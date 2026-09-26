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
#define N60_LOUDNESS_INTEGRATED_REFERENCE_LUFS -16.0f
#define N60_LOUDNESS_LOW_DB_PER_PHON 0.25f
#define N60_LOUDNESS_HIGH_DB_PER_PHON 0.125f
#define N60_LOUDNESS_LOW_CUT_DB_PER_PHON 0.15f
#define N60_LOUDNESS_HIGH_CUT_DB_PER_PHON 0.075f
#define N60_LOUDNESS_GAIN_RESPONSE_MS 50.0f
#define N60_MAINS_DETECTOR_SPAN_HZ 3.0
#define N60_MAINS_DETECTOR_BIN_SPACING_HZ 0.25
#define N60_MAINS_DETECTOR_TARGET_RATE 1000.0
#define N60_MAINS_DETECTOR_WINDOW_SECONDS 1.0
#define N60_MAINS_DETECTOR_MIN_LEVEL_DBFS -78.0
#define N60_MAINS_NOTCH_RETUNE_SECONDS 0.010

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

static N60MainsNotchCoefficients mains_notch_identity(void) {
    N60MainsNotchCoefficients coefficients = {
        .b0 = 1.0,
        .b1 = 0.0,
        .b2 = 0.0,
        .a1 = 0.0,
        .a2 = 0.0,
    };
    return coefficients;
}

static bool mains_notch_coefficients_are_finite(N60MainsNotchCoefficients coefficients) {
    return isfinite(coefficients.b0)
        && isfinite(coefficients.b1)
        && isfinite(coefficients.b2)
        && isfinite(coefficients.a1)
        && isfinite(coefficients.a2);
}

// Control-plane design for a narrow peaking cut. Double coefficients are kept
// through the realtime section because 50/60 Hz at 384 kHz is an unusually low
// normalized frequency where float coefficient quantization loses several dB of
// requested notch depth. This function is never called from the render callback.
static bool design_mains_notch(
    double sampleRate,
    double frequencyHz,
    double depthDB,
    double q,
    N60MainsNotchCoefficients *coefficients
) {
    if (coefficients == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz <= 0.0 || frequencyHz >= sampleRate * 0.5
        || !isfinite(depthDB) || depthDB < -40.0 || depthDB > 0.0
        || !isfinite(q) || q < 5.0 || q > 60.0) return false;

    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double alpha = sin(omega) / (2.0 * q);
    double A = pow(10.0, depthDB / 40.0);
    double cosOmega = cos(omega);
    double a0 = 1.0 + alpha / A;
    if (!isfinite(a0) || fabs(a0) < 1.0e-20) return false;

    N60MainsNotchCoefficients designed = {
        .b0 = (1.0 + alpha * A) / a0,
        .b1 = (-2.0 * cosOmega) / a0,
        .b2 = (1.0 - alpha * A) / a0,
        .a1 = (-2.0 * cosOmega) / a0,
        .a2 = (1.0 - alpha / A) / a0,
    };
    if (!mains_notch_coefficients_are_finite(designed)) return false;
    *coefficients = designed;
    return true;
}

static float process_mains_notch_cascade(
    const N60MainsNotchCoefficients *coefficients,
    N60MainsNotchState *states,
    uint32_t sectionCount,
    float input
) {
    double output = (double)input;
    for (uint32_t index = 0; index < sectionCount; ++index) {
        N60MainsNotchCoefficients c = coefficients[index];
        N60MainsNotchState *state = &states[index];
        double next = c.b0 * output + state->z1;
        state->z1 = c.b1 * output - c.a1 * next + state->z2;
        state->z2 = c.b2 * output - c.a2 * next;
        output = next;
    }
    return (float)output;
}

static bool mains_notch_runtime_matches_snapshot(const N60DynamicsRuntime *runtime, N60MainsNotchSnapshot snapshot) {
    if (!runtime->mainsNotchInitialized
        || runtime->mainsNotchCurrentFundamentalHz != snapshot.fundamentalHz
        || runtime->mainsNotchCurrentQ != snapshot.q
        || runtime->mainsNotchCurrentHarmonicCount != snapshot.harmonicCount) return false;
    for (uint32_t index = 0; index < snapshot.harmonicCount; ++index) {
        if (runtime->mainsNotchCurrentDepthsDB[index] != snapshot.depthsDB[index]) return false;
    }
    return true;
}

static void copy_mains_notch_snapshot_to_current(N60DynamicsRuntime *runtime, N60MainsNotchSnapshot snapshot) {
    runtime->mainsNotchCurrentFundamentalHz = snapshot.fundamentalHz;
    runtime->mainsNotchCurrentQ = snapshot.q;
    runtime->mainsNotchCurrentHarmonicCount = snapshot.harmonicCount;
    for (uint32_t index = 0; index < N60_MAX_MAINS_HARMONICS; ++index) {
        runtime->mainsNotchCurrentFilters[index] = snapshot.filters[index];
        runtime->mainsNotchCurrentDepthsDB[index] = snapshot.depthsDB[index];
        runtime->mainsNotchLeft[index].z1 = 0.0;
        runtime->mainsNotchLeft[index].z2 = 0.0;
        runtime->mainsNotchRight[index].z1 = 0.0;
        runtime->mainsNotchRight[index].z2 = 0.0;
    }
    runtime->mainsNotchInitialized = true;
}

static void promote_pending_mains_notch(N60DynamicsRuntime *runtime) {
    runtime->mainsNotchCurrentFundamentalHz = runtime->mainsNotchPendingFundamentalHz;
    runtime->mainsNotchCurrentQ = runtime->mainsNotchPendingQ;
    runtime->mainsNotchCurrentHarmonicCount = runtime->mainsNotchPendingHarmonicCount;
    for (uint32_t index = 0; index < N60_MAX_MAINS_HARMONICS; ++index) {
        runtime->mainsNotchCurrentFilters[index] = runtime->mainsNotchPendingFilters[index];
        runtime->mainsNotchCurrentDepthsDB[index] = runtime->mainsNotchPendingDepthsDB[index];
        runtime->mainsNotchLeft[index] = runtime->mainsNotchPendingLeft[index];
        runtime->mainsNotchRight[index] = runtime->mainsNotchPendingRight[index];
    }
    runtime->mainsNotchTransitionFramesTotal = 0;
    runtime->mainsNotchTransitionFramesRemaining = 0;
}

static void schedule_mains_notch_retune(N60DynamicsRuntime *runtime, N60MainsNotchSnapshot snapshot, uint32_t transitionFrames) {
    if (!runtime->mainsNotchInitialized) {
        copy_mains_notch_snapshot_to_current(runtime, snapshot);
        return;
    }
    if (runtime->mainsNotchTransitionFramesRemaining > 0) promote_pending_mains_notch(runtime);
    if (mains_notch_runtime_matches_snapshot(runtime, snapshot)) return;
    runtime->mainsNotchPendingFundamentalHz = snapshot.fundamentalHz;
    runtime->mainsNotchPendingQ = snapshot.q;
    runtime->mainsNotchPendingHarmonicCount = snapshot.harmonicCount;
    for (uint32_t index = 0; index < N60_MAX_MAINS_HARMONICS; ++index) {
        runtime->mainsNotchPendingFilters[index] = snapshot.filters[index];
        runtime->mainsNotchPendingDepthsDB[index] = snapshot.depthsDB[index];
        runtime->mainsNotchPendingLeft[index] = runtime->mainsNotchLeft[index];
        runtime->mainsNotchPendingRight[index] = runtime->mainsNotchRight[index];
    }
    runtime->mainsNotchTransitionFramesTotal = transitionFrames > 0 ? transitionFrames : 1;
    runtime->mainsNotchTransitionFramesRemaining = runtime->mainsNotchTransitionFramesTotal;
}

static void reset_mains_detector_window(N60DynamicsRuntime *runtime) {
    runtime->mainsDetectorSampleCount = 0;
    runtime->mainsDetectorWindowEnergy = 0.0;
    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        runtime->mainsDetectorOscCos[index] = 1.0;
        runtime->mainsDetectorOscSin[index] = 0.0;
        runtime->mainsDetectorReal[index] = 0.0;
        runtime->mainsDetectorImag[index] = 0.0;
    }
}

