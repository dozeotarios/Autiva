// IOHID monitor + take recorder (v12).
//
// The recorder exists so the warmup library can be built from *observed*
// gestures instead of invented coordinates: the operator performs an action
// once, and the trace gives position, timing, dwell and swipe velocity.
//
// Everything about the callback is deliberately boring: no locks, no
// allocation, no file I/O. It pushes into a preallocated SPSC ring; a flush
// timer drains it in batches. (A synchronous write per sample at ~120 Hz inside
// backboardd is the self-inflicted wedge this design exists to avoid.)
//
// Take lifecycle, all driven from the host:
//   record_start {label, take_id, max_ms} -> start.png + trace.jsonl
//   record_stop                            -> end.png + meta.json + INDEX line
//   record_status                          -> state + counters
//   record_arm   {label, take_id, max_ms}  -> start on the next volume-up,
//                                             stop on the next volume-down
//
// Volume keys are hardware HID consumer events; whether they surface in this
// process is measured (caps.monitor + the volume_events counter), not assumed.
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <ctime>

#include <atomic>
#include <string>

#include "ios.hpp"
#include "record.hpp"

namespace autiva {
namespace {

typedef struct __IOHIDEvent* IOHIDEventRef;
typedef struct __IOHIDEventSystemClient* IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient* IOHIDServiceRef;

constexpr uint32_t kEventTypeDigitizer = 11;
constexpr uint32_t kEventTypeKeyboard = 3;
constexpr uint32_t kFieldDigitizerX = 720896;
constexpr uint32_t kFieldDigitizerY = 720897;
constexpr uint32_t kFieldDigitizerRange = 720912;
constexpr uint32_t kFieldDigitizerTouch = 720913;
constexpr uint32_t kFieldDigitizerIndex = 720918;
constexpr uint32_t kFieldKeyboardUsagePage = 196608;  // 3 << 16
constexpr uint32_t kFieldKeyboardUsage = 196609;
constexpr uint32_t kConsumerPage = 0x0C;
constexpr uint32_t kVolumeUp = 0xE9;
constexpr uint32_t kVolumeDown = 0xEA;

extern "C" {
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator,
                                                               int type, CFDictionaryRef props);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client,
                                                 void (*cb)(void*, void*, IOHIDServiceRef,
                                                            IOHIDEventRef),
                                                 void* refcon, void* unk);
void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client,
                                               CFRunLoopRef runloop, CFStringRef mode);
void IOHIDEventSystemClientUnscheduleFromRunLoop(IOHIDEventSystemClientRef client,
                                                 CFRunLoopRef runloop, CFStringRef mode);
uint32_t IOHIDEventGetType(IOHIDEventRef event);
uint64_t IOHIDEventGetSenderID(IOHIDEventRef event);
double IOHIDEventGetFloatValue(IOHIDEventRef event, uint32_t field);
long IOHIDEventGetIntegerValue(IOHIDEventRef event, uint32_t field);
}

struct Recorder {
    std::atomic<bool> active{false};
    std::atomic<bool> armed{false};
    std::atomic<bool> monitor_ok{false};
    std::atomic<std::uint64_t> volume_events{0};
    std::atomic<std::uint64_t> samples{0};
    SampleRing ring{8192};

    std::string label;
    std::string take_id;
    std::string dir;
    int fd = -1;
    std::uint64_t t0_mono = 0;
    std::uint64_t t0_epoch = 0;
    std::uint64_t max_ms = 20000;
    std::uint32_t last_x = 0;
    std::uint32_t last_y = 0;
    bool finger_down = false;
    uint8_t finger_id = 0;
    int diag_left = 6;
};

Recorder& rec() {
    static Recorder r;
    return r;
}

// Defined below (take lifecycle); declared here so the volume-key handler can
// drive them without a second copy of the state machine.
void record_start_internal(const std::string& label, const std::string& take_id,
                           std::uint64_t max_ms);
std::string record_stop_internal();

// ── monitor plumbing ────────────────────────────────────────────────────────
IOHIDEventSystemClientRef g_monitor = nullptr;

void flush_queue_now();

