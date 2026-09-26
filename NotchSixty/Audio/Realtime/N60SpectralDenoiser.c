#include "N60SpectralDenoiser.h"

#include <float.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define N60_DENOISER_PI 3.14159265358979323846
#define N60_DENOISER_OUTPUT_RING_SIZE 16384u
#define N60_DENOISER_CAPTURE_SECONDS 1.0
#define N60_DENOISER_ADAPTIVE_BLOCK_SECONDS 1.0
#define N60_DENOISER_ADAPTIVE_READY_BLOCKS 2u
#define N60_DENOISER_EPSILON 1.0e-20f

typedef struct {
    float real;
    float imag;
} N60DenoiserComplex;

struct N60SpectralDenoiserRuntime {
    uint16_t bitReverse[N60_DENOISER_MAX_FFT_SIZE];
    N60DenoiserComplex twiddles[N60_DENOISER_MAX_FFT_SIZE / 2u];
    float windowQuality[1024];
    float windowHigh[2048];
    float windowUltra[4096];
    float windowSumQuality;
    float windowSumHigh;
    float windowSumUltra;

    float inputLeft[N60_DENOISER_MAX_FFT_SIZE];
    float inputRight[N60_DENOISER_MAX_FFT_SIZE];
    uint32_t inputWrite;
    uint32_t samplesAvailable;
    uint32_t samplesSinceFrame;
    uint64_t sampleIndex;
    uint32_t activeFFTSize;

    float outputLeft[N60_DENOISER_OUTPUT_RING_SIZE];
    float outputRight[N60_DENOISER_OUTPUT_RING_SIZE];
    N60DenoiserComplex fftLeft[N60_DENOISER_MAX_FFT_SIZE];
    N60DenoiserComplex fftRight[N60_DENOISER_MAX_FFT_SIZE];

    float noisePower[N60_DENOISER_MAX_BINS];
    float adaptiveMinimum[N60_DENOISER_MAX_BINS];
    float captureSum[N60_DENOISER_MAX_BINS];
    float previousEnhancedPower[N60_DENOISER_MAX_BINS];
    float linkedPower[N60_DENOISER_MAX_BINS];
    float targetGain[N60_DENOISER_MAX_BINS];
    float smoothedGain[N60_DENOISER_MAX_BINS];
    uint32_t adaptiveFramesInBlock;
    uint32_t adaptiveBlockTargetFrames;
    uint32_t adaptiveBlocksCompleted;
    bool profileReady;
    bool capturedProfile;

    uint32_t lastProfileRevision;
    bool captureActive;
    uint32_t captureFramesCollected;
    uint32_t captureTargetFrames;

    float estimatedNoiseDBFS;
    float meanSuppressionDB;
    float maxSuppressionDB;
    uint64_t spectralFramesProcessed;
};

static float clampf(float value, float minimum, float maximum) {
    return fminf(fmaxf(value, minimum), maximum);
}

static uint32_t fft_size_for_quality(N60DenoiserQuality quality) {
    switch (quality) {
    case N60DenoiserQualityQuality: return 1024u;
    case N60DenoiserQualityHigh: return 2048u;
    case N60DenoiserQualityUltra: return 4096u;
    default: return 0u;
    }
}

static bool quality_is_valid(N60DenoiserQuality quality) {
    return quality >= N60DenoiserQualityQuality && quality <= N60DenoiserQualityUltra;
}

static bool tuning_is_valid(N60DenoiserTuning tuning) {
    return tuning >= N60DenoiserTuningNatural && tuning <= N60DenoiserTuningCustom;
}

static bool command_is_valid(N60DenoiserProfileCommand command) {
    return command >= N60DenoiserProfileCommandNone && command <= N60DenoiserProfileCommandReset;
}

