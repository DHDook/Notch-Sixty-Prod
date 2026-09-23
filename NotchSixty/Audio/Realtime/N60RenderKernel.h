#ifndef N60RenderKernel_h
#define N60RenderKernel_h

#include <stdbool.h>
#include <stdint.h>

#include "N60Biquad.h"
#include "N60Convolution.h"
#include "N60Crossover.h"

#ifdef __cplusplus
extern "C" {
#endif

// User-facing EQ remains capped at 64 bands per channel. Independent stereo
// mode can therefore compile up to 128 render slots, with each slot explicitly
// scoped to left, right, or both channels.
#define N60_MAX_EQ_BANDS 64
#define N60_MAX_EQ_RENDER_SLOTS (N60_MAX_EQ_BANDS * 2)
#define N60_EQ_CHANNEL_LEFT 0x1u
#define N60_EQ_CHANNEL_RIGHT 0x2u
#define N60_EQ_CHANNEL_STEREO (N60_EQ_CHANNEL_LEFT | N60_EQ_CHANNEL_RIGHT)

typedef struct N60RenderKernel N60RenderKernel;

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
    N60BiquadBandSnapshot band;
    uint8_t channelMask;
} N60EQBandGraphState;

typedef struct {
    double sampleRate;
    uint32_t channelCount;
    float inputGainLinear;
    float headroomGainLinear;
    float outputGainLinear;
    // Channel balance is attenuation-only: 1/1 at center, never > unity.
    float balanceGainLeftLinear;
    float balanceGainRightLinear;
    bool bypassed;
    uint32_t latencyFrames;
    uint64_t generation;
    uint32_t gainTransitionFrames;
    bool eqBypassed;
    uint32_t eqBandCount;
    uint32_t eqTransitionFrames;
    N60EQBandGraphState eqBands[N60_MAX_EQ_RENDER_SLOTS];
    uint32_t crossoverTransitionFrames;
    N60CrossoverSnapshot crossover;
    // Linear-phase EQ FIR stage. Kept under the existing convolution name for
    // source compatibility with PR #19.
    N60ConvolutionGraphState convolution;
    // Independent room-correction FIR stage. This owns a separate convolver
    // and program-slot namespace from linear-phase EQ.
    N60ConvolutionGraphState roomCorrection;
} N60DSPGraphSnapshot;

typedef struct {
    N60DSPGraphSnapshot snapshot;
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
    uint64_t publishedGeneration;
    uint32_t latencyFrames;
    double sampleRate;
    uint32_t channelCount;
    bool bypassed;
    float inputGainLinear;
    float headroomGainLinear;
    float outputGainLinear;
    float balanceGainLeftLinear;
    float balanceGainRightLinear;
    bool eqBypassed;
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
    N60StereoMeterReading inputMeter;
    N60StereoMeterReading postEQMeter;
    N60StereoMeterReading outputMeter;
} N60RenderKernelDiagnostics;

N60DSPGraphSnapshot N60DSPGraphSnapshotMakeUnity(double sampleRate);

// Control-plane graph helpers. Coefficients/programs are prepared before
// publication; no filter construction or FFT setup occurs in the callback.
void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot * _Nonnull snapshot);

// Backward-compatible linked-stereo helper: applies the same band to L+R.
bool N60DSPGraphSnapshotSetEQBand(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled
);

// Stereo-aware helper. `channelMask` must contain left, right, or both bits.
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

bool N60DSPGraphSnapshotSetCrossover(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    double frequencyHz,
    N60CrossoverTopology topology,
    N60CrossoverMonitorMode monitorMode,
    float subGainLinear,
    bool subPolarityInverted,
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

N60RenderKernel * _Nullable N60RenderKernelCreate(void);
void N60RenderKernelDestroy(N60RenderKernel * _Nonnull kernel);
void N60RenderKernelReset(N60RenderKernel * _Nonnull kernel);

// Control-plane only. Programs are transformed into preallocated frequency-
// domain partitions before a graph is allowed to reference them.
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

// Control-plane only. The caller must serialize publications.
// The snapshot is copied into preallocated storage and atomically published.
bool N60RenderKernelPublishSnapshot(
    N60RenderKernel * _Nonnull kernel,
    N60DSPGraphSnapshot snapshot
);

// Realtime-safe buffer contract. Begin acquires one immutable graph generation
// for the entire hardware buffer; End releases it, publishes per-buffer meters,
// and accounts rendered frames.
N60RenderKernelRenderContext N60RenderKernelBeginRender(N60RenderKernel * _Nonnull kernel);
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

// Convenience one-frame wrapper for deterministic tests and non-callback use.
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
