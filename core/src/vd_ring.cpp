// E36 S3: virtual driver programme ring reader/writer and clock steering. See n60/vd_ring.h for the realtime contract.
// Realtime subset: no allocation, locks, exceptions or system calls in n60_vd_ring_read / n60_vd_ring_write.
#include "n60/vd_ring.h"

#include <atomic>
#include <cmath>
#include <cstring>

static_assert(std::atomic_ref<uint64_t>::is_always_lock_free && std::atomic_ref<uint32_t>::is_always_lock_free,
              "ring atomics must be lock-free: the reader maps the ring read-only");

namespace {

template <typename T>
inline T loadAcquire(const T &field) {
    return std::atomic_ref<T>(const_cast<T &>(field)).load(std::memory_order_acquire);
}
template <typename T>
inline T loadRelaxed(const T &field) {
    return std::atomic_ref<T>(const_cast<T &>(field)).load(std::memory_order_relaxed);
}
template <typename T>
inline void storeRelease(T &field, T value) {
    std::atomic_ref<T>(field).store(value, std::memory_order_release);
}
template <typename T>
inline void storeRelaxed(T &field, T value) {
    std::atomic_ref<T>(field).store(value, std::memory_order_relaxed);
}
template <typename T>
inline void addRelaxed(T &field, T value) {
    std::atomic_ref<T>(field).fetch_add(value, std::memory_order_relaxed);
}

inline const n60_vd_ring_header *header(const void *base) { return static_cast<const n60_vd_ring_header *>(base); }
inline const float *dataOf(const void *base) {
    return reinterpret_cast<const float *>(static_cast<const unsigned char *>(base) + N60_VD_RING_HEADER_BYTES);
}

}  // namespace