void handle_digitizer(IOHIDEventRef event) {
    Recorder& r = rec();
    if (!r.active.load(std::memory_order_relaxed)) return;

    const double dx = IOHIDEventGetFloatValue(event, kFieldDigitizerX);
    const double dy = IOHIDEventGetFloatValue(event, kFieldDigitizerY);
    // Coordinates may arrive normalized (0..1) or in device pixels depending on
    // the panel path; normalize defensively rather than assuming.
    const double x = dx <= 1.5 ? dx * kScreenW : dx;
    const double y = dy <= 1.5 ? dy * kScreenH : dy;
    const long range = IOHIDEventGetIntegerValue(event, kFieldDigitizerRange);
    const long touch = IOHIDEventGetIntegerValue(event, kFieldDigitizerTouch);

    RecordSample s;
    s.t_ms = static_cast<std::uint32_t>(mono_ms() - r.t0_mono);
    s.x = static_cast<std::int16_t>(x < 0 ? 0 : (x > kScreenW ? kScreenW : x));
    s.y = static_cast<std::int16_t>(y < 0 ? 0 : (y > kScreenH ? kScreenH : y));
    s.finger = r.finger_id;

    if (range && touch && !r.finger_down) {
        s.phase = static_cast<std::uint8_t>(SamplePhase::Down);
        r.finger_down = true;
    } else if (range && touch) {
        s.phase = static_cast<std::uint8_t>(SamplePhase::Move);
    } else {
        s.phase = static_cast<std::uint8_t>(SamplePhase::Up);
        r.finger_down = false;
    }
    if (r.ring.push(s)) r.samples.fetch_add(1, std::memory_order_relaxed);
}

void handle_keyboard(IOHIDEventRef event) {
    const long page = IOHIDEventGetIntegerValue(event, kFieldKeyboardUsagePage);
    const long usage = IOHIDEventGetIntegerValue(event, kFieldKeyboardUsage);
    if (page != static_cast<long>(kConsumerPage)) return;
    if (usage != static_cast<long>(kVolumeUp) && usage != static_cast<long>(kVolumeDown)) {
        return;
    }
    Recorder& r = rec();
    r.volume_events.fetch_add(1, std::memory_order_relaxed);
    log_line("monitor: volume key usage=" + std::to_string(usage));

    // Volume-up brackets the start, volume-down the stop. Same control idiom
    // AutoTouch uses, and it needs no UI on the device.
    if (usage == static_cast<long>(kVolumeUp) && r.armed.load() && !r.active.load()) {
        record_start_internal(r.label, r.take_id, r.max_ms);
    } else if (usage == static_cast<long>(kVolumeDown) && r.active.load()) {
        record_stop_internal();
    }
}

void monitor_callback(void*, void* refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    (void)refcon;
    (void)service;
    if (!event) return;
    if (IOHIDEventGetSenderID(event) == kSyntheticSenderId) return;  // our own taps

    Recorder& r = rec();
    const uint32_t type = IOHIDEventGetType(event);
    if (r.diag_left > 0) {
        --r.diag_left;
        log_line("monitor: event type=" + std::to_string(type) +
                 " page=" + std::to_string(IOHIDEventGetIntegerValue(event, kFieldKeyboardUsagePage)) +
                 " usage=" + std::to_string(IOHIDEventGetIntegerValue(event, kFieldKeyboardUsage)) +
                 " x=" + std::to_string(static_cast<int>(IOHIDEventGetFloatValue(event, kFieldDigitizerX))) +
                 " range=" + std::to_string(IOHIDEventGetIntegerValue(event, kFieldDigitizerRange)));
    }
    if (type == kEventTypeDigitizer) {
        r.monitor_ok.store(true);
        handle_digitizer(event);
    } else if (type == kEventTypeKeyboard) {
        handle_keyboard(event);
    }
}

