#include "N60Protection.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define N60_HALF_BAND_TAPS 65u
#define N60_HALF_BAND_CENTER 32u
#define N60_PI 3.14159265358979323846f
#define N60_EPSILON 1.0e-12f

/*
 Independently designed 65-tap Blackman-windowed half-band interpolator.
 Unity-normalized DC response. Every even coefficient except the center is
 mathematically zero, so the realtime FIR skips those multiplies.
*/
static const float kHalfBand[N60_HALF_BAND_TAPS] = {
    0.0f, -8.93785157026247e-06f, 0.0f, 8.8329163000838e-05f,
    0.0f, -0.000276868159748326f, 0.0f, 0.000625180796064176f,
    0.0f, -0.00120674594714632f, 0.0f, 0.00211986552642504f,
    0.0f, -0.00349032377425427f, 0.0f, 0.00547729190001286f,
    0.0f, -0.00828756826069623f, 0.0f, 0.0122089119142877f,
    0.0f, -0.0176878320018053f, 0.0f, 0.0255207897268248f,
    0.0f, -0.037383473403991f, 0.0f, 0.0576394659334684f,
    0.0f, -0.102387515243912f, 0.0f, 0.31705153844599f,
    0.499995782474098f,
    0.317051538445991f, 0.0f, -0.102387515243912f, 0.0f,
    0.0576394659334684f, 0.0f, -0.0373834734039911f, 0.0f,
    0.0255207897268248f, 0.0f, -0.0176878320018053f, 0.0f,
    0.0122089119142877f, 0.0f, -0.00828756826069622f, 0.0f,
    0.00547729190001286f, 0.0f, -0.00349032377425427f, 0.0f,
    0.00211986552642504f, 0.0f, -0.00120674594714632f, 0.0f,
    0.000625180796064177f, 0.0f, -0.000276868159748327f, 0.0f,
    8.83291630008379e-05f, 0.0f, -8.93785157026247e-06f, 0.0f
};

typedef struct {
    float samples[N60_HALF_BAND_TAPS];
    uint32_t writeIndex;
} N60HalfBandFIR;

typedef struct {
    N60HalfBandFIR left;
    N60HalfBandFIR right;
} N60StereoHalfBand;

struct N60ProtectionRuntime {
    N60StereoHalfBand upStage1;
    N60StereoHalfBand upStage2;
    N60StereoHalfBand downStage2;
    N60StereoHalfBand downStage1;
    uint32_t downStage2Phase;
    uint32_t downStage1Phase;

    float limiterDelayLeft[N60_PROTECTION_MAX_LOOKAHEAD_HIGH_SAMPLES + 1u];
    float limiterDelayRight[N60_PROTECTION_MAX_LOOKAHEAD_HIGH_SAMPLES + 1u];
    uint64_t limiterSequence;
    float limiterGain;

    float peakDequeValue[N60_PROTECTION_MAX_LOOKAHEAD_HIGH_SAMPLES + 1u];
    uint64_t peakDequeIndex[N60_PROTECTION_MAX_LOOKAHEAD_HIGH_SAMPLES + 1u];
    uint32_t peakDequeHead;
    uint32_t peakDequeCount;

    N60ProtectionTelemetry telemetry;
};

static bool factor_is_valid(N60OversamplingFactor factor) {
    return factor == N60OversamplingFactor1x
        || factor == N60OversamplingFactor2x
        || factor == N60OversamplingFactor4x;
}

static float db_to_linear(float db) {
    return powf(10.0f, db / 20.0f);
}

static float linear_to_db(float linear) {
    return 20.0f * log10f(fmaxf(linear, N60_EPSILON));
}

static uint32_t oversampling_latency_frames(N60OversamplingFactor factor) {
    switch (factor) {
    case N60OversamplingFactor2x: return 32u;
    case N60OversamplingFactor4x: return 48u;
    case N60OversamplingFactor1x:
    default: return 0u;
    }
}