static void apply_tuning_defaults(N60SpectralDenoiserSnapshot *snapshot) {
    switch (snapshot->tuning) {
    case N60DenoiserTuningNatural:
        snapshot->minimumGain = 0.35f;
        snapshot->decisionDirectedAlpha = 0.97f;
        snapshot->suppressionAttack = 0.82f;
        snapshot->suppressionRelease = 0.45f;
        snapshot->spectralSmoothingRadius = 2;
        snapshot->dehissStrength = 0.0f;
        break;
    case N60DenoiserTuningAggressive:
        snapshot->minimumGain = 0.08f;
        snapshot->decisionDirectedAlpha = 0.94f;
        snapshot->suppressionAttack = 0.68f;
        snapshot->suppressionRelease = 0.30f;
        snapshot->spectralSmoothingRadius = 1;
        snapshot->dehissStrength = 0.0f;
        break;
    case N60DenoiserTuningDehiss:
        snapshot->minimumGain = 0.18f;
        snapshot->decisionDirectedAlpha = 0.96f;
        snapshot->suppressionAttack = 0.78f;
        snapshot->suppressionRelease = 0.35f;
        snapshot->spectralSmoothingRadius = 2;
        snapshot->dehissStrength = 1.0f;
        break;
    case N60DenoiserTuningCustom:
    case N60DenoiserTuningStandard:
    default:
        snapshot->minimumGain = 0.20f;
        snapshot->decisionDirectedAlpha = 0.96f;
        snapshot->suppressionAttack = 0.75f;
        snapshot->suppressionRelease = 0.35f;
        snapshot->spectralSmoothingRadius = 1;
        snapshot->dehissStrength = 0.0f;
        break;
    }
}

N60SpectralDenoiserSnapshot N60SpectralDenoiserSnapshotMakeBypassed(double sampleRate) {
    N60SpectralDenoiserSnapshot snapshot = {0};
    snapshot.sampleRate = sampleRate;
    snapshot.enabled = false;
    snapshot.tuning = N60DenoiserTuningStandard;
    snapshot.quality = N60DenoiserQualityHigh;
    snapshot.reductionAmount = 0.5f;
    snapshot.thresholdDBFS = -60.0f;
    snapshot.protectedRangeEnabled = false;
    snapshot.protectedLowHz = 0.0f;
    snapshot.protectedHighHz = 150.0f;
    snapshot.profileRevision = 0;
    snapshot.profileCommand = N60DenoiserProfileCommandNone;
    snapshot.fftSize = fft_size_for_quality(snapshot.quality);
    snapshot.hopSize = snapshot.fftSize / 2u;
    snapshot.latencyFrames = snapshot.fftSize;
    apply_tuning_defaults(&snapshot);
    (void)sampleRate;
    return snapshot;
}

bool N60SpectralDenoiserSnapshotConfigure(
    N60SpectralDenoiserSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    N60DenoiserTuning tuning,
    N60DenoiserQuality quality,
    float reductionAmount,
    float thresholdDBFS,
    bool protectedRangeEnabled,
    float protectedLowHz,
    float protectedHighHz,
    uint32_t profileRevision,
    N60DenoiserProfileCommand profileCommand
) {
    if (snapshot == NULL
        || !isfinite(sampleRate) || sampleRate < 8000.0 || sampleRate > 384000.0
        || !quality_is_valid(quality) || !tuning_is_valid(tuning) || !command_is_valid(profileCommand)
        || !isfinite(reductionAmount) || reductionAmount < 0.0f || reductionAmount > 1.0f
        || !isfinite(thresholdDBFS) || thresholdDBFS < -96.0f || thresholdDBFS > -30.0f
        || !isfinite(protectedLowHz) || !isfinite(protectedHighHz)
        || protectedLowHz < 0.0f || protectedHighHz < protectedLowHz
        || protectedHighHz > 20000.0f || protectedHighHz >= (float)(sampleRate * 0.5)) {
        return false;
    }

    N60SpectralDenoiserSnapshot configured = {0};
    configured.sampleRate = sampleRate;
    configured.enabled = enabled;
    configured.tuning = tuning;
    configured.quality = quality;
    configured.reductionAmount = reductionAmount;
    configured.thresholdDBFS = thresholdDBFS;
    configured.protectedRangeEnabled = protectedRangeEnabled;
    configured.protectedLowHz = protectedLowHz;
    configured.protectedHighHz = protectedHighHz;
    configured.profileRevision = profileRevision;
    configured.profileCommand = profileCommand;
    configured.fftSize = fft_size_for_quality(quality);
    configured.hopSize = configured.fftSize / 2u;
    configured.latencyFrames = configured.fftSize;
    apply_tuning_defaults(&configured);
    *snapshot = configured;
    return true;
}

