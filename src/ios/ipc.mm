// Command server: unix socket (new) + command file (legacy, v8-compatible).
//
// Both paths feed the SAME executor behind one mutex, so a command file write
// and a socket request can never interleave. Differences are deliberate:
//   * socket  → one JSON line in, one JSON line out, id echoed, and an
//               immediate `busy` if the executor is taken (the caller gets a
//               fact, not a guess);
//   * file    → exactly v8's semantics (queue, single status file) so the
//               production poster keeps working untouched until the host is
//               flipped over.
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <ctime>
#include <mutex>
#include <string>

#include "ios.hpp"

namespace autiva {
namespace {

// Execution is serialised on one queue, and a semaphore answers the only
// question the watchdog needs: "is something executing right now?" — so a
// probe gets an immediate `busy` instead of queueing behind a 5 s capture.
// (std::mutex cannot be used for that: it must be unlocked by the locking
// thread, and the work runs on another queue.)
dispatch_queue_t g_exec_queue;
dispatch_semaphore_t g_exec_gate;
std::once_flag g_exec_once;
std::mutex g_state_mu;   // guards g_current
std::string g_current;
std::atomic<bool> g_busy{false};

void ensure_executor() {
    std::call_once(g_exec_once, [] {
        g_exec_queue = dispatch_queue_create("com.autiva.sbtouch.exec", DISPATCH_QUEUE_SERIAL);
        g_exec_gate = dispatch_semaphore_create(1);
    });
}

bool try_acquire_executor() {
    ensure_executor();
    return dispatch_semaphore_wait(g_exec_gate, DISPATCH_TIME_NOW) == 0;
}

void release_executor() {
    dispatch_semaphore_signal(g_exec_gate);
}

// ── field helpers ───────────────────────────────────────────────────────────
bool coord(const Command& cmd, const char* kx, const char* ky, int& x, int& y,
           ExecResult& out) {
    long long vx = 0, vy = 0;
    if (!json::get_int(cmd.root, kx, vx) || !json::get_int(cmd.root, ky, vy)) {
        out.error = std::string(kErrMissingField);
        return false;
    }
    if (vx < 0 || vy < 0 || vx > kScreenW || vy > kScreenH) {
        out.error = std::string(kErrOutOfRange);
        return false;
    }
    x = static_cast<int>(vx);
    y = static_cast<int>(vy);
    return true;
}

int bounded_int(const Command& cmd, const char* key, int fallback, int lo, int hi) {
    long long v = 0;
    if (!json::get_int(cmd.root, key, v)) return fallback;
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return static_cast<int>(v);
}

// ── router ──────────────────────────────────────────────────────────────────
void run_action(const Command& cmd, ExecResult& result) {
    if (cmd.action == "ping") {
        result.status = Status::Ok;
        return;
    }
    if (cmd.action == "version") {
        result.status = Status::Ok;
        result.result_json = version_json();
        return;
    }
    if (cmd.action == "state") {
        bool busy = g_busy.load();
        std::string action;
        {
            std::lock_guard<std::mutex> lk(g_state_mu);
            action = g_current;
        }
        result.status = Status::Ok;
        result.result_json = std::string("{\"busy\":") + (busy ? "true" : "false") +
                             ",\"action\":\"" + json::escape(action) + "\"}";
        return;
    }
    if (cmd.action == "tap") {
        int x = 0, y = 0;
        if (!coord(cmd, "x", "y", x, y, result)) return;
        // 0 (field absent) => sample a human hold inside hid_tap.
        const int hold = bounded_int(cmd, "hold_ms", 0, 20, 2000);
        result.delivered = hid_tap(x, y, hold);
        result.status = result.delivered ? Status::Ok : Status::Error;
        if (!result.delivered) result.error = std::string(kErrInternal);
        return;
    }
    if (cmd.action == "long_press") {
        int x = 0, y = 0;
        if (!coord(cmd, "x", "y", x, y, result)) return;
        const int dur = bounded_int(cmd, "duration_ms", 900, 50, 60000);
        result.delivered = hid_long_press(x, y, dur);
        result.status = result.delivered ? Status::Ok : Status::Error;
        if (!result.delivered) result.error = std::string(kErrInternal);
        return;
    }
    if (cmd.action == "swipe") {
        int x1 = 0, y1 = 0, x2 = 0, y2 = 0;
        ExecResult probe{};
        if (!coord(cmd, "x1", "y1", x1, y1, probe)) {
            result.error = probe.error;
            return;
        }
        if (!coord(cmd, "x2", "y2", x2, y2, probe)) {
            result.error = probe.error;
            return;
        }
        const int dur = bounded_int(cmd, "duration_ms", 300, 20, 10000);
        result.delivered = hid_swipe(x1, y1, x2, y2, dur);
        result.status = result.delivered ? Status::Ok : Status::Error;
        if (!result.delivered) result.error = std::string(kErrInternal);
        return;
    }
    if (cmd.action == "screenshot") {
        std::string out_path;
        if (!json::get_string(cmd.root, "out_path", out_path) || out_path.empty()) {
            result.error = std::string(kErrMissingField);
            return;
        }
        double scale = 1.0;
        json::get_double(cmd.root, "scale", scale);  // JSON numbers are doubles here
        if (scale <= 0.0) scale = 1.0;
        if (scale < 0.1) scale = 0.1;
        if (scale > 1.0) scale = 1.0;
        std::string err;
        if (!capture_png(out_path, scale, err)) {
            result.error = err.empty() ? std::string(kErrCapture) : err;
            return;
        }
        result.status = Status::Ok;
        return;
    }
    if (cmd.action == "clipboard_get") {
        std::string text;
        std::string err;
        if (!clipboard_get(text, err)) {
            result.error = err.empty() ? std::string(kErrInternal) : err;
            return;
        }
        result.status = Status::Ok;
        result.result_json = std::string("{\"text\":\"") + json::escape(text) + "\"}";
        return;
    }
    if (cmd.action == "clipboard") {
        // v8 answered `success` here and the caption never landed: UIPasteboard
        // writes from backboardd do not reach the app-facing general pasteboard
        // (production proves it — the caption path is pbset +
        // /var/mobile/clipboard_text.txt + ClipboardHelper inside Instagram).
        // Answer with a fact instead of a comfortable lie.
        std::string text;
        if (!json::get_string(cmd.root, "text", text)) {
            result.error = std::string(kErrMissingField);
            return;
        }
        std::string err;
        clipboard_set(text, err);  // best effort, still not authoritative
        result.error = "clipboard_write_unsupported_use_pbset";
        return;
    }
    if (cmd.action == "plan") {
        Plan plan;
        std::string parse_err;
        if (!parse_plan(cmd.root, plan, parse_err)) {
            result.error = parse_err;
            return;
        }
        std::string plan_json;
        std::string exec_err;
        result.delivered = execute_plan(plan, plan_json, exec_err);
        result.result_json = plan_json;
        result.status = result.delivered ? Status::Ok : Status::Error;
        if (!result.delivered) result.error = exec_err.empty() ? std::string(kErrInternal) : exec_err;
        return;
    }
    if (cmd.action == "record_start" || cmd.action == "record_arm") {
        std::string label, take_id;
        if (!json::get_string(cmd.root, "label", label)) {
            result.error = std::string(kErrMissingField) + ":label";
            return;
        }
        if (!json::get_string(cmd.root, "take_id", take_id) || take_id.empty()) {
            result.error = std::string(kErrMissingField) + ":take_id";
            return;
        }
        long long max_ms = 20000;
        json::get_int(cmd.root, "max_ms", max_ms);
        if (max_ms < 500 || max_ms > 600000) {
            result.error = std::string(kErrOutOfRange) + ":max_ms";
            return;
        }
        std::string rec_err;
        const bool armed = cmd.action == "record_arm";
        const bool started = armed ? record_arm(label, take_id, static_cast<std::uint64_t>(max_ms), rec_err)
                                   : record_start(label, take_id, static_cast<std::uint64_t>(max_ms), rec_err);
        if (!started) {
            result.error = rec_err.empty() ? std::string(kErrInternal) : rec_err;
            return;
        }
        result.status = Status::Ok;
        result.result_json = record_status();
        return;
    }
    if (cmd.action == "record_stop") {
        result.status = Status::Ok;
        result.result_json = record_stop();
        return;
    }
    if (cmd.action == "record_status") {
        result.status = Status::Ok;
        result.result_json = record_status();
        return;
    }
    result.error = std::string(kErrUnknownAction);
}

ExecResult execute(const Command& cmd, bool legacy) {
    ExecResult result{};
    const uint64_t started = mono_ms();
    {
        std::lock_guard<std::mutex> lk(g_state_mu);
        g_current = cmd.action;
    }
    g_busy.store(true);
    run_action(cmd, result);
    g_busy.store(false);
    {
        std::lock_guard<std::mutex> lk(g_state_mu);
        g_current.clear();
    }
    const uint64_t elapsed = mono_ms() - started;
    log_line("cmd " + cmd.action + (cmd.id.empty() ? "" : " id=" + cmd.id) +
             " status=" + status_name(result.status) + " " + std::to_string(elapsed) +
             "ms" + (legacy ? " (legacy)" : ""));
    return result;
}

// ── mailbox transport (the only one this process is allowed) ────────────────
//
// Measured on this device (2026-11-11): backboardd's sandbox refuses a unix
// socket node (bind -> EPERM on every candidate path) and refuses to register a
// Mach service name (CFMessagePortCreateLocal -> NULL). What it *does* allow is
// exactly what production has always used: creating and unlinking files under
// /var/mobile. So the command server is a file mailbox with per-request
// correlation:
//
//   host  -> /var/mobile/sbtouch_inbox/<id>.json    (written tmp + rename)
//   dylib -> /var/mobile/sbtouch_outbox/<id>.json   (written tmp + rename)
//
// This keeps every property the socket was for — one reply per request, no
// "last writer wins", an exact `busy` — without needing a capability this
// process does not have.
constexpr const char* kInboxDir = "/var/mobile/sbtouch_inbox";
constexpr const char* kOutboxDir = "/var/mobile/sbtouch_outbox";

bool write_file_atomic(const std::string& path, const std::string& body) {
    const std::string tmp = path + ".tmp";
    const int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;
    size_t sent = 0;
    while (sent < body.size()) {
        const ssize_t n = write(fd, body.data() + sent, body.size() - sent);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            close(fd);
            unlink(tmp.c_str());
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    close(fd);
    if (rename(tmp.c_str(), path.c_str()) != 0) {
        unlink(tmp.c_str());
        return false;
    }
    return true;
}

std::string read_file(const std::string& path, bool& ok) {
    ok = false;
    const int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return {};
    std::string out;
    char buf[1024];
    for (;;) {
        const ssize_t n = read(fd, buf, sizeof buf);
        if (n > 0) {
            out.append(buf, static_cast<size_t>(n));
            if (out.size() > 64 * 1024) break;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        break;
    }
    close(fd);
    ok = true;
    return out;
}

bool execute_plan_impl(const Plan& plan, std::string& result_json, std::string& err) {
    const uint64_t start = mono_ms();
    const uint64_t deadline = start + static_cast<uint64_t>(plan.budget_ms);
    uint64_t next_wake = start + 4000;
    int done = 0;
    int failed_at = -1;
    for (std::size_t i = 0; i < plan.steps.size(); ++i) {
        if (mono_ms() >= deadline) {
            err = "budget_exhausted";
            failed_at = static_cast<int>(i);
            break;
        }
        // Synthetic touches do not reset the display idle timer inside
        // backboardd (no BKUserEventTimer there), so nudge the display on a
        // timer instead of relying on a private API we do not have.
        if (mono_ms() >= next_wake) {
            const int fd = open(kWakeTriggerPath, O_WRONLY | O_CREAT, 0644);
            if (fd >= 0) close(fd);
            next_wake = mono_ms() + 4000;
        }
        const PlanStep& step = plan.steps[i];
        bool ok = true;
        switch (step.op) {
            case StepOp::Tap:
                ok = hid_tap(step.x, step.y, step.duration_ms);
                break;
            case StepOp::LongPress:
                ok = hid_long_press(step.x, step.y, step.duration_ms);
                break;
            case StepOp::Swipe:
                ok = hid_swipe(step.x, step.y, step.x2, step.y2, step.duration_ms);
                break;
            case StepOp::Wait:
                sleep_ms(step.duration_ms);
                break;
        }
        if (!ok) {
            err = "step_failed";
            failed_at = static_cast<int>(i);
            break;
        }
        ++done;
    }
    result_json = std::string("{\"steps\":") + std::to_string(plan.steps.size()) +
                  ",\"done\":" + std::to_string(done) + ",\"failed_at\":" +
                  (failed_at < 0 ? "null" : std::to_string(failed_at)) +
                  ",\"budget_ms\":" + std::to_string(plan.budget_ms) + "}";
    return failed_at < 0 && done == static_cast<int>(plan.steps.size());
}

void drain_inbox() {
    DIR* dir = opendir(kInboxDir);
    if (!dir) return;
    std::string name;
    while (dirent* entry = readdir(dir)) {
        const std::string candidate = entry->d_name;
        if (candidate == "." || candidate == "..") continue;
        if (candidate.size() > 5 && candidate.compare(candidate.size() - 5, 5, ".json") != 0) {
            continue;
        }
        name = candidate;
        break;
    }
    closedir(dir);
    if (name.empty()) return;

    const std::string path = std::string(kInboxDir) + "/" + name;
    bool ok = false;
    const std::string body = read_file(path, ok);
    unlink(path.c_str());
    if (!ok) return;

    std::string reply;
    Command cmd;
    std::string code;
    if (!parse_command(body, /*require_id=*/true, cmd, code)) {
        reply = make_reply("", Status::Error, 0, false, code);
        const std::string out = std::string(kOutboxDir) + "/" +
                                (name.empty() ? "unknown.json" : name);
        write_file_atomic(out, reply);
        return;
    }
    if (!try_acquire_executor()) {
        write_file_atomic(std::string(kOutboxDir) + "/" + name,
                          make_reply(cmd.id, Status::Busy, 0, false, {}));
        return;
    }
    const std::string out_path = std::string(kOutboxDir) + "/" + name;
    dispatch_async(g_exec_queue, ^{
        const uint64_t started = mono_ms();
        const ExecResult result = execute(cmd, /*legacy=*/false);
        const int elapsed = static_cast<int>(mono_ms() - started);
        write_file_atomic(out_path, make_reply(cmd.id, result.status, elapsed,
                                               result.delivered, result.error,
                                               result.result_json));
        release_executor();
    });
}

void start_mailbox() {
    mkdir(kInboxDir, 0755);
    mkdir(kOutboxDir, 0755);
    static dispatch_queue_t q;
    q = dispatch_queue_create("com.autiva.sbtouch.mailbox", DISPATCH_QUEUE_SERIAL);
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                              50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        for (int i = 0; i < 8; ++i) {
            drain_inbox();  // bounded burst; never spin
        }
    });
    dispatch_resume(timer);
    log_line("mailbox: serving pairs under /var/mobile/sbtouch_{inbox,outbox}/");
}

// ── legacy command file (unchanged semantics) ────────────────────────────────
void write_legacy(Status status, const std::string& error) {
    const std::string body =
        make_legacy_reply(status, error, static_cast<long long>(time(nullptr)));
    NSString* text = [NSString stringWithUTF8String:body.c_str()];
    [text writeToFile:[NSString stringWithUTF8String:kStatusPath]
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
}

void poll_command_file() {
    struct stat st {};
    if (stat(kCmdPath, &st) != 0) return;

    NSString* path = [NSString stringWithUTF8String:kCmdPath];
    NSString* body = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    unlink(kCmdPath);
    if (!body) {
        write_legacy(Status::Error, std::string(kErrBadJson));
        return;
    }

    Command cmd;
    std::string code;
    const std::string line(body.UTF8String ? body.UTF8String : "");
    if (!parse_command(line, /*require_id=*/false, cmd, code)) {
        write_legacy(Status::Error, code);
        return;
    }
    cmd.legacy = true;

    // v8 semantics: the poster is serial and waits, so queue (never `busy`).
    ensure_executor();
    dispatch_sync(g_exec_queue, ^{
        const ExecResult result = execute(cmd, /*legacy=*/true);
        write_legacy(result.status, result.error);
    });
}

void start_file_poller() {
    static dispatch_queue_t poll_q;
    poll_q = dispatch_queue_create("com.autiva.sbtouch.legacy", DISPATCH_QUEUE_SERIAL);
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, poll_q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                              50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        poll_command_file();
    });
    dispatch_resume(timer);
    log_line("legacy: polling /var/mobile/touch_cmd.json every 50ms");
}

}  // namespace


void ipc_start() {
    start_mailbox();
    start_file_poller();
}

bool execute_plan(const Plan& plan, std::string& result_json, std::string& err) {
    return execute_plan_impl(plan, result_json, err);
}

bool executor_busy() { return g_busy.load(); }

std::string current_action() {
    std::lock_guard<std::mutex> lk(g_state_mu);
    return g_current;
}

}  // namespace autiva
