#ifndef N60ProgramTransport_h
#define N60ProgramTransport_h

#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60ChannelRouter.h"
#include "N60CoreAudioChannelMapping.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_PROGRAM_OUTPUT_CHANNEL_UNMAPPED UINT32_MAX

typedef struct {
    float channels[N60_MAX_PROGRAM_CHANNELS];
} N60ProgramTransportFrame;

typedef struct {
    bool valid;
    uint32_t streamChannelCount;
    N60ProgramChannelLayout streamLayout;
    N60ProgramChannelLayout canonicalLayout;
    N60ChannelRoutingMatrix streamToCanonical;
} N60ProgramInputMap;

typedef struct {
    bool valid;
    uint32_t physicalChannelCount;
    N60ProgramChannelLayout canonicalLayout;
    uint32_t physicalChannelForProgram[N60_MAX_PROGRAM_CHANNELS];
} N60ProgramOutputMap;

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

static inline bool N60ProgramInputMapCompile(
    const AudioChannelDescription * _Nonnull streamDescriptions,
    uint32_t streamChannelCount,
    N60ProgramChannelLayout canonicalLayout,
    N60ProgramInputMap * _Nonnull mapOut
) {
    if (streamDescriptions == NULL
        || mapOut == NULL
        || !N60ProgramChannelLayoutIsValid(&canonicalLayout)
        || streamChannelCount != canonicalLayout.channelCount) {
        return false;
    }

    N60ProgramChannelLayout streamLayout = {0};
    if (!N60ProgramChannelLayoutFromAudioChannelDescriptions(
            streamDescriptions,
            streamChannelCount,
            &streamLayout)) {
        return false;
    }

    N60ChannelRoutingMatrix reorder = {0};
    if (!N60ChannelRoutingMatrixCompileSemanticReorder(
            &streamLayout,
            &canonicalLayout,
            &reorder)) {
        return false;
    }

    *mapOut = (N60ProgramInputMap){
        .valid = true,
        .streamChannelCount = streamChannelCount,
        .streamLayout = streamLayout,
        .canonicalLayout = canonicalLayout,
        .streamToCanonical = reorder,
    };
    return true;
}

/// Compiles semantic program roles to explicit physical Core Audio channels.
/// Extra physical channels may exist and are left unmapped/silenced, but every
/// canonical program role must appear exactly once in the device descriptions.
/// Unsupported/ambiguous labels are never guessed into semantic roles.
static inline bool N60ProgramOutputMapCompile(
    const AudioChannelDescription * _Nonnull physicalDescriptions,
    uint32_t physicalChannelCount,
    N60ProgramChannelLayout canonicalLayout,
    N60ProgramOutputMap * _Nonnull mapOut
) {
    if (physicalDescriptions == NULL
        || mapOut == NULL
        || physicalChannelCount == 0u
        || !N60ProgramChannelLayoutIsValid(&canonicalLayout)) {
        return false;
    }

    N60ProgramOutputMap result = {0};
    result.physicalChannelCount = physicalChannelCount;
    result.canonicalLayout = canonicalLayout;
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        result.physicalChannelForProgram[channel] = N60_PROGRAM_OUTPUT_CHANNEL_UNMAPPED;
    }

    bool semanticRoleSeen[N60_MAX_PROGRAM_CHANNELS + 1u] = {false};
    for (uint32_t physical = 0; physical < physicalChannelCount; ++physical) {
        const N60ProgramChannelRole role = N60ProgramChannelRoleFromAudioChannelLabel(
            physicalDescriptions[physical].mChannelLabel
        );
        if (!N60ProgramChannelRoleIsSemantic(role)) continue;
        const uint32_t roleIndex = (uint32_t)role;
        if (roleIndex > N60_MAX_PROGRAM_CHANNELS || semanticRoleSeen[roleIndex]) return false;
        semanticRoleSeen[roleIndex] = true;

        const int32_t program = N60ProgramChannelLayoutIndexOfRole(&canonicalLayout, role);
        if (program >= 0) {
            result.physicalChannelForProgram[(uint32_t)program] = physical;
        }
    }

    for (uint32_t program = 0; program < canonicalLayout.channelCount; ++program) {
        if (result.physicalChannelForProgram[program] == N60_PROGRAM_OUTPUT_CHANNEL_UNMAPPED) {
            return false;
        }
    }
    result.valid = true;
    *mapOut = result;
    return true;
}

