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
    const N60DynamicEQSnapshot *snapshot,
    float *left,
    float *right
) {
    for (uint32_t index = 0; index < snapshot->bandCount; ++index) {
        N60DynamicEQBandSnapshot band = snapshot->bands[index];
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
        update_gain_state(snapshot->enabled, snapshot->bypassTransitionCoefficient, band, detectorDB,
                          &runtime->dynamicGainDB[index], &runtime->staticGainDB[index], &runtime->wetMix[index]);
        if (snapshot->enabled && band.enabled) runtime->activeBandCount += 1u;
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
    const N60DynamicEQSnapshot *snapshot,
    float *sample
) {
    for (uint32_t index = 0; index < snapshot->bandCount; ++index) {
        N60DynamicEQBandSnapshot band = snapshot->bands[index];
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
        update_gain_state(snapshot->enabled, snapshot->bypassTransitionCoefficient, band, detectorDB,
                          &runtime->dynamicGainDB[index], &runtime->staticGainDB[index], &runtime->wetMix[index]);
        if (snapshot->enabled && band.enabled) runtime->activeBandCount += 1u;
        runtime->maxAbsDynamicGainDB = fmaxf(runtime->maxAbsDynamicGainDB, fabsf(runtime->dynamicGainDB[index]));
        float totalGainDB = clampf_local(runtime->staticGainDB[index] + runtime->dynamicGainDB[index], -42.0f, 18.0f);
        *sample = apply_shape(band, &runtime->processPrimaryLeft[index], &runtime->processSecondaryLeft[index],
                              input, totalGainDB, runtime->wetMix[index]);
    }
}

static void process_secondary_mono(
    N60DynamicEQRuntime *runtime,
    const N60DynamicEQSnapshot *snapshot,
    float *sample
) {
    for (uint32_t index = 0; index < snapshot->secondaryBandCount; ++index) {
        N60DynamicEQBandSnapshot band = snapshot->secondaryBands[index];
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
        update_gain_state(snapshot->enabled, snapshot->bypassTransitionCoefficient, band, detectorDB,
                          &runtime->secondaryDynamicGainDB[index], &runtime->secondaryStaticGainDB[index], &runtime->secondaryWetMix[index]);
        if (snapshot->enabled && band.enabled) runtime->activeBandCount += 1u;
        runtime->maxAbsDynamicGainDB = fmaxf(runtime->maxAbsDynamicGainDB, fabsf(runtime->secondaryDynamicGainDB[index]));
        float totalGainDB = clampf_local(runtime->secondaryStaticGainDB[index] + runtime->secondaryDynamicGainDB[index], -42.0f, 18.0f);
        *sample = apply_shape(band, &runtime->secondaryProcessPrimaryLeft[index], &runtime->secondaryProcessSecondaryLeft[index],
                              input, totalGainDB, runtime->secondaryWetMix[index]);
    }
}

void N60DynamicEQProcessStereoFrame(
    N60DynamicEQRuntime *runtime,
    const N60DynamicEQSnapshot *snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;
    if (!runtime->domainInitialized || runtime->currentDomain != snapshot->domain) {
        N60DynamicEQRuntimeReset(runtime);
        runtime->currentDomain = snapshot->domain;
        runtime->domainInitialized = true;
    }
    runtime->activeBandCount = 0;
    runtime->maxAbsDynamicGainDB = 0.0f;

    switch (snapshot->domain) {
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
