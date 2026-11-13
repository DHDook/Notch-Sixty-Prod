#ifndef N60LoudnessCapture_h
#define N60LoudnessCapture_h

// E28 S6b: demand-gated capture of the semantic program channels for BS.1770-4 loudness on the N-channel and binaural
// bridges (design note 6). One single-producer single-consumer ring of paired Input and Output frames:
//   Input  = the program channels as the render path sees them (after the AU rack or resampler when present; binaural: after program gain), in semantic role order (subwoofer lanes excluded);
//   Output = the same channel order after the whole render (graph, protection, master gain), then one channel per driven
//            subwoofer feed (E9 S10, after the limiter and master gain), or the two ear signals on the binaural bridge. A bridge that cannot map its output back to program roles creates the ring with no
//            output channels.
//
// Realtime contract (docs/REALTIME_RULES.md):
//   Allocation:       none on the audio thread. Both planes are allocated by N60LoudnessCaptureCreate off the callback.
//   Synchronisation:  the callback is the only writer of the write index and the consumer the only writer of the read
//                     index (acquire/release); the demand word is a relaxed-to-acquire atomic. No locks.
//   Latency:          0. The ring only copies; it adds nothing to the render path.
//   Sample rate:      capacity is sized at creation to a quarter of a second at the session rate, so any of the eight
//                     standard rates (44.1 to 384 kHz) survives a worker that drains every 50 ms.
//   Channels:         1 to N60_MAX_PROGRAM_CHANNELS input channels, 0 to N60_LOUDNESS_CAPTURE_MAX_OUTPUT_CHANNELS output channels.
//   Reset:            the consumer discards pending frames by moving the read index to the write index; counters keep
//                     counting. Unread frames are never overwritten: a full ring drops new frames and counts them.

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_LOUDNESS_CAPTURE_MIN_CAPACITY_FRAMES 4096u
#define N60_LOUDNESS_CAPTURE_MAX_CAPACITY_FRAMES (1u << 20)
/// Output plane ceiling: every program role plus up to 8 subwoofer feeds (`N60_LIVE_MAX_GRAPH_SUBWOOFERS`).
#define N60_LOUDNESS_CAPTURE_MAX_SUB_FEEDS 8u
#define N60_LOUDNESS_CAPTURE_MAX_OUTPUT_CHANNELS (N60_MAX_PROGRAM_CHANNELS + N60_LOUDNESS_CAPTURE_MAX_SUB_FEEDS)

typedef struct {
    uint32_t inputChannels;
    uint32_t outputChannels;
    uint32_t capacityFrames;
    uint32_t mask;
    float * _Nullable input;
    float * _Nullable output;
    _Atomic uint32_t demand;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic uint64_t capturedFrames;
    _Atomic uint64_t droppedFrames;
} N60LoudnessCapture;

/// Where one callback block lands in the ring. `frames` is 0 when there is no demand or no room.
typedef struct {
    uint64_t base;
    uint32_t frames;
} N60LoudnessCaptureBlock;

typedef struct {
    uint32_t demand;
    uint32_t availableFrames;
    uint64_t capturedFrames;
    uint64_t droppedFrames;
} N60LoudnessCaptureSnapshot;

static inline uint32_t N60LoudnessCaptureCapacityForRate(double sampleRate) {
    double wanted = sampleRate > 0.0 ? sampleRate * 0.25 : 0.0;
    uint32_t capacity = N60_LOUDNESS_CAPTURE_MIN_CAPACITY_FRAMES;
    while ((double)capacity < wanted && capacity < N60_LOUDNESS_CAPTURE_MAX_CAPACITY_FRAMES) capacity <<= 1;
    return capacity;
}

/// Control plane only. Returns NULL on a bad channel count or allocation failure.
static inline N60LoudnessCapture * _Nullable N60LoudnessCaptureCreate(
    uint32_t inputChannels, uint32_t outputChannels, double sampleRate
) {
    if (inputChannels == 0u || inputChannels > N60_MAX_PROGRAM_CHANNELS
        || outputChannels > N60_LOUDNESS_CAPTURE_MAX_OUTPUT_CHANNELS) {
        return NULL;
    }
    N60LoudnessCapture *capture = (N60LoudnessCapture *)calloc(1u, sizeof(N60LoudnessCapture));
    if (capture == NULL) return NULL;
    capture->inputChannels = inputChannels;
    capture->outputChannels = outputChannels;
    capture->capacityFrames = N60LoudnessCaptureCapacityForRate(sampleRate);
    capture->mask = capture->capacityFrames - 1u;
    capture->input = (float *)calloc((size_t)capture->capacityFrames * inputChannels, sizeof(float));
    if (outputChannels > 0u) {
        capture->output = (float *)calloc((size_t)capture->capacityFrames * outputChannels, sizeof(float));
    }
    if (capture->input == NULL || (outputChannels > 0u && capture->output == NULL)) {
        free(capture->input);
        free(capture->output);
        free(capture);
        return NULL;
    }
    atomic_init(&capture->demand, 0u);
    atomic_init(&capture->writeIndex, 0u);
    atomic_init(&capture->readIndex, 0u);
    atomic_init(&capture->capturedFrames, 0u);
    atomic_init(&capture->droppedFrames, 0u);
    return capture;
}

static inline void N60LoudnessCaptureDestroy(N60LoudnessCapture * _Nullable capture) {
    if (capture == NULL) return;
    free(capture->input);
    free(capture->output);
    free(capture);
}

static inline void N60LoudnessCaptureSetDemand(N60LoudnessCapture * _Nullable capture, bool enabled) {
    if (capture == NULL) return;
    atomic_store_explicit(&capture->demand, enabled ? 1u : 0u, memory_order_release);
}

