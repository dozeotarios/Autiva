// Logging + time base.
//
// The log is append-only with a bounded size. The previous build flushed on
// every write and never rotated; on a device with ~14 MB of free pages that is
// both disk churn and a stall inside a system daemon. Rotation happens once at
// init, never on the write path.
#include <cstdio>
#include <ctime>
#include <sys/stat.h>
#include <unistd.h>

#include "ios.hpp"

namespace autiva {
namespace {

FILE* g_log = nullptr;

constexpr long kRotateAt = 5L * 1024 * 1024;
constexpr int kKeepFiles = 3;

void rotate_once() {
    struct stat st {};
    if (stat(kLogPath, &st) != 0 || st.st_size < kRotateAt) return;
    char from[128];
    char to[128];
    for (int n = kKeepFiles - 1; n >= 1; --n) {
        std::snprintf(from, sizeof from, "%s.%d", kLogPath, n);
        std::snprintf(to, sizeof to, "%s.%d", kLogPath, n + 1);
        rename(from, to);  // missing source is fine
    }
    std::snprintf(to, sizeof to, "%s.1", kLogPath);
    rename(kLogPath, to);
}

}  // namespace

void log_init() {
    rotate_once();
    g_log = std::fopen(kLogPath, "a");
}

void log_line(const std::string& msg) {
    // Wall clock is fine for a human-facing log line; timestamps inside the
    // command path always use mono_ms().
    char stamp[32];
    const std::time_t now = std::time(nullptr);
    std::tm tm {};
    gmtime_r(&now, &tm);
    std::strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", &tm);
    char line[2048];
    const int n = std::snprintf(line, sizeof line, "[%s] %s\n", stamp, msg.c_str());
    if (n <= 0) return;
    if (g_log) {
        std::fwrite(line, 1, static_cast<size_t>(n), g_log);
        std::fflush(g_log);
    }
}

std::uint64_t mono_ms() {
    return static_cast<std::uint64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1000000ULL;
}

void sleep_ms(int ms) {
    if (ms <= 0) return;
    usleep(static_cast<useconds_t>(ms) * 1000);
}

void sleep_until_ms(std::uint64_t deadline) {
    const std::uint64_t now = mono_ms();
    if (deadline <= now) return;
    const std::uint64_t delta = deadline - now;
    // Sub-millisecond remainder: sleep the whole part, spin the rest.
    const std::uint64_t whole = delta > 1 ? delta - 1 : 0;
    if (whole) usleep(static_cast<useconds_t>(whole) * 1000);
    while (mono_ms() < deadline) {
        // Bounded spin (< 1 ms) — precise and cheap.
    }
}

}  // namespace autiva
