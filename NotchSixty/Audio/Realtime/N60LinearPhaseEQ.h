#ifndef N60LinearPhaseEQ_h
#define N60LinearPhaseEQ_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "N60Biquad.h"
#include "N60Convolution.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_LINEAR_PHASE_MAX_BANDS 64u
#define N60_LINEAR_PHASE_TARGET_GROUP_DELAY_SECONDS (1.0 / 46.875)
#define N60_LINEAR_PHASE_MAX_TAPS 16385u
#define N60_LINEAR_PHASE_MIN_TAPS 1025u

typedef struct {
    bool enabled;
    N60BiquadFilterType type;
    double frequencyHz;
    double gainDB;
    double q;
} N60LinearPhaseEQBand;

typedef struct {
    uint32_t tapCount;
    uint32_t groupDelayFrames;
    uint32_t totalLatencyFrames;
    double groupDelayMilliseconds;
} N60LinearPhaseEQDesignInfo;

typedef struct {
    double real;
    double imag;
} N60LinearPhaseComplex;

static inline uint32_t N60LinearPhaseEQRecommendedTapCount(double sampleRate) {
    if (!isfinite(sampleRate) || sampleRate <= 0.0) return 0;
    double desiredDelay = sampleRate * N60_LINEAR_PHASE_TARGET_GROUP_DELAY_SECONDS;
    uint32_t delayFrames = (uint32_t)llround(desiredDelay);
    uint32_t minimumDelay = (N60_LINEAR_PHASE_MIN_TAPS - 1u) / 2u;
    uint32_t maximumDelay = (N60_LINEAR_PHASE_MAX_TAPS - 1u) / 2u;
    if (delayFrames < minimumDelay) delayFrames = minimumDelay;
    if (delayFrames > maximumDelay) delayFrames = maximumDelay;
    return delayFrames * 2u + 1u;
}

static inline uint32_t N60LinearPhaseEQNextPowerOfTwo(uint32_t value) {
    if (value == 0) return 0;
    uint32_t result = 1;
    while (result < value && result <= (UINT32_MAX >> 1u)) result <<= 1u;
    return result;
}

static inline N60LinearPhaseComplex N60LinearPhaseComplexMultiply(
    N60LinearPhaseComplex lhs,
    N60LinearPhaseComplex rhs
) {
    N60LinearPhaseComplex result = {
        lhs.real * rhs.real - lhs.imag * rhs.imag,
        lhs.real * rhs.imag + lhs.imag * rhs.real,
    };
    return result;
}

static inline bool N60LinearPhaseFFT(
    N60LinearPhaseComplex *values,
    uint32_t count,
    bool inverse
) {
    if (values == NULL || count < 2 || (count & (count - 1u)) != 0u) return false;

    uint32_t j = 0;
    for (uint32_t i = 1; i < count; ++i) {
        uint32_t bit = count >> 1u;
        while ((j & bit) != 0u) {
            j ^= bit;
            bit >>= 1u;
        }
        j ^= bit;
        if (i < j) {
            N60LinearPhaseComplex temporary = values[i];
            values[i] = values[j];
            values[j] = temporary;
        }
    }

    const double pi = 3.14159265358979323846264338327950288;
    for (uint32_t length = 2; length <= count; length <<= 1u) {
        double angle = (inverse ? 2.0 : -2.0) * pi / (double)length;
        N60LinearPhaseComplex step = {cos(angle), sin(angle)};
        uint32_t half = length >> 1u;
        for (uint32_t base = 0; base < count; base += length) {
            N60LinearPhaseComplex twiddle = {1.0, 0.0};
            for (uint32_t offset = 0; offset < half; ++offset) {
                N60LinearPhaseComplex even = values[base + offset];
                N60LinearPhaseComplex odd = N60LinearPhaseComplexMultiply(
                    values[base + offset + half],
                    twiddle
                );
                values[base + offset] = (N60LinearPhaseComplex){
                    even.real + odd.real,
                    even.imag + odd.imag,
                };
                values[base + offset + half] = (N60LinearPhaseComplex){
                    even.real - odd.real,
                    even.imag - odd.imag,
                };
                twiddle = N60LinearPhaseComplexMultiply(twiddle, step);
            }
        }
    }

    if (inverse) {
        double scale = 1.0 / (double)count;
        for (uint32_t index = 0; index < count; ++index) {
            values[index].real *= scale;
            values[index].imag *= scale;
        }
    }
    return true;
}

