// Digitizer waveform profile.
//
// v8 emitted byte-identical touches: finger identity 2, tipPressure 1.0 on down
// and 0.0 on up, twist exactly 90, no radii at all, an 80 ms hold, and a linear
// swipe stepped at ~62 Hz. Those fields are not cosmetic — UIKit gesture
// recognizers and anti-automation SDKs branch on exactly them, and a touch with
// zero radius and constant full pressure is not something a finger can produce.
//
// Everything here is sampled per gesture from a seeded RNG, so:
//   * no two gestures are byte-identical,
//   * a session can be replayed exactly (same seed -> same waveform), which is
//     what makes a regression attributable instead of spooky.
//
// The constants are a first calibration from the physics of a real finger. v12
// (the recorder) measures the operator's actual touches on this panel and these
// numbers get re-tuned from that data — the profile is data, not lore.
#pragma once

#include <cstdint>

#include "rng.hpp"

namespace autiva {

struct TouchSample {
    double x = 0.0;             // normalized 0..1
    double y = 0.0;
    double z = 0.0;
    double pressure = 0.0;      // 0..1 tip pressure
    double major_radius = 0.0;  // normalized surface units
    double minor_radius = 0.0;
    double twist = 90.0;        // degrees
};

class DigitizerProfile {
public:
    explicit DigitizerProfile(std::uint64_t seed = 0);

    // A finger identity that stays stable for this process (a real user swipes
    // with the same finger ids for minutes) but is not a fixed constant.
    std::uint32_t finger_id() const { return finger_id_; }
    std::uint32_t hand_id() const { return finger_id_; }

    // Hold duration for a tap: log-normal around 85 ms, clamped to the range a
    // human actually produces (iOS registers < 200 ms as a tap).
    int tap_hold_ms();

    // A long press keeps the caller's intent but gets human jitter.
    int jittered_hold_ms(int requested);

    // Pressure at the down event and along the hold ramp (t in 0..1).
    double pressure_down();
    double pressure_hold(double t);

    // Contact geometry: a finger is an ellipse, and it rolls slightly.
    void radii(double& major, double& minor);
    double twist();

    // Micro-movement during a hold, in pixels (well below UIKit's 10 px slop,
    // so it can never turn a tap into a drag).
    double tremor_px();

    // Swipe sampling: 120-160 Hz like the panel, plus a slight path curve.
    int swipe_step_ms();
    double swipe_curve_px();

    Rng& rng() { return rng_; }

private:
    Rng rng_;
    std::uint32_t finger_id_;
    double base_major_;
    double base_minor_;
};

}  // namespace autiva
