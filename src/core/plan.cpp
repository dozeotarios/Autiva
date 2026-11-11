#include "plan.hpp"

#include "protocol.hpp"  // stable error codes

#include <cmath>

namespace autiva {
namespace {

constexpr int kMaxSteps = 500;
constexpr int kScreenW = 1125;
constexpr int kScreenH = 2436;
constexpr int kMaxBudgetMs = 600000;   // 10 min hard ceiling
constexpr int kDefaultBudgetMs = 120000;

bool coord_ok(long long v, int limit) { return v >= 0 && v <= limit; }

bool read_int(const json::Value& obj, const char* key, long long& out, std::string& err) {
    if (!json::get_int(obj, key, out)) {
        err = std::string("missing_field:") + key;
        return false;
    }
    return true;
}

}  // namespace

bool parse_plan(const json::Value& request, Plan& out, std::string& err) {
    out = Plan{};
    const json::Value* steps = json::find(request, "steps");
    if (!steps || !steps->is_array()) {
        err = std::string(kErrMissingField) + ":steps";
        return false;
    }
    if (steps->array.empty()) {
        err = std::string(kErrBadField) + ":steps_empty";
        return false;
    }
    if (steps->array.size() > static_cast<std::size_t>(kMaxSteps)) {
        err = std::string(kErrOutOfRange) + ":steps";
        return false;
    }

    for (const json::Value& raw : steps->array) {
        if (!raw.is_object()) {
            err = std::string(kErrBadField) + ":step";
            return false;
        }
        std::string op;
        if (!json::get_string(raw, "op", op)) {
            err = std::string(kErrMissingField) + ":op";
            return false;
        }
        PlanStep step;
        long long a = 0, b = 0, c = 0, d = 0, dur = 0;
        if (op == "tap") {
            step.op = StepOp::Tap;
            if (!read_int(raw, "x", a, err) || !read_int(raw, "y", b, err)) return false;
            if (!coord_ok(a, kScreenW) || !coord_ok(b, kScreenH)) {
                err = std::string(kErrOutOfRange) + ":tap";
                return false;
            }
            step.x = static_cast<int>(a);
            step.y = static_cast<int>(b);
            // Optional: 0 means "sample a human hold".
            if (json::get_int(raw, "hold_ms", dur)) {
                if (dur < 20 || dur > 2000) {
                    err = std::string(kErrOutOfRange) + ":hold_ms";
                    return false;
                }
                step.duration_ms = static_cast<int>(dur);
            }
        } else if (op == "long_press") {
            step.op = StepOp::LongPress;
            if (!read_int(raw, "x", a, err) || !read_int(raw, "y", b, err)) return false;
            if (!coord_ok(a, kScreenW) || !coord_ok(b, kScreenH)) {
                err = std::string(kErrOutOfRange) + ":long_press";
                return false;
            }
            step.x = static_cast<int>(a);
            step.y = static_cast<int>(b);
            if (!json::get_int(raw, "duration_ms", dur)) dur = 900;
            if (dur < 50 || dur > 60000) {
                err = std::string(kErrOutOfRange) + ":duration_ms";
                return false;
            }
            step.duration_ms = static_cast<int>(dur);
        } else if (op == "swipe") {
            step.op = StepOp::Swipe;
            if (!read_int(raw, "x1", a, err) || !read_int(raw, "y1", b, err) ||
                !read_int(raw, "x2", c, err) || !read_int(raw, "y2", d, err)) {
                return false;
            }
            if (!coord_ok(a, kScreenW) || !coord_ok(c, kScreenW) ||
                !coord_ok(b, kScreenH) || !coord_ok(d, kScreenH)) {
                err = std::string(kErrOutOfRange) + ":swipe";
                return false;
            }
            step.x = static_cast<int>(a);
            step.y = static_cast<int>(b);
            step.x2 = static_cast<int>(c);
            step.y2 = static_cast<int>(d);
            if (!json::get_int(raw, "duration_ms", dur)) dur = 300;
            if (dur < 20 || dur > 10000) {
                err = std::string(kErrOutOfRange) + ":duration_ms";
                return false;
            }
            step.duration_ms = static_cast<int>(dur);
        } else if (op == "wait") {
            step.op = StepOp::Wait;
            if (!json::get_int(raw, "ms", dur)) {
                err = std::string(kErrMissingField) + ":ms";
                return false;
            }
            if (dur < 0 || dur > 600000) {
                err = std::string(kErrOutOfRange) + ":ms";
                return false;
            }
            step.duration_ms = static_cast<int>(dur);
        } else {
            err = std::string(kErrBadField) + ":op:" + op;
            return false;
        }
        out.steps.push_back(step);
    }

    long long budget = 0;
    if (json::get_int(request, "budget_ms", budget)) {
        out.budget_ms = static_cast<int>(budget);
        if (out.budget_ms < 100 || out.budget_ms > kMaxBudgetMs) {
            err = std::string(kErrOutOfRange) + ":budget_ms";
            return false;
        }
        return true;
    }
    // Default budget: the plan's own durations plus generous slack, capped.
    int total = 0;
    for (const PlanStep& step : out.steps) {
        total += step.op == StepOp::Wait ? step.duration_ms : step.duration_ms + 50;
    }
    out.budget_ms = total + 15000;
    if (out.budget_ms > kDefaultBudgetMs) out.budget_ms = kDefaultBudgetMs;
    return true;
}

}  // namespace autiva
