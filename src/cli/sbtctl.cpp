// sbtctl — the one command-line client for the SBTouch command server.
//
// Transport: the file mailbox the server is actually allowed to use inside
// backboardd's sandbox (measured 2026-11-11: unix bind -> EPERM, Mach service
// registration -> refused; file create/unlink under /var/mobile -> allowed).
//
//   write  /var/mobile/sbtouch_inbox/<id>.json     (tmp + rename, atomic)
//   poll   /var/mobile/sbtouch_outbox/<id>.json    (10 ms, bounded)
//
// Exit codes are the contract the host relies on, and they are facts:
//   0  status=ok
//   2  status=busy   (executor taken — caller decides, we never retry)
//   3  no server / no reply within the deadline
//   4  status=error  (the reply says why)
//   5  usage / protocol error
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "json.hpp"

namespace {

constexpr const char* kInboxDir = "/var/mobile/sbtouch_inbox";
constexpr const char* kOutboxDir = "/var/mobile/sbtouch_outbox";
constexpr int kPollMs = 10;
constexpr int kDefaultTimeoutMs = 5000;

bool write_atomic(const std::string& path, const std::string& body) {
    const std::string tmp = path + ".tmp";
    const int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;
    size_t sent = 0;
    while (sent < body.size()) {
        const ssize_t n = ::write(fd, body.data() + sent, body.size() - sent);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            ::close(fd);
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    ::close(fd);
    return ::rename(tmp.c_str(), path.c_str()) == 0;
}

// Returns true when the file exists (contents may legitimately be empty).
bool read_whole(const std::string& path, std::string& out) {
    const int fd = ::open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    char buf[2048];
    out.clear();
    for (;;) {
        const ssize_t n = ::read(fd, buf, sizeof buf);
        if (n > 0) {
            out.append(buf, static_cast<size_t>(n));
            if (out.size() > 64 * 1024) break;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    ::close(fd);
    return true;
}

void sleep_ms(int ms) {
    struct timespec ts{ms / 1000, (static_cast<long>(ms) % 1000) * 1000000L};
    ::nanosleep(&ts, nullptr);
}

std::string generate_id() {
    struct timeval tv {};
    ::gettimeofday(&tv, nullptr);
    char buf[64];
    std::snprintf(buf, sizeof buf, "c%d-%ld%06ld", static_cast<int>(::getpid()),
                  static_cast<long>(tv.tv_sec), static_cast<long>(tv.tv_usec));
    return buf;
}

}  // namespace

int main(int argc, char** argv) {
    int timeout_ms = kDefaultTimeoutMs;
    std::string request;
    if (argc > 1) {
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (arg == "--timeout-ms" && i + 1 < argc) {
                timeout_ms = std::atoi(argv[++i]);
                continue;
            }
            if (!request.empty()) request.push_back(' ');
            request += arg;
        }
    } else {
        char buf[4096];
        size_t total = 0;
        while (total < 64 * 1024) {
            const ssize_t n = ::read(STDIN_FILENO, buf, sizeof buf);
            if (n > 0) {
                request.append(buf, static_cast<size_t>(n));
                total += static_cast<size_t>(n);
                continue;
            }
            if (n < 0 && errno == EINTR) continue;
            break;
        }
    }
    while (!request.empty() &&
           (request.back() == '\n' || request.back() == '\r' || request.back() == ' ')) {
        request.pop_back();
    }
    if (request.empty()) {
        std::fprintf(stderr, "usage: sbtctl '<json request>' [--timeout-ms N]\n");
        return 5;
    }

    autiva::json::Value parsed;
    std::string err;
    if (!autiva::json::parse(request, parsed, err)) {
        std::fprintf(stderr, "sbtctl: %s\n", err.c_str());
        return 5;
    }
    if (!parsed.is_object()) {
        std::fprintf(stderr, "sbtctl: request must be a JSON object\n");
        return 5;
    }

    // Correlation id: honour the caller's, otherwise inject one so the reply
    // can always be attributed (a mailbox entry with no id is unfalsifiable).
    std::string id;
    if (!autiva::json::get_string(parsed, "id", id) || id.empty()) {
        id = generate_id();
        const std::size_t brace = request.find('{');
        if (brace == std::string::npos) return 5;
        request.insert(brace + 1, "\"id\":\"" + id + "\",");
    }

    ::mkdir(kInboxDir, 0755);
    ::mkdir(kOutboxDir, 0755);
    const std::string inbox = std::string(kInboxDir) + "/" + id + ".json";
    const std::string outbox = std::string(kOutboxDir) + "/" + id + ".json";
    ::unlink(outbox.c_str());

    if (!write_atomic(inbox, request)) {
        std::fprintf(stderr, "sbtctl: cannot write %s: %s\n", inbox.c_str(),
                     std::strerror(errno));
        return 3;
    }

    std::string reply;
    for (int waited = 0; waited <= timeout_ms; waited += kPollMs) {
        if (read_whole(outbox, reply) && !reply.empty()) {
            ::unlink(outbox.c_str());
            break;
        }
        sleep_ms(kPollMs);
    }
    if (reply.empty()) {
        // Cancel the request. A tap that fires minutes later, when the caller
        // has long given up, is worse than a timeout: it lands in whatever is
        // on screen at that moment. The caller sees the failure and decides.
        ::unlink(inbox.c_str());
        std::fprintf(stderr, "sbtctl: no reply within %dms (request cancelled)\n",
                     timeout_ms);
        return 3;
    }

    std::printf("%s\n", reply.c_str());

    autiva::json::Value v;
    if (!autiva::json::parse(reply, v, err)) return 5;
    std::string status;
    if (!autiva::json::get_string(v, "status", status)) return 5;
    if (status == "ok") return 0;
    if (status == "busy") return 2;
    return 4;
}