static void process_mains_hum_detector(
    N60DynamicsRuntime *runtime,
    N60MainsHumDetectorSnapshot snapshot,
    float left,
    float right
) {
    if (!snapshot.enabled || snapshot.decimationFactor == 0 || snapshot.windowSamples == 0) return;
    runtime->mainsDetectorDecimationCounter += 1;
    if (runtime->mainsDetectorDecimationCounter < snapshot.decimationFactor) return;
    runtime->mainsDetectorDecimationCounter = 0;

    double mono = 0.5 * ((double)left + (double)right);
    runtime->mainsDetectorWindowEnergy += mono * mono;
    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        double oscCos = runtime->mainsDetectorOscCos[index];
        double oscSin = runtime->mainsDetectorOscSin[index];
        runtime->mainsDetectorReal[index] += mono * oscCos;
        runtime->mainsDetectorImag[index] += mono * oscSin;
        double stepCos = (double)snapshot.oscillatorStepCos[index];
        double stepSin = (double)snapshot.oscillatorStepSin[index];
        runtime->mainsDetectorOscCos[index] = oscCos * stepCos - oscSin * stepSin;
        runtime->mainsDetectorOscSin[index] = oscSin * stepCos + oscCos * stepSin;
    }
    runtime->mainsDetectorSampleCount += 1;
    if (runtime->mainsDetectorSampleCount < snapshot.windowSamples) return;

    double powers[N60_MAINS_DETECTOR_BIN_COUNT];
    uint32_t bestIndex = 0;
    double bestPower = 0.0;
    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        double re = runtime->mainsDetectorReal[index];
        double im = runtime->mainsDetectorImag[index];
        powers[index] = re * re + im * im;
        if (powers[index] > bestPower) {
            bestPower = powers[index];
            bestIndex = index;
        }
    }

    double background = 0.0;
    uint32_t backgroundCount = 0;
    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        int distance = (int)index - (int)bestIndex;
        if (distance >= -2 && distance <= 2) continue;
        background += powers[index];
        backgroundCount += 1;
    }
    double backgroundMean = backgroundCount > 0 ? background / (double)backgroundCount : 0.0;
    double n = (double)runtime->mainsDetectorSampleCount;
    // A relative spectral peak alone is not enough evidence of mains hum: an
    // out-of-band coherent tone can create a locally prominent leakage bin.
    // Require the candidate sinusoid to explain meaningful time-domain energy
    // in the detector window as well as standing above neighboring bins.
    double candidateMeanSquare = 2.0 * bestPower / fmax(n * n, 1.0);
    double totalMeanSquare = runtime->mainsDetectorWindowEnergy / fmax(n, 1.0);
    double levelDBFS = 10.0 * log10(fmax(candidateMeanSquare, 1.0e-20));
    double prominence = bestPower > 1.0e-20 ? 1.0 - backgroundMean / bestPower : 0.0;
    prominence = fmin(fmax(prominence, 0.0), 1.0);
    double toneEnergyFraction = candidateMeanSquare / fmax(totalMeanSquare, 1.0e-20);
    toneEnergyFraction = fmin(fmax(toneEnergyFraction, 0.0), 1.0);
    double confidence = prominence * toneEnergyFraction;
    if (levelDBFS < N60_MAINS_DETECTOR_MIN_LEVEL_DBFS) confidence = 0.0;

    double fractionalBin = 0.0;
    if (bestIndex > 0 && bestIndex + 1 < N60_MAINS_DETECTOR_BIN_COUNT) {
        double leftPower = powers[bestIndex - 1];
        double centerPower = powers[bestIndex];
        double rightPower = powers[bestIndex + 1];
        double denominator = leftPower - 2.0 * centerPower + rightPower;
        if (fabs(denominator) > 1.0e-20) {
            fractionalBin = 0.5 * (leftPower - rightPower) / denominator;
            fractionalBin = fmin(fmax(fractionalBin, -0.5), 0.5);
        }
    }
    runtime->mainsDetectedFrequencyHz = (float)(
        snapshot.searchStartHz
        + ((double)bestIndex + fractionalBin) * snapshot.binSpacingHz
    );
    runtime->mainsDetectionConfidence = (float)confidence;
    reset_mains_detector_window(runtime);
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

    snapshot.mainsNotch.enabled = false;
    snapshot.mainsNotch.fundamentalHz = 60.0;
    snapshot.mainsNotch.harmonicCount = 8;
    snapshot.mainsNotch.q = 30.0f;
    for (uint32_t index = 0; index < N60_MAX_MAINS_HARMONICS; ++index) {
        snapshot.mainsNotch.depthsDB[index] = 0.0f;
        snapshot.mainsNotch.filters[index] = mains_notch_identity();
    }

    snapshot.mainsHumDetector.enabled = false;
    snapshot.mainsHumDetector.searchCenterHz = 60.0;
    snapshot.mainsHumDetector.searchStartHz = 57.0;
    snapshot.mainsHumDetector.binSpacingHz = N60_MAINS_DETECTOR_BIN_SPACING_HZ;
    snapshot.mainsHumDetector.decimationFactor = 48;
    snapshot.mainsHumDetector.windowSamples = 1000;
    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        snapshot.mainsHumDetector.oscillatorStepCos[index] = 1.0f;
        snapshot.mainsHumDetector.oscillatorStepSin[index] = 0.0f;
    }

    snapshot.spectralDenoiser = N60SpectralDenoiserSnapshotMakeBypassed(sampleRate);

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
    snapshot.loudnessContour.perBandMode = false;
    snapshot.loudnessContour.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);
    snapshot.loudnessContour.flatContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FLAT_CONTOUR_DB);
    snapshot.loudnessContour.lowShelf = N60BiquadCoefficientsMakeIdentity();
    snapshot.loudnessContour.highShelf = N60BiquadCoefficientsMakeIdentity();
    snapshot.loudnessContour.levelSource = N60LoudnessLevelSourceSystemVolume;
    snapshot.loudnessContour.referencePhons = 85.0f;
    snapshot.loudnessContour.maxBoostDB = 12.0f;
    snapshot.loudnessContour.maxCutDB = 6.0f;
    snapshot.loudnessContour.responseCoefficient = coefficient_for_time_ms(sampleRate, N60_LOUDNESS_GAIN_RESPONSE_MS);
    snapshot.loudnessContour.lowBandLowPass = N60BiquadCoefficientsMakeIdentity();
    snapshot.loudnessContour.highBandHighPass = N60BiquadCoefficientsMakeIdentity();

    snapshot.dialogueLeveler.enabled = false;
    snapshot.dialogueLeveler.voiceGateEnabled = false;
    snapshot.dialogueLeveler.bandLowHz = 300.0;
    snapshot.dialogueLeveler.bandHighHz = 3500.0;
    snapshot.dialogueLeveler.targetGapDB = 10.0f;
    snapshot.dialogueLeveler.boostRatio = 2.0f;
    snapshot.dialogueLeveler.maxBoostDB = 8.0f;
    snapshot.dialogueLeveler.programGateThresholdDB = -50.0f;
    snapshot.dialogueLeveler.detectorCoefficient = coefficient_for_time_ms(sampleRate, 300.0f);
    snapshot.dialogueLeveler.attackCoefficient = coefficient_for_time_ms(sampleRate, 150.0f);
    snapshot.dialogueLeveler.releaseCoefficient = coefficient_for_time_ms(sampleRate, 900.0f);
    snapshot.dialogueLeveler.voiceEnvelopeCoefficient = coefficient_for_time_ms(sampleRate, 15.0f);
    snapshot.dialogueLeveler.voiceMeasurementCoefficient = coefficient_for_time_ms(sampleRate, 700.0f);
    snapshot.dialogueLeveler.modulationHighPassPole = (float)exp(-2.0 * M_PI * 2.5 / sampleRate);
    snapshot.dialogueLeveler.modulationLowPassPole = (float)exp(-2.0 * M_PI * 7.5 / sampleRate);
    snapshot.dialogueLeveler.confidenceFloorIndex = 0.15f;
    snapshot.dialogueLeveler.confidenceCeilingIndex = 0.45f;
    snapshot.dialogueLeveler.minConfidence = 0.2f;
    snapshot.dialogueLeveler.bandHighPass = N60BiquadCoefficientsMakeIdentity();
    snapshot.dialogueLeveler.bandLowPass = N60BiquadCoefficientsMakeIdentity();

    snapshot.dynamicEQ = N60DynamicEQSnapshotMakeBypassed(sampleRate);

    snapshot.deHarsh.enabled = false;
    snapshot.deHarsh.frequencyHz = 3500.0;
    snapshot.deHarsh.amountDB = -1.5f;
    snapshot.deHarsh.highShelf = N60BiquadCoefficientsMakeIdentity();

    snapshot.deEsser.enabled = false;
    snapshot.deEsser.dynamicEQMode = true;
    snapshot.deEsser.frequencyHz = 6500.0;
    snapshot.deEsser.thresholdDB = -24.0f;
    snapshot.deEsser.ratio = N60_DEESSER_RATIO;
    snapshot.deEsser.rangeDB = -24.0f;
    snapshot.deEsser.detectionQ = 2.0f;
    snapshot.deEsser.attackCoefficient = coefficient_for_time_ms(sampleRate, N60_DEESSER_ATTACK_MS);
    snapshot.deEsser.releaseCoefficient = coefficient_for_time_ms(sampleRate, N60_DEESSER_RELEASE_MS);
    snapshot.deEsser.sidechainHighPass = N60BiquadCoefficientsMakeIdentity();
    snapshot.deEsser.sidechainLowPass = N60BiquadCoefficientsMakeIdentity();

    snapshot.multibandCompressor.enabled = false;
    snapshot.multibandCompressor.lowMidFrequencyHz = 120.0;
    snapshot.multibandCompressor.midHighFrequencyHz = 3500.0;
    snapshot.multibandCompressor.lowTopology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.multibandCompressor.highTopology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.multibandCompressor.lowSectionCount = 0;
    snapshot.multibandCompressor.highSectionCount = 0;
    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        snapshot.multibandCompressor.thresholdDB[band] = -18.0f;
        snapshot.multibandCompressor.ratio[band] = N60_MULTIBAND_RATIO;
        snapshot.multibandCompressor.kneeWidthDB[band] = N60_MULTIBAND_KNEE_DB;
        snapshot.multibandCompressor.makeupGainDB[band] = 0.0f;
        snapshot.multibandCompressor.attackCoefficient[band] = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_ATTACK_MS);
        snapshot.multibandCompressor.releaseCoefficient[band] = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_RELEASE_MS);
        snapshot.multibandCompressor.sidechainHighPass[band] = N60BiquadCoefficientsMakeIdentity();
    }
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        snapshot.multibandCompressor.lowPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.multibandCompressor.highPass[index] = N60BiquadCoefficientsMakeIdentity();
    }

    snapshot.compressor.enabled = false;
    snapshot.compressor.topology = N60CompressorTopologyFeedForward;
    snapshot.compressor.programDependentRelease = false;
    snapshot.compressor.ratio = 1.0f;
    snapshot.compressor.attackCoefficient = coefficient_for_time_ms(sampleRate, 10.0f);
    snapshot.compressor.releaseCoefficient = coefficient_for_time_ms(sampleRate, 100.0f);
    snapshot.compressor.releaseFastCoefficient = coefficient_for_time_ms(sampleRate, 50.0f);
    snapshot.compressor.releaseSlowCoefficient = coefficient_for_time_ms(sampleRate, 200.0f);
    snapshot.compressor.sidechainHighPass = N60BiquadCoefficientsMakeIdentity();

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

