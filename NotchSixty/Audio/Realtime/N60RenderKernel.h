#ifndef N60RenderKernel_h
#define N60RenderKernel_h

#include <stdbool.h>
#include <stdint.h>

#include "N60Biquad.h"
#include "N60Convolution.h"
#include "N60Crossover.h"
#include "N60Dynamics.h"
#include "N60FractionalDelay.h"
#include "N60MixedPhase.h"
#include "N60Spatial.h"
#include "N60HeadphoneDSP.h"
#include "N60Protection.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MAX_EQ_BANDS 64
#define N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND 8
#define N60_MAX_EQ_USER_RENDER_SLOTS (N60_MAX_EQ_BANDS * 2 * N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND)
#define N60_MAX_EQ_MIXED_PHASE_RENDER_SLOTS (2u * N60_MIXED_PHASE_MAX_SECTIONS_PER_LANE)
#define N60_MAX_EQ_RENDER_SLOTS (N60_MAX_EQ_USER_RENDER_SLOTS + N60_MAX_EQ_MIXED_PHASE_RENDER_SLOTS)
#define N60_EQ_CHANNEL_LEFT 0x1u
#define N60_EQ_CHANNEL_RIGHT 0x2u
#define N60_EQ_CHANNEL_STEREO (N60_EQ_CHANNEL_LEFT | N60_EQ_CHANNEL_RIGHT)
#define N60_MAX_AUDITION_DELAY_FRAMES 131072u

static inline void N60MidSideEncode(
    float left,
    float right,
    float * _Nonnull mid,
    float * _Nonnull side
) {
    *mid = 0.5f * (left + right);
    *side = 0.5f * (left - right);
}

static inline void N60MidSideDecode(
    float mid,
    float side,
    float * _Nonnull left,
    float * _Nonnull right
) {
    *left = mid + side;
    *right = mid - side;
}

typedef enum {
    N60AuditionModeProcessed = 0,
    N60AuditionModeReference = 1,
    N60AuditionModeDelta = 2,
} N60AuditionMode;

typedef struct N60RenderKernel N60RenderKernel;

#define N60_AMBIENT_COMPENSATION_BAND_COUNT 3u

typedef struct {
    bool enabled;
    float levelGainLinear;
    N60BiquadBandSnapshot bands[N60_AMBIENT_COMPENSATION_BAND_COUNT];
    uint32_t transitionFrames;
} N60AmbientCompensationSnapshot;

typedef struct {
    bool enabled;
    uint32_t programSlot;
    uint64_t programGeneration;
    uint32_t tapCount;
    uint32_t partitionCount;
    uint32_t engineLatencyFrames;
    uint32_t declaredLatencyFrames;
} N60ConvolutionGraphState;

typedef struct {
    double sampleRate;
    uint32_t channelCount;
    float inputGainLinear;
    float headroomGainLinear;
    float outputGainLinear;
    float masterGainLinear;
    float balanceGainLeftLinear;
    float balanceGainRightLinear;
    N60SymmetryBalanceSnapshot symmetryBalance;
    N60SpeakerCrossfeedSnapshot speakerCrossfeed;
    N60CrosstalkCancellationSnapshot crosstalkCancellation;
    bool meteringEnabled;
    bool bypassed;
    N60AuditionMode auditionMode;
    N60InterChannelDelaySnapshot interChannelDelay;
    uint32_t latencyFrames;
    uint64_t generation;
    uint32_t gainTransitionFrames;
    bool eqBypassed;
    bool eqMidSideMode;
    bool mixedPhaseEnabled;
    uint32_t mixedPhaseCorrectionSectionCount;
    uint32_t eqBandCount;
    uint32_t eqTransitionFrames;
    // Keep the pre-PR23 band array representation intact; channel scope is a
    // parallel array so the proven linked-stereo path remains structurally stable.
    N60BiquadBandSnapshot eqBands[N60_MAX_EQ_RENDER_SLOTS];
    uint8_t eqBandChannelMasks[N60_MAX_EQ_RENDER_SLOTS];
    uint32_t crossoverTransitionFrames;
    N60CrossoverSnapshot crossover;
    N60DynamicsSnapshot dynamics;
    N60ProtectionSnapshot protection;
    N60AmbientCompensationSnapshot ambientCompensation;
    N60ConvolutionGraphState convolution;
    N60ConvolutionGraphState roomCorrection;
    N60ConvolutionGraphState speakerIR;
} N60DSPGraphSnapshot;

typedef struct {
    // Points at the reader-pinned snapshot slot for the lifetime of this render
    // context. The publisher cannot overwrite that slot until EndRender releases
    // its reader count, so copying the full graph once per callback is unnecessary.
    const N60DSPGraphSnapshot * _Nullable snapshot;
    uint32_t slotIndex;
    bool acquired;

    float inputPeakLeft;
    float inputPeakRight;
    double inputSquareSumLeft;
    double inputSquareSumRight;
    uint64_t inputOverRangeSamples;

    float postEQPeakLeft;
    float postEQPeakRight;
    double postEQSquareSumLeft;
    double postEQSquareSumRight;
    uint64_t postEQOverRangeSamples;

    float outputPeakLeft;
    float outputPeakRight;
    double outputSquareSumLeft;
    double outputSquareSumRight;
    uint64_t outputOverRangeSamples;

    uint32_t meteredFrames;
} N60RenderKernelRenderContext;

