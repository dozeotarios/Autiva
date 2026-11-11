// Host-side unit tests for the portable core. Runs on Linux with no device,
// no ObjC, no IOKit — that is the point of keeping the core dependency-free:
// protocol regressions are caught here in milliseconds instead of on a phone
// that needs a respring to deploy.
//
// Build/run:  make test
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "json.hpp"
#include "plan.hpp"
#include "record.hpp"
#include "profile.hpp"
#include "protocol.hpp"
#include "rng.hpp"

namespace {

int g_failures = 0;
int g_checks = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        ++g_checks;                                                        \
        if (!(cond)) {                                                     \
            ++g_failures;                                                  \
            std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);    \
        }                                                                  \
    } while (0)

#define CHECK_EQ(a, b)                                                     \
    do {                                                                   \
        ++g_checks;                                                        \
        const auto _a = (a);                                               \
        const auto _b = (b);                                               \
        if (!(_a == _b)) {                                                 \
            ++g_failures;                                                  \
            std::printf("FAIL %s:%d  %s == %s\n", __FILE__, __LINE__, #a,  \
                        #b);                                               \
        }                                                                  \
    } while (0)

using autiva::Command;
using autiva::Status;
using autiva::json::Value;

void test_parse_flat_object() {
    Value v;
    std::string err;
    CHECK(autiva::json::parse(R"({"action":"tap","x":562,"y":962.5,"ok":true,"n":null})", v, err));
    CHECK(v.is_object());
    std::string s;
    CHECK(autiva::json::get_string(v, "action", s));
    CHECK_EQ(s, std::string("tap"));
    long long i = 0;
    CHECK(autiva::json::get_int(v, "x", i));
    CHECK_EQ(i, 562LL);
    double d = 0;
    CHECK(autiva::json::get_double(v, "y", d));
    CHECK(d == 962.5);
    bool b = false;
    CHECK(autiva::json::get_bool(v, "ok", b));
    CHECK(b);
    CHECK(autiva::json::find(v, "n") != nullptr);
    CHECK_EQ(int(autiva::json::find(v, "n")->type), int(autiva::json::Type::Null));
    // Absent key is reported, never invented.
    CHECK(!autiva::json::get_string(v, "nope", s));
    CHECK(!autiva::json::get_int(v, "action", i));
}

void test_parse_nested_and_arrays() {
    Value v;
    std::string err;
    const char* plan = R"({"id":"p1","action":"plan","steps":[{"t":"tap","x":10,"y":20},{"t":"wait","ms":500}]})";
    CHECK(autiva::json::parse(plan, v, err));
    const Value* steps = autiva::json::find(v, "steps");
    CHECK(steps && steps->is_array());
    CHECK_EQ(steps ? steps->array.size() : 0u, 2u);
    if (steps && steps->array.size() == 2) {
        long long x = 0;
        CHECK(autiva::json::get_int(steps->array[0], "x", x));
        CHECK_EQ(x, 10LL);
        CHECK_EQ(steps->array[1].object.size(), 2u);
    }
}

void test_number_formatting() {
    Value v;
    std::string err;
    // Integral doubles must round-trip as integers: a coordinate of 562 must
    // never surface as 562.0000000000001 in a reply.
    CHECK(autiva::json::parse("562", v, err));
    CHECK_EQ(autiva::json::dump(v), std::string("562"));
    CHECK(autiva::json::parse("562.5", v, err));
    CHECK_EQ(autiva::json::dump(v), std::string("562.5"));
    CHECK(autiva::json::parse("-0.25", v, err));
    CHECK_EQ(autiva::json::dump(v), std::string("-0.25"));
    // Non-finite can be parsed but must never be emitted (JSON has no inf).
    CHECK(autiva::json::parse("1e999", v, err));
    CHECK_EQ(autiva::json::dump(v), std::string("null"));
}

void test_string_escapes() {
    Value v;
    std::string err;
    CHECK(autiva::json::parse(R"("a\"b\\c\nd\te")", v, err));
    CHECK_EQ(v.string, std::string("a\"b\\c\nd\te"));
    // BMP escape.
    CHECK(autiva::json::parse(R"("\u00e9")", v, err));
    CHECK_EQ(v.string, std::string("\xc3\xa9"));
    // Surrogate pair (😀 U+1F600).
    CHECK(autiva::json::parse(R"("\ud83d\ude00")", v, err));
    CHECK_EQ(v.string, std::string("\xf0\x9f\x98\x80"));
    // Round-trip through dump.
    Value obj;
    CHECK(autiva::json::parse("{}", obj, err));
    obj.type = autiva::json::Type::Object;
    Value s;
    s.type = autiva::json::Type::String;
    s.string = "line1\nline2 \"quoted\"";
    obj.object.emplace_back("k", s);
    CHECK_EQ(autiva::json::dump(obj), std::string(R"({"k":"line1\nline2 \"quoted\""})"));
}

void test_malformed_input() {
    Value v;
    std::string err;
    const char* bad[] = {
        "",
        "{",
        "{}x",
        R"({"a":})",
        R"({"a":"unterminated})",
        R"({"a":"bad\q"})",
        R"({"a":01})",
        R"({"a":"ctl)" "\x01" R"("})",
        "[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]]",
    };
    for (const char* text : bad) {
        err.clear();
        CHECK(!autiva::json::parse(text, v, err));
        CHECK(!err.empty());
    }
}

