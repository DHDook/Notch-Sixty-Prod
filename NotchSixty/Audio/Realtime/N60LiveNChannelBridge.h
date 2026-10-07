#ifndef N60LiveNChannelBridge_h
#define N60LiveNChannelBridge_h

#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60AdaptiveSampleRate.h"
#include "N60AudioUnitLiveRackBridge.h"
#include "N60LiveNChannelRenderCore.h"
#include "N60MIMOTreatmentLiveIntegration.h"
#include "N60ProgramTransport.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool enabled;
    uint32_t programChannelCount;
    uint32_t physicalChannelCount;
    float programPeak[N60_MAX_PROGRAM_CHANNELS];
    float programRMS[N60_MAX_PROGRAM_CHANNELS];
    uint64_t programOverRangeSamples[N60_MAX_PROGRAM_CHANNELS];
    float physicalPeak[N60_LIVE_MAX_PHYSICAL_CHANNELS];
    float physicalRMS[N60_LIVE_MAX_PHYSICAL_CHANNELS];
    uint64_t physicalOverRangeSamples[N60_LIVE_MAX_PHYSICAL_CHANNELS];
} N60LiveNChannelMeterSnapshot;

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
    bool adaptiveSampleRateEnabled;
    N60AdaptiveSRCSnapshot adaptiveSampleRate;
    uint64_t adaptiveTransportLatencyFrames;
    bool roomTreatmentConfigured;
    N60MIMOTreatmentLiveSnapshot roomTreatment;
    uint64_t roomTreatmentLatencyFrames;
    N60LiveNChannelMeterSnapshot meter;
} N60LiveNChannelBridgeSnapshot;

typedef struct N60LiveNChannelBridge {
    N60ProgramTransport * _Nullable transport;
    N60AdaptiveSRC * _Nullable adaptiveSRC;
    float * _Nullable adaptiveCaptureScratch;
    float * _Nullable adaptiveOutputScratch;
    N60LiveNChannelRenderRuntime * _Nullable renderRuntime;
    N60MIMOTreatmentLiveIntegration * _Nullable roomTreatment;
    N60AudioUnitLiveRackProcessor audioUnitRack;
    float * _Nullable audioUnitRackScratch;
    N60ProgramInputMap inputMap;
    N60LiveNChannelRenderGraph graph;

    uint32_t outputGateMinimumBufferedFrames;
    uint32_t startupFadeFrames;
    uint32_t startupFadeRemaining;

    _Atomic bool outputGateOpen;
    _Atomic uint32_t outputGainBits;
    _Atomic bool meteringDemand;
    _Atomic uint32_t meterProgramPeakBits[N60_MAX_PROGRAM_CHANNELS];
    _Atomic uint32_t meterProgramRMSBits[N60_MAX_PROGRAM_CHANNELS];
    _Atomic uint64_t meterProgramOverRangeSamples[N60_MAX_PROGRAM_CHANNELS];
    _Atomic uint32_t meterPhysicalPeakBits[N60_LIVE_MAX_PHYSICAL_CHANNELS];
    _Atomic uint32_t meterPhysicalRMSBits[N60_LIVE_MAX_PHYSICAL_CHANNELS];
    _Atomic uint64_t meterPhysicalOverRangeSamples[N60_LIVE_MAX_PHYSICAL_CHANNELS];
    _Atomic uint64_t captureCallbacks;
    _Atomic uint64_t outputCallbacks;
    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t renderFailures;
    _Atomic uint64_t outputWriteFailures;
    _Atomic uint64_t gatedOutputCallbacks;
    _Atomic uint64_t gatedOutputFrames;
} N60LiveNChannelBridge;

