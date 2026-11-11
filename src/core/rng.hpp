// Deterministic RNG for gesture sampling.
//
// xorshift128+ (same family as Swift's and V8's default): tiny, fast, no
// allocation, and — crucially — seedable so a session can be replayed exactly
// when something goes wrong. Every sampled parameter in the digitizer profile
// comes from here; nothing calls rand() or arc4random() behind the profile's
// back.
#pragma once

#include <cstdint>

namespace autiva {

class Rng {
public:
    Rng() : Rng(0x9E3779B97F4A7C15ULL) {}
    explicit Rng(std::uint64_t seed);

    std::uint64_t next_u64();
    // Uniform in [0, 1).
    double unit();
    // Uniform in [lo, hi).
    double uniform(double lo, double hi);
    // Uniform integer in [lo, hi] (inclusive).
    long long integer(long long lo, long long hi);
    // Standard normal (Box-Muller, one cached sample).
    double normal();
    // Log-normal with the given median and sigma (in log space).
    double log_normal(double median, double sigma);
    // Clamp helper used by every sampler (keeps the waveform in bounds even if
    // a caller passes a silly sigma).
    static double clamp(double v, double lo, double hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }

private:
    std::uint64_t state_[2];
    bool has_spare_ = false;
    double spare_ = 0.0;
};

}  // namespace autiva
