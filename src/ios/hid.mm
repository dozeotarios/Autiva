// Touch synthesis (v10): a sampled digitizer waveform instead of a constant.
//
// v8 emitted byte-identical touches for every gesture — finger 2, pressure 1.0,
// twist 90, no radii, fixed 80 ms hold, linear swipe at ~62 Hz. This version
// samples every field from the seeded DigitizerProfile (core/profile.cpp),
// schedules on absolute deadlines instead of usleep drift, and resets the
// display idle timer so the panel does not nap mid-sequence.
//
// Deliberately preserved from v8: the hand/finger event shape, the magic sender
// id, IsBuiltIn / IsDisplayIntegrated, and the main-queue dispatch (the
// XXTouchNG recipe that is known to work on iOS 13-16).
#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <cmath>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>

#include "ios.hpp"
#include "profile.hpp"

namespace autiva {
namespace {

typedef double IOHIDFloat;
typedef struct __IOHIDEvent* IOHIDEventRef;
typedef struct __IOHIDEventSystemClient* IOHIDEventSystemClientRef;
typedef uint32_t IOHIDDigitizerEventMask;
typedef uint32_t IOHIDDigitizerTransducerType;
typedef uint32_t IOHIDEventOptionBits;

constexpr int kHandTransducer = 3;
constexpr uint32_t kRange = 1U << 0;
constexpr uint32_t kTouch = 1U << 1;
constexpr uint32_t kPosition = 1U << 2;
constexpr uint32_t kIdentity = 1U << 5;
constexpr uint32_t kFieldIsBuiltIn = 4;
constexpr uint32_t kFieldIsDisplayIntegrated = 720921;
constexpr uint32_t kFieldMajorRadius = 720916;
constexpr uint32_t kFieldMinorRadius = 720917;

extern "C" {
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timestamp, IOHIDDigitizerTransducerType type,
    uint32_t index, uint32_t identity, IOHIDDigitizerEventMask eventMask,
    uint32_t buttonMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat barrelPressure, Boolean range, Boolean touch,
    IOHIDEventOptionBits options);
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator, uint64_t timestamp, uint32_t index, uint32_t identity,
    IOHIDDigitizerEventMask eventMask, IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist, Boolean range, Boolean touch,
    IOHIDEventOptionBits options);
void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child,
                           IOHIDEventOptionBits options);
void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, CFIndex value);
void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client,
                                         IOHIDEventRef event);
// Resolved with dlsym: if a future iOS drops it, the dylib must still load.
typedef void (*SetFloatFn)(IOHIDEventRef, uint32_t, double);
}

struct Env {
    DigitizerProfile profile;
    IOHIDEventSystemClientRef client = nullptr;
    SetFloatFn set_float = nullptr;
    // BKUserEventTimer (BackBoardServices): a synthetic touch does not reset the
    // display idle timer by itself, which is why the old stack needed
    // wake_trigger retries in the middle of a run.
    Class idle_cls = Nil;
    SEL idle_sel = nullptr;
    bool idle_timer = false;
};

Env& env() {
    static Env e{DigitizerProfile(static_cast<std::uint64_t>(getpid()) * 2654435761ULL +
                                 mono_ms())};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        e.client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        e.set_float = reinterpret_cast<SetFloatFn>(dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue"));
        e.idle_cls = objc_getClass("BKUserEventTimer");
        e.idle_sel = sel_registerName("userEventOccurred");
        e.idle_timer = e.idle_cls && [e.idle_cls respondsToSelector:e.idle_sel];
        // backboardd does not link BKUserEventTimer (measured: class absent), so
        // idle-timer reset is unavailable HERE. The mitigation is the display
        // wake nudge + capture retry, which needs no private API.
        log_line(std::string("hid: ids=") + (e.client ? "1" : "0") + " radii=" +
                 (e.set_float ? "1" : "0") + " idle_cls=" +
                 (e.idle_cls ? "1" : "0") + " idle_sel=" + (e.idle_sel ? "1" : "0") +
                 " idletimer=" + (e.idle_timer ? "1" : "0"));
    });
    return e;
}

