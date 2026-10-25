#include "N60MeasurementMonitorProc.h"

#include <stdatomic.h>
#include <stdlib.h>

struct N60MeasurementMonitorContext {
    n60_monitor_ring *ring;
    uint32_t channel;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t unsupported;
};

N60MeasurementMonitorContext *N60MeasurementMonitorContextCreate(n60_monitor_ring *ring, uint32_t channelIndex) {
    if (ring == NULL) return NULL;
    N60MeasurementMonitorContext *context = calloc(1, sizeof(*context));
    if (context == NULL) return NULL;
    context->ring = ring;
    context->channel = channelIndex;
    return context;
}

void N60MeasurementMonitorContextDestroy(N60MeasurementMonitorContext *context) { free(context); }

void N60MeasurementMonitorContextCounters(
    const N60MeasurementMonitorContext *context, uint64_t *callbacks, uint64_t *unsupportedLayouts
) {
    *callbacks = atomic_load_explicit(&context->callbacks, memory_order_relaxed);
    *unsupportedLayouts = atomic_load_explicit(&context->unsupported, memory_order_relaxed);
}

OSStatus N60MeasurementMonitorIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void)inDevice; (void)inNow; (void)inInputTime; (void)outOutputData; (void)inOutputTime;
    N60MeasurementMonitorContext *context = (N60MeasurementMonitorContext *)inClientData;
    if (context == NULL) return noErr;
    atomic_fetch_add_explicit(&context->callbacks, 1, memory_order_relaxed);
    if (inInputData == NULL) {
        atomic_fetch_add_explicit(&context->unsupported, 1, memory_order_relaxed);
        return noErr;
    }
    uint32_t channel = context->channel;
    for (UInt32 i = 0; i < inInputData->mNumberBuffers; ++i) {
        const AudioBuffer *buffer = &inInputData->mBuffers[i];
        if (channel >= buffer->mNumberChannels) {
            channel -= buffer->mNumberChannels;
            continue;
        }
        const uint32_t stride = buffer->mNumberChannels;
        const uint32_t bytes = stride * (uint32_t)sizeof(float);
        if (buffer->mData == NULL || bytes == 0 || buffer->mDataByteSize % bytes != 0) break;
        n60_monitor_ring_push(context->ring, ((const float *)buffer->mData) + channel, stride,
                              buffer->mDataByteSize / bytes);
        return noErr;
    }
    atomic_fetch_add_explicit(&context->unsupported, 1, memory_order_relaxed);
    return noErr;
}