static void refresh_derived_state(N60ProtectionSnapshot *snapshot) {
    if (snapshot == NULL || !isfinite(snapshot->sampleRate) || snapshot->sampleRate <= 0.0) return;

    snapshot->effectiveFactor = snapshot->limiterEnabled
        ? N60OversamplingFactor4x
        : snapshot->oversamplingFactor;

    double highRate = snapshot->sampleRate * (double)snapshot->effectiveFactor;
    uint32_t lookAheadHigh = snapshot->limiterEnabled
        ? (uint32_t)ceil((double)snapshot->limiterLookAheadMs * 0.001 * highRate)
        : 0u;
    if (lookAheadHigh > N60_PROTECTION_MAX_LOOKAHEAD_HIGH_SAMPLES) {
        lookAheadHigh = N60_PROTECTION_MAX_LOOKAHEAD_HIGH_SAMPLES;
    }
    snapshot->limiterLookAheadHighSamples = lookAheadHigh;
    snapshot->limiterLookAheadFrames = lookAheadHigh == 0u ? 0u
        : (lookAheadHigh + (uint32_t)snapshot->effectiveFactor - 1u) / (uint32_t)snapshot->effectiveFactor;
    snapshot->limiterAttackHighSamples = snapshot->limiterEnabled
        ? (uint32_t)fmax(1.0, ceil((double)snapshot->limiterAttackMs * 0.001 * highRate))
        : 1u;
    snapshot->limiterReleaseCoefficientHigh = snapshot->limiterEnabled
        ? expf(-1.0f / fmaxf(1.0f, snapshot->limiterReleaseMs * 0.001f * (float)highRate))
        : 0.0f;
    snapshot->latencyFrames = oversampling_latency_frames(snapshot->effectiveFactor)
        + snapshot->limiterLookAheadFrames;
}

N60ProtectionSnapshot N60ProtectionSnapshotMakeBypassed(double sampleRate) {
    N60ProtectionSnapshot snapshot;
    memset(&snapshot, 0, sizeof(snapshot));
    snapshot.sampleRate = sampleRate;
    snapshot.oversamplingFactor = N60OversamplingFactor1x;
    snapshot.effectiveFactor = N60OversamplingFactor1x;
    snapshot.clipperDriveLinear = 1.0f;
    snapshot.clipperThresholdLinear = db_to_linear(-1.5f);
    snapshot.clipperKneeSmooth = 0.5f;
    snapshot.clipperCurve = N60ClipperCurveQuadratic;
    snapshot.clipperCompensationLinear = 1.0f;
    snapshot.limiterCeilingLinear = db_to_linear(-0.2f);
    snapshot.limiterAttackMs = 0.1f;
    snapshot.limiterReleaseMs = 20.0f;
    snapshot.limiterLookAheadMs = 2.0f;
    refresh_derived_state(&snapshot);
    return snapshot;
}

bool N60ProtectionSnapshotSetOversamplingFactor(N60ProtectionSnapshot *snapshot, N60OversamplingFactor factor) {
    if (snapshot == NULL || !factor_is_valid(factor)) return false;
    snapshot->oversamplingFactor = factor;
    refresh_derived_state(snapshot);
    return N60ProtectionSnapshotIsValid(snapshot);
}

bool N60ProtectionSnapshotSetSoftClipper(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float driveDB,
    float thresholdDB,
    float kneeSmooth,
    N60ClipperCurveType curve,
    bool autoCompensateGain
) {
    if (snapshot == NULL
        || !isfinite(driveDB) || driveDB < 0.0f || driveDB > 12.0f
        || !isfinite(thresholdDB) || thresholdDB < -6.0f || thresholdDB > 0.0f
        || !isfinite(kneeSmooth) || kneeSmooth < 0.0f || kneeSmooth > 1.0f
        || curve < N60ClipperCurveQuadratic || curve > N60ClipperCurveAsymmetricTube) {
        return false;
    }
    snapshot->softClipperEnabled = enabled;
    snapshot->clipperDriveLinear = db_to_linear(driveDB);
    snapshot->clipperThresholdLinear = db_to_linear(thresholdDB);
    snapshot->clipperKneeSmooth = kneeSmooth;
    snapshot->clipperCurve = curve;
    snapshot->clipperCompensationLinear = autoCompensateGain ? 1.0f / snapshot->clipperDriveLinear : 1.0f;
    refresh_derived_state(snapshot);
    return N60ProtectionSnapshotIsValid(snapshot);
}