bool idle_timer_available() { return env().idle_timer; }

void reset_idle_timer() {
    Env& e = env();
    if (!e.idle_timer) return;
    ((void (*)(id, SEL))objc_msgSend)((id)e.idle_cls, e.idle_sel);
}

IOHIDEventRef build_event(const TouchSample& s, uint32_t mask, bool range, bool touch) {
    const uint64_t ts = mach_absolute_time();
    Env& e = env();

    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts, kHandTransducer, 0, e.profile.hand_id(), mask, 0, 0, 0, 0,
        0, 0, range ? 1 : 0, touch ? 1 : 0, 0);
    if (!hand) return nullptr;
    IOHIDEventSetIntegerValue(hand, kFieldIsBuiltIn, 1);
    IOHIDEventSetIntegerValue(hand, kFieldIsDisplayIntegrated, 1);

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, ts, e.profile.finger_id(), e.profile.finger_id(), mask, s.x, s.y,
        s.z, s.pressure, s.twist, range ? 1 : 0, touch ? 1 : 0, 0);
    if (!finger) {
        CFRelease(hand);
        return nullptr;
    }
    if (e.set_float) {
        e.set_float(finger, kFieldMajorRadius, s.major_radius);
        e.set_float(finger, kFieldMinorRadius, s.minor_radius);
    }
    IOHIDEventAppendEvent(hand, finger, 0);
    CFRelease(finger);
    return hand;
}

// Dispatch on the main queue (v8 behaviour) and report whether it ran. On the
// main thread we dispatch synchronously: waiting on a semaphore there would
// deadlock backboardd.
bool send_event(IOHIDEventRef event) {
    if (!event) return false;
    IOHIDEventRef strong = (IOHIDEventRef)CFRetain(event);
    if (pthread_main_np()) {
        IOHIDEventSetSenderID(strong, kSyntheticSenderId);
        IOHIDEventSystemClientDispatchEvent(env().client, strong);
        reset_idle_timer();
        CFRelease(strong);
        return true;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        IOHIDEventSetSenderID(strong, kSyntheticSenderId);
        IOHIDEventSystemClientDispatchEvent(env().client, strong);
        reset_idle_timer();
        CFRelease(strong);
        dispatch_semaphore_signal(done);
    });
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC)) == 0;
}

TouchSample sample_at(int x, int y, double pressure) {
    Env& e = env();
    TouchSample s;
    s.x = static_cast<double>(x) / kScreenW;
    s.y = static_cast<double>(y) / kScreenH;
    s.pressure = pressure;
    e.profile.radii(s.major_radius, s.minor_radius);
    s.twist = e.profile.twist();
    return s;
}

void send_move(const TouchSample& s) {
    IOHIDEventRef ev = build_event(s, kPosition, true, true);
    if (ev) {
        send_event(ev);
        CFRelease(ev);
    }
}

// Down + micro-tremor + up: the shape of a real tap, not two instantaneous
// events 80 ms apart. Tremor stays under 2 px (UIKit's tap slop is 10 px), so it
// can never turn a tap into a drag.
bool do_tap(int x, int y, int hold_ms, const char* label) {
    DigitizerProfile& p = env().profile;
    TouchSample down = sample_at(x, y, p.pressure_down());
    IOHIDEventRef ev = build_event(down, kRange | kTouch | kPosition, true, true);
    bool ok = send_event(ev);
    if (ev) CFRelease(ev);

    const uint64_t start = mono_ms();
    const uint64_t deadline = start + static_cast<uint64_t>(hold_ms);
    int tremors = 0;
    while (mono_ms() + 12 < deadline && tremors < 2) {
        const double amp = p.tremor_px();
        const double dx = amp * (tremors % 2 ? -1.0 : 1.0);
        const double dy = amp * (tremors % 2 ? 1.0 : -1.0);
        sleep_until_ms(start + static_cast<uint64_t>((tremors + 1) * 20));
        TouchSample mid = down;
        mid.x += dx / kScreenW;
        mid.y += dy / kScreenH;
        mid.pressure = p.pressure_hold(static_cast<double>(tremors + 1) / 3.0);
        p.radii(mid.major_radius, mid.minor_radius);
        send_move(mid);
        ++tremors;
    }
    sleep_until_ms(deadline);

    TouchSample up = sample_at(x, y, 0.0);
    IOHIDEventRef up_ev = build_event(up, kRange | kTouch, false, false);
    const bool ok_up = send_event(up_ev);
    if (up_ev) CFRelease(up_ev);

    log_line(std::string(label) + " (" + std::to_string(x) + "," + std::to_string(y) +
             ") hold=" + std::to_string(hold_ms) + "ms finger=" +
             std::to_string(p.finger_id()) + " tremors=" + std::to_string(tremors) +
             " delivered=" + (ok && ok_up ? "1" : "0"));
    return ok && ok_up;
}

}  // namespace

