#ifndef N60BinauralHeadphoneBridge_h
#define N60BinauralHeadphoneBridge_h

#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60ProgramTransport.h"
#include "N60AudioUnitLiveRackBridge.h"
#include "N60HeadTrackedBinauralRuntime.h"
#include "N60HeadphoneDSP.h"
#include "N60Protection.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool enabled;
    float peakLeft;
    float peakRight;
    float rmsLeft;
    float rmsRight;
    uint64_t overRangeLeft;
    uint64_t overRangeRight;
} N60BinauralHeadphoneMeterSnapshot;

typedef struct {
    uint64_t captureCallbacks;
    uint64_t outputCallbacks;
    uint64_t renderedFrames;
    uint64_t renderFailures;
    uint64_t outputWriteFailures;
    uint64_t gatedOutputCallbacks;
    uint64_t gatedOutputFrames;
    bool outputGateOpen;
    uint64_t algorithmicLatencyFrames;
    N60ProgramTransportSnapshot transport;
    N60ProtectionTelemetry protection;
    N60HeadTrackedBinauralSnapshot headTracking;
    N60BinauralHeadphoneMeterSnapshot meter;
} N60BinauralHeadphoneBridgeSnapshot;

typedef struct N60BinauralHeadphoneBridge {
    N60ProgramTransport * _Nullable transport;
    N60HeadTrackedBinauralRuntime * _Nullable binauralRuntime;
    N60HeadphoneDSPRuntime * _Nullable headphoneRuntime;
    N60ProtectionRuntime * _Nullable protectionRuntime;
    N60AudioUnitLiveRackProcessor audioUnitRack;
    float * _Nullable audioUnitRackScratch;
    N60ProgramInputMap inputMap;
    N60BinauralProfileDescriptor binauralDescriptor;
    N60HeadphoneDSPSnapshot headphoneSnapshot;
    N60ProtectionSnapshot protectionSnapshot;
    float programGainLinear;

    uint32_t outputGateMinimumBufferedFrames;
    uint32_t startupFadeFrames;
    uint32_t startupFadeRemaining;

    _Atomic bool outputGateOpen;
    _Atomic uint32_t outputGainBits;
    _Atomic bool meteringDemand;
    _Atomic uint32_t meterPeakLeftBits;
    _Atomic uint32_t meterPeakRightBits;
    _Atomic uint32_t meterRMSLeftBits;
    _Atomic uint32_t meterRMSRightBits;
    _Atomic uint64_t meterOverRangeLeft;
    _Atomic uint64_t meterOverRangeRight;
    _Atomic uint64_t captureCallbacks;
    _Atomic uint64_t outputCallbacks;
    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t renderFailures;
    _Atomic uint64_t outputWriteFailures;
    _Atomic uint64_t gatedOutputCallbacks;
    _Atomic uint64_t gatedOutputFrames;
} N60BinauralHeadphoneBridge;

