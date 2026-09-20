#ifndef N60RealtimeAudioBridge_h
#define N60RealtimeAudioBridge_h

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

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
    uint32_t bufferedFrames;
} N60RealtimeAudioBridgeSnapshot;

N60RealtimeAudioBridge *N60RealtimeAudioBridgeCreate(uint32_t capacityFrames);
void N60RealtimeAudioBridgeDestroy(N60RealtimeAudioBridge *bridge);
void N60RealtimeAudioBridgeReset(N60RealtimeAudioBridge *bridge);
void N60RealtimeAudioBridgeSetOutputGain(N60RealtimeAudioBridge *bridge, float gain);
N60RealtimeAudioBridgeSnapshot N60RealtimeAudioBridgeGetSnapshot(const N60RealtimeAudioBridge *bridge);

OSStatus N60CaptureIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
);

OSStatus N60OutputIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
);

#ifdef __cplusplus
}
#endif

#endif