bool hid_tap(int x, int y, int hold_ms) {
    // hold_ms <= 0 means "sample a human tap"; an explicit value is honoured
    // (the FSM carries tuned constants and must not drift under it).
    const int hold = hold_ms > 0 ? hold_ms : env().profile.tap_hold_ms();
    return do_tap(x, y, hold, "tap");
}

bool hid_long_press(int x, int y, int duration_ms) {
    const int hold = env().profile.jittered_hold_ms(duration_ms);
    return do_tap(x, y, hold, "long_press");
}

bool hid_swipe(int x1, int y1, int x2, int y2, int duration_ms) {
    Env& p = env();
    const int step_ms = p.profile.swipe_step_ms();
    const int steps = duration_ms / step_ms > 8 ? duration_ms / step_ms : 8;
    const double curve = p.profile.swipe_curve_px();

    TouchSample down = sample_at(x1, y1, p.profile.pressure_down());
    IOHIDEventRef ev = build_event(down, kRange | kTouch | kPosition, true, true);
    bool ok = send_event(ev);
    if (ev) CFRelease(ev);

    // Ease-out along the path (a flick decelerates), plus a slight lateral bow
    // so the trajectory is not a perfect straight line.
    const double ax = static_cast<double>(x1), ay = static_cast<double>(y1);
    const double dx = static_cast<double>(x2) - ax, dy = static_cast<double>(y2) - ay;
    const double len = std::sqrt(dx * dx + dy * dy);
    const double nx = len > 0.0 ? -dy / len : 0.0;
    const double ny = len > 0.0 ? dx / len : 0.0;

    const uint64_t t0 = mono_ms();
    int jitter_ms = 0;
    for (int i = 1; i <= steps; ++i) {
        const double u = static_cast<double>(i) / steps;
        const double eased = 1.0 - (1.0 - u) * (1.0 - u);
        const double bow = curve * std::sin(3.14159265358979323846 * u);
        TouchSample s = sample_at(static_cast<int>(ax + dx * eased + nx * bow),
                                  static_cast<int>(ay + dy * eased + ny * bow),
                                  p.profile.pressure_hold(u));
        jitter_ms += step_ms + static_cast<int>(p.profile.rng().uniform(-0.8, 0.8));
        sleep_until_ms(t0 + static_cast<uint64_t>(jitter_ms > 0 ? jitter_ms : 0));
        send_move(s);
    }

    TouchSample up = sample_at(x2, y2, 0.0);
    IOHIDEventRef up_ev = build_event(up, kRange | kTouch, false, false);
    const bool ok_up = send_event(up_ev);
    if (up_ev) CFRelease(up_ev);

    log_line("swipe (" + std::to_string(x1) + "," + std::to_string(y1) + ")->(" +
             std::to_string(x2) + "," + std::to_string(y2) + ") " +
             std::to_string(duration_ms) + "ms steps=" + std::to_string(steps) +
             " step_ms=" + std::to_string(step_ms) + " curve=" +
             std::to_string(static_cast<int>(curve * 10)) + " delivered=" +
             (ok && ok_up ? "1" : "0"));
    return ok && ok_up;
}

bool hid_idle_timer_available() { return idle_timer_available(); }

}  // namespace autiva