static inline uint32_t N60LiveNChannelFloatToBits(float value) {
    uint32_t bits = 0u;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline float N60LiveNChannelBitsToFloat(uint32_t bits) {
    float value = 0.0f;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static inline void N60LiveNChannelBridgeClearMeterPublication(
    N60LiveNChannelBridge * _Nullable bridge
) {
    if (bridge == NULL) return;
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        atomic_store_explicit(&bridge->meterProgramPeakBits[channel], 0u, memory_order_relaxed);
        atomic_store_explicit(&bridge->meterProgramRMSBits[channel], 0u, memory_order_relaxed);
        atomic_store_explicit(&bridge->meterProgramOverRangeSamples[channel], 0u, memory_order_relaxed);
    }
    for (uint32_t physical = 0; physical < N60_LIVE_MAX_PHYSICAL_CHANNELS; ++physical) {
        atomic_store_explicit(&bridge->meterPhysicalPeakBits[physical], 0u, memory_order_relaxed);
        atomic_store_explicit(&bridge->meterPhysicalRMSBits[physical], 0u, memory_order_relaxed);
        atomic_store_explicit(&bridge->meterPhysicalOverRangeSamples[physical], 0u, memory_order_relaxed);
    }
}

static inline float N60LiveNChannelClampOutputGain(float gain) {
    if (!isfinite(gain) || gain < 0.0f) return 0.0f;
    return gain > 1.0f ? 1.0f : gain;
}

static inline bool N60LiveNChannelInputMapMatchesGraph(
    const N60ProgramInputMap * _Nullable inputMap,
    const N60LiveNChannelRenderGraph * _Nullable graph
) {
    return inputMap != NULL
        && graph != NULL
        && inputMap->valid
        && N60LiveNChannelLayoutsEqual(&inputMap->canonicalLayout, &graph->programLayout);
}

/// Control-plane creation. The returned bridge is an opt-in live N-channel
/// callback engine; PR61 does not replace the shipping stereo bridge by default.
static inline N60LiveNChannelBridge * _Nullable N60LiveNChannelBridgeCreate(
    uint32_t transportCapacityFrames,
    N60ProgramInputMap inputMap,
    N60LiveNChannelRenderGraph graph,
    uint32_t outputGateMinimumBufferedFrames,
    uint32_t startupFadeFrames
) {
    if (transportCapacityFrames == 0u
        || outputGateMinimumBufferedFrames > transportCapacityFrames
        || !N60LiveNChannelRenderGraphIsValid(&graph)
        || !N60LiveNChannelInputMapMatchesGraph(&inputMap, &graph)) {
        return NULL;
    }

    N60LiveNChannelBridge * _Nullable bridge =
        (N60LiveNChannelBridge *)calloc(1u, sizeof(N60LiveNChannelBridge));
    if (bridge == NULL) return NULL;

    bridge->transport = N60ProgramTransportCreate(
        transportCapacityFrames,
        graph.programLayout
    );
    bridge->renderRuntime = N60LiveNChannelRenderRuntimeCreate();
    if (bridge->transport == NULL
        || bridge->renderRuntime == NULL
        || !N60LiveNChannelRenderRuntimePrepare(bridge->renderRuntime, &graph)) {
        N60ProgramTransportDestroy(bridge->transport);
        N60LiveNChannelRenderRuntimeDestroy(bridge->renderRuntime);
        free(bridge);
        return NULL;
    }

    bridge->inputMap = inputMap;
    bridge->graph = graph;
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
        N60LiveNChannelFloatToBits(1.0f),
        memory_order_relaxed
    );
    return bridge;
}

static inline void N60LiveNChannelBridgeDestroy(
    N60LiveNChannelBridge * _Nullable bridge
) {
    if (bridge == NULL) return;
    N60ProgramTransportDestroy(bridge->transport);
    N60AdaptiveSRCDestroy(bridge->adaptiveSRC);
    N60LiveNChannelRenderRuntimeDestroy(bridge->renderRuntime);
    N60MIMOTreatmentLiveIntegrationDestroy(bridge->roomTreatment);
    free(bridge->adaptiveCaptureScratch);
    free(bridge->adaptiveOutputScratch);
    free(bridge->audioUnitRackScratch);
    bridge->transport = NULL;
    bridge->renderRuntime = NULL;
    bridge->roomTreatment = NULL;
    free(bridge);
}

/// Control-plane reset. Producer/consumer callbacks must be stopped.
static inline bool N60LiveNChannelBridgeReset(
    N60LiveNChannelBridge * _Nonnull bridge
) {
    if (bridge == NULL
        || bridge->transport == NULL
        || bridge->renderRuntime == NULL
        || !N60LiveNChannelRenderRuntimePrepare(bridge->renderRuntime, &bridge->graph)) {
        return false;
    }
    N60ProgramTransportReset(bridge->transport);
    if (bridge->adaptiveSRC != NULL) {
        N60AdaptiveSRCReset(bridge->adaptiveSRC);
    }
    if (bridge->roomTreatment != NULL) {
        N60MIMOTreatmentLiveIntegrationReset(bridge->roomTreatment);
    }
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
    N60LiveNChannelBridgeClearMeterPublication(bridge);
    return true;
}