static inline bool N60LoudnessCaptureDemand(const N60LoudnessCapture * _Nullable capture) {
    return capture != NULL && atomic_load_explicit(&capture->demand, memory_order_acquire) != 0u;
}

/// Consumer side: drop everything pending (a rate change, a demand restart).
static inline void N60LoudnessCaptureDiscard(N60LoudnessCapture * _Nullable capture) {
    if (capture == NULL) return;
    const uint64_t write = atomic_load_explicit(&capture->writeIndex, memory_order_acquire);
    atomic_store_explicit(&capture->readIndex, write, memory_order_release);
}

static inline N60LoudnessCaptureSnapshot N60LoudnessCaptureGetSnapshot(const N60LoudnessCapture * _Nullable capture) {
    N60LoudnessCaptureSnapshot snapshot = {0};
    if (capture == NULL) return snapshot;
    snapshot.demand = atomic_load_explicit(&capture->demand, memory_order_acquire);
    const uint64_t read = atomic_load_explicit(&capture->readIndex, memory_order_acquire);
    const uint64_t write = atomic_load_explicit(&capture->writeIndex, memory_order_acquire);
    const uint64_t used = write >= read ? write - read : 0u;
    snapshot.availableFrames = used > capture->capacityFrames ? capture->capacityFrames : (uint32_t)used;
    snapshot.capturedFrames = atomic_load_explicit(&capture->capturedFrames, memory_order_relaxed);
    snapshot.droppedFrames = atomic_load_explicit(&capture->droppedFrames, memory_order_relaxed);
    return snapshot;
}

// MARK: Producer (audio callback)

/// Start a block of `frameCount` frames. Cheap when demand is off: one atomic load.
static inline N60LoudnessCaptureBlock N60LoudnessCaptureBeginBlock(
    N60LoudnessCapture * _Nullable capture, uint32_t frameCount
) {
    N60LoudnessCaptureBlock block = {0};
    if (capture == NULL || frameCount == 0u
        || atomic_load_explicit(&capture->demand, memory_order_acquire) == 0u) {
        return block;
    }
    const uint64_t write = atomic_load_explicit(&capture->writeIndex, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&capture->readIndex, memory_order_acquire);
    const uint64_t used = write >= read ? write - read : 0u;
    const uint64_t room = used >= capture->capacityFrames ? 0u : capture->capacityFrames - used;
    block.base = write;
    block.frames = frameCount < room ? frameCount : (uint32_t)room;
    if (block.frames < frameCount) {
        atomic_fetch_add_explicit(&capture->droppedFrames, frameCount - block.frames, memory_order_relaxed);
    }
    return block;
}

/// Write one frame of input channels (`inputChannels` values). Also clears the paired output slot, so a frame the render
/// path never reaches reads as silence rather than the previous lap's value.
static inline void N60LoudnessCaptureWriteInput(
    N60LoudnessCapture * _Nonnull capture, N60LoudnessCaptureBlock block, uint32_t frameIndex,
    const float * _Nonnull channels
) {
    if (frameIndex >= block.frames) return;
    const size_t slot = (size_t)((block.base + frameIndex) & capture->mask);
    memcpy(capture->input + slot * capture->inputChannels, channels, (size_t)capture->inputChannels * sizeof(float));
    if (capture->output != NULL) {
        memset(capture->output + slot * capture->outputChannels, 0, (size_t)capture->outputChannels * sizeof(float));
    }
}

/// Write one frame of output channels (`outputChannels` values).
static inline void N60LoudnessCaptureWriteOutput(
    N60LoudnessCapture * _Nonnull capture, N60LoudnessCaptureBlock block, uint32_t frameIndex,
    const float * _Nonnull channels
) {
    if (frameIndex >= block.frames || capture->output == NULL) return;
    const size_t slot = (size_t)((block.base + frameIndex) & capture->mask);
    memcpy(capture->output + slot * capture->outputChannels, channels, (size_t)capture->outputChannels * sizeof(float));
}

/// Publish the block. Call once, after the last write of the callback.
static inline void N60LoudnessCaptureCommit(N60LoudnessCapture * _Nonnull capture, N60LoudnessCaptureBlock block) {
    if (block.frames == 0u) return;
    atomic_store_explicit(&capture->writeIndex, block.base + block.frames, memory_order_release);
    atomic_fetch_add_explicit(&capture->capturedFrames, block.frames, memory_order_relaxed);
}

// MARK: Consumer (analysis worker)

/// Copy up to `capacityFrames` frames into interleaved destinations. Returns the frames read. `output` may be NULL when
/// the ring has no output channels.
static inline uint32_t N60LoudnessCaptureRead(
    N60LoudnessCapture * _Nonnull capture, float * _Nonnull input, float * _Nullable output, uint32_t capacityFrames
) {
    const uint64_t read = atomic_load_explicit(&capture->readIndex, memory_order_relaxed);
    const uint64_t write = atomic_load_explicit(&capture->writeIndex, memory_order_acquire);
    uint64_t available = write >= read ? write - read : 0u;
    if (available > capacityFrames) available = capacityFrames;
    for (uint64_t i = 0; i < available; ++i) {
        const size_t slot = (size_t)((read + i) & capture->mask);
        memcpy(input + (size_t)i * capture->inputChannels, capture->input + slot * capture->inputChannels,
               (size_t)capture->inputChannels * sizeof(float));
        if (output != NULL && capture->output != NULL) {
            memcpy(output + (size_t)i * capture->outputChannels, capture->output + slot * capture->outputChannels,
                   (size_t)capture->outputChannels * sizeof(float));
        }
    }
    atomic_store_explicit(&capture->readIndex, read + available, memory_order_release);
    return (uint32_t)available;
}

#ifdef __cplusplus
}
#endif

#endif
