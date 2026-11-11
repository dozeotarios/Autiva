#include "record.hpp"

#include <cstdio>

namespace autiva {

SampleRing::SampleRing(std::size_t capacity) : buffer_(capacity ? capacity : 1) {}

bool SampleRing::push(const RecordSample& sample) {
    const std::uint64_t w = write_.load(std::memory_order_relaxed);
    const std::uint64_t r = read_.load(std::memory_order_acquire);
    if (w - r >= buffer_.size()) {
        dropped_.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    buffer_[w % buffer_.size()] = sample;
    write_.store(w + 1, std::memory_order_release);
    return true;
}

std::size_t SampleRing::pop_batch(RecordSample* out, std::size_t max) {
    const std::uint64_t r = read_.load(std::memory_order_relaxed);
    const std::uint64_t w = write_.load(std::memory_order_acquire);
    std::size_t n = 0;
    while (r + n < w && n < max) {
        out[n] = buffer_[(r + n) % buffer_.size()];
        ++n;
    }
    if (n) read_.store(r + n, std::memory_order_release);
    return n;
}

std::string format_sample_line(const RecordSample& s) {
    const char* phase = s.phase == static_cast<std::uint8_t>(SamplePhase::Down) ? "down"
                        : s.phase == static_cast<std::uint8_t>(SamplePhase::Move) ? "move"
                                                                                 : "up";
    char buf[128];
    const int n = std::snprintf(buf, sizeof buf,
                                "{\"t\":%u,\"ph\":\"%s\",\"x\":%d,\"y\":%d,\"f\":%u}",
                                s.t_ms, phase, static_cast<int>(s.x), static_cast<int>(s.y),
                                static_cast<unsigned>(s.finger));
    if (n <= 0) return {};
    return std::string(buf, static_cast<std::size_t>(n));
}

std::string format_index_line(const std::string& take_id, const std::string& label,
                              std::uint64_t t_start_epoch, std::uint64_t duration_ms,
                              std::uint64_t samples, std::uint64_t dropped,
                              std::uint64_t volume_events) {
    char buf[512];
    const int n = std::snprintf(
        buf, sizeof buf,
        "{\"take\":\"%s\",\"label\":\"%s\",\"t_start\":%llu,\"duration_ms\":%llu,"
        "\"samples\":%llu,\"dropped\":%llu,\"volume_events\":%llu}",
        take_id.c_str(), label.c_str(), static_cast<unsigned long long>(t_start_epoch),
        static_cast<unsigned long long>(duration_ms),
        static_cast<unsigned long long>(samples),
        static_cast<unsigned long long>(dropped),
        static_cast<unsigned long long>(volume_events));
    if (n <= 0) return {};
    return std::string(buf, static_cast<std::size_t>(n));
}

std::string take_dir_name(const std::string& take_id, const std::string& label) {
    // take_id is caller-supplied and already id-sanitised by the protocol;
    // the label is sanitised separately, so the join is filesystem-safe.
    return take_id + "_" + label;
}

bool sanitize_label(const std::string& raw, std::string& out) {
    if (raw.empty() || raw.size() > 40) return false;
    out.clear();
    for (const char c : raw) {
        const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9') || c == '-' || c == '_';
        if (!ok) return false;
        out.push_back(c);
    }
    return true;
}

}  // namespace autiva
