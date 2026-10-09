#ifndef N60RealtimeAudioBridge_h
#define N60RealtimeAudioBridge_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "N60AdaptiveSampleRate.h"
#include "N60AudioUnitLiveRackBridge.h"
#include "N60RenderKernel.h"
#include "N60FeedForwardOutputTiming.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct N60RealtimeAudioBridge N60RealtimeAudioBridge;

typedef struct {
    bool enabled;
    float peakLeft;
    float peakRight;
    float rmsLeft;
    float rmsRight;
    uint64_t overRangeSamples;
} N60OutputVUMeterSnapshot;

#define N60_ANALYSIS_DEMAND_NONE 0u
#define N60_ANALYSIS_DEMAND_SPECTRUM (1u << 0)
#define N60_ANALYSIS_DEMAND_STEREO (1u << 1)
#define N60_ANALYSIS_DEMAND_ALL (N60_ANALYSIS_DEMAND_SPECTRUM | N60_ANALYSIS_DEMAND_STEREO)
#define N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES 65536u
#define N60_AMBIENT_REFERENCE_CAPACITY_FRAMES 131072u
#define N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES 131072u

// PR41 Slice C2a: immutable same-device speaker-output routing. The control
// plane compiles at most eight logical-bus routes; the realtime writer only
// reads this fixed-size map and writes preallocated Core Audio buffers.
#define N60_SPEAKER_OUTPUT_MAX_ROUTES 8u

typedef enum {
    N60SpeakerOutputBusLeftFullRange = 0,
    N60SpeakerOutputBusRightFullRange = 1,
    N60SpeakerOutputBusLeftLow = 2,
    N60SpeakerOutputBusRightLow = 3,
    N60SpeakerOutputBusLeftMid = 4,
    N60SpeakerOutputBusRightMid = 5,
    N60SpeakerOutputBusLeftHigh = 6,
    N60SpeakerOutputBusRightHigh = 7,
    N60SpeakerOutputBusSubMono = 8,
    N60SpeakerOutputBusCount = 9,
} N60SpeakerOutputBus;

typedef struct {
    float values[N60SpeakerOutputBusCount];
} N60SpeakerBusFrame;

#include "N60SpeakerDriverProcessing.h"

typedef struct {
    N60SpeakerOutputBus bus;
    uint32_t physicalChannelIndex;
} N60SpeakerOutputRouteDescriptor;

typedef struct {
    bool valid;
    uint32_t physicalChannelCount;
    uint32_t routeCount;
    N60SpeakerOutputRouteDescriptor routes[N60_SPEAKER_OUTPUT_MAX_ROUTES];
} N60SameDeviceOutputMap;

typedef struct {
    float inputLeft;
    float inputRight;
    float outputLeft;
    float outputRight;
} N60AnalysisFrame;

typedef struct {
    uint32_t demandMask;
    uint32_t availableFrames;
    uint64_t capturedFrames;
    uint64_t droppedFrames;
} N60AnalysisCaptureSnapshot;

typedef struct {
    float left;
    float right;
} N60AmbientPlaybackReferenceFrame;

typedef struct {
    bool enabled;
    uint32_t availableFrames;
    uint64_t capturedFrames;
    uint64_t droppedFrames;
} N60AmbientPlaybackReferenceSnapshot;

typedef struct {
    float left;
    float right;
} N60ActiveQuietZoneReferenceFrame;

typedef struct {
    bool enabled;
    uint32_t availableFrames;
    uint64_t capturedFrames;
    uint64_t droppedFrames;
} N60ActiveQuietZoneReferenceSnapshot;

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
    float transitionGain;
    uint32_t transitionFramesRemaining;
    N60OutputVUMeterSnapshot outputVUMeter;
    bool adaptiveSampleRateEnabled;
    N60AdaptiveSRCSnapshot adaptiveSampleRate;
} N60RealtimeAudioBridgeSnapshot;