static inline uint32_t N60BinauralHeadphoneFloatToBits(float value) {
    uint32_t bits = 0u;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline float N60BinauralHeadphoneBitsToFloat(uint32_t bits) {
    float value = 0.0f;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static inline void N60BinauralHeadphoneBridgeClearMeterPublication(
    N60BinauralHeadphoneBridge * _Nullable bridge
) {
    if (bridge == NULL) return;
    atomic_store_explicit(&bridge->meterPeakLeftBits, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->meterPeakRightBits, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->meterRMSLeftBits, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->meterRMSRightBits, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->meterOverRangeLeft, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->meterOverRangeRight, 0u, memory_order_relaxed);
}

static inline float N60BinauralHeadphoneClampGain(float gain) {
    if (!isfinite(gain) || gain < 0.0f) return 0.0f;
    return gain > 1.0f ? 1.0f : gain;
}

static inline bool N60BinauralHeadphoneInputMapMatchesDescriptor(
    const N60ProgramInputMap * _Nullable inputMap,
    const N60BinauralProfileDescriptor * _Nullable descriptor
) {
    if (inputMap == NULL || descriptor == NULL || !inputMap->valid
        || !N60ProgramChannelLayoutIsValid(&descriptor->programLayout)
        || inputMap->canonicalLayout.channelCount != descriptor->programLayout.channelCount) {
        return false;
    }
    for (uint32_t channel = 0; channel < descriptor->programLayout.channelCount; ++channel) {
        if (inputMap->canonicalLayout.channels[channel]
            != descriptor->programLayout.channels[channel]) {
            return false;
        }
    }
    return true;
}

/// Control-plane creation only. The channel-major IR arrays contain exactly
/// `programLayout.channelCount * tapCount` samples per ear. All allocation,
/// FFT-kernel preparation and runtime reset happen here before callbacks start.
static inline N60BinauralHeadphoneBridge * _Nullable N60BinauralHeadphoneBridgeCreate(
    uint32_t transportCapacityFrames,
    N60ProgramInputMap inputMap,
    N60BinauralProfileDescriptor binauralDescriptor,
    const float * _Nonnull leftIRs,
    const float * _Nonnull rightIRs,
    N60HeadphoneDSPSnapshot headphoneSnapshot,
    N60ProtectionSnapshot protectionSnapshot,
    float programGainLinear,
    uint32_t outputGateMinimumBufferedFrames,
    uint32_t startupFadeFrames
) {
    if (transportCapacityFrames == 0u
        || outputGateMinimumBufferedFrames > transportCapacityFrames
        || leftIRs == NULL
        || rightIRs == NULL
        || !N60BinauralProfileDescriptorIsValid(
            &binauralDescriptor, N60_BINAURAL_MAX_TAPS
        )
        || !N60BinauralHeadphoneInputMapMatchesDescriptor(
            &inputMap, &binauralDescriptor
        )
        || !N60HeadphoneDSPSnapshotIsValid(&headphoneSnapshot)
        || fabs(headphoneSnapshot.sampleRate - binauralDescriptor.sampleRate) >= 0.5
        || !N60ProtectionSnapshotIsValid(&protectionSnapshot)
        || fabs(protectionSnapshot.sampleRate - binauralDescriptor.sampleRate) >= 0.5
        || !isfinite(programGainLinear) || programGainLinear < 0.0f || programGainLinear > 16.0f) {
        return NULL;
    }

    N60BinauralHeadphoneBridge * _Nullable bridge =
        (N60BinauralHeadphoneBridge *)calloc(1u, sizeof(N60BinauralHeadphoneBridge));
    if (bridge == NULL) return NULL;

    bridge->transport = N60ProgramTransportCreate(
        transportCapacityFrames, binauralDescriptor.programLayout
    );
    bridge->binauralRuntime = N60HeadTrackedBinauralRuntimeCreate(
        binauralDescriptor, leftIRs, rightIRs
    );
    bridge->headphoneRuntime = N60HeadphoneDSPRuntimeCreate();
    bridge->protectionRuntime = N60ProtectionRuntimeCreate();

    if (bridge->transport == NULL
        || bridge->binauralRuntime == NULL
        || bridge->headphoneRuntime == NULL
        || bridge->protectionRuntime == NULL
        || !N60HeadphoneDSPRuntimePrepare(
            bridge->headphoneRuntime, &headphoneSnapshot
        )) {
        N60ProgramTransportDestroy(bridge->transport);
        N60HeadTrackedBinauralRuntimeDestroy(bridge->binauralRuntime);
        N60HeadphoneDSPRuntimeDestroy(bridge->headphoneRuntime);
        N60ProtectionRuntimeDestroy(bridge->protectionRuntime);
        free(bridge);
        return NULL;
    }

    bridge->inputMap = inputMap;
    bridge->binauralDescriptor = binauralDescriptor;
    bridge->headphoneSnapshot = headphoneSnapshot;
    bridge->protectionSnapshot = protectionSnapshot;
    bridge->programGainLinear = programGainLinear;
    bridge->outputGateMinimumBufferedFrames = outputGateMinimumBufferedFrames;
    bridge->startupFadeFrames = startupFadeFrames;
    bridge->startupFadeRemaining = 0u;
    atomic_store_explicit(
        &bridge->outputGateOpen,
        outputGateMinimumBufferedFrames == 0u,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &bridge->outputGainBits,
        N60BinauralHeadphoneFloatToBits(1.0f),
        memory_order_relaxed
    );
    return bridge;
}

static inline void N60BinauralHeadphoneBridgeDestroy(
    N60BinauralHeadphoneBridge * _Nullable bridge
) {
    if (bridge == NULL) return;
    N60ProgramTransportDestroy(bridge->transport);
    N60HeadTrackedBinauralRuntimeDestroy(bridge->binauralRuntime);
    N60HeadphoneDSPRuntimeDestroy(bridge->headphoneRuntime);
    N60ProtectionRuntimeDestroy(bridge->protectionRuntime);
    free(bridge->audioUnitRackScratch);
    bridge->transport = NULL;
    bridge->binauralRuntime = NULL;
    bridge->headphoneRuntime = NULL;
    bridge->protectionRuntime = NULL;
    free(bridge);
}

/// Control-plane reset only; producer and consumer callbacks must be stopped.
static inline bool N60BinauralHeadphoneBridgeReset(
    N60BinauralHeadphoneBridge * _Nonnull bridge
) {
    if (bridge == NULL
        || bridge->transport == NULL
        || bridge->binauralRuntime == NULL
        || bridge->headphoneRuntime == NULL
        || bridge->protectionRuntime == NULL
        || !N60HeadphoneDSPRuntimePrepare(
            bridge->headphoneRuntime, &bridge->headphoneSnapshot
        )) {
        return false;
    }
    N60ProgramTransportReset(bridge->transport);
    if (!N60HeadTrackedBinauralRuntimeReset(bridge->binauralRuntime)) return false;
    N60ProtectionRuntimeReset(bridge->protectionRuntime);
    bridge->startupFadeRemaining = 0u;
    atomic_store_explicit(
        &bridge->outputGateOpen,
        bridge->outputGateMinimumBufferedFrames == 0u,
        memory_order_release
    );
    atomic_store_explicit(&bridge->captureCallbacks, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputCallbacks, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->renderedFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->renderFailures, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->outputWriteFailures, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->gatedOutputCallbacks, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->gatedOutputFrames, 0u, memory_order_relaxed);
    atomic_store_explicit(&bridge->meteringDemand, false, memory_order_release);
    N60BinauralHeadphoneBridgeClearMeterPublication(bridge);
    return true;
}

static inline bool N60BinauralHeadphoneBridgeConfigureAudioUnitRack(
    N60BinauralHeadphoneBridge * _Nonnull bridge,
    N60AudioUnitLiveRackProcessor processor
) {
    if (bridge == NULL
        || bridge->transport == NULL
        || bridge->audioUnitRack.context != NULL
        || !N60AudioUnitLiveRackProcessorIsValid(&processor)
        || processor.channelCount
            != bridge->binauralDescriptor.programLayout.channelCount
        || processor.maximumFramesPerSlice
            > bridge->transport->capacityFrames) {
        return false;
    }

    const size_t sampleCount =
        (size_t)bridge->transport->capacityFrames
        * bridge->binauralDescriptor.programLayout.channelCount;
    float *scratch = (float *)calloc(
        sampleCount,
        sizeof(float)
    );
    if (scratch == NULL) return false;

    bridge->audioUnitRack = processor;
    bridge->audioUnitRackScratch = scratch;
    return true;
}

static inline void N60BinauralHeadphoneBridgeSetOutputGain(
    N60BinauralHeadphoneBridge * _Nullable bridge,
    float gain
) {
    if (bridge == NULL) return;
    atomic_store_explicit(
        &bridge->outputGainBits,
        N60BinauralHeadphoneFloatToBits(N60BinauralHeadphoneClampGain(gain)),
        memory_order_release
    );
}

static inline void N60BinauralHeadphoneBridgeSetMeteringDemand(
    N60BinauralHeadphoneBridge * _Nullable bridge, bool enabled
) {
    if (bridge == NULL) return;
    if (enabled) {
        N60BinauralHeadphoneBridgeClearMeterPublication(bridge);
        atomic_store_explicit(&bridge->meteringDemand, true, memory_order_release);
    } else {
        atomic_store_explicit(&bridge->meteringDemand, false, memory_order_release);
        N60BinauralHeadphoneBridgeClearMeterPublication(bridge);
    }
}

static inline N60BinauralHeadphoneMeterSnapshot N60BinauralHeadphoneBridgeGetMeterSnapshot(
    const N60BinauralHeadphoneBridge * _Nullable bridge
) {
    if (bridge == NULL) return (N60BinauralHeadphoneMeterSnapshot){0};
    return (N60BinauralHeadphoneMeterSnapshot){
        .enabled = atomic_load_explicit(&bridge->meteringDemand, memory_order_acquire),
        .peakLeft = N60BinauralHeadphoneBitsToFloat(atomic_load_explicit(&bridge->meterPeakLeftBits, memory_order_relaxed)),
        .peakRight = N60BinauralHeadphoneBitsToFloat(atomic_load_explicit(&bridge->meterPeakRightBits, memory_order_relaxed)),
        .rmsLeft = N60BinauralHeadphoneBitsToFloat(atomic_load_explicit(&bridge->meterRMSLeftBits, memory_order_relaxed)),
        .rmsRight = N60BinauralHeadphoneBitsToFloat(atomic_load_explicit(&bridge->meterRMSRightBits, memory_order_relaxed)),
        .overRangeLeft = atomic_load_explicit(&bridge->meterOverRangeLeft, memory_order_relaxed),
        .overRangeRight = atomic_load_explicit(&bridge->meterOverRangeRight, memory_order_relaxed),
    };
}

static inline bool N60BinauralHeadphoneBridgeCanPrepareTrackedGeneration(
    const N60BinauralHeadphoneBridge * _Nullable bridge
) {
    return bridge != NULL
        && bridge->binauralRuntime != NULL
        && N60HeadTrackedBinauralRuntimeCanPrepareGeneration(bridge->binauralRuntime);
}

static inline bool N60BinauralHeadphoneBridgePrepareTrackedGeneration(
    N60BinauralHeadphoneBridge * _Nonnull bridge,
    N60BinauralProfileDescriptor descriptor,
    const float * _Nonnull leftIRs,
    const float * _Nonnull rightIRs,
    N60HeadPose pose,
    uint32_t warmupFrames,
    uint32_t crossfadeFrames
) {
    if (bridge == NULL || bridge->binauralRuntime == NULL) return false;
    return N60HeadTrackedBinauralRuntimePrepareGeneration(
        bridge->binauralRuntime,
        descriptor,
        leftIRs,
        rightIRs,
        pose,
        warmupFrames,
        crossfadeFrames
    );
}

static inline uint64_t N60BinauralHeadphoneBridgeLatencyFrames(
    const N60BinauralHeadphoneBridge * _Nullable bridge
) {
    if (bridge == NULL || bridge->binauralRuntime == NULL) return 0u;
    const uint64_t correctionDelay = bridge->headphoneSnapshot.channels[0].delayFrames
        > bridge->headphoneSnapshot.channels[1].delayFrames
        ? bridge->headphoneSnapshot.channels[0].delayFrames
        : bridge->headphoneSnapshot.channels[1].delayFrames;
    return (N60AudioUnitLiveRackProcessorIsValid(&bridge->audioUnitRack)
            ? bridge->audioUnitRack.latencyFrames
            : 0u)
        + N60HeadTrackedBinauralRuntimeLatencyFrames(bridge->binauralRuntime)
        + correctionDelay
        + (uint64_t)N60ProtectionSnapshotLatencyFrames(&bridge->protectionSnapshot);
}

static inline N60BinauralHeadphoneBridgeSnapshot N60BinauralHeadphoneBridgeGetSnapshot(
    const N60BinauralHeadphoneBridge * _Nullable bridge
) {
    if (bridge == NULL) return (N60BinauralHeadphoneBridgeSnapshot){0};
    return (N60BinauralHeadphoneBridgeSnapshot){
        .captureCallbacks = atomic_load_explicit(&bridge->captureCallbacks, memory_order_relaxed),
        .outputCallbacks = atomic_load_explicit(&bridge->outputCallbacks, memory_order_relaxed),
        .renderedFrames = atomic_load_explicit(&bridge->renderedFrames, memory_order_relaxed),
        .renderFailures = atomic_load_explicit(&bridge->renderFailures, memory_order_relaxed),
        .outputWriteFailures = atomic_load_explicit(&bridge->outputWriteFailures, memory_order_relaxed),
        .gatedOutputCallbacks = atomic_load_explicit(
            &bridge->gatedOutputCallbacks, memory_order_relaxed
        ),
        .gatedOutputFrames = atomic_load_explicit(
            &bridge->gatedOutputFrames, memory_order_relaxed
        ),
        .outputGateOpen = atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire),
        .algorithmicLatencyFrames = N60BinauralHeadphoneBridgeLatencyFrames(bridge),
        .transport = N60ProgramTransportGetSnapshot(bridge->transport),
        .protection = N60ProtectionRuntimeTelemetry(bridge->protectionRuntime),
        .headTracking = N60HeadTrackedBinauralRuntimeGetSnapshot(bridge->binauralRuntime),
        .meter = N60BinauralHeadphoneBridgeGetMeterSnapshot(bridge),
    };
}

static inline void N60BinauralHeadphoneZeroOutput(
    AudioBufferList * _Nullable outputData
) {
    if (outputData == NULL) return;
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0u) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static inline bool N60BinauralHeadphoneWriteStereoFrame(
    AudioBufferList * _Nonnull outputData,
    uint32_t frameIndex,
    float left,
    float right
) {
    if (outputData == NULL || !N60ProgramTransportZeroOutputFrame(outputData, frameIndex)) {
        return false;
    }
    return N60ProgramTransportWriteFlattenedSample(
        outputData, 0u, frameIndex, isfinite(left) ? left : 0.0f
    ) && N60ProgramTransportWriteFlattenedSample(
        outputData, 1u, frameIndex, isfinite(right) ? right : 0.0f
    );
}

static inline float N60BinauralHeadphoneNextOutputGain(
    N60BinauralHeadphoneBridge * _Nonnull bridge,
    float masterGain
) {
    if (bridge == NULL || bridge->startupFadeRemaining == 0u
        || bridge->startupFadeFrames == 0u) {
        return masterGain;
    }
    const uint32_t completed = bridge->startupFadeFrames
        - bridge->startupFadeRemaining + 1u;
    const float fade = (float)completed / (float)bridge->startupFadeFrames;
    bridge->startupFadeRemaining -= 1u;
    return masterGain * fade;
}

static inline OSStatus N60BinauralHeadphoneCaptureIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)outOutputData;
    (void)inOutputTime;
    N60BinauralHeadphoneBridge *bridge = (N60BinauralHeadphoneBridge *)inClientData;
    if (bridge == NULL || bridge->transport == NULL || inInputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->captureCallbacks, 1u, memory_order_relaxed);
    (void)N60ProgramTransportCaptureBuffer(
        bridge->transport, &bridge->inputMap, inInputData
    );
    return noErr;
}