static inline double N60LinearPhaseBiquadMagnitude(
    N60BiquadCoefficients coefficients,
    double omega
) {
    double cos1 = cos(omega);
    double sin1 = sin(omega);
    double cos2 = cos(2.0 * omega);
    double sin2 = sin(2.0 * omega);

    double numeratorReal = (double)coefficients.b0
        + (double)coefficients.b1 * cos1
        + (double)coefficients.b2 * cos2;
    double numeratorImag = -(double)coefficients.b1 * sin1
        - (double)coefficients.b2 * sin2;
    double denominatorReal = 1.0
        + (double)coefficients.a1 * cos1
        + (double)coefficients.a2 * cos2;
    double denominatorImag = -(double)coefficients.a1 * sin1
        - (double)coefficients.a2 * sin2;

    double numeratorPower = numeratorReal * numeratorReal + numeratorImag * numeratorImag;
    double denominatorPower = denominatorReal * denominatorReal + denominatorImag * denominatorImag;
    if (!isfinite(numeratorPower) || !isfinite(denominatorPower) || denominatorPower <= 1.0e-30) return 1.0;
    double magnitude = sqrt(numeratorPower / denominatorPower);
    return isfinite(magnitude) ? magnitude : 1.0;
}

static inline bool N60LinearPhaseEQDesign(
    double sampleRate,
    const N60LinearPhaseEQBand *bands,
    uint32_t bandCount,
    float *outputTaps,
    uint32_t outputCapacity,
    N60LinearPhaseEQDesignInfo *designInfoOut
) {
    if (!isfinite(sampleRate)
        || sampleRate <= 0.0
        || bandCount > N60_LINEAR_PHASE_MAX_BANDS
        || (bandCount > 0 && bands == NULL)
        || outputTaps == NULL) {
        return false;
    }

    uint32_t tapCount = N60LinearPhaseEQRecommendedTapCount(sampleRate);
    if (tapCount == 0 || tapCount > outputCapacity || tapCount > N60_CONVOLUTION_MAX_TAPS) return false;

    N60BiquadBandSnapshot designedBands[N60_LINEAR_PHASE_MAX_BANDS];
    uint32_t designedCount = 0;
    for (uint32_t index = 0; index < bandCount; ++index) {
        if (!bands[index].enabled) continue;
        N60BiquadBandSnapshot snapshot = {0};
        if (!N60BiquadBandSnapshotMake(
                bands[index].type,
                sampleRate,
                bands[index].frequencyHz,
                bands[index].gainDB,
                bands[index].q,
                true,
                &snapshot)) {
            return false;
        }
        designedBands[designedCount++] = snapshot;
    }

    uint32_t fftSize = N60LinearPhaseEQNextPowerOfTwo(tapCount * 2u);
    if (fftSize == 0) return false;
    N60LinearPhaseComplex *spectrum = calloc(fftSize, sizeof(N60LinearPhaseComplex));
    if (spectrum == NULL) return false;

    const double pi = 3.14159265358979323846264338327950288;
    uint32_t nyquistBin = fftSize / 2u;
    for (uint32_t bin = 0; bin <= nyquistBin; ++bin) {
        double omega = 2.0 * pi * (double)bin / (double)fftSize;
        double magnitude = 1.0;
        for (uint32_t band = 0; band < designedCount; ++band) {
            magnitude *= N60LinearPhaseBiquadMagnitude(designedBands[band].coefficients, omega);
        }
        if (!isfinite(magnitude)) {
            free(spectrum);
            return false;
        }
        spectrum[bin].real = magnitude;
        if (bin > 0 && bin < nyquistBin) spectrum[fftSize - bin].real = magnitude;
    }

    if (!N60LinearPhaseFFT(spectrum, fftSize, true)) {
        free(spectrum);
        return false;
    }

    uint32_t groupDelay = (tapCount - 1u) / 2u;
    for (uint32_t index = 0; index < tapCount; ++index) {
        int64_t relative = (int64_t)index - (int64_t)groupDelay;
        uint32_t sourceIndex = relative >= 0
            ? (uint32_t)relative
            : (uint32_t)((int64_t)fftSize + relative);
        double window = 0.42
            - 0.5 * cos(2.0 * pi * (double)index / (double)(tapCount - 1u))
            + 0.08 * cos(4.0 * pi * (double)index / (double)(tapCount - 1u));
        double tap = spectrum[sourceIndex].real * window;
        if (!isfinite(tap)) {
            free(spectrum);
            return false;
        }
        outputTaps[index] = (float)tap;
    }
    free(spectrum);

    if (designInfoOut != NULL) {
        designInfoOut->tapCount = tapCount;
        designInfoOut->groupDelayFrames = groupDelay;
        designInfoOut->totalLatencyFrames = groupDelay + N60_CONVOLUTION_PARTITION_FRAMES;
        designInfoOut->groupDelayMilliseconds = (double)groupDelay / sampleRate * 1000.0;
    }
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