bool N60ProtectionSnapshotSetLimiter(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float ceilingDB,
    float attackMs,
    float releaseMs,
    float lookAheadMs
) {
    if (snapshot == NULL
        || !isfinite(ceilingDB) || ceilingDB < -20.0f || ceilingDB > 0.0f
        || !isfinite(attackMs) || attackMs < 0.1f || attackMs > 50.0f
        || !isfinite(releaseMs) || releaseMs < 5.0f || releaseMs > 500.0f
        || !isfinite(lookAheadMs) || lookAheadMs < 0.0f || lookAheadMs > N60_PROTECTION_MAX_LOOKAHEAD_MS) {
        return false;
    }
    snapshot->limiterEnabled = enabled;
    snapshot->limiterCeilingLinear = db_to_linear(ceilingDB);
    snapshot->limiterAttackMs = attackMs;
    snapshot->limiterReleaseMs = releaseMs;
    snapshot->limiterLookAheadMs = lookAheadMs;
    refresh_derived_state(snapshot);
    return N60ProtectionSnapshotIsValid(snapshot);
}

bool N60ProtectionSnapshotIsValid(const N60ProtectionSnapshot *snapshot) {
    if (snapshot == NULL
        || !isfinite(snapshot->sampleRate)
        || snapshot->sampleRate <= 0.0
        || snapshot->sampleRate > N60_PROTECTION_MAX_SAMPLE_RATE
        || !factor_is_valid(snapshot->oversamplingFactor)
        || !factor_is_valid(snapshot->effectiveFactor)
        || snapshot->limiterLookAheadHighSamples > N60_PROTECTION_MAX_LOOKAHEAD_HIGH_SAMPLES) {
        return false;
    }
    return isfinite(snapshot->clipperDriveLinear) && snapshot->clipperDriveLinear > 0.0f
        && isfinite(snapshot->clipperThresholdLinear) && snapshot->clipperThresholdLinear > 0.0f
        && snapshot->clipperThresholdLinear <= 1.0f
        && isfinite(snapshot->clipperKneeSmooth)
        && snapshot->clipperKneeSmooth >= 0.0f && snapshot->clipperKneeSmooth <= 1.0f
        && snapshot->clipperCurve >= N60ClipperCurveQuadratic
        && snapshot->clipperCurve <= N60ClipperCurveAsymmetricTube
        && isfinite(snapshot->clipperCompensationLinear) && snapshot->clipperCompensationLinear > 0.0f
        && isfinite(snapshot->limiterCeilingLinear) && snapshot->limiterCeilingLinear > 0.0f
        && snapshot->limiterCeilingLinear <= 1.0f
        && isfinite(snapshot->limiterAttackMs)
        && isfinite(snapshot->limiterReleaseMs)
        && isfinite(snapshot->limiterLookAheadMs)
        && isfinite(snapshot->limiterReleaseCoefficientHigh);
}

uint32_t N60ProtectionSnapshotLatencyFrames(const N60ProtectionSnapshot *snapshot) {
    return snapshot != NULL ? snapshot->latencyFrames : 0u;
}

N60ProtectionRuntime *N60ProtectionRuntimeCreate(void) {
    N60ProtectionRuntime *runtime = calloc(1, sizeof(N60ProtectionRuntime));
    if (runtime != NULL) N60ProtectionRuntimeReset(runtime);
    return runtime;
}

void N60ProtectionRuntimeDestroy(N60ProtectionRuntime *runtime) {
    free(runtime);
}

void N60ProtectionRuntimeReset(N60ProtectionRuntime *runtime) {
    if (runtime == NULL) return;
    memset(runtime, 0, sizeof(*runtime));
    runtime->limiterGain = 1.0f;
}

