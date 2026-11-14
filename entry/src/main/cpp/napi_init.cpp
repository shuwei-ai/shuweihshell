/*
 * The NAPI surface of the native library.
 *
 * ArkTS calls into this through `import swshell from 'libswshell.so'`.  The
 * exported functions are deliberately small and blocking-free from ArkTS's
 * point of view: anything that waits on the device runs on a libuv worker
 * thread and resolves a promise.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "napi/native_api.h"
#include "js_native_api.h"

#include "device_session.h"
#include "discovery.h"
#include "hdc_crypto.h"
#include "js_sandbox.h"
#include "py_sandbox.h"
#include "ssh_client.h"

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>

namespace {

swshell::DeviceSession *gSession = nullptr;
std::string gKeyDir;

napi_value MakeString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

napi_value MakeInt32(napi_env env, int32_t value)
{
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value MakeBool(napi_env env, bool value)
{
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value MakeExecResult(napi_env env, const swshell::ExecResult &result)
{
    napi_value object = nullptr;
    napi_create_object(env, &object);
    napi_set_named_property(env, object, "ok", MakeBool(env, result.ok));
    napi_set_named_property(env, object, "output", MakeString(env, result.output));
    napi_set_named_property(env, object, "error", MakeString(env, result.error));
    napi_value exitCode = nullptr;
    napi_create_int32(env, result.exitCode, &exitCode);
    napi_set_named_property(env, object, "exitCode", exitCode);
    return object;
}

swshell::DeviceSession *EnsureSession()
{
    if (gSession == nullptr) {
        gSession = new swshell::DeviceSession();
    }
    return gSession;
}

void DestroySession()
{
    if (gSession != nullptr) {
        delete gSession;
        gSession = nullptr;
    }
}

}  // namespace

namespace swshell {
DeviceSession* GetActiveDeviceSession()
{
    return gSession;
}
}

namespace {

/* --- init ------------------------------------------------------------- */

napi_value Init(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return MakeBool(env, false);
    }
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
    std::string keyDir(len, '\0');
    napi_get_value_string_utf8(env, argv[0], keyDir.data(), len + 1, &len);
    gKeyDir = keyDir;
    return MakeBool(env, true);
}

/* --- connect (async) -------------------------------------------------- */

struct ConnectTask {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string host;
    int port = 0;
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    bool ok = false;
    std::string error;
};

/*
 * The handshake runs on the session's libuv loop thread, so the result has to
 * be handed back to this worker thread before the promise can be resolved.
 */
void ConnectExecute(napi_env env, void *data)
{
    ConnectTask *task = static_cast<ConnectTask *>(data);
    swshell::DeviceSession *session = EnsureSession();
    session->ConnectAsync(task->host, task->port, gKeyDir, [task](bool ok, const std::string &error) {
        {
            std::lock_guard<std::mutex> lock(task->mutex);
            task->ok = ok;
            task->error = error;
            task->done = true;
        }
        task->cv.notify_all();
    });
    std::unique_lock<std::mutex> lock(task->mutex);
    task->cv.wait_for(lock, std::chrono::seconds(25), [task] { return task->done; });
    if (!task->done) {
        task->ok = false;
        task->error = "timed out waiting for the device handshake";
    }
}

void ConnectComplete(napi_env env, napi_status status, void *data)
{
    ConnectTask *task = static_cast<ConnectTask *>(data);
    napi_value result = nullptr;
    if (task->ok) {
        napi_get_boolean(env, true, &result);
    } else {
        napi_value object = nullptr;
        napi_create_object(env, &object);
        napi_set_named_property(env, object, "ok", MakeBool(env, false));
        napi_set_named_property(env, object, "error", MakeString(env, task->error));
        result = object;
    }
    napi_resolve_deferred(env, task->deferred, result);
    napi_delete_async_work(env, task->work);
    delete task;
}