void test_id_sanitisation() {
    std::string out;
    CHECK(autiva::sanitize_id("a1-B_c.d:e", out));
    CHECK_EQ(out, std::string("a1-B_c.d:e"));
    CHECK(!autiva::sanitize_id("", out));
    CHECK(!autiva::sanitize_id("has space", out));
    CHECK(!autiva::sanitize_id("quote\"", out));
    CHECK(!autiva::sanitize_id(std::string(65, 'a'), out));
    CHECK(autiva::sanitize_id(std::string(64, 'a'), out));
}

void test_parse_command() {
    Command cmd;
    std::string code;
    CHECK(autiva::parse_command(R"({"id":"r1","action":"tap","x":1,"y":2})", true, cmd, code));
    CHECK_EQ(cmd.id, std::string("r1"));
    CHECK_EQ(cmd.action, std::string("tap"));
    CHECK(!cmd.legacy);

    // Socket requests must carry an id; the legacy file protocol need not.
    code.clear();
    CHECK(!autiva::parse_command(R"({"action":"ping"})", true, cmd, code));
    CHECK_EQ(code, std::string(autiva::kErrBadId));
    code.clear();
    CHECK(autiva::parse_command(R"({"action":"ping"})", false, cmd, code));
    CHECK(cmd.id.empty());

    code.clear();
    CHECK(!autiva::parse_command(R"({"id":"r2"})", true, cmd, code));
    CHECK_EQ(code, std::string(autiva::kErrMissingAction));

    code.clear();
    CHECK(!autiva::parse_command(R"({"id":"bad id","action":"ping"})", true, cmd, code));
    CHECK_EQ(code, std::string(autiva::kErrBadId));

    code.clear();
    CHECK(!autiva::parse_command("{not json", true, cmd, code));
    CHECK_EQ(code, std::string(autiva::kErrBadJson));

    // An unknown action parses fine — routing is what rejects it, so the host
    // gets `unknown_action` (a fact) instead of a parse error (a guess).
    code.clear();
    CHECK(autiva::parse_command(R"({"id":"r3","action":"teleport"})", true, cmd, code));
    CHECK_EQ(cmd.action, std::string("teleport"));
}

void test_reply_shapes() {
    const std::string ok = autiva::make_reply("r1", Status::Ok, 12, true, {}, "");
    CHECK_EQ(ok, std::string(R"({"id":"r1","status":"ok","ms":12,"delivered":true})"));

    const std::string err = autiva::make_reply("r2", Status::Error, 3, false,
                                               autiva::kErrMissingField, "");
    CHECK_EQ(err, std::string(R"({"id":"r2","status":"error","ms":3,"delivered":false,"error":"missing_field"})"));

    const std::string busy = autiva::make_reply("r3", Status::Busy, 0, false, {}, "");
    CHECK_EQ(busy, std::string(R"({"id":"r3","status":"busy","ms":0,"delivered":false})"));

    const std::string with_result =
        autiva::make_reply("r4", Status::Ok, 1, true, {}, R"({"v":[1,2]})");
    CHECK_EQ(with_result, std::string(R"({"id":"r4","status":"ok","ms":1,"delivered":true,"result":{"v":[1,2]}})"));

    // Legacy shape is what touch_client.py already parses on the file protocol.
    CHECK_EQ(autiva::make_legacy_reply(Status::Ok, {}, 7),
             std::string(R"({"status":"success","ts":7})"));
    CHECK_EQ(autiva::make_legacy_reply(Status::Error, autiva::kErrCapture, 0),
             std::string(R"({"status":"fail","ts":0,"error":"capture_failed"})"));

    // A refused-because-stale request must be distinguishable from a dead
    // device: the host logs the difference.
    CHECK_EQ(autiva::make_reply("r5", Status::Error, 0, false, autiva::kErrStaleRequest),
             std::string(R"({"id":"r5","status":"error","ms":0,"delivered":false,"error":"stale_request"})"));
}


