#ifndef N60MIMOTreatmentTransition_h
#define N60MIMOTreatmentTransition_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "N60MIMOFIRRuntime.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MIMO_TREATMENT_DEFAULT_FADE_FRAMES 2048u
#define N60_MIMO_TREATMENT_DEFAULT_FAULT_FADE_FRAMES 512u
#define N60_MIMO_TREATMENT_MAX_TRANSITION_FRAMES 192000u
#define N60_MIMO_TREATMENT_MIX_SCALE 16777215u

typedef enum {
    N60MIMOTreatmentStateBypassed = 0,
    N60MIMOTreatmentStateArming = 1,
    N60MIMOTreatmentStateActive = 2,
    N60MIMOTreatmentStateDisarming = 3,
    N60MIMOTreatmentStateFaultFading = 4,
    N60MIMOTreatmentStateFaulted = 5,
} N60MIMOTreatmentState;

typedef enum {
    N60MIMOTreatmentFaultNone = 0,
    N60MIMOTreatmentFaultAuthorizationRevoked = 1,
    N60MIMOTreatmentFaultMeasurementInvalid = 2,
    N60MIMOTreatmentFaultProtection = 3,
    N60MIMOTreatmentFaultSourceUnavailable = 4,
    N60MIMOTreatmentFaultTreatmentRuntimeFailure = 5,
    N60MIMOTreatmentFaultIdentityRuntimeFailure = 6,
    N60MIMOTreatmentFaultEmergencyStop = 7,
} N60MIMOTreatmentFault;

typedef struct {
    N60MIMOTreatmentState state;
    N60MIMOTreatmentFault fault;
    bool authorized;
    bool armRequested;
    float treatmentMix;
    uint32_t channelCount;
    uint32_t tapCount;
    uint32_t declaredLatencyFrames;
    uint32_t engineLatencyFrames;
    uint32_t totalLatencyFrames;
    uint32_t fadeFrames;
    uint32_t faultFadeFrames;
    uint64_t processedFrames;
    uint64_t armRequests;
    uint64_t bypassRequests;
    uint64_t faultRequests;
    uint64_t completedTransitions;
    uint64_t hardRuntimeFailures;
} N60MIMOTreatmentTransitionSnapshot;

typedef struct N60MIMOTreatmentTransitionRuntime {
    const N60MIMOFIRProgram * _Nonnull treatmentProgram;
    N60MIMOFIRProgram * _Nullable identityProgram;
    N60MIMOFIRRuntime * _Nullable identityRuntime;
    N60MIMOFIRRuntime * _Nullable treatmentRuntime;

    uint32_t fadeFrames;
    uint32_t faultFadeFrames;

    N60MIMOTreatmentState state;
    N60MIMOTreatmentFault fault;
    float mix;
    float transitionStartMix;
    float transitionTargetMix;
    uint32_t transitionFrames;
    uint32_t transitionPosition;

    _Atomic bool authorized;
    _Atomic bool armRequested;
    _Atomic bool clearFaultRequested;
    _Atomic uint32_t pendingFault;

    _Atomic uint32_t publishedState;
    _Atomic uint32_t publishedFault;
    _Atomic uint32_t publishedMixQ24;

    _Atomic uint64_t processedFrames;
    _Atomic uint64_t armRequests;
    _Atomic uint64_t bypassRequests;
    _Atomic uint64_t faultRequests;
    _Atomic uint64_t completedTransitions;
    _Atomic uint64_t hardRuntimeFailures;
} N60MIMOTreatmentTransitionRuntime;

static inline float N60MIMOTreatmentSmoothstep(float value) {
    const float x = value < 0.0f ? 0.0f : (value > 1.0f ? 1.0f : value);
    return x * x * (3.0f - 2.0f * x);
}

static inline uint32_t N60MIMOTreatmentMixToQ24(float mix) {
    const float bounded = mix < 0.0f ? 0.0f : (mix > 1.0f ? 1.0f : mix);
    return (uint32_t)lrintf(bounded * (float)N60_MIMO_TREATMENT_MIX_SCALE);
}

