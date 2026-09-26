#include "N60DynamicEQ.h"

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

static N60DynamicEQBiquadCoefficients identity_coefficients(void) {
    N60DynamicEQBiquadCoefficients result = {0};
    result.b0 = 1.0;
    return result;
}

// Control-plane RBJ constant-peak-gain band-pass design. Double precision is
// deliberate: a 20 Hz / high-Q detector at 384 kHz is a numerically demanding
// normalized-frequency case even though the public audio stream remains float.
static bool design_band_pass(
    double sampleRate,
    double frequencyHz,
    double q,
    N60DynamicEQBiquadCoefficients *result
) {
    if (result == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz < 20.0 || frequencyHz >= sampleRate * 0.5
        || !isfinite(q) || q < 0.4 || q > 8.0) return false;

    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double sinOmega = sin(omega);
    double cosOmega = cos(omega);
    double alpha = sinOmega / (2.0 * q);
    double a0 = 1.0 + alpha;
    if (!isfinite(a0) || fabs(a0) < 1.0e-20) return false;

    N60DynamicEQBiquadCoefficients configured = {
        .b0 = alpha / a0,
        .b1 = 0.0,
        .b2 = -alpha / a0,
        .a1 = (-2.0 * cosOmega) / a0,
        .a2 = (1.0 - alpha) / a0,
    };
    if (!isfinite(configured.b0) || !isfinite(configured.b1) || !isfinite(configured.b2)
        || !isfinite(configured.a1) || !isfinite(configured.a2)) return false;
    *result = configured;
    return true;
}

