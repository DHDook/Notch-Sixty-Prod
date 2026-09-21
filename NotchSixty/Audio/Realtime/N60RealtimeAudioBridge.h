#ifndef N60RealtimeAudioBridge_h
#define N60RealtimeAudioBridge_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "N60RenderKernel.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct N60RealtimeAudioBridge N60RealtimeAudioBridge;

typedef struct {
    uint64_t captureCallbacks;
    uint64_t outputCallbacks;
    uint64_t capturedFrames;
    uint64_t deliveredFrames;
    uint64_t underrunFrames;
    uint64_t overrunFrames;
    uint64_t unsupportedBufferLayouts;
    uint64_t gatedOutputCallbacks;
    uint64_t gatedOutputFrames;
    uint32_t bufferedFrames;
    bool outputGateOpen;
} N60RealtimeAudioBridgeSnapshot;

N60RealtimeAudioBridge * _Nullable N60RealtimeAudioBridgeCreate(uint32_t capacityFrames);
void N60RealtimeAudioBridgeDestroy(N60RealtimeAudioBridge * _Nonnull bridge);
void N60RealtimeAudioBridgeReset(N60RealtimeAudioBridge * _Nonnull bridge);
void N60RealtimeAudioBridgeSetOutputGain(N60RealtimeAudioBridge * _Nonnull bridge, float gain);
void N60RealtimeAudioBridgeConfigureOutputGate(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint32_t minimumBufferedFrames,
    uint32_t fadeInFrames
);
bool N60RealtimeAudioBridgePublishDSPGraph(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60DSPGraphSnapshot snapshot
);
N60RealtimeAudioBridgeSnapshot N60RealtimeAudioBridgeGetSnapshot(const N60RealtimeAudioBridge * _Nonnull bridge);
N60RenderKernelDiagnostics N60RealtimeAudioBridgeGetRenderDiagnostics(
    const N60RealtimeAudioBridge * _Nonnull bridge
);

OSStatus N60CaptureIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
);

OSStatus N60OutputIOProc(
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
