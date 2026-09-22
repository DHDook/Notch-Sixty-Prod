#ifndef N60RenderKernel_h
#define N60RenderKernel_h

#include <stdbool.h>
#include <stdint.h>

#include "N60Biquad.h"
#include "N60Crossover.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MAX_EQ_BANDS 64

typedef struct N60RenderKernel N60RenderKernel;

typedef struct {
    double sampleRate;
    uint32_t channelCount;
    float inputGainLinear;
    float headroomGainLinear;
    float outputGainLinear;
    bool bypassed;
    uint32_t latencyFrames;
    uint64_t generation;
    uint32_t gainTransitionFrames;
    bool eqBypassed;
    uint32_t eqBandCount;
    uint32_t eqTransitionFrames;
    N60BiquadBandSnapshot eqBands[N60_MAX_EQ_BANDS];
    uint32_t crossoverTransitionFrames;
    N60CrossoverSnapshot crossover;
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
    uint64_t publishedGeneration;
    uint32_t latencyFrames;
    double sampleRate;
    uint32_t channelCount;
    bool bypassed;
    float inputGainLinear;
    float headroomGainLinear;
    float outputGainLinear;
    bool eqBypassed;
    uint32_t eqBandCount;
    bool crossoverEnabled;
    double crossoverFrequencyHz;
    N60CrossoverTopology crossoverTopology;
    N60CrossoverMonitorMode crossoverMonitorMode;
    float crossoverSubGainLinear;
    bool crossoverSubPolarityInverted;
    uint32_t crossoverSectionCount;
    N60StereoMeterReading inputMeter;
    N60StereoMeterReading postEQMeter;
    N60StereoMeterReading outputMeter;
} N60RenderKernelDiagnostics;

N60DSPGraphSnapshot N60DSPGraphSnapshotMakeUnity(double sampleRate);

// Control-plane graph helpers. Coefficients are designed before publication;
// no trigonometry or filter construction occurs in the realtime callback.
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
bool N60DSPGraphSnapshotSetCrossover(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    double frequencyHz,
    N60CrossoverTopology topology,
    N60CrossoverMonitorMode monitorMode,
    float subGainLinear,
    bool subPolarityInverted,
    bool enabled
);

N60RenderKernel * _Nullable N60RenderKernelCreate(void);
void N60RenderKernelDestroy(N60RenderKernel * _Nonnull kernel);
void N60RenderKernelReset(N60RenderKernel * _Nonnull kernel);

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
