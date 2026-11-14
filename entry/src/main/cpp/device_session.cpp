/*
 * The app-role device session - implementation.  See device_session.h.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "device_session.h"

#include "base.h"
#include "define.h"
#include "define_enum.h"
#include "define_plus.h"
#include "host_tcp.h"
#include "discovery.h"
#include "hdc_crypto.h"
#include "serial_struct.h"
#include "tlv.h"

#include <chrono>
#include <memory>
#include <sstream>

namespace swshell {

using Hdc::HdcHostTCP;
using Hdc::HdcSessionBase;
using Hdc::HSession;

namespace {

/* The daemon separates the host name from the public key with this byte. */
constexpr char kHostDaemonBufSeparator = '\x0C';

/*
 * Builds the numeric TLV the daemon's extended shell command expects:
 * the command itself and the bundle it should run in.
 */
std::string BuildShellTlv(const std::string &bundleName, const std::string &command)
{
    Hdc::TlvBuf tlv(Hdc::Base::REGISTERD_TAG_SET);
    if (!bundleName.empty()) {
        if (!tlv.Append(Hdc::TAG_SHELL_BUNDLE, bundleName)) {
            return std::string();
        }
    }
    if (command.empty() || !tlv.Append(Hdc::TAG_SHELL_CMD, command)) {
        return std::string();
    }
    uint32_t size = tlv.GetBufSize();
    if (size == 0) {
        return std::string();
    }
    std::vector<uint8_t> buffer(size, 0);
    if (!tlv.CopyToBuf(buffer.data(), buffer.size())) {
        return std::string();
    }
    return std::string(reinterpret_cast<const char *>(buffer.data()), buffer.size());
}

}  // namespace

DeviceSession::DeviceSession() : HdcSessionBase(true)
{
    StartLoop();
    Report("device session created");
}

DeviceSession::~DeviceSession()
{
    Disconnect();
}

void DeviceSession::StartLoop()
{
    if (loopRunning_.exchange(true)) {
        return;
    }
    /*
     * WorkerPendding() runs uv_run over the session's main loop.  Every
     * libuv call that touches the session has to happen on this thread.
     */
    loopThread_ = std::thread([this]() {
        this->WorkerPendding();
        loopRunning_ = false;
    });
}

void DeviceSession::StopLoop()
{
    if (!loopRunning_.load()) {
        return;
    }
    /* Stops uv_run, which lets the loop thread fall out of WorkerPendding. */
    this->PostStopInstanceMessage(false);
    if (loopThread_.joinable()) {
        loopThread_.join();
    }
    loopRunning_ = false;
}

void DeviceSession::Report(const std::string &message)
{
    if (logSink) {
        logSink(message);
    }
}

void DeviceSession::ReportState(bool ready, const std::string &detail)
{
    if (stateSink) {
        stateSink(ready, detail);
    }
}

void DeviceSession::ConnectAsync(const std::string &host, int port, const std::string &keyDir,
                                 ConnectCallback callback)
{
    std::string cryptoError;
    if (!HdcCrypto::Instance().EnsureKeypair(keyDir, cryptoError)) {
        FinishConnect(false, "client keypair unavailable: " + cryptoError);
        return;
    }

    keyDir_ = keyDir;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        connectCallback_ = callback;
        handshakeOk_ = false;
        handshakeError_.clear();
    }

    if (tcpClient_ == nullptr) {
        tcpClient_ = new HdcHostTCP(true, this);
    }

    if (port > 0) {
        candidates_.assign(1, port);
    } else {
        candidates_ = ListListeningPorts();
        if (candidates_.empty()) {
            FinishConnect(false, "the device has no reachable TCP port to try");
            return;
        }
        Report("the device is listening on " + std::to_string(candidates_.size()) + " ports, trying them");
    }
    candidateIndex_ = 0;
    TryNextCandidate();
}