void N60ProtectionRuntimeBeginBuffer(N60ProtectionRuntime *runtime) {
    if (runtime == NULL) return;
    runtime->telemetry.inputTruePeakLinear = 0.0f;
    runtime->telemetry.outputTruePeakLinear = 0.0f;
    runtime->telemetry.limiterGainReductionDB = 0.0f;
    runtime->telemetry.limiterSafetyClampSamples = 0u;
}

N60ProtectionTelemetry N60ProtectionRuntimeTelemetry(const N60ProtectionRuntime *runtime) {
    N60ProtectionTelemetry telemetry = {0};
    if (runtime != NULL) telemetry = runtime->telemetry;
    return telemetry;
}

static float fir_push(N60HalfBandFIR *fir, float input) {
    uint32_t newest = fir->writeIndex;
    fir->samples[newest] = input;
    float output = kHalfBand[N60_HALF_BAND_CENTER]
        * fir->samples[(newest + N60_HALF_BAND_TAPS - N60_HALF_BAND_CENTER) % N60_HALF_BAND_TAPS];
    for (uint32_t tap = 1u; tap < N60_HALF_BAND_TAPS; tap += 2u) {
        uint32_t index = (newest + N60_HALF_BAND_TAPS - tap) % N60_HALF_BAND_TAPS;
        output += kHalfBand[tap] * fir->samples[index];
    }
    fir->writeIndex = (newest + 1u) % N60_HALF_BAND_TAPS;
    return output;
}

static void interpolate2(N60StereoHalfBand *stage, float left, float right, float outLeft[2], float outRight[2]) {
    outLeft[0] = 2.0f * fir_push(&stage->left, left);
    outRight[0] = 2.0f * fir_push(&stage->right, right);
    outLeft[1] = 2.0f * fir_push(&stage->left, 0.0f);
    outRight[1] = 2.0f * fir_push(&stage->right, 0.0f);
}

static bool decimate2(
    N60StereoHalfBand *stage,
    uint32_t *phase,
    float left,
    float right,
    float *outLeft,
    float *outRight
) {
    float filteredLeft = fir_push(&stage->left, left);
    float filteredRight = fir_push(&stage->right, right);
    bool emit = *phase == 0u;
    *phase ^= 1u;
    if (emit) {
        *outLeft = filteredLeft;
        *outRight = filteredRight;
    }
    return emit;
}

static float curve_value(N60ClipperCurveType curve, float u, bool negative) {
    u = fminf(fmaxf(u, 0.0f), 1.0f);
    switch (curve) {
    case N60ClipperCurveCubic:
        return 1.0f - powf(1.0f - u, 3.0f);
    case N60ClipperCurveSine:
        return sinf(0.5f * N60_PI * u);
    case N60ClipperCurveAsymmetricTube:
        return negative
            ? 1.0f - powf(1.0f - u, 2.5f)
            : sinf(0.5f * N60_PI * u);
    case N60ClipperCurveQuadratic:
    default:
        return 2.0f * u - u * u;
    }
}

static float soft_clip_sample(const N60ProtectionSnapshot *snapshot, float input) {
    float driven = input * snapshot->clipperDriveLinear;
    float sign = driven < 0.0f ? -1.0f : 1.0f;
    float magnitude = fabsf(driven);
    float threshold = snapshot->clipperThresholdLinear;
    float linearLimited = fminf(magnitude, 1.0f);
    float shaped = linearLimited;
    if (magnitude > threshold) {
        float headroom = fmaxf(1.0f - threshold, 1.0e-6f);
        float u = (magnitude - threshold) / headroom;
        shaped = threshold + headroom * curve_value(snapshot->clipperCurve, u, sign < 0.0f);
        shaped = fminf(shaped, 1.0f);
    }
    float mixed = linearLimited + (shaped - linearLimited) * snapshot->clipperKneeSmooth;
    return sign * fminf(mixed, 1.0f) * snapshot->clipperCompensationLinear;
}