static inline float N60MIMOTreatmentMixFromQ24(uint32_t value) {
    const uint32_t bounded = value > N60_MIMO_TREATMENT_MIX_SCALE
        ? N60_MIMO_TREATMENT_MIX_SCALE
        : value;
    return (float)bounded / (float)N60_MIMO_TREATMENT_MIX_SCALE;
}

static inline bool N60MIMOTreatmentTransitionFramesAreValid(uint32_t frames) {
    return frames > 0u && frames <= N60_MIMO_TREATMENT_MAX_TRANSITION_FRAMES;
}

static inline N60MIMOFIRProgram * _Nullable
N60MIMOTreatmentCreateLatencyMatchedIdentity(
    const N60MIMOFIRProgram * _Nonnull treatmentProgram
) {
    if (treatmentProgram == NULL
        || treatmentProgram->channelCount == 0u
        || treatmentProgram->channelCount > N60_MIMO_FIR_MAX_CHANNELS
        || treatmentProgram->tapCount == 0u
        || treatmentProgram->tapCount > N60_MIMO_FIR_MAX_TAPS
        || treatmentProgram->declaredLatencyFrames >= treatmentProgram->tapCount) {
        return NULL;
    }

    const uint32_t channels = treatmentProgram->channelCount;
    const uint32_t taps = treatmentProgram->tapCount;
    const size_t count = (size_t)channels * channels * taps;
    float *identity = (float *)calloc(count, sizeof(float));
    if (identity == NULL) return NULL;

    for (uint32_t channel = 0u; channel < channels; ++channel) {
        identity[
            N60MIMOFIRTapOffset(
                channels,
                taps,
                channel,
                channel,
                treatmentProgram->declaredLatencyFrames
            )
        ] = 1.0f;
    }

    N60MIMOFIRProgram *program = N60MIMOFIRProgramCreate(
        channels,
        identity,
        taps,
        treatmentProgram->declaredLatencyFrames
    );
    free(identity);
    return program;
}

static inline void N60MIMOTreatmentPublishRuntimeState(
    N60MIMOTreatmentTransitionRuntime * _Nonnull runtime
) {
    atomic_store_explicit(
        &runtime->publishedState,
        (uint32_t)runtime->state,
        memory_order_release
    );
    atomic_store_explicit(
        &runtime->publishedFault,
        (uint32_t)runtime->fault,
        memory_order_release
    );
    atomic_store_explicit(
        &runtime->publishedMixQ24,
        N60MIMOTreatmentMixToQ24(runtime->mix),
        memory_order_release
    );
}

static inline void N60MIMOTreatmentBeginTransition(
    N60MIMOTreatmentTransitionRuntime * _Nonnull runtime,
    N60MIMOTreatmentState state,
    float targetMix,
    uint32_t frames
) {
    runtime->state = state;
    runtime->transitionStartMix = runtime->mix;
    runtime->transitionTargetMix = targetMix;
    runtime->transitionFrames = frames;
    runtime->transitionPosition = 0u;
}

