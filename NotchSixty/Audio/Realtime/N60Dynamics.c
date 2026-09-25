#include "N60Dynamics.h"

#include <math.h>
#include <stddef.h>

#define N60_DYNAMICS_EPSILON 1.0e-12f
#define N60_DYNAMICS_MIN_TIME_MS 0.05f
#define N60_DYNAMICS_MAX_TIME_MS 5000.0f

static float clampf(float value, float minimum, float maximum) {
    return fminf(fmaxf(value, minimum), maximum);
}

static float coefficient_for_time_ms(double sampleRate, float timeMs) {
    if (!isfinite(sampleRate) || sampleRate <= 0.0 || !isfinite(timeMs)) return NAN;
    float safeTimeMs = clampf(timeMs, N60_DYNAMICS_MIN_TIME_MS, N60_DYNAMICS_MAX_TIME_MS);
    double samples = sampleRate * ((double)safeTimeMs / 1000.0);
    return (float)exp(-1.0 / samples);
}

static float db_to_linear(float db) {
    return powf(10.0f, db / 20.0f);
}

static float linear_to_db(float linear) {
    return 20.0f * log10f(fmaxf(linear, N60_DYNAMICS_EPSILON));
}

static bool valid_coefficient(float coefficient) {
    return isfinite(coefficient) && coefficient >= 0.0f && coefficient < 1.0f;
}

static float smooth_toward(float current, float target, float coefficient) {
    return target + coefficient * (current - target);
}

static float compressor_target_gain_db(float detectorDB, N60CompressorSnapshot snapshot) {
    if (!snapshot.enabled) return 0.0f;
    float over = detectorDB - snapshot.thresholdDB;
    float slope = (1.0f / snapshot.ratio) - 1.0f;
    float compressionDB = 0.0f;

    if (snapshot.kneeWidthDB <= 0.0f) {
        if (over > 0.0f) compressionDB = slope * over;
    } else {
        float halfKnee = snapshot.kneeWidthDB * 0.5f;
        if (over >= halfKnee) {
            compressionDB = slope * over;
        } else if (over > -halfKnee) {
            float kneePosition = over + halfKnee;
            compressionDB = slope * kneePosition * kneePosition / (2.0f * snapshot.kneeWidthDB);
        }
    }
    return compressionDB + snapshot.makeupGainDB;
}

static float expander_target_gain_db(float detectorDB, N60ExpanderSnapshot snapshot) {
    if (!snapshot.enabled || detectorDB >= snapshot.thresholdDB) return 0.0f;
    float gainDB = (snapshot.ratio - 1.0f) * (detectorDB - snapshot.thresholdDB);
    return fmaxf(gainDB, snapshot.rangeDB);
}

N60DynamicsSnapshot N60DynamicsSnapshotMakeBypassed(double sampleRate) {
    N60DynamicsSnapshot snapshot = {0};
    snapshot.compressor.enabled = false;
    snapshot.compressor.ratio = 1.0f;
    snapshot.compressor.attackCoefficient = coefficient_for_time_ms(sampleRate, 10.0f);
    snapshot.compressor.releaseCoefficient = coefficient_for_time_ms(sampleRate, 100.0f);

    snapshot.expander.enabled = false;
    snapshot.expander.ratio = 1.0f;
    snapshot.expander.rangeDB = 0.0f;
    snapshot.expander.attackCoefficient = coefficient_for_time_ms(sampleRate, 5.0f);
    snapshot.expander.releaseCoefficient = coefficient_for_time_ms(sampleRate, 100.0f);

    snapshot.pauseGate.enabled = false;
    snapshot.pauseGate.thresholdDBFS = -60.0f;
    snapshot.pauseGate.hysteresisDB = 3.0f;
    snapshot.pauseGate.fadeOutCoefficient = coefficient_for_time_ms(sampleRate, 10.0f);
    snapshot.pauseGate.fadeInCoefficient = coefficient_for_time_ms(sampleRate, 200.0f);
    snapshot.pauseGate.detectorAttackCoefficient = coefficient_for_time_ms(sampleRate, 1.0f);
    snapshot.pauseGate.detectorReleaseCoefficient = coefficient_for_time_ms(sampleRate, 10.0f);
    snapshot.bypassTransitionCoefficient = coefficient_for_time_ms(sampleRate, 5.0f);
    return snapshot;
}