static inline bool N60ProgramTransportBufferFrameCount(
    const AudioBufferList * _Nullable bufferList,
    uint32_t requiredFlattenedChannels,
    uint32_t * _Nonnull frameCountOut
) {
    if (bufferList == NULL
        || frameCountOut == NULL
        || bufferList->mNumberBuffers == 0u
        || requiredFlattenedChannels == 0u) {
        return false;
    }
    uint64_t flattenedChannels = 0u;
    uint32_t frameCount = UINT32_MAX;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0u) return false;
        const uint64_t bytesPerFrame = (uint64_t)sizeof(float) * buffer->mNumberChannels;
        if (bytesPerFrame == 0u || ((uint64_t)buffer->mDataByteSize % bytesPerFrame) != 0u) return false;
        const uint32_t bufferFrames = (uint32_t)((uint64_t)buffer->mDataByteSize / bytesPerFrame);
        if (bufferFrames < frameCount) frameCount = bufferFrames;
        flattenedChannels += buffer->mNumberChannels;
    }
    if (flattenedChannels < requiredFlattenedChannels || frameCount == UINT32_MAX) return false;
    *frameCountOut = frameCount;
    return true;
}

static inline bool N60ProgramTransportReadFlattenedSample(
    const AudioBufferList * _Nonnull bufferList,
    uint32_t flattenedChannel,
    uint32_t frameIndex,
    float * _Nonnull sampleOut
) {
    if (bufferList == NULL || sampleOut == NULL) return false;
    uint32_t remaining = flattenedChannel;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mNumberChannels == 0u) continue;
        if (remaining >= buffer->mNumberChannels) {
            remaining -= buffer->mNumberChannels;
            continue;
        }
        if (buffer->mData == NULL) return false;
        const uint64_t sampleIndex = (uint64_t)frameIndex * buffer->mNumberChannels + remaining;
        const uint64_t requiredBytes = (sampleIndex + 1u) * sizeof(float);
        if (requiredBytes > buffer->mDataByteSize) return false;
        *sampleOut = ((const float *)buffer->mData)[sampleIndex];
        return true;
    }
    return false;
}

static inline bool N60ProgramTransportWriteFlattenedSample(
    AudioBufferList * _Nonnull bufferList,
    uint32_t flattenedChannel,
    uint32_t frameIndex,
    float sample
) {
    if (bufferList == NULL) return false;
    uint32_t remaining = flattenedChannel;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mNumberChannels == 0u) continue;
        if (remaining >= buffer->mNumberChannels) {
            remaining -= buffer->mNumberChannels;
            continue;
        }
        if (buffer->mData == NULL) return false;
        const uint64_t sampleIndex = (uint64_t)frameIndex * buffer->mNumberChannels + remaining;
        const uint64_t requiredBytes = (sampleIndex + 1u) * sizeof(float);
        if (requiredBytes > buffer->mDataByteSize) return false;
        ((float *)buffer->mData)[sampleIndex] = sample;
        return true;
    }
    return false;
}

static inline bool N60ProgramTransportZeroOutputFrame(
    AudioBufferList * _Nonnull bufferList,
    uint32_t frameIndex
) {
    if (bufferList == NULL || bufferList->mNumberBuffers == 0u) return false;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0u) return false;
        const uint64_t base = (uint64_t)frameIndex * buffer->mNumberChannels;
        const uint64_t requiredBytes = (base + buffer->mNumberChannels) * sizeof(float);
        if (requiredBytes > buffer->mDataByteSize) return false;
        float *samples = (float *)buffer->mData;
        for (UInt32 channel = 0; channel < buffer->mNumberChannels; ++channel) {
            samples[base + channel] = 0.0f;
        }
    }
    return true;
}

/// Reads one Core Audio frame in stream order and losslessly reorders it into
/// Notch Sixty's canonical semantic layout. No mixing/downmixing occurs here.
static inline bool N60ProgramInputMapReadFrame(
    const N60ProgramInputMap * _Nonnull map,
    const AudioBufferList * _Nonnull inputData,
    uint32_t frameIndex,
    N60ProgramTransportFrame * _Nonnull canonicalFrameOut
) {
    if (map == NULL || inputData == NULL || canonicalFrameOut == NULL || !map->valid) return false;
    float stream[N60_MAX_PROGRAM_CHANNELS] = {0};
    float canonical[N60_MAX_PROGRAM_CHANNELS] = {0};
    for (uint32_t channel = 0; channel < map->streamChannelCount; ++channel) {
        if (!N60ProgramTransportReadFlattenedSample(inputData, channel, frameIndex, &stream[channel])) {
            return false;
        }
        if (!isfinite(stream[channel])) stream[channel] = 0.0f;
    }
    if (!N60ChannelRoutingMatrixProcessFrame(&map->streamToCanonical, stream, canonical)) return false;
    *canonicalFrameOut = (N60ProgramTransportFrame){0};
    memcpy(
        canonicalFrameOut->channels,
        canonical,
        map->canonicalLayout.channelCount * sizeof(float)
    );
    return true;
}