typedef struct {
    float sourceLeft;
    float sourceRight;
    float left;
    float right;
    float referenceLeft;
    float referenceRight;
    bool processingActive;
} N60StereoPlaybackFrame;

typedef struct {
    float peakLeft;
    float peakRight;
    float rmsLeft;
    float rmsRight;
    uint64_t overRangeSamples;
} N60StereoMeterReading;

typedef struct {
    uint64_t renderedFrames;
    uint64_t sanitizedNonFiniteSamples;
    uint64_t flushedDenormalSamples;
    uint64_t snapshotReadMisses;
    uint64_t convolutionProgramMisses;
    uint64_t roomCorrectionProgramMisses;
    uint64_t speakerIRProgramMisses;
    uint64_t publishedGeneration;
    uint32_t latencyFrames;
    double sampleRate;
    uint32_t channelCount;
    bool meteringEnabled;
    bool bypassed;
    N60AuditionMode auditionMode;
    double interChannelDelayMs;
    uint32_t interChannelAlignmentLatencyFrames;
    float inputGainLinear;
    float headroomGainLinear;
    float outputGainLinear;
    float masterGainLinear;
    float balanceGainLeftLinear;
    float balanceGainRightLinear;
    bool eqBypassed;
    bool eqMidSideMode;
    bool mixedPhaseEnabled;
    uint32_t mixedPhaseCorrectionSectionCount;
    uint32_t eqBandCount;
    uint32_t eqLeftBandCount;
    uint32_t eqRightBandCount;
    bool crossoverEnabled;
    double crossoverFrequencyHz;
    N60CrossoverTopology crossoverTopology;
    N60CrossoverMonitorMode crossoverMonitorMode;
    float crossoverSubGainLinear;
    bool crossoverSubPolarityInverted;
    uint32_t crossoverSectionCount;
    float mainsDetectedFrequencyHz;
    float mainsDetectionConfidence;
    bool spectralDenoiserEnabled;
    N60DenoiserTuning spectralDenoiserTuning;
    N60DenoiserQuality spectralDenoiserQuality;
    uint32_t denoiserFFTSize;
    uint32_t denoiserHopSize;
    uint32_t denoiserLatencyFrames;
    bool denoiserProfileReady;
    bool denoiserCapturedProfile;
    bool denoiserCaptureActive;
    float denoiserCaptureProgress;
    float denoiserEstimatedNoiseDBFS;
    float denoiserMeanSuppressionDB;
    float denoiserMaxSuppressionDB;
    uint64_t denoiserSpectralFramesProcessed;
    bool deEsserEnabled;
    bool deEsserDynamicEQMode;
    double deEsserFrequencyHz;
    bool multibandCompressorEnabled;
    double multibandLowMidFrequencyHz;
    double multibandMidHighFrequencyHz;
    N60CrossoverTopology multibandTopology;
    float deEsserGainReductionDB;
    float multibandLowGainReductionDB;
    float multibandMidGainReductionDB;
    float multibandHighGainReductionDB;
    float loudnessShortTermLUFS;
    float loudnessMatchGainDB;
    float loudnessContourScale;
    float dialogueProgramLevelDBFS;
    float dialogueBandLevelDBFS;
    float dialogueGapDB;
    float dialogueVoiceConfidence;
    float dialogueBoostDB;
    bool compressorEnabled;
    bool expanderEnabled;
    bool pauseGateEnabled;
    float compressorGainReductionDB;
    float expanderAttenuationDB;
    float pauseGateGain;
    bool pauseGateOpen;
    bool softClipperEnabled;
    bool limiterEnabled;
    N60OversamplingFactor oversamplingFactor;
    N60OversamplingFactor effectiveOversamplingFactor;
    float inputTruePeakLinear;
    float outputTruePeakLinear;
    float limiterGainReductionDB;
    float gainRiderAttenuationDB;
    float sustainedLimiterGainReductionDB;
    bool truePeakGuardActive;
    uint64_t limiterSafetyClampSamples;
    bool convolutionEnabled;
    uint32_t convolutionProgramSlot;
    uint64_t convolutionProgramGeneration;
    uint32_t convolutionTapCount;
    uint32_t convolutionPartitionCount;
    uint32_t convolutionEngineLatencyFrames;
    uint32_t convolutionDeclaredLatencyFrames;
    bool roomCorrectionEnabled;
    uint32_t roomCorrectionProgramSlot;
    uint64_t roomCorrectionProgramGeneration;
    uint32_t roomCorrectionTapCount;
    uint32_t roomCorrectionPartitionCount;
    uint32_t roomCorrectionEngineLatencyFrames;
    uint32_t roomCorrectionDeclaredLatencyFrames;
    bool speakerIREnabled;
    uint32_t speakerIRProgramSlot;
    uint64_t speakerIRProgramGeneration;
    uint32_t speakerIRTapCount;
    uint32_t speakerIRPartitionCount;
    uint32_t speakerIREngineLatencyFrames;
    uint32_t speakerIRDeclaredLatencyFrames;
    N60StereoMeterReading inputMeter;
    N60StereoMeterReading postEQMeter;
    N60StereoMeterReading outputMeter;
} N60RenderKernelDiagnostics;