static inline N60MIMOTreatmentTransitionRuntime * _Nullable
N60MIMOTreatmentTransitionRuntimeCreate(
    const N60MIMOFIRProgram * _Nonnull treatmentProgram,
    uint32_t fadeFrames,
    uint32_t faultFadeFrames
) {
    if (treatmentProgram == NULL
        || !N60MIMOTreatmentTransitionFramesAreValid(fadeFrames)
        || !N60MIMOTreatmentTransitionFramesAreValid(faultFadeFrames)) {
        return NULL;
    }

    const N60MIMOFIRProgramInfo info =
        N60MIMOFIRProgramGetInfo(treatmentProgram);
    if (!info.prepared
        || info.channelCount == 0u
        || info.channelCount > N60_MIMO_FIR_MAX_CHANNELS
        || info.tapCount == 0u
        || info.declaredLatencyFrames >= info.tapCount) {
        return NULL;
    }

    N60MIMOTreatmentTransitionRuntime *runtime =
        (N60MIMOTreatmentTransitionRuntime *)calloc(
            1u,
            sizeof(N60MIMOTreatmentTransitionRuntime)
        );
    if (runtime == NULL) return NULL;

    runtime->treatmentProgram = treatmentProgram;
    runtime->identityProgram =
        N60MIMOTreatmentCreateLatencyMatchedIdentity(treatmentProgram);
    if (runtime->identityProgram == NULL) {
        free(runtime);
        return NULL;
    }

    runtime->identityRuntime =
        N60MIMOFIRRuntimeCreate(runtime->identityProgram);
    runtime->treatmentRuntime =
        N60MIMOFIRRuntimeCreate(treatmentProgram);
    if (runtime->identityRuntime == NULL
        || runtime->treatmentRuntime == NULL) {
        N60MIMOFIRRuntimeDestroy(runtime->identityRuntime);
        N60MIMOFIRRuntimeDestroy(runtime->treatmentRuntime);
        N60MIMOFIRProgramDestroy(runtime->identityProgram);
        free(runtime);
        return NULL;
    }

    runtime->fadeFrames = fadeFrames;
    runtime->faultFadeFrames = faultFadeFrames;
    runtime->state = N60MIMOTreatmentStateBypassed;
    runtime->fault = N60MIMOTreatmentFaultNone;
    runtime->mix = 0.0f;

    atomic_store_explicit(&runtime->authorized, false, memory_order_relaxed);
    atomic_store_explicit(&runtime->armRequested, false, memory_order_relaxed);
    atomic_store_explicit(&runtime->clearFaultRequested, false, memory_order_relaxed);
    atomic_store_explicit(
        &runtime->pendingFault,
        (uint32_t)N60MIMOTreatmentFaultNone,
        memory_order_relaxed
    );
    N60MIMOTreatmentPublishRuntimeState(runtime);
    return runtime;
}

static inline void N60MIMOTreatmentTransitionRuntimeDestroy(
    N60MIMOTreatmentTransitionRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    N60MIMOFIRRuntimeDestroy(runtime->identityRuntime);
    N60MIMOFIRRuntimeDestroy(runtime->treatmentRuntime);
    N60MIMOFIRProgramDestroy(runtime->identityProgram);
    runtime->identityRuntime = NULL;
    runtime->treatmentRuntime = NULL;
    runtime->identityProgram = NULL;
    runtime->treatmentProgram = NULL;
    free(runtime);
}

/// Control-plane only: resets both FIR histories and revokes authorization.
/// Re-arming after reset therefore requires explicit re-authorization.
static inline void N60MIMOTreatmentTransitionRuntimeReset(
    N60MIMOTreatmentTransitionRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    N60MIMOFIRRuntimeReset(runtime->identityRuntime);
    N60MIMOFIRRuntimeReset(runtime->treatmentRuntime);
    runtime->state = N60MIMOTreatmentStateBypassed;
    runtime->fault = N60MIMOTreatmentFaultNone;
    runtime->mix = 0.0f;
    runtime->transitionStartMix = 0.0f;
    runtime->transitionTargetMix = 0.0f;
    runtime->transitionFrames = 0u;
    runtime->transitionPosition = 0u;
    atomic_store_explicit(&runtime->authorized, false, memory_order_release);
    atomic_store_explicit(&runtime->armRequested, false, memory_order_release);
    atomic_store_explicit(&runtime->clearFaultRequested, false, memory_order_release);
    atomic_store_explicit(
        &runtime->pendingFault,
        (uint32_t)N60MIMOTreatmentFaultNone,
        memory_order_release
    );
    N60MIMOTreatmentPublishRuntimeState(runtime);
}

static inline void N60MIMOTreatmentTransitionSetAuthorized(
    N60MIMOTreatmentTransitionRuntime * _Nonnull runtime,
    bool authorized
) {
    if (runtime == NULL) return;
    atomic_store_explicit(
        &runtime->authorized,
        authorized,
        memory_order_release
    );
}

