#ifndef N60MixedPhase_h
#define N60MixedPhase_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>

#include "N60Biquad.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MIXED_PHASE_MAX_SECTIONS_PER_LANE 6u
#define N60_MIXED_PHASE_ANALYSIS_POINTS 96u

/// Control-plane result for the fixed Mixed Phase mode.
///
/// The correction cascade is all-pass only: magnitude remains unity and no
/// fixed/buffer latency is introduced. `fittedDelaySamples` is the best-fit
/// pure-delay slope of the resulting phase response, not graph latency.
typedef struct {
    uint32_t sectionCount;
    N60BiquadBandSnapshot sections[N60_MIXED_PHASE_MAX_SECTIONS_PER_LANE];
    double inputPhaseResidualRadiansRMS;
    double outputPhaseResidualRadiansRMS;
    double fittedDelaySamples;
} N60MixedPhaseDesignInfo;

typedef struct {
    double real;
    double imag;
} N60MixedComplex;

static inline N60MixedComplex N60MixedComplexMultiply(N60MixedComplex lhs, N60MixedComplex rhs) {
    N60MixedComplex value = {
        .real = lhs.real * rhs.real - lhs.imag * rhs.imag,
        .imag = lhs.real * rhs.imag + lhs.imag * rhs.real,
    };
    return value;
}

static inline N60MixedComplex N60MixedComplexDivide(N60MixedComplex numerator, N60MixedComplex denominator) {
    double norm = denominator.real * denominator.real + denominator.imag * denominator.imag;
    if (!isfinite(norm) || norm < 1.0e-30) {
        N60MixedComplex invalid = {.real = NAN, .imag = NAN};
        return invalid;
    }
    N60MixedComplex value = {
        .real = (numerator.real * denominator.real + numerator.imag * denominator.imag) / norm,
        .imag = (numerator.imag * denominator.real - numerator.real * denominator.imag) / norm,
    };
    return value;
}

static inline N60MixedComplex N60MixedPhaseSectionResponse(
    N60BiquadCoefficients coefficients,
    double omega
) {
    double c1 = cos(omega);
    double s1 = sin(omega);
    double c2 = cos(2.0 * omega);
    double s2 = sin(2.0 * omega);
    N60MixedComplex numerator = {
        .real = coefficients.b0 + coefficients.b1 * c1 + coefficients.b2 * c2,
        .imag = -coefficients.b1 * s1 - coefficients.b2 * s2,
    };
    N60MixedComplex denominator = {
        .real = 1.0 + coefficients.a1 * c1 + coefficients.a2 * c2,
        .imag = -coefficients.a1 * s1 - coefficients.a2 * s2,
    };
    return N60MixedComplexDivide(numerator, denominator);
}

static inline double N60MixedPhaseWrapDelta(double value) {
    while (value > M_PI) value -= 2.0 * M_PI;
    while (value < -M_PI) value += 2.0 * M_PI;
    return value;
}

static inline bool N60MixedPhaseAnalysisGrid(
    double sampleRate,
    double * _Nonnull omega,
    uint32_t count
) {
    if (omega == NULL || count < 2u || !isfinite(sampleRate) || sampleRate <= 0.0) return false;
    double minimumHz = 30.0;
    double maximumHz = fmin(20000.0, sampleRate * 0.45);
    if (!(maximumHz > minimumHz)) return false;
    double ratio = pow(maximumHz / minimumHz, 1.0 / (double)(count - 1u));
    double frequency = minimumHz;
    for (uint32_t index = 0; index < count; ++index) {
        omega[index] = 2.0 * M_PI * frequency / sampleRate;
        frequency *= ratio;
    }
    return true;
}

static inline bool N60MixedPhaseSourceAnalysis(
    const N60BiquadBandSnapshot * _Nullable sourceSections,
    uint32_t sourceCount,
    const double * _Nonnull omega,
    uint32_t pointCount,
    double * _Nonnull unwrappedPhase,
    double * _Nonnull weights
) {
    if (omega == NULL || unwrappedPhase == NULL || weights == NULL) return false;
    double previousRaw = 0.0;
    double phaseOffset = 0.0;
    for (uint32_t point = 0; point < pointCount; ++point) {
        N60MixedComplex response = {.real = 1.0, .imag = 0.0};
        for (uint32_t section = 0; section < sourceCount; ++section) {
            if (sourceSections == NULL || !sourceSections[section].enabled) continue;
            N60MixedComplex sectionResponse = N60MixedPhaseSectionResponse(
                sourceSections[section].coefficients,
                omega[point]
            );
            response = N60MixedComplexMultiply(response, sectionResponse);
        }
        if (!isfinite(response.real) || !isfinite(response.imag)) return false;
        double raw = atan2(response.imag, response.real);
        if (point > 0u) {
            double delta = raw - previousRaw;
            if (delta > M_PI) phaseOffset -= 2.0 * M_PI;
            else if (delta < -M_PI) phaseOffset += 2.0 * M_PI;
        }
        previousRaw = raw;
        unwrappedPhase[point] = raw + phaseOffset;
        double magnitude = hypot(response.real, response.imag);
        if (!isfinite(magnitude)) return false;
        if (magnitude < 0.05) magnitude = 0.05;
        if (magnitude > 1.0) magnitude = 1.0;
        weights[point] = magnitude;
    }
    return true;
}