void DeviceSession::TryNextCandidate()
{
    if (candidateIndex_ >= candidates_.size()) {
        FinishConnect(false, "none of the device's listening ports spoke the hdc protocol");
        return;
    }
    const int port = candidates_[candidateIndex_++];
    connectKey_ = "127.0.0.1:" + std::to_string(port);

    /*
     * The connect has to be issued from the loop thread: uv_tcp_connect is
     * not thread safe, and a connect issued from anywhere else is queued
     * and never sent.
     */
    Hdc::Base::DoNextLoop(&loopMain, this, [](const uint8_t flag, std::string &msg, const void *data) {
        auto *self = const_cast<DeviceSession *>(static_cast<const DeviceSession *>(data));
        self->session_ = self->tcpClient_->ConnectDaemon(self->connectKey_, false);
        if (self->session_ == nullptr) {
            self->FinishConnect(false, "failed to open a TCP session to " + self->connectKey_);
        }
    });
}

void DeviceSession::FinishConnect(bool ok, const std::string &error)
{
    /*
     * A failed handshake on one port just means that port is not the hdc
     * daemon; if there are more candidates, try the next one.
     */
    if (!ok && candidateIndex_ < candidates_.size() && !handshakeError_.empty()) {
        Report("port " + connectKey_ + " did not answer the hdc handshake: " + handshakeError_);
        handshakeError_.clear();
        TryNextCandidate();
        return;
    }

    ConnectCallback callback;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (ok) {
            handshakeOk_ = true;
            handshakeError_.clear();
        } else if (handshakeError_.empty()) {
            handshakeError_ = error;
        }
        callback = connectCallback_;
        connectCallback_ = nullptr;
    }
    if (callback) {
        callback(ok, ok ? std::string() : error);
    }
    ReportState(ok, ok ? ("connected to " + connectKey_) : error);
}

void DeviceSession::Disconnect()
{
    if (tcpClient_ != nullptr) {
        delete tcpClient_;
        tcpClient_ = nullptr;
    }
    session_ = nullptr;
    StopLoop();
}

bool DeviceSession::IsReady() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return handshakeOk_;
}

bool DeviceSession::SendHandshake(HSession hSession, const uint32_t channelId, uint8_t authType,
                                  const std::string &buf)
{
    HdcSessionBase::SessionHandShake handshake;
    handshake.banner = Hdc::HANDSHAKE_MESSAGE;
    handshake.authType = authType;
    handshake.sessionId = hSession->sessionId;
    handshake.connectKey = connectKey_;
    handshake.buf = buf;
    handshake.version = Hdc::Base::GetVersion();

    std::string serialized = Hdc::SerialStruct::SerializeToString(handshake);
    int ret = Send(hSession->sessionId, channelId, Hdc::CMD_KERNEL_HANDSHAKE,
                   reinterpret_cast<uint8_t *>(const_cast<char *>(serialized.data())),
                   static_cast<int>(serialized.size()));
    if (ret < 0) {
        Report("failed to send a handshake packet");
        return false;
    }
    return true;
}

bool DeviceSession::HandleHandshake(HSession hSession, const uint32_t channelId, uint8_t *payload,
                                    int payloadSize)
{
    HdcSessionBase::SessionHandShake handshake;
    Hdc::SerialStruct::ParseFromString(handshake, std::string(reinterpret_cast<char *>(payload), payloadSize));

    if (handshake.banner == Hdc::HANDSHAKE_FAILED) {
        FinishConnect(false, "the device refused the handshake");
        return false;
    }
    if (handshake.banner != Hdc::HANDSHAKE_MESSAGE) {
        Report("unexpected handshake banner from the device");
        return false;
    }

    switch (handshake.authType) {
        case HdcSessionBase::AUTH_PUBLICKEY: {
            /*
             * The device is asking for our public key.  It also tells us
             * which signature scheme it supports; we always offer
             * RSA-3072/SHA-512, which is what the upstream host does.
             */
            std::map<std::string, std::string> tlvMap;
            if (Hdc::Base::TlvToStringMap(handshake.buf, tlvMap)) {
                auto it = tlvMap.find(TAG_AUTH_TYPE);
                if (it != tlvMap.end() && it->second != std::to_string(Hdc::AuthVerifyType::RSA_3072_SHA512)) {
                    FinishConnect(false, "the device only supports the legacy RSA auth mode");
                    return false;
                }
            }
            std::string info = HdcCrypto::Instance().HostName();
            info += kHostDaemonBufSeparator;
            info += HdcCrypto::Instance().PublicKeyPem();
            if (!SendHandshake(hSession, channelId, HdcSessionBase::AUTH_PUBLICKEY, info)) {
                FinishConnect(false, "failed to send our public key");
                return false;
            }
            Report("sent our public key to the device");
            return true;
        }
        case HdcSessionBase::AUTH_SIGNATURE: {
            /* The device sent the token to sign. */
            std::string signature;
            std::string signError;
            if (!HdcCrypto::Instance().SignToken(handshake.buf, signature, signError)) {
                FinishConnect(false, "failed to sign the device challenge: " + signError);
                return false;
            }
            if (!SendHandshake(hSession, channelId, HdcSessionBase::AUTH_SIGNATURE, signature)) {
                FinishConnect(false, "failed to send our signature");
                return false;
            }
            Report("signed the device challenge");
            return true;
        }
        case HdcSessionBase::AUTH_OK: {
            session_ = hSession;
            FinishConnect(true, std::string());
            return true;
        }
        default:
            Report("unexpected handshake state from the device");
            return false;
    }
}

