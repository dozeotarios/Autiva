// Gesture plans: many steps executed from one request.
//
// Why this exists: the host drives the phone over SSH, so one command per step
// costs a round trip (~120 ms + poll) and the *gaps between* steps become
// network latency instead of human timing. A plan is pushed once and executed
// on the device against absolute deadlines, which is both faster and more
// realistic. It also removes the entire class of "the host died mid-session and
// left the phone halfway through".
//
// Everything here is portable and host-tested; the platform layer only supplies
// the primitives (tap/swipe/long_press) and the clock.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "json.hpp"

namespace autiva {

enum class StepOp : unsigned char { Tap, LongPress, Swipe, Wait };

struct PlanStep {
    StepOp op = StepOp::Wait;
    int x = 0;
    int y = 0;
    int x2 = 0;
    int y2 = 0;
    int duration_ms = 0;  // hold / swipe duration / wait
};

struct Plan {
    std::vector<PlanStep> steps;
    // Absolute wall-clock budget for the whole plan (safety: a plan must never
    // hold the executor forever).
    int budget_ms = 0;
};

// Parse and validate a `plan` request. Validation is total: every coordinate,
// duration and count is checked BEFORE anything executes, so a malformed plan
// can never leave the phone half-driven.
bool parse_plan(const json::Value& request, Plan& out, std::string& err);

}  // namespace autiva
