/*
 * Finding the device's hdc daemon without being told the port.
 * See discovery.h for the protocol and the port-reuse caveat.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "discovery.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <fstream>
#include <sstream>

namespace swshell {

namespace {

/* The port the daemon listens on for discovery, and the banner it answers
 * with.  Both come from developtools_hdc/src/daemon/daemon_tcp.cpp and
 * src/common/define.h. */
constexpr uint16_t kDiscoveryPort = 8710;
constexpr const char *kDiscoveryRequest = "loopBroadcast";
constexpr const char *kDiscoveryBanner = "OHOS HDC-";

/*
 * Parses "<banner>-<port>" and returns the port, or 0 when the datagram is
 * not the daemon's answer - the app also receives the broadcast it sent
 * itself, and that one must be ignored.
 */
int ParseDaemonPort(const char *data, size_t length)
{
    const size_t bannerLength = strlen(kDiscoveryBanner);
    if (length <= bannerLength || memcmp(data, kDiscoveryBanner, bannerLength) != 0) {
        return 0;
    }
    int port = 0;
    for (size_t i = bannerLength; i < length; i++) {
        const char c = data[i];
        if (c < '0' || c > '9') {
            return 0;
        }
        port = port * 10 + (c - '0');
        if (port > 65535) {
            return 0;
        }
    }
    return port;
}

}  // namespace

int DiscoverDaemonPort(int timeoutMs, std::string &error)
{
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        error = std::string("socket failed: ") + strerror(errno);
        return 0;
    }

    /* The daemon binds the same port on the wildcard address, so we need
     * SO_REUSEADDR to be able to bind it as well. */
    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    int broadcast = 1;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast));

    struct sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    local.sin_port = htons(kDiscoveryPort);
    if (bind(sock, reinterpret_cast<struct sockaddr *>(&local), sizeof(local)) < 0) {
        error = std::string("bind to the discovery port failed: ") + strerror(errno);
        close(sock);
        return 0;
    }

    /* Ask on the loopback address and on the broadcast address: the daemon
     * binds the wildcard address, so either reaches it, and the loopback
     * one keeps the source address on this device, which is where the daemon
     * sends its answer back to. */
    struct sockaddr_in target = {};
    target.sin_family = AF_INET;
    target.sin_port = htons(kDiscoveryPort);
    target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sendto(sock, kDiscoveryRequest, strlen(kDiscoveryRequest), 0,
           reinterpret_cast<struct sockaddr *>(&target), sizeof(target));

    target.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(sock, kDiscoveryRequest, strlen(kDiscoveryRequest), 0,
           reinterpret_cast<struct sockaddr *>(&target), sizeof(target));

    int port = 0;
    const int pollMs = (timeoutMs > 0) ? timeoutMs : 3000;
    int waited = 0;
    while (waited < pollMs && port == 0) {
        struct pollfd fds = {};
        fds.fd = sock;
        fds.events = POLLIN;
        int ready = poll(&fds, 1, 200);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = std::string("poll failed: ") + strerror(errno);
            break;
        }
        if (ready == 0) {
            waited += 200;
            continue;
        }
        char buffer[256] = { 0 };
        struct sockaddr_in from = {};
        socklen_t fromLength = sizeof(from);
        ssize_t received = recvfrom(sock, buffer, sizeof(buffer) - 1, 0,
                                    reinterpret_cast<struct sockaddr *>(&from), &fromLength);
        if (received <= 0) {
            waited += 200;
            continue;
        }
        port = ParseDaemonPort(buffer, static_cast<size_t>(received));
        if (port == 0) {
            /* That was our own broadcast coming back.  Keep waiting. */
            waited += 200;
        }
    }

    close(sock);
    if (port == 0 && error.empty()) {
        error = "the device's hdc daemon did not answer the discovery broadcast";
    }
    return port;
}

namespace {

/*
 * Reads the listening TCP ports out of /proc/net/tcp.
 *
 * The format is one row per socket; the local address is hex, in
 * host byte order, followed by a colon and the hex port.  The state column
 * is 0A for LISTEN.  Only the wildcard address (00000000) and the loopback
 * address (0100007F) are of interest.
 */
void CollectPortsFromProc(const char *path, std::vector<int> &ports)
{
    std::ifstream file(path);
    std::string line;
    std::getline(file, line); /* the header row */
    while (std::getline(file, line)) {
        std::istringstream row(line);
        std::string field;
        std::string local;
        std::string remote;
        std::string state;
        if (!(row >> field >> local >> remote >> state)) {
            continue;
        }
        if (state != "0A") {
            continue;
        }
        const size_t colon = local.find(':');
        if (colon == std::string::npos) {
            continue;
        }
        const std::string address = local.substr(0, colon);
        if (address != "00000000" && address != "0100007F") {
            continue;
        }
        const long port = strtol(local.c_str() + colon + 1, nullptr, 16);
        if (port > 0 && port <= 65535) {
            ports.push_back(static_cast<int>(port));
        }
    }
}

}  // namespace

std::vector<int> ListListeningPorts()
{
    std::vector<int> ports;
    CollectPortsFromProc("/proc/net/tcp", ports);
    CollectPortsFromProc("/proc/net/tcp6", ports);
    std::sort(ports.begin(), ports.end());
    ports.erase(std::unique(ports.begin(), ports.end()), ports.end());
    return ports;
}

}  // namespace swshell