static float process_band_pass(
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

N60DynamicEQSnapshot N60DynamicEQSnapshotMakeBypassed(double sampleRate) {
    N60DynamicEQSnapshot snapshot = {0};
    snapshot.enabled = false;
    snapshot.sampleRate = sampleRate;
    snapshot.bandCount = 0;
    snapshot.bypassTransitionCoefficient = time_pole(sampleRate, N60_DYNAMIC_EQ_TRANSITION_MS);
    for (uint32_t index = 0; index < N60_DYNAMIC_EQ_MAX_BANDS; ++index) {
        snapshot.bands[index].analysisBandPass = identity_coefficients();
    }
    return snapshot;
}

bool N60DynamicEQSnapshotSetEnabled(N60DynamicEQSnapshot *snapshot, bool enabled) {
    if (snapshot == NULL) return false;
    snapshot->enabled = enabled;
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
    if (snapshot == NULL || index >= N60_DYNAMIC_EQ_MAX_BANDS
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
        || !isfinite(boostThresholdDB) || boostThresholdDB < -60.0f || boostThresholdDB > 0.0f
        || !isfinite(boostRatio) || boostRatio < 1.0f || boostRatio > 10.0f
        || !isfinite(maxBoostDB) || maxBoostDB < 0.0f || maxBoostDB > 12.0f
        || !detector_is_valid(detectorMode)
        || !isfinite(rmsWindowMs) || rmsWindowMs < 5.0f || rmsWindowMs > 200.0f) return false;

    N60DynamicEQBandSnapshot configured = {0};
    configured.enabled = enabled;
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
    if (!design_band_pass(sampleRate, frequencyHz, q, &configured.analysisBandPass)) return false;

    snapshot->sampleRate = sampleRate;
    snapshot->bands[index] = configured;
    if (snapshot->bandCount < index + 1u) snapshot->bandCount = index + 1u;
    snapshot->bypassTransitionCoefficient = time_pole(sampleRate, N60_DYNAMIC_EQ_TRANSITION_MS);
    return true;
}

bool N60DynamicEQSnapshotIsValid(N60DynamicEQSnapshot snapshot) {
    if (!isfinite(snapshot.sampleRate) || snapshot.sampleRate <= 0.0 || snapshot.sampleRate > 384000.0
        || snapshot.bandCount > N60_DYNAMIC_EQ_MAX_BANDS
        || !isfinite(snapshot.bypassTransitionCoefficient)
        || snapshot.bypassTransitionCoefficient < 0.0f || snapshot.bypassTransitionCoefficient >= 1.0f) return false;

    for (uint32_t index = 0; index < snapshot.bandCount; ++index) {
        N60DynamicEQBandSnapshot band = snapshot.bands[index];
        if (!isfinite(band.frequencyHz) || band.frequencyHz < 20.0 || band.frequencyHz > 20000.0 || band.frequencyHz >= snapshot.sampleRate * 0.5
            || !isfinite(band.q) || band.q < 0.4f || band.q > 8.0f
            || !isfinite(band.staticGainDB) || band.staticGainDB < -18.0f || band.staticGainDB > 6.0f
            || !isfinite(band.thresholdDB) || band.thresholdDB < -60.0f || band.thresholdDB > 0.0f
            || !isfinite(band.ratio) || band.ratio < 1.0f || band.ratio > 10.0f
            || !isfinite(band.rangeDB) || band.rangeDB < -24.0f || band.rangeDB > 0.0f
            || !isfinite(band.attackCoefficient) || band.attackCoefficient < 0.0f || band.attackCoefficient >= 1.0f
            || !isfinite(band.releaseCoefficient) || band.releaseCoefficient < 0.0f || band.releaseCoefficient >= 1.0f
            || !direction_is_valid(band.direction)
            || !isfinite(band.boostThresholdDB) || band.boostThresholdDB < -60.0f || band.boostThresholdDB > 0.0f
            || !isfinite(band.boostRatio) || band.boostRatio < 1.0f || band.boostRatio > 10.0f
            || !isfinite(band.maxBoostDB) || band.maxBoostDB < 0.0f || band.maxBoostDB > 12.0f
            || !detector_is_valid(band.detectorMode)
            || !isfinite(band.rmsCoefficient) || band.rmsCoefficient < 0.0f || band.rmsCoefficient >= 1.0f
            || !isfinite(band.analysisBandPass.b0) || !isfinite(band.analysisBandPass.b1)
            || !isfinite(band.analysisBandPass.b2) || !isfinite(band.analysisBandPass.a1)
            || !isfinite(band.analysisBandPass.a2)) return false;
    }
    return true;
}

void N60DynamicEQRuntimeReset(N60DynamicEQRuntime *runtime) {
    if (runtime == NULL) return;
    memset(runtime, 0, sizeof(*runtime));
    for (uint32_t index = 0; index < N60_DYNAMIC_EQ_MAX_BANDS; ++index) {
        runtime->detectorLevelDBFS[index] = -120.0f;
    }
}

void N60DynamicEQProcessStereoFrame(
    N60DynamicEQRuntime *runtime,
    N60DynamicEQSnapshot snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;

    runtime->activeBandCount = 0;
    runtime->maxAbsDynamicGainDB = 0.0f;

    for (uint32_t index = 0; index < snapshot.bandCount && index < N60_DYNAMIC_EQ_MAX_BANDS; ++index) {
        N60DynamicEQBandSnapshot band = snapshot.bands[index];
        float inputLeft = *left;
        float inputRight = *right;
        float bandLeft = process_band_pass(band.analysisBandPass, &runtime->analysisLeft[index], inputLeft);
        float bandRight = process_band_pass(band.analysisBandPass, &runtime->analysisRight[index], inputRight);

        float detectorLinear = 0.0f;
        if (band.detectorMode == N60DynamicEQDetectorRMS) {
            float instantPower = 0.5f * (bandLeft * bandLeft + bandRight * bandRight);
            runtime->rmsPower[index] = smooth_pole(runtime->rmsPower[index], instantPower, band.rmsCoefficient);
            detectorLinear = sqrtf(fmaxf(runtime->rmsPower[index], 0.0f));
        } else {
            detectorLinear = fmaxf(fabsf(bandLeft), fabsf(bandRight));
            runtime->rmsPower[index] = detectorLinear * detectorLinear;
        }
        float detectorDB = linear_to_db(detectorLinear);
        runtime->detectorLevelDBFS[index] = detectorDB;

        bool active = snapshot.enabled && band.enabled;
        float targetDynamicDB = active ? target_dynamic_gain_db(detectorDB, band) : 0.0f;
        float currentDynamicDB = runtime->dynamicGainDB[index];
        bool correctionGrowing = fabsf(targetDynamicDB) > fabsf(currentDynamicDB);
        float dynamicPole = active
            ? (correctionGrowing ? band.attackCoefficient : band.releaseCoefficient)
            : snapshot.bypassTransitionCoefficient;
        runtime->dynamicGainDB[index] = smooth_pole(currentDynamicDB, targetDynamicDB, dynamicPole);

        float staticTargetDB = active ? band.staticGainDB : 0.0f;
        runtime->staticGainDB[index] = smooth_pole(
            runtime->staticGainDB[index], staticTargetDB, snapshot.bypassTransitionCoefficient);
        float mixTarget = active ? 1.0f : 0.0f;
        runtime->wetMix[index] = smooth_pole(
            runtime->wetMix[index], mixTarget, snapshot.bypassTransitionCoefficient);

        if (active) runtime->activeBandCount += 1u;
        runtime->maxAbsDynamicGainDB = fmaxf(
            runtime->maxAbsDynamicGainDB, fabsf(runtime->dynamicGainDB[index]));

        float totalGainDB = runtime->staticGainDB[index] + runtime->dynamicGainDB[index];
        totalGainDB = clampf_local(totalGainDB, -42.0f, 18.0f);
        float bandScale = (db_to_linear(totalGainDB) - 1.0f) * runtime->wetMix[index];
        *left = inputLeft + bandScale * bandLeft;
        *right = inputRight + bandScale * bandRight;
    }
}

N60DynamicEQTelemetry N60DynamicEQRuntimeTelemetry(const N60DynamicEQRuntime *runtime) {
    N60DynamicEQTelemetry telemetry = {0};
    if (runtime == NULL) return telemetry;
    telemetry.activeBandCount = runtime->activeBandCount;
    telemetry.maxAbsDynamicGainDB = runtime->maxAbsDynamicGainDB;
    return telemetry;
}