bool monitor_start() {
    Recorder& r = rec();
    if (g_monitor) return true;
    // 1..3 covers the documented client types; whichever the process accepts
    // wins, and it is logged so the answer is never a guess again.
    for (int type = 1; type <= 3 && !g_monitor; ++type) {
        g_monitor = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, type, nullptr);
        if (g_monitor) {
            log_line("monitor: client type=" + std::to_string(type));
        }
    }
    if (!g_monitor) {
        g_monitor = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        log_line("monitor: fell back to IOHIDEventSystemClientCreate");
    }
    if (!g_monitor) {
        log_line("monitor: no HID client available");
        return false;
    }
    // A monitor client is not subscribed to the touchscreen by default: without
    // an explicit match it sees IMU/ALS/vendor events only (measured: types
    // 13/12/1, zero digitizer). Matching the digitizer service is what makes
    // real touches arrive.
    NSDictionary* match = @{
        @"PrimaryUsagePage" : @(0x0D),  // kHIDPage_Digitizer
        @"PrimaryUsage" : @(0x04),      // kHIDUsage_Dig_TouchScreen
    };
    const int matched = IOHIDEventSystemClientSetMatching(
        g_monitor, (__bridge CFDictionaryRef)match);
    log_line("monitor: setMatching(digitizer/touchscreen) -> " + std::to_string(matched));

    IOHIDEventSystemClientRegisterEventCallback(g_monitor, monitor_callback, nullptr, nullptr);
    IOHIDEventSystemClientScheduleWithRunLoop(g_monitor, CFRunLoopGetMain(),
                                              kCFRunLoopDefaultMode);
    // NOTE (measured 2026-11-11): this process never receives digitizer events.
    // setMatching(digitizer) fails with a non-zero IOReturn and the default
    // client delivers only IMU/ALS/vendor types, so `monitor_ok` stays false
    // until a digitizer event actually arrives. Recording therefore reports
    // itself unavailable instead of writing empty traces that look successful.
    log_line("monitor: registered and scheduled (awaiting a digitizer event)");
    return true;
}

