#ifndef N60FeedForwardOutputTiming_h
#define N60FeedForwardOutputTiming_h

#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

typedef struct {
    _Atomic uint64_t epoch;
    _Atomic uint64_t firstFrameHostTime;
    _Atomic uint64_t sampleTimeBits;
    _Atomic uint32_t renderedFrames;
    _Atomic uint64_t callbackCount;
    _Atomic uint64_t invalidCount;
} N60FeedForwardOutputTiming;

typedef struct {
    bool valid;
    uint64_t firstFrameHostTime;
    double firstFrameSampleTime;
    uint32_t renderedFrames;
    uint64_t callbackCount;
    uint64_t invalidCount;
} N60FeedForwardOutputTimingSnapshot;

static inline uint64_t N60FeedForwardTimeEncodeDouble(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline double N60FeedForwardTimeDecodeDouble(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

/// Always a passive observer. Does not schedule, mix or inject audio.
/// Output callbacks are single-producer; reader sees an all-or-nothing
/// timestamp tuple via an even/odd publication epoch.
static inline void N60FeedForwardOutputTimingObserve(
    N60FeedForwardOutputTiming * _Nonnull witness,
    const AudioTimeStamp * _Nullable outputTime,
    uint32_t frames
) {
    if (witness == NULL) return;
    atomic_fetch_add_explicit(
        &witness->callbackCount, 1u, memory_order_relaxed
    );
    if (outputTime == NULL
        || (outputTime->mFlags & kAudioTimeStampHostTimeValid) == 0
        || (outputTime->mFlags & kAudioTimeStampSampleTimeValid) == 0
        || outputTime->mHostTime == 0
        || !isfinite(outputTime->mSampleTime)
        || outputTime->mSampleTime < 0
        || frames == 0) {
        atomic_fetch_add_explicit(
            &witness->invalidCount, 1u, memory_order_relaxed
        );
        return;
    }
    uint64_t epoch = atomic_load_explicit(
        &witness->epoch, memory_order_relaxed
    );
    atomic_store_explicit(&witness->epoch, epoch + 1u, memory_order_release);
    atomic_store_explicit(
        &witness->firstFrameHostTime,
        outputTime->mHostTime,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &witness->sampleTimeBits,
        N60FeedForwardTimeEncodeDouble(outputTime->mSampleTime),
        memory_order_relaxed
    );
    atomic_store_explicit(
        &witness->renderedFrames,
        frames,
        memory_order_relaxed
    );
    atomic_store_explicit(&witness->epoch, epoch + 2u, memory_order_release);
}

/// Control-plane reset only, when output callbacks are stopped.
/// Prevents reusing timing evidence from a previous output device/route.
static inline void N60FeedForwardOutputTimingReset(
    N60FeedForwardOutputTiming * _Nonnull witness
) {
    if (witness == NULL) return;
    atomic_store_explicit(&witness->epoch, 0, memory_order_release);
    atomic_store_explicit(&witness->firstFrameHostTime, 0, memory_order_relaxed);
    atomic_store_explicit(&witness->sampleTimeBits, 0, memory_order_relaxed);
    atomic_store_explicit(&witness->renderedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&witness->callbackCount, 0, memory_order_relaxed);
    atomic_store_explicit(&witness->invalidCount, 0, memory_order_relaxed);
}

static inline N60FeedForwardOutputTimingSnapshot
N60FeedForwardOutputTimingRead(
    const N60FeedForwardOutputTiming * _Nonnull witness
) {
    N60FeedForwardOutputTimingSnapshot result = {0};
    if (witness == NULL) return result;
    result.callbackCount = atomic_load_explicit(
        &witness->callbackCount, memory_order_acquire
    );
    result.invalidCount = atomic_load_explicit(
        &witness->invalidCount, memory_order_acquire
    );
    for (int attempts = 0; attempts < 4; ++attempts) {
        uint64_t before = atomic_load_explicit(
            &witness->epoch, memory_order_acquire
        );
        if ((before & 1u) != 0 || before == 0) continue;
        const uint64_t host = atomic_load_explicit(
            &witness->firstFrameHostTime, memory_order_relaxed
        );
        const double sample = N60FeedForwardTimeDecodeDouble(
            atomic_load_explicit(
                &witness->sampleTimeBits, memory_order_relaxed
            )
        );
        const uint32_t count = atomic_load_explicit(
            &witness->renderedFrames, memory_order_relaxed
        );
        uint64_t after = atomic_load_explicit(
            &witness->epoch, memory_order_acquire
        );
        if (before == after && (after & 1u) == 0) {
            result.valid = true;
            result.firstFrameHostTime = host;
            result.firstFrameSampleTime = sample;
            result.renderedFrames = count;
            break;
        }
    }
    return result;
}
#endif
