#ifndef N60HeadTrackedBinauralRuntime_h
#define N60HeadTrackedBinauralRuntime_h

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "N60BinauralRenderer.h"
#include "N60HeadTracking.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool lockFreePosePublication;
    bool transitionBusy;
    uint32_t activeRendererIndex;
    uint64_t acceptedGenerations;
    uint64_t completedTransitions;
    uint64_t rejectedGenerations;
    N60HeadPose currentPose;
} N60HeadTrackedBinauralSnapshot;

typedef struct {
    uint64_t appliedCommandSequence;
    bool active;
    uint32_t oldIndex;
    uint32_t newIndex;
    uint32_t warmupFramesRemaining;
    N60SpatialCrossfade crossfade;
} N60HeadTrackedBinauralTransitionRuntime;

typedef struct N60HeadTrackedBinauralRuntime {
    N60BinauralRenderer * _Nullable renderers[2];
    N60HeadPoseAtomic poseAtomic;

    _Atomic uint32_t activeRendererIndex;
    _Atomic bool transitionBusy;
    _Atomic uint64_t commandSequence;
    _Atomic uint32_t pendingRendererIndex;
    _Atomic uint32_t pendingWarmupFrames;
    _Atomic uint32_t pendingCrossfadeFrames;
    _Atomic uint64_t acceptedGenerations;
    _Atomic uint64_t completedTransitions;
    _Atomic uint64_t rejectedGenerations;

    N60HeadTrackedBinauralTransitionRuntime transition;
} N60HeadTrackedBinauralRuntime;

static inline void N60HeadTrackedBinauralBeginCommandWrite(
    N60HeadTrackedBinauralRuntime * _Nonnull runtime
) {
    atomic_fetch_add_explicit(&runtime->commandSequence, 1u, memory_order_acq_rel);
}

static inline void N60HeadTrackedBinauralEndCommandWrite(
    N60HeadTrackedBinauralRuntime * _Nonnull runtime
) {
    atomic_fetch_add_explicit(&runtime->commandSequence, 1u, memory_order_release);
}

/// Control-plane creation. Both renderer objects and all FFT/history memory are
/// allocated before callbacks start; only generation 0 is initially prepared.
static inline N60HeadTrackedBinauralRuntime * _Nullable N60HeadTrackedBinauralRuntimeCreate(
    N60BinauralProfileDescriptor initialDescriptor,
    const float * _Nonnull leftIRs,
    const float * _Nonnull rightIRs
) {
    if (leftIRs == NULL || rightIRs == NULL
        || !N60BinauralProfileDescriptorIsValid(
            &initialDescriptor, N60_BINAURAL_MAX_TAPS
        )) {
        return NULL;
    }

    N60HeadTrackedBinauralRuntime * _Nullable runtime =
        (N60HeadTrackedBinauralRuntime *)calloc(
            1u, sizeof(N60HeadTrackedBinauralRuntime)
        );
    if (runtime == NULL) return NULL;

    runtime->renderers[0] = N60BinauralRendererCreate();
    runtime->renderers[1] = N60BinauralRendererCreate();
    if (runtime->renderers[0] == NULL
        || runtime->renderers[1] == NULL
        || !N60BinauralRendererPrepareProfile(
            runtime->renderers[0], initialDescriptor, leftIRs, rightIRs
        )) {
        N60BinauralRendererDestroy(runtime->renderers[0]);
        N60BinauralRendererDestroy(runtime->renderers[1]);
        free(runtime);
        return NULL;
    }

    N60HeadPoseAtomicInitialize(
        &runtime->poseAtomic,
        (N60HeadPose){ .yawDegrees = 0.0, .pitchDegrees = 0.0, .rollDegrees = 0.0 }
    );
    atomic_init(&runtime->activeRendererIndex, 0u);
    atomic_init(&runtime->transitionBusy, false);
    atomic_init(&runtime->commandSequence, 0u);
    atomic_init(&runtime->pendingRendererIndex, 1u);
    atomic_init(&runtime->pendingWarmupFrames, 0u);
    atomic_init(&runtime->pendingCrossfadeFrames, 0u);
    atomic_init(&runtime->acceptedGenerations, 0u);
    atomic_init(&runtime->completedTransitions, 0u);
    atomic_init(&runtime->rejectedGenerations, 0u);
    return runtime;
}