static inline bool N60LiveNChannelBridgeConfigureAdaptiveSampleRate(
    N60LiveNChannelBridge * _Nonnull bridge,
    double inputSampleRate,
    double outputSampleRate,
    uint32_t targetBufferedInputFrames
) {
    if (bridge == NULL
        || bridge->adaptiveSRC != NULL
        || !isfinite(inputSampleRate) || inputSampleRate <= 0.0
        || !isfinite(outputSampleRate) || outputSampleRate <= 0.0
        || bridge->graph.programLayout.channelCount == 0u
        || bridge->graph.programLayout.channelCount > N60_ADAPTIVE_SRC_MAX_CHANNELS) {
        return false;
    }
    if (fabs(inputSampleRate - outputSampleRate) < 0.5) return true;

    const uint32_t channels = bridge->graph.programLayout.channelCount;
    N60AdaptiveSRCConfiguration configuration = N60AdaptiveSRCConfigurationMakeDefault(
        inputSampleRate,
        outputSampleRate,
        channels,
        bridge->transport->capacityFrames,
        targetBufferedInputFrames
    );
    N60AdaptiveSRC *adaptiveSRC = N60AdaptiveSRCCreate(configuration);
    if (adaptiveSRC == NULL) return false;

    const size_t sampleCount = (size_t)bridge->transport->capacityFrames * channels;
    float *captureScratch = (float *)calloc(sampleCount, sizeof(float));
    float *outputScratch = (float *)calloc(sampleCount, sizeof(float));
    if (captureScratch == NULL || outputScratch == NULL) {
        free(captureScratch);
        free(outputScratch);
        N60AdaptiveSRCDestroy(adaptiveSRC);
        return false;
    }

    bridge->adaptiveSRC = adaptiveSRC;
    bridge->adaptiveCaptureScratch = captureScratch;
    bridge->adaptiveOutputScratch = outputScratch;
    return true;
}

static inline bool N60LiveNChannelBridgeAdaptiveSampleRateEnabled(
    const N60LiveNChannelBridge * _Nullable bridge
) {
    return bridge != NULL && bridge->adaptiveSRC != NULL;
}

static inline bool N60LiveNChannelBridgeConfigureAudioUnitRack(
    N60LiveNChannelBridge * _Nonnull bridge,
    N60AudioUnitLiveRackProcessor processor
) {
    if (bridge == NULL
        || bridge->transport == NULL
        || bridge->audioUnitRack.context != NULL
        || !N60AudioUnitLiveRackProcessorIsValid(&processor)
        || processor.channelCount
            != bridge->graph.programLayout.channelCount
        || processor.maximumFramesPerSlice
            > bridge->transport->capacityFrames) {
        return false;
    }

    const size_t sampleCount =
        (size_t)bridge->transport->capacityFrames
        * bridge->graph.programLayout.channelCount;
    float *scratch = (float *)calloc(
        sampleCount,
        sizeof(float)
    );
    if (scratch == NULL) return false;

    bridge->audioUnitRack = processor;
    bridge->audioUnitRackScratch = scratch;
    return true;
}

static inline bool N60LiveNChannelBridgeConfigureRoomTreatment(
    N60LiveNChannelBridge * _Nonnull bridge,
    uint32_t treatmentChannelCount,
    const uint32_t * _Nonnull treatmentPhysicalChannels,
    const float * _Nonnull taps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    uint32_t fadeFrames,
    uint32_t faultFadeFrames
) {
    if (bridge == NULL
        || bridge->roomTreatment != NULL
        || treatmentPhysicalChannels == NULL
        || taps == NULL) {
        return false;
    }
    N60MIMOTreatmentLiveIntegration *integration =
        N60MIMOTreatmentLiveIntegrationCreate(
            bridge->graph.outputMap.physicalChannelCount,
            treatmentChannelCount,
            treatmentPhysicalChannels,
            taps,
            tapCount,
            declaredLatencyFrames,
            fadeFrames,
            faultFadeFrames
        );
    if (integration == NULL) return false;
    bridge->roomTreatment = integration;
    return true;
}

static inline void N60LiveNChannelBridgeSetRoomTreatmentAuthorized(
    N60LiveNChannelBridge * _Nullable bridge,
    bool authorized
) {
    if (bridge == NULL || bridge->roomTreatment == NULL) return;
    N60MIMOTreatmentLiveSetAuthorized(
        bridge->roomTreatment,
        authorized
    );
}