bool N60SpectralDenoiserSnapshotIsValid(N60SpectralDenoiserSnapshot snapshot, double sampleRate) {
    if (!isfinite(sampleRate) || sampleRate < 8000.0 || sampleRate > 384000.0
        || !isfinite(snapshot.sampleRate) || fabs(snapshot.sampleRate - sampleRate) > 0.5
        || !quality_is_valid(snapshot.quality) || !tuning_is_valid(snapshot.tuning)
        || !command_is_valid(snapshot.profileCommand)
        || !isfinite(snapshot.reductionAmount) || snapshot.reductionAmount < 0.0f || snapshot.reductionAmount > 1.0f
        || !isfinite(snapshot.thresholdDBFS) || snapshot.thresholdDBFS < -96.0f || snapshot.thresholdDBFS > -30.0f
        || !isfinite(snapshot.protectedLowHz) || !isfinite(snapshot.protectedHighHz)
        || snapshot.protectedLowHz < 0.0f || snapshot.protectedHighHz < snapshot.protectedLowHz
        || snapshot.protectedHighHz > 20000.0f || snapshot.protectedHighHz >= (float)(sampleRate * 0.5)
        || !isfinite(snapshot.minimumGain) || snapshot.minimumGain <= 0.0f || snapshot.minimumGain > 1.0f
        || !isfinite(snapshot.decisionDirectedAlpha) || snapshot.decisionDirectedAlpha < 0.0f || snapshot.decisionDirectedAlpha >= 1.0f
        || !isfinite(snapshot.suppressionAttack) || snapshot.suppressionAttack < 0.0f || snapshot.suppressionAttack >= 1.0f
        || !isfinite(snapshot.suppressionRelease) || snapshot.suppressionRelease < 0.0f || snapshot.suppressionRelease >= 1.0f
        || snapshot.spectralSmoothingRadius > 4u
        || !isfinite(snapshot.dehissStrength) || snapshot.dehissStrength < 0.0f || snapshot.dehissStrength > 2.0f) {
        return false;
    }
    uint32_t expected = fft_size_for_quality(snapshot.quality);
    return snapshot.fftSize == expected
        && snapshot.hopSize == expected / 2u
        && snapshot.latencyFrames == expected;
}

static void build_window(float *window, uint32_t size, float *sumOut) {
    double sum = 0.0;
    for (uint32_t index = 0; index < size; ++index) {
        double hann = 0.5 - 0.5 * cos(2.0 * N60_DENOISER_PI * (double)index / (double)size);
        float value = (float)sqrt(fmax(hann, 0.0));
        window[index] = value;
        sum += (double)value;
    }
    *sumOut = (float)sum;
}

static void clear_processing_state(N60SpectralDenoiserRuntime *runtime) {
    memset(runtime->inputLeft, 0, sizeof(runtime->inputLeft));
    memset(runtime->inputRight, 0, sizeof(runtime->inputRight));
    memset(runtime->outputLeft, 0, sizeof(runtime->outputLeft));
    memset(runtime->outputRight, 0, sizeof(runtime->outputRight));
    memset(runtime->fftLeft, 0, sizeof(runtime->fftLeft));
    memset(runtime->fftRight, 0, sizeof(runtime->fftRight));
    memset(runtime->noisePower, 0, sizeof(runtime->noisePower));
    memset(runtime->captureSum, 0, sizeof(runtime->captureSum));
    memset(runtime->previousEnhancedPower, 0, sizeof(runtime->previousEnhancedPower));
    memset(runtime->linkedPower, 0, sizeof(runtime->linkedPower));
    memset(runtime->targetGain, 0, sizeof(runtime->targetGain));
    runtime->inputWrite = 0;
    runtime->samplesAvailable = 0;
    runtime->samplesSinceFrame = 0;
    runtime->sampleIndex = 0;
    runtime->adaptiveFramesInBlock = 0;
    runtime->adaptiveBlockTargetFrames = 0;
    runtime->adaptiveBlocksCompleted = 0;
    runtime->profileReady = false;
    runtime->capturedProfile = false;
    runtime->lastProfileRevision = 0;
    runtime->captureActive = false;
    runtime->captureFramesCollected = 0;
    runtime->captureTargetFrames = 0;
    runtime->estimatedNoiseDBFS = -120.0f;
    runtime->meanSuppressionDB = 0.0f;
    runtime->maxSuppressionDB = 0.0f;
    runtime->spectralFramesProcessed = 0;
    for (uint32_t bin = 0; bin < N60_DENOISER_MAX_BINS; ++bin) {
        runtime->adaptiveMinimum[bin] = FLT_MAX;
        runtime->smoothedGain[bin] = 1.0f;
    }
}

