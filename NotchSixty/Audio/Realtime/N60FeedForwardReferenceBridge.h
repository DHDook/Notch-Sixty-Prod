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
/// E4 S9b1 pair mode: the reference channel plus an error-microphone channel
/// of the same device (one clock), filled by one IOProc into two parallel
/// rings that share one write and read index. A callback is accepted only if
/// both channels are present with the same frame count and every sample in
/// both is finite. Read takes the reference frames only (and skips the
/// matching error samples); ReadPair takes both. The two channels must differ.
N60FeedForwardReferenceBridge * _Nullable N60FeedForwardReferenceBridgeCreatePair(
    uint32_t capacityFrames,
    uint32_t referenceChannelIndex,
    uint32_t errorChannelIndex
);
bool N60FeedForwardReferenceBridgeIsPair(
    const N60FeedForwardReferenceBridge * _Nonnull bridge
);
void N60FeedForwardReferenceBridgeDestroy(
    N60FeedForwardReferenceBridge * _Nonnull bridge
);
/// Control plane, with the IOProc stopped.
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

/// Pair-mode test input path. Returns 0 on a one-channel bridge.
uint32_t N60FeedForwardReferenceBridgeProcessPairPlanar(
    N60FeedForwardReferenceBridge * _Nonnull bridge,
    const float * _Nonnull reference,
    const float * _Nonnull error,
    uint32_t frameCount,
    uint64_t firstFrameHostTime,
    double firstFrameSampleTime
);

/// Pair mode: up to capacityFrames reference frames and the error samples
/// recorded with them. Returns 0 on a one-channel bridge.
uint32_t N60FeedForwardReferenceBridgeReadPair(
    N60FeedForwardReferenceBridge * _Nonnull bridge,
    N60FeedForwardReferenceFrame * _Nonnull destination,
    float * _Nonnull errorDestination,
    uint32_t capacityFrames
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