static inline bool N60LiveNChannelBridgeRequestRoomTreatmentArm(
    N60LiveNChannelBridge * _Nullable bridge
) {
    return bridge != NULL
        && bridge->roomTreatment != NULL
        && N60MIMOTreatmentLiveRequestArm(bridge->roomTreatment);
}

static inline void N60LiveNChannelBridgeRequestRoomTreatmentBypass(
    N60LiveNChannelBridge * _Nullable bridge
) {
    if (bridge == NULL || bridge->roomTreatment == NULL) return;
    N60MIMOTreatmentLiveRequestBypass(bridge->roomTreatment);
}

static inline bool N60LiveNChannelBridgeLatchRoomTreatmentFault(
    N60LiveNChannelBridge * _Nullable bridge,
    N60MIMOTreatmentFault fault
) {
    return bridge != NULL
        && bridge->roomTreatment != NULL
        && N60MIMOTreatmentLiveLatchFault(
            bridge->roomTreatment,
            fault
        );
}

static inline void N60LiveNChannelBridgeRequestRoomTreatmentFaultClear(
    N60LiveNChannelBridge * _Nullable bridge
) {
    if (bridge == NULL || bridge->roomTreatment == NULL) return;
    N60MIMOTreatmentLiveRequestFaultClear(bridge->roomTreatment);
}

static inline void N60LiveNChannelBridgeSetOutputGain(
    N60LiveNChannelBridge * _Nullable bridge,
    float gain
) {
    if (bridge == NULL) return;
    atomic_store_explicit(
        &bridge->outputGainBits,
        N60LiveNChannelFloatToBits(N60LiveNChannelClampOutputGain(gain)),
        memory_order_release
    );
}

static inline void N60LiveNChannelBridgeSetMeteringDemand(
    N60LiveNChannelBridge * _Nullable bridge,
    bool enabled
) {
    if (bridge == NULL) return;
    if (enabled) {
        N60LiveNChannelBridgeClearMeterPublication(bridge);
        atomic_store_explicit(&bridge->meteringDemand, true, memory_order_release);
    } else {
        atomic_store_explicit(&bridge->meteringDemand, false, memory_order_release);
        N60LiveNChannelBridgeClearMeterPublication(bridge);
    }
}

static inline N60LiveNChannelMeterSnapshot N60LiveNChannelBridgeGetMeterSnapshot(
    const N60LiveNChannelBridge * _Nullable bridge
) {
    N60LiveNChannelMeterSnapshot result = {0};
    if (bridge == NULL) return result;
    result.enabled = atomic_load_explicit(&bridge->meteringDemand, memory_order_acquire);
    result.programChannelCount = bridge->graph.programLayout.channelCount;
    result.physicalChannelCount = bridge->graph.outputMap.physicalChannelCount;
    for (uint32_t channel = 0; channel < result.programChannelCount; ++channel) {
        result.programPeak[channel] = N60LiveNChannelBitsToFloat(atomic_load_explicit(
            &bridge->meterProgramPeakBits[channel], memory_order_relaxed
        ));
        result.programRMS[channel] = N60LiveNChannelBitsToFloat(atomic_load_explicit(
            &bridge->meterProgramRMSBits[channel], memory_order_relaxed
        ));
        result.programOverRangeSamples[channel] = atomic_load_explicit(
            &bridge->meterProgramOverRangeSamples[channel], memory_order_relaxed
        );
    }
    for (uint32_t physical = 0; physical < result.physicalChannelCount; ++physical) {
        result.physicalPeak[physical] = N60LiveNChannelBitsToFloat(atomic_load_explicit(
            &bridge->meterPhysicalPeakBits[physical], memory_order_relaxed
        ));
        result.physicalRMS[physical] = N60LiveNChannelBitsToFloat(atomic_load_explicit(
            &bridge->meterPhysicalRMSBits[physical], memory_order_relaxed
        ));
        result.physicalOverRangeSamples[physical] = atomic_load_explicit(
            &bridge->meterPhysicalOverRangeSamples[physical], memory_order_relaxed
        );
    }
    return result;
}

static inline float N60LiveNChannelMeterProgramPeak(
    const N60LiveNChannelMeterSnapshot * _Nullable meter, uint32_t channel
) {
    return meter != NULL && channel < meter->programChannelCount ? meter->programPeak[channel] : 0.0f;
}

