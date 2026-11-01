#include "N60LevelSessionProc.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"

#if defined(__APPLE__)
#include "N60TargetedRoomMeasurementBridge.h"
#endif

struct N60LevelSessionContext {
    n60_graph *graph;
    n60_monitor_ring *ring;
    uint32_t inputChannel;
    uint32_t laneCount;
    uint32_t maxBlockFrames;
    uint32_t outputChannels[N60_LEVEL_SESSION_MAX_LANES];
    /* laneCount planes of maxBlockFrames: silent input (never written after Create) and rendered output. */
    float *silence;
    float *planes;
    const float *inPointers[N60_LEVEL_SESSION_MAX_LANES];
    float *outPointers[N60_LEVEL_SESSION_MAX_LANES];
    _Atomic uint64_t callbacks;
    _Atomic uint64_t unsupported;
    _Atomic uint64_t failures;
    _Atomic uint64_t frames;
    _Atomic bool stopRequested;
    _Atomic bool rampDone;
    _Atomic uint32_t lastPeakBits;
};

N60LevelSessionContext *N60LevelSessionContextCreate(
    void *graph, n60_monitor_ring *ring, uint32_t inputChannel,
    const uint32_t *outputChannels, uint32_t laneCount, uint32_t maxBlockFrames
) {
    if (graph == NULL || outputChannels == NULL || laneCount == 0u || laneCount > N60_LEVEL_SESSION_MAX_LANES
        || maxBlockFrames == 0u || maxBlockFrames > (1u << 20)) return NULL;
    N60LevelSessionContext *context = calloc(1, sizeof(*context));
    if (context == NULL) return NULL;
    const size_t samples = (size_t)laneCount * maxBlockFrames;
    context->silence = calloc(samples, sizeof(float));
    context->planes = calloc(samples, sizeof(float));
    if (context->silence == NULL || context->planes == NULL) {
        N60LevelSessionContextDestroy(context);
        return NULL;
    }
    context->graph = (n60_graph *)graph;
    context->ring = ring;
    context->inputChannel = inputChannel;
    context->laneCount = laneCount;
    context->maxBlockFrames = maxBlockFrames;
    for (uint32_t lane = 0; lane < laneCount; ++lane) {
        context->outputChannels[lane] = outputChannels[lane];
        context->inPointers[lane] = context->silence + (size_t)lane * maxBlockFrames;
        context->outPointers[lane] = context->planes + (size_t)lane * maxBlockFrames;
    }
    return context;
}

void N60LevelSessionContextDestroy(N60LevelSessionContext *context) {
    if (context == NULL) return;
    free(context->silence);
    free(context->planes);
    free(context);
}

void N60LevelSessionContextSetInputChannel(N60LevelSessionContext *context, uint32_t inputChannel) {
    context->inputChannel = inputChannel;
}

void N60LevelSessionContextRequestStop(N60LevelSessionContext *context) {
    atomic_store_explicit(&context->stopRequested, true, memory_order_release);
}

N60LevelSessionSnapshot N60LevelSessionContextSnapshot(const N60LevelSessionContext *context) {
    N60LevelSessionSnapshot s;
    memset(&s, 0, sizeof s);
    s.callbacks = atomic_load_explicit(&context->callbacks, memory_order_relaxed);
    s.unsupportedBufferLayouts = atomic_load_explicit(&context->unsupported, memory_order_relaxed);
    s.processFailures = atomic_load_explicit(&context->failures, memory_order_relaxed);
    s.framesRendered = atomic_load_explicit(&context->frames, memory_order_relaxed);
    s.stopRequested = atomic_load_explicit(&context->stopRequested, memory_order_acquire);
    s.rampDone = atomic_load_explicit(&context->rampDone, memory_order_acquire);
    const uint32_t bits = atomic_load_explicit(&context->lastPeakBits, memory_order_relaxed);
    memcpy(&s.lastPeak, &bits, sizeof bits);
    return s;
}