bool N60DynamicsSnapshotSetMainsNotch(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double fundamentalHz,
    uint32_t harmonicCount,
    float q,
    const float *depthsDB,
    uint32_t depthCount
) {
    if (snapshot == NULL || depthsDB == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(fundamentalHz) || fundamentalHz < 40.0 || fundamentalHz > 70.0
        || harmonicCount < 1 || harmonicCount > N60_MAX_MAINS_HARMONICS
        || depthCount < harmonicCount || depthCount > N60_MAX_MAINS_HARMONICS
        || !isfinite(q) || q < 5.0f || q > 60.0f) return false;

    N60MainsNotchSnapshot configured = {0};
    configured.enabled = enabled;
    configured.fundamentalHz = fundamentalHz;
    configured.harmonicCount = harmonicCount;
    configured.q = q;
    for (uint32_t index = 0; index < N60_MAX_MAINS_HARMONICS; ++index) {
        configured.depthsDB[index] = 0.0f;
        configured.filters[index] = mains_notch_identity();
    }

    for (uint32_t index = 0; index < harmonicCount; ++index) {
        float depthDB = depthsDB[index];
        if (!isfinite(depthDB) || depthDB < -40.0f || depthDB > 0.0f) return false;
        configured.depthsDB[index] = depthDB;
        double harmonicHz = fundamentalHz * (double)(index + 1u);
        if (harmonicHz >= sampleRate * 0.45 || fabsf(depthDB) < 1.0e-6f) continue;
        if (!design_mains_notch(
                sampleRate,
                harmonicHz,
                depthDB,
                q,
                &configured.filters[index])) return false;
    }

    snapshot->mainsNotch = configured;
    return true;
}

bool N60DynamicsSnapshotSetMainsHumDetector(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double searchCenterHz
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(searchCenterHz) || searchCenterHz < 47.0 || searchCenterHz > 63.0) return false;
    uint32_t decimation = (uint32_t)llround(sampleRate / N60_MAINS_DETECTOR_TARGET_RATE);
    if (decimation < 1) decimation = 1;
    double detectorRate = sampleRate / (double)decimation;
    uint32_t windowSamples = (uint32_t)llround(detectorRate * N60_MAINS_DETECTOR_WINDOW_SECONDS);
    if (windowSamples < 128) windowSamples = 128;

    N60MainsHumDetectorSnapshot configured = {0};
    configured.enabled = enabled;
    configured.searchCenterHz = searchCenterHz;
    configured.searchStartHz = searchCenterHz - N60_MAINS_DETECTOR_SPAN_HZ;
    configured.binSpacingHz = N60_MAINS_DETECTOR_BIN_SPACING_HZ;
    configured.decimationFactor = decimation;
    configured.windowSamples = windowSamples;
    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        double frequency = configured.searchStartHz + (double)index * configured.binSpacingHz;
        double step = 2.0 * M_PI * frequency / detectorRate;
        configured.oscillatorStepCos[index] = (float)cos(step);
        configured.oscillatorStepSin[index] = (float)sin(step);
    }
    snapshot->mainsHumDetector = configured;
    return true;
}

bool N60DynamicsSnapshotSetSpectralDenoiser(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    N60DenoiserTuning tuning,
    N60DenoiserQuality quality,
    float reductionAmount,
    float thresholdDBFS,
    bool protectedRangeEnabled,
    float protectedLowHz,
    float protectedHighHz,
    uint32_t profileRevision,
    N60DenoiserProfileCommand profileCommand
) {
    if (snapshot == NULL) return false;
    N60SpectralDenoiserSnapshot configured = N60SpectralDenoiserSnapshotMakeBypassed(sampleRate);
    if (!N60SpectralDenoiserSnapshotConfigure(
            &configured,
            sampleRate,
            enabled,
            tuning,
            quality,
            reductionAmount,
            thresholdDBFS,
            protectedRangeEnabled,
            protectedLowHz,
            protectedHighHz,
            profileRevision,
            profileCommand)) return false;
    snapshot->spectralDenoiser = configured;
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
    configured.perBandMode = false;
    configured.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);
    configured.flatContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FLAT_CONTOUR_DB);
    double bassDB = N60_LOUDNESS_MAX_BASS_DB * strength;
    double trebleDB = N60_LOUDNESS_MAX_TREBLE_DB * strength;
    if (!N60BiquadDesign(N60BiquadFilterTypeLowShelf, sampleRate, N60_LOUDNESS_LOW_SHELF_HZ, bassDB, 0.7071067811865476, &configured.lowShelf)
        || !N60BiquadDesign(N60BiquadFilterTypeHighShelf, sampleRate, N60_LOUDNESS_HIGH_SHELF_HZ, trebleDB, 0.7071067811865476, &configured.highShelf)) return false;
    snapshot->loudnessContour = configured;
    return true;
}

bool N60DynamicsSnapshotSetPerBandLoudness(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    float strength,
    float referencePhons,
    float maxBoostDB,
    float maxCutDB,
    N60LoudnessLevelSource levelSource
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(strength) || strength < 0.0f || strength > 1.0f
        || !isfinite(referencePhons) || referencePhons < 60.0f || referencePhons > 95.0f
        || !isfinite(maxBoostDB) || maxBoostDB < 6.0f || maxBoostDB > 20.0f
        || !isfinite(maxCutDB) || maxCutDB < 0.0f || maxCutDB > 6.0f
        || (levelSource != N60LoudnessLevelSourceSystemVolume && levelSource != N60LoudnessLevelSourceIntegrated)
        || N60_LOUDNESS_HIGH_SHELF_HZ >= sampleRate * 0.45) return false;

    N60LoudnessContourSnapshot configured = {0};
    configured.enabled = enabled;
    configured.strength = strength;
    configured.perBandMode = true;
    configured.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);
    configured.flatContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FLAT_CONTOUR_DB);
    configured.lowShelf = N60BiquadCoefficientsMakeIdentity();
    configured.highShelf = N60BiquadCoefficientsMakeIdentity();
    configured.levelSource = levelSource;
    configured.referencePhons = referencePhons;
    configured.maxBoostDB = maxBoostDB;
    configured.maxCutDB = maxCutDB;
    configured.responseCoefficient = coefficient_for_time_ms(sampleRate, N60_LOUDNESS_GAIN_RESPONSE_MS);
    if (!valid_coefficient(configured.responseCoefficient)
        || !N60BiquadDesign(N60BiquadFilterTypeLowPass, sampleRate, N60_LOUDNESS_LOW_SHELF_HZ, 0.0, 0.7071067811865476, &configured.lowBandLowPass)
        || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, N60_LOUDNESS_HIGH_SHELF_HZ, 0.0, 0.7071067811865476, &configured.highBandHighPass)) return false;
    snapshot->loudnessContour = configured;
    return true;
}