static inline float N60LiveNChannelMeterProgramRMS(
    const N60LiveNChannelMeterSnapshot * _Nullable meter, uint32_t channel
) {
    return meter != NULL && channel < meter->programChannelCount ? meter->programRMS[channel] : 0.0f;
}

static inline uint64_t N60LiveNChannelMeterProgramOverRangeSamples(
    const N60LiveNChannelMeterSnapshot * _Nullable meter, uint32_t channel
) {
    return meter != NULL && channel < meter->programChannelCount
        ? meter->programOverRangeSamples[channel] : 0u;
}

static inline float N60LiveNChannelMeterPhysicalPeak(
    const N60LiveNChannelMeterSnapshot * _Nullable meter, uint32_t physical
) {
    return meter != NULL && physical < meter->physicalChannelCount ? meter->physicalPeak[physical] : 0.0f;
}

static inline float N60LiveNChannelMeterPhysicalRMS(
    const N60LiveNChannelMeterSnapshot * _Nullable meter, uint32_t physical
) {
    return meter != NULL && physical < meter->physicalChannelCount ? meter->physicalRMS[physical] : 0.0f;
}

static inline uint64_t N60LiveNChannelMeterPhysicalOverRangeSamples(
    const N60LiveNChannelMeterSnapshot * _Nullable meter, uint32_t physical
) {
    return meter != NULL && physical < meter->physicalChannelCount
        ? meter->physicalOverRangeSamples[physical] : 0u;
}

static inline N60LiveNChannelBridgeSnapshot N60LiveNChannelBridgeGetSnapshot(
    const N60LiveNChannelBridge * _Nullable bridge
) {
    if (bridge == NULL) return (N60LiveNChannelBridgeSnapshot){0};
    N60LiveNChannelBridgeSnapshot result = {
        .captureCallbacks = atomic_load_explicit(&bridge->captureCallbacks, memory_order_relaxed),
        .outputCallbacks = atomic_load_explicit(&bridge->outputCallbacks, memory_order_relaxed),
        .renderedFrames = atomic_load_explicit(&bridge->renderedFrames, memory_order_relaxed),
        .renderFailures = atomic_load_explicit(&bridge->renderFailures, memory_order_relaxed),
        .outputWriteFailures = atomic_load_explicit(&bridge->outputWriteFailures, memory_order_relaxed),
        .gatedOutputCallbacks = atomic_load_explicit(
            &bridge->gatedOutputCallbacks,
            memory_order_relaxed
        ),
        .gatedOutputFrames = atomic_load_explicit(
            &bridge->gatedOutputFrames,
            memory_order_relaxed
        ),
        .outputGateOpen = atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire),
        .algorithmicLatencyFrames =
            N60LiveNChannelRenderGraphLatencyFrames(&bridge->graph)
            + (N60AudioUnitLiveRackProcessorIsValid(&bridge->audioUnitRack)
                ? bridge->audioUnitRack.latencyFrames
                : 0u),
        .transport = N60ProgramTransportGetSnapshot(bridge->transport),
        .adaptiveSampleRateEnabled = bridge->adaptiveSRC != NULL,
        .roomTreatmentConfigured = bridge->roomTreatment != NULL,
        .meter = N60LiveNChannelBridgeGetMeterSnapshot(bridge),
    };
    if (bridge->adaptiveSRC != NULL) {
        result.adaptiveSampleRate = N60AdaptiveSRCGetSnapshot(bridge->adaptiveSRC);
        result.adaptiveTransportLatencyFrames = (uint64_t)ceil(
            (double)result.adaptiveSampleRate.targetBufferedFrames
            * result.adaptiveSampleRate.outputSampleRate
            / result.adaptiveSampleRate.inputSampleRate
        );
    }
    if (bridge->roomTreatment != NULL) {
        result.roomTreatment =
            N60MIMOTreatmentLiveGetSnapshot(bridge->roomTreatment);
        result.roomTreatmentLatencyFrames =
            result.roomTreatment.totalLatencyFrames;
    }
    return result;
}

