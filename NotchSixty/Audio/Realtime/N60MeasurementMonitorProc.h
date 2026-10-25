#ifndef N60MeasurementMonitorProc_h
#define N60MeasurementMonitorProc_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "n60/measure.h"

#ifdef __cplusplus
extern "C" {
#endif

/// E11 S8: input-only monitor callback for the RTA and SPL meter. It copies one input channel of a microphone
/// device into the core's SPSC ring (`n60_monitor_ring_push`) and does nothing else: no output, no aggregate, no
/// allocation, no locks. The context only borrows the ring, which the owner keeps alive until the IOProc is
/// destroyed.
typedef struct N60MeasurementMonitorContext N60MeasurementMonitorContext;

N60MeasurementMonitorContext * _Nullable N60MeasurementMonitorContextCreate(
    n60_monitor_ring * _Nonnull ring,
    uint32_t channelIndex
);
void N60MeasurementMonitorContextDestroy(N60MeasurementMonitorContext * _Nullable context);
/// Callbacks served and callbacks whose buffer layout was unusable (channel missing, not 4-byte frames).
void N60MeasurementMonitorContextCounters(
    const N60MeasurementMonitorContext * _Nonnull context,
    uint64_t * _Nonnull callbacks,
    uint64_t * _Nonnull unsupportedLayouts
);

OSStatus N60MeasurementMonitorIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
);

#ifdef __cplusplus
}
#endif

#endif