N60SpectralDenoiserRuntime *N60SpectralDenoiserCreate(void) {
    N60SpectralDenoiserRuntime *runtime = calloc(1, sizeof(N60SpectralDenoiserRuntime));
    if (runtime == NULL) return NULL;

    uint32_t bitCount = 12;
    for (uint32_t index = 0; index < N60_DENOISER_MAX_FFT_SIZE; ++index) {
        uint32_t source = index;
        uint32_t reversed = 0;
        for (uint32_t bit = 0; bit < bitCount; ++bit) {
            reversed = (reversed << 1u) | (source & 1u);
            source >>= 1u;
        }
        runtime->bitReverse[index] = (uint16_t)reversed;
    }
    for (uint32_t index = 0; index < N60_DENOISER_MAX_FFT_SIZE / 2u; ++index) {
        double phase = -2.0 * N60_DENOISER_PI * (double)index / (double)N60_DENOISER_MAX_FFT_SIZE;
        runtime->twiddles[index].real = (float)cos(phase);
        runtime->twiddles[index].imag = (float)sin(phase);
    }
    build_window(runtime->windowQuality, 1024u, &runtime->windowSumQuality);
    build_window(runtime->windowHigh, 2048u, &runtime->windowSumHigh);
    build_window(runtime->windowUltra, 4096u, &runtime->windowSumUltra);
    clear_processing_state(runtime);
    runtime->activeFFTSize = 2048u;
    return runtime;
}

void N60SpectralDenoiserDestroy(N60SpectralDenoiserRuntime *runtime) {
    free(runtime);
}

void N60SpectralDenoiserReset(N60SpectralDenoiserRuntime *runtime) {
    if (runtime == NULL) return;
    uint32_t active = runtime->activeFFTSize;
    clear_processing_state(runtime);
    runtime->activeFFTSize = active > 0 ? active : 2048u;
}

static const float *window_for_size(const N60SpectralDenoiserRuntime *runtime, uint32_t size, float *sumOut) {
    switch (size) {
    case 1024u:
        *sumOut = runtime->windowSumQuality;
        return runtime->windowQuality;
    case 4096u:
        *sumOut = runtime->windowSumUltra;
        return runtime->windowUltra;
    case 2048u:
    default:
        *sumOut = runtime->windowSumHigh;
        return runtime->windowHigh;
    }
}

static N60DenoiserComplex complex_multiply(N60DenoiserComplex lhs, N60DenoiserComplex rhs) {
    N60DenoiserComplex result = {
        lhs.real * rhs.real - lhs.imag * rhs.imag,
        lhs.real * rhs.imag + lhs.imag * rhs.real,
    };
    return result;
}

static void transform(N60SpectralDenoiserRuntime *runtime, N60DenoiserComplex *values, uint32_t size, bool inverse) {
    uint32_t bitCount = 0;
    for (uint32_t value = size; value > 1u; value >>= 1u) bitCount += 1u;
    uint32_t shift = 12u - bitCount;
    for (uint32_t index = 0; index < size; ++index) {
        uint32_t reversed = ((uint32_t)runtime->bitReverse[index]) >> shift;
        if (reversed > index) {
            N60DenoiserComplex temporary = values[index];
            values[index] = values[reversed];
            values[reversed] = temporary;
        }
    }

    for (uint32_t length = 2u; length <= size; length <<= 1u) {
        uint32_t halfLength = length >> 1u;
        uint32_t twiddleStep = N60_DENOISER_MAX_FFT_SIZE / length;
        for (uint32_t base = 0; base < size; base += length) {
            for (uint32_t offset = 0; offset < halfLength; ++offset) {
                N60DenoiserComplex twiddle = runtime->twiddles[offset * twiddleStep];
                if (inverse) twiddle.imag = -twiddle.imag;
                N60DenoiserComplex even = values[base + offset];
                N60DenoiserComplex odd = complex_multiply(values[base + offset + halfLength], twiddle);
                values[base + offset] = (N60DenoiserComplex){even.real + odd.real, even.imag + odd.imag};
                values[base + offset + halfLength] = (N60DenoiserComplex){even.real - odd.real, even.imag - odd.imag};
            }
        }
    }

    if (inverse) {
        float scale = 1.0f / (float)size;
        for (uint32_t index = 0; index < size; ++index) {
            values[index].real *= scale;
            values[index].imag *= scale;
        }
    }
}