bool N60DynamicsSnapshotSetCompressor(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float kneeWidthDB,
    float attackMs,
    float releaseMs,
    float makeupGainDB
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(thresholdDB) || thresholdDB < -96.0f || thresholdDB > 0.0f
        || !isfinite(ratio) || ratio < 1.0f || ratio > 100.0f
        || !isfinite(kneeWidthDB) || kneeWidthDB < 0.0f || kneeWidthDB > 24.0f
        || !isfinite(attackMs) || attackMs < 0.05f || attackMs > 1000.0f
        || !isfinite(releaseMs) || releaseMs < 1.0f || releaseMs > 5000.0f
        || !isfinite(makeupGainDB) || makeupGainDB < -24.0f || makeupGainDB > 24.0f) {
        return false;
    }
    N60CompressorSnapshot configured = {0};
    configured.enabled = enabled;
    configured.thresholdDB = thresholdDB;
    configured.ratio = ratio;
    configured.kneeWidthDB = kneeWidthDB;
    configured.makeupGainDB = makeupGainDB;
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, attackMs);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, releaseMs);
    if (!valid_coefficient(configured.attackCoefficient) || !valid_coefficient(configured.releaseCoefficient)) return false;
    snapshot->compressor = configured;
    return true;
}

bool N60DynamicsSnapshotSetExpander(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float attackMs,
    float releaseMs
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(thresholdDB) || thresholdDB < -120.0f || thresholdDB > 0.0f
        || !isfinite(ratio) || ratio < 1.0f || ratio > 20.0f
        || !isfinite(rangeDB) || rangeDB < -96.0f || rangeDB > 0.0f
        || !isfinite(attackMs) || attackMs < 0.05f || attackMs > 1000.0f
        || !isfinite(releaseMs) || releaseMs < 1.0f || releaseMs > 5000.0f) {
        return false;
    }
    N60ExpanderSnapshot configured = {0};
    configured.enabled = enabled;
    configured.thresholdDB = thresholdDB;
    configured.ratio = ratio;
    configured.rangeDB = rangeDB;
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, attackMs);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, releaseMs);
    if (!valid_coefficient(configured.attackCoefficient) || !valid_coefficient(configured.releaseCoefficient)) return false;
    snapshot->expander = configured;
    return true;
}

bool N60DynamicsSnapshotSetPauseGate(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDBFS,
    float holdMs,
    float fadeOutAttackMs,
    float fadeInReleaseMs,
    float hysteresisDB
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(thresholdDBFS) || thresholdDBFS < -120.0f || thresholdDBFS > -20.0f
        || !isfinite(holdMs) || holdMs < 0.0f || holdMs > 5000.0f
        || !isfinite(fadeOutAttackMs) || fadeOutAttackMs < 0.05f || fadeOutAttackMs > 1000.0f
        || !isfinite(fadeInReleaseMs) || fadeInReleaseMs < 0.05f || fadeInReleaseMs > 5000.0f
        || !isfinite(hysteresisDB) || hysteresisDB < 0.0f || hysteresisDB > 24.0f) {
        return false;
    }
    double holdFramesDouble = sampleRate * ((double)holdMs / 1000.0);
    if (!isfinite(holdFramesDouble) || holdFramesDouble > (double)UINT32_MAX) return false;

    N60PauseGateSnapshot configured = {0};
    configured.enabled = enabled;
    configured.thresholdDBFS = thresholdDBFS;
    configured.hysteresisDB = hysteresisDB;
    configured.holdFrames = (uint32_t)llround(holdFramesDouble);
    configured.fadeOutCoefficient = coefficient_for_time_ms(sampleRate, fadeOutAttackMs);
    configured.fadeInCoefficient = coefficient_for_time_ms(sampleRate, fadeInReleaseMs);
    configured.detectorAttackCoefficient = coefficient_for_time_ms(sampleRate, 1.0f);
    configured.detectorReleaseCoefficient = coefficient_for_time_ms(sampleRate, 10.0f);
    if (!valid_coefficient(configured.fadeOutCoefficient)
        || !valid_coefficient(configured.fadeInCoefficient)
        || !valid_coefficient(configured.detectorAttackCoefficient)
        || !valid_coefficient(configured.detectorReleaseCoefficient)) return false;
    snapshot->pauseGate = configured;
    return true;
}

