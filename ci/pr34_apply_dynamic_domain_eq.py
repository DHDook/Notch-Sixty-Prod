from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise SystemExit(f"{path}: expected one replacement anchor, found {text.count(old)}")
    path.write_text(text.replace(old, new, 1))


def replace_between(path: Path, start: str, end: str, replacement: str) -> None:
    text = path.read_text()
    if replacement in text:
        return
    a = text.find(start)
    b = text.find(end, a + len(start))
    if a < 0 or b < 0:
        raise SystemExit(f"{path}: replacement range not found")
    path.write_text(text[:a] + replacement + text[b:])


DYNAMIC_H = r'''#ifndef N60DynamicEQ_h
#define N60DynamicEQ_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_DYNAMIC_EQ_MAX_BANDS 64u

typedef enum {
    N60DynamicEQDirectionCutOnly = 0,
    N60DynamicEQDirectionBoostOnly = 1,
    N60DynamicEQDirectionBoth = 2,
} N60DynamicEQDirection;

typedef enum {
    N60DynamicEQDetectorPeak = 0,
    N60DynamicEQDetectorRMS = 1,
} N60DynamicEQDetectorMode;

typedef enum {
    N60DynamicEQDomainLinkedStereo = 0,
    N60DynamicEQDomainDualMono = 1,
    N60DynamicEQDomainMidSide = 2,
} N60DynamicEQDomain;

typedef enum {
    N60DynamicEQLanePrimary = 0,
    N60DynamicEQLaneSecondary = 1,
} N60DynamicEQLane;

typedef enum {
    N60DynamicEQShapePeak = 0,
    N60DynamicEQShapeLowShelf = 1,
    N60DynamicEQShapeHighShelf = 2,
    N60DynamicEQShapeNotch = 3,
    N60DynamicEQShapeBandPass = 4,
    N60DynamicEQShapeTilt = 5,
} N60DynamicEQShape;

typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
} N60DynamicEQBiquadCoefficients;

typedef struct {
    bool enabled;
    N60DynamicEQShape shape;
    double frequencyHz;
    float q;
    float staticGainDB;
    float thresholdDB;
    float ratio;
    float rangeDB;
    float attackCoefficient;
    float releaseCoefficient;
    N60DynamicEQDirection direction;
    float boostThresholdDB;
    float boostRatio;
    float maxBoostDB;
    N60DynamicEQDetectorMode detectorMode;
    float rmsCoefficient;
    N60DynamicEQBiquadCoefficients analysisBandPass;
    N60DynamicEQBiquadCoefficients basisPrimary;
    N60DynamicEQBiquadCoefficients basisSecondary;
} N60DynamicEQBandSnapshot;

typedef struct {
    bool enabled;
    N60DynamicEQDomain domain;
    double sampleRate;
    uint32_t bandCount;
    uint32_t secondaryBandCount;
    float bypassTransitionCoefficient;
    N60DynamicEQBandSnapshot bands[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBandSnapshot secondaryBands[N60_DYNAMIC_EQ_MAX_BANDS];
} N60DynamicEQSnapshot;

typedef struct {
    double z1;
    double z2;
} N60DynamicEQBiquadState;

typedef struct {
    N60DynamicEQBiquadState analysisLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState analysisRight[N60_DYNAMIC_EQ_MAX_BANDS];
    float rmsPower[N60_DYNAMIC_EQ_MAX_BANDS];
    float dynamicGainDB[N60_DYNAMIC_EQ_MAX_BANDS];
    float staticGainDB[N60_DYNAMIC_EQ_MAX_BANDS];
    float wetMix[N60_DYNAMIC_EQ_MAX_BANDS];
    float detectorLevelDBFS[N60_DYNAMIC_EQ_MAX_BANDS];

    N60DynamicEQBiquadState processPrimaryLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState processPrimaryRight[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState processSecondaryLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState processSecondaryRight[N60_DYNAMIC_EQ_MAX_BANDS];

    N60DynamicEQBiquadState secondaryAnalysisLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryAnalysisRight[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryProcessPrimaryLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryProcessPrimaryRight[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryProcessSecondaryLeft[N60_DYNAMIC_EQ_MAX_BANDS];
    N60DynamicEQBiquadState secondaryProcessSecondaryRight[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryRmsPower[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryDynamicGainDB[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryStaticGainDB[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryWetMix[N60_DYNAMIC_EQ_MAX_BANDS];
    float secondaryDetectorLevelDBFS[N60_DYNAMIC_EQ_MAX_BANDS];

    float maxAbsDynamicGainDB;
    uint32_t activeBandCount;
    N60DynamicEQDomain currentDomain;
    bool domainInitialized;
} N60DynamicEQRuntime;

typedef struct {
    uint32_t activeBandCount;
    float maxAbsDynamicGainDB;
} N60DynamicEQTelemetry;

N60DynamicEQSnapshot N60DynamicEQSnapshotMakeBypassed(double sampleRate);
bool N60DynamicEQSnapshotSetEnabled(N60DynamicEQSnapshot *snapshot, bool enabled);
bool N60DynamicEQSnapshotSetDomain(N60DynamicEQSnapshot *snapshot, N60DynamicEQDomain domain);
bool N60DynamicEQSnapshotSetBand(
    N60DynamicEQSnapshot *snapshot,
    double sampleRate,
    uint32_t index,
    bool enabled,
    double frequencyHz,
    float q,
    float staticGainDB,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float attackMs,
    float releaseMs,
    N60DynamicEQDirection direction,
    float boostThresholdDB,
    float boostRatio,
    float maxBoostDB,
    N60DynamicEQDetectorMode detectorMode,
    float rmsWindowMs
);
bool N60DynamicEQSnapshotSetBandForLane(
    N60DynamicEQSnapshot *snapshot,
    double sampleRate,
    N60DynamicEQLane lane,
    uint32_t index,
    bool enabled,
    N60DynamicEQShape shape,
    double frequencyHz,
    float q,
    float staticGainDB,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float attackMs,
    float releaseMs,
    N60DynamicEQDirection direction,
    float boostThresholdDB,
    float boostRatio,
    float maxBoostDB,
    N60DynamicEQDetectorMode detectorMode,
    float rmsWindowMs
);
bool N60DynamicEQSnapshotIsValid(N60DynamicEQSnapshot snapshot);
void N60DynamicEQRuntimeReset(N60DynamicEQRuntime *runtime);
void N60DynamicEQProcessStereoFrame(
    N60DynamicEQRuntime *runtime,
    N60DynamicEQSnapshot snapshot,
    float *left,
    float *right
);
N60DynamicEQTelemetry N60DynamicEQRuntimeTelemetry(const N60DynamicEQRuntime *runtime);

#ifdef __cplusplus
}
#endif

#endif
'''

