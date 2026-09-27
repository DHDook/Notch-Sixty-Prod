#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "NotchSixty/Audio/Realtime/N60SpectralDenoiser.c"
text = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one anchor, found {count}")
    text = text.replace(old, new, 1)

replace_once(
    """    float outputLeft[N60_DENOISER_OUTPUT_RING_SIZE];
    float outputRight[N60_DENOISER_OUTPUT_RING_SIZE];
    N60DenoiserComplex fftLeft[N60_DENOISER_MAX_FFT_SIZE];
""",
    """    float outputLeft[N60_DENOISER_OUTPUT_RING_SIZE];
    float outputRight[N60_DENOISER_OUTPUT_RING_SIZE];
    uint64_t outputGeneration;
    uint64_t outputGenerationTag[N60_DENOISER_OUTPUT_RING_SIZE];
    N60DenoiserComplex fftLeft[N60_DENOISER_MAX_FFT_SIZE];
""",
    "output generation storage",
)

replace_once(
    """    float targetGain[N60_DENOISER_MAX_BINS];
    float smoothedGain[N60_DENOISER_MAX_BINS];
    uint32_t adaptiveFramesInBlock;
""",
    """    float targetGain[N60_DENOISER_MAX_BINS];
    float smoothedGain[N60_DENOISER_MAX_BINS];
    bool enhancementHistoryValid;
    bool adaptiveBlockFresh;
    uint32_t adaptiveFramesInBlock;
""",
    "history validity storage",
)

start = text.index("static void clear_processing_state(N60SpectralDenoiserRuntime *runtime) {")
end = text.index("\n}\n\nN60SpectralDenoiserRuntime *N60SpectralDenoiserCreate", start) + 3
new_reset = """static void reset_processing_state(N60SpectralDenoiserRuntime *runtime) {
    // Large sample, FFT, overlap-add, and profile arrays are logically invalidated
    // rather than cleared. Input samples are overwritten before the first new FFT;
    // FFT work buffers are initialized by process_spectral_frame; the output ring
    // is protected by generation tags; and profile/history validity is scalar.
    runtime->inputWrite = 0;
    runtime->samplesAvailable = 0;
    runtime->samplesSinceFrame = 0;
    runtime->sampleIndex = 0;

    runtime->outputGeneration += 1u;
    if (runtime->outputGeneration == 0u) runtime->outputGeneration = 1u;

    runtime->adaptiveFramesInBlock = 0;
    runtime->adaptiveBlockTargetFrames = 0;
    runtime->adaptiveBlocksCompleted = 0;
    runtime->adaptiveBlockFresh = true;
    runtime->profileReady = false;
    runtime->capturedProfile = false;
    runtime->enhancementHistoryValid = false;
    runtime->lastProfileRevision = 0;
    runtime->captureActive = false;
    runtime->captureFramesCollected = 0;
    runtime->captureTargetFrames = 0;
    runtime->estimatedNoiseDBFS = -120.0f;
    runtime->meanSuppressionDB = 0.0f;
    runtime->maxSuppressionDB = 0.0f;
    runtime->spectralFramesProcessed = 0;
}
"""
text = text[:start] + new_reset + text[end:]

text = text.replace("    clear_processing_state(runtime);\n    runtime->activeFFTSize = 2048u;", "    reset_processing_state(runtime);\n    runtime->activeFFTSize = 2048u;", 1)
text = text.replace("    clear_processing_state(runtime);\n    runtime->activeFFTSize = active > 0 ? active : 2048u;", "    reset_processing_state(runtime);\n    runtime->activeFFTSize = active > 0 ? active : 2048u;", 1)

replace_once(
    """static void reset_adaptive_minimum(N60SpectralDenoiserRuntime *runtime, uint32_t binCount) {
    for (uint32_t bin = 0; bin < binCount; ++bin) runtime->adaptiveMinimum[bin] = FLT_MAX;
    runtime->adaptiveFramesInBlock = 0;
}
""",
    """static void reset_adaptive_minimum(N60SpectralDenoiserRuntime *runtime, uint32_t binCount) {
    (void)binCount;
    runtime->adaptiveFramesInBlock = 0;
    runtime->adaptiveBlockFresh = true;
}
""",
    "adaptive minimum reset",
)

