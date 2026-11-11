#include "rng.hpp"

#include <cmath>

namespace autiva {

Rng::Rng(std::uint64_t seed) {
    // SplitMix64 to fill the state: a zero state would make xorshift128+ stick.
    std::uint64_t z = seed + 0x9E3779B97F4A7C15ULL;
    auto splitmix = [&z]() {
        z += 0x9E3779B97F4A7C15ULL;
        std::uint64_t x = z;
        x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
        x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
        return x ^ (x >> 31);
    };
    state_[0] = splitmix();
    state_[1] = splitmix();
    if (state_[0] == 0 && state_[1] == 0) state_[0] = 1;
}

std::uint64_t Rng::next_u64() {
    std::uint64_t x = state_[0];
    const std::uint64_t y = state_[1];
    state_[0] = y;
    x ^= x << 23;
    state_[1] = x ^ y ^ (x >> 17) ^ (y >> 26);
    return state_[1] + y;
}

double Rng::unit() {
    // 53 meaningful bits: exactly representable in a double, never 1.0.
    return static_cast<double>(next_u64() >> 11) * (1.0 / 9007199254740992.0);
}

double Rng::uniform(double lo, double hi) { return lo + (hi - lo) * unit(); }

long long Rng::integer(long long lo, long long hi) {
    if (hi <= lo) return lo;
    const std::uint64_t span = static_cast<std::uint64_t>(hi - lo) + 1;
    return lo + static_cast<long long>(next_u64() % span);
}

double Rng::normal() {
    if (has_spare_) {
        has_spare_ = false;
        return spare_;
    }
    // Box-Muller, guarding log(0).
    double u1 = unit();
    if (u1 < 1e-12) u1 = 1e-12;
    const double u2 = unit();
    const double r = std::sqrt(-2.0 * std::log(u1));
    spare_ = r * std::sin(2.0 * 3.14159265358979323846 * u2);
    has_spare_ = true;
    return r * std::cos(2.0 * 3.14159265358979323846 * u2);
}

double Rng::log_normal(double median, double sigma) {
    return median * std::exp(normal() * sigma);
}

}  // namespace autiva
