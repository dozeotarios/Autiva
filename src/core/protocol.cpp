#include "protocol.hpp"

#include <cstdio>

namespace autiva {
namespace {

std::string number(int v) {
    char buf[24];
    std::snprintf(buf, sizeof buf, "%d", v);
    return buf;
}

}  // namespace

const char* status_name(Status status) {
    switch (status) {
        case Status::Ok: return "ok";
        case Status::Busy: return "busy";
        case Status::Error: return "error";
    }
    return "error";
}

bool sanitize_id(std::string_view raw, std::string& out) {
    if (raw.empty() || raw.size() > 64) return false;
    out.clear();
    out.reserve(raw.size());
    for (const char c : raw) {
        const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9') || c == '-' || c == '_' ||
                        c == '.' || c == ':';
        if (!ok) return false;
        out.push_back(c);
    }
    return true;
}

bool parse_command(std::string_view line, bool require_id, Command& cmd,
                   std::string& out_of_error_code) {
    cmd = Command{};
    std::string err;
    if (!json::parse(line, cmd.root, err)) {
        out_of_error_code = std::string(kErrBadJson);
        return false;
    }
    if (!cmd.root.is_object()) {
        out_of_error_code = std::string(kErrBadJson);
        return false;
    }

    std::string raw_id;
    const bool has_id = json::get_string(cmd.root, "id", raw_id);
    if (has_id) {
        if (!sanitize_id(raw_id, cmd.id)) {
            out_of_error_code = std::string(kErrBadId);
            return false;
        }
    } else if (require_id) {
        out_of_error_code = std::string(kErrBadId);
        return false;
    }

    if (!json::get_string(cmd.root, "action", cmd.action) || cmd.action.empty()) {
        out_of_error_code = std::string(kErrMissingAction);
        return false;
    }
    if (cmd.action.size() > 32) {
        out_of_error_code = std::string(kErrBadField);
        return false;
    }
    return true;
}

std::string make_reply(const std::string& id, Status status, int elapsed_ms,
                       bool delivered, std::string_view error_code,
                       std::string_view result_json) {
    std::string out = "{\"id\":\"";
    out += json::escape(id);
    out += "\",\"status\":\"";
    out += status_name(status);
    out += "\",\"ms\":";
    out += number(elapsed_ms < 0 ? 0 : elapsed_ms);
    out += ",\"delivered\":";
    out += delivered ? "true" : "false";
    if (status == Status::Error && !error_code.empty()) {
        out += ",\"error\":\"";
        out += json::escape(error_code);
        out += '"';
    }
    if (!result_json.empty()) {
        out += ",\"result\":";
        out += std::string(result_json);
    }
    out += '}';
    return out;
}

std::string make_legacy_reply(Status status, std::string_view error_code,
                              int elapsed_ms) {
    std::string out = "{\"status\":\"";
    out += status == Status::Ok ? "success" : "fail";
    out += "\",\"ts\":";
    out += number(elapsed_ms >= 0 ? elapsed_ms : 0);
    if (status == Status::Error && !error_code.empty()) {
        out += ",\"error\":\"";
        out += json::escape(error_code);
        out += '"';
    }
    out += '}';
    return out;
}

}  // namespace autiva
