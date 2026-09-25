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
#define N60_DC_CUTOFF_HZ 0.5
#define N60_LOUDNESS_LOW_SHELF_HZ 120.0
#define N60_LOUDNESS_HIGH_SHELF_HZ 8000.0
#define N60_LOUDNESS_MAX_BASS_DB 6.0
#define N60_LOUDNESS_MAX_TREBLE_DB 3.0
#define N60_LOUDNESS_K_HIGH_PASS_HZ 38.13547087602444
#define N60_LOUDNESS_K_HIGH_PASS_Q 0.5003270373238773
#define N60_LOUDNESS_K_SHELF_HZ 1681.974450955533
#define N60_LOUDNESS_K_SHELF_Q 0.7071752369554196
#define N60_LOUDNESS_K_SHELF_DB 3.999843853973347
#define N60_LOUDNESS_MEASUREMENT_SECONDS 3.0
#define N60_LOUDNESS_GATE_LUFS -60.0f
#define N60_LOUDNESS_FULL_CONTOUR_DB -30.0f
#define N60_LOUDNESS_FLAT_CONTOUR_DB -6.0f

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

    snapshot.stereoMode.mode = N60StereoModeStereo;
    snapshot.stereoWidener.enabled = false;
    snapshot.stereoWidener.monoLowBand = true;
    snapshot.stereoWidener.lowMidFrequencyHz = 200.0;
    snapshot.stereoWidener.midHighFrequencyHz = 4000.0;
    snapshot.stereoWidener.lowWidth = 0.0f;
    snapshot.stereoWidener.midWidth = 1.0f;
    snapshot.stereoWidener.highWidth = 1.0f;
    snapshot.stereoWidener.sectionCount = 0;
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        snapshot.stereoWidener.lowPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.stereoWidener.highPass[index] = N60BiquadCoefficientsMakeIdentity();
    }

    snapshot.dcOffsetFilter.enabled = false;
    snapshot.dcOffsetFilter.poleCoefficient = (float)exp(-2.0 * M_PI * N60_DC_CUTOFF_HZ / sampleRate);

    snapshot.infrasonicFilter.enabled = false;
    snapshot.infrasonicFilter.cutoffHz = 18.0;
    snapshot.infrasonicFilter.slope = N60InfrasonicSlope48DBPerOctave;
    snapshot.infrasonicFilter.sectionCount = 0;
    for (uint32_t index = 0; index < N60_MAX_INFRASONIC_SECTIONS; ++index) {
        snapshot.infrasonicFilter.highPass[index] = N60BiquadCoefficientsMakeIdentity();
    }

    snapshot.loudnessMatch.enabled = false;
    snapshot.loudnessMatch.dialogueGateEnabled = false;
    snapshot.loudnessMatch.targetLUFS = -16.0f;
    snapshot.loudnessMatch.maxCorrectionDB = 12.0f;
    snapshot.loudnessMatch.attackCoefficient = coefficient_for_time_ms(sampleRate, 1000.0f);
    snapshot.loudnessMatch.releaseCoefficient = coefficient_for_time_ms(sampleRate, 3000.0f);
    snapshot.loudnessMatch.measurementCoefficient = (float)exp(-1.0 / (sampleRate * N60_LOUDNESS_MEASUREMENT_SECONDS));
    snapshot.loudnessMatch.kWeightHighPass = N60BiquadCoefficientsMakeIdentity();
    snapshot.loudnessMatch.kWeightShelf = N60BiquadCoefficientsMakeIdentity();

    snapshot.loudnessContour.enabled = false;
    snapshot.loudnessContour.strength = 1.0f;
    snapshot.loudnessContour.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);
    snapshot.loudnessContour.flatContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FLAT_CONTOUR_DB);
    snapshot.loudnessContour.lowShelf = N60BiquadCoefficientsMakeIdentity();
    snapshot.loudnessContour.highShelf = N60BiquadCoefficientsMakeIdentity();

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


bool N60DynamicsSnapshotSetStereoMode(
    N60DynamicsSnapshot *snapshot,
    N60StereoMode mode
) {
    if (snapshot == NULL) return false;
    if (mode != N60StereoModeStereo
        && mode != N60StereoModeWideMono
        && mode != N60StereoModeTrueMono) return false;
    snapshot->stereoMode.mode = mode;
    return true;
}

