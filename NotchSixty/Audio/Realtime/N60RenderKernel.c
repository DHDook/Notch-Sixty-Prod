#include "N60RenderKernel.h"

#include <math.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdlib.h>

#define N60_SNAPSHOT_SLOT_COUNT 2
#define N60_SNAPSHOT_ACQUIRE_ATTEMPTS 3

typedef struct {
    N60DSPGraphSnapshot snapshot;
    _Atomic uint32_t readers;
} N60SnapshotSlot;

struct N60RenderKernel {
    N60SnapshotSlot slots[N60_SNAPSHOT_SLOT_COUNT];
    _Atomic uint32_t activeSlot;
    _Atomic uint64_t nextGeneration;

    _Atomic uint64_t renderedFrames;
    _Atomic uint64_t sanitizedNonFiniteSamples;
    _Atomic uint64_t flushedDenormalSamples;
    _Atomic uint64_t snapshotReadMisses;
};

static bool snapshot_is_valid(N60DSPGraphSnapshot snapshot) {
    return isfinite(snapshot.sampleRate)
        && snapshot.sampleRate > 0.0
        && snapshot.channelCount == 2
        && isfinite(snapshot.inputGainLinear)
        && isfinite(snapshot.outputGainLinear);
}

static float sanitize_sample(N60RenderKernel *kernel, float sample) {
    if (!isfinite(sample)) {
        atomic_fetch_add_explicit(&kernel->sanitizedNonFiniteSamples, 1, memory_order_relaxed);
        return 0.0f;
    }

    if (fpclassify(sample) == FP_SUBNORMAL) {
        atomic_fetch_add_explicit(&kernel->flushedDenormalSamples, 1, memory_order_relaxed);
        return 0.0f;
    }

    return sample;
}

static N60RenderKernelRenderContext acquire_render_context(N60RenderKernel *kernel) {
    N60RenderKernelRenderContext context = {0};
    if (kernel == NULL) {
        return context;
    }

    for (uint32_t attempt = 0; attempt < N60_SNAPSHOT_ACQUIRE_ATTEMPTS; ++attempt) {
        uint32_t slotIndex = atomic_load_explicit(&kernel->activeSlot, memory_order_acquire);
        N60SnapshotSlot *slot = &kernel->slots[slotIndex];

        atomic_fetch_add_explicit(&slot->readers, 1, memory_order_acq_rel);
        if (slotIndex == atomic_load_explicit(&kernel->activeSlot, memory_order_acquire)) {
            context.snapshot = slot->snapshot;
            context.slotIndex = slotIndex;
            context.acquired = true;
            return context;
        }
        atomic_fetch_sub_explicit(&slot->readers, 1, memory_order_release);
    }

    atomic_fetch_add_explicit(&kernel->snapshotReadMisses, 1, memory_order_relaxed);
    return context;
}

N60DSPGraphSnapshot N60DSPGraphSnapshotMakeUnity(double sampleRate) {
    N60DSPGraphSnapshot snapshot = {0};
    snapshot.sampleRate = sampleRate;
    snapshot.channelCount = 2;
    snapshot.inputGainLinear = 1.0f;
    snapshot.outputGainLinear = 1.0f;
    snapshot.bypassed = false;
    snapshot.latencyFrames = 0;
    snapshot.generation = 0;
    return snapshot;
}

N60RenderKernel *N60RenderKernelCreate(void) {
    N60RenderKernel *kernel = calloc(1, sizeof(N60RenderKernel));
    if (kernel == NULL) {
        return NULL;
    }

    N60DSPGraphSnapshot initial = N60DSPGraphSnapshotMakeUnity(48000.0);
    initial.generation = 1;
    kernel->slots[0].snapshot = initial;
    kernel->slots[1].snapshot = initial;
    atomic_store_explicit(&kernel->activeSlot, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->nextGeneration, 1, memory_order_relaxed);
    return kernel;
}

void N60RenderKernelDestroy(N60RenderKernel *kernel) {
    free(kernel);
}

void N60RenderKernelReset(N60RenderKernel *kernel) {
    if (kernel == NULL) {
        return;
    }

    atomic_store_explicit(&kernel->renderedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->sanitizedNonFiniteSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->flushedDenormalSamples, 0, memory_order_relaxed);
    atomic_store_explicit(&kernel->snapshotReadMisses, 0, memory_order_relaxed);
}