bool DeviceSession::FetchCommand(HSession hSession, const uint32_t channelId, const uint16_t command,
                                  uint8_t *payload, int payloadSize)
{
    if (command == Hdc::CMD_KERNEL_HANDSHAKE) {
        return HandleHandshake(hSession, channelId, payload, payloadSize);
    }
    if (command == Hdc::CMD_KERNEL_ECHO_RAW) {
        std::string chunk(reinterpret_cast<const char *>(payload), static_cast<size_t>(payloadSize));
        StreamChunkCallback chunkSink = nullptr;
        {
            std::lock_guard<std::mutex> lock(execMutex_);
            if (pendingChannelId_ != 0 && (channelId == pendingChannelId_ || channelId == 0)) {
                pendingOutput_.append(chunk);
                chunkSink = streamChunkSink_;
            }
        }
        if (chunkSink) {
            chunkSink(chunk);
        }
        return true;
    }
    if (command == Hdc::CMD_KERNEL_ECHO) {
        std::string chunk;
        if (payloadSize > 1) {
            chunk.assign(reinterpret_cast<const char *>(payload + 1), static_cast<size_t>(payloadSize - 1));
        } else if (payloadSize == 1) {
            // empty message with only MessageLevel
        } else {
            chunk.assign(reinterpret_cast<const char *>(payload), static_cast<size_t>(payloadSize));
        }
        StreamChunkCallback chunkSink = nullptr;
        {
            std::lock_guard<std::mutex> lock(execMutex_);
            if (pendingChannelId_ != 0 && (channelId == pendingChannelId_ || channelId == 0)) {
                if (!chunk.empty()) {
                    pendingOutput_.append(chunk);
                    chunkSink = streamChunkSink_;
                }
            }
        }
        if (chunkSink && !chunk.empty()) {
            chunkSink(chunk);
        }
        return true;
    }
    if (command == Hdc::CMD_KERNEL_CHANNEL_CLOSE) {
        {
            std::lock_guard<std::mutex> lock(execMutex_);
            if (channelId == pendingChannelId_) {
                pendingDone_ = true;
            }
        }
        execCv_.notify_all();
        return true;
    }
    return true;
}

void DeviceSession::SendChannelClose(uint32_t sessionId, uint32_t channelId)
{
    if (channelId == 0 || !loopRunning_.load()) {
        return;
    }
    struct CloseCtx {
        DeviceSession *self = nullptr;
        uint32_t sessionId = 0;
        uint32_t channelId = 0;
    };
    CloseCtx *ctx = new CloseCtx{this, sessionId, channelId};
    Hdc::Base::DoNextLoop(&loopMain, ctx, [](const uint8_t, std::string &, const void *data) {
        std::unique_ptr<CloseCtx> c(const_cast<CloseCtx *>(static_cast<const CloseCtx *>(data)));
        uint8_t count = 1;
        c->self->Send(c->sessionId, c->channelId, Hdc::CMD_KERNEL_CHANNEL_CLOSE, &count, 1);
    });
}