static inline bool N60MixedPhaseAllPassPhase(
    N60BiquadBandSnapshot section,
    const double * _Nonnull omega,
    uint32_t pointCount,
    double * _Nonnull unwrappedPhase
) {
    if (omega == NULL || unwrappedPhase == NULL || !section.enabled
        || section.type != N60BiquadFilterTypeAllPass) return false;
    double previousRaw = 0.0;
    double phaseOffset = 0.0;
    for (uint32_t point = 0; point < pointCount; ++point) {
        N60MixedComplex response = N60MixedPhaseSectionResponse(section.coefficients, omega[point]);
        if (!isfinite(response.real) || !isfinite(response.imag)) return false;
        double raw = atan2(response.imag, response.real);
        if (point > 0u) {
            double delta = raw - previousRaw;
            if (delta > M_PI) phaseOffset -= 2.0 * M_PI;
            else if (delta < -M_PI) phaseOffset += 2.0 * M_PI;
        }
        previousRaw = raw;
        unwrappedPhase[point] = raw + phaseOffset;
    }
    return true;
}

/// Returns nonlinear phase error after removing the best-fit constant phase and
/// pure-delay slope. This is the independently authored Mixed Phase objective.
static inline double N60MixedPhaseResidualRMS(
    const double * _Nonnull omega,
    const double * _Nonnull phase,
    const double * _Nonnull weights,
    uint32_t count,
    double * _Nullable fittedDelaySamples
) {
    if (omega == NULL || phase == NULL || weights == NULL || count < 2u) return INFINITY;
    double s = 0.0;
    double sx = 0.0;
    double sy = 0.0;
    double sxx = 0.0;
    double sxy = 0.0;
    for (uint32_t index = 0; index < count; ++index) {
        double w = weights[index];
        double x = omega[index];
        double y = phase[index];
        if (!isfinite(w) || !isfinite(x) || !isfinite(y) || w <= 0.0) return INFINITY;
        s += w;
        sx += w * x;
        sy += w * y;
        sxx += w * x * x;
        sxy += w * x * y;
    }
    double denominator = s * sxx - sx * sx;
    if (!isfinite(denominator) || fabs(denominator) < 1.0e-20) return INFINITY;
    double slope = (s * sxy - sx * sy) / denominator;
    double intercept = (sy - slope * sx) / s;
    double squared = 0.0;
    for (uint32_t index = 0; index < count; ++index) {
        double residual = phase[index] - (intercept + slope * omega[index]);
        squared += weights[index] * residual * residual;
    }
    if (fittedDelaySamples != NULL) *fittedDelaySamples = -slope;
    return sqrt(squared / s);
}

static inline N60BiquadBandSnapshot N60MixedPhaseDesignSectionAt(
    const N60MixedPhaseDesignInfo * _Nonnull info,
    uint32_t index
) {
    if (info == NULL || index >= info->sectionCount || index >= N60_MIXED_PHASE_MAX_SECTIONS_PER_LANE) {
        N60BiquadBandSnapshot empty = {0};
        return empty;
    }
    return info->sections[index];
}

