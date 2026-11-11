// Recorder core: a lock-free sample ring and the on-disk trace format.
//
// The monitor callback runs on the HID thread inside backboardd. It must never
// block and must never do file I/O: a synchronous write with fflush per sample
// at ~120 Hz is exactly the kind of stall that starves the userspace watchdog.
// So the callback only pushes into a preallocated SPSC ring, and a flush thread
// drains it in batches.
//
// Both the ring and the line formatting are portable and host-tested; the
// platform layer owns only the IOHID callback and the files.
#pragma once

#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

namespace autiva {

enum class SamplePhase : std::uint8_t { Down = 0, Move = 1, Up = 2 };

struct RecordSample {
    std::uint32_t t_ms = 0;   // ms since take start
    std::int16_t x = 0;       // device pixels
    std::int16_t y = 0;
    std::uint8_t phase = 0;   // SamplePhase
    std::uint8_t finger = 0;  // finger identity from the digitizer
};

// Single-producer / single-consumer ring. push() is called from the HID
// callback; pop_batch() from the flush thread. Full ring drops the sample and
// counts it — dropping is always preferable to blocking a system daemon.
class SampleRing {
public:
    explicit SampleRing(std::size_t capacity = 8192);

    bool push(const RecordSample& sample);
    std::size_t pop_batch(RecordSample* out, std::size_t max);
    std::uint64_t dropped() const { return dropped_.load(std::memory_order_relaxed); }
    std::size_t capacity() const { return buffer_.size(); }
    bool empty() const {
        return read_.load(std::memory_order_relaxed) == write_.load(std::memory_order_relaxed);
    }

private:
    std::vector<RecordSample> buffer_;
    std::atomic<std::uint64_t> write_{0};
    std::atomic<std::uint64_t> read_{0};
    std::atomic<std::uint64_t> dropped_{0};
};

// One JSONL line per sample, no trailing newline.
std::string format_sample_line(const RecordSample& sample);

// The take's index line (one per completed take, appended to INDEX.jsonl).
std::string format_index_line(const std::string& take_id, const std::string& label,
                              std::uint64_t t_start_epoch, std::uint64_t duration_ms,
                              std::uint64_t samples, std::uint64_t dropped,
                              std::uint64_t volume_events);

// Directory name for a take: safe for the filesystem, sortable, and unique.
std::string take_dir_name(const std::string& take_id, const std::string& label);

// Reject labels that would escape the record directory or break the format.
bool sanitize_label(const std::string& raw, std::string& out);

}  // namespace autiva