static float bin_power(N60DenoiserComplex value, uint32_t bin, uint32_t nyquistBin, float windowSum) {
    float scale = (bin == 0u || bin == nyquistBin) ? 1.0f / windowSum : 2.0f / windowSum;
    return (value.real * value.real + value.imag * value.imag) * scale * scale;
}

static bool bin_is_protected(N60SpectralDenoiserSnapshot snapshot, double sampleRate, uint32_t bin) {
    if (!snapshot.protectedRangeEnabled) return false;
    double frequency = (double)bin * sampleRate / (double)snapshot.fftSize;
    return frequency >= (double)snapshot.protectedLowHz && frequency <= (double)snapshot.protectedHighHz;
}

static void reset_adaptive_minimum(N60SpectralDenoiserRuntime *runtime, uint32_t binCount) {
    for (uint32_t bin = 0; bin < binCount; ++bin) runtime->adaptiveMinimum[bin] = FLT_MAX;
    runtime->adaptiveFramesInBlock = 0;
}

static void begin_capture(N60SpectralDenoiserRuntime *runtime, double sampleRate, uint32_t hopSize, uint32_t binCount) {
    memset(runtime->captureSum, 0, sizeof(float) * binCount);
    runtime->captureFramesCollected = 0;
    runtime->captureTargetFrames = (uint32_t)ceil(sampleRate * N60_DENOISER_CAPTURE_SECONDS / (double)hopSize);
    if (runtime->captureTargetFrames < 4u) runtime->captureTargetFrames = 4u;
    runtime->captureActive = true;
}

static void reset_profile(N60SpectralDenoiserRuntime *runtime, uint32_t binCount) {
    memset(runtime->noisePower, 0, sizeof(float) * binCount);
    memset(runtime->previousEnhancedPower, 0, sizeof(float) * binCount);
    for (uint32_t bin = 0; bin < binCount; ++bin) runtime->smoothedGain[bin] = 1.0f;
    runtime->profileReady = false;
    runtime->capturedProfile = false;
    runtime->adaptiveBlocksCompleted = 0;
    runtime->captureActive = false;
    runtime->captureFramesCollected = 0;
    runtime->captureTargetFrames = 0;
    reset_adaptive_minimum(runtime, binCount);
}

static void handle_profile_command(
    N60SpectralDenoiserRuntime *runtime,
    N60SpectralDenoiserSnapshot snapshot,
    double sampleRate
) {
    if (snapshot.profileRevision == runtime->lastProfileRevision) return;
    runtime->lastProfileRevision = snapshot.profileRevision;
    uint32_t binCount = snapshot.fftSize / 2u + 1u;
    if (snapshot.profileCommand == N60DenoiserProfileCommandReset) {
        reset_profile(runtime, binCount);
    } else if (snapshot.profileCommand == N60DenoiserProfileCommandCapture) {
        begin_capture(runtime, sampleRate, snapshot.hopSize, binCount);
    }
}