uint32_t N60LevelSessionProcess(
    N60LevelSessionContext *context, const float *mic, uint32_t micStride,
    float *const *lanes, const uint32_t *strides, uint32_t frames
) {
    atomic_fetch_add_explicit(&context->callbacks, 1u, memory_order_relaxed);
    /* Read the stop flag before rendering: the owner posts active = 0 before setting it, so a block that sees it
     * also sees the posted parameter when the graph drains its mailbox. */
    const bool stopping = atomic_load_explicit(&context->stopRequested, memory_order_acquire);
    if (mic != NULL && context->ring != NULL && frames > 0u) {
        (void)n60_monitor_ring_push(context->ring, mic, micStride, frames);
    }
    float peak = 0.0f;
    bool failed = false;
    uint32_t done = 0u;
    while (done < frames) {
        uint32_t n = frames - done;
        if (n > context->maxBlockFrames) n = context->maxBlockFrames;
        if (n60_graph_process(context->graph, context->inPointers, context->outPointers, n) != N60_STATUS_OK) {
            atomic_fetch_add_explicit(&context->failures, 1u, memory_order_relaxed);
            failed = true;
            for (uint32_t lane = 0; lane < context->laneCount; ++lane) {
                memset(context->outPointers[lane], 0, sizeof(float) * n);
            }
        }
        for (uint32_t lane = 0; lane < context->laneCount; ++lane) {
            float *dst = lanes[lane];
            if (dst == NULL) continue;
            const uint32_t stride = strides[lane];
            const float *src = context->outPointers[lane];
            for (uint32_t i = 0; i < n; ++i) {
                float v = src[i];
                if (!isfinite(v)) v = 0.0f;
                if (v > 1.0f) v = 1.0f;
                if (v < -1.0f) v = -1.0f;
                const float a = fabsf(v);
                if (a > peak) peak = a;
                dst[(size_t)(done + i) * stride] = v;
            }
        }
        done += n;
    }
    uint32_t bits;
    memcpy(&bits, &peak, sizeof bits);
    atomic_store_explicit(&context->lastPeakBits, bits, memory_order_relaxed);
    atomic_fetch_add_explicit(&context->frames, frames, memory_order_relaxed);
    if (stopping && !failed && peak == 0.0f && frames > 0u) {
        atomic_store_explicit(&context->rampDone, true, memory_order_release);
    }
    return done;
}

#if defined(__APPLE__)
OSStatus N60LevelSessionIOProc(
    AudioDeviceID inDevice, const AudioTimeStamp *inNow, const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void)inDevice; (void)inNow; (void)inInputTime; (void)inOutputTime;
    N60LevelSessionContext *context = (N60LevelSessionContext *)inClientData;
    if (context == NULL || outOutputData == NULL) return noErr;
    N60TargetedRoomMeasurementZeroOutput(outOutputData);

    float *lanes[N60_LEVEL_SESSION_MAX_LANES];
    uint32_t strides[N60_LEVEL_SESSION_MAX_LANES];
    uint32_t frames = UINT32_MAX;
    bool layoutOK = true;
    for (uint32_t lane = 0; lane < context->laneCount; ++lane) {
        N60TargetedMeasurementOutputView view = {0};
        if (N60TargetedRoomMeasurementMakeOutputView(outOutputData, context->outputChannels[lane], &view)) {
            lanes[lane] = view.samples;
            strides[lane] = view.stride;
            if (view.frameCount < frames) frames = view.frameCount;
        } else {
            lanes[lane] = NULL;
            strides[lane] = 1u;
            layoutOK = false;
        }
    }
    if (!layoutOK) atomic_fetch_add_explicit(&context->unsupported, 1u, memory_order_relaxed);
    if (frames == UINT32_MAX || frames == 0u) return noErr;

    N60TargetedMeasurementInputView input = {0};
    const bool haveMic = N60TargetedRoomMeasurementMakeInputView(inInputData, context->inputChannel, &input);
    if (!haveMic) atomic_fetch_add_explicit(&context->unsupported, 1u, memory_order_relaxed);
    (void)N60LevelSessionProcess(context, haveMic ? input.samples : NULL, haveMic ? input.stride : 0u,
                                 lanes, strides, haveMic && input.frameCount < frames ? input.frameCount : frames);
    return noErr;
}
#endif