DYNAMIC_C = r'''#include "N60DynamicEQ.h"

#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define N60_DYNAMIC_EQ_EPSILON 1.0e-20f
#define N60_DYNAMIC_EQ_TRANSITION_MS 5.0f

static float clampf_local(float value, float lower, float upper) {
    return fminf(upper, fmaxf(lower, value));
}

static float time_pole(double sampleRate, float milliseconds) {
    if (!isfinite(sampleRate) || sampleRate <= 0.0 || !isfinite(milliseconds) || milliseconds <= 0.0f) return 0.0f;
    return (float)exp(-1.0 / (sampleRate * ((double)milliseconds / 1000.0)));
}

static float smooth_pole(float current, float target, float pole) {
    return target + pole * (current - target);
}

static float linear_to_db(float value) {
    return 20.0f * log10f(fmaxf(fabsf(value), N60_DYNAMIC_EQ_EPSILON));
}

static float db_to_linear(float valueDB) {
    return powf(10.0f, valueDB / 20.0f);
}

static bool direction_is_valid(N60DynamicEQDirection direction) {
    return direction == N60DynamicEQDirectionCutOnly
        || direction == N60DynamicEQDirectionBoostOnly
        || direction == N60DynamicEQDirectionBoth;
}

static bool detector_is_valid(N60DynamicEQDetectorMode detector) {
    return detector == N60DynamicEQDetectorPeak || detector == N60DynamicEQDetectorRMS;
}

static bool domain_is_valid(N60DynamicEQDomain domain) {
    return domain == N60DynamicEQDomainLinkedStereo
        || domain == N60DynamicEQDomainDualMono
        || domain == N60DynamicEQDomainMidSide;
}

static bool lane_is_valid(N60DynamicEQLane lane) {
    return lane == N60DynamicEQLanePrimary || lane == N60DynamicEQLaneSecondary;
}

static bool shape_is_valid(N60DynamicEQShape shape) {
    return shape == N60DynamicEQShapePeak
        || shape == N60DynamicEQShapeLowShelf
        || shape == N60DynamicEQShapeHighShelf
        || shape == N60DynamicEQShapeNotch
        || shape == N60DynamicEQShapeBandPass
        || shape == N60DynamicEQShapeTilt;
}

static N60DynamicEQBiquadCoefficients identity_coefficients(void) {
    N60DynamicEQBiquadCoefficients result = {0};
    result.b0 = 1.0;
    return result;
}

static bool coefficients_are_finite(N60DynamicEQBiquadCoefficients c) {
    return isfinite(c.b0) && isfinite(c.b1) && isfinite(c.b2)
        && isfinite(c.a1) && isfinite(c.a2);
}

// Public RBJ-style detector/basis sections are designed on the control plane.
// The audio thread only runs fixed biquads and smoothed scalar gains.
static bool design_filter(
    N60DynamicEQShape shape,
    double sampleRate,
    double frequencyHz,
    double q,
    N60DynamicEQBiquadCoefficients *analysis,
    N60DynamicEQBiquadCoefficients *primary,
    N60DynamicEQBiquadCoefficients *secondary
) {
    if (analysis == NULL || primary == NULL || secondary == NULL
        || !shape_is_valid(shape)
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz < 20.0 || frequencyHz >= sampleRate * 0.5
        || !isfinite(q) || q < 0.4 || q > 8.0) return false;

    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double sinOmega = sin(omega);
    double cosOmega = cos(omega);
    double alpha = sinOmega / (2.0 * q);
    double a0 = 1.0 + alpha;
    if (!isfinite(a0) || fabs(a0) < 1.0e-20) return false;

    N60DynamicEQBiquadCoefficients bandPass = {
        .b0 = alpha / a0,
        .b1 = 0.0,
        .b2 = -alpha / a0,
        .a1 = (-2.0 * cosOmega) / a0,
        .a2 = (1.0 - alpha) / a0,
    };
    N60DynamicEQBiquadCoefficients lowPass = {
        .b0 = ((1.0 - cosOmega) * 0.5) / a0,
        .b1 = (1.0 - cosOmega) / a0,
        .b2 = ((1.0 - cosOmega) * 0.5) / a0,
        .a1 = (-2.0 * cosOmega) / a0,
        .a2 = (1.0 - alpha) / a0,
    };
    N60DynamicEQBiquadCoefficients highPass = {
        .b0 = ((1.0 + cosOmega) * 0.5) / a0,
        .b1 = -(1.0 + cosOmega) / a0,
        .b2 = ((1.0 + cosOmega) * 0.5) / a0,
        .a1 = (-2.0 * cosOmega) / a0,
        .a2 = (1.0 - alpha) / a0,
    };
    if (!coefficients_are_finite(bandPass)
        || !coefficients_are_finite(lowPass)
        || !coefficients_are_finite(highPass)) return false;

    *secondary = identity_coefficients();
    switch (shape) {
    case N60DynamicEQShapeLowShelf:
        *analysis = lowPass;
        *primary = lowPass;
        break;
    case N60DynamicEQShapeHighShelf:
        *analysis = highPass;
        *primary = highPass;
        break;
    case N60DynamicEQShapeTilt:
        *analysis = bandPass;
        *primary = lowPass;
        *secondary = highPass;
        break;
    case N60DynamicEQShapePeak:
    case N60DynamicEQShapeNotch:
    case N60DynamicEQShapeBandPass:
    default:
        *analysis = bandPass;
        *primary = bandPass;
        break;
    }
    return true;
}

static float process_biquad(
    N60DynamicEQBiquadCoefficients coefficients,
    N60DynamicEQBiquadState *state,
    float input
) {
    double output = coefficients.b0 * (double)input + state->z1;
    double nextZ1 = coefficients.b1 * (double)input - coefficients.a1 * output + state->z2;
    double nextZ2 = coefficients.b2 * (double)input - coefficients.a2 * output;
    if (!isfinite(output) || !isfinite(nextZ1) || !isfinite(nextZ2)) {
        state->z1 = 0.0;
        state->z2 = 0.0;
        return 0.0f;
    }
    state->z1 = nextZ1;
    state->z2 = nextZ2;
    return (float)output;
}

static float target_dynamic_gain_db(float detectorDB, N60DynamicEQBandSnapshot band) {
    float cutDB = 0.0f;
    float boostDB = 0.0f;

    if ((band.direction == N60DynamicEQDirectionCutOnly || band.direction == N60DynamicEQDirectionBoth)
        && detectorDB > band.thresholdDB && band.ratio > 1.0f) {
        float overDB = detectorDB - band.thresholdDB;
        cutDB = -overDB * (1.0f - (1.0f / band.ratio));
        cutDB = fmaxf(cutDB, band.rangeDB);
    }

    if ((band.direction == N60DynamicEQDirectionBoostOnly || band.direction == N60DynamicEQDirectionBoth)
        && detectorDB < band.boostThresholdDB && band.boostRatio > 1.0f) {
        float underDB = band.boostThresholdDB - detectorDB;
        boostDB = underDB * (1.0f - (1.0f / band.boostRatio));
        boostDB = fminf(boostDB, band.maxBoostDB);
    }

    return cutDB + boostDB;
}

static float apply_shape(
    N60DynamicEQBandSnapshot band,
    N60DynamicEQBiquadState *primaryState,
    N60DynamicEQBiquadState *secondaryState,
    float input,
    float totalGainDB,
    float wetMix
) {
    float primary = process_biquad(band.basisPrimary, primaryState, input);
    if (band.shape == N60DynamicEQShapeTilt) {
        float secondary = process_biquad(band.basisSecondary, secondaryState, input);
        float half = 0.5f * totalGainDB;
        float lowScale = (db_to_linear(-half) - 1.0f) * wetMix;
        float highScale = (db_to_linear(half) - 1.0f) * wetMix;
        return input + lowScale * primary + highScale * secondary;
    }
    float scale = (db_to_linear(totalGainDB) - 1.0f) * wetMix;
    return input + scale * primary;
}

N60DynamicEQSnapshot N60DynamicEQSnapshotMakeBypassed(double sampleRate) {
    N60DynamicEQSnapshot snapshot = {0};
    snapshot.enabled = false;
    snapshot.domain = N60DynamicEQDomainLinkedStereo;
    snapshot.sampleRate = sampleRate;
    snapshot.bandCount = 0;
    snapshot.secondaryBandCount = 0;
    snapshot.bypassTransitionCoefficient = time_pole(sampleRate, N60_DYNAMIC_EQ_TRANSITION_MS);
    for (uint32_t index = 0; index < N60_DYNAMIC_EQ_MAX_BANDS; ++index) {
        snapshot.bands[index].analysisBandPass = identity_coefficients();
        snapshot.bands[index].basisPrimary = identity_coefficients();
        snapshot.bands[index].basisSecondary = identity_coefficients();
        snapshot.secondaryBands[index].analysisBandPass = identity_coefficients();
        snapshot.secondaryBands[index].basisPrimary = identity_coefficients();
        snapshot.secondaryBands[index].basisSecondary = identity_coefficients();
    }
    return snapshot;
}

bool N60DynamicEQSnapshotSetEnabled(N60DynamicEQSnapshot *snapshot, bool enabled) {
    if (snapshot == NULL) return false;
    snapshot->enabled = enabled;
    return true;
}

bool N60DynamicEQSnapshotSetDomain(N60DynamicEQSnapshot *snapshot, N60DynamicEQDomain domain) {
    if (snapshot == NULL || !domain_is_valid(domain)) return false;
    snapshot->domain = domain;
    return true;
}

bool N60DynamicEQSnapshotSetBandForLane(
    N60DynamicEQSnapshot *snapshot,
    double sampleRate,
    N60DynamicEQLane lane,
    uint32_t index,
    bool enabled,
    N60DynamicEQShape shape,
    double frequencyHz,
    float q,
    float staticGainDB,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float attackMs,
    float releaseMs,
    N60DynamicEQDirection direction,
    float boostThresholdDB,
    float boostRatio,
    float maxBoostDB,
    N60DynamicEQDetectorMode detectorMode,
    float rmsWindowMs
) {
    if (snapshot == NULL || !lane_is_valid(lane) || index >= N60_DYNAMIC_EQ_MAX_BANDS
        || !shape_is_valid(shape)
        || !isfinite(sampleRate) || sampleRate <= 0.0 || sampleRate > 384000.0
        || !isfinite(frequencyHz) || frequencyHz < 20.0 || frequencyHz > 20000.0 || frequencyHz >= sampleRate * 0.5
        || !isfinite(q) || q < 0.4f || q > 8.0f
        || !isfinite(staticGainDB) || staticGainDB < -18.0f || staticGainDB > 6.0f
        || !isfinite(thresholdDB) || thresholdDB < -60.0f || thresholdDB > 0.0f
        || !isfinite(ratio) || ratio < 1.0f || ratio > 10.0f
        || !isfinite(rangeDB) || rangeDB < -24.0f || rangeDB > 0.0f
        || !isfinite(attackMs) || attackMs < 1.0f || attackMs > 100.0f
        || !isfinite(releaseMs) || releaseMs < 10.0f || releaseMs > 1000.0f
        || !direction_is_valid(direction)
        || (shape == N60DynamicEQShapeNotch && direction != N60DynamicEQDirectionCutOnly)
        || !isfinite(boostThresholdDB) || boostThresholdDB < -60.0f || boostThresholdDB > 0.0f
        || !isfinite(boostRatio) || boostRatio < 1.0f || boostRatio > 10.0f
        || !isfinite(maxBoostDB) || maxBoostDB < 0.0f || maxBoostDB > 12.0f
        || !detector_is_valid(detectorMode)
        || !isfinite(rmsWindowMs) || rmsWindowMs < 5.0f || rmsWindowMs > 200.0f) return false;

    N60DynamicEQBandSnapshot configured = {0};
    configured.enabled = enabled;
    configured.shape = shape;
    configured.frequencyHz = frequencyHz;
    configured.q = q;
    configured.staticGainDB = staticGainDB;
    configured.thresholdDB = thresholdDB;
    configured.ratio = ratio;
    configured.rangeDB = rangeDB;
    configured.attackCoefficient = time_pole(sampleRate, attackMs);
    configured.releaseCoefficient = time_pole(sampleRate, releaseMs);
    configured.direction = direction;
    configured.boostThresholdDB = boostThresholdDB;
    configured.boostRatio = boostRatio;
    configured.maxBoostDB = maxBoostDB;
    configured.detectorMode = detectorMode;
    configured.rmsCoefficient = time_pole(sampleRate, rmsWindowMs);
    if (!design_filter(
            shape, sampleRate, frequencyHz, q,
            &configured.analysisBandPass,
            &configured.basisPrimary,
            &configured.basisSecondary)) return false;

    snapshot->sampleRate = sampleRate;
    if (lane == N60DynamicEQLaneSecondary) {
        snapshot->secondaryBands[index] = configured;
        if (snapshot->secondaryBandCount < index + 1u) snapshot->secondaryBandCount = index + 1u;
    } else {
        snapshot->bands[index] = configured;
        if (snapshot->bandCount < index + 1u) snapshot->bandCount = index + 1u;
    }
    snapshot->bypassTransitionCoefficient = time_pole(sampleRate, N60_DYNAMIC_EQ_TRANSITION_MS);
    return true;
}

bool N60DynamicEQSnapshotSetBand(
    N60DynamicEQSnapshot *snapshot,
    double sampleRate,
    uint32_t index,
    bool enabled,
    double frequencyHz,
    float q,
    float staticGainDB,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float attackMs,
    float releaseMs,
    N60DynamicEQDirection direction,
    float boostThresholdDB,
    float boostRatio,
    float maxBoostDB,
    N60DynamicEQDetectorMode detectorMode,
    float rmsWindowMs
) {
    if (snapshot == NULL) return false;
    snapshot->domain = N60DynamicEQDomainLinkedStereo;
    return N60DynamicEQSnapshotSetBandForLane(
        snapshot, sampleRate, N60DynamicEQLanePrimary, index, enabled,
        N60DynamicEQShapePeak, frequencyHz, q, staticGainDB,
        thresholdDB, ratio, rangeDB, attackMs, releaseMs, direction,
        boostThresholdDB, boostRatio, maxBoostDB, detectorMode, rmsWindowMs
    );
}

static bool band_is_valid(N60DynamicEQBandSnapshot band, double sampleRate) {
    return shape_is_valid(band.shape)
        && isfinite(band.frequencyHz) && band.frequencyHz >= 20.0 && band.frequencyHz <= 20000.0 && band.frequencyHz < sampleRate * 0.5
        && isfinite(band.q) && band.q >= 0.4f && band.q <= 8.0f
        && isfinite(band.staticGainDB) && band.staticGainDB >= -18.0f && band.staticGainDB <= 6.0f
        && isfinite(band.thresholdDB) && band.thresholdDB >= -60.0f && band.thresholdDB <= 0.0f
        && isfinite(band.ratio) && band.ratio >= 1.0f && band.ratio <= 10.0f
        && isfinite(band.rangeDB) && band.rangeDB >= -24.0f && band.rangeDB <= 0.0f
        && isfinite(band.attackCoefficient) && band.attackCoefficient >= 0.0f && band.attackCoefficient < 1.0f
        && isfinite(band.releaseCoefficient) && band.releaseCoefficient >= 0.0f && band.releaseCoefficient < 1.0f
        && direction_is_valid(band.direction)
        && !(band.shape == N60DynamicEQShapeNotch && band.direction != N60DynamicEQDirectionCutOnly)
        && isfinite(band.boostThresholdDB) && band.boostThresholdDB >= -60.0f && band.boostThresholdDB <= 0.0f
        && isfinite(band.boostRatio) && band.boostRatio >= 1.0f && band.boostRatio <= 10.0f
        && isfinite(band.maxBoostDB) && band.maxBoostDB >= 0.0f && band.maxBoostDB <= 12.0f
        && detector_is_valid(band.detectorMode)
        && isfinite(band.rmsCoefficient) && band.rmsCoefficient >= 0.0f && band.rmsCoefficient < 1.0f
        && coefficients_are_finite(band.analysisBandPass)
        && coefficients_are_finite(band.basisPrimary)
        && coefficients_are_finite(band.basisSecondary);
}

bool N60DynamicEQSnapshotIsValid(N60DynamicEQSnapshot snapshot) {
    if (!domain_is_valid(snapshot.domain)
        || !isfinite(snapshot.sampleRate) || snapshot.sampleRate <= 0.0 || snapshot.sampleRate > 384000.0
        || snapshot.bandCount > N60_DYNAMIC_EQ_MAX_BANDS
        || snapshot.secondaryBandCount > N60_DYNAMIC_EQ_MAX_BANDS
        || (snapshot.domain == N60DynamicEQDomainLinkedStereo && snapshot.secondaryBandCount != 0)
        || !isfinite(snapshot.bypassTransitionCoefficient)
        || snapshot.bypassTransitionCoefficient < 0.0f || snapshot.bypassTransitionCoefficient >= 1.0f) return false;

    for (uint32_t index = 0; index < snapshot.bandCount; ++index) {
        if (!band_is_valid(snapshot.bands[index], snapshot.sampleRate)) return false;
    }
    for (uint32_t index = 0; index < snapshot.secondaryBandCount; ++index) {
        if (!band_is_valid(snapshot.secondaryBands[index], snapshot.sampleRate)) return false;
    }
    return true;
}

void N60DynamicEQRuntimeReset(N60DynamicEQRuntime *runtime) {
    if (runtime == NULL) return;
    memset(runtime, 0, sizeof(*runtime));
    for (uint32_t index = 0; index < N60_DYNAMIC_EQ_MAX_BANDS; ++index) {
        runtime->detectorLevelDBFS[index] = -120.0f;
        runtime->secondaryDetectorLevelDBFS[index] = -120.0f;
    }
}

static void update_gain_state(
    bool enabled,
    float bypassTransitionCoefficient,
    N60DynamicEQBandSnapshot band,
    float detectorDB,
    float *dynamicGainDB,
    float *staticGainDB,
    float *wetMix
) {
    bool active = enabled && band.enabled;
    float targetDynamicDB = active ? target_dynamic_gain_db(detectorDB, band) : 0.0f;
    float currentDynamicDB = *dynamicGainDB;
    bool correctionGrowing = fabsf(targetDynamicDB) > fabsf(currentDynamicDB);
    float dynamicPole = active
        ? (correctionGrowing ? band.attackCoefficient : band.releaseCoefficient)
        : bypassTransitionCoefficient;
    *dynamicGainDB = smooth_pole(currentDynamicDB, targetDynamicDB, dynamicPole);
    *staticGainDB = smooth_pole(
        *staticGainDB, active ? band.staticGainDB : 0.0f, bypassTransitionCoefficient);
    *wetMix = smooth_pole(*wetMix, active ? 1.0f : 0.0f, bypassTransitionCoefficient);
}

static void process_linked_stereo(
    N60DynamicEQRuntime *runtime,
    N60DynamicEQSnapshot snapshot,
    float *left,
    float *right
) {
    for (uint32_t index = 0; index < snapshot.bandCount; ++index) {
        N60DynamicEQBandSnapshot band = snapshot.bands[index];
        float inputLeft = *left;
        float inputRight = *right;
        float analysisLeft = process_biquad(band.analysisBandPass, &runtime->analysisLeft[index], inputLeft);
        float analysisRight = process_biquad(band.analysisBandPass, &runtime->analysisRight[index], inputRight);
        float detectorLinear;
        if (band.detectorMode == N60DynamicEQDetectorRMS) {
            float instantPower = 0.5f * (analysisLeft * analysisLeft + analysisRight * analysisRight);
            runtime->rmsPower[index] = smooth_pole(runtime->rmsPower[index], instantPower, band.rmsCoefficient);
            detectorLinear = sqrtf(fmaxf(runtime->rmsPower[index], 0.0f));
        } else {
            detectorLinear = fmaxf(fabsf(analysisLeft), fabsf(analysisRight));
            runtime->rmsPower[index] = detectorLinear * detectorLinear;
        }
        float detectorDB = linear_to_db(detectorLinear);
        runtime->detectorLevelDBFS[index] = detectorDB;
        update_gain_state(snapshot.enabled, snapshot.bypassTransitionCoefficient, band, detectorDB,
                          &runtime->dynamicGainDB[index], &runtime->staticGainDB[index], &runtime->wetMix[index]);
        if (snapshot.enabled && band.enabled) runtime->activeBandCount += 1u;
        runtime->maxAbsDynamicGainDB = fmaxf(runtime->maxAbsDynamicGainDB, fabsf(runtime->dynamicGainDB[index]));
        float totalGainDB = clampf_local(runtime->staticGainDB[index] + runtime->dynamicGainDB[index], -42.0f, 18.0f);
        *left = apply_shape(band, &runtime->processPrimaryLeft[index], &runtime->processSecondaryLeft[index],
                            inputLeft, totalGainDB, runtime->wetMix[index]);
        *right = apply_shape(band, &runtime->processPrimaryRight[index], &runtime->processSecondaryRight[index],
                             inputRight, totalGainDB, runtime->wetMix[index]);
    }
}

static void process_primary_mono(
    N60DynamicEQRuntime *runtime,
    N60DynamicEQSnapshot snapshot,
    float *sample
) {
    for (uint32_t index = 0; index < snapshot.bandCount; ++index) {
        N60DynamicEQBandSnapshot band = snapshot.bands[index];
        float input = *sample;
        float analysis = process_biquad(band.analysisBandPass, &runtime->analysisLeft[index], input);
        float detectorLinear;
        if (band.detectorMode == N60DynamicEQDetectorRMS) {
            float instantPower = analysis * analysis;
            runtime->rmsPower[index] = smooth_pole(runtime->rmsPower[index], instantPower, band.rmsCoefficient);
            detectorLinear = sqrtf(fmaxf(runtime->rmsPower[index], 0.0f));
        } else {
            detectorLinear = fabsf(analysis);
            runtime->rmsPower[index] = detectorLinear * detectorLinear;
        }
        float detectorDB = linear_to_db(detectorLinear);
        runtime->detectorLevelDBFS[index] = detectorDB;
        update_gain_state(snapshot.enabled, snapshot.bypassTransitionCoefficient, band, detectorDB,
                          &runtime->dynamicGainDB[index], &runtime->staticGainDB[index], &runtime->wetMix[index]);
        if (snapshot.enabled && band.enabled) runtime->activeBandCount += 1u;
        runtime->maxAbsDynamicGainDB = fmaxf(runtime->maxAbsDynamicGainDB, fabsf(runtime->dynamicGainDB[index]));
        float totalGainDB = clampf_local(runtime->staticGainDB[index] + runtime->dynamicGainDB[index], -42.0f, 18.0f);
        *sample = apply_shape(band, &runtime->processPrimaryLeft[index], &runtime->processSecondaryLeft[index],
                              input, totalGainDB, runtime->wetMix[index]);
    }
}

static void process_secondary_mono(
    N60DynamicEQRuntime *runtime,
    N60DynamicEQSnapshot snapshot,
    float *sample
) {
    for (uint32_t index = 0; index < snapshot.secondaryBandCount; ++index) {
        N60DynamicEQBandSnapshot band = snapshot.secondaryBands[index];
        float input = *sample;
        float analysis = process_biquad(band.analysisBandPass, &runtime->secondaryAnalysisLeft[index], input);
        float detectorLinear;
        if (band.detectorMode == N60DynamicEQDetectorRMS) {
            float instantPower = analysis * analysis;
            runtime->secondaryRmsPower[index] = smooth_pole(runtime->secondaryRmsPower[index], instantPower, band.rmsCoefficient);
            detectorLinear = sqrtf(fmaxf(runtime->secondaryRmsPower[index], 0.0f));
        } else {
            detectorLinear = fabsf(analysis);
            runtime->secondaryRmsPower[index] = detectorLinear * detectorLinear;
        }
        float detectorDB = linear_to_db(detectorLinear);
        runtime->secondaryDetectorLevelDBFS[index] = detectorDB;
        update_gain_state(snapshot.enabled, snapshot.bypassTransitionCoefficient, band, detectorDB,
                          &runtime->secondaryDynamicGainDB[index], &runtime->secondaryStaticGainDB[index], &runtime->secondaryWetMix[index]);
        if (snapshot.enabled && band.enabled) runtime->activeBandCount += 1u;
        runtime->maxAbsDynamicGainDB = fmaxf(runtime->maxAbsDynamicGainDB, fabsf(runtime->secondaryDynamicGainDB[index]));
        float totalGainDB = clampf_local(runtime->secondaryStaticGainDB[index] + runtime->secondaryDynamicGainDB[index], -42.0f, 18.0f);
        *sample = apply_shape(band, &runtime->secondaryProcessPrimaryLeft[index], &runtime->secondaryProcessSecondaryLeft[index],
                              input, totalGainDB, runtime->secondaryWetMix[index]);
    }
}

void N60DynamicEQProcessStereoFrame(
    N60DynamicEQRuntime *runtime,
    N60DynamicEQSnapshot snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;
    if (!runtime->domainInitialized || runtime->currentDomain != snapshot.domain) {
        N60DynamicEQRuntimeReset(runtime);
        runtime->currentDomain = snapshot.domain;
        runtime->domainInitialized = true;
    }
    runtime->activeBandCount = 0;
    runtime->maxAbsDynamicGainDB = 0.0f;

    switch (snapshot.domain) {
    case N60DynamicEQDomainDualMono:
        process_primary_mono(runtime, snapshot, left);
        process_secondary_mono(runtime, snapshot, right);
        break;
    case N60DynamicEQDomainMidSide: {
        float mid = 0.5f * (*left + *right);
        float side = 0.5f * (*left - *right);
        process_primary_mono(runtime, snapshot, &mid);
        process_secondary_mono(runtime, snapshot, &side);
        *left = mid + side;
        *right = mid - side;
        break;
    }
    case N60DynamicEQDomainLinkedStereo:
    default:
        process_linked_stereo(runtime, snapshot, left, right);
        break;
    }
}

N60DynamicEQTelemetry N60DynamicEQRuntimeTelemetry(const N60DynamicEQRuntime *runtime) {
    N60DynamicEQTelemetry telemetry = {0};
    if (runtime == NULL) return telemetry;
    telemetry.activeBandCount = runtime->activeBandCount;
    telemetry.maxAbsDynamicGainDB = runtime->maxAbsDynamicGainDB;
    return telemetry;
}
'''

