// Wire protocol for the SBTouch command server.
//
// One JSON object per line in, one JSON object per line out — over a unix
// socket (`/var/mobile/sbtouch.sock`) and, unchanged, over the legacy command
// file (`/var/mobile/touch_cmd.json`) that production still uses.
//
// Every socket request carries an id and every reply echoes it. That is the
// whole point: the previous protocol had a single `touch_status.json` and
// "last writer wins", so a status written by one command could be read as the
// answer to another, and `success` only meant "queued on the main queue".
#pragma once

#include <string>
#include <string_view>

#include "json.hpp"

namespace autiva {

enum class Status : unsigned char { Ok, Busy, Error };

const char* status_name(Status status);

// Stable machine-readable error codes. The host maps these; do not reword.
inline constexpr std::string_view kErrBadJson = "bad_json";
inline constexpr std::string_view kErrBadId = "bad_id";
inline constexpr std::string_view kErrMissingAction = "missing_action";
inline constexpr std::string_view kErrUnknownAction = "unknown_action";
inline constexpr std::string_view kErrMissingField = "missing_field";
inline constexpr std::string_view kErrBadField = "bad_field";
inline constexpr std::string_view kErrOutOfRange = "out_of_range";
inline constexpr std::string_view kErrCapture = "capture_failed";
inline constexpr std::string_view kErrInternal = "internal";

struct Command {
    std::string id;      // sanitised; empty only for the legacy file protocol
    std::string action;  // "tap", "swipe", "long_press", "screenshot", ...
    json::Value root;    // full request, for action-specific reads
    bool legacy = false; // came from the command file, not the socket
};

// Parse one request line. `out_of` receives a stable error code on failure.
// `require_id` is true for socket requests (correlation is mandatory there)
// and false for the legacy file protocol (v8 compatibility).
bool parse_command(std::string_view line, bool require_id, Command& cmd,
                   std::string& out_of_error_code);

// Keep ids to a boring alphabet so a reply can never be built from something
// that breaks JSON or log parsing. Returns false if the id is unusable.
bool sanitize_id(std::string_view raw, std::string& out);

// Build a reply line (no trailing newline). `result_json` is an already
// serialised JSON object fragment ("" for none).
std::string make_reply(const std::string& id, Status status, int elapsed_ms,
                       bool delivered, std::string_view error_code,
                       std::string_view result_json = {});

// Legacy reply shape for the command file: {"status":"success"|"fail",...}.
// v8 compatibility — the current host client reads exactly this.
std::string make_legacy_reply(Status status, std::string_view error_code,
                              int elapsed_ms);

}  // namespace autiva