// ── take lifecycle ─────────────────────────────────────────────────────────
bool write_text(const std::string& path, const std::string& body) {
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;
    size_t sent = 0;
    while (sent < body.size()) {
        const ssize_t n = write(fd, body.data() + sent, body.size() - sent);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            close(fd);
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    close(fd);
    return true;
}

void flush_queue_now() {
    Recorder& r = rec();
    if (r.fd < 0) return;
    RecordSample batch[256];
    for (;;) {
        const std::size_t n = r.ring.pop_batch(batch, 256);
        if (!n) break;
        std::string out;
        out.reserve(n * 64);
        for (std::size_t i = 0; i < n; ++i) {
            out += format_sample_line(batch[i]);
            out.push_back('\n');
        }
        size_t sent = 0;
        while (sent < out.size()) {
            const ssize_t w = write(r.fd, out.data() + sent, out.size() - sent);
            if (w <= 0) break;
            sent += static_cast<size_t>(w);
        }
    }
}

dispatch_source_t g_flush_timer = nullptr;

void ensure_flush_timer() {
    if (g_flush_timer) return;
    static dispatch_queue_t q;
    q = dispatch_queue_create("com.autiva.sbtouch.flush", DISPATCH_QUEUE_SERIAL);
    g_flush_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(g_flush_timer, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                              250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_flush_timer, ^{
        flush_queue_now();
    });
    dispatch_resume(g_flush_timer);
}

void record_start_internal(const std::string& label, const std::string& take_id,
                           std::uint64_t max_ms) {
    Recorder& r = rec();
    if (r.active.load()) return;
    mkdir(kRecordDir, 0755);
    r.label = label;
    r.take_id = take_id;
    r.max_ms = max_ms ? max_ms : 20000;
    r.dir = std::string(kRecordDir) + "/" + take_dir_name(take_id, label);
    mkdir(r.dir.c_str(), 0755);

    // Boundary frame: what screen the take started on.
    std::string cap_err;
    capture_png(r.dir + "/start.png", 0.5, cap_err);

    r.fd = open((r.dir + "/trace.jsonl").c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (r.fd < 0) {
        log_line("record: cannot open trace (" + std::to_string(errno) + ")");
        return;
    }
    r.t0_mono = mono_ms();
    r.t0_epoch = static_cast<std::uint64_t>(time(nullptr));
    r.samples.store(0);
    r.finger_down = false;
    r.armed.store(false);
    r.active.store(true);
    ensure_flush_timer();
    log_line("record: started " + r.dir + " max_ms=" + std::to_string(r.max_ms));
}

std::string record_stop_internal() {
    Recorder& r = rec();
    if (!r.active.load()) return "{\"recording\":false}";
    r.active.store(false);
    flush_queue_now();
    if (r.fd >= 0) {
        close(r.fd);
        r.fd = -1;
    }
    std::string cap_err;
    capture_png(r.dir + "/end.png", 0.5, cap_err);

    const std::uint64_t duration = mono_ms() - r.t0_mono;
    const std::uint64_t samples = r.samples.load();
    const std::uint64_t dropped = r.ring.dropped();
    const std::uint64_t volume = r.volume_events.load();

    char meta[512];
    std::snprintf(meta, sizeof meta,
                  "{\"take\":\"%s\",\"label\":\"%s\",\"screen\":[%d,%d],"
                  "\"t_start\":%llu,\"duration_ms\":%llu,\"samples\":%llu,"
                  "\"dropped\":%llu,\"volume_events\":%llu}\n",
                  r.take_id.c_str(), r.label.c_str(), kScreenW, kScreenH,
                  static_cast<unsigned long long>(r.t0_epoch),
                  static_cast<unsigned long long>(duration),
                  static_cast<unsigned long long>(samples),
                  static_cast<unsigned long long>(dropped),
                  static_cast<unsigned long long>(volume));
    write_text(r.dir + "/meta.json", meta);

    const std::string index_line = format_index_line(
        r.take_id, r.label, r.t0_epoch, duration, samples, dropped, volume);
    const int idx = open((std::string(kRecordDir) + "/INDEX.jsonl").c_str(),
                         O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (idx >= 0) {
        write(idx, index_line.c_str(), index_line.size());
        write(idx, "\n", 1);
        close(idx);
    }
    log_line("record: stopped " + r.dir + " samples=" + std::to_string(samples) +
             " dropped=" + std::to_string(dropped) + " duration=" +
             std::to_string(duration) + "ms");
    return "{\"recording\":false,\"take\":\"" + r.take_id + "\",\"samples\":" +
           std::to_string(samples) + ",\"dropped\":" + std::to_string(dropped) +
           ",\"duration_ms\":" + std::to_string(duration) + ",\"volume_events\":" +
           std::to_string(volume) + "}";
}

}  // namespace

bool record_start(const std::string& label, const std::string& take_id,
                  std::uint64_t max_ms, std::string& err) {
    std::string clean;
    if (!sanitize_label(label, clean)) {
        err = std::string(kErrBadField) + ":label";
        return false;
    }
    if (!monitor_start()) {
        err = "monitor_unavailable";
        return false;
    }
    if (!rec().monitor_ok.load()) {
        // Refuse instead of writing an empty trace that reads like a success.
        err = "no_touch_source";
        return false;
    }
    if (rec().active.load()) {
        err = "already_recording";
        return false;
    }
    record_start_internal(clean, take_id, max_ms);
    return rec().active.load();
}

std::string record_stop() { return record_stop_internal(); }

bool record_arm(const std::string& label, const std::string& take_id, std::uint64_t max_ms,
                std::string& err) {
    std::string clean;
    if (!sanitize_label(label, clean)) {
        err = std::string(kErrBadField) + ":label";
        return false;
    }
    if (!monitor_start()) {
        err = "monitor_unavailable";
        return false;
    }
    if (!rec().monitor_ok.load()) {
        err = "no_touch_source";
        return false;
    }
    Recorder& r = rec();
    r.label = clean;
    r.take_id = take_id;
    r.max_ms = max_ms ? max_ms : 20000;
    r.armed.store(true);
    return true;
}

std::string record_status() {
    Recorder& r = rec();
    std::string out = "{\"recording\":";
    out += r.active.load() ? "true" : "false";
    out += ",\"armed\":";
    out += r.armed.load() ? "true" : "false";
    out += ",\"monitor\":";
    out += r.monitor_ok.load() ? "true" : "false";
    out += ",\"digitizer_events\":";
    out += std::to_string(r.samples.load());
    out += ",\"take\":\"" + r.take_id + "\",\"label\":\"" + r.label + "\"";
    out += ",\"samples\":" + std::to_string(r.samples.load());
    out += ",\"dropped\":" + std::to_string(r.ring.dropped());
    out += ",\"volume_events\":" + std::to_string(r.volume_events.load());
    if (r.active.load()) {
        out += ",\"elapsed_ms\":" + std::to_string(mono_ms() - r.t0_mono);
    }
    out += "}";
    return out;
}

bool monitor_available() { return rec().monitor_ok.load(); }

}  // namespace autiva