static inline bool N60MIMOTreatmentTransitionRequestArm(
    N60MIMOTreatmentTransitionRuntime * _Nonnull runtime
) {
    if (runtime == NULL
        || !atomic_load_explicit(
            &runtime->authorized,
            memory_order_acquire
        )) {
        return false;
    }
    atomic_store_explicit(&runtime->armRequested, true, memory_order_release);
    atomic_fetch_add_explicit(
        &runtime->armRequests,
        1u,
        memory_order_relaxed
    );
    return true;
}

static inline void N60MIMOTreatmentTransitionRequestBypass(
    N60MIMOTreatmentTransitionRuntime * _Nonnull runtime
) {
    if (runtime == NULL) return;
    atomic_store_explicit(&runtime->armRequested, false, memory_order_release);
    atomic_fetch_add_explicit(
        &runtime->bypassRequests,
        1u,
        memory_order_relaxed
    );
}

static inline bool N60MIMOTreatmentTransitionLatchFault(
    N60MIMOTreatmentTransitionRuntime * _Nonnull runtime,
    N60MIMOTreatmentFault fault
) {
    if (runtime == NULL || fault == N60MIMOTreatmentFaultNone) return false;
    uint32_t expected = (uint32_t)N60MIMOTreatmentFaultNone;
    const bool latched = atomic_compare_exchange_strong_explicit(
        &runtime->pendingFault,
        &expected,
        (uint32_t)fault,
        memory_order_acq_rel,
        memory_order_acquire
    );
    if (latched) {
        atomic_fetch_add_explicit(
            &runtime->faultRequests,
            1u,
            memory_order_relaxed
        );
    }
    return latched;
}

static inline void N60MIMOTreatmentTransitionRequestFaultClear(
    N60MIMOTreatmentTransitionRuntime * _Nonnull runtime
) {
    if (runtime == NULL) return;
    atomic_store_explicit(
        &runtime->clearFaultRequested,
        true,
        memory_order_release
    );
}

static inline void N60MIMOTreatmentAdvanceTransition(
    N60MIMOTreatmentTransitionRuntime * _Nonnull runtime
) {
    if (runtime->transitionFrames == 0u) return;

    runtime->transitionPosition += 1u;
    const float normalized =
        (float)runtime->transitionPosition
        / (float)runtime->transitionFrames;
    const float shaped = N60MIMOTreatmentSmoothstep(normalized);
    runtime->mix =
        runtime->transitionStartMix
        + (runtime->transitionTargetMix - runtime->transitionStartMix)
            * shaped;

    if (runtime->transitionPosition < runtime->transitionFrames) return;

    runtime->mix = runtime->transitionTargetMix;
    runtime->transitionPosition = 0u;
    runtime->transitionFrames = 0u;
    atomic_fetch_add_explicit(
        &runtime->completedTransitions,
        1u,
        memory_order_relaxed
    );

    if (runtime->state == N60MIMOTreatmentStateArming) {
        runtime->state = N60MIMOTreatmentStateActive;
    } else if (runtime->state == N60MIMOTreatmentStateDisarming) {
        runtime->state = N60MIMOTreatmentStateBypassed;
    } else if (runtime->state == N60MIMOTreatmentStateFaultFading) {
        runtime->state = N60MIMOTreatmentStateFaulted;
    }
}