N60RealtimeAudioBridge * _Nullable N60RealtimeAudioBridgeCreate(uint32_t capacityFrames);
void N60RealtimeAudioBridgeDestroy(N60RealtimeAudioBridge * _Nonnull bridge);
void N60RealtimeAudioBridgeReset(N60RealtimeAudioBridge * _Nonnull bridge);
void N60RealtimeAudioBridgeSetOutputGain(N60RealtimeAudioBridge * _Nonnull bridge, float gain);
void N60RealtimeAudioBridgeSetTransitionGainImmediate(
    N60RealtimeAudioBridge * _Nonnull bridge,
    float gain
);
void N60RealtimeAudioBridgeRampTransitionGain(
    N60RealtimeAudioBridge * _Nonnull bridge,
    float targetGain,
    uint32_t transitionFrames
);
void N60RealtimeAudioBridgeConfigureOutputGate(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint32_t minimumBufferedFrames,
    uint32_t fadeInFrames
);

// Control-plane only. When configured, capture remains in the tap's native
// clock domain and the output callback consumes stereo frames at the selected
// output device's native rate through the PR69 adaptive SRC. Matched-rate
// sessions leave this disabled and retain the original direct SPSC path.
bool N60RealtimeAudioBridgeConfigureAdaptiveSampleRate(
    N60RealtimeAudioBridge * _Nonnull bridge,
    double inputSampleRate,
    double outputSampleRate,
    uint32_t targetBufferedInputFrames
);
bool N60RealtimeAudioBridgeAdaptiveSampleRateEnabled(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
// Control-plane only. Configure before callbacks start. The processor context
// remains owned by the Swift transport session for the entire IOProc lifetime.
bool N60RealtimeAudioBridgeConfigureAudioUnitRack(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60AudioUnitLiveRackProcessor processor
);
// Full render-kernel metering remains available for engineering/detailed meter
// surfaces. This is intentionally independent from the lightweight Dashboard VU
// pipeline below.
void N60RealtimeAudioBridgeSetMeteringDemand(bool enabled);
bool N60RealtimeAudioBridgeMeteringDemand(void);

// Signature Dashboard VUs use an output-only bridge meter. Demand is read once
// per physical-output callback and only that output meter advances while enabled.
void N60RealtimeAudioBridgeSetOutputVUMeterDemand(bool enabled);
bool N60RealtimeAudioBridgeOutputVUMeterDemand(void);
N60OutputVUMeterSnapshot N60RealtimeAudioBridgeGetOutputVUMeterSnapshot(
    const N60RealtimeAudioBridge * _Nonnull bridge
);

// Spectrum and stereo analysis share one bounded SPSC capture ring. The
// physical-output callback writes exact render Input and DSP Output samples
// only while one of these demand bits is active. Consumers read/copy off the
// realtime thread; unread samples are never overwritten.
void N60RealtimeAudioBridgeSetAnalysisDemand(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint32_t demandMask
);
uint32_t N60RealtimeAudioBridgeAnalysisDemand(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
// Consumer-side operation. The analysis worker is the sole owner of
// the ring read index and calls this off the realtime thread when a
// demand generation changes.
void N60RealtimeAudioBridgeDiscardAnalysisFrames(
    N60RealtimeAudioBridge * _Nonnull bridge
);
N60AnalysisCaptureSnapshot N60RealtimeAudioBridgeGetAnalysisCaptureSnapshot(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
uint32_t N60RealtimeAudioBridgeReadAnalysisFrames(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60AnalysisFrame * _Nonnull destination,
    uint32_t capacityFrames
);

// PR89 uses a second SPSC ring so Ambient Compensation never competes with
// ProductionAnalysisWorker for the analysis-ring read index. Frames contain the
// final stereo values after normal DSP/output gain/transition gain and before
// physical speaker-bus mapping.
void N60RealtimeAudioBridgeSetAmbientReferenceDemand(
    N60RealtimeAudioBridge * _Nonnull bridge,
    bool enabled
);
bool N60RealtimeAudioBridgeAmbientReferenceDemand(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
void N60RealtimeAudioBridgeDiscardAmbientReferenceFrames(
    N60RealtimeAudioBridge * _Nonnull bridge
);
N60AmbientPlaybackReferenceSnapshot
N60RealtimeAudioBridgeGetAmbientReferenceSnapshot(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
uint32_t N60RealtimeAudioBridgeReadAmbientReferenceFrames(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60AmbientPlaybackReferenceFrame * _Nonnull destination,
    uint32_t capacityFrames
);

void N60RealtimeAudioBridgeSetActiveQuietZoneReferenceDemand(
    N60RealtimeAudioBridge * _Nonnull bridge,
    bool enabled
);
bool N60RealtimeAudioBridgeActiveQuietZoneReferenceDemand(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
void N60RealtimeAudioBridgeDiscardActiveQuietZoneReferenceFrames(
    N60RealtimeAudioBridge * _Nonnull bridge
);
N60ActiveQuietZoneReferenceSnapshot
N60RealtimeAudioBridgeGetActiveQuietZoneReferenceSnapshot(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
uint32_t N60RealtimeAudioBridgeReadActiveQuietZoneReferenceFrames(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60ActiveQuietZoneReferenceFrame * _Nonnull destination,
    uint32_t capacityFrames
);

bool N60RealtimeAudioBridgePrepareConvolutionProgram(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
bool N60RealtimeAudioBridgePrepareRoomCorrectionProgram(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
bool N60RealtimeAudioBridgePrepareSpeakerIRProgram(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
bool N60RealtimeAudioBridgePublishDSPGraph(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60DSPGraphSnapshot snapshot
);
// Control-plane only. Configure/clear only before callbacks start or after stop.
bool N60RealtimeAudioBridgeConfigureHeadphoneDSP(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60HeadphoneDSPSnapshot snapshot
);
void N60RealtimeAudioBridgeClearHeadphoneDSP(N60RealtimeAudioBridge * _Nonnull bridge);
/// Passive output callback timing only. It is NOT measured DAC latency or
/// authorization for anti-noise output.
N60FeedForwardOutputTimingSnapshot
N60RealtimeAudioBridgeGetFeedForwardOutputTimingSnapshot(
    const N60RealtimeAudioBridge * _Nonnull bridge
);

N60RealtimeAudioBridgeSnapshot N60RealtimeAudioBridgeGetSnapshot(const N60RealtimeAudioBridge * _Nonnull bridge);
N60RenderKernelDiagnostics N60RealtimeAudioBridgeGetRenderDiagnostics(
    const N60RealtimeAudioBridge * _Nonnull bridge
);

N60SpeakerBusFrame N60SpeakerBusFrameMakeSilence(void);
bool N60SpeakerBusFrameSet(
    N60SpeakerBusFrame * _Nonnull frame,
    N60SpeakerOutputBus bus,
    float value
);
float N60SpeakerBusFrameGet(
    const N60SpeakerBusFrame * _Nonnull frame,
    N60SpeakerOutputBus bus
);
bool N60SameDeviceOutputMapCompile(
    uint32_t physicalChannelCount,
    const N60SpeakerOutputRouteDescriptor * _Nonnull routes,
    uint32_t routeCount,
    N60SameDeviceOutputMap * _Nonnull mapOut
);
// Session setup operation. Configure only while physical output callbacks
// are stopped; the realtime callback reads the copied fixed-size map directly.
bool N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60SameDeviceOutputMap map
);
bool N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60SpeakerBusSplitterSnapshot snapshot
);
bool N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60SpeakerDriverProcessingSnapshot snapshot
);

bool N60SameDeviceOutputMapValueForChannel(
    const N60SameDeviceOutputMap * _Nonnull map,
    const N60SpeakerBusFrame * _Nonnull frame,
    uint32_t physicalChannelIndex,
    float * _Nonnull valueOut
);
// Writes one frame to an arbitrary Core Audio output buffer layout. Every
// physical channel represented by the AudioBufferList is zeroed first; mapped
// channels then receive their logical-bus value. No allocation or locking.
bool N60SameDeviceOutputMapWriteFrame(
    const N60SameDeviceOutputMap * _Nonnull map,
    const N60SpeakerBusFrame * _Nonnull frame,
    AudioBufferList * _Nonnull outputData,
    uint32_t frameIndex
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