(ROOT / "NotchSixty/Audio/Realtime/N60DynamicEQ.h").write_text(DYNAMIC_H)
(ROOT / "NotchSixty/Audio/Realtime/N60DynamicEQ.c").write_text(DYNAMIC_C)

# EQ filter capability metadata + compatibility-path validation.
audio = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
replace_once(
    audio,
    '''    var cType: N60BiquadFilterType {\n''',
    '''    var dynamicEQShape: N60DynamicEQShape? {\n        switch self {\n        case .peaking: return N60DynamicEQShapePeak\n        case .lowShelf: return N60DynamicEQShapeLowShelf\n        case .highShelf: return N60DynamicEQShapeHighShelf\n        case .bandPass: return N60DynamicEQShapeBandPass\n        case .tilt: return N60DynamicEQShapeTilt\n        case .notch: return N60DynamicEQShapeNotch\n        case .lowPass, .highPass, .linkwitzTransform, .fir, .allPass: return nil\n        }\n    }\n\n    var supportsDynamicEQ: Bool { dynamicEQShape != nil }\n\n    var cType: N60BiquadFilterType {\n'''
)
old_validation = '''        if band.dynamic.enabled {\n            guard band.type == .peaking,\n                  DynamicEQBandConfiguration.frequencyRange.contains(band.frequencyHz),\n                  DynamicEQBandConfiguration.qRange.contains(band.q),\n                  band.dynamic.isValid else {\n                throw EQConfigurationError.invalidBand(index: index)\n            }\n        }\n'''
new_validation = '''        if band.dynamic.enabled {\n            guard band.type.supportsDynamicEQ,\n                  DynamicEQBandConfiguration.frequencyRange.contains(band.frequencyHz),\n                  DynamicEQBandConfiguration.qRange.contains(band.q),\n                  band.dynamic.isValid,\n                  !(band.type == .notch && band.dynamic.direction != .cutOnly) else {\n                throw EQConfigurationError.invalidBand(index: index)\n            }\n        }\n'''
replace_once(audio, old_validation, new_validation)