static inline void N60HeadTrackedBinauralRuntimeDestroy(
    N60HeadTrackedBinauralRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    N60BinauralRendererDestroy(runtime->renderers[0]);
    N60BinauralRendererDestroy(runtime->renderers[1]);
    runtime->renderers[0] = NULL;
    runtime->renderers[1] = NULL;
    free(runtime);
}

/// Control-plane reset only; audio callbacks must be stopped.
static inline bool N60HeadTrackedBinauralRuntimeReset(
    N60HeadTrackedBinauralRuntime * _Nonnull runtime
) {
    if (runtime == NULL || runtime->renderers[0] == NULL
        || runtime->renderers[1] == NULL) {
        return false;
    }
    N60BinauralRendererResetRuntime(runtime->renderers[0]);
    N60BinauralRendererResetRuntime(runtime->renderers[1]);
    runtime->transition = (N60HeadTrackedBinauralTransitionRuntime){0};
    atomic_store_explicit(&runtime->activeRendererIndex, 0u, memory_order_release);
    atomic_store_explicit(&runtime->transitionBusy, false, memory_order_release);
    atomic_store_explicit(&runtime->commandSequence, 0u, memory_order_release);
    atomic_store_explicit(&runtime->acceptedGenerations, 0u, memory_order_relaxed);
    atomic_store_explicit(&runtime->completedTransitions, 0u, memory_order_relaxed);
    atomic_store_explicit(&runtime->rejectedGenerations, 0u, memory_order_relaxed);
    return N60HeadPoseAtomicPublish(
        &runtime->poseAtomic,
        (N60HeadPose){ .yawDegrees = 0.0, .pitchDegrees = 0.0, .rollDegrees = 0.0 }
    );
}

static inline bool N60HeadTrackedBinauralRuntimePoseIsLockFree(
    const N60HeadTrackedBinauralRuntime * _Nullable runtime
) {
    return runtime != NULL && N60HeadPoseAtomicIsLockFree(&runtime->poseAtomic);
}

static inline bool N60HeadTrackedBinauralRuntimeCanPrepareGeneration(
    const N60HeadTrackedBinauralRuntime * _Nullable runtime
) {
    return runtime != NULL
        && !atomic_load_explicit(&runtime->transitionBusy, memory_order_acquire);
}

static inline bool N60HeadTrackedBinauralDescriptorMatchesActiveContract(
    const N60HeadTrackedBinauralRuntime * _Nonnull runtime,
    const N60BinauralProfileDescriptor * _Nonnull descriptor
) {
    if (runtime == NULL || descriptor == NULL) return false;
    const uint32_t active = atomic_load_explicit(
        &runtime->activeRendererIndex, memory_order_acquire
    );
    if (active > 1u || runtime->renderers[active] == NULL
        || !runtime->renderers[active]->prepared) {
        return false;
    }
    const N60BinauralProfileDescriptor current = runtime->renderers[active]->descriptor;
    if (descriptor->sampleRate != current.sampleRate
        || descriptor->tapCount != current.tapCount
        || descriptor->declaredLatencyFrames != current.declaredLatencyFrames
        || descriptor->kind != current.kind
        || descriptor->lfeMode != current.lfeMode
        || descriptor->programLayout.channelCount != current.programLayout.channelCount) {
        return false;
    }
    for (uint32_t channel = 0; channel < current.programLayout.channelCount; ++channel) {
        if (descriptor->programLayout.channels[channel]
            != current.programLayout.channels[channel]) {
            return false;
        }
    }
    return true;
}

