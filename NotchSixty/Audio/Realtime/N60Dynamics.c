#include "N60Dynamics.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#define N60_DYNAMICS_EPSILON 1.0e-12f
#define N60_DYNAMICS_MIN_TIME_MS 0.05f
#define N60_DYNAMICS_MAX_TIME_MS 5000.0f
#define N60_DEESSER_RATIO 4.0f
#define N60_DEESSER_ATTACK_MS 1.0f
#define N60_DEESSER_RELEASE_MS 50.0f
#define N60_MULTIBAND_RATIO 3.0f
#define N60_MULTIBAND_KNEE_DB 6.0f
#define N60_MULTIBAND_ATTACK_MS 10.0f
#define N60_MULTIBAND_RELEASE_MS 150.0f

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

static float process_filter_cascade(
    const N60BiquadCoefficients *coefficients,
    N60BiquadState *states,
    uint32_t sectionCount,
    float input
) {
    float output = input;
    for (uint32_t index = 0; index < sectionCount; ++index) {
        output = N60BiquadProcessSample(coefficients[index], &states[index], output);
    }
    return output;
}

static float dynamics_compression_target(
    float detector,
    bool enabled,
    float thresholdDB,
    float ratio,
    float kneeWidthDB
) {
    N60CompressorSnapshot compressor = {0};
    compressor.enabled = enabled;
    compressor.thresholdDB = thresholdDB;
    compressor.ratio = ratio;
    compressor.kneeWidthDB = kneeWidthDB;
    compressor.makeupGainDB = 0.0f;
    return compressor_target_gain_db(linear_to_db(detector), compressor);
}

N60DynamicsSnapshot N60DynamicsSnapshotMakeBypassed(double sampleRate) {
    N60DynamicsSnapshot snapshot = {0};

    snapshot.deEsser.enabled = false;
    snapshot.deEsser.dynamicEQMode = true;
    snapshot.deEsser.frequencyHz = 6500.0;
    snapshot.deEsser.thresholdDB = -24.0f;
    snapshot.deEsser.ratio = N60_DEESSER_RATIO;
    snapshot.deEsser.attackCoefficient = coefficient_for_time_ms(sampleRate, N60_DEESSER_ATTACK_MS);
    snapshot.deEsser.releaseCoefficient = coefficient_for_time_ms(sampleRate, N60_DEESSER_RELEASE_MS);
    snapshot.deEsser.sidechainHighPass = N60BiquadCoefficientsMakeIdentity();
    snapshot.deEsser.sidechainLowPass = N60BiquadCoefficientsMakeIdentity();

    snapshot.multibandCompressor.enabled = false;
    snapshot.multibandCompressor.lowMidFrequencyHz = 120.0;
    snapshot.multibandCompressor.midHighFrequencyHz = 3500.0;
    snapshot.multibandCompressor.topology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.multibandCompressor.sectionCount = 0;
    snapshot.multibandCompressor.thresholdDB[0] = -18.0f;
    snapshot.multibandCompressor.thresholdDB[1] = -18.0f;
    snapshot.multibandCompressor.thresholdDB[2] = -18.0f;
    snapshot.multibandCompressor.ratio = N60_MULTIBAND_RATIO;
    snapshot.multibandCompressor.kneeWidthDB = N60_MULTIBAND_KNEE_DB;
    snapshot.multibandCompressor.attackCoefficient = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_ATTACK_MS);
    snapshot.multibandCompressor.releaseCoefficient = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_RELEASE_MS);
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        snapshot.multibandCompressor.lowPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.multibandCompressor.highPass[index] = N60BiquadCoefficientsMakeIdentity();
    }

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

bool N60DynamicsSnapshotSetDeEsser(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    bool dynamicEQMode
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz < 2000.0 || frequencyHz > 10000.0
        || frequencyHz >= sampleRate * 0.45
        || !isfinite(thresholdDB) || thresholdDB < -60.0f || thresholdDB > 0.0f) {
        return false;
    }

    double lowerFrequency = frequencyHz / sqrt(2.0);
    double upperFrequency = frequencyHz * sqrt(2.0);
    upperFrequency = fmin(upperFrequency, sampleRate * 0.45);
    if (lowerFrequency <= 0.0 || upperFrequency <= lowerFrequency) return false;

    N60DeEsserSnapshot configured = {0};
    configured.enabled = enabled;
    configured.dynamicEQMode = dynamicEQMode;
    configured.frequencyHz = frequencyHz;
    configured.thresholdDB = thresholdDB;
    configured.ratio = N60_DEESSER_RATIO;
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, N60_DEESSER_ATTACK_MS);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, N60_DEESSER_RELEASE_MS);
    if (!valid_coefficient(configured.attackCoefficient)
        || !valid_coefficient(configured.releaseCoefficient)
        || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, lowerFrequency, 0.0, 0.7071067811865476, &configured.sidechainHighPass)
        || !N60BiquadDesign(N60BiquadFilterTypeLowPass, sampleRate, upperFrequency, 0.0, 0.7071067811865476, &configured.sidechainLowPass)) {
        return false;
    }
    snapshot->deEsser = configured;
    return true;
}

