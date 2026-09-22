#ifndef N60RenderKernel_h
#define N60RenderKernel_h

#include <stdbool.h>
#include <stdint.h>

#include "N60Biquad.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MAX_EQ_BANDS 64

typedef struct N60RenderKernel N60RenderKernel;

typedef struct {
    double sampleRate;
    uint32_t channelCount;
    float inputGainLinear;
    float outputGainLinear;
    bool bypassed;
    uint32_t latencyFrames;
    uint64_t generation;
    bool eqBypassed;
    uint32_t eqBandCount;
    uint32_t eqTransitionFrames;
    N60BiquadBandSnapshot eqBands[N60_MAX_EQ_BANDS];
} N60DSPGraphSnapshot;

typedef struct {
    N60DSPGraphSnapshot snapshot;
    uint32_t slotIndex;
    bool acquired;
} N60RenderKernelRenderContext;

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
    bool eqBypassed;
    uint32_t eqBandCount;
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
// for the entire hardware buffer; End releases it and accounts rendered frames.
N60RenderKernelRenderContext N60RenderKernelBeginRender(N60RenderKernel * _Nonnull kernel);
void N60RenderKernelProcessStereoFrameInContext(
    N60RenderKernel * _Nonnull kernel,
    const N60RenderKernelRenderContext * _Nonnull context,
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
