#ifndef N60FeedForwardPreviewFIR_h
#define N60FeedForwardPreviewFIR_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_FEED_FORWARD_PREVIEW_MAX_TAPS 256u
#define N60_FEED_FORWARD_PREVIEW_MAX_OUTPUT_PEAK 0.06309573444801933f

typedef struct N60FeedForwardPreviewFIR N60FeedForwardPreviewFIR;

typedef struct {
    uint64_t renderedFrames;
    uint64_t sanitizedInputs;
    uint64_t limitedOutputFrames;
    bool configured;
} N60FeedForwardPreviewFIRSnapshot;

/// Control plane only. This pure preview processor is deliberately NOT wired
/// to a Core Audio output callback and has no feed-forward Arm control.
N60FeedForwardPreviewFIR * _Nullable N60FeedForwardPreviewFIRCreate(void);
void N60FeedForwardPreviewFIRDestroy(
    N60FeedForwardPreviewFIR * _Nullable processor
);
void N60FeedForwardPreviewFIRReset(
    N60FeedForwardPreviewFIR * _Nonnull processor
);

/// Control-plane configuration only while rendering is stopped.
/// Coefficients must be finite and each output's L1 gain <= -24 dBFS.
bool N60FeedForwardPreviewFIRConfigure(
    N60FeedForwardPreviewFIR * _Nonnull processor,
    const float * _Nonnull leftTaps,
    const float * _Nonnull rightTaps,
    uint32_t tapCount
);

/// Fully deterministic, allocation-free dry-run processing; never mixed into
/// actual program audio. Null/invalid input produces zero anti-noise.
void N60FeedForwardPreviewFIRProcessFrame(
    N60FeedForwardPreviewFIR * _Nonnull processor,
    float reference,
    float * _Nonnull left,
    float * _Nonnull right
);

N60FeedForwardPreviewFIRSnapshot N60FeedForwardPreviewFIRGetSnapshot(
    const N60FeedForwardPreviewFIR * _Nonnull processor
);

#ifdef __cplusplus
}
#endif

#endif
