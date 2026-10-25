// Single-producer single-consumer sample ring for the input monitor (E11 S8, design note 7).
//
// Realtime: push is wait-free, takes no lock, allocates nothing and never blocks; when the ring
// is full the frames that do not fit are dropped and counted. Allocation: create only.
// Synchronisation: release/acquire on the two indices. Latency: whatever the consumer lets
// accumulate. Sample rate and channel count: none (mono floats). Reset: consumer side, producer
// stopped.
#include <atomic>
#include <cmath>
#include <cstdint>
#include <new>

#include "n60/measure.h"

struct n60_monitor_ring {
    float *data = nullptr;
    uint32_t mask = 0;
    alignas(64) std::atomic<uint64_t> head{0};  // written by the producer
    alignas(64) std::atomic<uint64_t> tail{0};  // written by the consumer
    alignas(64) std::atomic<uint64_t> overruns{0};
};

int32_t n60_monitor_ring_create(uint32_t capacity_frames, n60_monitor_ring **ring_out) {
    if (ring_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    *ring_out = nullptr;
    if (capacity_frames < 256 || capacity_frames > (1u << 24) || (capacity_frames & (capacity_frames - 1)) != 0) {
        return N60_MEASURE_ERR_SIZE;
    }
    n60_monitor_ring *ring = new (std::nothrow) n60_monitor_ring();
    if (ring == nullptr) return N60_MEASURE_ERR_ALLOC;
    ring->data = new (std::nothrow) float[capacity_frames]();
    if (ring->data == nullptr) {
        delete ring;
        return N60_MEASURE_ERR_ALLOC;
    }
    ring->mask = capacity_frames - 1;
    *ring_out = ring;
    return N60_MEASURE_OK;
}

void n60_monitor_ring_destroy(n60_monitor_ring *ring) {
    if (ring == nullptr) return;
    delete[] ring->data;
    delete ring;
}

uint32_t n60_monitor_ring_push(n60_monitor_ring *ring, const float *samples, uint32_t stride, uint32_t frames) {
    if (ring == nullptr || samples == nullptr || stride == 0 || frames == 0) return 0;
    const uint64_t head = ring->head.load(std::memory_order_relaxed);
    const uint64_t tail = ring->tail.load(std::memory_order_acquire);
    const uint64_t capacity = static_cast<uint64_t>(ring->mask) + 1;
    const uint64_t space = capacity - (head - tail);
    const uint32_t accepted = frames < space ? frames : static_cast<uint32_t>(space);
    for (uint32_t i = 0; i < accepted; ++i) {
        const float v = samples[static_cast<size_t>(i) * stride];
        ring->data[(head + i) & ring->mask] = std::isfinite(v) ? v : 0.0f;
    }
    ring->head.store(head + accepted, std::memory_order_release);
    if (accepted < frames) ring->overruns.fetch_add(frames - accepted, std::memory_order_relaxed);
    return accepted;
}

uint32_t n60_monitor_ring_pop(n60_monitor_ring *ring, float *out, uint32_t max_frames) {
    if (ring == nullptr || out == nullptr || max_frames == 0) return 0;
    const uint64_t tail = ring->tail.load(std::memory_order_relaxed);
    const uint64_t head = ring->head.load(std::memory_order_acquire);
    const uint64_t avail = head - tail;
    const uint32_t n = avail < max_frames ? static_cast<uint32_t>(avail) : max_frames;
    for (uint32_t i = 0; i < n; ++i) out[i] = ring->data[(tail + i) & ring->mask];
    ring->tail.store(tail + n, std::memory_order_release);
    return n;
}

uint32_t n60_monitor_ring_available(const n60_monitor_ring *ring) {
    if (ring == nullptr) return 0;
    return static_cast<uint32_t>(ring->head.load(std::memory_order_acquire) - ring->tail.load(std::memory_order_acquire));
}

uint64_t n60_monitor_ring_overrun_frames(const n60_monitor_ring *ring) {
    return ring == nullptr ? 0 : ring->overruns.load(std::memory_order_relaxed);
}

void n60_monitor_ring_reset(n60_monitor_ring *ring) {
    if (ring == nullptr) return;
    ring->tail.store(ring->head.load(std::memory_order_acquire), std::memory_order_release);
    ring->overruns.store(0, std::memory_order_relaxed);
}