# Stereo graph validation, headroom accounting, and domain-aware compilation.
stereo = ROOT / "NotchSixty/Audio/StereoPlaybackControl.swift"
replace_once(stereo, old_validation, new_validation)
replace_between(
    stereo,
    '''    private var sharedDynamicSourceBands: [EQBand] {\n''',
    '''    private func publishMinimumPhaseBand(\n''',
    '''    private func dynamicBoostDB(in bands: [EQBand]) -> Double {\n        bands.lazy\n            .filter { $0.enabled && $0.type.supportsDynamicEQ && $0.dynamic.enabled }\n            .reduce(0.0) { partial, band in\n                let dynamic = band.dynamic\n                let boost = dynamic.direction == .cutOnly ? 0.0 : max(0.0, dynamic.maxBoostDB)\n                return partial + boost\n            }\n    }\n\n    private func conservativeAutomaticHeadroomDB(\n        dynamics: DynamicsConfiguration\n    ) -> Double {\n        guard dynamics.automaticHeadroom.enabled else { return 0 }\n\n        func channelBoost(_ bands: [EQBand]) -> Double {\n            bands.lazy.filter(\\.enabled).reduce(0.0) { partial, band in\n                if band.type == .fir {\n                    return partial + (band.firKernel?.conservativeBoostDB ?? 0.0)\n                }\n                return partial + max(0.0, band.gainDB)\n            }\n        }\n        let staticBoost: Double\n        if bypassed {\n            staticBoost = 0\n        } else {\n            switch channelMode {\n            case .linked: staticBoost = channelBoost(linkedBands)\n            case .independent: staticBoost = max(channelBoost(leftBands), channelBoost(rightBands))\n            case .midSide: staticBoost = max(channelBoost(midBands), channelBoost(sideBands))\n            }\n        }\n\n        let dynamicBoost: Double\n        if bypassed {\n            dynamicBoost = 0\n        } else {\n            switch channelMode {\n            case .linked:\n                dynamicBoost = dynamicBoostDB(in: linkedBands)\n            case .independent:\n                dynamicBoost = max(dynamicBoostDB(in: leftBands), dynamicBoostDB(in: rightBands))\n            case .midSide:\n                dynamicBoost = max(dynamicBoostDB(in: midBands), dynamicBoostDB(in: sideBands))\n            }\n        }\n        return min(dynamics.automaticHeadroom.maxAttenuationDB, staticBoost + dynamicBoost)\n    }\n\n    private func makeDomainDynamicEQSnapshot(sampleRate: Double) throws -> N60DynamicEQSnapshot {\n        var snapshot = N60DynamicEQSnapshotMakeBypassed(sampleRate)\n        let domain: N60DynamicEQDomain\n        switch channelMode {\n        case .linked: domain = N60DynamicEQDomainLinkedStereo\n        case .independent: domain = N60DynamicEQDomainDualMono\n        case .midSide: domain = N60DynamicEQDomainMidSide\n        }\n        guard N60DynamicEQSnapshotSetDomain(&snapshot, domain) else {\n            throw DynamicsConfigurationError.invalidDynamicEQ\n        }\n\n        func compileLane(_ source: [EQBand], lane: N60DynamicEQLane) throws -> Int {\n            let validated = try validatedEnabledBands(source, sampleRate: sampleRate)\n            let dynamicBands = validated.filter { $0.dynamic.enabled }\n            var outputIndex: UInt32 = 0\n            for (sourceIndex, band) in dynamicBands.enumerated() {\n                guard let shape = band.type.dynamicEQShape else {\n                    throw EQConfigurationError.invalidBand(index: sourceIndex)\n                }\n                let dynamic = band.dynamic\n                guard N60DynamicEQSnapshotSetBandForLane(\n                    &snapshot, sampleRate, lane, outputIndex, true, shape,\n                    band.frequencyHz, Float(band.q), 0,\n                    Float(dynamic.thresholdDB), Float(dynamic.ratio), Float(dynamic.rangeDB),\n                    Float(dynamic.attackMs), Float(dynamic.releaseMs), dynamic.direction.cType,\n                    Float(dynamic.boostThresholdDB), Float(dynamic.boostRatio), Float(dynamic.maxBoostDB),\n                    dynamic.detectorMode.cType, Float(dynamic.rmsWindowMs)\n                ) else {\n                    throw EQConfigurationError.invalidBand(index: sourceIndex)\n                }\n                outputIndex += 1\n            }\n            return Int(outputIndex)\n        }\n\n        let count: Int\n        switch channelMode {\n        case .linked:\n            count = try compileLane(linkedBands, lane: N60DynamicEQLanePrimary)\n        case .independent:\n            count = try compileLane(leftBands, lane: N60DynamicEQLanePrimary)\n                + compileLane(rightBands, lane: N60DynamicEQLaneSecondary)\n        case .midSide:\n            count = try compileLane(midBands, lane: N60DynamicEQLanePrimary)\n                + compileLane(sideBands, lane: N60DynamicEQLaneSecondary)\n        }\n        guard N60DynamicEQSnapshotSetEnabled(&snapshot, !bypassed && count > 0) else {\n            throw DynamicsConfigurationError.invalidDynamicEQ\n        }\n        return snapshot\n    }\n\n    private func publishMinimumPhaseBand(\n'''
)
replace_once(
    stereo,
    '''        var compiledDynamics = dynamicsConfiguration\n        try compileUnifiedDynamicEQ(into: &compiledDynamics, sampleRate: sampleRate)\n''',
    '''        var compiledDynamics = dynamicsConfiguration\n        // EQ-band dynamics are compiled below into a domain-aware realtime snapshot.\n        // Keep the older standalone DynamicEQConfiguration empty so it cannot\n        // accidentally create a second shared layer.\n        compiledDynamics.dynamicEQ = DynamicEQConfiguration()\n'''
)
replace_once(
    stereo,
    '''        graph.dynamics = try compiledDynamics.makeSnapshot(sampleRate: sampleRate)\n        graph.protection = try compiledDynamics.makeProtectionSnapshot(sampleRate: sampleRate)\n''',
    '''        graph.dynamics = try compiledDynamics.makeSnapshot(sampleRate: sampleRate)\n        graph.dynamics.dynamicEQ = try makeDomainDynamicEQSnapshot(sampleRate: sampleRate)\n        graph.protection = try compiledDynamics.makeProtectionSnapshot(sampleRate: sampleRate)\n'''
)