napi_value Connect(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        return MakeBool(env, false);
    }

    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
    std::string host(len, '\0');
    napi_get_value_string_utf8(env, argv[0], host.data(), len + 1, &len);
    int32_t port = 0;
    napi_get_value_int32(env, argv[1], &port);

    ConnectTask *task = new ConnectTask();
    task->host = host;
    task->port = port;

    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);
    napi_create_async_work(env, nullptr, MakeString(env, "swshellConnect"), ConnectExecute, ConnectComplete,
                           task, &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

/* --- exec (async) ----------------------------------------------------- */

struct ExecTask {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string command;
    std::string bundleName;
    unsigned timeoutSeconds = 30;
    swshell::ExecResult result;
};

void ExecExecute(napi_env env, void *data)
{
    ExecTask *task = static_cast<ExecTask *>(data);
    if (gSession == nullptr) {
        task->result.error = "not connected";
        return;
    }
    gSession->Exec(task->command, task->bundleName, task->result, task->timeoutSeconds);
}

void ExecComplete(napi_env env, napi_status status, void *data)
{
    ExecTask *task = static_cast<ExecTask *>(data);
    napi_resolve_deferred(env, task->deferred, MakeExecResult(env, task->result));
    napi_delete_async_work(env, task->work);
    delete task;
}

napi_value Exec(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        napi_value rejected = nullptr;
        napi_create_object(env, &rejected);
        napi_set_named_property(env, rejected, "ok", MakeBool(env, false));
        napi_set_named_property(env, rejected, "error", MakeString(env, "missing command"));
        return rejected;
    }

    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
    std::string command(len, '\0');
    napi_get_value_string_utf8(env, argv[0], command.data(), len + 1, &len);

    std::string bundleName;
    if (argc >= 2 && argv[1] != nullptr) {
        napi_valuetype argType = napi_undefined;
        napi_typeof(env, argv[1], &argType);
        if (argType == napi_string) {
            napi_get_value_string_utf8(env, argv[1], nullptr, 0, &len);
            bundleName.assign(len, '\0');
            napi_get_value_string_utf8(env, argv[1], bundleName.data(), len + 1, &len);
        }
    }

    unsigned timeoutSeconds = 30;
    if (argc >= 3 && argv[2] != nullptr) {
        napi_valuetype argType = napi_undefined;
        napi_typeof(env, argv[2], &argType);
        if (argType == napi_number) {
            int32_t val = 0;
            if (napi_get_value_int32(env, argv[2], &val) == napi_ok && val >= 0) {
                timeoutSeconds = static_cast<unsigned>(val);
            }
        }
    }

    ExecTask *task = new ExecTask();
    task->command = command;
    task->bundleName = bundleName;
    task->timeoutSeconds = timeoutSeconds;

    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);
    napi_create_async_work(env, nullptr, MakeString(env, "swshellExec"), ExecExecute, ExecComplete,
                            task, &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

/* --- execStream -------------------------------------------------------- */

struct StreamExecTask {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_threadsafe_function tsfn = nullptr;
    std::string command;
    std::string bundleName;
    unsigned timeoutSeconds = 0;
    swshell::ExecResult result;
};

static void StreamCallJs(napi_env env, napi_value js_cb, void *context, void *data)
{
    if (env == nullptr || js_cb == nullptr || data == nullptr) {
        delete static_cast<std::string *>(data);
        return;
    }
    auto *chunk = static_cast<std::string *>(data);
    napi_value strVal = nullptr;
    napi_create_string_utf8(env, chunk->c_str(), chunk->size(), &strVal);
    delete chunk;

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value callRet = nullptr;
    napi_call_function(env, undefined, js_cb, 1, &strVal, &callRet);
}

void ExecStreamExecute(napi_env env, void *data)
{
    StreamExecTask *task = static_cast<StreamExecTask *>(data);
    if (gSession == nullptr) {
        task->result.error = "not connected";
        return;
    }

    swshell::DeviceSession::StreamChunkCallback onChunk = nullptr;
    if (task->tsfn != nullptr) {
        napi_threadsafe_function tsfn = task->tsfn;
        onChunk = [tsfn](const std::string &chunk) {
            auto *chunkCopy = new std::string(chunk);
            napi_status st = napi_call_threadsafe_function(tsfn, chunkCopy, napi_tsfn_nonblocking);
            if (st != napi_ok) {
                delete chunkCopy;
            }
        };
    }

    gSession->Exec(task->command, task->bundleName, task->result, task->timeoutSeconds, onChunk);
}

void ExecStreamComplete(napi_env env, napi_status status, void *data)
{
    StreamExecTask *task = static_cast<StreamExecTask *>(data);
    if (task->tsfn != nullptr) {
        napi_release_threadsafe_function(task->tsfn, napi_tsfn_release);
        task->tsfn = nullptr;
    }
    napi_resolve_deferred(env, task->deferred, MakeExecResult(env, task->result));
    napi_delete_async_work(env, task->work);
    delete task;
}

napi_value ExecStream(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        napi_value rejected = nullptr;
        napi_create_object(env, &rejected);
        napi_set_named_property(env, rejected, "ok", MakeBool(env, false));
        napi_set_named_property(env, rejected, "error", MakeString(env, "missing command"));
        return rejected;
    }

    auto *task = new StreamExecTask();
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
    task->command.assign(len, '\0');
    napi_get_value_string_utf8(env, argv[0], task->command.data(), len + 1, &len);

    if (argc >= 2 && argv[1] != nullptr) {
        napi_valuetype t;
        napi_typeof(env, argv[1], &t);
        if (t == napi_string) {
            napi_get_value_string_utf8(env, argv[1], nullptr, 0, &len);
            task->bundleName.assign(len, '\0');
            napi_get_value_string_utf8(env, argv[1], task->bundleName.data(), len + 1, &len);
        }
    }

    if (argc >= 3 && argv[2] != nullptr) {
        napi_valuetype t;
        napi_typeof(env, argv[2], &t);
        if (t == napi_function) {
            napi_value resourceName = nullptr;
            napi_create_string_utf8(env, "swshellStream", NAPI_AUTO_LENGTH, &resourceName);
            napi_create_threadsafe_function(env, argv[2], nullptr, resourceName, 0, 1,
                                            nullptr, nullptr, nullptr, StreamCallJs, &task->tsfn);
        }
    }

    if (argc >= 4 && argv[3] != nullptr) {
        int timeout = 0;
        napi_get_value_int32(env, argv[3], &timeout);
        task->timeoutSeconds = timeout >= 0 ? static_cast<unsigned>(timeout) : 0;
    } else {
        task->timeoutSeconds = 0; // 0 = stream mode (wait until exit or abort)
    }

    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);
    napi_create_async_work(env, nullptr, MakeString(env, "swshellExecStream"), ExecStreamExecute,
                           ExecStreamComplete, task, &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

/* --- abort ------------------------------------------------------------- */

napi_value Abort(napi_env env, napi_callback_info info)
{
    bool ok = false;
    if (gSession != nullptr) {
        ok = gSession->Abort();
    }
    return MakeBool(env, ok);
}

/* --- discover ---------------------------------------------------------- */

/*
 * Asks the device's hdc daemon for the port it is listening on.  The
 * daemon answers the same LAN broadcast the `hdc target discover` command
 * sends, so this is the on-device equivalent of that.
 */
struct DiscoverTask {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int port = 0;
    std::string error;
};

void DiscoverExecute(napi_env env, void *data)
{
    DiscoverTask *task = static_cast<DiscoverTask *>(data);
    task->port = swshell::DiscoverDaemonPort(3000, task->error);
}

void DiscoverComplete(napi_env env, napi_status status, void *data)
{
    DiscoverTask *task = static_cast<DiscoverTask *>(data);
    if (task->port > 0) {
        napi_value result = nullptr;
        napi_create_int32(env, task->port, &result);
        napi_resolve_deferred(env, task->deferred, result);
    } else {
        napi_value object = nullptr;
        napi_create_object(env, &object);
        napi_set_named_property(env, object, "port", MakeInt32(env, 0));
        napi_set_named_property(env, object, "error", MakeString(env, task->error));
        napi_resolve_deferred(env, task->deferred, object);
    }
    napi_delete_async_work(env, task->work);
    delete task;
}

napi_value Discover(napi_env env, napi_callback_info info)
{
    DiscoverTask *task = new DiscoverTask();
    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);
    napi_create_async_work(env, nullptr, MakeString(env, "swshellDiscover"), DiscoverExecute, DiscoverComplete,
                           task, &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

/* --- execSync ---------------------------------------------------------- */

/*
 * The synchronous variant.  rpc.RemoteObject.onRemoteRequest may not await,
 * and the native session already blocks until the command finishes, so this
 * is the call the AIDL service uses.
 */
napi_value ExecSync(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    swshell::ExecResult result;
    if (argc >= 1) {
        size_t len = 0;
        napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
        std::string command(len, '\0');
        napi_get_value_string_utf8(env, argv[0], command.data(), len + 1, &len);

        std::string bundleName;
        if (argc >= 2) {
            napi_get_value_string_utf8(env, argv[1], nullptr, 0, &len);
            bundleName.assign(len, '\0');
            napi_get_value_string_utf8(env, argv[1], bundleName.data(), len + 1, &len);
        }
        if (gSession != nullptr) {
            gSession->Exec(command, bundleName, result);
        } else {
            result.error = "not connected";
        }
    } else {
        result.error = "missing command";
    }
    return MakeExecResult(env, result);
}

/* --- listPorts --------------------------------------------------------- */

/* The TCP ports this device is listening on, straight out of /proc/net/tcp. */
napi_value ListPorts(napi_env env, napi_callback_info info)
{
    std::vector<int> ports = swshell::ListListeningPorts();
    napi_value array = nullptr;
    napi_create_array_with_length(env, ports.size(), &array);
    for (size_t i = 0; i < ports.size(); i++) {
        napi_set_element(env, array, static_cast<uint32_t>(i), MakeInt32(env, ports[i]));
    }
    return array;
}

/* --- disconnect -------------------------------------------------------- */

napi_value Disconnect(napi_env env, napi_callback_info info)
{
    DestroySession();
    return MakeBool(env, true);
}

/* --- state ------------------------------------------------------------ */

napi_value IsConnected(napi_env env, napi_callback_info info)
{
    return MakeBool(env, gSession != nullptr && gSession->IsReady());
}

/* --- public key -------------------------------------------------------- */

napi_value PublicKey(napi_env env, napi_callback_info info)
{
    return MakeString(env, swshell::HdcCrypto::Instance().PublicKeyPem());
}

/* --- runJs (async offline JSVM sandbox) ------------------------------ */

struct RunJsTask {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string code;
    std::string inputJson;
    int timeoutMs = 5000;
    swshell::JsEvalResult evalResult;
};

void RunJsExecute(napi_env env, void *data)
{
    RunJsTask *task = static_cast<RunJsTask *>(data);
    task->evalResult = swshell::EvalJsSandbox(task->code, task->inputJson, task->timeoutMs);
}

void RunJsComplete(napi_env env, napi_status status, void *data)
{
    RunJsTask *task = static_cast<RunJsTask *>(data);
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "ok", MakeBool(env, task->evalResult.ok));
    napi_set_named_property(env, obj, "result", MakeString(env, task->evalResult.result));
    napi_set_named_property(env, obj, "logs", MakeString(env, task->evalResult.logs));
    napi_set_named_property(env, obj, "error", MakeString(env, task->evalResult.error));
    napi_set_named_property(env, obj, "elapsedMs", MakeInt32(env, static_cast<int32_t>(task->evalResult.elapsedMs)));
    napi_resolve_deferred(env, task->deferred, obj);
    napi_delete_async_work(env, task->work);
    delete task;
}

napi_value RunJs(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1 || argv[0] == nullptr) {
        napi_value errObj = nullptr;
        napi_create_object(env, &errObj);
        napi_set_named_property(env, errObj, "ok", MakeBool(env, false));
        napi_set_named_property(env, errObj, "result", MakeString(env, ""));
        napi_set_named_property(env, errObj, "logs", MakeString(env, ""));
        napi_set_named_property(env, errObj, "error", MakeString(env, "missing code"));
        napi_set_named_property(env, errObj, "elapsedMs", MakeInt32(env, 0));
        return errObj;
    }

    auto readUtf8Arg = [&](napi_value val) -> std::string {
        if (val == nullptr) {
            return std::string();
        }
        napi_valuetype argType = napi_undefined;
        if (napi_typeof(env, val, &argType) != napi_ok || argType != napi_string) {
            return std::string();
        }
        size_t len = 0;
        napi_get_value_string_utf8(env, val, nullptr, 0, &len);
        std::string out(len, '\0');
        if (len > 0) {
            napi_get_value_string_utf8(env, val, out.data(), len + 1, &len);
        }
        return out;
    };

    RunJsTask *task = new RunJsTask();
    task->code = readUtf8Arg(argv[0]);
    if (argc >= 2) {
        task->inputJson = readUtf8Arg(argv[1]);
    }
    if (argc >= 3 && argv[2] != nullptr) {
        napi_valuetype argType = napi_undefined;
        if (napi_typeof(env, argv[2], &argType) == napi_ok && argType == napi_number) {
            int32_t ms = 5000;
            if (napi_get_value_int32(env, argv[2], &ms) == napi_ok && ms > 0) {
                task->timeoutMs = ms;
            }
        }
    }

    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);
    napi_create_async_work(env, nullptr, MakeString(env, "swshellRunJs"), RunJsExecute, RunJsComplete,
                            task, &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

/* --- runPython (async offline MicroPython sandbox) ------------------- */

struct RunPythonTask {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string code;
    swshell::PySandboxOptions options;
    swshell::PySandboxResult result;
};

void RunPythonExecute(napi_env env, void *data)
{
    RunPythonTask *task = static_cast<RunPythonTask *>(data);
    task->result = swshell::ExecutePythonSandbox(task->code, task->options);
}

void RunPythonComplete(napi_env env, napi_status status, void *data)
{
    RunPythonTask *task = static_cast<RunPythonTask *>(data);
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "ok", MakeBool(env, task->result.ok));
    napi_set_named_property(env, obj, "stdout", MakeString(env, task->result.stdoutStr));
    napi_set_named_property(env, obj, "stderr", MakeString(env, task->result.stderrStr));
    napi_set_named_property(env, obj, "timedOut", MakeBool(env, task->result.timedOut));
    napi_set_named_property(env, obj, "elapsedMs", MakeInt32(env, static_cast<int32_t>(task->result.elapsedMs)));
    napi_resolve_deferred(env, task->deferred, obj);
    napi_delete_async_work(env, task->work);
    delete task;
}

