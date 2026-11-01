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
/// E4 S22b1: speaker-drive ring (frames) and its host-time anchor ring (callbacks).
#define N60_SPEAKER_DRIVE_CAPACITY_FRAMES 262144u
#define N60_SPEAKER_DRIVE_ANCHOR_CAPACITY 4096u

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

/// E4 S22b1: one render callback's place in the speaker-drive stream. `firstFrameIndex` counts
/// frames written to the drive ring since the bridge was reset (the index only increases); `outputHostTime` is the
/// output buffer's host time (0 when the callback had none). `reserved` is, with the live feed-forward
/// attached, the low 32 bits of its output index at the start of this callback (E4 S25b), else 0.
typedef struct {
    uint64_t outputHostTime;
    uint64_t firstFrameIndex;
    uint32_t frames;
    uint32_t reserved;
} N60SpeakerDriveAnchor;

typedef struct {
    bool enabled;
    uint32_t availableFrames;
    uint32_t availableAnchors;
    uint64_t capturedFrames;
    /// Frames of callbacks that were not recorded because a ring was full. Any change is a gap.
    uint64_t droppedFrames;
    uint64_t droppedAnchors;
} N60SpeakerDriveSnapshot;

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
// E6 S8/S8b. Control thread only. Attaches (graph != NULL) or detaches (NULL) a libn60core
// n60_graph used by the plain-stereo callback branch. The callback owns the hand-over: the
// side taking over is warmed on the live input for 50 ms (the kernel is cold-started first),
// then crossfaded in over 20 ms, so attach and detach neither step nor resume stale state.
// Blocks larger than maxFrames are rendered in chunks. maxFrames and sampleRate are fixed by the
// first attach (a later attach with a larger maxFrames or another rate is refused until Release),
// and a different graph object is accepted only after the previous hand-over has ended. The
// crossfade time-aligns the two paths (E6 S8b2c): the callback reads the kernel's latency from its
// snapshot and the graph's from SetUnifiedGraphLatency, and delays the lower-latency side by the
// difference (slewed with the mix, clamped to the warm-up length), so the fade mixes aligned
// signals. Route changes to the AU rack or same-device branch happen with IO stopped. The same-device multi-output
// branch renders through the graph like the plain stereo branch (the speaker-bus splitter and driver processing stay in
// the bridge). The AU rack renders through the graph only after BindRackToGraph; otherwise it uses the kernel. The bridge never owns or frees the graph; a detached graph pointer
// stays referenced until ReleaseUnifiedGraph or N60RealtimeAudioBridgeDestroy, so the owner
// releases the graph only after one of those (with IO stopped). sampleRate sets the warm-up and fade lengths.
// Allocates the scratch on first attach, never in the callback.
bool N60RealtimeAudioBridgeSetUnifiedGraph(
    N60RealtimeAudioBridge * _Nonnull bridge,
    void * _Nullable graph,
    uint32_t maxFrames,
    double sampleRate
);
// Control thread. Publishes the graph's path latency (n60_graph_latency_frames) for the fade
// alignment. Call before the attach and after every graph update. The applied alignment is
// capped at a quarter of the 20 ms fade (and by the warm-up and a 16384-frame ring).
void N60RealtimeAudioBridgeSetUnifiedGraphLatency(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint32_t latencyFrames
);
// Test/diagnostic accessor: graph minus kernel latency (frames) latched for the most recent fade.
int32_t N60RealtimeAudioBridgeUnifiedGraphAlignmentFrames(const N60RealtimeAudioBridge * _Nonnull bridge);
// E6 S8e. Control thread, IO stopped or the graph not yet attached. Registers this bridge's AU rack as the host callback
// of the graph's EXTERNAL stage (the graph must have one, at the rack's position) and lets the graph render rack routes.
// Returns false without a configured rack or when the graph refuses. Call after ConfigureAudioUnitRack and before the
// graph is attached. Unbind (before the rack or the graph is freed) clears the callback.
bool N60RealtimeAudioBridgeBindRackToGraph(N60RealtimeAudioBridge * _Nonnull bridge, void * _Nonnull graph);
// Lifetime: ReleaseUnifiedGraph and Destroy unbind automatically, so call ReleaseUnifiedGraph (or Unbind) before the graph is destroyed. IO must be stopped while binding or unbinding.
void N60RealtimeAudioBridgeUnbindRackFromGraph(N60RealtimeAudioBridge * _Nonnull bridge, void * _Nullable graph);
// Drops the graph reference and returns the callback to kernel-only. IO must be stopped.
void N60RealtimeAudioBridgeReleaseUnifiedGraph(N60RealtimeAudioBridge * _Nonnull bridge);
// True while a graph is attached and wanted (a detach in progress reads false).
bool N60RealtimeAudioBridgeUnifiedGraphActive(const N60RealtimeAudioBridge * _Nonnull bridge);
// Weight of the graph in the output as of the last block: 0 kernel only, 1 graph only.
float N60RealtimeAudioBridgeUnifiedGraphMix(const N60RealtimeAudioBridge * _Nonnull bridge);
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

