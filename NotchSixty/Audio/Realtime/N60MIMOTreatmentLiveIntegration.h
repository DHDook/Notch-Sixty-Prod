#ifndef N60MIMOTreatmentLiveIntegration_h
#define N60MIMOTreatmentLiveIntegration_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "N60LiveNChannelRenderCore.h"
#include "N60MIMOTreatmentTransition.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool configured;
    uint32_t physicalChannelCount;
    uint32_t treatmentChannelCount;
    uint32_t treatmentPhysicalChannels[N60_MIMO_FIR_MAX_CHANNELS];
    uint32_t totalLatencyFrames;
    N60MIMOTreatmentTransitionSnapshot transition;
    uint64_t processedFrames;
    uint64_t protectionClampSamples;
    uint64_t integrationFailures;
} N60MIMOTreatmentLiveSnapshot;

typedef struct N60MIMOTreatmentLiveIntegration {
    N60MIMOFIRProgram * _Nullable program;
    N60MIMOTreatmentTransitionRuntime * _Nullable transition;
    uint32_t physicalChannelCount;
    uint32_t treatmentChannelCount;
    uint32_t treatmentPhysicalChannels[N60_MIMO_FIR_MAX_CHANNELS];

    uint32_t totalLatencyFrames;
    uint32_t delayRingFrames;
    uint32_t delayWriteIndex;
    float * _Nullable delayRing;

    _Atomic uint64_t processedFrames;
    _Atomic uint64_t protectionClampSamples;
    _Atomic uint64_t integrationFailures;
} N60MIMOTreatmentLiveIntegration;

static inline bool N60MIMOTreatmentLivePhysicalMapIsValid(
    uint32_t physicalChannelCount,
    uint32_t treatmentChannelCount,
    const uint32_t * _Nonnull treatmentPhysicalChannels
) {
    if (physicalChannelCount == 0u
        || physicalChannelCount > N60_LIVE_MAX_PHYSICAL_CHANNELS
        || treatmentChannelCount == 0u
        || treatmentChannelCount > N60_MIMO_FIR_MAX_CHANNELS
        || treatmentPhysicalChannels == NULL) {
        return false;
    }
    bool used[N60_LIVE_MAX_PHYSICAL_CHANNELS] = {false};
    for (uint32_t channel = 0u; channel < treatmentChannelCount; ++channel) {
        const uint32_t physical = treatmentPhysicalChannels[channel];
        if (physical >= physicalChannelCount || used[physical]) return false;
        used[physical] = true;
    }
    return true;
}

/// Control-plane only. Owns the immutable FIR program, transition runtime and
/// full-physical-output latency-match ring.
static inline N60MIMOTreatmentLiveIntegration * _Nullable
N60MIMOTreatmentLiveIntegrationCreate(
    uint32_t physicalChannelCount,
    uint32_t treatmentChannelCount,
    const uint32_t * _Nonnull treatmentPhysicalChannels,
    const float * _Nonnull taps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    uint32_t fadeFrames,
    uint32_t faultFadeFrames
) {
    if (!N60MIMOTreatmentLivePhysicalMapIsValid(
            physicalChannelCount,
            treatmentChannelCount,
            treatmentPhysicalChannels)
        || taps == NULL) {
        return NULL;
    }

    N60MIMOFIRProgram *program = N60MIMOFIRProgramCreate(
        treatmentChannelCount,
        taps,
        tapCount,
        declaredLatencyFrames
    );
    if (program == NULL) return NULL;

    N60MIMOTreatmentTransitionRuntime *transition =
        N60MIMOTreatmentTransitionRuntimeCreate(
            program,
            fadeFrames,
            faultFadeFrames
        );
    if (transition == NULL) {
        N60MIMOFIRProgramDestroy(program);
        return NULL;
    }

    const N60MIMOFIRProgramInfo info = N60MIMOFIRProgramGetInfo(program);
    const uint32_t totalLatencyFrames =
        info.declaredLatencyFrames + info.engineLatencyFrames;
    if (totalLatencyFrames == 0u) {
        N60MIMOTreatmentTransitionRuntimeDestroy(transition);
        N60MIMOFIRProgramDestroy(program);
        return NULL;
    }

    const uint32_t delayRingFrames = totalLatencyFrames + 1u;
    const size_t delaySamples =
        (size_t)delayRingFrames * physicalChannelCount;
    float *delayRing = (float *)calloc(delaySamples, sizeof(float));
    if (delayRing == NULL) {
        N60MIMOTreatmentTransitionRuntimeDestroy(transition);
        N60MIMOFIRProgramDestroy(program);
        return NULL;
    }

    N60MIMOTreatmentLiveIntegration *integration =
        (N60MIMOTreatmentLiveIntegration *)calloc(
            1u,
            sizeof(N60MIMOTreatmentLiveIntegration)
        );
    if (integration == NULL) {
        free(delayRing);
        N60MIMOTreatmentTransitionRuntimeDestroy(transition);
        N60MIMOFIRProgramDestroy(program);
        return NULL;
    }

    integration->program = program;
    integration->transition = transition;
    integration->physicalChannelCount = physicalChannelCount;
    integration->treatmentChannelCount = treatmentChannelCount;
    integration->totalLatencyFrames = totalLatencyFrames;
    integration->delayRingFrames = delayRingFrames;
    integration->delayRing = delayRing;
    for (uint32_t channel = 0u; channel < treatmentChannelCount; ++channel) {
        integration->treatmentPhysicalChannels[channel] =
            treatmentPhysicalChannels[channel];
    }
    return integration;
}

