// Shared surface of the iOS side. Everything Apple-specific lives behind these
// declarations so the portable core stays testable on a Linux host.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

#include "plan.hpp"
#include "protocol.hpp"

namespace autiva {

// ── paths / geometry ────────────────────────────────────────────────────────
inline constexpr const char* kCmdPath = "/var/mobile/touch_cmd.json";
inline constexpr const char* kStatusPath = "/var/mobile/touch_status.json";
inline constexpr const char* kSocketPath = "/var/mobile/sbtouch.sock";
inline constexpr const char* kLogPath = "/var/mobile/touch_injector.log";
inline constexpr const char* kLoadedMarker = "/var/mobile/touch_injector_loaded.txt";
inline constexpr const char* kRecordDir = "/var/mobile/sbtouch_record";
// WiFiKeepAlive watches this path; touching it brings the display back.
inline constexpr const char* kWakeTriggerPath = "/var/mobile/wake_trigger";

inline constexpr int kScreenW = 1125;  // iPhone X native pixels
inline constexpr int kScreenH = 2436;

// Magic sender id from XXTouchNG: lets us tell our own synthetic touches apart
// from real ones when the monitor is running.
inline constexpr std::uint64_t kSyntheticSenderId = 0x8000000817319372ULL;

// ── logging ─────────────────────────────────────────────────────────────────
void log_init();
void log_line(const std::string& msg);
void log_rotate_if_needed();

// ── time ────────────────────────────────────────────────────────────────────
// Monotonic milliseconds. Never wall clock: NTP/Wi-Fi corrections must not be
// able to reorder a swipe.
std::uint64_t mono_ms();
// Absolute deadline helper for the scheduler (v10).
void sleep_until_ms(std::uint64_t deadline);
void sleep_ms(int ms);

// ── HID synthesis ───────────────────────────────────────────────────────────
// Each returns true when the event was actually dispatched on the main queue
// (i.e. "delivered", not merely "queued").
bool hid_tap(int x, int y, int hold_ms);
bool hid_long_press(int x, int y, int duration_ms);
bool hid_swipe(int x1, int y1, int x2, int y2, int duration_ms);

// ── capture ─────────────────────────────────────────────────────────────────
// Writes a PNG on the device. Runs on the caller's thread (never the main
// queue) and reuses cached Metal objects across calls.
bool capture_png(const std::string& out_path, double scale, std::string& err);
// Same capture with an explicit retry budget (0 for boundary frames: a take
// must not be delayed by four display-wake attempts).
bool capture_png_n(const std::string& out_path, double scale, int retries,
                   std::string& err);

// ── clipboard ───────────────────────────────────────────────────────────────
bool clipboard_set(const std::string& text, std::string& err);
bool clipboard_get(std::string& out, std::string& err);

// True when BKUserEventTimer resolved (synthetic touches then reset the idle timer).
bool hid_idle_timer_available();

// ── router / ipc ────────────────────────────────────────────────────────────
struct ExecResult {
    Status status = Status::Error;
    std::string error;
    std::string result_json;
    bool delivered = false;
};

ExecResult execute_command(const Command& cmd);

// Executes a validated plan; fills a result fragment and returns all-delivered.
bool execute_plan(const Plan& plan, std::string& result_json, std::string& err);

// Starts the unix-socket server and the legacy file poller.
void ipc_start();

// Current executor state, for the `state` action and the `busy` reply.
std::string current_action();
bool executor_busy();

// ── recorder (v12) ──────────────────────────────────────────────────────────
bool record_start(const std::string& label, const std::string& take_id,
                  std::uint64_t max_ms, std::string& err);
bool record_arm(const std::string& label, const std::string& take_id,
                std::uint64_t max_ms, std::string& err);
std::string record_stop();
std::string record_status();
bool monitor_available();
// Starts the monitor and reports whether digitizer events actually arrive.
bool monitor_probe(std::string& result_json, std::string& err);

// Build identity for the `version` action.
std::string version_json();

}  // namespace autiva