static inline void N60LiveNChannelZeroOutput(AudioBufferList * _Nullable outputData) {
    if (outputData == NULL) return;
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0u) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static inline bool N60LiveNChannelWritePhysicalFrame(
    const N60LiveNChannelPhysicalFrame * _Nonnull frame,
    AudioBufferList * _Nonnull outputData,
    uint32_t frameIndex,
    float gain
) {
    if (frame == NULL
        || outputData == NULL
        || frame->physicalChannelCount == 0u
        || frame->physicalChannelCount > N60_LIVE_MAX_PHYSICAL_CHANNELS
        || !isfinite(gain)) {
        return false;
    }
    if (!N60ProgramTransportZeroOutputFrame(outputData, frameIndex)) return false;
    for (uint32_t physical = 0; physical < frame->physicalChannelCount; ++physical) {
        const float value = frame->values[physical] * gain;
        if (!N60ProgramTransportWriteFlattenedSample(
                outputData,
                physical,
                frameIndex,
                isfinite(value) ? value : 0.0f)) {
            return false;
        }
    }
    return true;
}

static inline float N60LiveNChannelBridgeNextOutputGain(
    N60LiveNChannelBridge * _Nonnull bridge,
    float masterGain
) {
    if (bridge == NULL || bridge->startupFadeRemaining == 0u || bridge->startupFadeFrames == 0u) {
        return masterGain;
    }
    const uint32_t completed = bridge->startupFadeFrames - bridge->startupFadeRemaining + 1u;
    const float fade = (float)completed / (float)bridge->startupFadeFrames;
    bridge->startupFadeRemaining -= 1u;
    return masterGain * fade;
}

/// Realtime capture callback: Core Audio stream order -> canonical semantic ring.
static inline OSStatus N60LiveNChannelCaptureIOProc(
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

    N60LiveNChannelBridge *bridge = (N60LiveNChannelBridge *)inClientData;
    if (bridge == NULL || bridge->transport == NULL || inInputData == NULL) return noErr;
    atomic_fetch_add_explicit(&bridge->captureCallbacks, 1u, memory_order_relaxed);

    if (bridge->adaptiveSRC != NULL) {
        uint32_t frameCount = 0u;
        if (!N60ProgramTransportBufferFrameCount(
                inInputData,
                bridge->inputMap.streamChannelCount,
                &frameCount)) {
            N60ProgramTransportRecordUnsupportedBufferLayout(bridge->transport);
            return noErr;
        }
        const uint32_t capacity = bridge->transport->capacityFrames;
        const uint32_t framesToStage = frameCount < capacity ? frameCount : capacity;
        const uint32_t channels = bridge->graph.programLayout.channelCount;
        uint32_t staged = 0u;
        for (; staged < framesToStage; ++staged) {
            N60ProgramTransportFrame canonical = {0};
            if (!N60ProgramInputMapReadFrame(
                    &bridge->inputMap,
                    inInputData,
                    staged,
                    &canonical)) {
                N60ProgramTransportRecordUnsupportedBufferLayout(bridge->transport);
                break;
            }
            memcpy(
                bridge->adaptiveCaptureScratch + (size_t)staged * channels,
                canonical.channels,
                (size_t)channels * sizeof(float)
            );
        }
        if (staged > 0u) {
            (void)N60AdaptiveSRCPushInterleaved(
                bridge->adaptiveSRC,
                bridge->adaptiveCaptureScratch,
                staged
            );
        }
        return noErr;
    }

    (void)N60ProgramTransportCaptureBuffer(
        bridge->transport,
        &bridge->inputMap,
        inInputData
    );
    return noErr;
}