napi_value RunPython(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1 || argv[0] == nullptr) {
        napi_value errObj = nullptr;
        napi_create_object(env, &errObj);
        napi_set_named_property(env, errObj, "ok", MakeBool(env, false));
        napi_set_named_property(env, errObj, "stdout", MakeString(env, ""));
        napi_set_named_property(env, errObj, "stderr", MakeString(env, "missing code"));
        napi_set_named_property(env, errObj, "timedOut", MakeBool(env, false));
        napi_set_named_property(env, errObj, "elapsedMs", MakeInt32(env, 0));
        return errObj;
    }

    auto readUtf8Arg = [&](napi_value val) -> std::string {
        if (val == nullptr) {
            return std::string();
        }
        napi_valuetype argType = napi_undefined;
        if (napi_typeof(env, val, &argType) != napi_ok || argType != napi_string) {
            return std::string();
        }
        size_t len = 0;
        napi_get_value_string_utf8(env, val, nullptr, 0, &len);
        std::string out(len, '\0');
        if (len > 0) {
            napi_get_value_string_utf8(env, val, out.data(), len + 1, &len);
        }
        return out;
    };

    RunPythonTask *task = new RunPythonTask();
    task->code = readUtf8Arg(argv[0]);
    if (argc >= 2) {
        task->options.inputJson = readUtf8Arg(argv[1]);
    }
    if (argc >= 3 && argv[2] != nullptr) {
        napi_valuetype argType = napi_undefined;
        if (napi_typeof(env, argv[2], &argType) == napi_ok && argType == napi_number) {
            int32_t ms = 5000;
            if (napi_get_value_int32(env, argv[2], &ms) == napi_ok && ms > 0) {
                task->options.timeoutMs = static_cast<uint32_t>(ms);
            }
        }
    }
    if (argc >= 4 && argv[3] != nullptr) {
        napi_valuetype argType = napi_undefined;
        if (napi_typeof(env, argv[3], &argType) == napi_ok && argType == napi_number) {
            int64_t bytes = 4 * 1024 * 1024;
            if (napi_get_value_int64(env, argv[3], &bytes) == napi_ok && bytes > 0) {
                task->options.heapLimitBytes = static_cast<size_t>(bytes);
            }
        }
    }

    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);
    napi_create_async_work(env, nullptr, MakeString(env, "swshellRunPython"), RunPythonExecute, RunPythonComplete,
                           task, &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

/* --- sshExec (async native SSH-2.0 remote execution) ------------------ */

struct SshExecTask {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    swshell::SshExecRequest req;
    swshell::SshExecResult res;
};

static std::string ReadNamedStringProp(napi_env env, napi_value obj, const char *name)
{
    bool hasProp = false;
    if (napi_has_named_property(env, obj, name, &hasProp) != napi_ok || !hasProp) {
        return std::string();
    }
    napi_value prop = nullptr;
    if (napi_get_named_property(env, obj, name, &prop) != napi_ok || prop == nullptr) {
        return std::string();
    }
    napi_valuetype argType = napi_undefined;
    if (napi_typeof(env, prop, &argType) != napi_ok || argType != napi_string) {
        return std::string();
    }
    size_t len = 0;
    napi_get_value_string_utf8(env, prop, nullptr, 0, &len);
    std::string out(len, '\0');
    if (len > 0) {
        napi_get_value_string_utf8(env, prop, out.data(), len + 1, &len);
    }
    return out;
}

static int ReadNamedIntProp(napi_env env, napi_value obj, const char *name, int defaultVal)
{
    bool hasProp = false;
    if (napi_has_named_property(env, obj, name, &hasProp) != napi_ok || !hasProp) {
        return defaultVal;
    }
    napi_value prop = nullptr;
    if (napi_get_named_property(env, obj, name, &prop) != napi_ok || prop == nullptr) {
        return defaultVal;
    }
    napi_valuetype argType = napi_undefined;
    if (napi_typeof(env, prop, &argType) != napi_ok || argType != napi_number) {
        return defaultVal;
    }
    int32_t val = defaultVal;
    if (napi_get_value_int32(env, prop, &val) != napi_ok) {
        return defaultVal;
    }
    return static_cast<int>(val);
}

void SshExecExecute(napi_env env, void *data)
{
    SshExecTask *task = static_cast<SshExecTask *>(data);
    task->res = swshell::ExecuteSshCommand(task->req);
}

void SshExecComplete(napi_env env, napi_status status, void *data)
{
    SshExecTask *task = static_cast<SshExecTask *>(data);
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "ok", MakeBool(env, task->res.ok));
    napi_set_named_property(env, obj, "exitCode", MakeInt32(env, task->res.exitCode));
    napi_set_named_property(env, obj, "output", MakeString(env, task->res.output));
    napi_set_named_property(env, obj, "stderrOutput", MakeString(env, task->res.stderrOutput));
    napi_set_named_property(env, obj, "error", MakeString(env, task->res.error));
    napi_set_named_property(env, obj, "hostFingerprint", MakeString(env, task->res.hostFingerprint));
    napi_resolve_deferred(env, task->deferred, obj);
    napi_delete_async_work(env, task->work);
    delete task;
}