bool N60DynamicsSnapshotSetDialogueLeveler(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double bandLowHz,
    double bandHighHz,
    float targetGapDB,
    float boostRatio,
    float maxBoostDB,
    float detectorWindowMs,
    float attackMs,
    float releaseMs,
    float programGateThresholdDB,
    bool voiceGateEnabled,
    float modulationCenterHz,
    float modulationBandwidthHz,
    float voiceEnvelopeWindowMs,
    float voiceMeasurementWindowMs,
    float confidenceFloorIndex,
    float confidenceCeilingIndex,
    float minConfidence
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(bandLowHz) || !isfinite(bandHighHz)
        || bandLowHz < 100.0 || bandLowHz > 8000.0 || bandHighHz < 100.0 || bandHighHz > 8000.0
        || bandLowHz >= bandHighHz || bandHighHz >= sampleRate * 0.45
        || !isfinite(targetGapDB) || targetGapDB < 3.0f || targetGapDB > 20.0f
        || !isfinite(boostRatio) || boostRatio < 1.0f || boostRatio > 6.0f
        || !isfinite(maxBoostDB) || maxBoostDB < 0.0f || maxBoostDB > 15.0f
        || !isfinite(detectorWindowMs) || detectorWindowMs < 50.0f || detectorWindowMs > 500.0f
        || !isfinite(attackMs) || attackMs < 10.0f || attackMs > 1000.0f
        || !isfinite(releaseMs) || releaseMs < 50.0f || releaseMs > 3000.0f
        || !isfinite(programGateThresholdDB) || programGateThresholdDB < -70.0f || programGateThresholdDB > -30.0f
        || !isfinite(modulationCenterHz) || modulationCenterHz < 2.0f || modulationCenterHz > 10.0f
        || !isfinite(modulationBandwidthHz) || modulationBandwidthHz < 2.0f || modulationBandwidthHz > 8.0f
        || !isfinite(voiceEnvelopeWindowMs) || voiceEnvelopeWindowMs < 5.0f || voiceEnvelopeWindowMs > 30.0f
        || !isfinite(voiceMeasurementWindowMs) || voiceMeasurementWindowMs < 300.0f || voiceMeasurementWindowMs > 1500.0f
        || !isfinite(confidenceFloorIndex) || confidenceFloorIndex < 0.0f || confidenceFloorIndex > 1.0f
        || !isfinite(confidenceCeilingIndex) || confidenceCeilingIndex <= confidenceFloorIndex || confidenceCeilingIndex > 1.0f
        || !isfinite(minConfidence) || minConfidence < 0.0f || minConfidence > 1.0f) return false;

    float modulationLowHz = fmaxf(0.5f, modulationCenterHz - 0.5f * modulationBandwidthHz);
    float modulationHighHz = modulationCenterHz + 0.5f * modulationBandwidthHz;
    if (modulationHighHz >= sampleRate * 0.45f) return false;

    N60DialogueLevelerSnapshot configured = {0};
    configured.enabled = enabled;
    configured.voiceGateEnabled = voiceGateEnabled;
    configured.bandLowHz = bandLowHz;
    configured.bandHighHz = bandHighHz;
    configured.targetGapDB = targetGapDB;
    configured.boostRatio = boostRatio;
    configured.maxBoostDB = maxBoostDB;
    configured.programGateThresholdDB = programGateThresholdDB;
    configured.detectorCoefficient = coefficient_for_time_ms(sampleRate, detectorWindowMs);
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, attackMs);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, releaseMs);
    configured.voiceEnvelopeCoefficient = coefficient_for_time_ms(sampleRate, voiceEnvelopeWindowMs);
    configured.voiceMeasurementCoefficient = coefficient_for_time_ms(sampleRate, voiceMeasurementWindowMs);
    configured.modulationHighPassPole = (float)exp(-2.0 * M_PI * (double)modulationLowHz / sampleRate);
    configured.modulationLowPassPole = (float)exp(-2.0 * M_PI * (double)modulationHighHz / sampleRate);
    configured.confidenceFloorIndex = confidenceFloorIndex;
    configured.confidenceCeilingIndex = confidenceCeilingIndex;
    configured.minConfidence = minConfidence;
    if (!valid_coefficient(configured.detectorCoefficient)
        || !valid_coefficient(configured.attackCoefficient)
        || !valid_coefficient(configured.releaseCoefficient)
        || !valid_coefficient(configured.voiceEnvelopeCoefficient)
        || !valid_coefficient(configured.voiceMeasurementCoefficient)
        || !valid_coefficient(configured.modulationHighPassPole)
        || !valid_coefficient(configured.modulationLowPassPole)
        || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, bandLowHz, 0.0, 0.7071067811865476, &configured.bandHighPass)
        || !N60BiquadDesign(N60BiquadFilterTypeLowPass, sampleRate, bandHighHz, 0.0, 0.7071067811865476, &configured.bandLowPass)) return false;
    snapshot->dialogueLeveler = configured;
    return true;
}

bool N60DynamicsSnapshotSetDeHarsh(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    float amountDB,
    double frequencyHz
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(amountDB) || amountDB < -6.0f || amountDB > 0.0f
        || !isfinite(frequencyHz) || frequencyHz < 1500.0 || frequencyHz > 10000.0
        || frequencyHz >= sampleRate * 0.45) return false;
    N60DeHarshSnapshot configured = {0};
    configured.enabled = enabled;
    configured.frequencyHz = frequencyHz;
    configured.amountDB = amountDB;
    if (!N60BiquadDesign(N60BiquadFilterTypeHighShelf, sampleRate, frequencyHz, amountDB, 0.7071067811865476, &configured.highShelf)) return false;
    snapshot->deHarsh = configured;
    return true;
}

bool N60DynamicsSnapshotSetDynamicEQEnabled(
    N60DynamicsSnapshot *snapshot,
    bool enabled
) {
    if (snapshot == NULL) return false;
    return N60DynamicEQSnapshotSetEnabled(&snapshot->dynamicEQ, enabled);
}

bool N60DynamicsSnapshotSetDynamicEQBand(
    N60DynamicsSnapshot *snapshot,
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
    return N60DynamicEQSnapshotSetBand(
        &snapshot->dynamicEQ,
        sampleRate,
        index,
        enabled,
        frequencyHz,
        q,
        staticGainDB,
        thresholdDB,
        ratio,
        rangeDB,
        attackMs,
        releaseMs,
        direction,
        boostThresholdDB,
        boostRatio,
        maxBoostDB,
        detectorMode,
        rmsWindowMs
    );
}

bool N60DynamicsSnapshotSetDeEsser(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    bool dynamicEQMode
) {
    return N60DynamicsSnapshotSetDeEsserAdvanced(
        snapshot, sampleRate, enabled, frequencyHz, thresholdDB,
        N60_DEESSER_RATIO, -24.0f, 2.0f,
        N60_DEESSER_ATTACK_MS, N60_DEESSER_RELEASE_MS, dynamicEQMode
    );
}

bool N60DynamicsSnapshotSetDeEsserAdvanced(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float detectionQ,
    float attackMs,
    float releaseMs,
    bool dynamicEQMode
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz < 2000.0 || frequencyHz > 10000.0
        || frequencyHz >= sampleRate * 0.45
        || !isfinite(thresholdDB) || thresholdDB < -60.0f || thresholdDB > 0.0f
        || !isfinite(ratio) || ratio < 1.0f || ratio > 20.0f
        || !isfinite(rangeDB) || rangeDB < -24.0f || rangeDB > 0.0f
        || !isfinite(detectionQ) || detectionQ < 0.5f || detectionQ > 8.0f
        || !isfinite(attackMs) || attackMs < 0.1f || attackMs > 100.0f
        || !isfinite(releaseMs) || releaseMs < 10.0f || releaseMs > 1000.0f) {
        return false;
    }

    // Detection-Q is expressed as inverse octave half-bandwidth. Q=2.0 yields
    // the accepted PR28 band (centre / sqrt(2) ... centre * sqrt(2)).
    double octaveHalfWidth = 1.0 / (double)detectionQ;
    double lowerFrequency = frequencyHz * pow(2.0, -octaveHalfWidth);
    double upperFrequency = frequencyHz * pow(2.0, octaveHalfWidth);
    upperFrequency = fmin(upperFrequency, sampleRate * 0.45);
    if (lowerFrequency <= 0.0 || upperFrequency <= lowerFrequency) return false;

    N60DeEsserSnapshot configured = {0};
    configured.enabled = enabled;
    configured.dynamicEQMode = dynamicEQMode;
    configured.frequencyHz = frequencyHz;
    configured.thresholdDB = thresholdDB;
    configured.ratio = ratio;
    configured.rangeDB = rangeDB;
    configured.detectionQ = detectionQ;
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, attackMs);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, releaseMs);
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
    return N60DynamicsSnapshotSetMultibandCompressorAdvanced(
        snapshot, sampleRate, enabled, lowMidFrequencyHz, midHighFrequencyHz,
        topology, topology,
        lowThresholdDB, midThresholdDB, highThresholdDB,
        N60_MULTIBAND_RATIO, N60_MULTIBAND_RATIO, N60_MULTIBAND_RATIO,
        N60_MULTIBAND_ATTACK_MS, N60_MULTIBAND_ATTACK_MS, N60_MULTIBAND_ATTACK_MS,
        N60_MULTIBAND_RELEASE_MS, N60_MULTIBAND_RELEASE_MS, N60_MULTIBAND_RELEASE_MS,
        N60_MULTIBAND_KNEE_DB, N60_MULTIBAND_KNEE_DB, N60_MULTIBAND_KNEE_DB,
        0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 0.0f
    );
}