/// Control-plane generation preparation. Claims the inactive renderer with one
/// atomic busy flag, writes all kernels off realtime, publishes one coherent
/// PR59 pose snapshot, then sends a compact transition command to the callback.
static inline bool N60HeadTrackedBinauralRuntimePrepareGeneration(
    N60HeadTrackedBinauralRuntime * _Nonnull runtime,
    N60BinauralProfileDescriptor descriptor,
    const float * _Nonnull leftIRs,
    const float * _Nonnull rightIRs,
    N60HeadPose pose,
    uint32_t warmupFrames,
    uint32_t crossfadeFrames
) {
    if (runtime == NULL || leftIRs == NULL || rightIRs == NULL
        || crossfadeFrames == 0u || !N60HeadPoseIsValid(pose)
        || !N60BinauralProfileDescriptorIsValid(
            &descriptor, N60_BINAURAL_MAX_TAPS
        )
        || !N60HeadTrackedBinauralDescriptorMatchesActiveContract(
            runtime, &descriptor
        )) {
        if (runtime != NULL) {
            atomic_fetch_add_explicit(
                &runtime->rejectedGenerations, 1u, memory_order_relaxed
            );
        }
        return false;
    }

    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &runtime->transitionBusy,
            &expected,
            true,
            memory_order_acq_rel,
            memory_order_acquire)) {
        atomic_fetch_add_explicit(
            &runtime->rejectedGenerations, 1u, memory_order_relaxed
        );
        return false;
    }

    const uint32_t active = atomic_load_explicit(
        &runtime->activeRendererIndex, memory_order_acquire
    );
    const uint32_t inactive = active == 0u ? 1u : 0u;
    const bool prepared = runtime->renderers[inactive] != NULL
        && N60BinauralRendererPrepareProfile(
            runtime->renderers[inactive], descriptor, leftIRs, rightIRs
        )
        && N60HeadPoseAtomicPublish(&runtime->poseAtomic, pose);
    if (!prepared) {
        atomic_store_explicit(
            &runtime->transitionBusy, false, memory_order_release
        );
        atomic_fetch_add_explicit(
            &runtime->rejectedGenerations, 1u, memory_order_relaxed
        );
        return false;
    }

    N60HeadTrackedBinauralBeginCommandWrite(runtime);
    atomic_store_explicit(
        &runtime->pendingRendererIndex, inactive, memory_order_relaxed
    );
    atomic_store_explicit(
        &runtime->pendingWarmupFrames, warmupFrames, memory_order_relaxed
    );
    atomic_store_explicit(
        &runtime->pendingCrossfadeFrames, crossfadeFrames, memory_order_relaxed
    );
    N60HeadTrackedBinauralEndCommandWrite(runtime);
    atomic_fetch_add_explicit(
        &runtime->acceptedGenerations, 1u, memory_order_relaxed
    );
    return true;
}

/// Realtime callback boundary. Latches at most one generation command per audio
/// buffer. No waiting/retry loop; an in-progress control-plane write is simply
/// observed on the following callback.
static inline void N60HeadTrackedBinauralRuntimeBeginBuffer(
    N60HeadTrackedBinauralRuntime * _Nonnull runtime
) {
    if (runtime == NULL || runtime->transition.active) return;
    const uint64_t before = atomic_load_explicit(
        &runtime->commandSequence, memory_order_acquire
    );
    if ((before & 1u) != 0u
        || before == runtime->transition.appliedCommandSequence) {
        return;
    }
    const uint32_t pending = atomic_load_explicit(
        &runtime->pendingRendererIndex, memory_order_relaxed
    );
    const uint32_t warmup = atomic_load_explicit(
        &runtime->pendingWarmupFrames, memory_order_relaxed
    );
    const uint32_t crossfade = atomic_load_explicit(
        &runtime->pendingCrossfadeFrames, memory_order_relaxed
    );
    const uint64_t after = atomic_load_explicit(
        &runtime->commandSequence, memory_order_acquire
    );
    if (before != after || (after & 1u) != 0u || pending > 1u
        || crossfade == 0u) {
        return;
    }

    const uint32_t active = atomic_load_explicit(
        &runtime->activeRendererIndex, memory_order_acquire
    );
    if (pending == active) {
        runtime->transition.appliedCommandSequence = after;
        atomic_store_explicit(
            &runtime->transitionBusy, false, memory_order_release
        );
        return;
    }

    runtime->transition.appliedCommandSequence = after;
    runtime->transition.active = true;
    runtime->transition.oldIndex = active;
    runtime->transition.newIndex = pending;
    runtime->transition.warmupFramesRemaining = warmup;
    (void)N60SpatialCrossfadeStart(
        &runtime->transition.crossfade, crossfade
    );
}