static void update_profile(
    N60SpectralDenoiserRuntime *runtime,
    const float *power,
    uint32_t binCount,
    double sampleRate,
    uint32_t hopSize
) {
    if (runtime->adaptiveBlockTargetFrames == 0u) {
        runtime->adaptiveBlockTargetFrames = (uint32_t)ceil(sampleRate * N60_DENOISER_ADAPTIVE_BLOCK_SECONDS / (double)hopSize);
        if (runtime->adaptiveBlockTargetFrames < 4u) runtime->adaptiveBlockTargetFrames = 4u;
    }

    if (runtime->captureActive) {
        for (uint32_t bin = 0; bin < binCount; ++bin) runtime->captureSum[bin] += power[bin];
        runtime->captureFramesCollected += 1u;
        if (runtime->captureFramesCollected >= runtime->captureTargetFrames) {
            float scale = 1.0f / (float)runtime->captureFramesCollected;
            for (uint32_t bin = 0; bin < binCount; ++bin) {
                runtime->noisePower[bin] = fmaxf(runtime->captureSum[bin] * scale, N60_DENOISER_EPSILON);
            }
            runtime->profileReady = true;
            runtime->capturedProfile = true;
            runtime->captureActive = false;
            reset_adaptive_minimum(runtime, binCount);
        }
        return;
    }

    if (runtime->capturedProfile) return;

    for (uint32_t bin = 0; bin < binCount; ++bin) {
        runtime->adaptiveMinimum[bin] = fminf(runtime->adaptiveMinimum[bin], power[bin]);
    }
    runtime->adaptiveFramesInBlock += 1u;
    if (runtime->adaptiveFramesInBlock < runtime->adaptiveBlockTargetFrames) return;

    for (uint32_t bin = 0; bin < binCount; ++bin) {
        float candidate = fmaxf(runtime->adaptiveMinimum[bin], N60_DENOISER_EPSILON);
        if (runtime->adaptiveBlocksCompleted == 0u || runtime->noisePower[bin] <= 0.0f) {
            runtime->noisePower[bin] = candidate;
        } else {
            float previous = runtime->noisePower[bin];
            if (candidate > previous) candidate = fminf(candidate, previous * 1.2589254f); // at most +1 dB per block
            float coefficient = candidate < previous ? 0.55f : 0.90f;
            runtime->noisePower[bin] = coefficient * previous + (1.0f - coefficient) * candidate;
        }
    }
    runtime->adaptiveBlocksCompleted += 1u;
    if (runtime->adaptiveBlocksCompleted >= N60_DENOISER_ADAPTIVE_READY_BLOCKS) runtime->profileReady = true;
    reset_adaptive_minimum(runtime, binCount);
}

static void update_noise_telemetry(N60SpectralDenoiserRuntime *runtime, uint32_t binCount) {
    if (!runtime->profileReady) {
        runtime->estimatedNoiseDBFS = -120.0f;
        return;
    }
    double rmsPower = 0.0;
    for (uint32_t bin = 0; bin < binCount; ++bin) {
        double weight = (bin == 0u || bin + 1u == binCount) ? 1.0 : 0.5;
        rmsPower += weight * (double)runtime->noisePower[bin];
    }
    runtime->estimatedNoiseDBFS = (float)(10.0 * log10(fmax(rmsPower, 1.0e-20)));
}