bool N60DynamicsSnapshotSetMultibandCompressorAdvanced(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    N60CrossoverTopology lowTopology,
    N60CrossoverTopology highTopology,
    float lowThresholdDB,
    float midThresholdDB,
    float highThresholdDB,
    float lowRatio,
    float midRatio,
    float highRatio,
    float lowAttackMs,
    float midAttackMs,
    float highAttackMs,
    float lowReleaseMs,
    float midReleaseMs,
    float highReleaseMs,
    float lowKneeDB,
    float midKneeDB,
    float highKneeDB,
    float lowSidechainHPFHz,
    float midSidechainHPFHz,
    float highSidechainHPFHz,
    float lowMakeupDB,
    float midMakeupDB,
    float highMakeupDB
) {
    const float thresholds[3] = {lowThresholdDB, midThresholdDB, highThresholdDB};
    const float ratios[3] = {lowRatio, midRatio, highRatio};
    const float attacks[3] = {lowAttackMs, midAttackMs, highAttackMs};
    const float releases[3] = {lowReleaseMs, midReleaseMs, highReleaseMs};
    const float knees[3] = {lowKneeDB, midKneeDB, highKneeDB};
    const float sidechainHPF[3] = {lowSidechainHPFHz, midSidechainHPFHz, highSidechainHPFHz};
    const float makeup[3] = {lowMakeupDB, midMakeupDB, highMakeupDB};
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(lowMidFrequencyHz) || lowMidFrequencyHz < 40.0 || lowMidFrequencyHz > 250.0
        || !isfinite(midHighFrequencyHz) || midHighFrequencyHz < 1000.0 || midHighFrequencyHz > 8000.0
        || lowMidFrequencyHz >= midHighFrequencyHz || midHighFrequencyHz >= sampleRate * 0.45) return false;
    for (uint32_t band = 0; band < 3; ++band) {
        if (!isfinite(thresholds[band]) || thresholds[band] < -60.0f || thresholds[band] > 0.0f
            || !isfinite(ratios[band]) || ratios[band] < 1.0f || ratios[band] > 20.0f
            || !isfinite(attacks[band]) || attacks[band] < 1.0f || attacks[band] > 200.0f
            || !isfinite(releases[band]) || releases[band] < 10.0f || releases[band] > 1000.0f
            || !isfinite(knees[band]) || knees[band] < 0.0f || knees[band] > 20.0f
            || !isfinite(sidechainHPF[band]) || sidechainHPF[band] < 0.0f || sidechainHPF[band] > 300.0f
            || !isfinite(makeup[band]) || makeup[band] < -12.0f || makeup[band] > 12.0f) return false;
    }

    double lowQ[N60_MAX_CROSSOVER_SECTIONS] = {0};
    double highQ[N60_MAX_CROSSOVER_SECTIONS] = {0};
    uint32_t lowCount = 0, highCount = 0;
    if (!N60CrossoverTopologyQValues(lowTopology, lowQ, &lowCount)
        || !N60CrossoverTopologyQValues(highTopology, highQ, &highCount)) return false;

    N60MultibandCompressorSnapshot configured = {0};
    configured.enabled = enabled;
    configured.lowMidFrequencyHz = lowMidFrequencyHz;
    configured.midHighFrequencyHz = midHighFrequencyHz;
    configured.lowTopology = lowTopology;
    configured.highTopology = highTopology;
    configured.lowSectionCount = lowCount;
    configured.highSectionCount = highCount;
    for (uint32_t band = 0; band < 3; ++band) {
        configured.thresholdDB[band] = thresholds[band];
        configured.ratio[band] = ratios[band];
        configured.kneeWidthDB[band] = knees[band];
        configured.makeupGainDB[band] = makeup[band];
        configured.attackCoefficient[band] = coefficient_for_time_ms(sampleRate, attacks[band]);
        configured.releaseCoefficient[band] = coefficient_for_time_ms(sampleRate, releases[band]);
        configured.sidechainHighPass[band] = N60BiquadCoefficientsMakeIdentity();
        if (!valid_coefficient(configured.attackCoefficient[band])
            || !valid_coefficient(configured.releaseCoefficient[band])) return false;
        if (sidechainHPF[band] > 0.0f) {
            if (sidechainHPF[band] >= sampleRate * 0.45
                || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, sidechainHPF[band], 0.0, 0.7071067811865476, &configured.sidechainHighPass[band])) return false;
        }
    }
    for (uint32_t i = 0; i < N60_MAX_CROSSOVER_SECTIONS; ++i) {
        configured.lowPass[i] = N60BiquadCoefficientsMakeIdentity();
        configured.highPass[i] = N60BiquadCoefficientsMakeIdentity();
    }
    for (uint32_t i = 0; i < lowCount; ++i) {
        if (!N60BiquadDesign(N60BiquadFilterTypeLowPass, sampleRate, lowMidFrequencyHz, 0.0, lowQ[i], &configured.lowPass[i])) return false;
    }
    for (uint32_t i = 0; i < highCount; ++i) {
        if (!N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, midHighFrequencyHz, 0.0, highQ[i], &configured.highPass[i])) return false;
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
    return N60DynamicsSnapshotSetCompressorAdvanced(
        snapshot, sampleRate, enabled, thresholdDB, ratio, kneeWidthDB,
        attackMs, releaseMs, makeupGainDB,
        N60CompressorTopologyFeedForward, false, 0.0f
    );
}

