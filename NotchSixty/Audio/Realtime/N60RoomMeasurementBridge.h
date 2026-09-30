#ifndef N60RoomMeasurementBridge_h
#define N60RoomMeasurementBridge_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct N60RoomMeasurementBridge N60RoomMeasurementBridge;

typedef struct {
    uint32_t frameCursor;
    uint32_t totalFrameCount;
    uint32_t leftCapturedFrames;
    uint32_t rightCapturedFrames;
    uint64_t callbacks;
    uint64_t unsupportedBufferLayouts;
    bool complete;
} N60RoomMeasurementBridgeSnapshot;

/// Allocates all sweep/capture storage on the control plane. The returned bridge
/// owns a copy of `sweepSamples`, so Swift/worker memory may be released after
/// creation. The realtime callback performs no allocation or locking.
N60RoomMeasurementBridge * _Nullable N60RoomMeasurementBridgeCreate(
    const float * _Nonnull sweepSamples,
    uint32_t sweepFrameCount,
    uint32_t leadInFrames,
    uint32_t tailFrames,
    uint32_t settlingFrames,
    uint32_t inputChannelIndex
);

void N60RoomMeasurementBridgeDestroy(N60RoomMeasurementBridge * _Nonnull bridge);

/// Control-plane operation. Call only while the calibration IOProc is stopped.
void N60RoomMeasurementBridgeReset(N60RoomMeasurementBridge * _Nonnull bridge);

N60RoomMeasurementBridgeSnapshot N60RoomMeasurementBridgeGetSnapshot(
    const N60RoomMeasurementBridge * _Nonnull bridge
);

/// Deterministic planar test/control primitive used by the IOProc internally.
/// Returns the number of measurement-timeline frames consumed. Output beyond
/// completion is zero-filled.
uint32_t N60RoomMeasurementBridgeProcessPlanar(
    N60RoomMeasurementBridge * _Nonnull bridge,
    const float * _Nonnull microphoneSamples,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight,
    uint32_t frameCount
);

/// Control-plane copies. Materialize captures only after the IOProc has stopped.
uint32_t N60RoomMeasurementBridgeCopyLeftCapture(
    const N60RoomMeasurementBridge * _Nonnull bridge,
    float * _Nonnull destination,
    uint32_t capacityFrames
);
uint32_t N60RoomMeasurementBridgeCopyRightCapture(
    const N60RoomMeasurementBridge * _Nonnull bridge,
    float * _Nonnull destination,
    uint32_t capacityFrames
);

/// Calibration-only full-duplex IOProc. It reads one selected aggregate/device
/// input channel, writes only the first physical stereo output pair, silences all
/// other output channels, and advances the preallocated paired L/R measurement.
OSStatus N60RoomMeasurementIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nullable inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nullable outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
);

#ifdef __cplusplus
}
#endif

#endif