void test_rng_determinism_and_bounds() {
    autiva::Rng a(42), b(42);
    for (int i = 0; i < 100; ++i) CHECK_EQ(a.next_u64(), b.next_u64());

    autiva::Rng r(7);
    double min = 1.0, max = 0.0, sum = 0.0, sumsq = 0.0;
    const int n = 20000;
    for (int i = 0; i < n; ++i) {
        const double u = r.unit();
        CHECK(u >= 0.0 && u < 1.0);
        if (u < min) min = u;
        if (u > max) max = u;
        sum += u;
        sumsq += u * u;
    }
    const double mean = sum / n;
    const double var = sumsq / n - mean * mean;
    CHECK(mean > 0.48 && mean < 0.52);
    CHECK(var > 0.075 && var < 0.092);   // uniform variance = 1/12

    for (int i = 0; i < 5000; ++i) {
        const long long v = r.integer(1, 14);
        CHECK(v >= 1 && v <= 14);
        const double u = r.uniform(-3.0, -1.0);
        CHECK(u >= -3.0 && u < -1.0);
    }
    // Seeded log-normal median lands on the requested median.
    autiva::Rng l(99);
    std::vector<double> samples;
    for (int i = 0; i < 5000; ++i) samples.push_back(l.log_normal(85.0, 0.22));
    std::sort(samples.begin(), samples.end());
    const double median = samples[samples.size() / 2];
    CHECK(median > 78.0 && median < 92.0);
}

void test_digitizer_profile() {
    autiva::DigitizerProfile p(1234);
    CHECK(p.finger_id() >= 1 && p.finger_id() <= 14);   // never 0
    CHECK_EQ(p.hand_id(), p.finger_id());
    for (int i = 0; i < 500; ++i) {
        const int hold = p.tap_hold_ms();
        CHECK(hold >= 45 && hold <= 160);
        const double down = p.pressure_down();
        CHECK(down >= 0.30 && down <= 0.45);
        const double mid = p.pressure_hold(0.5);
        CHECK(mid >= 0.20 && mid <= 0.95);
        double major = 0, minor = 0;
        p.radii(major, minor);
        CHECK(major >= 0.0040 && major <= 0.0130);
        CHECK(minor >= 0.0025 && minor <= 0.0100);
        CHECK(minor <= major * 1.5);
        const double twist = p.twist();
        CHECK(twist >= 60.0 && twist <= 120.0);
        const double tremor = p.tremor_px();
        CHECK(tremor >= 0.4 && tremor <= 1.8 && tremor < 10.0);  // below UIKit slop
        const int step = p.swipe_step_ms();
        CHECK(step >= 6 && step <= 8);
        const double curve = p.swipe_curve_px();
        CHECK(curve >= -2.5 && curve <= 2.5);
    }
    // A long press keeps the intent but is not a constant.
    CHECK(p.jittered_hold_ms(900) >= 720 && p.jittered_hold_ms(900) <= 1080);
    // Different seeds must not produce the same session.
    autiva::DigitizerProfile q(4321);
    CHECK(p.finger_id() != q.finger_id() || p.tap_hold_ms() != q.tap_hold_ms());
}


