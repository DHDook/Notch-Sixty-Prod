#ifndef N60FeedForwardReferenceBridge_h
#define N60FeedForwardReferenceBridge_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct N60FeedForwardReferenceBridge N60FeedForwardReferenceBridge;

typedef struct {
    float sample;
    uint64_t firstFrameHostTime;
    double firstFrameSampleTime;
    uint32_t frameOffset;
} N60FeedForwardReferenceFrame;

typedef struct {
    uint32_t availableFrames;
    uint32_t capacityFrames;
    uint64_t receivedFrames;
    uint64_t droppedFrames;
    uint64_t callbacks;
    uint64_t invalidTimestamps;
    uint64_t unsupportedBufferLayouts;
} N60FeedForwardReferenceSnapshot;

/// Allocation is strictly control-plane. Power-of-two capacity >= 256.
/// The bridge is input-only: it never modifies playback or injects anti-noise.
N60FeedForwardReferenceBridge * _Nullable N60FeedForwardReferenceBridgeCreate(
    uint32_t capacityFrames,
    uint32_t inputChannelIndex
);
void N60FeedForwardReferenceBridgeDestroy(
    N60FeedForwardReferenceBridge * _Nonnull bridge
);
void N60FeedForwardReferenceBridgeReset(
    N60FeedForwardReferenceBridge * _Nonnull bridge
);
N60FeedForwardReferenceSnapshot N60FeedForwardReferenceBridgeGetSnapshot(
    const N60FeedForwardReferenceBridge * _Nonnull bridge
);

/// Testable deterministic input path. Timestamps apply to the FIRST frame.
uint32_t N60FeedForwardReferenceBridgeProcessPlanar(
    N60FeedForwardReferenceBridge * _Nonnull bridge,
    const float * _Nonnull input,
    uint32_t frameCount,
    uint64_t firstFrameHostTime,
    double firstFrameSampleTime
);

uint32_t N60FeedForwardReferenceBridgeRead(
    N60FeedForwardReferenceBridge * _Nonnull bridge,
    N60FeedForwardReferenceFrame * _Nonnull destination,
    uint32_t capacityFrames
);

OSStatus N60FeedForwardReferenceIOProc(
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