/// Writes one canonical semantic frame to explicitly mapped physical channels.
/// Every channel represented by the callback frame is silenced first so unused
/// hardware outputs never retain stale samples.
static inline bool N60ProgramOutputMapWriteFrame(
    const N60ProgramOutputMap * _Nonnull map,
    const N60ProgramTransportFrame * _Nonnull canonicalFrame,
    AudioBufferList * _Nonnull outputData,
    uint32_t frameIndex
) {
    if (map == NULL || canonicalFrame == NULL || outputData == NULL || !map->valid) return false;
    if (!N60ProgramTransportZeroOutputFrame(outputData, frameIndex)) return false;
    for (uint32_t program = 0; program < map->canonicalLayout.channelCount; ++program) {
        const uint32_t physical = map->physicalChannelForProgram[program];
        if (physical == N60_PROGRAM_OUTPUT_CHANNEL_UNMAPPED
            || physical >= map->physicalChannelCount
            || !N60ProgramTransportWriteFlattenedSample(
                outputData,
                physical,
                frameIndex,
                canonicalFrame->channels[program])) {
            return false;
        }
    }
    return true;
}

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

/// Control-plane reset only; callbacks must be stopped.
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

/// Realtime producer primitive for the capture callback. It never overwrites
/// unread frames; excess input is dropped and counted, matching the current
/// stereo bridge's bounded SPSC policy.
static inline uint32_t N60ProgramTransportCaptureBuffer(
    N60ProgramTransport * _Nonnull transport,
    const N60ProgramInputMap * _Nonnull inputMap,
    const AudioBufferList * _Nonnull inputData
) {
    if (transport == NULL
        || inputMap == NULL
        || inputData == NULL
        || transport->frames == NULL
        || !inputMap->valid
        || inputMap->canonicalLayout.channelCount != transport->canonicalLayout.channelCount) {
        return 0u;
    }
    for (uint32_t channel = 0; channel < transport->canonicalLayout.channelCount; ++channel) {
        if (inputMap->canonicalLayout.channels[channel] != transport->canonicalLayout.channels[channel]) return 0u;
    }

    uint32_t frameCount = 0u;
    if (!N60ProgramTransportBufferFrameCount(
            inputData,
            inputMap->streamChannelCount,
            &frameCount)) {
        atomic_fetch_add_explicit(&transport->unsupportedBufferLayouts, 1u, memory_order_relaxed);
        return 0u;
    }

    const uint64_t writeIndex = atomic_load_explicit(&transport->writeIndex, memory_order_relaxed);
    const uint64_t readIndex = atomic_load_explicit(&transport->readIndex, memory_order_acquire);
    const uint64_t used = writeIndex >= readIndex ? writeIndex - readIndex : transport->capacityFrames;
    const uint64_t available = used < transport->capacityFrames
        ? transport->capacityFrames - used
        : 0u;
    const uint32_t framesToWrite = frameCount < available ? frameCount : (uint32_t)available;
    uint32_t ringIndex = (uint32_t)(writeIndex % transport->capacityFrames);

    for (uint32_t frame = 0; frame < framesToWrite; ++frame) {
        N60ProgramTransportFrame canonical = {0};
        if (!N60ProgramInputMapReadFrame(inputMap, inputData, frame, &canonical)) {
            atomic_fetch_add_explicit(&transport->unsupportedBufferLayouts, 1u, memory_order_relaxed);
            break;
        }
        transport->frames[ringIndex] = canonical;
        ringIndex += 1u;
        if (ringIndex == transport->capacityFrames) ringIndex = 0u;
    }

    atomic_store_explicit(&transport->writeIndex, writeIndex + framesToWrite, memory_order_release);
    atomic_fetch_add_explicit(&transport->capturedFrames, framesToWrite, memory_order_relaxed);
    if (framesToWrite < frameCount) {
        atomic_fetch_add_explicit(
            &transport->overrunFrames,
            frameCount - framesToWrite,
            memory_order_relaxed
        );
    }
    return framesToWrite;
}

/// Realtime consumer primitive used by the future N-channel output callback.
/// The caller owns DSP processing between dequeue and `N60ProgramOutputMapWriteFrame`.
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
