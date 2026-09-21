#ifndef N60RenderKernel_h
#define N60RenderKernel_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct N60RenderKernel N60RenderKernel;

typedef struct {
    double sampleRate;
    uint32_t channelCount;
    float inputGainLinear;
    float outputGainLinear;
    bool bypassed;
    uint32_t latencyFrames;
    uint64_t generation;
} N60DSPGraphSnapshot;

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
} N60RenderKernelDiagnostics;

N60DSPGraphSnapshot N60DSPGraphSnapshotMakeUnity(double sampleRate);

N60RenderKernel * _Nullable N60RenderKernelCreate(void);
void N60RenderKernelDestroy(N60RenderKernel * _Nonnull kernel);
void N60RenderKernelReset(N60RenderKernel * _Nonnull kernel);

// Control-plane only. The caller must serialize publications.
// The snapshot is copied into preallocated storage and atomically published.
bool N60RenderKernelPublishSnapshot(
    N60RenderKernel * _Nonnull kernel,
    N60DSPGraphSnapshot snapshot
);

// Realtime-safe: no allocation, blocking locks, logging, I/O, or control-plane work.
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