# UI: all channel lanes can own dynamics; phase mode no longer disables it.
view = ROOT / "NotchSixty/ContentView.swift"
replace_once(
    view,
    '''                    Text("Commercial capacity: up to \\(EQConfiguration.maximumBandCount) EQ bands. Dynamic settings are owned by Linked, Left (Independent), or Mid (Mid/Side) Peak bands in Minimum/Mixed Phase and render as one identical physical-stereo layer.")\n''',
    '''                    Text("Commercial capacity: up to \\(EQConfiguration.maximumBandCount) EQ bands. Dynamic EQ follows the active band domain: Linked is stereo-linked, Independent uses separate Left/Right lanes, and Mid/Side uses separate Mid/Side lanes. Peak, shelves, Tilt, Notch, and Band Pass support dynamics in Minimum, Mixed, and Linear phase modes.")\n'''
)
replace_between(
    view,
    '''        let dynamicOwnerChannel: Bool = {\n''',
    '''        VStack(alignment: .leading, spacing: 6) {\n''',
    '''        let dynamicSupported = band.type.supportsDynamicEQ\n\n        VStack(alignment: .leading, spacing: 6) {\n'''
)
owner_note = '''            if engine.eqConfiguration.phaseMode != .linearPhase && band.type == .peaking && !dynamicOwnerChannel {\n                Text(engine.stereoEQConfiguration.channelMode == .midSide\n                     ? "Dynamic EQ is shared across physical L/R; edit Dynamic settings from Mid."\n                     : "Dynamic EQ is shared across physical L/R; edit Dynamic settings from Left.")\n                    .font(.caption2)\n                    .foregroundStyle(.secondary)\n            }\n\n'''
replace_once(view, owner_note, '''            if !dynamicSupported {\n                Text("Dynamic EQ is not available for HP/LP, Linkwitz Transform, FIR, or All-Pass bands.")\n                    .font(.caption2)\n                    .foregroundStyle(.secondary)\n            }\n\n''')
replace_once(
    view,
    '''                    Picker("Direction", selection: binding.dynamic.direction) {\n                        ForEach(DynamicEQDirection.allCases) { value in Text(value.displayName).tag(value) }\n                    }.frame(width: 165)\n''',
    '''                    if band.type == .notch {\n                        Text("Cut Only").frame(width: 165, alignment: .leading)\n                    } else {\n                        Picker("Direction", selection: binding.dynamic.direction) {\n                            ForEach(DynamicEQDirection.allCases) { value in Text(value.displayName).tag(value) }\n                        }.frame(width: 165)\n                    }\n'''
)
replace_once(
    view,
    '''            } else if band.dynamic.enabled {\n                Text("Dynamic is inactive for this band. Use Linked + Minimum phase + Peak to enable dynamic operation.")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n                    .padding(.leading, 40)\n            }\n''',
    '''                if engine.eqConfiguration.phaseMode == .linearPhase {\n                    Text("Linear Phase keeps the static FIR linear-phase; the time-varying Dynamic correction runs as a minimum-phase layer after the FIR.")\n                        .font(.caption2)\n                        .foregroundStyle(.secondary)\n                        .padding(.leading, 40)\n                }\n            }\n'''
)
replace_once(
    view,
    '''                if sanitized.type != .peaking {\n                    sanitized.constantQ = false\n                    sanitized.dynamic.enabled = false\n                }\n''',
    '''                if sanitized.type != .peaking {\n                    sanitized.constantQ = false\n                }\n                if !sanitized.type.supportsDynamicEQ {\n                    sanitized.dynamic.enabled = false\n                }\n                if sanitized.type == .notch {\n                    sanitized.dynamic.direction = .cutOnly\n                }\n'''
)

