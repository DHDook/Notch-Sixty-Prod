#ifndef N60Biquad_h
#define N60Biquad_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    N60BiquadFilterTypePeaking = 0,
    N60BiquadFilterTypeLowShelf = 1,
    N60BiquadFilterTypeHighShelf = 2,
    N60BiquadFilterTypeLowPass = 3,
    N60BiquadFilterTypeHighPass = 4,
    N60BiquadFilterTypeNotch = 5,
} N60BiquadFilterType;

typedef struct {
    float b0;
    float b1;
    float b2;
    float a1;
    float a2;
} N60BiquadCoefficients;

typedef struct {
    float z1;
    float z2;
} N60BiquadState;

typedef struct {
    bool enabled;
    N60BiquadFilterType type;
    double frequencyHz;
    double gainDB;
    double q;
    N60BiquadCoefficients coefficients;
} N60BiquadBandSnapshot;

static inline N60BiquadCoefficients N60BiquadCoefficientsMakeIdentity(void) {
    N60BiquadCoefficients coefficients = {
        .b0 = 1.0f,
        .b1 = 0.0f,
        .b2 = 0.0f,
        .a1 = 0.0f,
        .a2 = 0.0f,
    };
    return coefficients;
}

static inline bool N60BiquadCoefficientsAreFinite(N60BiquadCoefficients coefficients) {
    return isfinite(coefficients.b0)
        && isfinite(coefficients.b1)
        && isfinite(coefficients.b2)
        && isfinite(coefficients.a1)
        && isfinite(coefficients.a2);
}

static inline N60BiquadCoefficients N60BiquadNormalize(
    double b0,
    double b1,
    double b2,
    double a0,
    double a1,
    double a2
) {
    if (!isfinite(a0) || fabs(a0) < 1.0e-20) {
        return N60BiquadCoefficientsMakeIdentity();
    }

    N60BiquadCoefficients coefficients = {
        .b0 = (float)(b0 / a0),
        .b1 = (float)(b1 / a0),
        .b2 = (float)(b2 / a0),
        .a1 = (float)(a1 / a0),
        .a2 = (float)(a2 / a0),
    };
    return coefficients;
}

// Control-plane coefficient design. Never call from the realtime render path.
static inline bool N60BiquadDesign(
    N60BiquadFilterType type,
    double sampleRate,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients * _Nonnull coefficients
) {
    if (coefficients == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz <= 0.0
        || frequencyHz >= sampleRate * 0.5
        || !isfinite(gainDB)
        || !isfinite(q) || q <= 0.0) {
        return false;
    }

    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double cosOmega = cos(omega);
    double sinOmega = sin(omega);
    double alpha = sinOmega / (2.0 * q);
    double b0 = 0.0;
    double b1 = 0.0;
    double b2 = 0.0;
    double a0 = 1.0;
    double a1 = 0.0;
    double a2 = 0.0;

    switch (type) {
    case N60BiquadFilterTypePeaking: {
        double A = pow(10.0, gainDB / 40.0);
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cosOmega;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cosOmega;
        a2 = 1.0 - alpha / A;
        break;
    }
    case N60BiquadFilterTypeLowShelf: {
        double A = pow(10.0, gainDB / 40.0);
        double beta = 2.0 * sqrt(A) * alpha;
        b0 = A * ((A + 1.0) - (A - 1.0) * cosOmega + beta);
        b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosOmega);
        b2 = A * ((A + 1.0) - (A - 1.0) * cosOmega - beta);
        a0 = (A + 1.0) + (A - 1.0) * cosOmega + beta;
        a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosOmega);
        a2 = (A + 1.0) + (A - 1.0) * cosOmega - beta;
        break;
    }
    case N60BiquadFilterTypeHighShelf: {
        double A = pow(10.0, gainDB / 40.0);
        double beta = 2.0 * sqrt(A) * alpha;
        b0 = A * ((A + 1.0) + (A - 1.0) * cosOmega + beta);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosOmega);
        b2 = A * ((A + 1.0) + (A - 1.0) * cosOmega - beta);
        a0 = (A + 1.0) - (A - 1.0) * cosOmega + beta;
        a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosOmega);
        a2 = (A + 1.0) - (A - 1.0) * cosOmega - beta;
        break;
    }
    case N60BiquadFilterTypeLowPass:
        b0 = (1.0 - cosOmega) * 0.5;
        b1 = 1.0 - cosOmega;
        b2 = (1.0 - cosOmega) * 0.5;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosOmega;
        a2 = 1.0 - alpha;
        break;
    case N60BiquadFilterTypeHighPass:
        b0 = (1.0 + cosOmega) * 0.5;
        b1 = -(1.0 + cosOmega);
        b2 = (1.0 + cosOmega) * 0.5;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosOmega;
        a2 = 1.0 - alpha;
        break;
    case N60BiquadFilterTypeNotch:
        b0 = 1.0;
        b1 = -2.0 * cosOmega;
        b2 = 1.0;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosOmega;
        a2 = 1.0 - alpha;
        break;
    default:
        return false;
    }

    N60BiquadCoefficients normalized = N60BiquadNormalize(b0, b1, b2, a0, a1, a2);
    if (!N60BiquadCoefficientsAreFinite(normalized)) {
        return false;
    }
    *coefficients = normalized;
    return true;
}

static inline bool N60BiquadBandSnapshotMake(
    N60BiquadFilterType type,
    double sampleRate,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled,
    N60BiquadBandSnapshot * _Nonnull band
) {
    if (band == NULL) {
        return false;
    }

    N60BiquadCoefficients coefficients = N60BiquadCoefficientsMakeIdentity();
    if (enabled && !N60BiquadDesign(type, sampleRate, frequencyHz, gainDB, q, &coefficients)) {
        return false;
    }

    band->enabled = enabled;
    band->type = type;
    band->frequencyHz = frequencyHz;
    band->gainDB = gainDB;
    band->q = q;
    band->coefficients = coefficients;
    return true;
}

// Realtime-safe transposed-direct-form-II state processing.
static inline float N60BiquadProcessSample(
    N60BiquadCoefficients coefficients,
    N60BiquadState * _Nonnull state,
    float input
) {
    float output = coefficients.b0 * input + state->z1;
    state->z1 = coefficients.b1 * input - coefficients.a1 * output + state->z2;
    state->z2 = coefficients.b2 * input - coefficients.a2 * output;
    return output;
}

#ifdef __cplusplus
}
#endif

#endif