static inline void N60MIMOTreatmentLiveIntegrationDestroy(
    N60MIMOTreatmentLiveIntegration * _Nullable integration
) {
    if (integration == NULL) return;
    N60MIMOTreatmentTransitionRuntimeDestroy(integration->transition);
    N60MIMOFIRProgramDestroy(integration->program);
    free(integration->delayRing);
    integration->transition = NULL;
    integration->program = NULL;
    integration->delayRing = NULL;
    free(integration);
}

/// Control-plane only. Reset revokes authorization via PR76.
static inline void N60MIMOTreatmentLiveIntegrationReset(
    N60MIMOTreatmentLiveIntegration * _Nullable integration
) {
    if (integration == NULL
        || integration->transition == NULL
        || integration->delayRing == NULL) {
        return;
    }
    N60MIMOTreatmentTransitionRuntimeReset(integration->transition);
    memset(
        integration->delayRing,
        0,
        (size_t)integration->delayRingFrames
            * integration->physicalChannelCount
            * sizeof(float)
    );
    integration->delayWriteIndex = 0u;
    atomic_store_explicit(
        &integration->processedFrames,
        0u,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &integration->protectionClampSamples,
        0u,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &integration->integrationFailures,
        0u,
        memory_order_relaxed
    );
}

static inline void N60MIMOTreatmentLiveSetAuthorized(
    N60MIMOTreatmentLiveIntegration * _Nullable integration,
    bool authorized
) {
    if (integration == NULL || integration->transition == NULL) return;
    N60MIMOTreatmentTransitionSetAuthorized(
        integration->transition,
        authorized
    );
}

static inline bool N60MIMOTreatmentLiveRequestArm(
    N60MIMOTreatmentLiveIntegration * _Nullable integration
) {
    return integration != NULL
        && integration->transition != NULL
        && N60MIMOTreatmentTransitionRequestArm(integration->transition);
}

static inline void N60MIMOTreatmentLiveRequestBypass(
    N60MIMOTreatmentLiveIntegration * _Nullable integration
) {
    if (integration == NULL || integration->transition == NULL) return;
    N60MIMOTreatmentTransitionRequestBypass(integration->transition);
}

static inline bool N60MIMOTreatmentLiveLatchFault(
    N60MIMOTreatmentLiveIntegration * _Nullable integration,
    N60MIMOTreatmentFault fault
) {
    return integration != NULL
        && integration->transition != NULL
        && N60MIMOTreatmentTransitionLatchFault(
            integration->transition,
            fault
        );
}

static inline void N60MIMOTreatmentLiveRequestFaultClear(
    N60MIMOTreatmentLiveIntegration * _Nullable integration
) {
    if (integration == NULL || integration->transition == NULL) return;
    N60MIMOTreatmentTransitionRequestFaultClear(integration->transition);
}