extern "C" {

uint32_t n60_vd_ring_abi_version(void) { return N60_VD_RING_ABI_VERSION; }

uint32_t n60_vd_ring_capacity_frames(uint32_t channels) {
    if (channels == 0 || channels > N60_VD_RING_MAX_CHANNELS) return 0;
    return (N60_VD_RING_BYTES - N60_VD_RING_HEADER_BYTES) / (channels * 4u);
}

int n60_vd_ring_writer_init(void *base, size_t bytes, uint32_t channels, uint32_t sampleRate) {
    if (base == nullptr || bytes < N60_VD_RING_BYTES || sampleRate == 0) return N60_VD_ERR_ARGUMENT;
    const uint32_t capacity = n60_vd_ring_capacity_frames(channels);
    if (capacity == 0) return N60_VD_ERR_GEOMETRY;
    auto *h = static_cast<n60_vd_ring_header *>(base);
    uint32_t epoch = 0;
    if (h->magic == N60_VD_RING_MAGIC) epoch = loadRelaxed(h->epoch);
    h->magic = N60_VD_RING_MAGIC;
    h->layoutVersion = N60_VD_RING_LAYOUT_VERSION;
    h->channels = channels;
    h->sampleRate = sampleRate;
    h->capacityFrames = capacity;
    h->headerBytes = N60_VD_RING_HEADER_BYTES;
    storeRelaxed<uint64_t>(h->writeFrames, 0);
    storeRelaxed<uint64_t>(h->lastHostTime, 0);
    storeRelease<uint32_t>(h->epoch, epoch + 1u);
    return N60_VD_OK;
}

uint32_t n60_vd_ring_write(void *base, const float *interleaved, uint32_t frames, uint64_t hostTime) {
    auto *h = static_cast<n60_vd_ring_header *>(base);
    if (base == nullptr || interleaved == nullptr || h->magic != N60_VD_RING_MAGIC) return 0;
    const uint32_t channels = h->channels;
    const uint32_t capacity = h->capacityFrames;
    if (channels == 0 || channels > N60_VD_RING_MAX_CHANNELS || capacity == 0 || frames > capacity) return 0;
    float *data = reinterpret_cast<float *>(static_cast<unsigned char *>(base) + N60_VD_RING_HEADER_BYTES);
    const uint64_t w = loadRelaxed(h->writeFrames);
    uint32_t slot = static_cast<uint32_t>(w % capacity);
    for (uint32_t i = 0; i < frames; ++i) {
        std::memcpy(data + static_cast<size_t>(slot) * channels, interleaved + static_cast<size_t>(i) * channels,
                    sizeof(float) * channels);
        if (++slot == capacity) slot = 0;
    }
    storeRelaxed<uint64_t>(h->lastHostTime, hostTime);
    storeRelease<uint64_t>(h->writeFrames, w + frames);
    return frames;
}

int n60_vd_ring_reader_attach(n60_vd_ring_reader *reader, const void *base, size_t bytes, uint32_t primeFrames) {
    if (reader == nullptr || base == nullptr || bytes < N60_VD_RING_BYTES) return N60_VD_ERR_ARGUMENT;
    const n60_vd_ring_header *h = header(base);
    if (h->magic != N60_VD_RING_MAGIC) return N60_VD_ERR_MAGIC;
    if (h->layoutVersion != N60_VD_RING_LAYOUT_VERSION) return N60_VD_ERR_VERSION;
    if (h->headerBytes != N60_VD_RING_HEADER_BYTES || h->channels == 0 || h->channels > N60_VD_RING_MAX_CHANNELS ||
        h->capacityFrames != n60_vd_ring_capacity_frames(h->channels)) {
        return N60_VD_ERR_GEOMETRY;
    }
    std::memset(reader, 0, sizeof *reader);
    reader->base = base;
    reader->channels = h->channels;
    reader->capacityFrames = h->capacityFrames;
    uint32_t prime = primeFrames == 0 ? 1024u : primeFrames;
    if (prime > reader->capacityFrames / 4u) prime = reader->capacityFrames / 4u;
    reader->primeFrames = prime;
    reader->highFrames = reader->capacityFrames / 2u;
    reader->epoch = loadAcquire(h->epoch);
    reader->readPos = loadAcquire(h->writeFrames);
    reader->running = 0;
    return N60_VD_OK;
}

uint32_t n60_vd_ring_read(n60_vd_ring_reader *r, float *out, uint32_t frames, uint32_t outChannels) {
    const size_t outCount = static_cast<size_t>(frames) * outChannels;
    if (r == nullptr || r->base == nullptr || out == nullptr || outChannels == 0) return 0;
    const n60_vd_ring_header *h = header(r->base);
    const uint32_t epoch = loadAcquire(h->epoch);
    uint64_t w = loadAcquire(h->writeFrames);
    if (epoch != r->epoch) {  // the writer restarted: start over at its new position
        r->epoch = epoch;
        r->readPos = w;
        r->running = 0;
        addRelaxed<uint64_t>(r->epochChanges, 1);
        // The restarted ring may have another channel count, hence another capacity and stride: re-validate or go silent.
        const uint32_t ch = h->channels;
        if (ch == 0 || ch > N60_VD_RING_MAX_CHANNELS || h->capacityFrames != n60_vd_ring_capacity_frames(ch)) {
            std::memset(out, 0, sizeof(float) * outCount);
            storeRelaxed<uint32_t>(r->fillFrames, 0);
            return 0;
        }
        r->channels = ch;
        r->capacityFrames = h->capacityFrames;
        r->highFrames = r->capacityFrames / 2u;
        if (r->primeFrames > r->capacityFrames / 4u) r->primeFrames = r->capacityFrames / 4u;
    } else if (w < r->readPos) {
        r->readPos = w;
        r->running = 0;
    }
    uint64_t fill = w - r->readPos;
    if (fill > r->highFrames) {  // too full: skip to the prime level, counted as dropped
        const uint64_t keep = r->primeFrames;
        addRelaxed<uint64_t>(r->droppedFrames, fill - keep);
        r->readPos = w - keep;
        fill = keep;
    }
    if (!r->running && fill >= r->primeFrames) r->running = 1;

    const uint32_t capacity = r->capacityFrames;
    uint32_t produced = 0;
    if (r->running) {
        produced = fill < frames ? static_cast<uint32_t>(fill) : frames;
        const uint64_t start = r->readPos;
        const float *data = dataOf(r->base);
        const uint32_t ch = r->channels;
        const uint32_t copyCh = ch < outChannels ? ch : outChannels;
        uint32_t slot = static_cast<uint32_t>(start % capacity);
        for (uint32_t i = 0; i < produced; ++i) {
            const float *src = data + static_cast<size_t>(slot) * ch;
            float *dst = out + static_cast<size_t>(i) * outChannels;
            for (uint32_t c = 0; c < copyCh; ++c) dst[c] = src[c];
            for (uint32_t c = copyCh; c < outChannels; ++c) dst[c] = 0.0f;
            if (++slot == capacity) slot = 0;
        }
        // Torn-read check: if the writer lapped the span we just read, that audio is not trustworthy.
        const uint64_t w2 = loadAcquire(h->writeFrames);
        if (w2 - start > capacity) {
            addRelaxed<uint64_t>(r->overruns, 1);
            produced = 0;
            r->readPos = w2 - r->primeFrames;
            r->running = 0;
            w = w2;
        } else {
            r->readPos = start + produced;
        }
        if (produced < frames) {  // ran dry: re-prime so the next block is not a stutter of single frames
            r->running = 0;
        }
    }
    if (produced < frames) {
        std::memset(out + static_cast<size_t>(produced) * outChannels, 0,
                    sizeof(float) * (outCount - static_cast<size_t>(produced) * outChannels));
        // Priming silence before the first audio is not an underrun; silence after audio has played is.
        if (r->hasPlayed) addRelaxed<uint64_t>(r->underrunFrames, frames - produced);
    }
    if (produced > 0) r->hasPlayed = 1;
    const uint64_t newFill = w >= r->readPos ? w - r->readPos : 0;
    storeRelaxed<uint32_t>(r->fillFrames, static_cast<uint32_t>(newFill > UINT32_MAX ? UINT32_MAX : newFill));
    if (r->running) {  // the control plane averages these over its window; priming fill says nothing about clock drift
        addRelaxed<uint64_t>(r->fillSum, newFill);
        addRelaxed<uint64_t>(r->fillSamples, 1);
    }
    return produced;
}

double n60_vd_ring_reader_mean_fill(const n60_vd_ring_reader *r, uint64_t *prevSum, uint64_t *prevSamples) {
    const uint64_t sum = loadRelaxed(r->fillSum);
    const uint64_t count = loadRelaxed(r->fillSamples);
    if (count <= *prevSamples) return -1.0;
    const double mean = static_cast<double>(sum - *prevSum) / static_cast<double>(count - *prevSamples);
    *prevSum = sum;
    *prevSamples = count;
    return mean;
}

void n60_vd_steer_init(n60_vd_steer *s, double sampleRate, uint32_t targetFrames) {
    std::memset(s, 0, sizeof *s);
    s->sampleRate = sampleRate;
    s->targetFrames = targetFrames;
    s->filteredFrames = targetFrames;
    s->scalar = 1.0;
}

double n60_vd_steer_update(n60_vd_steer *s, double fillFrames, double dt) {
    if (!(dt > 0.0) || !(s->sampleRate > 0.0)) return s->scalar;
    if (!s->primed) {
        s->filteredFrames = fillFrames;
        s->primed = 1;
    }
    // One-pole smoothing of the sampled fill (time constant 0.4 s) hides callback-size jitter.
    const double alpha = 1.0 - std::exp(-dt / 0.4);
    s->filteredFrames += alpha * (static_cast<double>(fillFrames) - s->filteredFrames);
    const double err = (s->filteredFrames - s->targetFrames) / s->sampleRate;  // seconds; positive means too full
    const double limit = N60_VD_STEER_MAX_PPM * 1e-6;
    const double kp = 1.2, ki = 0.36;  // critically damped, natural frequency 0.6 rad/s
    s->integral += err * dt;
    // Anti-windup: the integral term alone may not exceed the limit.
    const double iMax = limit / ki;
    if (s->integral > iMax) s->integral = iMax;
    if (s->integral < -iMax) s->integral = -iMax;
    double eps = -(kp * err + ki * s->integral);  // too full: slow the writer down
    if (eps > limit) eps = limit;
    if (eps < -limit) eps = -limit;
    s->scalar = 1.0 + eps;
    return s->scalar;
}

}  // extern "C"
