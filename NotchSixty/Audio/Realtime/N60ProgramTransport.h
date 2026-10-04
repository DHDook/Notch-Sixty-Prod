#ifndef N60ProgramTransport_h
#define N60ProgramTransport_h

#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "N60ChannelRouter.h"
#include "N60CoreAudioChannelMapping.h"
#include "N60ProgramTransportCore.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_PROGRAM_OUTPUT_CHANNEL_UNMAPPED UINT32_MAX

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

/// Extra hardware channels are allowed and remain silent, but every canonical
/// semantic program role must appear exactly once. Unknown labels are never guessed.
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

    bool roleSeen[N60_MAX_PROGRAM_CHANNELS + 1u] = {false};
    for (uint32_t physical = 0; physical < physicalChannelCount; ++physical) {
        const N60ProgramChannelRole role = N60ProgramChannelRoleFromAudioChannelLabel(
            physicalDescriptions[physical].mChannelLabel
        );
        if (!N60ProgramChannelRoleIsSemantic(role)) continue;
        const uint32_t roleIndex = (uint32_t)role;
        if (roleIndex > N60_MAX_PROGRAM_CHANNELS || roleSeen[roleIndex]) return false;
        roleSeen[roleIndex] = true;
        const int32_t program = N60ProgramChannelLayoutIndexOfRole(&canonicalLayout, role);
        if (program >= 0) result.physicalChannelForProgram[(uint32_t)program] = physical;
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
        || requiredFlattenedChannels == 0u) return false;

    uint64_t flattenedChannels = 0u;
    uint32_t frameCount = UINT32_MAX;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferList->mNumberBuffers; ++bufferIndex) {
        const AudioBuffer *buffer = &bufferList->mBuffers[bufferIndex];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0u) return false;
        const uint64_t bytesPerFrame = (uint64_t)sizeof(float) * buffer->mNumberChannels;
        if (((uint64_t)buffer->mDataByteSize % bytesPerFrame) != 0u) return false;
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
        if (remaining >= buffer->mNumberChannels) {
            remaining -= buffer->mNumberChannels;
            continue;
        }
        if (buffer->mData == NULL || buffer->mNumberChannels == 0u) return false;
        const uint64_t sampleIndex = (uint64_t)frameIndex * buffer->mNumberChannels + remaining;
        if ((sampleIndex + 1u) * sizeof(float) > buffer->mDataByteSize) return false;
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
        if (remaining >= buffer->mNumberChannels) {
            remaining -= buffer->mNumberChannels;
            continue;
        }
        if (buffer->mData == NULL || buffer->mNumberChannels == 0u) return false;
        const uint64_t sampleIndex = (uint64_t)frameIndex * buffer->mNumberChannels + remaining;
        if ((sampleIndex + 1u) * sizeof(float) > buffer->mDataByteSize) return false;
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
        if ((base + buffer->mNumberChannels) * sizeof(float) > buffer->mDataByteSize) return false;
        float *samples = (float *)buffer->mData;
        for (UInt32 channel = 0; channel < buffer->mNumberChannels; ++channel) {
            samples[base + channel] = 0.0f;
        }
    }
    return true;
}

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
    memcpy(canonicalFrameOut->channels, canonical, map->canonicalLayout.channelCount * sizeof(float));
    return true;
}

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
                outputData, physical, frameIndex, canonicalFrame->channels[program])) {
            return false;
        }
    }
    return true;
}

/// Realtime capture adapter. Ring indices are latched/published once per callback,
/// matching the existing stereo bridge rather than paying atomic traffic per frame.
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
        || !N60ProgramTransportLayoutMatches(transport, &inputMap->canonicalLayout)) {
        return 0u;
    }

    uint32_t frameCount = 0u;
    if (!N60ProgramTransportBufferFrameCount(inputData, inputMap->streamChannelCount, &frameCount)) {
        N60ProgramTransportRecordUnsupportedBufferLayout(transport);
        return 0u;
    }

    const uint64_t writeIndex = atomic_load_explicit(&transport->writeIndex, memory_order_relaxed);
    const uint64_t readIndex = atomic_load_explicit(&transport->readIndex, memory_order_acquire);
    const uint64_t used = writeIndex >= readIndex ? writeIndex - readIndex : transport->capacityFrames;
    const uint64_t available = used < transport->capacityFrames
        ? transport->capacityFrames - used
        : 0u;
    const uint32_t requested = frameCount < available ? frameCount : (uint32_t)available;
    uint32_t written = 0u;
    uint32_t ringIndex = (uint32_t)(writeIndex % transport->capacityFrames);
    for (; written < requested; ++written) {
        N60ProgramTransportFrame canonical = {0};
        if (!N60ProgramInputMapReadFrame(inputMap, inputData, written, &canonical)) {
            N60ProgramTransportRecordUnsupportedBufferLayout(transport);
            break;
        }
        transport->frames[ringIndex] = canonical;
        ringIndex += 1u;
        if (ringIndex == transport->capacityFrames) ringIndex = 0u;
    }

    atomic_store_explicit(&transport->writeIndex, writeIndex + written, memory_order_release);
    atomic_fetch_add_explicit(&transport->capturedFrames, written, memory_order_relaxed);
    if (written < frameCount) {
        atomic_fetch_add_explicit(&transport->overrunFrames, frameCount - written, memory_order_relaxed);
    }
    return written;
}

#ifdef __cplusplus
}
#endif

#endif