/// Realtime-safe frame render. During a pending generation transition the new
/// renderer is first warmed with live program history, then PR59 smoothstep
/// crossfades two already-rendered stereo generations. No kernel prep/trig/search.
static inline bool N60HeadTrackedBinauralRuntimeProcessFrame(
    N60HeadTrackedBinauralRuntime * _Nonnull runtime,
    const float * _Nonnull programInput,
    uint32_t channelCount,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight
) {
    if (runtime == NULL || programInput == NULL
        || outputLeft == NULL || outputRight == NULL) {
        return false;
    }

    if (!runtime->transition.active) {
        const uint32_t active = atomic_load_explicit(
            &runtime->activeRendererIndex, memory_order_relaxed
        );
        if (active > 1u || runtime->renderers[active] == NULL) return false;
        return N60BinauralRendererProcessFrame(
            runtime->renderers[active],
            programInput,
            channelCount,
            outputLeft,
            outputRight
        );
    }

    N60BinauralRenderer * _Nullable oldRenderer =
        runtime->renderers[runtime->transition.oldIndex];
    N60BinauralRenderer * _Nullable newRenderer =
        runtime->renderers[runtime->transition.newIndex];
    if (oldRenderer == NULL || newRenderer == NULL) return false;

    float oldLeft = 0.0f, oldRight = 0.0f;
    float newLeft = 0.0f, newRight = 0.0f;
    const bool oldOK = N60BinauralRendererProcessFrame(
        oldRenderer, programInput, channelCount, &oldLeft, &oldRight
    );
    const bool newOK = N60BinauralRendererProcessFrame(
        newRenderer, programInput, channelCount, &newLeft, &newRight
    );
    if (!oldOK || !newOK) return false;

    if (runtime->transition.warmupFramesRemaining > 0u) {
        runtime->transition.warmupFramesRemaining -= 1u;
        *outputLeft = oldLeft;
        *outputRight = oldRight;
        return true;
    }

    N60SpatialCrossfadeProcessStereo(
        &runtime->transition.crossfade,
        oldLeft,
        oldRight,
        newLeft,
        newRight,
        outputLeft,
        outputRight
    );
    if (!runtime->transition.crossfade.active) {
        atomic_store_explicit(
            &runtime->activeRendererIndex,
            runtime->transition.newIndex,
            memory_order_release
        );
        runtime->transition.active = false;
        atomic_fetch_add_explicit(
            &runtime->completedTransitions, 1u, memory_order_relaxed
        );
        atomic_store_explicit(
            &runtime->transitionBusy, false, memory_order_release
        );
    }
    return true;
}

static inline uint64_t N60HeadTrackedBinauralRuntimeLatencyFrames(
    const N60HeadTrackedBinauralRuntime * _Nullable runtime
) {
    if (runtime == NULL) return 0u;
    const uint32_t active = atomic_load_explicit(
        &runtime->activeRendererIndex, memory_order_acquire
    );
    if (active > 1u || runtime->renderers[active] == NULL) return 0u;
    return N60BinauralRendererLatencyFrames(runtime->renderers[active]);
}

static inline N60HeadTrackedBinauralSnapshot N60HeadTrackedBinauralRuntimeGetSnapshot(
    const N60HeadTrackedBinauralRuntime * _Nullable runtime
) {
    if (runtime == NULL) return (N60HeadTrackedBinauralSnapshot){0};
    return (N60HeadTrackedBinauralSnapshot){
        .lockFreePosePublication = N60HeadTrackedBinauralRuntimePoseIsLockFree(runtime),
        .transitionBusy = atomic_load_explicit(
            &runtime->transitionBusy, memory_order_acquire
        ),
        .activeRendererIndex = atomic_load_explicit(
            &runtime->activeRendererIndex, memory_order_acquire
        ),
        .acceptedGenerations = atomic_load_explicit(
            &runtime->acceptedGenerations, memory_order_relaxed
        ),
        .completedTransitions = atomic_load_explicit(
            &runtime->completedTransitions, memory_order_relaxed
        ),
        .rejectedGenerations = atomic_load_explicit(
            &runtime->rejectedGenerations, memory_order_relaxed
        ),
        .currentPose = N60HeadPoseAtomicLoad(&runtime->poseAtomic),
    };
}

#ifdef __cplusplus
}
#endif

#endif