static uint32_t limiter_capacity(void) {
    return N60_PROTECTION_MAX_LOOKAHEAD_HIGH_SAMPLES + 1u;
}

static void deque_remove_expired(N60ProtectionRuntime *runtime, uint64_t minimumIndex) {
    uint32_t capacity = limiter_capacity();
    while (runtime->peakDequeCount > 0u
        && runtime->peakDequeIndex[runtime->peakDequeHead] < minimumIndex) {
        runtime->peakDequeHead = (runtime->peakDequeHead + 1u) % capacity;
        runtime->peakDequeCount -= 1u;
    }
}

static void deque_push(N60ProtectionRuntime *runtime, uint64_t index, float value) {
    uint32_t capacity = limiter_capacity();
    while (runtime->peakDequeCount > 0u) {
        uint32_t tail = (runtime->peakDequeHead + runtime->peakDequeCount - 1u) % capacity;
        if (runtime->peakDequeValue[tail] > value) break;
        runtime->peakDequeCount -= 1u;
    }
    uint32_t insert = (runtime->peakDequeHead + runtime->peakDequeCount) % capacity;
    runtime->peakDequeValue[insert] = value;
    runtime->peakDequeIndex[insert] = index;
    runtime->peakDequeCount += 1u;
}

static void process_limiter_high_sample(
    N60ProtectionRuntime *runtime,
    const N60ProtectionSnapshot *snapshot,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    uint32_t capacity = limiter_capacity();
    uint64_t sequence = runtime->limiterSequence;
    uint32_t writeIndex = (uint32_t)(sequence % capacity);
    runtime->limiterDelayLeft[writeIndex] = inputLeft;
    runtime->limiterDelayRight[writeIndex] = inputRight;

    float detectorPeak = fmaxf(fabsf(inputLeft), fabsf(inputRight));
    deque_push(runtime, sequence, detectorPeak);

    uint64_t outputSequence = sequence >= snapshot->limiterLookAheadHighSamples
        ? sequence - snapshot->limiterLookAheadHighSamples
        : 0u;
    deque_remove_expired(runtime, outputSequence);

    float delayedLeft = 0.0f;
    float delayedRight = 0.0f;
    if (sequence >= snapshot->limiterLookAheadHighSamples) {
        uint32_t readIndex = (uint32_t)(outputSequence % capacity);
        delayedLeft = runtime->limiterDelayLeft[readIndex];
        delayedRight = runtime->limiterDelayRight[readIndex];
    }

    float windowPeak = runtime->peakDequeCount > 0u
        ? runtime->peakDequeValue[runtime->peakDequeHead]
        : 0.0f;
    float targetGain = windowPeak > snapshot->limiterCeilingLinear
        ? snapshot->limiterCeilingLinear / fmaxf(windowPeak, N60_EPSILON)
        : 1.0f;

    if (targetGain < runtime->limiterGain) {
        float attackStep = 1.0f / (float)fmax(1u, snapshot->limiterAttackHighSamples);
        runtime->limiterGain = fmaxf(targetGain, runtime->limiterGain - attackStep);
    } else {
        float release = snapshot->limiterReleaseCoefficientHigh;
        runtime->limiterGain = targetGain + release * (runtime->limiterGain - targetGain);
    }

    float left = delayedLeft * runtime->limiterGain;
    float right = delayedRight * runtime->limiterGain;
    float safetyPeak = fmaxf(fabsf(left), fabsf(right));
    if (safetyPeak > snapshot->limiterCeilingLinear) {
        float safetyGain = snapshot->limiterCeilingLinear / fmaxf(safetyPeak, N60_EPSILON);
        left *= safetyGain;
        right *= safetyGain;
        runtime->telemetry.limiterSafetyClampSamples += 1u;
    }

    float reductionDB = -linear_to_db(fminf(runtime->limiterGain, 1.0f));
    runtime->telemetry.limiterGainReductionDB = fmaxf(runtime->telemetry.limiterGainReductionDB, reductionDB);
    *outputLeft = left;
    *outputRight = right;
    runtime->limiterSequence = sequence + 1u;
}