static inline OSStatus N60BinauralHeadphoneOutputIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
) {
    (void)inDevice;
    (void)inNow;
    (void)inInputData;
    (void)inInputTime;
    (void)inOutputTime;

    N60BinauralHeadphoneBridge *bridge = (N60BinauralHeadphoneBridge *)inClientData;
    if (bridge == NULL
        || bridge->transport == NULL
        || bridge->binauralRuntime == NULL
        || bridge->headphoneRuntime == NULL
        || bridge->protectionRuntime == NULL
        || outOutputData == NULL) {
        return noErr;
    }
    atomic_fetch_add_explicit(&bridge->outputCallbacks, 1u, memory_order_relaxed);

    uint32_t frameCount = 0u;
    if (!N60ProgramTransportBufferFrameCount(outOutputData, 2u, &frameCount)) {
        N60BinauralHeadphoneZeroOutput(outOutputData);
        atomic_fetch_add_explicit(&bridge->outputWriteFailures, 1u, memory_order_relaxed);
        return noErr;
    }

    const N60ProgramTransportSnapshot before =
        N60ProgramTransportGetSnapshot(bridge->transport);
    if (!atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire)) {
        if (before.bufferedFrames >= bridge->outputGateMinimumBufferedFrames
            && before.bufferedFrames >= frameCount) {
            bridge->startupFadeRemaining = bridge->startupFadeFrames;
            atomic_store_explicit(&bridge->outputGateOpen, true, memory_order_release);
        } else {
            N60BinauralHeadphoneZeroOutput(outOutputData);
            atomic_fetch_add_explicit(
                &bridge->gatedOutputCallbacks, 1u, memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &bridge->gatedOutputFrames, frameCount, memory_order_relaxed
            );
            return noErr;
        }
    }

    const float masterGain = N60BinauralHeadphoneBitsToFloat(
        atomic_load_explicit(&bridge->outputGainBits, memory_order_acquire)
    );
    const bool meterDemand = atomic_load_explicit(
        &bridge->meteringDemand, memory_order_acquire
    );
    float meterPeakLeft = 0.0f;
    float meterPeakRight = 0.0f;
    double meterSquareLeft = 0.0;
    double meterSquareRight = 0.0;
    uint64_t meterOverLeft = 0u;
    uint64_t meterOverRight = 0u;
    N60ProtectionRuntimeBeginBuffer(bridge->protectionRuntime);
    N60HeadTrackedBinauralRuntimeBeginBuffer(bridge->binauralRuntime);

    const uint32_t programChannels =
        bridge->binauralDescriptor.programLayout.channelCount;
    const bool rackConfigured =
        N60AudioUnitLiveRackProcessorIsValid(&bridge->audioUnitRack);

    if (rackConfigured) {
        if (frameCount > bridge->audioUnitRack.maximumFramesPerSlice
            || bridge->audioUnitRackScratch == NULL) {
            N60BinauralHeadphoneZeroOutput(outOutputData);
            atomic_fetch_add_explicit(
                &bridge->renderFailures, 1u, memory_order_relaxed
            );
            return noErr;
        }

        for (uint32_t frameIndex = 0;
             frameIndex < frameCount;
             ++frameIndex) {
            N60ProgramTransportFrame program = {0};
            (void)N60ProgramTransportDequeueFrame(
                bridge->transport,
                &program
            );
            float *destination =
                bridge->audioUnitRackScratch
                + (size_t)frameIndex * programChannels;
            for (uint32_t channel = 0;
                 channel < programChannels;
                 ++channel) {
                destination[channel] =
                    program.channels[channel]
                    * bridge->programGainLinear;
            }
        }

        const double sampleTime =
            inOutputTime != NULL
            && (inOutputTime->mFlags
                & kAudioTimeStampSampleTimeValid) != 0
                ? inOutputTime->mSampleTime
                : 0.0;
        if (!N60AudioUnitLiveRackProcess(
                &bridge->audioUnitRack,
                bridge->audioUnitRackScratch,
                bridge->audioUnitRackScratch,
                frameCount,
                programChannels,
                sampleTime)) {
            N60BinauralHeadphoneZeroOutput(outOutputData);
            atomic_fetch_add_explicit(
                &bridge->renderFailures, 1u, memory_order_relaxed
            );
            return noErr;
        }
    }

    for (uint32_t frameIndex = 0; frameIndex < frameCount; ++frameIndex) {
        N60ProgramTransportFrame program = {0};
        if (rackConfigured) {
            memcpy(
                program.channels,
                bridge->audioUnitRackScratch
                    + (size_t)frameIndex * programChannels,
                (size_t)programChannels * sizeof(float)
            );
        } else {
            (void)N60ProgramTransportDequeueFrame(
                bridge->transport,
                &program
            );
            for (uint32_t channel = 0;
                 channel < programChannels;
                 ++channel) {
                program.channels[channel] *=
                    bridge->programGainLinear;
            }
        }

        float left = 0.0f;
        float right = 0.0f;
        bool rendered = N60HeadTrackedBinauralRuntimeProcessFrame(
            bridge->binauralRuntime,
            program.channels,
            bridge->binauralDescriptor.programLayout.channelCount,
            &left,
            &right
        );
        if (rendered) {
            float correctedLeft = 0.0f;
            float correctedRight = 0.0f;
            rendered = N60HeadphoneDSPProcessStereoFrame(
                bridge->headphoneRuntime,
                &bridge->headphoneSnapshot,
                left,
                right,
                &correctedLeft,
                &correctedRight
            );
            left = correctedLeft;
            right = correctedRight;
        }
        if (!rendered) {
            left = 0.0f;
            right = 0.0f;
            atomic_fetch_add_explicit(
                &bridge->renderFailures, 1u, memory_order_relaxed
            );
        }

        N60ProtectionProcessStereoFrame(
            bridge->protectionRuntime, &bridge->protectionSnapshot, &left, &right
        );
        const float gain = N60BinauralHeadphoneNextOutputGain(bridge, masterGain);
        left *= gain;
        right *= gain;
        if (meterDemand) {
            const float leftMagnitude = fabsf(left);
            const float rightMagnitude = fabsf(right);
            if (leftMagnitude > meterPeakLeft) meterPeakLeft = leftMagnitude;
            if (rightMagnitude > meterPeakRight) meterPeakRight = rightMagnitude;
            meterSquareLeft += (double)left * (double)left;
            meterSquareRight += (double)right * (double)right;
            if (leftMagnitude > 1.0f) meterOverLeft += 1u;
            if (rightMagnitude > 1.0f) meterOverRight += 1u;
        }

        if (!N60BinauralHeadphoneWriteStereoFrame(
                outOutputData, frameIndex, left, right)) {
            N60BinauralHeadphoneZeroOutput(outOutputData);
            atomic_fetch_add_explicit(
                &bridge->outputWriteFailures, 1u, memory_order_relaxed
            );
            return noErr;
        }
        atomic_fetch_add_explicit(&bridge->renderedFrames, 1u, memory_order_relaxed);
    }
    if (meterDemand && frameCount > 0u) {
        atomic_store_explicit(&bridge->meterPeakLeftBits, N60BinauralHeadphoneFloatToBits(meterPeakLeft), memory_order_relaxed);
        atomic_store_explicit(&bridge->meterPeakRightBits, N60BinauralHeadphoneFloatToBits(meterPeakRight), memory_order_relaxed);
        atomic_store_explicit(&bridge->meterRMSLeftBits, N60BinauralHeadphoneFloatToBits((float)sqrt(meterSquareLeft / (double)frameCount)), memory_order_relaxed);
        atomic_store_explicit(&bridge->meterRMSRightBits, N60BinauralHeadphoneFloatToBits((float)sqrt(meterSquareRight / (double)frameCount)), memory_order_relaxed);
        atomic_fetch_add_explicit(&bridge->meterOverRangeLeft, meterOverLeft, memory_order_relaxed);
        atomic_fetch_add_explicit(&bridge->meterOverRangeRight, meterOverRight, memory_order_relaxed);
    }
    return noErr;
}

#ifdef __cplusplus
}
#endif

#endif