bool N60DynamicsSnapshotSetMultibandCompressor(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    N60CrossoverTopology topology,
    float lowThresholdDB,
    float midThresholdDB,
    float highThresholdDB
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(lowMidFrequencyHz) || lowMidFrequencyHz < 40.0 || lowMidFrequencyHz > 250.0
        || !isfinite(midHighFrequencyHz) || midHighFrequencyHz < 1000.0 || midHighFrequencyHz > 8000.0
        || lowMidFrequencyHz >= midHighFrequencyHz || midHighFrequencyHz >= sampleRate * 0.45
        || !isfinite(lowThresholdDB) || lowThresholdDB < -60.0f || lowThresholdDB > 0.0f
        || !isfinite(midThresholdDB) || midThresholdDB < -60.0f || midThresholdDB > 0.0f
        || !isfinite(highThresholdDB) || highThresholdDB < -60.0f || highThresholdDB > 0.0f) {
        return false;
    }

    double qValues[N60_MAX_CROSSOVER_SECTIONS] = {0};
    uint32_t sectionCount = 0;
    if (!N60CrossoverTopologyQValues(topology, qValues, &sectionCount)) return false;

    N60MultibandCompressorSnapshot configured = {0};
    configured.enabled = enabled;
    configured.lowMidFrequencyHz = lowMidFrequencyHz;
    configured.midHighFrequencyHz = midHighFrequencyHz;
    configured.topology = topology;
    configured.sectionCount = sectionCount;
    configured.thresholdDB[0] = lowThresholdDB;
    configured.thresholdDB[1] = midThresholdDB;
    configured.thresholdDB[2] = highThresholdDB;
    configured.ratio = N60_MULTIBAND_RATIO;
    configured.kneeWidthDB = N60_MULTIBAND_KNEE_DB;
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_ATTACK_MS);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_RELEASE_MS);
    if (!valid_coefficient(configured.attackCoefficient) || !valid_coefficient(configured.releaseCoefficient)) return false;

    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        configured.lowPass[index] = N60BiquadCoefficientsMakeIdentity();
        configured.highPass[index] = N60BiquadCoefficientsMakeIdentity();
    }
    for (uint32_t index = 0; index < sectionCount; ++index) {
        if (!N60BiquadDesign(
                N60BiquadFilterTypeLowPass,
                sampleRate,
                lowMidFrequencyHz,
                0.0,
                qValues[index],
                &configured.lowPass[index])
            || !N60BiquadDesign(
                N60BiquadFilterTypeHighPass,
                sampleRate,
                midHighFrequencyHz,
                0.0,
                qValues[index],
                &configured.highPass[index])) {
            return false;
        }
    }

    snapshot->multibandCompressor = configured;
    return true;
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

    if (!isfinite(snapshot.deEsser.frequencyHz)
        || snapshot.deEsser.frequencyHz < 2000.0 || snapshot.deEsser.frequencyHz > 10000.0
        || !isfinite(snapshot.deEsser.thresholdDB)
        || snapshot.deEsser.thresholdDB < -60.0f || snapshot.deEsser.thresholdDB > 0.0f
        || snapshot.deEsser.ratio < 1.0f
        || !valid_coefficient(snapshot.deEsser.attackCoefficient)
        || !valid_coefficient(snapshot.deEsser.releaseCoefficient)
        || !N60BiquadCoefficientsAreFinite(snapshot.deEsser.sidechainHighPass)
        || !N60BiquadCoefficientsAreFinite(snapshot.deEsser.sidechainLowPass)) return false;

    if (!isfinite(snapshot.multibandCompressor.lowMidFrequencyHz)
        || !isfinite(snapshot.multibandCompressor.midHighFrequencyHz)
        || snapshot.multibandCompressor.lowMidFrequencyHz >= snapshot.multibandCompressor.midHighFrequencyHz
        || snapshot.multibandCompressor.sectionCount > N60_MAX_CROSSOVER_SECTIONS
        || snapshot.multibandCompressor.ratio < 1.0f
        || !isfinite(snapshot.multibandCompressor.kneeWidthDB)
        || !valid_coefficient(snapshot.multibandCompressor.attackCoefficient)
        || !valid_coefficient(snapshot.multibandCompressor.releaseCoefficient)) return false;
    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        if (!isfinite(snapshot.multibandCompressor.thresholdDB[band])
            || snapshot.multibandCompressor.thresholdDB[band] < -60.0f
            || snapshot.multibandCompressor.thresholdDB[band] > 0.0f) return false;
    }
    for (uint32_t index = 0; index < snapshot.multibandCompressor.sectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.lowPass[index])
            || !N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.highPass[index])) return false;
    }

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
    memset(runtime, 0, sizeof(*runtime));
    runtime->pauseGateGain = 1.0f;
    runtime->gateOpen = true;
}