static void process_spectral_frame(
    N60SpectralDenoiserRuntime *runtime,
    N60SpectralDenoiserSnapshot snapshot,
    double sampleRate,
    uint64_t frameStart
) {
    uint32_t size = snapshot.fftSize;
    uint32_t binCount = size / 2u + 1u;
    uint32_t nyquistBin = size / 2u;
    float windowSum = 0.0f;
    const float *window = window_for_size(runtime, size, &windowSum);
    uint32_t oldest = runtime->inputWrite;

    memset(runtime->fftLeft, 0, sizeof(N60DenoiserComplex) * size);
    memset(runtime->fftRight, 0, sizeof(N60DenoiserComplex) * size);
    for (uint32_t index = 0; index < size; ++index) {
        uint32_t sourceIndex = (oldest + index) % size;
        float w = window[index];
        runtime->fftLeft[index].real = runtime->inputLeft[sourceIndex] * w;
        runtime->fftRight[index].real = runtime->inputRight[sourceIndex] * w;
    }
    transform(runtime, runtime->fftLeft, size, false);
    transform(runtime, runtime->fftRight, size, false);

    for (uint32_t bin = 0; bin < binCount; ++bin) {
        float leftPower = bin_power(runtime->fftLeft[bin], bin, nyquistBin, windowSum);
        float rightPower = bin_power(runtime->fftRight[bin], bin, nyquistBin, windowSum);
        runtime->linkedPower[bin] = fmaxf(leftPower, rightPower);
    }

    update_profile(runtime, runtime->linkedPower, binCount, sampleRate, snapshot.hopSize);
    update_noise_telemetry(runtime, binCount);

    float thresholdPower = powf(10.0f, snapshot.thresholdDBFS / 10.0f);
    double weightedSuppression = 0.0;
    double weightedPower = 0.0;
    float maximumSuppression = 0.0f;

    for (uint32_t bin = 0; bin < binCount; ++bin) {
        float target = 1.0f;
        if (runtime->profileReady && snapshot.reductionAmount > 0.0f && !bin_is_protected(snapshot, sampleRate, bin)) {
            float noise = fminf(fmaxf(runtime->noisePower[bin], N60_DENOISER_EPSILON), thresholdPower);
            if (snapshot.dehissStrength > 0.0f) {
                double frequency = (double)bin * sampleRate / (double)size;
                double start = 3000.0;
                double nyquist = sampleRate * 0.5;
                float highWeight = nyquist > start
                    ? clampf((float)((frequency - start) / (nyquist - start)), 0.0f, 1.0f)
                    : 0.0f;
                noise *= 1.0f + 1.5f * snapshot.dehissStrength * highWeight;
            }
            float power = fmaxf(runtime->linkedPower[bin], N60_DENOISER_EPSILON);
            float posterior = power / fmaxf(noise, N60_DENOISER_EPSILON);
            float instantaneousPrior = fmaxf(posterior - 1.0f, 0.0f);
            float previousPrior = runtime->previousEnhancedPower[bin] / fmaxf(noise, N60_DENOISER_EPSILON);
            float prior = snapshot.decisionDirectedAlpha * previousPrior
                + (1.0f - snapshot.decisionDirectedAlpha) * instantaneousPrior;
            float wiener = prior / (1.0f + prior);
            float baseGain = fmaxf(wiener, snapshot.minimumGain);
            target = powf(baseGain, snapshot.reductionAmount);
        }
        runtime->targetGain[bin] = clampf(target, snapshot.minimumGain, 1.0f);
    }

    uint32_t radius = snapshot.spectralSmoothingRadius;
    for (uint32_t bin = 0; bin < binCount; ++bin) {
        float target = runtime->targetGain[bin];
        if (radius > 0u && !bin_is_protected(snapshot, sampleRate, bin)) {
            double sum = 0.0;
            double weightSum = 0.0;
            int start = (int)bin - (int)radius;
            int end = (int)bin + (int)radius;
            for (int neighbor = start; neighbor <= end; ++neighbor) {
                if (neighbor < 0 || neighbor >= (int)binCount) continue;
                int distance = neighbor > (int)bin ? neighbor - (int)bin : (int)bin - neighbor;
                double weight = (double)(radius + 1u - (uint32_t)distance);
                sum += (double)runtime->targetGain[neighbor] * weight;
                weightSum += weight;
            }
            if (weightSum > 0.0) target = (float)(sum / weightSum);
        }
        if (bin_is_protected(snapshot, sampleRate, bin)) target = 1.0f;

        float previous = runtime->smoothedGain[bin];
        float coefficient = target < previous ? snapshot.suppressionAttack : snapshot.suppressionRelease;
        float gain = target + coefficient * (previous - target);
        gain = clampf(gain, snapshot.minimumGain, 1.0f);
        runtime->smoothedGain[bin] = gain;
        runtime->previousEnhancedPower[bin] = runtime->linkedPower[bin] * gain * gain;

        runtime->fftLeft[bin].real *= gain;
        runtime->fftLeft[bin].imag *= gain;
        runtime->fftRight[bin].real *= gain;
        runtime->fftRight[bin].imag *= gain;
        if (bin > 0u && bin < nyquistBin) {
            uint32_t mirror = size - bin;
            runtime->fftLeft[mirror].real *= gain;
            runtime->fftLeft[mirror].imag *= gain;
            runtime->fftRight[mirror].real *= gain;
            runtime->fftRight[mirror].imag *= gain;
        }

        float suppressionDB = -20.0f * log10f(fmaxf(gain, N60_DENOISER_EPSILON));
        maximumSuppression = fmaxf(maximumSuppression, suppressionDB);
        double weight = (double)runtime->linkedPower[bin];
        weightedSuppression += (double)suppressionDB * weight;
        weightedPower += weight;
    }

    transform(runtime, runtime->fftLeft, size, true);
    transform(runtime, runtime->fftRight, size, true);
    for (uint32_t index = 0; index < size; ++index) {
        uint64_t absoluteTarget = frameStart + (uint64_t)snapshot.latencyFrames + (uint64_t)index;
        uint32_t ringIndex = (uint32_t)(absoluteTarget & (N60_DENOISER_OUTPUT_RING_SIZE - 1u));
        float w = window[index];
        runtime->outputLeft[ringIndex] += runtime->fftLeft[index].real * w;
        runtime->outputRight[ringIndex] += runtime->fftRight[index].real * w;
    }

    runtime->meanSuppressionDB = weightedPower > 1.0e-20 ? (float)(weightedSuppression / weightedPower) : 0.0f;
    runtime->maxSuppressionDB = maximumSuppression;
    runtime->spectralFramesProcessed += 1u;
}