void test_plan_validation() {
    autiva::Plan plan;
    std::string err;
    Value req;
    const char* good = R"({"id":"p","action":"plan","steps":[
        {"op":"tap","x":562,"y":962},
        {"op":"wait","ms":400},
        {"op":"swipe","x1":560,"y1":1800,"x2":560,"y2":900,"duration_ms":320},
        {"op":"long_press","x":100,"y":200,"duration_ms":900}]})";
    CHECK(autiva::json::parse(good, req, err));
    CHECK(autiva::parse_plan(req, plan, err));
    CHECK_EQ(plan.steps.size(), 4u);
    CHECK_EQ(int(plan.steps[0].op), int(autiva::StepOp::Tap));
    CHECK_EQ(plan.steps[0].duration_ms, 0);      // sampled at execution
    CHECK_EQ(int(plan.steps[1].op), int(autiva::StepOp::Wait));
    CHECK_EQ(plan.steps[1].duration_ms, 400);
    CHECK_EQ(plan.steps[2].x2, 560);
    CHECK(plan.budget_ms >= 15000 && plan.budget_ms <= 120000);

    // Every rejection below must happen BEFORE execution, so the phone is
    // never left half-driven by a malformed plan.
    const char* bad[] = {
        R"({"id":"p","action":"plan"})",                                    // no steps
        R"({"id":"p","action":"plan","steps":[]})",                         // empty
        R"({"id":"p","action":"plan","steps":[{"op":"teleport","x":1,"y":2}]})",
        R"({"id":"p","action":"plan","steps":[{"op":"tap","x":-1,"y":2}]})",
        R"({"id":"p","action":"plan","steps":[{"op":"tap","x":5000,"y":2}]})",
        R"({"id":"p","action":"plan","steps":[{"op":"tap","y":2}]})",
        R"({"id":"p","action":"plan","steps":[{"op":"wait"}]})",
        R"({"id":"p","action":"plan","steps":[{"op":"swipe","x1":1,"y1":2,"x2":3,"y2":4,"duration_ms":999999}]})",
        R"({"id":"p","action":"plan","steps":[{"op":"tap","x":1,"y":2}],"budget_ms":5})",
    };
    for (const char* text : bad) {
        Value v;
        std::string e2;
        CHECK(autiva::json::parse(text, v, e2));
        autiva::Plan p2;
        CHECK(!autiva::parse_plan(v, p2, e2));
        CHECK(!e2.empty());
    }
}


void test_sample_ring() {
    autiva::SampleRing ring(4);
    autiva::RecordSample s{};
    for (int i = 0; i < 4; ++i) {
        s.t_ms = static_cast<std::uint32_t>(i);
        CHECK(ring.push(s));
    }
    CHECK_EQ(ring.dropped(), 0ull);
    // A full ring drops instead of blocking the HID thread.
    s.t_ms = 99;
    CHECK(!ring.push(s));
    CHECK_EQ(ring.dropped(), 1ull);

    autiva::RecordSample batch[8];
    CHECK_EQ(ring.pop_batch(batch, 8), 4u);
    CHECK_EQ(batch[0].t_ms, 0u);
    CHECK_EQ(batch[3].t_ms, 3u);

    // Wrap-around: after draining, indices must not alias.
    for (int i = 10; i < 14; ++i) {
        s.t_ms = static_cast<std::uint32_t>(i);
        CHECK(ring.push(s));
    }
    CHECK_EQ(ring.pop_batch(batch, 8), 4u);
    CHECK_EQ(batch[0].t_ms, 10u);
    CHECK_EQ(batch[3].t_ms, 13u);
    CHECK(ring.empty());
}

void test_record_formatting() {
    autiva::RecordSample s{};
    s.t_ms = 12484;
    s.x = 562;
    s.y = 962;
    s.phase = static_cast<std::uint8_t>(autiva::SamplePhase::Down);
    s.finger = 3;
    CHECK_EQ(autiva::format_sample_line(s),
             std::string(R"({"t":12484,"ph":"down","x":562,"y":962,"f":3})"));
    s.phase = static_cast<std::uint8_t>(autiva::SamplePhase::Up);
    CHECK(autiva::format_sample_line(s).find("\"ph\":\"up\"") != std::string::npos);

    const std::string index = autiva::format_index_line("t1", "like_reel", 1700000000, 900, 42,
                                                       0, 2);
    for (const char* key : {"\"take\":\"t1\"", "\"label\":\"like_reel\"",
                            "\"duration_ms\":900", "\"samples\":42",
                            "\"volume_events\":2"}) {
        CHECK(index.find(key) != std::string::npos);
    }
    CHECK_EQ(autiva::take_dir_name("t1", "like_reel"), std::string("t1_like_reel"));

    std::string out;
    CHECK(autiva::sanitize_label("like_reel", out));
    CHECK_EQ(out, std::string("like_reel"));
    CHECK(!autiva::sanitize_label("like reel", out));
    CHECK(!autiva::sanitize_label("../etc", out));
    CHECK(!autiva::sanitize_label("", out));
    CHECK(!autiva::sanitize_label(std::string(41, 'a'), out));
}

}  // namespace

int main() {
    test_parse_flat_object();
    test_parse_nested_and_arrays();
    test_number_formatting();
    test_string_escapes();
    test_malformed_input();
    test_id_sanitisation();
    test_parse_command();
    test_reply_shapes();
    test_rng_determinism_and_bounds();
    test_digitizer_profile();
    test_plan_validation();
    test_sample_ring();
    test_record_formatting();

    std::printf("%d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