bool DeviceSession::Exec(const std::string &command, const std::string &bundleName, ExecResult &result,
                         unsigned timeoutSeconds, StreamChunkCallback onChunk)
{
    std::lock_guard<std::mutex> serializeLock(execSerializeMutex_);
    if (!IsReady() || session_ == nullptr) {
        result.error = "not connected to the device";
        return false;
    }

    uint16_t cmdFlag = Hdc::CMD_UNITY_EXECUTE;
    std::string payload;
    if (!bundleName.empty()) {
        cmdFlag = Hdc::CMD_UNITY_EXECUTE_EX;
        payload = BuildShellTlv(bundleName, command);
        if (payload.empty()) {
            result.error = "failed to encode the command";
            return false;
        }
    } else {
        cmdFlag = Hdc::CMD_UNITY_EXECUTE;
        payload = command;
    }

    uint32_t channelId = 0;
    {
        std::lock_guard<std::mutex> lock(execMutex_);
        channelId = nextChannelId_++;
        pendingChannelId_ = channelId;
        pendingOutput_.clear();
        pendingDone_ = false;
        pendingAborted_ = false;
        streamChunkSink_ = onChunk;
    }

    struct SendCtx {
        DeviceSession *self = nullptr;
        uint32_t sessionId = 0;
        uint32_t channelId = 0;
        uint16_t cmdFlag = 0;
        std::string payload;
        int sendRet = 0;
        std::mutex mtx;
        std::condition_variable cv;
        bool done = false;
    };
    auto ctx = std::make_shared<SendCtx>();
    ctx->self = this;
    ctx->sessionId = session_->sessionId;
    ctx->channelId = channelId;
    ctx->cmdFlag = cmdFlag;
    ctx->payload = std::move(payload);

    Hdc::Base::DoNextLoop(&loopMain, ctx.get(), [](const uint8_t, std::string &, const void *data) {
        auto *c = const_cast<SendCtx *>(static_cast<const SendCtx *>(data));
        c->sendRet = c->self->Send(c->sessionId, c->channelId, c->cmdFlag,
                                   reinterpret_cast<const uint8_t *>(c->payload.data()),
                                   static_cast<int>(c->payload.size()));
        {
            std::lock_guard<std::mutex> lock(c->mtx);
            c->done = true;
        }
        c->cv.notify_all();
    });

    {
        std::unique_lock<std::mutex> lock(ctx->mtx);
        ctx->cv.wait(lock, [&ctx] { return ctx->done; });
    }

    if (ctx->sendRet < 0) {
        std::lock_guard<std::mutex> lock(execMutex_);
        pendingChannelId_ = 0;
        streamChunkSink_ = nullptr;
        result.error = "failed to send the command";
        return false;
    }

    bool timedOut = false;
    bool wasAborted = false;
    uint32_t sessionId = session_->sessionId;
    {
        std::unique_lock<std::mutex> lock(execMutex_);
        if (timeoutSeconds > 0) {
            bool signalled = execCv_.wait_for(lock, std::chrono::seconds(timeoutSeconds),
                                              [this] { return pendingDone_; });
            if (!signalled) {
                timedOut = true;
            }
        } else {
            execCv_.wait(lock, [this] { return pendingDone_; });
        }
        result.output = pendingOutput_;
        wasAborted = pendingAborted_;
        pendingChannelId_ = 0;
        streamChunkSink_ = nullptr;
    }

    if (wasAborted) {
        result.ok = false;
        result.exitCode = -130;
        result.error = "命令已由用户中断 (SIGINT)";
        return false;
    }
    if (timedOut) {
        SendChannelClose(sessionId, channelId);
        result.ok = false;
        result.exitCode = -124;
        result.error = "Command timed out after " + std::to_string(timeoutSeconds) + "s";
        Report("command timed out after " + std::to_string(timeoutSeconds) + "s on channel " +
               std::to_string(channelId));
        return false;
    }
    result.ok = true;
    return true;
}

bool DeviceSession::Abort()
{
    uint32_t channelId = 0;
    uint32_t sessionId = 0;
    {
        std::lock_guard<std::mutex> lock(execMutex_);
        if (pendingChannelId_ == 0 || session_ == nullptr) {
            return false;
        }
        channelId = pendingChannelId_;
        sessionId = session_->sessionId;
        pendingAborted_ = true;
        pendingDone_ = true;
    }

    SendChannelClose(sessionId, channelId);
    execCv_.notify_all();
    Report("aborted command on channel " + std::to_string(channelId));
    return true;
}

}  // namespace swshell