static void process_high_sample(
    N60ProtectionRuntime *runtime,
    const N60ProtectionSnapshot *snapshot,
    float *left,
    float *right
) {
    float inputPeak = fmaxf(fabsf(*left), fabsf(*right));
    runtime->telemetry.inputTruePeakLinear = fmaxf(runtime->telemetry.inputTruePeakLinear, inputPeak);

    if (snapshot->softClipperEnabled) {
        *left = soft_clip_sample(snapshot, *left);
        *right = soft_clip_sample(snapshot, *right);
    }
    if (snapshot->limiterEnabled) {
        float limitedLeft = 0.0f;
        float limitedRight = 0.0f;
        process_limiter_high_sample(runtime, snapshot, *left, *right, &limitedLeft, &limitedRight);
        *left = limitedLeft;
        *right = limitedRight;
    }

    float outputPeak = fmaxf(fabsf(*left), fabsf(*right));
    runtime->telemetry.outputTruePeakLinear = fmaxf(runtime->telemetry.outputTruePeakLinear, outputPeak);
}

void N60ProtectionProcessStereoFrame(
    N60ProtectionRuntime *runtime,
    const N60ProtectionSnapshot *snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || snapshot == NULL || left == NULL || right == NULL) return;

    N60OversamplingFactor factor = snapshot->effectiveFactor;
    if (factor == N60OversamplingFactor1x) {
        process_high_sample(runtime, snapshot, left, right);
        return;
    }

    float level1Left[2];
    float level1Right[2];
    interpolate2(&runtime->upStage1, *left, *right, level1Left, level1Right);

    if (factor == N60OversamplingFactor2x) {
        for (uint32_t index = 0; index < 2u; ++index) {
            process_high_sample(runtime, snapshot, &level1Left[index], &level1Right[index]);
        }
        float outputLeft = 0.0f;
        float outputRight = 0.0f;
        for (uint32_t index = 0; index < 2u; ++index) {
            if (decimate2(&runtime->downStage1, &runtime->downStage1Phase,
                          level1Left[index], level1Right[index], &outputLeft, &outputRight)) {
                *left = outputLeft;
                *right = outputRight;
            }
        }
        return;
    }

    float highLeft[4];
    float highRight[4];
    for (uint32_t level1 = 0; level1 < 2u; ++level1) {
        float pairLeft[2];
        float pairRight[2];
        interpolate2(&runtime->upStage2, level1Left[level1], level1Right[level1], pairLeft, pairRight);
        highLeft[level1 * 2u] = pairLeft[0];
        highLeft[level1 * 2u + 1u] = pairLeft[1];
        highRight[level1 * 2u] = pairRight[0];
        highRight[level1 * 2u + 1u] = pairRight[1];
    }
    for (uint32_t index = 0; index < 4u; ++index) {
        process_high_sample(runtime, snapshot, &highLeft[index], &highRight[index]);
    }

    float level1DownLeft[2] = {0.0f, 0.0f};
    float level1DownRight[2] = {0.0f, 0.0f};
    uint32_t emitted = 0u;
    for (uint32_t index = 0; index < 4u; ++index) {
        float downLeft = 0.0f;
        float downRight = 0.0f;
        if (decimate2(&runtime->downStage2, &runtime->downStage2Phase,
                      highLeft[index], highRight[index], &downLeft, &downRight)) {
            if (emitted < 2u) {
                level1DownLeft[emitted] = downLeft;
                level1DownRight[emitted] = downRight;
            }
            emitted += 1u;
        }
    }

    float outputLeft = 0.0f;
    float outputRight = 0.0f;
    for (uint32_t index = 0; index < 2u; ++index) {
        if (decimate2(&runtime->downStage1, &runtime->downStage1Phase,
                      level1DownLeft[index], level1DownRight[index], &outputLeft, &outputRight)) {
            *left = outputLeft;
            *right = outputRight;
        }
    }
}