/// Standalone realtime-safe transition reference.
///
/// Both latency-matched identity and treatment FIR engines are kept warm at all
/// times so arm/bypass/fault transitions do not introduce a history discontinuity.
/// This function is not connected to the production output graph in PR76.
static inline bool N60MIMOTreatmentTransitionProcessFrame(
    N60MIMOTreatmentTransitionRuntime * _Nonnull runtime,
    const float * _Nonnull input,
    float * _Nonnull output
) {
    if (runtime == NULL
        || runtime->identityRuntime == NULL
        || runtime->treatmentRuntime == NULL
        || runtime->treatmentProgram == NULL
        || input == NULL
        || output == NULL) {
        return false;
    }

    const uint32_t channels = runtime->treatmentProgram->channelCount;
    float identity[N60_MIMO_FIR_MAX_CHANNELS] = {0};
    float treatment[N60_MIMO_FIR_MAX_CHANNELS] = {0};

    const bool identityOK = N60MIMOFIRRuntimeProcessFrame(
        runtime->identityRuntime,
        input,
        identity
    );
    if (!identityOK) {
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            output[channel] = 0.0f;
        }
        runtime->mix = 0.0f;
        runtime->fault = N60MIMOTreatmentFaultIdentityRuntimeFailure;
        runtime->state = N60MIMOTreatmentStateFaulted;
        atomic_fetch_add_explicit(
            &runtime->hardRuntimeFailures,
            1u,
            memory_order_relaxed
        );
        N60MIMOTreatmentPublishRuntimeState(runtime);
        return false;
    }

    const bool treatmentOK = N60MIMOFIRRuntimeProcessFrame(
        runtime->treatmentRuntime,
        input,
        treatment
    );
    if (!treatmentOK) {
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            output[channel] = identity[channel];
        }
        runtime->mix = 0.0f;
        runtime->fault = N60MIMOTreatmentFaultTreatmentRuntimeFailure;
        runtime->state = N60MIMOTreatmentStateFaulted;
        atomic_fetch_add_explicit(
            &runtime->hardRuntimeFailures,
            1u,
            memory_order_relaxed
        );
        N60MIMOTreatmentPublishRuntimeState(runtime);
        return true;
    }

    const bool authorized = atomic_load_explicit(
        &runtime->authorized,
        memory_order_acquire
    );
    const bool armRequested = atomic_load_explicit(
        &runtime->armRequested,
        memory_order_acquire
    );

    if (!authorized
        && runtime->state != N60MIMOTreatmentStateBypassed
        && runtime->state != N60MIMOTreatmentStateFaulted
        && runtime->fault == N60MIMOTreatmentFaultNone) {
        runtime->fault = N60MIMOTreatmentFaultAuthorizationRevoked;
        N60MIMOTreatmentBeginTransition(
            runtime,
            N60MIMOTreatmentStateFaultFading,
            0.0f,
            runtime->faultFadeFrames
        );
    }

    const uint32_t pending = atomic_exchange_explicit(
        &runtime->pendingFault,
        (uint32_t)N60MIMOTreatmentFaultNone,
        memory_order_acq_rel
    );
    if (pending != (uint32_t)N60MIMOTreatmentFaultNone
        && runtime->fault == N60MIMOTreatmentFaultNone) {
        runtime->fault = (N60MIMOTreatmentFault)pending;
        if (runtime->mix > 0.0f
            || runtime->state == N60MIMOTreatmentStateArming
            || runtime->state == N60MIMOTreatmentStateActive
            || runtime->state == N60MIMOTreatmentStateDisarming) {
            N60MIMOTreatmentBeginTransition(
                runtime,
                N60MIMOTreatmentStateFaultFading,
                0.0f,
                runtime->faultFadeFrames
            );
        } else {
            runtime->mix = 0.0f;
            runtime->state = N60MIMOTreatmentStateFaulted;
        }
    }

    if (runtime->fault == N60MIMOTreatmentFaultNone) {
        switch (runtime->state) {
        case N60MIMOTreatmentStateBypassed:
            runtime->mix = 0.0f;
            if (armRequested && authorized) {
                N60MIMOTreatmentBeginTransition(
                    runtime,
                    N60MIMOTreatmentStateArming,
                    1.0f,
                    runtime->fadeFrames
                );
            }
            break;
        case N60MIMOTreatmentStateArming:
            if (!armRequested) {
                N60MIMOTreatmentBeginTransition(
                    runtime,
                    N60MIMOTreatmentStateDisarming,
                    0.0f,
                    runtime->fadeFrames
                );
            }
            break;
        case N60MIMOTreatmentStateActive:
            runtime->mix = 1.0f;
            if (!armRequested) {
                N60MIMOTreatmentBeginTransition(
                    runtime,
                    N60MIMOTreatmentStateDisarming,
                    0.0f,
                    runtime->fadeFrames
                );
            }
            break;
        case N60MIMOTreatmentStateDisarming:
            if (armRequested && authorized) {
                N60MIMOTreatmentBeginTransition(
                    runtime,
                    N60MIMOTreatmentStateArming,
                    1.0f,
                    runtime->fadeFrames
                );
            }
            break;
        case N60MIMOTreatmentStateFaultFading:
        case N60MIMOTreatmentStateFaulted:
            break;
        }
    }

    if (runtime->state == N60MIMOTreatmentStateArming
        || runtime->state == N60MIMOTreatmentStateDisarming
        || runtime->state == N60MIMOTreatmentStateFaultFading) {
        N60MIMOTreatmentAdvanceTransition(runtime);
    }

    if (runtime->state == N60MIMOTreatmentStateFaulted
        && !armRequested
        && atomic_exchange_explicit(
            &runtime->clearFaultRequested,
            false,
            memory_order_acq_rel
        )) {
        runtime->fault = N60MIMOTreatmentFaultNone;
        runtime->state = N60MIMOTreatmentStateBypassed;
        runtime->mix = 0.0f;
    }

    const float mix = runtime->mix;
    for (uint32_t channel = 0u; channel < channels; ++channel) {
        const float dry = identity[channel];
        const float wet = treatment[channel];
        const float value = dry + (wet - dry) * mix;
        output[channel] = isfinite(value) ? value : dry;
    }

    atomic_fetch_add_explicit(
        &runtime->processedFrames,
        1u,
        memory_order_relaxed
    );
    N60MIMOTreatmentPublishRuntimeState(runtime);
    return true;
}