bool N60DynamicsSnapshotSetStereoWidener(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    bool monoLowBand,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    float lowWidth,
    float midWidth,
    float highWidth
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(lowMidFrequencyHz) || lowMidFrequencyHz < 80.0 || lowMidFrequencyHz > 500.0
        || !isfinite(midHighFrequencyHz) || midHighFrequencyHz < 1500.0 || midHighFrequencyHz > 8000.0
        || lowMidFrequencyHz >= midHighFrequencyHz || midHighFrequencyHz >= sampleRate * 0.45
        || !isfinite(lowWidth) || lowWidth < 0.0f || lowWidth > 1.0f
        || !isfinite(midWidth) || midWidth < 1.0f || midWidth > 2.0f
        || !isfinite(highWidth) || highWidth < 1.0f || highWidth > 2.0f) return false;

    double qValues[N60_MAX_CROSSOVER_SECTIONS] = {0};
    uint32_t sectionCount = 0;
    if (!N60CrossoverTopologyQValues(N60CrossoverTopologyLinkwitzRiley24, qValues, &sectionCount)) return false;

    N60StereoWidenerSnapshot configured = {0};
    configured.enabled = enabled;
    configured.monoLowBand = monoLowBand;
    configured.lowMidFrequencyHz = lowMidFrequencyHz;
    configured.midHighFrequencyHz = midHighFrequencyHz;
    configured.lowWidth = lowWidth;
    configured.midWidth = midWidth;
    configured.highWidth = highWidth;
    configured.sectionCount = sectionCount;
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        configured.lowPass[index] = N60BiquadCoefficientsMakeIdentity();
        configured.highPass[index] = N60BiquadCoefficientsMakeIdentity();
    }
    for (uint32_t index = 0; index < sectionCount; ++index) {
        if (!N60BiquadDesign(N60BiquadFilterTypeLowPass, sampleRate, lowMidFrequencyHz, 0.0, qValues[index], &configured.lowPass[index])
            || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, midHighFrequencyHz, 0.0, qValues[index], &configured.highPass[index])) return false;
    }
    snapshot->stereoWidener = configured;
    return true;
}

bool N60DynamicsSnapshotSetDCOffsetFilter(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0) return false;
    N60DCOffsetFilterSnapshot configured = {0};
    configured.enabled = enabled;
    configured.poleCoefficient = (float)exp(-2.0 * M_PI * N60_DC_CUTOFF_HZ / sampleRate);
    if (!isfinite(configured.poleCoefficient) || configured.poleCoefficient <= 0.0f || configured.poleCoefficient >= 1.0f) return false;
    snapshot->dcOffsetFilter = configured;
    return true;
}

bool N60DynamicsSnapshotSetInfrasonicFilter(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double cutoffHz,
    N60InfrasonicSlope slope
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(cutoffHz) || cutoffHz < 10.0 || cutoffHz > 30.0
        || cutoffHz >= sampleRate * 0.45) return false;

    uint32_t sectionCount = 0;
    switch (slope) {
    case N60InfrasonicSlope24DBPerOctave: sectionCount = 2; break;
    case N60InfrasonicSlope48DBPerOctave: sectionCount = 4; break;
    case N60InfrasonicSlope96DBPerOctave: sectionCount = 8; break;
    default: return false;
    }

    N60InfrasonicFilterSnapshot configured = {0};
    configured.enabled = enabled;
    configured.cutoffHz = cutoffHz;
    configured.slope = slope;
    configured.sectionCount = sectionCount;
    for (uint32_t index = 0; index < N60_MAX_INFRASONIC_SECTIONS; ++index) {
        configured.highPass[index] = N60BiquadCoefficientsMakeIdentity();
    }

    // Exact even-order Butterworth pole-pair Q values. For order N and
    // section k, Q = 1 / (2*cos((2k+1)*pi/(2N))). Coefficients are prepared
    // on the control plane; the realtime callback only consumes them.
    uint32_t order = sectionCount * 2;
    for (uint32_t index = 0; index < sectionCount; ++index) {
        double angle = ((2.0 * (double)index + 1.0) * M_PI) / (2.0 * (double)order);
        double q = 1.0 / (2.0 * cos(angle));
        if (!isfinite(q) || q <= 0.0
            || !N60BiquadDesign(
                N60BiquadFilterTypeHighPass,
                sampleRate,
                cutoffHz,
                0.0,
                q,
                &configured.highPass[index])) return false;
    }
    snapshot->infrasonicFilter = configured;
    return true;
}