/// Realtime-safe physical-output integration.
///
/// Every physical channel is delayed by the exact PR76 treatment subsystem
/// latency. The selected treatment-source channels are then replaced by the
/// latency-matched PR76 transition outputs. This preserves relative timing
/// between treated and untreated speakers/subwoofers.
///
/// A final emergency sample clamp is applied to the aligned physical frame.
/// Any clamp latches a PR76 protection fault so the treatment fades to identity.
/// This is a last-resort fail-safe and is not a substitute for the physical
/// source excursion/thermal/protection acceptance required by PR75.
static inline bool N60MIMOTreatmentLiveProcessPhysicalFrame(
    N60MIMOTreatmentLiveIntegration * _Nonnull integration,
    float * _Nonnull physicalValues,
    uint32_t physicalChannelCount
) {
    if (integration == NULL
        || integration->transition == NULL
        || integration->delayRing == NULL
        || physicalValues == NULL
        || physicalChannelCount != integration->physicalChannelCount) {
        if (integration != NULL) {
            atomic_fetch_add_explicit(
                &integration->integrationFailures,
                1u,
                memory_order_relaxed
            );
        }
        return false;
    }

    float treatmentInput[N60_MIMO_FIR_MAX_CHANNELS] = {0};
    float treatmentOutput[N60_MIMO_FIR_MAX_CHANNELS] = {0};
    for (uint32_t channel = 0u;
         channel < integration->treatmentChannelCount;
         ++channel) {
        const uint32_t physical =
            integration->treatmentPhysicalChannels[channel];
        treatmentInput[channel] = isfinite(physicalValues[physical])
            ? physicalValues[physical]
            : 0.0f;
    }

    const bool treatmentOK = N60MIMOTreatmentTransitionProcessFrame(
        integration->transition,
        treatmentInput,
        treatmentOutput
    );

    const uint32_t write = integration->delayWriteIndex;
    const uint32_t read =
        (write + 1u) % integration->delayRingFrames;
    float *writeFrame =
        integration->delayRing
        + (size_t)write * physicalChannelCount;
    const float *readFrame =
        integration->delayRing
        + (size_t)read * physicalChannelCount;

    for (uint32_t physical = 0u;
         physical < physicalChannelCount;
         ++physical) {
        writeFrame[physical] = isfinite(physicalValues[physical])
            ? physicalValues[physical]
            : 0.0f;
        physicalValues[physical] = readFrame[physical];
    }
    integration->delayWriteIndex = read;

    if (!treatmentOK) {
        memset(
            physicalValues,
            0,
            (size_t)physicalChannelCount * sizeof(float)
        );
        atomic_fetch_add_explicit(
            &integration->integrationFailures,
            1u,
            memory_order_relaxed
        );
        return false;
    }

    for (uint32_t channel = 0u;
         channel < integration->treatmentChannelCount;
         ++channel) {
        const uint32_t physical =
            integration->treatmentPhysicalChannels[channel];
        physicalValues[physical] = treatmentOutput[channel];
    }

    bool protectionFault = false;
    uint64_t clampSamples = 0u;
    for (uint32_t physical = 0u;
         physical < physicalChannelCount;
         ++physical) {
        float value = physicalValues[physical];
        if (!isfinite(value)) {
            value = 0.0f;
            protectionFault = true;
            clampSamples += 1u;
        } else if (value > 1.0f) {
            value = 1.0f;
            protectionFault = true;
            clampSamples += 1u;
        } else if (value < -1.0f) {
            value = -1.0f;
            protectionFault = true;
            clampSamples += 1u;
        }
        physicalValues[physical] = value;
    }
    if (clampSamples > 0u) {
        atomic_fetch_add_explicit(
            &integration->protectionClampSamples,
            clampSamples,
            memory_order_relaxed
        );
    }
    if (protectionFault) {
        (void)N60MIMOTreatmentTransitionLatchFault(
            integration->transition,
            N60MIMOTreatmentFaultProtection
        );
    }

    atomic_fetch_add_explicit(
        &integration->processedFrames,
        1u,
        memory_order_relaxed
    );
    return true;
}

static inline N60MIMOTreatmentLiveSnapshot
N60MIMOTreatmentLiveGetSnapshot(
    const N60MIMOTreatmentLiveIntegration * _Nullable integration
) {
    N60MIMOTreatmentLiveSnapshot snapshot = {0};
    if (integration == NULL || integration->transition == NULL) {
        return snapshot;
    }
    snapshot.configured = true;
    snapshot.physicalChannelCount = integration->physicalChannelCount;
    snapshot.treatmentChannelCount = integration->treatmentChannelCount;
    snapshot.totalLatencyFrames = integration->totalLatencyFrames;
    for (uint32_t channel = 0u;
         channel < integration->treatmentChannelCount;
         ++channel) {
        snapshot.treatmentPhysicalChannels[channel] =
            integration->treatmentPhysicalChannels[channel];
    }
    snapshot.transition =
        N60MIMOTreatmentTransitionGetSnapshot(integration->transition);
    snapshot.processedFrames = atomic_load_explicit(
        &integration->processedFrames,
        memory_order_relaxed
    );
    snapshot.protectionClampSamples = atomic_load_explicit(
        &integration->protectionClampSamples,
        memory_order_relaxed
    );
    snapshot.integrationFailures = atomic_load_explicit(
        &integration->integrationFailures,
        memory_order_relaxed
    );
    return snapshot;
}

#ifdef __cplusplus
}
#endif

#endif