/// Realtime output callback. This is the first complete live N-channel callback
/// path: semantic dequeue -> PR54 lanes -> PR55 bass management -> physical map.
/// Graph/runtime mutation is intentionally forbidden while callbacks run.
static inline OSStatus N60LiveNChannelOutputIOProc(
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

    N60LiveNChannelBridge *bridge = (N60LiveNChannelBridge *)inClientData;
    if (bridge == NULL
        || bridge->transport == NULL
        || bridge->renderRuntime == NULL
        || outOutputData == NULL) {
        return noErr;
    }
    atomic_fetch_add_explicit(&bridge->outputCallbacks, 1u, memory_order_relaxed);

    uint32_t frameCount = 0u;
    if (!N60ProgramTransportBufferFrameCount(
            outOutputData,
            bridge->graph.outputMap.physicalChannelCount,
            &frameCount)) {
        N60LiveNChannelZeroOutput(outOutputData);
        atomic_fetch_add_explicit(&bridge->outputWriteFailures, 1u, memory_order_relaxed);
        return noErr;
    }

    const bool adaptiveSampleRate = bridge->adaptiveSRC != NULL;
    if (!atomic_load_explicit(&bridge->outputGateOpen, memory_order_acquire)) {
        const uint32_t bufferedFrames = adaptiveSampleRate
            ? N60AdaptiveSRCGetSnapshot(bridge->adaptiveSRC).bufferedFrames
            : N60ProgramTransportGetSnapshot(bridge->transport).bufferedFrames;
        const bool gateReady = adaptiveSampleRate
            ? bufferedFrames >= bridge->outputGateMinimumBufferedFrames
            : (bufferedFrames >= bridge->outputGateMinimumBufferedFrames
                && bufferedFrames >= frameCount);
        if (gateReady) {
            atomic_store_explicit(&bridge->outputGateOpen, true, memory_order_release);
            bridge->startupFadeRemaining = bridge->startupFadeFrames;
        } else {
            N60LiveNChannelZeroOutput(outOutputData);
            atomic_fetch_add_explicit(&bridge->gatedOutputCallbacks, 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&bridge->gatedOutputFrames, frameCount, memory_order_relaxed);
            return noErr;
        }
    }

    if (adaptiveSampleRate) {
        const uint32_t pulled = N60AdaptiveSRCPullInterleaved(
            bridge->adaptiveSRC,
            bridge->adaptiveOutputScratch,
            frameCount
        );
        if (pulled < frameCount) {
            N60LiveNChannelZeroOutput(outOutputData);
            N60AdaptiveSRCRelockConsumer(bridge->adaptiveSRC);
            atomic_store_explicit(&bridge->outputGateOpen, false, memory_order_release);
            bridge->startupFadeRemaining = bridge->startupFadeFrames;
            atomic_fetch_add_explicit(&bridge->gatedOutputCallbacks, 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&bridge->gatedOutputFrames, frameCount, memory_order_relaxed);
            return noErr;
        }
    }

    const float masterGain = N60LiveNChannelBitsToFloat(
        atomic_load_explicit(&bridge->outputGainBits, memory_order_acquire)
    );
    const bool meterDemand = atomic_load_explicit(
        &bridge->meteringDemand, memory_order_acquire
    );
    N60ProgramLaneMeterAccumulator programMeter = {0};
    float physicalPeak[N60_LIVE_MAX_PHYSICAL_CHANNELS] = {0};
    double physicalSquareSum[N60_LIVE_MAX_PHYSICAL_CHANNELS] = {0};
    uint64_t physicalOverRange[N60_LIVE_MAX_PHYSICAL_CHANNELS] = {0};
    uint32_t physicalMeterFrames = 0u;
    if (meterDemand) {
        N60ProgramLaneMeterAccumulatorReset(
            &programMeter, bridge->graph.programLayout.channelCount
        );
    }

    const uint32_t programChannels =
        bridge->graph.programLayout.channelCount;
    const bool rackConfigured =
        N60AudioUnitLiveRackProcessorIsValid(&bridge->audioUnitRack);
    if (rackConfigured) {
        if (frameCount > bridge->audioUnitRack.maximumFramesPerSlice
            || bridge->audioUnitRackScratch == NULL) {
            N60LiveNChannelZeroOutput(outOutputData);
            atomic_fetch_add_explicit(
                &bridge->renderFailures, 1u, memory_order_relaxed
            );
            return noErr;
        }

        for (uint32_t frameIndex = 0;
             frameIndex < frameCount;
             ++frameIndex) {
            float *destination =
                bridge->audioUnitRackScratch
                + (size_t)frameIndex * programChannels;
            if (adaptiveSampleRate) {
                memcpy(
                    destination,
                    bridge->adaptiveOutputScratch
                        + (size_t)frameIndex * programChannels,
                    (size_t)programChannels * sizeof(float)
                );
            } else {
                N60ProgramTransportFrame canonical = {0};
                (void)N60ProgramTransportDequeueFrame(
                    bridge->transport,
                    &canonical
                );
                memcpy(
                    destination,
                    canonical.channels,
                    (size_t)programChannels * sizeof(float)
                );
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
            N60LiveNChannelZeroOutput(outOutputData);
            atomic_fetch_add_explicit(
                &bridge->renderFailures, 1u, memory_order_relaxed
            );
            return noErr;
        }
    }

    for (uint32_t frameIndex = 0; frameIndex < frameCount; ++frameIndex) {
        N60ProgramTransportFrame input = {0};
        if (rackConfigured) {
            memcpy(
                input.channels,
                bridge->audioUnitRackScratch
                    + (size_t)frameIndex * programChannels,
                (size_t)programChannels * sizeof(float)
            );
        } else if (adaptiveSampleRate) {
            memcpy(
                input.channels,
                bridge->adaptiveOutputScratch
                    + (size_t)frameIndex * programChannels,
                (size_t)programChannels * sizeof(float)
            );
        } else {
            (void)N60ProgramTransportDequeueFrame(
                bridge->transport,
                &input
            );
        }

        N60LiveNChannelPhysicalFrame physical = {0};
        if (!N60LiveNChannelRenderProcessFrame(
                bridge->renderRuntime,
                &bridge->graph,
                &input,
                &physical,
                meterDemand ? &programMeter : NULL)) {
            (void)N60ProgramTransportZeroOutputFrame(outOutputData, frameIndex);
            atomic_fetch_add_explicit(&bridge->renderFailures, 1u, memory_order_relaxed);
            continue;
        }

        if (bridge->roomTreatment != NULL
            && !N60MIMOTreatmentLiveProcessPhysicalFrame(
                bridge->roomTreatment,
                physical.values,
                physical.physicalChannelCount)) {
            (void)N60ProgramTransportZeroOutputFrame(outOutputData, frameIndex);
            atomic_fetch_add_explicit(&bridge->renderFailures, 1u, memory_order_relaxed);
            continue;
        }

        const float gain = N60LiveNChannelBridgeNextOutputGain(bridge, masterGain);
        if (meterDemand) {
            for (uint32_t physicalIndex = 0; physicalIndex < physical.physicalChannelCount; ++physicalIndex) {
                const float value = physical.values[physicalIndex] * gain;
                const float magnitude = fabsf(value);
                if (magnitude > physicalPeak[physicalIndex]) physicalPeak[physicalIndex] = magnitude;
                physicalSquareSum[physicalIndex] += (double)value * (double)value;
                if (magnitude > 1.0f) physicalOverRange[physicalIndex] += 1u;
            }
            physicalMeterFrames += 1u;
        }
        if (!N60LiveNChannelWritePhysicalFrame(&physical, outOutputData, frameIndex, gain)) {
            (void)N60ProgramTransportZeroOutputFrame(outOutputData, frameIndex);
            atomic_fetch_add_explicit(&bridge->outputWriteFailures, 1u, memory_order_relaxed);
            continue;
        }
        atomic_fetch_add_explicit(&bridge->renderedFrames, 1u, memory_order_relaxed);
    }

    if (meterDemand) {
        const N60ProgramLaneMeterReading reading =
            N60ProgramLaneMeterAccumulatorReading(&programMeter);
        for (uint32_t channel = 0; channel < reading.channelCount; ++channel) {
            atomic_store_explicit(
                &bridge->meterProgramPeakBits[channel],
                N60LiveNChannelFloatToBits(reading.peak[channel]),
                memory_order_relaxed
            );
            atomic_store_explicit(
                &bridge->meterProgramRMSBits[channel],
                N60LiveNChannelFloatToBits(reading.rms[channel]),
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &bridge->meterProgramOverRangeSamples[channel],
                reading.overRangeSamples[channel],
                memory_order_relaxed
            );
        }
        if (physicalMeterFrames > 0u) {
            for (uint32_t physicalIndex = 0;
                 physicalIndex < bridge->graph.outputMap.physicalChannelCount;
                 ++physicalIndex) {
                const float rms = (float)sqrt(
                    physicalSquareSum[physicalIndex] / (double)physicalMeterFrames
                );
                atomic_store_explicit(
                    &bridge->meterPhysicalPeakBits[physicalIndex],
                    N60LiveNChannelFloatToBits(physicalPeak[physicalIndex]),
                    memory_order_relaxed
                );
                atomic_store_explicit(
                    &bridge->meterPhysicalRMSBits[physicalIndex],
                    N60LiveNChannelFloatToBits(rms),
                    memory_order_relaxed
                );
                atomic_fetch_add_explicit(
                    &bridge->meterPhysicalOverRangeSamples[physicalIndex],
                    physicalOverRange[physicalIndex],
                    memory_order_relaxed
                );
            }
        }
    }
    return noErr;
}

#ifdef __cplusplus
}
#endif

#endif