static void process_de_esser(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    float dryLeft = *left;
    float dryRight = *right;
    float bandLeft = N60BiquadProcessSample(
        snapshot.deEsser.sidechainHighPass,
        &runtime->deEsserHighPassLeft,
        dryLeft
    );
    bandLeft = N60BiquadProcessSample(
        snapshot.deEsser.sidechainLowPass,
        &runtime->deEsserLowPassLeft,
        bandLeft
    );
    float bandRight = N60BiquadProcessSample(
        snapshot.deEsser.sidechainHighPass,
        &runtime->deEsserHighPassRight,
        dryRight
    );
    bandRight = N60BiquadProcessSample(
        snapshot.deEsser.sidechainLowPass,
        &runtime->deEsserLowPassRight,
        bandRight
    );

    float detector = fmaxf(fabsf(bandLeft), fabsf(bandRight));
    float targetDB = dynamics_compression_target(
        detector,
        snapshot.deEsser.enabled,
        snapshot.deEsser.thresholdDB,
        snapshot.deEsser.ratio,
        3.0f
    );
    float coefficient = !snapshot.deEsser.enabled
        ? snapshot.bypassTransitionCoefficient
        : (targetDB < runtime->deEsserGainDB
            ? snapshot.deEsser.attackCoefficient
            : snapshot.deEsser.releaseCoefficient);
    runtime->deEsserGainDB = smooth_toward(runtime->deEsserGainDB, targetDB, coefficient);
    float gain = db_to_linear(runtime->deEsserGainDB);

    if (snapshot.deEsser.dynamicEQMode) {
        *left = dryLeft + (gain - 1.0f) * bandLeft;
        *right = dryRight + (gain - 1.0f) * bandRight;
    } else {
        *left = dryLeft * gain;
        *right = dryRight * gain;
    }
}

static void process_multiband_compressor(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    N60MultibandCompressorSnapshot multiband = snapshot.multibandCompressor;
    if (multiband.sectionCount == 0) return;

    float dryLeft = *left;
    float dryRight = *right;
    float lowLeft = process_filter_cascade(
        multiband.lowPass,
        runtime->multibandLowPassLeft,
        multiband.sectionCount,
        dryLeft
    );
    float lowRight = process_filter_cascade(
        multiband.lowPass,
        runtime->multibandLowPassRight,
        multiband.sectionCount,
        dryRight
    );
    float highLeft = process_filter_cascade(
        multiband.highPass,
        runtime->multibandHighPassLeft,
        multiband.sectionCount,
        dryLeft
    );
    float highRight = process_filter_cascade(
        multiband.highPass,
        runtime->multibandHighPassRight,
        multiband.sectionCount,
        dryRight
    );

    // Residual-complement mid band guarantees sample-exact unity recombination
    // when all three gains are 0 dB, while the outer legs retain LR slopes.
    float midLeft = dryLeft - lowLeft - highLeft;
    float midRight = dryRight - lowRight - highRight;
    const float bandLeft[N60_MULTIBAND_BAND_COUNT] = {lowLeft, midLeft, highLeft};
    const float bandRight[N60_MULTIBAND_BAND_COUNT] = {lowRight, midRight, highRight};
    float outputLeft = 0.0f;
    float outputRight = 0.0f;

    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        float detector = fmaxf(fabsf(bandLeft[band]), fabsf(bandRight[band]));
        float targetDB = dynamics_compression_target(
            detector,
            multiband.enabled,
            multiband.thresholdDB[band],
            multiband.ratio,
            multiband.kneeWidthDB
        );
        float coefficient = !multiband.enabled
            ? snapshot.bypassTransitionCoefficient
            : (targetDB < runtime->multibandGainDB[band]
                ? multiband.attackCoefficient
                : multiband.releaseCoefficient);
        runtime->multibandGainDB[band] = smooth_toward(
            runtime->multibandGainDB[band],
            targetDB,
            coefficient
        );
        float gain = db_to_linear(runtime->multibandGainDB[band]);
        outputLeft += bandLeft[band] * gain;
        outputRight += bandRight[band] * gain;
    }

    *left = outputLeft;
    *right = outputRight;
}

void N60DynamicsProcessCoreStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;

    process_de_esser(runtime, snapshot, left, right);
    process_multiband_compressor(runtime, snapshot, left, right);

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
    telemetry.deEsserGainReductionDB = fmaxf(0.0f, -runtime->deEsserGainDB);
    telemetry.multibandLowGainReductionDB = fmaxf(0.0f, -runtime->multibandGainDB[0]);
    telemetry.multibandMidGainReductionDB = fmaxf(0.0f, -runtime->multibandGainDB[1]);
    telemetry.multibandHighGainReductionDB = fmaxf(0.0f, -runtime->multibandGainDB[2]);
    telemetry.compressorGainReductionDB = fmaxf(0.0f, -runtime->compressorGainDB);
    telemetry.expanderAttenuationDB = fmaxf(0.0f, -runtime->expanderGainDB);
    telemetry.pauseGateGain = runtime->pauseGateGain;
    telemetry.pauseGateOpen = runtime->gateOpen;
    return telemetry;
}