#ifndef N60ProgramTransportCore_h
#define N60ProgramTransportCore_h

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float channels[N60_MAX_PROGRAM_CHANNELS];
} N60ProgramTransportFrame;

typedef struct {
    uint64_t capturedFrames;
    uint64_t consumedFrames;
    uint64_t overrunFrames;
    uint64_t underrunFrames;
    uint64_t unsupportedBufferLayouts;
    uint32_t bufferedFrames;
} N60ProgramTransportSnapshot;

typedef struct N60ProgramTransport {
    uint32_t capacityFrames;
    N60ProgramChannelLayout canonicalLayout;
    N60ProgramTransportFrame * _Nullable frames;
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
    _Atomic uint64_t capturedFrames;
    _Atomic uint64_t consumedFrames;
    _Atomic uint64_t overrunFrames;
    _Atomic uint64_t underrunFrames;
    _Atomic uint64_t unsupportedBufferLayouts;
} N60ProgramTransport;

static inline N60ProgramTransport * _Nullable N60ProgramTransportCreate(
    uint32_t capacityFrames,
    N60ProgramChannelLayout canonicalLayout
) {
    if (capacityFrames == 0u || !N60ProgramChannelLayoutIsValid(&canonicalLayout)) return NULL;
    N60ProgramTransport * _Nullable transport =
        (N60ProgramTransport *)calloc(1u, sizeof(N60ProgramTransport));
    if (transport == NULL) return NULL;
    transport->frames = (N60ProgramTransportFrame *)calloc(
        capacityFrames,
        sizeof(N60ProgramTransportFrame)
    );
    if (transport->frames == NULL) {
        free(transport);
        return NULL;
    }
    transport->capacityFrames = capacityFrames;
    transport->canonicalLayout = canonicalLayout;
    return transport;
}

static inline void N60ProgramTransportDestroy(N60ProgramTransport * _Nullable transport) {
    if (transport == NULL) return;
    free(transport->frames);
    transport->frames = NULL;
    free(transport);
}

/// Control-plane reset only; producer/consumer callbacks must be stopped.
static inline void N60ProgramTransportReset(N60ProgramTransport * _Nullable transport) {
    if (transport == NULL) return;
    if (transport->frames != NULL) {
        memset(
            transport->frames,
            0,
            (size_t)transport->capacityFrames * sizeof(N60ProgramTransportFrame)
        );
    }
    atomic_store_explicit(&transport->writeIndex, 0u, memory_order_relaxed);
    atomic_store_explicit(&transport->readIndex, 0u, memory_order_relaxed);
    atomic_store_explicit(&transport->capturedFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&transport->consumedFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&transport->overrunFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&transport->underrunFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&transport->unsupportedBufferLayouts, 0u, memory_order_relaxed);
}

static inline bool N60ProgramTransportLayoutMatches(
    const N60ProgramTransport * _Nullable transport,
    const N60ProgramChannelLayout * _Nullable layout
) {
    if (transport == NULL
        || layout == NULL
        || !N60ProgramChannelLayoutIsValid(layout)
        || transport->canonicalLayout.channelCount != layout->channelCount) {
        return false;
    }
    for (uint32_t channel = 0; channel < layout->channelCount; ++channel) {
        if (transport->canonicalLayout.channels[channel] != layout->channels[channel]) return false;
    }
    return true;
}

/// Realtime SPSC producer primitive. Never overwrites unread frames.
static inline bool N60ProgramTransportEnqueueFrame(
    N60ProgramTransport * _Nonnull transport,
    const N60ProgramTransportFrame * _Nonnull frame
) {
    if (transport == NULL || frame == NULL || transport->frames == NULL) return false;
    const uint64_t writeIndex = atomic_load_explicit(&transport->writeIndex, memory_order_relaxed);
    const uint64_t readIndex = atomic_load_explicit(&transport->readIndex, memory_order_acquire);
    const uint64_t used = writeIndex >= readIndex ? writeIndex - readIndex : transport->capacityFrames;
    if (used >= transport->capacityFrames) {
        atomic_fetch_add_explicit(&transport->overrunFrames, 1u, memory_order_relaxed);
        return false;
    }
    transport->frames[(uint32_t)(writeIndex % transport->capacityFrames)] = *frame;
    atomic_store_explicit(&transport->writeIndex, writeIndex + 1u, memory_order_release);
    atomic_fetch_add_explicit(&transport->capturedFrames, 1u, memory_order_relaxed);
    return true;
}

/// Realtime SPSC consumer primitive. Empty reads return silence and count one
/// underrun frame so the future output callback can fail closed without stale data.
static inline bool N60ProgramTransportDequeueFrame(
    N60ProgramTransport * _Nonnull transport,
    N60ProgramTransportFrame * _Nonnull frameOut
) {
    if (transport == NULL || frameOut == NULL || transport->frames == NULL) return false;
    const uint64_t readIndex = atomic_load_explicit(&transport->readIndex, memory_order_relaxed);
    const uint64_t writeIndex = atomic_load_explicit(&transport->writeIndex, memory_order_acquire);
    if (writeIndex <= readIndex) {
        atomic_fetch_add_explicit(&transport->underrunFrames, 1u, memory_order_relaxed);
        *frameOut = (N60ProgramTransportFrame){0};
        return false;
    }
    *frameOut = transport->frames[(uint32_t)(readIndex % transport->capacityFrames)];
    atomic_store_explicit(&transport->readIndex, readIndex + 1u, memory_order_release);
    atomic_fetch_add_explicit(&transport->consumedFrames, 1u, memory_order_relaxed);
    return true;
}

static inline void N60ProgramTransportRecordUnsupportedBufferLayout(
    N60ProgramTransport * _Nullable transport
) {
    if (transport == NULL) return;
    atomic_fetch_add_explicit(&transport->unsupportedBufferLayouts, 1u, memory_order_relaxed);
}

static inline N60ProgramTransportSnapshot N60ProgramTransportGetSnapshot(
    const N60ProgramTransport * _Nullable transport
) {
    if (transport == NULL) return (N60ProgramTransportSnapshot){0};
    const uint64_t writeIndex = atomic_load_explicit(&transport->writeIndex, memory_order_acquire);
    const uint64_t readIndex = atomic_load_explicit(&transport->readIndex, memory_order_acquire);
    const uint64_t buffered = writeIndex >= readIndex ? writeIndex - readIndex : 0u;
    return (N60ProgramTransportSnapshot){
        .capturedFrames = atomic_load_explicit(&transport->capturedFrames, memory_order_relaxed),
        .consumedFrames = atomic_load_explicit(&transport->consumedFrames, memory_order_relaxed),
        .overrunFrames = atomic_load_explicit(&transport->overrunFrames, memory_order_relaxed),
        .underrunFrames = atomic_load_explicit(&transport->underrunFrames, memory_order_relaxed),
        .unsupportedBufferLayouts = atomic_load_explicit(
            &transport->unsupportedBufferLayouts,
            memory_order_relaxed
        ),
        .bufferedFrames = buffered > UINT32_MAX ? UINT32_MAX : (uint32_t)buffered,
    };
}

#ifdef __cplusplus
}
#endif

#endif
