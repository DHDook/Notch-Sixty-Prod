#ifndef N60AmbientMonitorBridge_h
#define N60AmbientMonitorBridge_h

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct N60AmbientMonitorBridge N60AmbientMonitorBridge;

typedef struct {
    uint32_t capacityFrames;
    uint32_t availableFrames;
    uint64_t capturedFrames;
    uint64_t droppedFrames;
    uint64_t callbacks;
    uint64_t unsupportedBufferLayouts;
} N60AmbientMonitorSnapshot;

/// Control-plane allocation. capacityFrames must be a power of two.
N60AmbientMonitorBridge * _Nullable N60AmbientMonitorBridgeCreate(
    uint32_t capacityFrames,
    uint32_t inputChannelIndex
);

void N60AmbientMonitorBridgeDestroy(
    N60AmbientMonitorBridge * _Nonnull bridge
);

/// Control-plane operation. Safe while stopped.
void N60AmbientMonitorBridgeReset(
    N60AmbientMonitorBridge * _Nonnull bridge
);

N60AmbientMonitorSnapshot N60AmbientMonitorBridgeGetSnapshot(
    const N60AmbientMonitorBridge * _Nonnull bridge
);

/// Deterministic planar primitive used by tests and by the IOProc implementation.
/// The producer never overwrites unread samples; excess input is dropped.
uint32_t N60AmbientMonitorBridgeProcessPlanar(
    N60AmbientMonitorBridge * _Nonnull bridge,
    const float * _Nonnull microphoneSamples,
    uint32_t frameCount
);

/// Sole-consumer control-plane read. Returns frames copied and advances read index.
uint32_t N60AmbientMonitorBridgeReadFrames(
    N60AmbientMonitorBridge * _Nonnull bridge,
    float * _Nonnull destination,
    uint32_t capacityFrames
);

/// Sole-consumer control-plane discard.
void N60AmbientMonitorBridgeDiscardFrames(
    N60AmbientMonitorBridge * _Nonnull bridge
);

/// Input-only monitor callback. The callback only resolves the configured channel
/// and copies samples into the preallocated SPSC ring.
OSStatus N60AmbientMonitorIOProc(
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