static inline N60MIMOTreatmentTransitionSnapshot
N60MIMOTreatmentTransitionGetSnapshot(
    const N60MIMOTreatmentTransitionRuntime * _Nullable runtime
) {
    N60MIMOTreatmentTransitionSnapshot snapshot = {0};
    if (runtime == NULL || runtime->treatmentProgram == NULL) return snapshot;

    const N60MIMOFIRProgramInfo info =
        N60MIMOFIRProgramGetInfo(runtime->treatmentProgram);
    snapshot.state = (N60MIMOTreatmentState)atomic_load_explicit(
        &runtime->publishedState,
        memory_order_acquire
    );
    snapshot.fault = (N60MIMOTreatmentFault)atomic_load_explicit(
        &runtime->publishedFault,
        memory_order_acquire
    );
    snapshot.authorized = atomic_load_explicit(
        &runtime->authorized,
        memory_order_acquire
    );
    snapshot.armRequested = atomic_load_explicit(
        &runtime->armRequested,
        memory_order_acquire
    );
    snapshot.treatmentMix = N60MIMOTreatmentMixFromQ24(
        atomic_load_explicit(
            &runtime->publishedMixQ24,
            memory_order_acquire
        )
    );
    snapshot.channelCount = info.channelCount;
    snapshot.tapCount = info.tapCount;
    snapshot.declaredLatencyFrames = info.declaredLatencyFrames;
    snapshot.engineLatencyFrames = info.engineLatencyFrames;
    snapshot.totalLatencyFrames =
        info.declaredLatencyFrames + info.engineLatencyFrames;
    snapshot.fadeFrames = runtime->fadeFrames;
    snapshot.faultFadeFrames = runtime->faultFadeFrames;
    snapshot.processedFrames = atomic_load_explicit(
        &runtime->processedFrames,
        memory_order_relaxed
    );
    snapshot.armRequests = atomic_load_explicit(
        &runtime->armRequests,
        memory_order_relaxed
    );
    snapshot.bypassRequests = atomic_load_explicit(
        &runtime->bypassRequests,
        memory_order_relaxed
    );
    snapshot.faultRequests = atomic_load_explicit(
        &runtime->faultRequests,
        memory_order_relaxed
    );
    snapshot.completedTransitions = atomic_load_explicit(
        &runtime->completedTransitions,
        memory_order_relaxed
    );
    snapshot.hardRuntimeFailures = atomic_load_explicit(
        &runtime->hardRuntimeFailures,
        memory_order_relaxed
    );
    return snapshot;
}

#ifdef __cplusplus
}
#endif

#endif