# Replace the temporary owner-bank tests with domain-aware contracts.
tests = ROOT / "NotchSixtyTests/NotchSixtyTests.swift"
replace_between(
    tests,
    '''    func testMidSideUsesMidBankForSharedDynamicEQ() throws {\n''',
    '''    func testMidSideRealtimeIdentityAndAuditionContracts() throws {\n''',
    '''    func testMidSideDynamicEQUsesIndependentMidAndSideLanes() throws {\n        var dynamic = EQBandDynamicConfiguration()\n        dynamic.enabled = true\n        dynamic.thresholdDB = -30\n        dynamic.ratio = 2\n        dynamic.rangeDB = -6\n\n        let midBand = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 0, q: 1.0, dynamic: dynamic)\n        let sideBand = EQBand(type: .highShelf, frequencyHz: 4_000, gainDB: 0, q: 0.707, dynamic: dynamic)\n        let configuration = StereoEQConfiguration(\n            channelMode: .midSide, editChannel: .mid, phaseMode: .minimumPhase,\n            midBands: [midBand], sideBands: [sideBand], midSideSeeded: true\n        )\n        let graph = try configuration.makeGraphSnapshot(\n            sampleRate: 96_000, gainConfiguration: DSPGainConfiguration(),\n            bassManagementConfiguration: BassManagementConfiguration(),\n            playbackConfiguration: PlaybackControlConfiguration()\n        )\n        XCTAssertTrue(graph.dynamics.dynamicEQ.enabled)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.domain, N60DynamicEQDomainMidSide)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.bandCount, 1)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.secondaryBandCount, 1)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.bands.0.shape, N60DynamicEQShapePeak)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.secondaryBands.0.shape, N60DynamicEQShapeHighShelf)\n    }\n\n    func testIndependentDynamicEQUsesSeparateLeftAndRightLanes() throws {\n        var dynamic = EQBandDynamicConfiguration()\n        dynamic.enabled = true\n        let leftBand = EQBand(type: .lowShelf, frequencyHz: 120, gainDB: 0, q: 0.707, dynamic: dynamic)\n        let rightBand = EQBand(type: .peaking, frequencyHz: 1_600, gainDB: 0, q: 1.2, dynamic: dynamic)\n        let configuration = StereoEQConfiguration(\n            channelMode: .independent, editChannel: .right, phaseMode: .mixedPhase,\n            leftBands: [leftBand], rightBands: [rightBand], independentSeeded: true\n        )\n        let graph = try configuration.makeGraphSnapshot(\n            sampleRate: 192_000, gainConfiguration: DSPGainConfiguration(),\n            bassManagementConfiguration: BassManagementConfiguration(),\n            playbackConfiguration: PlaybackControlConfiguration()\n        )\n        XCTAssertTrue(graph.dynamics.dynamicEQ.enabled)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.domain, N60DynamicEQDomainDualMono)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.bandCount, 1)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.secondaryBandCount, 1)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.bands.0.shape, N60DynamicEQShapeLowShelf)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.secondaryBands.0.shape, N60DynamicEQShapePeak)\n    }\n\n    func testLinearPhaseRetainsDynamicAsPostFIRMinimumPhaseLayer() throws {\n        var dynamic = EQBandDynamicConfiguration()\n        dynamic.enabled = true\n        let band = EQBand(type: .tilt, frequencyHz: 1_000, gainDB: 2, q: 0.707, dynamic: dynamic)\n        let configuration = StereoEQConfiguration(phaseMode: .linearPhase, linkedBands: [band])\n        let graph = try configuration.makeGraphSnapshot(\n            sampleRate: 96_000, gainConfiguration: DSPGainConfiguration(),\n            bassManagementConfiguration: BassManagementConfiguration(),\n            playbackConfiguration: PlaybackControlConfiguration()\n        )\n        XCTAssertTrue(graph.dynamics.dynamicEQ.enabled)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.domain, N60DynamicEQDomainLinkedStereo)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.bandCount, 1)\n        XCTAssertEqual(graph.dynamics.dynamicEQ.bands.0.shape, N60DynamicEQShapeTilt)\n    }\n\n    func testDynamicEQFilterCoverageAndStructuralRestrictions() throws {\n        var dynamic = EQBandDynamicConfiguration()\n        dynamic.enabled = true\n        var notchDynamic = dynamic\n        notchDynamic.direction = .cutOnly\n        let supported = [\n            EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 0, q: 1, dynamic: dynamic),\n            EQBand(type: .lowShelf, frequencyHz: 120, gainDB: 0, q: 0.707, dynamic: dynamic),\n            EQBand(type: .highShelf, frequencyHz: 5_000, gainDB: 0, q: 0.707, dynamic: dynamic),\n            EQBand(type: .tilt, frequencyHz: 1_000, gainDB: 0, q: 0.707, dynamic: dynamic),\n            EQBand(type: .notch, frequencyHz: 2_000, gainDB: 0, q: 2, dynamic: notchDynamic),\n            EQBand(type: .bandPass, frequencyHz: 800, gainDB: 0, q: 1, dynamic: dynamic),\n        ]\n        let graph = try StereoEQConfiguration(linkedBands: supported).makeGraphSnapshot(\n            sampleRate: 48_000, gainConfiguration: DSPGainConfiguration(),\n            bassManagementConfiguration: BassManagementConfiguration(),\n            playbackConfiguration: PlaybackControlConfiguration()\n        )\n        XCTAssertEqual(graph.dynamics.dynamicEQ.bandCount, 6)\n\n        for type in [EQFilterType.lowPass, .highPass, .linkwitzTransform, .fir, .allPass] {\n            var band = EQBand(type: type, dynamic: dynamic)\n            if type == .fir { band.firKernel = .validation() }\n            XCTAssertThrowsError(try StereoEQConfiguration(linkedBands: [band]).makeGraphSnapshot(\n                sampleRate: 48_000, gainConfiguration: DSPGainConfiguration(),\n                bassManagementConfiguration: BassManagementConfiguration(),\n                playbackConfiguration: PlaybackControlConfiguration()\n            ))\n        }\n\n        var invalidNotch = dynamic\n        invalidNotch.direction = .boostOnly\n        let notch = EQBand(type: .notch, frequencyHz: 2_000, gainDB: 0, q: 2, dynamic: invalidNotch)\n        XCTAssertThrowsError(try StereoEQConfiguration(linkedBands: [notch]).makeGraphSnapshot(\n            sampleRate: 48_000, gainConfiguration: DSPGainConfiguration(),\n            bassManagementConfiguration: BassManagementConfiguration(),\n            playbackConfiguration: PlaybackControlConfiguration()\n        ))\n    }\n\n    func testMidSideRealtimeIdentityAndAuditionContracts() throws {\n'''
)

print("Applied domain-aware Dynamic EQ architecture")