/// Designs a small all-pass cascade that reduces the active biquad chain's
/// nonlinear phase residual. This function is control-plane only.
static inline bool N60MixedPhaseDesign(
    double sampleRate,
    const N60BiquadBandSnapshot * _Nullable sourceSections,
    uint32_t sourceCount,
    N60MixedPhaseDesignInfo * _Nonnull info
) {
    if (info == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || (sourceCount > 0u && sourceSections == NULL)) return false;

    N60MixedPhaseDesignInfo result = {0};
    if (sourceCount == 0u) {
        *info = result;
        return true;
    }

    double omega[N60_MIXED_PHASE_ANALYSIS_POINTS] = {0};
    double sourcePhase[N60_MIXED_PHASE_ANALYSIS_POINTS] = {0};
    double correctionPhase[N60_MIXED_PHASE_ANALYSIS_POINTS] = {0};
    double weights[N60_MIXED_PHASE_ANALYSIS_POINTS] = {0};
    if (!N60MixedPhaseAnalysisGrid(sampleRate, omega, N60_MIXED_PHASE_ANALYSIS_POINTS)
        || !N60MixedPhaseSourceAnalysis(
            sourceSections,
            sourceCount,
            omega,
            N60_MIXED_PHASE_ANALYSIS_POINTS,
            sourcePhase,
            weights)) {
        return false;
    }

    result.inputPhaseResidualRadiansRMS = N60MixedPhaseResidualRMS(
        omega, sourcePhase, weights, N60_MIXED_PHASE_ANALYSIS_POINTS, NULL
    );
    if (!isfinite(result.inputPhaseResidualRadiansRMS)) return false;
    if (result.inputPhaseResidualRadiansRMS < 1.0e-7) {
        result.outputPhaseResidualRadiansRMS = result.inputPhaseResidualRadiansRMS;
        *info = result;
        return true;
    }

    static const double qCandidates[] = {
        0.5, 0.7071067811865476, 1.0, 1.4, 2.0, 3.0, 5.0, 8.0,
    };
    const uint32_t frequencyCandidateCount = 36u;
    double minimumHz = 30.0;
    double maximumHz = fmin(20000.0, sampleRate * 0.45);
    double frequencyRatio = pow(maximumHz / minimumHz, 1.0 / (double)(frequencyCandidateCount - 1u));

    double currentPhase[N60_MIXED_PHASE_ANALYSIS_POINTS] = {0};
    for (uint32_t point = 0; point < N60_MIXED_PHASE_ANALYSIS_POINTS; ++point) {
        currentPhase[point] = sourcePhase[point];
    }
    double currentResidual = result.inputPhaseResidualRadiansRMS;

    for (uint32_t slot = 0; slot < N60_MIXED_PHASE_MAX_SECTIONS_PER_LANE; ++slot) {
        bool found = false;
        double bestResidual = currentResidual;
        N60BiquadBandSnapshot bestSection = {0};
        double bestCandidatePhase[N60_MIXED_PHASE_ANALYSIS_POINTS] = {0};

        double frequencyHz = minimumHz;
        for (uint32_t frequencyIndex = 0; frequencyIndex < frequencyCandidateCount; ++frequencyIndex) {
            for (uint32_t qIndex = 0; qIndex < (uint32_t)(sizeof(qCandidates) / sizeof(qCandidates[0])); ++qIndex) {
                N60BiquadBandSnapshot candidate = {0};
                if (!N60BiquadBandSnapshotMake(
                        N60BiquadFilterTypeAllPass,
                        sampleRate,
                        frequencyHz,
                        0.0,
                        qCandidates[qIndex],
                        true,
                        &candidate)) {
                    return false;
                }
                double candidatePhase[N60_MIXED_PHASE_ANALYSIS_POINTS] = {0};
                if (!N60MixedPhaseAllPassPhase(
                        candidate,
                        omega,
                        N60_MIXED_PHASE_ANALYSIS_POINTS,
                        candidatePhase)) {
                    return false;
                }
                double combinedPhase[N60_MIXED_PHASE_ANALYSIS_POINTS] = {0};
                for (uint32_t point = 0; point < N60_MIXED_PHASE_ANALYSIS_POINTS; ++point) {
                    combinedPhase[point] = currentPhase[point] + candidatePhase[point];
                }
                double residual = N60MixedPhaseResidualRMS(
                    omega,
                    combinedPhase,
                    weights,
                    N60_MIXED_PHASE_ANALYSIS_POINTS,
                    NULL
                );
                if (isfinite(residual) && residual < bestResidual) {
                    found = true;
                    bestResidual = residual;
                    bestSection = candidate;
                    for (uint32_t point = 0; point < N60_MIXED_PHASE_ANALYSIS_POINTS; ++point) {
                        bestCandidatePhase[point] = candidatePhase[point];
                    }
                }
            }
            frequencyHz *= frequencyRatio;
        }

        // Avoid spending correction sections on numerically insignificant wins.
        if (!found || bestResidual >= currentResidual * 0.995) break;
        result.sections[result.sectionCount++] = bestSection;
        for (uint32_t point = 0; point < N60_MIXED_PHASE_ANALYSIS_POINTS; ++point) {
            correctionPhase[point] += bestCandidatePhase[point];
            currentPhase[point] += bestCandidatePhase[point];
        }
        currentResidual = bestResidual;
    }

    result.outputPhaseResidualRadiansRMS = N60MixedPhaseResidualRMS(
        omega,
        currentPhase,
        weights,
        N60_MIXED_PHASE_ANALYSIS_POINTS,
        &result.fittedDelaySamples
    );
    if (!isfinite(result.outputPhaseResidualRadiansRMS) || !isfinite(result.fittedDelaySamples)) return false;
    *info = result;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif /* N60MixedPhase_h */