bool N60DynamicsSnapshotSetLoudnessMatch(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    bool dialogueGateEnabled,
    float targetLUFS,
    float maxCorrectionDB,
    float attackSeconds,
    float releaseSeconds
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(targetLUFS) || targetLUFS < -24.0f || targetLUFS > -10.0f
        || !isfinite(maxCorrectionDB) || maxCorrectionDB < 3.0f || maxCorrectionDB > 20.0f
        || !isfinite(attackSeconds) || attackSeconds < 0.3f || attackSeconds > 5.0f
        || !isfinite(releaseSeconds) || releaseSeconds < 1.0f || releaseSeconds > 10.0f
        || N60_LOUDNESS_K_SHELF_HZ >= sampleRate * 0.45) return false;

    N60LoudnessMatchSnapshot configured = {0};
    configured.enabled = enabled;
    configured.dialogueGateEnabled = dialogueGateEnabled;
    configured.targetLUFS = targetLUFS;
    configured.maxCorrectionDB = maxCorrectionDB;
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, attackSeconds * 1000.0f);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, releaseSeconds * 1000.0f);
    configured.measurementCoefficient = (float)exp(-1.0 / (sampleRate * N60_LOUDNESS_MEASUREMENT_SECONDS));
    if (!valid_coefficient(configured.attackCoefficient)
        || !valid_coefficient(configured.releaseCoefficient)
        || !valid_coefficient(configured.measurementCoefficient)
        || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, N60_LOUDNESS_K_HIGH_PASS_HZ, 0.0, N60_LOUDNESS_K_HIGH_PASS_Q, &configured.kWeightHighPass)
        || !N60BiquadDesign(N60BiquadFilterTypeHighShelf, sampleRate, N60_LOUDNESS_K_SHELF_HZ, N60_LOUDNESS_K_SHELF_DB, N60_LOUDNESS_K_SHELF_Q, &configured.kWeightShelf)) return false;
    snapshot->loudnessMatch = configured;
    return true;
}

