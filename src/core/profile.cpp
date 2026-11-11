#include "profile.hpp"

#include <cmath>

namespace autiva {

DigitizerProfile::DigitizerProfile(std::uint64_t seed) : rng_(seed) {
    // 1..14: 0 means "no finger" in the digitizer vocabulary, and a stream of
    // touches that always claims id 2 is a signature in its own right.
    finger_id_ = static_cast<std::uint32_t>(rng_.integer(1, 14));
    base_major_ = rng_.uniform(0.0060, 0.0105);
    base_minor_ = rng_.uniform(0.0038, 0.0072);
}

int DigitizerProfile::tap_hold_ms() {
    const double raw = rng_.log_normal(85.0, 0.22);
    return static_cast<int>(Rng::clamp(raw, 45.0, 160.0));
}

int DigitizerProfile::jittered_hold_ms(int requested) {
    if (requested <= 0) requested = 900;
    const double raw = static_cast<double>(requested) * (1.0 + rng_.normal() * 0.05);
    const long long lo = requested * 8 / 10;
    const long long hi = requested * 12 / 10;
    return static_cast<int>(Rng::clamp(raw, static_cast<double>(lo), static_cast<double>(hi)));
}

double DigitizerProfile::pressure_down() { return rng_.uniform(0.30, 0.45); }

double DigitizerProfile::pressure_hold(double t) {
    // Contact firms up after landing, peaks, then relaxes a touch before lift.
    const double shaped = 0.55 + 0.35 * std::sin(3.14159265358979323846 * Rng::clamp(t, 0.0, 1.0));
    return Rng::clamp(shaped + rng_.normal() * 0.03, 0.20, 0.95);
}

void DigitizerProfile::radii(double& major, double& minor) {
    major = Rng::clamp(base_major_ * (1.0 + rng_.normal() * 0.05), 0.0040, 0.0130);
    minor = Rng::clamp(base_minor_ * (1.0 + rng_.normal() * 0.05), 0.0025, 0.0100);
}

double DigitizerProfile::twist() { return Rng::clamp(90.0 + rng_.normal() * 6.0, 60.0, 120.0); }

double DigitizerProfile::tremor_px() { return rng_.uniform(0.4, 1.8); }

int DigitizerProfile::swipe_step_ms() {
    // 6-8 ms between samples => 125-160 Hz, matching the panel's report rate.
    return static_cast<int>(rng_.integer(6, 8));
}

double DigitizerProfile::swipe_curve_px() { return rng_.uniform(-2.5, 2.5); }

}  // namespace autiva