// E4 S22b1: the samples written to the physical output (after master gain and fades, including
// any tonal anti-noise), with one host-time anchor per callback, for the feed-forward echo model.
// Single producer (render callback), single consumer (control plane). A callback is recorded
// whole or not at all. The tap is the final stereo mix before any same-device speaker-bus split
// or driver processing. Only the consumer moves the read indices: after enabling demand it drains
// both rings, and any change in the dropped counters is a gap (RestartDrive). Off by default; Swift enables it only behind e4.feedforward-live.
void N60RealtimeAudioBridgeSetSpeakerDriveDemand(
    N60RealtimeAudioBridge * _Nonnull bridge,
    bool enabled
);
bool N60RealtimeAudioBridgeSpeakerDriveDemand(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
N60SpeakerDriveSnapshot N60RealtimeAudioBridgeGetSpeakerDriveSnapshot(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
uint32_t N60RealtimeAudioBridgeReadSpeakerDriveFrames(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60AmbientPlaybackReferenceFrame * _Nonnull destination,
    uint32_t capacityFrames
);
/// E4 S25b: as ReadSpeakerDriveFrames, and the feed-forward anti-noise alone at the same indices
/// (the second drive signal; error-side echo removal leaves it out). Advances the read index once.
uint32_t N60RealtimeAudioBridgeReadSpeakerDriveFramesWithFeedForward(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60AmbientPlaybackReferenceFrame * _Nonnull destination,
    N60AmbientPlaybackReferenceFrame * _Nonnull feedForwardDestination,
    uint32_t capacityFrames
);
uint32_t N60RealtimeAudioBridgeReadSpeakerDriveAnchors(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60SpeakerDriveAnchor * _Nonnull destination,
    uint32_t capacityAnchors
);

/// E4 S25b: live feed-forward (flag e4.feedforward-live; see N60RenderKernel.h). Attach/Detach with IO
/// stopped; the rest are lock-free. Nothing here arms the filter: Arm is the only path, and it is gated
/// in Swift by the written authorisation (FeedForwardLiveArmGate).
bool N60RealtimeAudioBridgeAttachFeedForwardLive(N60RealtimeAudioBridge * _Nonnull bridge, double sampleRate, double peakLimit);
void N60RealtimeAudioBridgeDetachFeedForwardLive(N60RealtimeAudioBridge * _Nonnull bridge);
bool N60RealtimeAudioBridgeSetFeedForwardLiveWeights(
    N60RealtimeAudioBridge * _Nonnull bridge,
    const float * _Nonnull left,
    const float * _Nonnull right,
    uint32_t count
);
uint32_t N60RealtimeAudioBridgeArmFeedForwardLive(
    N60RealtimeAudioBridge * _Nonnull bridge,
    double leadSeconds,
    double requiredSeconds
);
void N60RealtimeAudioBridgeDisarmFeedForwardLive(N60RealtimeAudioBridge * _Nonnull bridge);
void N60RealtimeAudioBridgeMarkFeedForwardLiveReferenceLost(N60RealtimeAudioBridge * _Nonnull bridge);
N60RenderKernelFeedForwardLiveStatus N60RealtimeAudioBridgeGetFeedForwardLiveStatus(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
uint64_t N60RealtimeAudioBridgePushFeedForwardLiveReference(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint64_t startIndex,
    const float * _Nonnull samples,
    uint32_t count
);

/// E4 S14: dead-man lease on the anti-noise (see N60RenderKernel.h). Control plane only.
void N60RealtimeAudioBridgeRenewActiveQuietZoneLease(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint64_t durationFrames
);
void N60RealtimeAudioBridgeReleaseActiveQuietZoneLease(
    N60RealtimeAudioBridge * _Nonnull bridge
);
uint64_t N60RealtimeAudioBridgeActiveQuietZoneLeaseExpiryCount(
    const N60RealtimeAudioBridge * _Nonnull bridge
);

/// E4 S15: live howl guard on the anti-noise (see N60RenderKernel.h). Attach is control plane with
/// IO stopped and a no-op when already attached at this rate; Rearm and TripCount are lock-free.
bool N60RealtimeAudioBridgeAttachHowlGuard(N60RealtimeAudioBridge * _Nonnull bridge, double sampleRate);
void N60RealtimeAudioBridgeRearmHowlGuard(N60RealtimeAudioBridge * _Nonnull bridge);
uint64_t N60RealtimeAudioBridgeHowlGuardTripCount(const N60RealtimeAudioBridge * _Nonnull bridge);

/// E4 S18b: adaptive tonal gain mailbox, phase-anchor telemetry and the worker's howl-trip request
/// (see N60ActiveQuietZone.h). Publish has one writer (the adaptive worker); Pop has one reader.
/// Publish returns the sequence (0 when there is no kernel or the record is rejected outright).
uint64_t N60RealtimeAudioBridgePublishActiveQuietZoneGainRecord(
    N60RealtimeAudioBridge * _Nonnull bridge,
    const N60ActiveQuietZoneGainRecord * _Nonnull record
);
bool N60RealtimeAudioBridgePopActiveQuietZoneTelemetry(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60ActiveQuietZoneTelemetryRecord * _Nonnull record
);
N60ActiveQuietZoneMailboxStats N60RealtimeAudioBridgeActiveQuietZoneMailboxStats(
    const N60RealtimeAudioBridge * _Nonnull bridge
);
void N60RealtimeAudioBridgeRequestHowlTrip(N60RealtimeAudioBridge * _Nonnull bridge);

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

/// Control-plane/offline protected-driver excitation renderer.
///
/// This deliberately reuses the production speaker bus splitter followed by
/// the production per-driver processor. It accepts ONLY split Low/Mid/High
/// buses whose configured driver path is enabled and limiter-protected.
/// It does not route audio to hardware and must not be called from a realtime
/// callback.
bool N60ProtectedSpeakerBusRenderProgram(
    const float * _Nonnull monoInput,
    uint32_t frameCount,
    N60SpeakerOutputBus targetBus,
    N60SpeakerBusSplitterSnapshot splitterSnapshot,
    N60SpeakerDriverProcessingSnapshot driverSnapshot,
    float * _Nonnull output
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