replace_once(
    """static void begin_capture(N60SpectralDenoiserRuntime *runtime, double sampleRate, uint32_t hopSize, uint32_t binCount) {
    memset(runtime->captureSum, 0, sizeof(float) * binCount);
    runtime->captureFramesCollected = 0;
""",
    """static void begin_capture(N60SpectralDenoiserRuntime *runtime, double sampleRate, uint32_t hopSize, uint32_t binCount) {
    (void)binCount;
    runtime->captureFramesCollected = 0;
""",
    "capture reset",
)

replace_once(
    """static void reset_profile(N60SpectralDenoiserRuntime *runtime, uint32_t binCount) {
    memset(runtime->noisePower, 0, sizeof(float) * binCount);
    memset(runtime->previousEnhancedPower, 0, sizeof(float) * binCount);
    for (uint32_t bin = 0; bin < binCount; ++bin) runtime->smoothedGain[bin] = 1.0f;
    runtime->profileReady = false;
""",
    """static void reset_profile(N60SpectralDenoiserRuntime *runtime, uint32_t binCount) {
    runtime->profileReady = false;
    runtime->enhancementHistoryValid = false;
""",
    "profile reset",
)

replace_once(
    """    if (runtime->captureActive) {
        for (uint32_t bin = 0; bin < binCount; ++bin) runtime->captureSum[bin] += power[bin];
        runtime->captureFramesCollected += 1u;
""",
    """    if (runtime->captureActive) {
        bool firstCaptureFrame = runtime->captureFramesCollected == 0u;
        for (uint32_t bin = 0; bin < binCount; ++bin) {
            if (firstCaptureFrame) {
                runtime->captureSum[bin] = power[bin];
            } else {
                runtime->captureSum[bin] += power[bin];
            }
        }
        runtime->captureFramesCollected += 1u;
""",
    "capture accumulation",
)

replace_once(
    """            runtime->profileReady = true;
            runtime->capturedProfile = true;
            runtime->captureActive = false;
""",
    """            runtime->profileReady = true;
            runtime->capturedProfile = true;
            runtime->captureActive = false;
            runtime->enhancementHistoryValid = false;
""",
    "capture completion history",
)

replace_once(
    """    for (uint32_t bin = 0; bin < binCount; ++bin) {
        if (power[bin] <= adaptiveCeilingPower) {
            runtime->adaptiveMinimum[bin] = fminf(runtime->adaptiveMinimum[bin], power[bin]);
        }
    }
    runtime->adaptiveFramesInBlock += 1u;
""",
    """    bool firstAdaptiveFrame = runtime->adaptiveBlockFresh;
    for (uint32_t bin = 0; bin < binCount; ++bin) {
        if (power[bin] <= adaptiveCeilingPower) {
            runtime->adaptiveMinimum[bin] = firstAdaptiveFrame
                ? power[bin]
                : fminf(runtime->adaptiveMinimum[bin], power[bin]);
        } else if (firstAdaptiveFrame) {
            runtime->adaptiveMinimum[bin] = FLT_MAX;
        }
    }
    runtime->adaptiveBlockFresh = false;
    runtime->adaptiveFramesInBlock += 1u;
""",
    "adaptive accumulation",
)

replace_once(
    """    bool learnedAnyBin = false;
    for (uint32_t bin = 0; bin < binCount; ++bin) {
        if (runtime->adaptiveMinimum[bin] == FLT_MAX) continue;
        learnedAnyBin = true;
""",
    """    bool learnedAnyBin = false;
    for (uint32_t bin = 0; bin < binCount; ++bin) {
        if (runtime->adaptiveMinimum[bin] == FLT_MAX) {
            if (runtime->adaptiveBlocksCompleted == 0u) runtime->noisePower[bin] = 0.0f;
            continue;
        }
        learnedAnyBin = true;
""",
    "adaptive stale noise invalidation",
)

replace_once(
    """    if (learnedAnyBin) {
        runtime->adaptiveBlocksCompleted += 1u;
        if (runtime->adaptiveBlocksCompleted >= N60_DENOISER_ADAPTIVE_READY_BLOCKS) runtime->profileReady = true;
    }
""",
    """    if (learnedAnyBin) {
        bool wasReady = runtime->profileReady;
        runtime->adaptiveBlocksCompleted += 1u;
        if (runtime->adaptiveBlocksCompleted >= N60_DENOISER_ADAPTIVE_READY_BLOCKS) runtime->profileReady = true;
        if (!wasReady && runtime->profileReady) runtime->enhancementHistoryValid = false;
    }
""",
    "adaptive readiness history",
)