bool N60DynamicsSnapshotIsValid(N60DynamicsSnapshot snapshot) {
    if (!valid_coefficient(snapshot.bypassTransitionCoefficient)) return false;
    if (snapshot.compressor.ratio < 1.0f || snapshot.compressor.ratio > 100.0f
        || !isfinite(snapshot.compressor.thresholdDB)
        || !isfinite(snapshot.compressor.kneeWidthDB)
        || !isfinite(snapshot.compressor.makeupGainDB)
        || !valid_coefficient(snapshot.compressor.attackCoefficient)
        || !valid_coefficient(snapshot.compressor.releaseCoefficient)) return false;
    if (snapshot.expander.ratio < 1.0f || snapshot.expander.ratio > 20.0f
        || snapshot.expander.rangeDB > 0.0f
        || !isfinite(snapshot.expander.thresholdDB)
        || !isfinite(snapshot.expander.rangeDB)
        || !valid_coefficient(snapshot.expander.attackCoefficient)
        || !valid_coefficient(snapshot.expander.releaseCoefficient)) return false;
    if (!isfinite(snapshot.pauseGate.thresholdDBFS)
        || !isfinite(snapshot.pauseGate.hysteresisDB)
        || snapshot.pauseGate.hysteresisDB < 0.0f
        || !valid_coefficient(snapshot.pauseGate.fadeOutCoefficient)
        || !valid_coefficient(snapshot.pauseGate.fadeInCoefficient)
        || !valid_coefficient(snapshot.pauseGate.detectorAttackCoefficient)
        || !valid_coefficient(snapshot.pauseGate.detectorReleaseCoefficient)) return false;
    return true;
}

void N60DynamicsRuntimeReset(N60DynamicsRuntime *runtime) {
    if (runtime == NULL) return;
    runtime->compressorGainDB = 0.0f;
    runtime->expanderGainDB = 0.0f;
    runtime->pauseGateGain = 1.0f;
    runtime->gateDetectorEnvelope = 0.0f;
    runtime->gateBelowThresholdFrames = 0;
    runtime->gateOpen = true;
}

void N60DynamicsProcessCoreStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;

    float detector = fmaxf(fabsf(*left), fabsf(*right));
    float detectorDB = linear_to_db(detector);

    float compressorTargetDB = compressor_target_gain_db(detectorDB, snapshot.compressor);
    float compressorCoefficient;
    if (!snapshot.compressor.enabled) {
        compressorCoefficient = snapshot.bypassTransitionCoefficient;
    } else {
        compressorCoefficient = compressorTargetDB < runtime->compressorGainDB
            ? snapshot.compressor.attackCoefficient
            : snapshot.compressor.releaseCoefficient;
    }
    runtime->compressorGainDB = smooth_toward(
        runtime->compressorGainDB,
        compressorTargetDB,
        compressorCoefficient
    );
    float compressorGain = db_to_linear(runtime->compressorGainDB);
    *left *= compressorGain;
    *right *= compressorGain;

    detector = fmaxf(fabsf(*left), fabsf(*right));
    detectorDB = linear_to_db(detector);
    float expanderTargetDB = expander_target_gain_db(detectorDB, snapshot.expander);
    float expanderCoefficient;
    if (!snapshot.expander.enabled) {
        expanderCoefficient = snapshot.bypassTransitionCoefficient;
    } else {
        expanderCoefficient = expanderTargetDB < runtime->expanderGainDB
            ? snapshot.expander.attackCoefficient
            : snapshot.expander.releaseCoefficient;
    }
    runtime->expanderGainDB = smooth_toward(
        runtime->expanderGainDB,
        expanderTargetDB,
        expanderCoefficient
    );
    float expanderGain = db_to_linear(runtime->expanderGainDB);
    *left *= expanderGain;
    *right *= expanderGain;
}

void N60DynamicsProcessPauseGateStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;

    float gateDetectorInput = fmaxf(fabsf(*left), fabsf(*right));
    float detectorCoefficient = gateDetectorInput > runtime->gateDetectorEnvelope
        ? snapshot.pauseGate.detectorAttackCoefficient
        : snapshot.pauseGate.detectorReleaseCoefficient;
    runtime->gateDetectorEnvelope = smooth_toward(
        runtime->gateDetectorEnvelope,
        gateDetectorInput,
        detectorCoefficient
    );

    float gateTarget = 1.0f;
    float gateCoefficient = snapshot.bypassTransitionCoefficient;
    if (snapshot.pauseGate.enabled) {
        float gateLevelDB = linear_to_db(runtime->gateDetectorEnvelope);
        float openThresholdDB = snapshot.pauseGate.thresholdDBFS + snapshot.pauseGate.hysteresisDB;
        if (!runtime->gateOpen) {
            if (gateLevelDB >= openThresholdDB) {
                runtime->gateOpen = true;
                runtime->gateBelowThresholdFrames = 0;
            }
        } else if (gateLevelDB <= snapshot.pauseGate.thresholdDBFS) {
            if (runtime->gateBelowThresholdFrames < snapshot.pauseGate.holdFrames) {
                runtime->gateBelowThresholdFrames += 1;
            }
            if (runtime->gateBelowThresholdFrames >= snapshot.pauseGate.holdFrames) {
                runtime->gateOpen = false;
            }
        } else {
            runtime->gateBelowThresholdFrames = 0;
        }

        gateTarget = runtime->gateOpen ? 1.0f : 0.0f;
        // Product contract: Attack closes/fades out; Release opens/fades in.
        gateCoefficient = gateTarget < runtime->pauseGateGain
            ? snapshot.pauseGate.fadeOutCoefficient
            : snapshot.pauseGate.fadeInCoefficient;
    } else {
        runtime->gateOpen = true;
        runtime->gateBelowThresholdFrames = 0;
    }

    runtime->pauseGateGain = smooth_toward(runtime->pauseGateGain, gateTarget, gateCoefficient);
    *left *= runtime->pauseGateGain;
    *right *= runtime->pauseGateGain;
}

void N60DynamicsProcessStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    N60DynamicsProcessCoreStereoFrame(runtime, snapshot, left, right);
    N60DynamicsProcessPauseGateStereoFrame(runtime, snapshot, left, right);
}

N60DynamicsTelemetry N60DynamicsRuntimeTelemetry(const N60DynamicsRuntime *runtime) {
    N60DynamicsTelemetry telemetry = {0};
    if (runtime == NULL) return telemetry;
    telemetry.compressorGainReductionDB = fmaxf(0.0f, -runtime->compressorGainDB);
    telemetry.expanderAttenuationDB = fmaxf(0.0f, -runtime->expanderGainDB);
    telemetry.pauseGateGain = runtime->pauseGateGain;
    telemetry.pauseGateOpen = runtime->gateOpen;
    return telemetry;
}