bool N60DynamicsSnapshotSetCompressorAdvanced(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float kneeWidthDB,
    float attackMs,
    float releaseMs,
    float makeupGainDB,
    N60CompressorTopology topology,
    bool programDependentRelease,
    float sidechainHighPassHz
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(thresholdDB) || thresholdDB < -96.0f || thresholdDB > 0.0f
        || !isfinite(ratio) || ratio < 1.0f || ratio > 100.0f
        || !isfinite(kneeWidthDB) || kneeWidthDB < 0.0f || kneeWidthDB > 24.0f
        || !isfinite(attackMs) || attackMs < 0.05f || attackMs > 1000.0f
        || !isfinite(releaseMs) || releaseMs < 1.0f || releaseMs > 5000.0f
        || !isfinite(makeupGainDB) || makeupGainDB < -24.0f || makeupGainDB > 24.0f
        || (topology != N60CompressorTopologyFeedForward && topology != N60CompressorTopologyFeedBack)
        || !isfinite(sidechainHighPassHz) || sidechainHighPassHz < 0.0f || sidechainHighPassHz > 300.0f) return false;

    N60CompressorSnapshot configured = {0};
    configured.enabled = enabled;
    configured.topology = topology;
    configured.programDependentRelease = programDependentRelease;
    configured.thresholdDB = thresholdDB;
    configured.ratio = ratio;
    configured.kneeWidthDB = kneeWidthDB;
    configured.makeupGainDB = makeupGainDB;
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, attackMs);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, releaseMs);
    configured.releaseFastCoefficient = coefficient_for_time_ms(sampleRate, fmaxf(releaseMs * 0.5f, 1.0f));
    configured.releaseSlowCoefficient = coefficient_for_time_ms(sampleRate, fminf(releaseMs * 2.0f, 5000.0f));
    configured.sidechainHighPass = N60BiquadCoefficientsMakeIdentity();
    if (!valid_coefficient(configured.attackCoefficient)
        || !valid_coefficient(configured.releaseCoefficient)
        || !valid_coefficient(configured.releaseFastCoefficient)
        || !valid_coefficient(configured.releaseSlowCoefficient)) return false;
    if (sidechainHighPassHz > 0.0f) {
        if (sidechainHighPassHz >= sampleRate * 0.45
            || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, sidechainHighPassHz, 0.0, 0.7071067811865476, &configured.sidechainHighPass)) return false;
    }
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
    if (!isfinite(snapshot.mainsNotch.fundamentalHz)
        || snapshot.mainsNotch.fundamentalHz < 40.0 || snapshot.mainsNotch.fundamentalHz > 70.0
        || snapshot.mainsNotch.harmonicCount < 1 || snapshot.mainsNotch.harmonicCount > N60_MAX_MAINS_HARMONICS
        || !isfinite(snapshot.mainsNotch.q) || snapshot.mainsNotch.q < 5.0f || snapshot.mainsNotch.q > 60.0f) return false;
    for (uint32_t index = 0; index < snapshot.mainsNotch.harmonicCount; ++index) {
        if (!isfinite(snapshot.mainsNotch.depthsDB[index])
            || snapshot.mainsNotch.depthsDB[index] < -40.0f || snapshot.mainsNotch.depthsDB[index] > 0.0f
            || !mains_notch_coefficients_are_finite(snapshot.mainsNotch.filters[index])) return false;
    }
    if (!isfinite(snapshot.mainsHumDetector.searchCenterHz)
        || snapshot.mainsHumDetector.searchCenterHz < 47.0 || snapshot.mainsHumDetector.searchCenterHz > 63.0
        || !isfinite(snapshot.mainsHumDetector.searchStartHz)
        || !isfinite(snapshot.mainsHumDetector.binSpacingHz)
        || snapshot.mainsHumDetector.binSpacingHz <= 0.0
        || snapshot.mainsHumDetector.decimationFactor == 0
        || snapshot.mainsHumDetector.windowSamples == 0) return false;
    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        if (!isfinite(snapshot.mainsHumDetector.oscillatorStepCos[index])
            || !isfinite(snapshot.mainsHumDetector.oscillatorStepSin[index])) return false;
    }
    if (!N60SpectralDenoiserSnapshotIsValid(snapshot.spectralDenoiser, snapshot.spectralDenoiser.sampleRate)) return false;
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
        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.highShelf)
        || (snapshot.loudnessContour.levelSource != N60LoudnessLevelSourceSystemVolume && snapshot.loudnessContour.levelSource != N60LoudnessLevelSourceIntegrated)
        || !isfinite(snapshot.loudnessContour.referencePhons) || snapshot.loudnessContour.referencePhons < 60.0f || snapshot.loudnessContour.referencePhons > 95.0f
        || !isfinite(snapshot.loudnessContour.maxBoostDB) || snapshot.loudnessContour.maxBoostDB < 6.0f || snapshot.loudnessContour.maxBoostDB > 20.0f
        || !isfinite(snapshot.loudnessContour.maxCutDB) || snapshot.loudnessContour.maxCutDB < 0.0f || snapshot.loudnessContour.maxCutDB > 6.0f
        || !valid_coefficient(snapshot.loudnessContour.responseCoefficient)
        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.lowBandLowPass)
        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.highBandHighPass)) return false;

    if (!isfinite(snapshot.dialogueLeveler.bandLowHz) || !isfinite(snapshot.dialogueLeveler.bandHighHz)
        || snapshot.dialogueLeveler.bandLowHz < 100.0 || snapshot.dialogueLeveler.bandHighHz > 8000.0
        || snapshot.dialogueLeveler.bandLowHz >= snapshot.dialogueLeveler.bandHighHz
        || !isfinite(snapshot.dialogueLeveler.targetGapDB) || snapshot.dialogueLeveler.targetGapDB < 3.0f || snapshot.dialogueLeveler.targetGapDB > 20.0f
        || !isfinite(snapshot.dialogueLeveler.boostRatio) || snapshot.dialogueLeveler.boostRatio < 1.0f || snapshot.dialogueLeveler.boostRatio > 6.0f
        || !isfinite(snapshot.dialogueLeveler.maxBoostDB) || snapshot.dialogueLeveler.maxBoostDB < 0.0f || snapshot.dialogueLeveler.maxBoostDB > 15.0f
        || !isfinite(snapshot.dialogueLeveler.programGateThresholdDB) || snapshot.dialogueLeveler.programGateThresholdDB < -70.0f || snapshot.dialogueLeveler.programGateThresholdDB > -30.0f
        || !valid_coefficient(snapshot.dialogueLeveler.detectorCoefficient)
        || !valid_coefficient(snapshot.dialogueLeveler.attackCoefficient)
        || !valid_coefficient(snapshot.dialogueLeveler.releaseCoefficient)
        || !valid_coefficient(snapshot.dialogueLeveler.voiceEnvelopeCoefficient)
        || !valid_coefficient(snapshot.dialogueLeveler.voiceMeasurementCoefficient)
        || !valid_coefficient(snapshot.dialogueLeveler.modulationHighPassPole)
        || !valid_coefficient(snapshot.dialogueLeveler.modulationLowPassPole)
        || !isfinite(snapshot.dialogueLeveler.confidenceFloorIndex)
        || !isfinite(snapshot.dialogueLeveler.confidenceCeilingIndex)
        || snapshot.dialogueLeveler.confidenceFloorIndex < 0.0f
        || snapshot.dialogueLeveler.confidenceCeilingIndex <= snapshot.dialogueLeveler.confidenceFloorIndex
        || snapshot.dialogueLeveler.confidenceCeilingIndex > 1.0f
        || !isfinite(snapshot.dialogueLeveler.minConfidence) || snapshot.dialogueLeveler.minConfidence < 0.0f || snapshot.dialogueLeveler.minConfidence > 1.0f
        || !N60BiquadCoefficientsAreFinite(snapshot.dialogueLeveler.bandHighPass)
        || !N60BiquadCoefficientsAreFinite(snapshot.dialogueLeveler.bandLowPass)) return false;

    if (!N60DynamicEQSnapshotIsValid(snapshot.dynamicEQ)) return false;

    if (!isfinite(snapshot.deHarsh.frequencyHz) || snapshot.deHarsh.frequencyHz < 1500.0 || snapshot.deHarsh.frequencyHz > 10000.0
        || !isfinite(snapshot.deHarsh.amountDB) || snapshot.deHarsh.amountDB < -6.0f || snapshot.deHarsh.amountDB > 0.0f
        || !N60BiquadCoefficientsAreFinite(snapshot.deHarsh.highShelf)) return false;

    if (!isfinite(snapshot.deEsser.frequencyHz)
        || snapshot.deEsser.frequencyHz < 2000.0 || snapshot.deEsser.frequencyHz > 10000.0
        || !isfinite(snapshot.deEsser.thresholdDB)
        || snapshot.deEsser.thresholdDB < -60.0f || snapshot.deEsser.thresholdDB > 0.0f
        || snapshot.deEsser.ratio < 1.0f || snapshot.deEsser.ratio > 20.0f
        || !isfinite(snapshot.deEsser.rangeDB) || snapshot.deEsser.rangeDB < -24.0f || snapshot.deEsser.rangeDB > 0.0f
        || !isfinite(snapshot.deEsser.detectionQ) || snapshot.deEsser.detectionQ < 0.5f || snapshot.deEsser.detectionQ > 8.0f
        || !valid_coefficient(snapshot.deEsser.attackCoefficient)
        || !valid_coefficient(snapshot.deEsser.releaseCoefficient)
        || !N60BiquadCoefficientsAreFinite(snapshot.deEsser.sidechainHighPass)
        || !N60BiquadCoefficientsAreFinite(snapshot.deEsser.sidechainLowPass)) return false;

    if (!isfinite(snapshot.multibandCompressor.lowMidFrequencyHz)
        || !isfinite(snapshot.multibandCompressor.midHighFrequencyHz)
        || snapshot.multibandCompressor.lowMidFrequencyHz >= snapshot.multibandCompressor.midHighFrequencyHz
        || snapshot.multibandCompressor.lowSectionCount > N60_MAX_CROSSOVER_SECTIONS
        || snapshot.multibandCompressor.highSectionCount > N60_MAX_CROSSOVER_SECTIONS) return false;
    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        if (!isfinite(snapshot.multibandCompressor.thresholdDB[band])
            || snapshot.multibandCompressor.thresholdDB[band] < -60.0f || snapshot.multibandCompressor.thresholdDB[band] > 0.0f
            || !isfinite(snapshot.multibandCompressor.ratio[band]) || snapshot.multibandCompressor.ratio[band] < 1.0f || snapshot.multibandCompressor.ratio[band] > 20.0f
            || !isfinite(snapshot.multibandCompressor.kneeWidthDB[band]) || snapshot.multibandCompressor.kneeWidthDB[band] < 0.0f || snapshot.multibandCompressor.kneeWidthDB[band] > 20.0f
            || !isfinite(snapshot.multibandCompressor.makeupGainDB[band]) || snapshot.multibandCompressor.makeupGainDB[band] < -12.0f || snapshot.multibandCompressor.makeupGainDB[band] > 12.0f
            || !valid_coefficient(snapshot.multibandCompressor.attackCoefficient[band])
            || !valid_coefficient(snapshot.multibandCompressor.releaseCoefficient[band])
            || !N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.sidechainHighPass[band])) return false;
    }
    for (uint32_t index = 0; index < snapshot.multibandCompressor.lowSectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.lowPass[index])) return false;
    }
    for (uint32_t index = 0; index < snapshot.multibandCompressor.highSectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.highPass[index])) return false;
    }

    if (snapshot.compressor.ratio < 1.0f || snapshot.compressor.ratio > 100.0f
        || (snapshot.compressor.topology != N60CompressorTopologyFeedForward && snapshot.compressor.topology != N60CompressorTopologyFeedBack)
        || !isfinite(snapshot.compressor.thresholdDB)
        || !isfinite(snapshot.compressor.kneeWidthDB)
        || !isfinite(snapshot.compressor.makeupGainDB)
        || !valid_coefficient(snapshot.compressor.attackCoefficient)
        || !valid_coefficient(snapshot.compressor.releaseCoefficient)
        || !valid_coefficient(snapshot.compressor.releaseFastCoefficient)
        || !valid_coefficient(snapshot.compressor.releaseSlowCoefficient)
        || !N60BiquadCoefficientsAreFinite(snapshot.compressor.sidechainHighPass)) return false;
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
    N60DynamicEQRuntimeReset(&runtime->dynamicEQ);
    reset_mains_detector_window(runtime);
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

    dryLeft = *left;
    dryRight = *right;
    process_mains_hum_detector(runtime, snapshot.mainsHumDetector, dryLeft, dryRight);

    uint32_t retuneFrames = (uint32_t)fmax(32.0, snapshot.mainsHumDetector.decimationFactor * N60_MAINS_DETECTOR_TARGET_RATE * N60_MAINS_NOTCH_RETUNE_SECONDS);
    schedule_mains_notch_retune(runtime, snapshot.mainsNotch, retuneFrames);
    float notchLeft = process_mains_notch_cascade(
        runtime->mainsNotchCurrentFilters,
        runtime->mainsNotchLeft,
        runtime->mainsNotchCurrentHarmonicCount,
        dryLeft
    );
    float notchRight = process_mains_notch_cascade(
        runtime->mainsNotchCurrentFilters,
        runtime->mainsNotchRight,
        runtime->mainsNotchCurrentHarmonicCount,
        dryRight
    );
    if (runtime->mainsNotchTransitionFramesRemaining > 0) {
        float pendingLeft = process_mains_notch_cascade(
            runtime->mainsNotchPendingFilters,
            runtime->mainsNotchPendingLeft,
            runtime->mainsNotchPendingHarmonicCount,
            dryLeft
        );
        float pendingRight = process_mains_notch_cascade(
            runtime->mainsNotchPendingFilters,
            runtime->mainsNotchPendingRight,
            runtime->mainsNotchPendingHarmonicCount,
            dryRight
        );
        uint32_t completed = runtime->mainsNotchTransitionFramesTotal - runtime->mainsNotchTransitionFramesRemaining + 1;
        float mix = (float)completed / (float)runtime->mainsNotchTransitionFramesTotal;
        notchLeft += (pendingLeft - notchLeft) * mix;
        notchRight += (pendingRight - notchRight) * mix;
        runtime->mainsNotchTransitionFramesRemaining -= 1;
        if (runtime->mainsNotchTransitionFramesRemaining == 0) promote_pending_mains_notch(runtime);
    }
    float mainsTarget = snapshot.mainsNotch.enabled ? 1.0f : 0.0f;
    runtime->mainsNotchMix = smooth_toward(runtime->mainsNotchMix, mainsTarget, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (notchLeft - dryLeft) * runtime->mainsNotchMix;
    *right = dryRight + (notchRight - dryRight) * runtime->mainsNotchMix;
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
    N60LoudnessContourSnapshot config = snapshot.loudnessContour;

    if (!config.perBandMode) {
        float wetLeft = N60BiquadProcessSample(config.lowShelf, &runtime->loudnessLowShelfLeft, dryLeft);
        wetLeft = N60BiquadProcessSample(config.highShelf, &runtime->loudnessHighShelfLeft, wetLeft);
        float wetRight = N60BiquadProcessSample(config.lowShelf, &runtime->loudnessLowShelfRight, dryRight);
        wetRight = N60BiquadProcessSample(config.highShelf, &runtime->loudnessHighShelfRight, wetRight);
        float volumeScale = 0.0f;
        if (masterGainLinear <= config.fullContourMasterGainLinear) {
            volumeScale = 1.0f;
        } else if (masterGainLinear < config.flatContourMasterGainLinear) {
            float masterDB = linear_to_db(masterGainLinear);
            volumeScale = (N60_LOUDNESS_FLAT_CONTOUR_DB - masterDB)
                / (N60_LOUDNESS_FLAT_CONTOUR_DB - N60_LOUDNESS_FULL_CONTOUR_DB);
            volumeScale = clampf(volumeScale, 0.0f, 1.0f);
        }
        float target = config.enabled ? volumeScale : 0.0f;
        runtime->loudnessMix = smooth_toward(runtime->loudnessMix, target, snapshot.bypassTransitionCoefficient);
        runtime->loudnessLowGainDB = N60_LOUDNESS_MAX_BASS_DB * config.strength * runtime->loudnessMix;
        runtime->loudnessHighGainDB = N60_LOUDNESS_MAX_TREBLE_DB * config.strength * runtime->loudnessMix;
        runtime->loudnessEstimatedPhons = config.referencePhons;
        *left = dryLeft + (wetLeft - dryLeft) * runtime->loudnessMix;
        *right = dryRight + (wetRight - dryRight) * runtime->loudnessMix;
        return;
    }

    float lowLeft = N60BiquadProcessSample(config.lowBandLowPass, &runtime->loudnessLowBandLeft, dryLeft);
    float lowRight = N60BiquadProcessSample(config.lowBandLowPass, &runtime->loudnessLowBandRight, dryRight);
    float highLeft = N60BiquadProcessSample(config.highBandHighPass, &runtime->loudnessHighBandLeft, dryLeft);
    float highRight = N60BiquadProcessSample(config.highBandHighPass, &runtime->loudnessHighBandRight, dryRight);

    float measuredLUFS = -0.691f + 10.0f * log10f(fmaxf(runtime->loudnessMeanSquare, N60_DYNAMICS_EPSILON));
    float estimatedPhons;
    if (config.levelSource == N60LoudnessLevelSourceIntegrated) {
        // Commercial calibration: -16 LUFS program level corresponds to the
        // configured reference-phons point. This is intentionally explicit and
        // deterministic rather than claiming to be a calibrated SPL meter.
        estimatedPhons = config.referencePhons + (measuredLUFS - N60_LOUDNESS_INTEGRATED_REFERENCE_LUFS);
    } else {
        // Preserve PR29's useful anchor points: master -6 dB is flat/reference;
        // master -30 dB is 24 phons below reference and therefore reaches the
        // historical +6/+3 dB contour with the default psychoacoustic slopes.
        float masterDB = linear_to_db(fmaxf(masterGainLinear, N60_DYNAMICS_EPSILON));
        estimatedPhons = config.referencePhons + (masterDB - N60_LOUDNESS_FLAT_CONTOUR_DB);
    }
    runtime->loudnessEstimatedPhons = estimatedPhons;

    float phonDelta = config.referencePhons - estimatedPhons;
    float lowTargetDB = 0.0f;
    float highTargetDB = 0.0f;
    if (config.enabled && phonDelta >= 0.0f) {
        lowTargetDB = fminf(config.maxBoostDB, phonDelta * N60_LOUDNESS_LOW_DB_PER_PHON) * config.strength;
        highTargetDB = fminf(config.maxBoostDB, phonDelta * N60_LOUDNESS_HIGH_DB_PER_PHON) * config.strength;
    } else if (config.enabled) {
        float surplus = -phonDelta;
        lowTargetDB = -fminf(config.maxCutDB, surplus * N60_LOUDNESS_LOW_CUT_DB_PER_PHON) * config.strength;
        highTargetDB = -fminf(config.maxCutDB, surplus * N60_LOUDNESS_HIGH_CUT_DB_PER_PHON) * config.strength;
    }

    float coefficient = config.enabled ? config.responseCoefficient : snapshot.bypassTransitionCoefficient;
    runtime->loudnessLowGainDB = smooth_toward(runtime->loudnessLowGainDB, lowTargetDB, coefficient);
    runtime->loudnessHighGainDB = smooth_toward(runtime->loudnessHighGainDB, highTargetDB, coefficient);
    float lowGain = db_to_linear(runtime->loudnessLowGainDB);
    float highGain = db_to_linear(runtime->loudnessHighGainDB);
    // Residual-additive form is exact unity at 0 dB even though the band filters
    // themselves are not complementary crossover pairs.
    *left = dryLeft + lowLeft * (lowGain - 1.0f) + highLeft * (highGain - 1.0f);
    *right = dryRight + lowRight * (lowGain - 1.0f) + highRight * (highGain - 1.0f);
    float normalization = fmaxf(config.maxBoostDB, fmaxf(config.maxCutDB, 1.0f));
    runtime->loudnessMix = clampf(fmaxf(fabsf(runtime->loudnessLowGainDB), fabsf(runtime->loudnessHighGainDB)) / normalization, 0.0f, 1.0f);
}

