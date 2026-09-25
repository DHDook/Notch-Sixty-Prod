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

#define N60_MAX_EQ_BANDS 64
#define N60_MAX_EQ_RENDER_SLOTS (N60_MAX_EQ_BANDS * 2)
#define N60_EQ_CHANNEL_LEFT 0x1u
#define N60_EQ_CHANNEL_RIGHT 0x2u
#define N60_EQ_CHANNEL_STEREO (N60_EQ_CHANNEL_LEFT | N60_EQ_CHANNEL_RIGHT)
#define N60_MAX_AUDITION_DELAY_FRAMES 131072u

typedef enum {
    N60AuditionModeProcessed = 0,
    N60AuditionModeReference = 1,
    N60AuditionModeDelta = 2,
} N60AuditionMode;

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
    double sampleRate;
    uint32_t channelCount;
    float inputGainLinear;
    float headroomGainLinear;
    float outputGainLinear;
    float masterGainLinear;
    float balanceGainLeftLinear;
    float balanceGainRightLinear;
    bool bypassed;
    N60AuditionMode auditionMode;
    uint32_t latencyFrames;
    uint64_t generation;
    uint32_t gainTransitionFrames;
    bool eqBypassed;
    uint32_t eqBandCount;
    uint32_t eqTransitionFrames;
    // Keep the pre-PR23 band array representation intact; channel scope is a
    // parallel array so the proven linked-stereo path remains structurally stable.
    N60BiquadBandSnapshot eqBands[N60_MAX_EQ_RENDER_SLOTS];
    uint8_t eqBandChannelMasks[N60_MAX_EQ_RENDER_SLOTS];
    uint32_t crossoverTransitionFrames;
    N60CrossoverSnapshot crossover;
    N60ConvolutionGraphState convolution;
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
    N60AuditionMode auditionMode;
    float inputGainLinear;
    float headroomGainLinear;
    float outputGainLinear;
    float masterGainLinear;
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
void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot * _Nonnull snapshot);
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
bool N60RenderKernelPublishSnapshot(
    N60RenderKernel * _Nonnull kernel,
    N60DSPGraphSnapshot snapshot
);
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