N60DSPGraphSnapshot N60DSPGraphSnapshotMakeUnity(double sampleRate);
bool N60DSPGraphSnapshotSetMeteringEnabled(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    bool enabled
);
void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot * _Nonnull snapshot);
bool N60DSPGraphSnapshotSetSymmetryBalance(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    double position,
    bool enabled
);
bool N60DSPGraphSnapshotSetSpeakerCrossfeed(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    double amount,
    bool enabled
);
bool N60DSPGraphSnapshotSetCrosstalkCancellation(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    double amount,
    double headShadowFrequencyHz,
    bool enabled
);
bool N60DSPGraphSnapshotSetInterChannelDelay(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    double signedDelayMs
);
bool N60DSPGraphSnapshotSetEQBand(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled
);
bool N60DSPGraphSnapshotSetEQBandForChannels(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t bandIndex,
    uint8_t channelMask,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled
);
bool N60DSPGraphSnapshotSetEQPreparedBandForChannels(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t bandIndex,
    uint8_t channelMask,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
);
bool N60DSPGraphSnapshotSetEQPreparedBand(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
);
bool N60DSPGraphSnapshotSetAmbientCompensation(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    double levelDB,
    double lowSupportDB,
    double presenceSupportDB,
    double detailSupportDB,
    bool enabled
);
bool N60DSPGraphSnapshotSetCrossover(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    double frequencyHz,
    N60CrossoverTopology topology,
    N60CrossoverMonitorMode monitorMode,
    float subGainLinear,
    bool subPolarityInverted,
    bool enabled
);
bool N60DSPGraphSnapshotSetSubPhaseAlignment(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    double frequencyHz,
    double q,
    bool enabled
);
bool N60DSPGraphSnapshotSetConvolutionProgram(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
);
bool N60DSPGraphSnapshotSetRoomCorrectionProgram(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
);
bool N60DSPGraphSnapshotSetSpeakerIRProgram(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
);

N60RenderKernel * _Nullable N60RenderKernelCreate(void);
// Control-plane only. Configure/clear only while callbacks are stopped.
bool N60RenderKernelConfigureHeadphoneDSP(
    N60RenderKernel * _Nonnull kernel,
    const N60HeadphoneDSPSnapshot * _Nonnull snapshot
);
void N60RenderKernelClearHeadphoneDSP(N60RenderKernel * _Nonnull kernel);
void N60RenderKernelDestroy(N60RenderKernel * _Nonnull kernel);
void N60RenderKernelReset(N60RenderKernel * _Nonnull kernel);
bool N60RenderKernelPrepareConvolutionProgram(
    N60RenderKernel * _Nonnull kernel,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
bool N60RenderKernelPrepareRoomCorrectionProgram(
    N60RenderKernel * _Nonnull kernel,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
bool N60RenderKernelPrepareSpeakerIRProgram(
    N60RenderKernel * _Nonnull kernel,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
bool N60RenderKernelPublishSnapshot(
    N60RenderKernel * _Nonnull kernel,
    N60DSPGraphSnapshot snapshot
);
N60RenderKernelRenderContext N60RenderKernelBeginRender(N60RenderKernel * _Nonnull kernel);
void N60RenderKernelProcessStereoPlaybackFrameInContext(
    N60RenderKernel * _Nonnull kernel,
    N60RenderKernelRenderContext * _Nonnull context,
    float inputLeft,
    float inputRight,
    N60StereoPlaybackFrame * _Nonnull playbackFrame
);
void N60RenderKernelProcessStereoSystemFrameInContext(
    N60RenderKernel * _Nonnull kernel,
    N60RenderKernelRenderContext * _Nonnull context,
    const N60StereoPlaybackFrame * _Nonnull playbackFrame,
    float rackLeft,
    float rackRight,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight
);
void N60RenderKernelProcessStereoFrameInContext(
    N60RenderKernel * _Nonnull kernel,
    N60RenderKernelRenderContext * _Nonnull context,
    float inputLeft,
    float inputRight,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight
);
void N60RenderKernelEndRender(
    N60RenderKernel * _Nonnull kernel,
    N60RenderKernelRenderContext * _Nonnull context,
    uint32_t renderedFrames
);
void N60RenderKernelProcessStereoFrame(
    N60RenderKernel * _Nonnull kernel,
    float inputLeft,
    float inputRight,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight
);
N60RenderKernelDiagnostics N60RenderKernelGetDiagnostics(
    const N60RenderKernel * _Nonnull kernel
);

#ifdef __cplusplus
}
#endif

#endif