replace_once(
    """    double weightedSuppression = 0.0;
    double weightedPower = 0.0;
    float maximumSuppression = 0.0f;

    for (uint32_t bin = 0; bin < binCount; ++bin) {
""",
    """    double weightedSuppression = 0.0;
    double weightedPower = 0.0;
    float maximumSuppression = 0.0f;
    bool historyValid = runtime->enhancementHistoryValid && runtime->profileReady;

    for (uint32_t bin = 0; bin < binCount; ++bin) {
""",
    "history validity latch",
)

replace_once(
    """            float previousPrior = runtime->previousEnhancedPower[bin] / fmaxf(noise, N60_DENOISER_EPSILON);
""",
    """            float previousPrior = historyValid
                ? runtime->previousEnhancedPower[bin] / fmaxf(noise, N60_DENOISER_EPSILON)
                : 0.0f;
""",
    "previous enhanced history",
)

replace_once(
    """        float previous = runtime->smoothedGain[bin];
""",
    """        float previous = historyValid ? runtime->smoothedGain[bin] : 1.0f;
""",
    "smoothed gain history",
)

replace_once(
    """    transform(runtime, runtime->fftLeft, size, true);
    transform(runtime, runtime->fftRight, size, true);
""",
    """    runtime->enhancementHistoryValid = runtime->profileReady;

    transform(runtime, runtime->fftLeft, size, true);
    transform(runtime, runtime->fftRight, size, true);
""",
    "history commit",
)

replace_once(
    """        uint32_t ringIndex = (uint32_t)(absoluteTarget & (N60_DENOISER_OUTPUT_RING_SIZE - 1u));
        float w = window[index];
        runtime->outputLeft[ringIndex] += runtime->fftLeft[index].real * w;
        runtime->outputRight[ringIndex] += runtime->fftRight[index].real * w;
""",
    """        uint32_t ringIndex = (uint32_t)(absoluteTarget & (N60_DENOISER_OUTPUT_RING_SIZE - 1u));
        if (runtime->outputGenerationTag[ringIndex] != runtime->outputGeneration) {
            runtime->outputGenerationTag[ringIndex] = runtime->outputGeneration;
            runtime->outputLeft[ringIndex] = 0.0f;
            runtime->outputRight[ringIndex] = 0.0f;
        }
        float w = window[index];
        runtime->outputLeft[ringIndex] += runtime->fftLeft[index].real * w;
        runtime->outputRight[ringIndex] += runtime->fftRight[index].real * w;
""",
    "output generation write",
)

replace_once(
    """    if (runtime->activeFFTSize != snapshot.fftSize) {
        clear_processing_state(runtime);
        runtime->activeFFTSize = snapshot.fftSize;
    }
""",
    """    if (runtime->activeFFTSize != snapshot.fftSize) {
        reset_processing_state(runtime);
        runtime->activeFFTSize = snapshot.fftSize;
    }
""",
    "quality transition reset",
)

replace_once(
    """    uint32_t outputIndex = (uint32_t)(runtime->sampleIndex & (N60_DENOISER_OUTPUT_RING_SIZE - 1u));
    float delayedLeft = runtime->outputLeft[outputIndex];
    float delayedRight = runtime->outputRight[outputIndex];
    runtime->outputLeft[outputIndex] = 0.0f;
    runtime->outputRight[outputIndex] = 0.0f;
""",
    """    uint32_t outputIndex = (uint32_t)(runtime->sampleIndex & (N60_DENOISER_OUTPUT_RING_SIZE - 1u));
    bool outputValid = runtime->outputGenerationTag[outputIndex] == runtime->outputGeneration;
    float delayedLeft = outputValid ? runtime->outputLeft[outputIndex] : 0.0f;
    float delayedRight = outputValid ? runtime->outputRight[outputIndex] : 0.0f;
    if (outputValid) {
        runtime->outputLeft[outputIndex] = 0.0f;
        runtime->outputRight[outputIndex] = 0.0f;
    }
""",
    "output generation read",
)

if "clear_processing_state(runtime)" in text:
    raise RuntimeError("clear_processing_state call remains")
if "static void clear_processing_state" in text:
    raise RuntimeError("clear_processing_state definition remains")

path.write_text(text)