void N60SpectralDenoiserProcessStereoFrame(
    N60SpectralDenoiserRuntime *runtime,
    N60SpectralDenoiserSnapshot snapshot,
    double sampleRate,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (outputLeft == NULL || outputRight == NULL) return;
    if (runtime == NULL || !N60SpectralDenoiserSnapshotIsValid(snapshot, sampleRate)) {
        *outputLeft = inputLeft;
        *outputRight = inputRight;
        return;
    }

    if (runtime->activeFFTSize != snapshot.fftSize) {
        clear_processing_state(runtime);
        runtime->activeFFTSize = snapshot.fftSize;
    }

    handle_profile_command(runtime, snapshot, sampleRate);

    uint32_t size = snapshot.fftSize;
    runtime->inputLeft[runtime->inputWrite] = inputLeft;
    runtime->inputRight[runtime->inputWrite] = inputRight;
    runtime->inputWrite = (runtime->inputWrite + 1u) % size;
    if (runtime->samplesAvailable < size) runtime->samplesAvailable += 1u;

    uint32_t outputIndex = (uint32_t)(runtime->sampleIndex & (N60_DENOISER_OUTPUT_RING_SIZE - 1u));
    float delayedLeft = runtime->outputLeft[outputIndex];
    float delayedRight = runtime->outputRight[outputIndex];
    runtime->outputLeft[outputIndex] = 0.0f;
    runtime->outputRight[outputIndex] = 0.0f;

    if (runtime->samplesAvailable == size) {
        if (runtime->samplesSinceFrame == 0u) {
            uint64_t frameStart = runtime->sampleIndex + 1u - (uint64_t)size;
            process_spectral_frame(runtime, snapshot, sampleRate, frameStart);
        }
        runtime->samplesSinceFrame += 1u;
        if (runtime->samplesSinceFrame >= snapshot.hopSize) runtime->samplesSinceFrame = 0u;
    }

    if (snapshot.enabled) {
        *outputLeft = delayedLeft;
        *outputRight = delayedRight;
    } else {
        *outputLeft = inputLeft;
        *outputRight = inputRight;
    }
    runtime->sampleIndex += 1u;
}

N60SpectralDenoiserTelemetry N60SpectralDenoiserRuntimeTelemetry(const N60SpectralDenoiserRuntime *runtime) {
    N60SpectralDenoiserTelemetry telemetry = {0};
    if (runtime == NULL) return telemetry;
    telemetry.profileReady = runtime->profileReady;
    telemetry.capturedProfile = runtime->capturedProfile;
    telemetry.captureActive = runtime->captureActive;
    telemetry.captureProgress = runtime->captureActive && runtime->captureTargetFrames > 0u
        ? clampf((float)runtime->captureFramesCollected / (float)runtime->captureTargetFrames, 0.0f, 1.0f)
        : (runtime->capturedProfile ? 1.0f : 0.0f);
    telemetry.estimatedNoiseDBFS = runtime->estimatedNoiseDBFS;
    telemetry.meanSuppressionDB = runtime->meanSuppressionDB;
    telemetry.maxSuppressionDB = runtime->maxSuppressionDB;
    telemetry.fftSize = runtime->activeFFTSize;
    telemetry.hopSize = runtime->activeFFTSize / 2u;
    telemetry.latencyFrames = runtime->activeFFTSize;
    telemetry.spectralFramesProcessed = runtime->spectralFramesProcessed;
    return telemetry;
}
