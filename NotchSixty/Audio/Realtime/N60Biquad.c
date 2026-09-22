#include "N60Biquad.h"

#include <math.h>
#include <stddef.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static bool finite_positive(double value) {
    return isfinite(value) && value > 0.0;
}

static bool coefficients_are_finite(N60BiquadCoefficients coefficients) {
    return isfinite(coefficients.b0)
        && isfinite(coefficients.b1)
        && isfinite(coefficients.b2)
        && isfinite(coefficients.a1)
        && isfinite(coefficients.a2);
}

static N60BiquadCoefficients normalize(
    double b0,
    double b1,
    double b2,
    double a0,
    double a1,
    double a2
) {
    N60BiquadCoefficients coefficients = {0};
    if (!isfinite(a0) || fabs(a0) < 1.0e-20) {
        return N60BiquadCoefficientsMakeIdentity();
    }

    coefficients.b0 = (float)(b0 / a0);
    coefficients.b1 = (float)(b1 / a0);
    coefficients.b2 = (float)(b2 / a0);
    coefficients.a1 = (float)(a1 / a0);
    coefficients.a2 = (float)(a2 / a0);
    return coefficients;
}

N60BiquadCoefficients N60BiquadCoefficientsMakeIdentity(void) {
    N60BiquadCoefficients coefficients = {
        .b0 = 1.0f,
        .b1 = 0.0f,
        .b2 = 0.0f,
        .a1 = 0.0f,
        .a2 = 0.0f,
    };
    return coefficients;
}

bool N60BiquadDesign(
    N60BiquadFilterType type,
    double sampleRate,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients *coefficients
) {
    if (coefficients == NULL
        || !finite_positive(sampleRate)
        || !finite_positive(frequencyHz)
        || !isfinite(gainDB)
        || !finite_positive(q)) {
        return false;
    }

    double nyquist = sampleRate * 0.5;
    if (!(frequencyHz < nyquist)) {
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
        double shelfAlpha = sinOmega / sqrt(2.0);
        double beta = 2.0 * sqrt(A) * shelfAlpha;
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
        double shelfAlpha = sinOmega / sqrt(2.0);
        double beta = 2.0 * sqrt(A) * shelfAlpha;
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

    N60BiquadCoefficients normalized = normalize(b0, b1, b2, a0, a1, a2);
    if (!coefficients_are_finite(normalized)) {
        return false;
    }

    *coefficients = normalized;
    return true;
}

bool N60BiquadBandSnapshotMake(
    N60BiquadFilterType type,
    double sampleRate,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled,
    N60BiquadBandSnapshot *band
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

float N60BiquadProcessSample(
    N60BiquadCoefficients coefficients,
    N60BiquadState *state,
    float input
) {
    float output = coefficients.b0 * input + state->z1;
    state->z1 = coefficients.b1 * input - coefficients.a1 * output + state->z2;
    state->z2 = coefficients.b2 * input - coefficients.a2 * output;
    return output;
}

double N60BiquadMagnitudeDB(
    N60BiquadCoefficients coefficients,
    double sampleRate,
    double frequencyHz
) {
    if (!finite_positive(sampleRate) || frequencyHz < 0.0 || frequencyHz > sampleRate * 0.5) {
        return NAN;
    }

    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double cos1 = cos(omega);
    double sin1 = sin(omega);
    double cos2 = cos(2.0 * omega);
    double sin2 = sin(2.0 * omega);

    double numeratorReal = coefficients.b0 + coefficients.b1 * cos1 + coefficients.b2 * cos2;
    double numeratorImag = -(coefficients.b1 * sin1 + coefficients.b2 * sin2);
    double denominatorReal = 1.0 + coefficients.a1 * cos1 + coefficients.a2 * cos2;
    double denominatorImag = -(coefficients.a1 * sin1 + coefficients.a2 * sin2);

    double numeratorPower = numeratorReal * numeratorReal + numeratorImag * numeratorImag;
    double denominatorPower = denominatorReal * denominatorReal + denominatorImag * denominatorImag;
    if (!(denominatorPower > 0.0)) {
        return INFINITY;
    }
    if (!(numeratorPower > 0.0)) {
        return -INFINITY;
    }

    return 10.0 * log10(numeratorPower / denominatorPower);
}