bool N60DynamicsSnapshotSetLoudnessContour(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    float strength
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(strength) || strength < 0.0f || strength > 1.0f
        || N60_LOUDNESS_HIGH_SHELF_HZ >= sampleRate * 0.45) return false;
    N60LoudnessContourSnapshot configured = {0};
    configured.enabled = enabled;
    configured.strength = strength;
    configured.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);
    configured.flatContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FLAT_CONTOUR_DB);
    double bassDB = N60_LOUDNESS_MAX_BASS_DB * strength;
    double trebleDB = N60_LOUDNESS_MAX_TREBLE_DB * strength;
    if (!N60BiquadDesign(N60BiquadFilterTypeLowShelf, sampleRate, N60_LOUDNESS_LOW_SHELF_HZ, bassDB, 0.7071067811865476, &configured.lowShelf)
        || !N60BiquadDesign(N60BiquadFilterTypeHighShelf, sampleRate, N60_LOUDNESS_HIGH_SHELF_HZ, trebleDB, 0.7071067811865476, &configured.highShelf)) return false;
    snapshot->loudnessContour = configured;
    return true;
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
    if (snapshot.stereoMode.mode != N60StereoModeStereo
        && snapshot.stereoMode.mode != N60StereoModeWideMono
        && snapshot.stereoMode.mode != N60StereoModeTrueMono) return false;
    if (!isfinite(snapshot.stereoWidener.lowMidFrequencyHz)
        || snapshot.stereoWidener.lowMidFrequencyHz < 80.0 || snapshot.stereoWidener.lowMidFrequencyHz > 500.0
        || !isfinite(snapshot.stereoWidener.midHighFrequencyHz)
        || snapshot.stereoWidener.midHighFrequencyHz < 1500.0 || snapshot.stereoWidener.midHighFrequencyHz > 8000.0
        || snapshot.stereoWidener.lowMidFrequencyHz >= snapshot.stereoWidener.midHighFrequencyHz
        || !isfinite(snapshot.stereoWidener.lowWidth) || snapshot.stereoWidener.lowWidth < 0.0f || snapshot.stereoWidener.lowWidth > 1.0f
        || !isfinite(snapshot.stereoWidener.midWidth) || snapshot.stereoWidener.midWidth < 1.0f || snapshot.stereoWidener.midWidth > 2.0f
        || !isfinite(snapshot.stereoWidener.highWidth) || snapshot.stereoWidener.highWidth < 1.0f || snapshot.stereoWidener.highWidth > 2.0f
        || snapshot.stereoWidener.sectionCount > N60_MAX_CROSSOVER_SECTIONS) return false;
    for (uint32_t index = 0; index < snapshot.stereoWidener.sectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.stereoWidener.lowPass[index])
            || !N60BiquadCoefficientsAreFinite(snapshot.stereoWidener.highPass[index])) return false;
    }
    if (!isfinite(snapshot.dcOffsetFilter.poleCoefficient) || snapshot.dcOffsetFilter.poleCoefficient <= 0.0f || snapshot.dcOffsetFilter.poleCoefficient >= 1.0f) return false;
    if (!isfinite(snapshot.infrasonicFilter.cutoffHz) || snapshot.infrasonicFilter.cutoffHz < 10.0 || snapshot.infrasonicFilter.cutoffHz > 30.0 || snapshot.infrasonicFilter.sectionCount > N60_MAX_INFRASONIC_SECTIONS) return false;
    for (uint32_t index = 0; index < snapshot.infrasonicFilter.sectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.infrasonicFilter.highPass[index])) return false;
    }
    if (!isfinite(snapshot.loudnessMatch.targetLUFS) || snapshot.loudnessMatch.targetLUFS < -24.0f || snapshot.loudnessMatch.targetLUFS > -10.0f
        || !isfinite(snapshot.loudnessMatch.maxCorrectionDB) || snapshot.loudnessMatch.maxCorrectionDB < 3.0f || snapshot.loudnessMatch.maxCorrectionDB > 20.0f
        || !valid_coefficient(snapshot.loudnessMatch.attackCoefficient)
        || !valid_coefficient(snapshot.loudnessMatch.releaseCoefficient)
        || !valid_coefficient(snapshot.loudnessMatch.measurementCoefficient)
        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessMatch.kWeightHighPass)
        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessMatch.kWeightShelf)) return false;
    if (!isfinite(snapshot.loudnessContour.strength) || snapshot.loudnessContour.strength < 0.0f || snapshot.loudnessContour.strength > 1.0f
        || !isfinite(snapshot.loudnessContour.fullContourMasterGainLinear) || snapshot.loudnessContour.fullContourMasterGainLinear <= 0.0f
        || !isfinite(snapshot.loudnessContour.flatContourMasterGainLinear) || snapshot.loudnessContour.flatContourMasterGainLinear <= snapshot.loudnessContour.fullContourMasterGainLinear
        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.lowShelf)
        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.highShelf)) return false;

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
    runtime->stereoMatrixLL = 1.0f;
    runtime->stereoMatrixRR = 1.0f;
    runtime->widenerLowWidth = 1.0f;
    runtime->widenerMidWidth = 1.0f;
    runtime->widenerHighWidth = 1.0f;
    runtime->pauseGateGain = 1.0f;
    runtime->gateOpen = true;
}


void N60DynamicsProcessPreEQStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;

    float dryLeft = *left;
    float dryRight = *right;
    float dcLeft = dryLeft - runtime->dcPreviousInputLeft + snapshot.dcOffsetFilter.poleCoefficient * runtime->dcPreviousOutputLeft;
    float dcRight = dryRight - runtime->dcPreviousInputRight + snapshot.dcOffsetFilter.poleCoefficient * runtime->dcPreviousOutputRight;
    runtime->dcPreviousInputLeft = dryLeft;
    runtime->dcPreviousInputRight = dryRight;
    runtime->dcPreviousOutputLeft = dcLeft;
    runtime->dcPreviousOutputRight = dcRight;
    float dcTarget = snapshot.dcOffsetFilter.enabled ? 1.0f : 0.0f;
    runtime->dcMix = smooth_toward(runtime->dcMix, dcTarget, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (dcLeft - dryLeft) * runtime->dcMix;
    *right = dryRight + (dcRight - dryRight) * runtime->dcMix;

    dryLeft = *left;
    dryRight = *right;
    float hpLeft = process_filter_cascade(snapshot.infrasonicFilter.highPass, runtime->infrasonicLeft, snapshot.infrasonicFilter.sectionCount, dryLeft);
    float hpRight = process_filter_cascade(snapshot.infrasonicFilter.highPass, runtime->infrasonicRight, snapshot.infrasonicFilter.sectionCount, dryRight);
    float infrasonicTarget = snapshot.infrasonicFilter.enabled ? 1.0f : 0.0f;
    runtime->infrasonicMix = smooth_toward(runtime->infrasonicMix, infrasonicTarget, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (hpLeft - dryLeft) * runtime->infrasonicMix;
    *right = dryRight + (hpRight - dryRight) * runtime->infrasonicMix;
}

static void process_stereo_mode(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    float targetLL = 1.0f, targetLR = 0.0f, targetRL = 0.0f, targetRR = 1.0f;
    if (snapshot.stereoMode.mode == N60StereoModeWideMono) {
        const float equalPower = 0.7071067811865476f;
        targetLL = targetLR = targetRL = targetRR = equalPower;
    } else if (snapshot.stereoMode.mode == N60StereoModeTrueMono) {
        targetLL = targetLR = targetRL = targetRR = 0.5f;
    }
    runtime->stereoMatrixLL = smooth_toward(runtime->stereoMatrixLL, targetLL, snapshot.bypassTransitionCoefficient);
    runtime->stereoMatrixLR = smooth_toward(runtime->stereoMatrixLR, targetLR, snapshot.bypassTransitionCoefficient);
    runtime->stereoMatrixRL = smooth_toward(runtime->stereoMatrixRL, targetRL, snapshot.bypassTransitionCoefficient);
    runtime->stereoMatrixRR = smooth_toward(runtime->stereoMatrixRR, targetRR, snapshot.bypassTransitionCoefficient);
    float inputLeft = *left;
    float inputRight = *right;
    *left = inputLeft * runtime->stereoMatrixLL + inputRight * runtime->stereoMatrixLR;
    *right = inputLeft * runtime->stereoMatrixRL + inputRight * runtime->stereoMatrixRR;
}

static void process_stereo_widener(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    N60StereoWidenerSnapshot widener = snapshot.stereoWidener;
    if (widener.sectionCount == 0) return;

    float mid = 0.5f * (*left + *right);
    float side = 0.5f * (*left - *right);
    float lowSide = process_filter_cascade(widener.lowPass, runtime->widenerLowPass, widener.sectionCount, side);
    float highSide = process_filter_cascade(widener.highPass, runtime->widenerHighPass, widener.sectionCount, side);
    float midSide = side - lowSide - highSide;

    float lowTarget = widener.enabled ? (widener.monoLowBand ? 0.0f : widener.lowWidth) : 1.0f;
    float midTarget = widener.enabled ? widener.midWidth : 1.0f;
    float highTarget = widener.enabled ? widener.highWidth : 1.0f;
    runtime->widenerLowWidth = smooth_toward(runtime->widenerLowWidth, lowTarget, snapshot.bypassTransitionCoefficient);
    runtime->widenerMidWidth = smooth_toward(runtime->widenerMidWidth, midTarget, snapshot.bypassTransitionCoefficient);
    runtime->widenerHighWidth = smooth_toward(runtime->widenerHighWidth, highTarget, snapshot.bypassTransitionCoefficient);

    float processedSide = lowSide * runtime->widenerLowWidth
        + midSide * runtime->widenerMidWidth
        + highSide * runtime->widenerHighWidth;
    *left = mid + processedSide;
    *right = mid - processedSide;
}

static void process_loudness_match(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    float weightedLeft = N60BiquadProcessSample(snapshot.loudnessMatch.kWeightHighPass, &runtime->loudnessKWeightHighPassLeft, *left);
    weightedLeft = N60BiquadProcessSample(snapshot.loudnessMatch.kWeightShelf, &runtime->loudnessKWeightShelfLeft, weightedLeft);
    float weightedRight = N60BiquadProcessSample(snapshot.loudnessMatch.kWeightHighPass, &runtime->loudnessKWeightHighPassRight, *right);
    weightedRight = N60BiquadProcessSample(snapshot.loudnessMatch.kWeightShelf, &runtime->loudnessKWeightShelfRight, weightedRight);
    float instantMeanSquare = 0.5f * (weightedLeft * weightedLeft + weightedRight * weightedRight);
    if (!runtime->loudnessMeasurementPrimed && instantMeanSquare > N60_DYNAMICS_EPSILON) {
        runtime->loudnessMeanSquare = instantMeanSquare;
        runtime->loudnessMeasurementPrimed = true;
    } else {
        runtime->loudnessMeanSquare = smooth_toward(runtime->loudnessMeanSquare, instantMeanSquare, snapshot.loudnessMatch.measurementCoefficient);
    }
    float measuredLUFS = -0.691f + 10.0f * log10f(fmaxf(runtime->loudnessMeanSquare, N60_DYNAMICS_EPSILON));
    float targetGainDB = 0.0f;
    if (snapshot.loudnessMatch.enabled && !(snapshot.loudnessMatch.dialogueGateEnabled && measuredLUFS < N60_LOUDNESS_GATE_LUFS)) {
        targetGainDB = clampf(snapshot.loudnessMatch.targetLUFS - measuredLUFS, -snapshot.loudnessMatch.maxCorrectionDB, snapshot.loudnessMatch.maxCorrectionDB);
    }
    float coefficient = targetGainDB < runtime->loudnessMatchGainDB
        ? snapshot.loudnessMatch.attackCoefficient
        : snapshot.loudnessMatch.releaseCoefficient;
    if (!snapshot.loudnessMatch.enabled) coefficient = snapshot.bypassTransitionCoefficient;
    runtime->loudnessMatchGainDB = smooth_toward(runtime->loudnessMatchGainDB, targetGainDB, coefficient);
    float gain = db_to_linear(runtime->loudnessMatchGainDB);
    *left *= gain;
    *right *= gain;
}

static void process_loudness_contour(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float masterGainLinear,
    float *left,
    float *right
) {
    float dryLeft = *left;
    float dryRight = *right;
    float wetLeft = N60BiquadProcessSample(snapshot.loudnessContour.lowShelf, &runtime->loudnessLowShelfLeft, dryLeft);
    wetLeft = N60BiquadProcessSample(snapshot.loudnessContour.highShelf, &runtime->loudnessHighShelfLeft, wetLeft);
    float wetRight = N60BiquadProcessSample(snapshot.loudnessContour.lowShelf, &runtime->loudnessLowShelfRight, dryRight);
    wetRight = N60BiquadProcessSample(snapshot.loudnessContour.highShelf, &runtime->loudnessHighShelfRight, wetRight);
    float volumeScale = 0.0f;
    if (masterGainLinear <= snapshot.loudnessContour.fullContourMasterGainLinear) {
        volumeScale = 1.0f;
    } else if (masterGainLinear < snapshot.loudnessContour.flatContourMasterGainLinear) {
        float masterDB = linear_to_db(masterGainLinear);
        volumeScale = (N60_LOUDNESS_FLAT_CONTOUR_DB - masterDB) / (N60_LOUDNESS_FLAT_CONTOUR_DB - N60_LOUDNESS_FULL_CONTOUR_DB);
        volumeScale = clampf(volumeScale, 0.0f, 1.0f);
    }
    float target = snapshot.loudnessContour.enabled ? volumeScale : 0.0f;
    runtime->loudnessMix = smooth_toward(runtime->loudnessMix, target, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (wetLeft - dryLeft) * runtime->loudnessMix;
    *right = dryRight + (wetRight - dryRight) * runtime->loudnessMix;
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

void N60DynamicsProcessCoreStereoFrameWithMasterGain(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float masterGainLinear,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;
    if (!isfinite(masterGainLinear) || masterGainLinear < 0.0f) masterGainLinear = 1.0f;

    process_stereo_mode(runtime, snapshot, left, right);
    process_stereo_widener(runtime, snapshot, left, right);
    process_loudness_match(runtime, snapshot, left, right);
    process_loudness_contour(runtime, snapshot, masterGainLinear, left, right);
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

void N60DynamicsProcessCoreStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    N60DynamicsProcessCoreStereoFrameWithMasterGain(runtime, snapshot, 1.0f, left, right);
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
    telemetry.loudnessShortTermLUFS = -0.691f + 10.0f * log10f(fmaxf(runtime->loudnessMeanSquare, N60_DYNAMICS_EPSILON));
    telemetry.loudnessMatchGainDB = runtime->loudnessMatchGainDB;
    telemetry.loudnessContourScale = runtime->loudnessMix;
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