bool N60RenderKernelPublishSnapshot(N60RenderKernel *kernel, N60DSPGraphSnapshot snapshot) {
    if (kernel == NULL || !snapshot_is_valid(snapshot)) {
        return false;
    }

    uint32_t active = atomic_load_explicit(&kernel->activeSlot, memory_order_acquire);
    uint32_t inactive = active == 0 ? 1 : 0;
    N60SnapshotSlot *slot = &kernel->slots[inactive];

    // Publication is control-plane only. Wait for a callback that still owns
    // the inactive slot from an older graph generation to release it.
    while (atomic_load_explicit(&slot->readers, memory_order_acquire) != 0) {
        sched_yield();
    }

    snapshot.generation = atomic_fetch_add_explicit(&kernel->nextGeneration, 1, memory_order_relaxed) + 1;
    slot->snapshot = snapshot;
    atomic_store_explicit(&kernel->activeSlot, inactive, memory_order_release);
    return true;
}

N60RenderKernelRenderContext N60RenderKernelBeginRender(N60RenderKernel *kernel) {
    return acquire_render_context(kernel);
}

void N60RenderKernelProcessStereoFrameInContext(
    N60RenderKernel *kernel,
    const N60RenderKernelRenderContext *context,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (kernel == NULL || context == NULL || outputLeft == NULL || outputRight == NULL) {
        return;
    }

    float left = sanitize_sample(kernel, inputLeft);
    float right = sanitize_sample(kernel, inputRight);

    if (context->acquired && !context->snapshot.bypassed) {
        left *= context->snapshot.inputGainLinear;
        right *= context->snapshot.inputGainLinear;

        // PR #12 reference processor: intentional identity stage.
        // Future graph stages are inserted here behind the same snapshot contract.

        left *= context->snapshot.outputGainLinear;
        right *= context->snapshot.outputGainLinear;
    }

    *outputLeft = sanitize_sample(kernel, left);
    *outputRight = sanitize_sample(kernel, right);
}

void N60RenderKernelEndRender(
    N60RenderKernel *kernel,
    N60RenderKernelRenderContext *context,
    uint32_t renderedFrames
) {
    if (kernel == NULL || context == NULL) {
        return;
    }

    if (context->acquired && context->slotIndex < N60_SNAPSHOT_SLOT_COUNT) {
        atomic_fetch_sub_explicit(&kernel->slots[context->slotIndex].readers, 1, memory_order_release);
        context->acquired = false;
    }
    atomic_fetch_add_explicit(&kernel->renderedFrames, renderedFrames, memory_order_relaxed);
}

void N60RenderKernelProcessStereoFrame(
    N60RenderKernel *kernel,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (kernel == NULL || outputLeft == NULL || outputRight == NULL) {
        return;
    }

    N60RenderKernelRenderContext context = N60RenderKernelBeginRender(kernel);
    N60RenderKernelProcessStereoFrameInContext(
        kernel,
        &context,
        inputLeft,
        inputRight,
        outputLeft,
        outputRight
    );
    N60RenderKernelEndRender(kernel, &context, 1);
}

N60RenderKernelDiagnostics N60RenderKernelGetDiagnostics(const N60RenderKernel *kernel) {
    N60RenderKernelDiagnostics diagnostics = {0};
    if (kernel == NULL) {
        return diagnostics;
    }

    N60RenderKernel *mutableKernel = (N60RenderKernel *)kernel;
    N60RenderKernelRenderContext context = acquire_render_context(mutableKernel);
    if (context.acquired) {
        diagnostics.publishedGeneration = context.snapshot.generation;
        diagnostics.latencyFrames = context.snapshot.latencyFrames;
        diagnostics.sampleRate = context.snapshot.sampleRate;
        diagnostics.channelCount = context.snapshot.channelCount;
        diagnostics.bypassed = context.snapshot.bypassed;
        N60RenderKernelEndRender(mutableKernel, &context, 0);
    }

    diagnostics.renderedFrames = atomic_load_explicit(&kernel->renderedFrames, memory_order_relaxed);
    diagnostics.sanitizedNonFiniteSamples = atomic_load_explicit(&kernel->sanitizedNonFiniteSamples, memory_order_relaxed);
    diagnostics.flushedDenormalSamples = atomic_load_explicit(&kernel->flushedDenormalSamples, memory_order_relaxed);
    diagnostics.snapshotReadMisses = atomic_load_explicit(&kernel->snapshotReadMisses, memory_order_relaxed);
    return diagnostics;
}