static void process_de_harsh(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    float dryLeft = *left;
    float dryRight = *right;
    float wetLeft = N60BiquadProcessSample(snapshot.deHarsh.highShelf, &runtime->deHarshLeft, dryLeft);
    float wetRight = N60BiquadProcessSample(snapshot.deHarsh.highShelf, &runtime->deHarshRight, dryRight);
    float target = snapshot.deHarsh.enabled ? 1.0f : 0.0f;
    runtime->deHarshMix = smooth_toward(runtime->deHarshMix, target, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (wetLeft - dryLeft) * runtime->deHarshMix;
    *right = dryRight + (wetRight - dryRight) * runtime->deHarshMix;
}

static void process_dialogue_leveler(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    N60DialogueLevelerSnapshot config = snapshot.dialogueLeveler;
    float dryLeft = *left;
    float dryRight = *right;

    float dialogueLeft = N60BiquadProcessSample(config.bandHighPass, &runtime->dialogueHighPassLeft, dryLeft);
    dialogueLeft = N60BiquadProcessSample(config.bandLowPass, &runtime->dialogueLowPassLeft, dialogueLeft);
    float dialogueRight = N60BiquadProcessSample(config.bandHighPass, &runtime->dialogueHighPassRight, dryRight);
    dialogueRight = N60BiquadProcessSample(config.bandLowPass, &runtime->dialogueLowPassRight, dialogueRight);

    float programPower = 0.5f * (dryLeft * dryLeft + dryRight * dryRight);
    float dialoguePower = 0.5f * (dialogueLeft * dialogueLeft + dialogueRight * dialogueRight);
    runtime->dialogueProgramMeanSquare = smooth_toward(runtime->dialogueProgramMeanSquare, programPower, config.detectorCoefficient);
    runtime->dialogueBandMeanSquare = smooth_toward(runtime->dialogueBandMeanSquare, dialoguePower, config.detectorCoefficient);
    runtime->dialogueProgramLevelDBFS = 10.0f * log10f(fmaxf(runtime->dialogueProgramMeanSquare, N60_DYNAMICS_EPSILON));
    runtime->dialogueBandLevelDBFS = 10.0f * log10f(fmaxf(runtime->dialogueBandMeanSquare, N60_DYNAMICS_EPSILON));
    runtime->dialogueGapDB = runtime->dialogueProgramLevelDBFS - runtime->dialogueBandLevelDBFS;

    // Independently authored speech-likeness confidence: measure normalized
    // syllabic-rate modulation energy in the dialogue-band envelope. All filter
    // coefficients are prepared in the snapshot; the render path is fixed state.
    float dialogueEnvelopeInput = sqrtf(fmaxf(dialoguePower, 0.0f));
    runtime->dialogueVoiceEnvelope = smooth_toward(
        runtime->dialogueVoiceEnvelope, dialogueEnvelopeInput, config.voiceEnvelopeCoefficient);
    float modulationHP = runtime->dialogueVoiceEnvelope - runtime->dialogueModulationPreviousInput
        + config.modulationHighPassPole * runtime->dialogueModulationHighPassOutput;
    runtime->dialogueModulationPreviousInput = runtime->dialogueVoiceEnvelope;
    runtime->dialogueModulationHighPassOutput = modulationHP;
    float modulationLP = (1.0f - config.modulationLowPassPole) * modulationHP
        + config.modulationLowPassPole * runtime->dialogueModulationLowPassOutput;
    runtime->dialogueModulationLowPassOutput = modulationLP;
    float modulationPower = modulationLP * modulationLP;
    runtime->dialogueModulationMeanSquare = smooth_toward(
        runtime->dialogueModulationMeanSquare, modulationPower, config.voiceMeasurementCoefficient);
    float modulationIndex = sqrtf(fmaxf(runtime->dialogueModulationMeanSquare, 0.0f))
        / fmaxf(runtime->dialogueVoiceEnvelope, 1.0e-6f);
    float mappedConfidence = (modulationIndex - config.confidenceFloorIndex)
        / fmaxf(config.confidenceCeilingIndex - config.confidenceFloorIndex, 1.0e-6f);
    mappedConfidence = clampf(mappedConfidence, 0.0f, 1.0f);
    runtime->dialogueVoiceConfidence = config.voiceGateEnabled
        ? config.minConfidence + (1.0f - config.minConfidence) * mappedConfidence
        : 1.0f;

    float targetBoostDB = 0.0f;
    if (config.enabled && runtime->dialogueProgramLevelDBFS >= config.programGateThresholdDB) {
        float excessGap = fmaxf(0.0f, runtime->dialogueGapDB - config.targetGapDB);
        float correctionFraction = config.boostRatio > 1.0f ? (1.0f - 1.0f / config.boostRatio) : 0.0f;
        targetBoostDB = fminf(config.maxBoostDB, excessGap * correctionFraction);
        targetBoostDB *= runtime->dialogueVoiceConfidence;
    }
    float coefficient = !config.enabled
        ? snapshot.bypassTransitionCoefficient
        : (targetBoostDB > runtime->dialogueBoostDB ? config.attackCoefficient : config.releaseCoefficient);
    runtime->dialogueBoostDB = smooth_toward(runtime->dialogueBoostDB, targetBoostDB, coefficient);

    // Boost only the extracted dialogue band, not the full program. The same
    // correction is applied to L/R, preserving the stereo image of the band.
    float bandGain = db_to_linear(runtime->dialogueBoostDB);
    *left = dryLeft + dialogueLeft * (bandGain - 1.0f);
    *right = dryRight + dialogueRight * (bandGain - 1.0f);
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
    targetDB = fmaxf(targetDB, snapshot.deEsser.rangeDB);
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
    if (multiband.lowSectionCount == 0 || multiband.highSectionCount == 0) return;

    float dryLeft = *left;
    float dryRight = *right;
    float lowLeft = process_filter_cascade(
        multiband.lowPass,
        runtime->multibandLowPassLeft,
        multiband.lowSectionCount,
        dryLeft
    );
    float lowRight = process_filter_cascade(
        multiband.lowPass,
        runtime->multibandLowPassRight,
        multiband.lowSectionCount,
        dryRight
    );
    float highLeft = process_filter_cascade(
        multiband.highPass,
        runtime->multibandHighPassLeft,
        multiband.highSectionCount,
        dryLeft
    );
    float highRight = process_filter_cascade(
        multiband.highPass,
        runtime->multibandHighPassRight,
        multiband.highSectionCount,
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
        float detectorLeft = N60BiquadProcessSample(multiband.sidechainHighPass[band], &runtime->multibandSidechainLeft[band], bandLeft[band]);
        float detectorRight = N60BiquadProcessSample(multiband.sidechainHighPass[band], &runtime->multibandSidechainRight[band], bandRight[band]);
        float detector = fmaxf(fabsf(detectorLeft), fabsf(detectorRight));
        float targetDB = dynamics_compression_target(
            detector,
            multiband.enabled,
            multiband.thresholdDB[band],
            multiband.ratio[band],
            multiband.kneeWidthDB[band]
        );
        if (multiband.enabled) targetDB += multiband.makeupGainDB[band];
        float coefficient = !multiband.enabled
            ? snapshot.bypassTransitionCoefficient
            : (targetDB < runtime->multibandGainDB[band]
                ? multiband.attackCoefficient[band]
                : multiband.releaseCoefficient[band]);
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
    process_dialogue_leveler(runtime, snapshot, left, right);
    N60DynamicEQProcessStereoFrame(&runtime->dynamicEQ, snapshot.dynamicEQ, left, right);
    process_de_harsh(runtime, snapshot, left, right);
    process_de_esser(runtime, snapshot, left, right);
    process_multiband_compressor(runtime, snapshot, left, right);

    float detectorFeedGain = snapshot.compressor.topology == N60CompressorTopologyFeedBack
        ? db_to_linear(runtime->compressorGainDB) : 1.0f;
    float compressorDetectorLeft = N60BiquadProcessSample(
        snapshot.compressor.sidechainHighPass, &runtime->compressorSidechainLeft, *left * detectorFeedGain);
    float compressorDetectorRight = N60BiquadProcessSample(
        snapshot.compressor.sidechainHighPass, &runtime->compressorSidechainRight, *right * detectorFeedGain);
    float detector = fmaxf(fabsf(compressorDetectorLeft), fabsf(compressorDetectorRight));
    float detectorDB = linear_to_db(detector);

    float compressorTargetDB = compressor_target_gain_db(detectorDB, snapshot.compressor);
    float compressorCoefficient;
    if (!snapshot.compressor.enabled) {
        compressorCoefficient = snapshot.bypassTransitionCoefficient;
    } else if (compressorTargetDB < runtime->compressorGainDB) {
        compressorCoefficient = snapshot.compressor.attackCoefficient;
    } else if (snapshot.compressor.programDependentRelease) {
        float depth = clampf(-runtime->compressorGainDB / 12.0f, 0.0f, 1.0f);
        compressorCoefficient = snapshot.compressor.releaseFastCoefficient
            + depth * (snapshot.compressor.releaseSlowCoefficient - snapshot.compressor.releaseFastCoefficient);
    } else {
        compressorCoefficient = snapshot.compressor.releaseCoefficient;
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
    telemetry.mainsDetectedFrequencyHz = runtime->mainsDetectedFrequencyHz;
    telemetry.mainsDetectionConfidence = runtime->mainsDetectionConfidence;
    telemetry.loudnessShortTermLUFS = -0.691f + 10.0f * log10f(fmaxf(runtime->loudnessMeanSquare, N60_DYNAMICS_EPSILON));
    telemetry.loudnessMatchGainDB = runtime->loudnessMatchGainDB;
    telemetry.loudnessContourScale = runtime->loudnessMix;
    telemetry.loudnessLowCompensationDB = runtime->loudnessLowGainDB;
    telemetry.loudnessHighCompensationDB = runtime->loudnessHighGainDB;
    telemetry.loudnessEstimatedPhons = runtime->loudnessEstimatedPhons;
    telemetry.deHarshMix = runtime->deHarshMix;
    telemetry.dialogueProgramLevelDBFS = runtime->dialogueProgramLevelDBFS;
    telemetry.dialogueBandLevelDBFS = runtime->dialogueBandLevelDBFS;
    telemetry.dialogueGapDB = runtime->dialogueGapDB;
    telemetry.dialogueVoiceConfidence = runtime->dialogueVoiceConfidence;
    telemetry.dialogueBoostDB = runtime->dialogueBoostDB;
    N60DynamicEQTelemetry dynamicEQ = N60DynamicEQRuntimeTelemetry(&runtime->dynamicEQ);
    telemetry.dynamicEQActiveBandCount = dynamicEQ.activeBandCount;
    telemetry.dynamicEQMaxAbsGainDB = dynamicEQ.maxAbsDynamicGainDB;
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