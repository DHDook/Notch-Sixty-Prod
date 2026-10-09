#include "N60FeedForwardPreviewFIR.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

struct N60FeedForwardPreviewFIR {
    float history[N60_FEED_FORWARD_PREVIEW_MAX_TAPS];
    float left[N60_FEED_FORWARD_PREVIEW_MAX_TAPS];
    float right[N60_FEED_FORWARD_PREVIEW_MAX_TAPS];
    uint32_t tapCount;
    uint32_t writeIndex;
    uint64_t renderedFrames;
    uint64_t sanitizedInputs;
    uint64_t limitedOutputFrames;
};

N60FeedForwardPreviewFIR *N60FeedForwardPreviewFIRCreate(void) {
    return calloc(1u, sizeof(N60FeedForwardPreviewFIR));
}

void N60FeedForwardPreviewFIRDestroy(N60FeedForwardPreviewFIR *processor) {
    free(processor);
}

void N60FeedForwardPreviewFIRReset(N60FeedForwardPreviewFIR *processor) {
    if (processor == NULL) return;
    memset(processor->history, 0, sizeof(processor->history));
    processor->writeIndex = 0;
    processor->renderedFrames = 0;
    processor->sanitizedInputs = 0;
    processor->limitedOutputFrames = 0;
}

/// On invalid input leave the previously configured taps intact; never partly
/// publish untrusted gains.
bool N60FeedForwardPreviewFIRConfigure(
    N60FeedForwardPreviewFIR *processor,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount
) {
    if (processor == NULL || leftTaps == NULL || rightTaps == NULL
        || tapCount == 0 || tapCount > N60_FEED_FORWARD_PREVIEW_MAX_TAPS) {
        return false;
    }
    double leftSum = 0, rightSum = 0;
    for (uint32_t i = 0; i < tapCount; ++i) {
        if (!isfinite(leftTaps[i]) || !isfinite(rightTaps[i])) return false;
        leftSum += fabs((double)leftTaps[i]);
        rightSum += fabs((double)rightTaps[i]);
    }
    if (leftSum > N60_FEED_FORWARD_PREVIEW_MAX_OUTPUT_PEAK
        || rightSum > N60_FEED_FORWARD_PREVIEW_MAX_OUTPUT_PEAK) {
        return false;
    }
    memset(processor->left, 0, sizeof(processor->left));
    memset(processor->right, 0, sizeof(processor->right));
    memcpy(processor->left, leftTaps, tapCount * sizeof(float));
    memcpy(processor->right, rightTaps, tapCount * sizeof(float));
    processor->tapCount = tapCount;
    N60FeedForwardPreviewFIRReset(processor);
    return true;
}

void N60FeedForwardPreviewFIRProcessFrame(
    N60FeedForwardPreviewFIR *processor,
    float reference,
    float *left,
    float *right
) {
    if (left != NULL) *left = 0;
    if (right != NULL) *right = 0;
    if (processor == NULL || left == NULL || right == NULL) return;
    if (processor->tapCount == 0) return;
    if (!isfinite(reference)) {
        // A non-finite microphone input is a fault: erase the history rather
        // than allowing NaN to pollute later anti-noise samples.
        memset(processor->history, 0, sizeof(processor->history));
        processor->sanitizedInputs += 1;
        return;
    }
    if (reference > 1) reference = 1;
    if (reference < -1) reference = -1;

    const uint32_t cursor = processor->writeIndex;
    processor->history[cursor] = reference;
    float l = 0, r = 0;
    for (uint32_t tap = 0; tap < processor->tapCount; ++tap) {
        const uint32_t location =
            (cursor - tap) & (N60_FEED_FORWARD_PREVIEW_MAX_TAPS - 1u);
        const float x = processor->history[location];
        l += processor->left[tap] * x;
        r += processor->right[tap] * x;
    }
    processor->writeIndex =
        (cursor + 1u) & (N60_FEED_FORWARD_PREVIEW_MAX_TAPS - 1u);
    const float maxOutput = N60_FEED_FORWARD_PREVIEW_MAX_OUTPUT_PEAK;
    if (!isfinite(l) || !isfinite(r)) {
        l = 0;
        r = 0;
        processor->sanitizedInputs += 1;
    } else {
        if (fabsf(l) > maxOutput || fabsf(r) > maxOutput) {
            processor->limitedOutputFrames += 1;
        }
        if (l > maxOutput) l = maxOutput;
        if (l < -maxOutput) l = -maxOutput;
        if (r > maxOutput) r = maxOutput;
        if (r < -maxOutput) r = -maxOutput;
    }
    processor->renderedFrames += 1;
    *left = l;
    *right = r;
}

N60FeedForwardPreviewFIRSnapshot N60FeedForwardPreviewFIRGetSnapshot(
    const N60FeedForwardPreviewFIR *processor
) {
    if (processor == NULL) return (N60FeedForwardPreviewFIRSnapshot){0};
    return (N60FeedForwardPreviewFIRSnapshot){
        .renderedFrames = processor->renderedFrames,
        .sanitizedInputs = processor->sanitizedInputs,
        .limitedOutputFrames = processor->limitedOutputFrames,
        .configured = processor->tapCount > 0
    };
}