napi_value SshExec(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_valuetype argType = napi_undefined;
    if (argc < 1 || argv[0] == nullptr ||
        napi_typeof(env, argv[0], &argType) != napi_ok || argType != napi_object) {
        napi_value errObj = nullptr;
        napi_create_object(env, &errObj);
        napi_set_named_property(env, errObj, "ok", MakeBool(env, false));
        napi_set_named_property(env, errObj, "exitCode", MakeInt32(env, -1));
        napi_set_named_property(env, errObj, "output", MakeString(env, ""));
        napi_set_named_property(env, errObj, "stderrOutput", MakeString(env, ""));
        napi_set_named_property(env, errObj, "error", MakeString(env, "missing sshExec options object"));
        napi_set_named_property(env, errObj, "hostFingerprint", MakeString(env, ""));
        return errObj;
    }

    SshExecTask *task = new SshExecTask();
    task->req.host = ReadNamedStringProp(env, argv[0], "host");
    task->req.port = ReadNamedIntProp(env, argv[0], "port", 22);
    task->req.username = ReadNamedStringProp(env, argv[0], "username");
    task->req.password = ReadNamedStringProp(env, argv[0], "password");
    task->req.privateKeyPem = ReadNamedStringProp(env, argv[0], "privateKeyPem");
    task->req.command = ReadNamedStringProp(env, argv[0], "command");
    task->req.expectedFingerprint = ReadNamedStringProp(env, argv[0], "expectedFingerprint");
    task->req.timeoutSeconds = ReadNamedIntProp(env, argv[0], "timeoutSeconds", 30);

    napi_value promise = nullptr;
    napi_create_promise(env, &task->deferred, &promise);
    napi_create_async_work(env, nullptr, MakeString(env, "swshellSshExec"), SshExecExecute, SshExecComplete,
                            task, &task->work);
    napi_queue_async_work(env, task->work);
    return promise;
}

/* --- module registration ---------------------------------------------- */

napi_value InitAll(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        { "init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "disconnect", nullptr, Disconnect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "exec", nullptr, Exec, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "execStream", nullptr, ExecStream, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "abort", nullptr, Abort, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "execSync", nullptr, ExecSync, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "discover", nullptr, Discover, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "listPorts", nullptr, ListPorts, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isConnected", nullptr, IsConnected, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "publicKey", nullptr, PublicKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "runJs", nullptr, RunJs, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "runPython", nullptr, RunPython, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshExec", nullptr, SshExec, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

napi_module g_module = {
    1,                          /* nm_version */
    0,                          /* nm_flags */
    nullptr,                    /* nm_filename */
    InitAll,                    /* nm_register_func */
    "swshell",                  /* nm_modname */
    nullptr,                    /* nm_priv */
    {nullptr, nullptr, nullptr, nullptr}, /* reserved */
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterSwShellModule(void)
{
    napi_module_register(&g_module);
}
