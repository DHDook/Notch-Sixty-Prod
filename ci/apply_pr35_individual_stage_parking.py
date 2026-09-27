from pathlib import Path


def replace_exact(path: str, old: str, new: str, expected: int = 1) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{path}: expected {expected} occurrence(s), found {count}: {old[:100]!r}")
    file.write_text(text.replace(old, new))


def replace_span(path: str, start: str, end: str, replacement: str) -> None:
    file = Path(path)
    text = file.read_text()
    first = text.find(start)
    if first < 0:
        raise SystemExit(f"{path}: start marker missing: {start!r}")
    if text.find(start, first + 1) >= 0:
        raise SystemExit(f"{path}: start marker not unique: {start!r}")
    last = text.find(end, first + len(start))
    if last < 0:
        raise SystemExit(f"{path}: end marker missing after start: {end!r}")
    file.write_text(text[:first] + replacement + text[last:])


header = "NotchSixty/Audio/Realtime/N60Dynamics.h"
source = "NotchSixty/Audio/Realtime/N60Dynamics.c"

replace_exact(
    header,
    """    bool gateOpen;\n    bool preEQParked;\n    bool coreParked;\n} N60DynamicsRuntime;""",
    """    bool gateOpen;\n    bool preEQParked;\n    bool coreParked;\n    bool dcParked;\n    bool infrasonicParked;\n    bool mainsNotchParked;\n    bool mainsDetectorParked;\n    bool stereoModeParked;\n    bool widenerParked;\n    bool loudnessMatchParked;\n    bool loudnessContourParked;\n    bool dialogueLevelerParked;\n    bool deHarshParked;\n    bool deEsserParked;\n    bool multibandParked;\n    bool compressorParked;\n    bool expanderParked;\n    bool pauseGateParked;\n} N60DynamicsRuntime;""",
)

replace_exact(
    source,
    """    runtime->mainsNotchTransitionFramesTotal = 0u;\n    runtime->mainsNotchTransitionFramesRemaining = 0u;\n    runtime->preEQParked = true;""",
    """    runtime->mainsNotchTransitionFramesTotal = 0u;\n    runtime->mainsNotchTransitionFramesRemaining = 0u;\n    runtime->dcParked = true;\n    runtime->infrasonicParked = true;\n    runtime->mainsNotchParked = true;\n    runtime->preEQParked = true;""",
)

replace_exact(
    source,
    """    runtime->compressorGainDB = 0.0f;\n    runtime->expanderGainDB = 0.0f;\n    runtime->coreParked = true;""",
    """    runtime->compressorGainDB = 0.0f;\n    runtime->expanderGainDB = 0.0f;\n    runtime->stereoModeParked = true;\n    runtime->widenerParked = true;\n    runtime->loudnessMatchParked = true;\n    runtime->loudnessContourParked = true;\n    runtime->dialogueLevelerParked = true;\n    runtime->deHarshParked = true;\n    runtime->deEsserParked = true;\n    runtime->multibandParked = true;\n    runtime->compressorParked = true;\n    runtime->expanderParked = true;\n    runtime->coreParked = true;""",
)

replace_span(
    source,
    "static void process_mains_hum_detector(",
    "static float dynamics_compression_target(",
    r'''static void process_mains_hum_detector(
    N60DynamicsRuntime *runtime,
    const N60MainsHumDetectorSnapshot *snapshot,
    float left,
    float right
) {
    if (!snapshot->enabled || snapshot->decimationFactor == 0 || snapshot->windowSamples == 0) {
        if (!runtime->mainsDetectorParked) {
            reset_mains_detector_window(runtime);
            runtime->mainsDetectedFrequencyHz = 0.0f;
            runtime->mainsDetectionConfidence = 0.0f;
            runtime->mainsDetectorDecimationCounter = 0u;
            runtime->mainsDetectorParked = true;
        }
        return;
    }
    if (runtime->mainsDetectorParked) {
        reset_mains_detector_window(runtime);
        runtime->mainsDetectorDecimationCounter = 0u;
        runtime->mainsDetectorParked = false;
    }
    runtime->mainsDetectorDecimationCounter += 1;
    if (runtime->mainsDetectorDecimationCounter < snapshot->decimationFactor) return;
    runtime->mainsDetectorDecimationCounter = 0;

    double mono = 0.5 * ((double)left + (double)right);
    runtime->mainsDetectorWindowEnergy += mono * mono;
    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        double oscCos = runtime->mainsDetectorOscCos[index];
        double oscSin = runtime->mainsDetectorOscSin[index];
        runtime->mainsDetectorReal[index] += mono * oscCos;
        runtime->mainsDetectorImag[index] += mono * oscSin;
        double stepCos = (double)snapshot->oscillatorStepCos[index];
        double stepSin = (double)snapshot->oscillatorStepSin[index];
        runtime->mainsDetectorOscCos[index] = oscCos * stepCos - oscSin * stepSin;
        runtime->mainsDetectorOscSin[index] = oscSin * stepCos + oscCos * stepSin;
    }
    runtime->mainsDetectorSampleCount += 1;
    if (runtime->mainsDetectorSampleCount < snapshot->windowSamples) return;

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
        snapshot->searchStartHz
        + ((double)bestIndex + fractionalBin) * snapshot->binSpacingHz
    );
    runtime->mainsDetectionConfidence = (float)confidence;
    reset_mains_detector_window(runtime);
}

''',
)

replace_span(
    source,
    "void N60DynamicsProcessPreEQStereoFrame(",
    "static void process_stereo_mode(",
    r'''void N60DynamicsProcessPreEQStereoFrame(
    N60DynamicsRuntime *runtime,
    const N60DynamicsSnapshot *snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || snapshot == NULL || left == NULL || right == NULL) return;

    if (pre_eq_snapshot_is_idle(snapshot)) {
        if (!runtime->preEQParked && pre_eq_runtime_is_neutral(runtime)) {
            park_pre_eq_runtime(runtime);
        }
        if (runtime->preEQParked) {
            process_mains_hum_detector(runtime, &snapshot->mainsHumDetector, *left, *right);
            return;
        }
    } else {
        activate_pre_eq_runtime(runtime);
    }

    if (snapshot->dcOffsetFilter.enabled && runtime->dcParked) {
        runtime->dcPreviousInputLeft = 0.0f;
        runtime->dcPreviousInputRight = 0.0f;
        runtime->dcPreviousOutputLeft = 0.0f;
        runtime->dcPreviousOutputRight = 0.0f;
        runtime->dcMix = 0.0f;
        runtime->dcParked = false;
    }
    if (!runtime->dcParked) {
        float dryLeft = *left;
        float dryRight = *right;
        float dcLeft = dryLeft - runtime->dcPreviousInputLeft + snapshot->dcOffsetFilter.poleCoefficient * runtime->dcPreviousOutputLeft;
        float dcRight = dryRight - runtime->dcPreviousInputRight + snapshot->dcOffsetFilter.poleCoefficient * runtime->dcPreviousOutputRight;
        runtime->dcPreviousInputLeft = dryLeft;
        runtime->dcPreviousInputRight = dryRight;
        runtime->dcPreviousOutputLeft = dcLeft;
        runtime->dcPreviousOutputRight = dcRight;
        float dcTarget = snapshot->dcOffsetFilter.enabled ? 1.0f : 0.0f;
        runtime->dcMix = smooth_toward(runtime->dcMix, dcTarget, snapshot->bypassTransitionCoefficient);
        if (!snapshot->dcOffsetFilter.enabled && near_zero(runtime->dcMix)) {
            runtime->dcMix = 0.0f;
            runtime->dcPreviousInputLeft = 0.0f;
            runtime->dcPreviousInputRight = 0.0f;
            runtime->dcPreviousOutputLeft = 0.0f;
            runtime->dcPreviousOutputRight = 0.0f;
            runtime->dcParked = true;
        } else {
            *left = dryLeft + (dcLeft - dryLeft) * runtime->dcMix;
            *right = dryRight + (dcRight - dryRight) * runtime->dcMix;
        }
    }

    if (snapshot->infrasonicFilter.enabled && runtime->infrasonicParked) {
        memset(runtime->infrasonicLeft, 0, sizeof(runtime->infrasonicLeft));
        memset(runtime->infrasonicRight, 0, sizeof(runtime->infrasonicRight));
        runtime->infrasonicMix = 0.0f;
        runtime->infrasonicParked = false;
    }
    if (!runtime->infrasonicParked) {
        float dryLeft = *left;
        float dryRight = *right;
        float hpLeft = process_filter_cascade(snapshot->infrasonicFilter.highPass, runtime->infrasonicLeft, snapshot->infrasonicFilter.sectionCount, dryLeft);
        float hpRight = process_filter_cascade(snapshot->infrasonicFilter.highPass, runtime->infrasonicRight, snapshot->infrasonicFilter.sectionCount, dryRight);
        float target = snapshot->infrasonicFilter.enabled ? 1.0f : 0.0f;
        runtime->infrasonicMix = smooth_toward(runtime->infrasonicMix, target, snapshot->bypassTransitionCoefficient);
        if (!snapshot->infrasonicFilter.enabled && near_zero(runtime->infrasonicMix)) {
            runtime->infrasonicMix = 0.0f;
            memset(runtime->infrasonicLeft, 0, sizeof(runtime->infrasonicLeft));
            memset(runtime->infrasonicRight, 0, sizeof(runtime->infrasonicRight));
            runtime->infrasonicParked = true;
        } else {
            *left = dryLeft + (hpLeft - dryLeft) * runtime->infrasonicMix;
            *right = dryRight + (hpRight - dryRight) * runtime->infrasonicMix;
        }
    }

    process_mains_hum_detector(runtime, &snapshot->mainsHumDetector, *left, *right);

    if (snapshot->mainsNotch.enabled && runtime->mainsNotchParked) {
        memset(runtime->mainsNotchLeft, 0, sizeof(runtime->mainsNotchLeft));
        memset(runtime->mainsNotchRight, 0, sizeof(runtime->mainsNotchRight));
        memset(runtime->mainsNotchPendingLeft, 0, sizeof(runtime->mainsNotchPendingLeft));
        memset(runtime->mainsNotchPendingRight, 0, sizeof(runtime->mainsNotchPendingRight));
        runtime->mainsNotchInitialized = false;
        runtime->mainsNotchMix = 0.0f;
        runtime->mainsNotchTransitionFramesTotal = 0u;
        runtime->mainsNotchTransitionFramesRemaining = 0u;
        runtime->mainsNotchParked = false;
    }
    if (!runtime->mainsNotchParked) {
        float dryLeft = *left;
        float dryRight = *right;
        if (snapshot->mainsNotch.enabled) {
            uint32_t retuneFrames = (uint32_t)fmax(32.0, snapshot->mainsHumDetector.decimationFactor * N60_MAINS_DETECTOR_TARGET_RATE * N60_MAINS_NOTCH_RETUNE_SECONDS);
            schedule_mains_notch_retune(runtime, &snapshot->mainsNotch, retuneFrames);
        }
        float notchLeft = process_mains_notch_cascade(runtime->mainsNotchCurrentFilters, runtime->mainsNotchLeft, runtime->mainsNotchCurrentHarmonicCount, dryLeft);
        float notchRight = process_mains_notch_cascade(runtime->mainsNotchCurrentFilters, runtime->mainsNotchRight, runtime->mainsNotchCurrentHarmonicCount, dryRight);
        if (runtime->mainsNotchTransitionFramesRemaining > 0) {
            float pendingLeft = process_mains_notch_cascade(runtime->mainsNotchPendingFilters, runtime->mainsNotchPendingLeft, runtime->mainsNotchPendingHarmonicCount, dryLeft);
            float pendingRight = process_mains_notch_cascade(runtime->mainsNotchPendingFilters, runtime->mainsNotchPendingRight, runtime->mainsNotchPendingHarmonicCount, dryRight);
            uint32_t completed = runtime->mainsNotchTransitionFramesTotal - runtime->mainsNotchTransitionFramesRemaining + 1;
            float mix = (float)completed / (float)runtime->mainsNotchTransitionFramesTotal;
            notchLeft += (pendingLeft - notchLeft) * mix;
            notchRight += (pendingRight - notchRight) * mix;
            runtime->mainsNotchTransitionFramesRemaining -= 1;
            if (runtime->mainsNotchTransitionFramesRemaining == 0) promote_pending_mains_notch(runtime);
        }
        float target = snapshot->mainsNotch.enabled ? 1.0f : 0.0f;
        runtime->mainsNotchMix = smooth_toward(runtime->mainsNotchMix, target, snapshot->bypassTransitionCoefficient);
        if (!snapshot->mainsNotch.enabled
            && near_zero(runtime->mainsNotchMix)
            && runtime->mainsNotchTransitionFramesRemaining == 0u) {
            runtime->mainsNotchMix = 0.0f;
            runtime->mainsNotchInitialized = false;
            memset(runtime->mainsNotchLeft, 0, sizeof(runtime->mainsNotchLeft));
            memset(runtime->mainsNotchRight, 0, sizeof(runtime->mainsNotchRight));
            memset(runtime->mainsNotchPendingLeft, 0, sizeof(runtime->mainsNotchPendingLeft));
            memset(runtime->mainsNotchPendingRight, 0, sizeof(runtime->mainsNotchPendingRight));
            runtime->mainsNotchParked = true;
        } else {
            *left = dryLeft + (notchLeft - dryLeft) * runtime->mainsNotchMix;
            *right = dryRight + (notchRight - dryRight) * runtime->mainsNotchMix;
        }
    }
}

''',
)

replace_span(
    source,
    "static void process_stereo_mode(",
    "static void process_stereo_widener(",
    r'''static void process_stereo_mode(N60DynamicsRuntime *runtime, const N60DynamicsSnapshot *snapshot, float *left, float *right) {
    bool enabled = snapshot->stereoMode.mode != N60StereoModeStereo;
    if (!enabled && runtime->stereoModeParked) return;
    if (enabled && runtime->stereoModeParked) runtime->stereoModeParked = false;

    float targetLL = 1.0f, targetLR = 0.0f, targetRL = 0.0f, targetRR = 1.0f;
    if (snapshot->stereoMode.mode == N60StereoModeWideMono) {
        const float equalPower = 0.7071067811865476f;
        targetLL = targetLR = targetRL = targetRR = equalPower;
    } else if (snapshot->stereoMode.mode == N60StereoModeTrueMono) {
        targetLL = targetLR = targetRL = targetRR = 0.5f;
    }
    runtime->stereoMatrixLL = smooth_toward(runtime->stereoMatrixLL, targetLL, snapshot->bypassTransitionCoefficient);
    runtime->stereoMatrixLR = smooth_toward(runtime->stereoMatrixLR, targetLR, snapshot->bypassTransitionCoefficient);
    runtime->stereoMatrixRL = smooth_toward(runtime->stereoMatrixRL, targetRL, snapshot->bypassTransitionCoefficient);
    runtime->stereoMatrixRR = smooth_toward(runtime->stereoMatrixRR, targetRR, snapshot->bypassTransitionCoefficient);
    if (!enabled
        && near_one(runtime->stereoMatrixLL)
        && near_zero(runtime->stereoMatrixLR)
        && near_zero(runtime->stereoMatrixRL)
        && near_one(runtime->stereoMatrixRR)) {
        runtime->stereoMatrixLL = 1.0f;
        runtime->stereoMatrixLR = 0.0f;
        runtime->stereoMatrixRL = 0.0f;
        runtime->stereoMatrixRR = 1.0f;
        runtime->stereoModeParked = true;
        return;
    }
    float inputLeft = *left;
    float inputRight = *right;
    *left = inputLeft * runtime->stereoMatrixLL + inputRight * runtime->stereoMatrixLR;
    *right = inputLeft * runtime->stereoMatrixRL + inputRight * runtime->stereoMatrixRR;
}

''',
)

replace_span(
    source,
    "static void process_stereo_widener(",
    "static void process_loudness_match(",
    r'''static void process_stereo_widener(N60DynamicsRuntime *runtime, const N60DynamicsSnapshot *snapshot, float *left, float *right) {
    const N60StereoWidenerSnapshot *widener = &snapshot->stereoWidener;
    if (!widener->enabled && runtime->widenerParked) return;
    if (widener->enabled && runtime->widenerParked) {
        memset(runtime->widenerLowPass, 0, sizeof(runtime->widenerLowPass));
        memset(runtime->widenerHighPass, 0, sizeof(runtime->widenerHighPass));
        runtime->widenerLowWidth = 1.0f;
        runtime->widenerMidWidth = 1.0f;
        runtime->widenerHighWidth = 1.0f;
        runtime->widenerParked = false;
    }
    if (widener->sectionCount == 0) {
        runtime->widenerParked = !widener->enabled;
        return;
    }

    float dryLeft = *left;
    float dryRight = *right;
    float mid = 0.5f * (dryLeft + dryRight);
    float side = 0.5f * (dryLeft - dryRight);
    float lowSide = process_filter_cascade(widener->lowPass, runtime->widenerLowPass, widener->sectionCount, side);
    float highSide = process_filter_cascade(widener->highPass, runtime->widenerHighPass, widener->sectionCount, side);
    float midSide = side - lowSide - highSide;
    float lowTarget = widener->enabled ? (widener->monoLowBand ? 0.0f : widener->lowWidth) : 1.0f;
    float midTarget = widener->enabled ? widener->midWidth : 1.0f;
    float highTarget = widener->enabled ? widener->highWidth : 1.0f;
    runtime->widenerLowWidth = smooth_toward(runtime->widenerLowWidth, lowTarget, snapshot->bypassTransitionCoefficient);
    runtime->widenerMidWidth = smooth_toward(runtime->widenerMidWidth, midTarget, snapshot->bypassTransitionCoefficient);
    runtime->widenerHighWidth = smooth_toward(runtime->widenerHighWidth, highTarget, snapshot->bypassTransitionCoefficient);
    if (!widener->enabled
        && near_one(runtime->widenerLowWidth)
        && near_one(runtime->widenerMidWidth)
        && near_one(runtime->widenerHighWidth)) {
        runtime->widenerLowWidth = 1.0f;
        runtime->widenerMidWidth = 1.0f;
        runtime->widenerHighWidth = 1.0f;
        memset(runtime->widenerLowPass, 0, sizeof(runtime->widenerLowPass));
        memset(runtime->widenerHighPass, 0, sizeof(runtime->widenerHighPass));
        runtime->widenerParked = true;
        return;
    }
    float processedSide = lowSide * runtime->widenerLowWidth + midSide * runtime->widenerMidWidth + highSide * runtime->widenerHighWidth;
    *left = mid + processedSide;
    *right = mid - processedSide;
}

''',
)

replace_span(
    source,
    "static void process_loudness_match(",
    "static void process_loudness_contour(",
    r'''static void process_loudness_match(N60DynamicsRuntime *runtime, const N60DynamicsSnapshot *snapshot, float *left, float *right) {
    bool measurementNeeded = snapshot->loudnessMatch.enabled
        || (snapshot->loudnessContour.enabled
            && snapshot->loudnessContour.perBandMode
            && snapshot->loudnessContour.levelSource == N60LoudnessLevelSourceIntegrated);
    if (!measurementNeeded && !snapshot->loudnessMatch.enabled && runtime->loudnessMatchParked) return;
    if (measurementNeeded && runtime->loudnessMatchParked) {
        memset(&runtime->loudnessKWeightHighPassLeft, 0, sizeof(runtime->loudnessKWeightHighPassLeft));
        memset(&runtime->loudnessKWeightHighPassRight, 0, sizeof(runtime->loudnessKWeightHighPassRight));
        memset(&runtime->loudnessKWeightShelfLeft, 0, sizeof(runtime->loudnessKWeightShelfLeft));
        memset(&runtime->loudnessKWeightShelfRight, 0, sizeof(runtime->loudnessKWeightShelfRight));
        runtime->loudnessMeanSquare = 0.0f;
        runtime->loudnessMeasurementPrimed = false;
        runtime->loudnessMatchParked = false;
    }

    float measuredLUFS = -120.0f;
    if (measurementNeeded) {
        float weightedLeft = N60BiquadProcessSample(snapshot->loudnessMatch.kWeightHighPass, &runtime->loudnessKWeightHighPassLeft, *left);
        weightedLeft = N60BiquadProcessSample(snapshot->loudnessMatch.kWeightShelf, &runtime->loudnessKWeightShelfLeft, weightedLeft);
        float weightedRight = N60BiquadProcessSample(snapshot->loudnessMatch.kWeightHighPass, &runtime->loudnessKWeightHighPassRight, *right);
        weightedRight = N60BiquadProcessSample(snapshot->loudnessMatch.kWeightShelf, &runtime->loudnessKWeightShelfRight, weightedRight);
        float instantMeanSquare = 0.5f * (weightedLeft * weightedLeft + weightedRight * weightedRight);
        if (!runtime->loudnessMeasurementPrimed && instantMeanSquare > N60_DYNAMICS_EPSILON) {
            runtime->loudnessMeanSquare = instantMeanSquare;
            runtime->loudnessMeasurementPrimed = true;
        } else {
            runtime->loudnessMeanSquare = smooth_toward(runtime->loudnessMeanSquare, instantMeanSquare, snapshot->loudnessMatch.measurementCoefficient);
        }
        measuredLUFS = -0.691f + 10.0f * log10f(fmaxf(runtime->loudnessMeanSquare, N60_DYNAMICS_EPSILON));
    }

    if (!snapshot->loudnessMatch.enabled) {
        if (!near_zero(runtime->loudnessMatchGainDB)) {
            runtime->loudnessMatchGainDB = smooth_toward(runtime->loudnessMatchGainDB, 0.0f, snapshot->bypassTransitionCoefficient);
            if (!near_zero(runtime->loudnessMatchGainDB)) {
                float gain = db_to_linear(runtime->loudnessMatchGainDB);
                *left *= gain;
                *right *= gain;
            } else {
                runtime->loudnessMatchGainDB = 0.0f;
            }
        }
        if (!measurementNeeded && near_zero(runtime->loudnessMatchGainDB)) {
            runtime->loudnessMatchGainDB = 0.0f;
            runtime->loudnessMeanSquare = 0.0f;
            runtime->loudnessMeasurementPrimed = false;
            memset(&runtime->loudnessKWeightHighPassLeft, 0, sizeof(runtime->loudnessKWeightHighPassLeft));
            memset(&runtime->loudnessKWeightHighPassRight, 0, sizeof(runtime->loudnessKWeightHighPassRight));
            memset(&runtime->loudnessKWeightShelfLeft, 0, sizeof(runtime->loudnessKWeightShelfLeft));
            memset(&runtime->loudnessKWeightShelfRight, 0, sizeof(runtime->loudnessKWeightShelfRight));
            runtime->loudnessMatchParked = true;
        }
        return;
    }

    runtime->loudnessMatchParked = false;
    float targetGainDB = 0.0f;
    if (!(snapshot->loudnessMatch.dialogueGateEnabled && measuredLUFS < N60_LOUDNESS_GATE_LUFS)) {
        targetGainDB = clampf(snapshot->loudnessMatch.targetLUFS - measuredLUFS, -snapshot->loudnessMatch.maxCorrectionDB, snapshot->loudnessMatch.maxCorrectionDB);
    }
    float coefficient = targetGainDB < runtime->loudnessMatchGainDB ? snapshot->loudnessMatch.attackCoefficient : snapshot->loudnessMatch.releaseCoefficient;
    runtime->loudnessMatchGainDB = smooth_toward(runtime->loudnessMatchGainDB, targetGainDB, coefficient);
    float gain = db_to_linear(runtime->loudnessMatchGainDB);
    *left *= gain;
    *right *= gain;
}

''',
)

replace_span(
    source,
    "static void process_loudness_contour(",
    "static void process_de_harsh(",
    r'''static void process_loudness_contour(N60DynamicsRuntime *runtime, const N60DynamicsSnapshot *snapshot, float masterGainLinear, float *left, float *right) {
    float dryLeft = *left;
    float dryRight = *right;
    const N60LoudnessContourSnapshot *config = &snapshot->loudnessContour;
    if (!config->enabled && runtime->loudnessContourParked) return;
    if (config->enabled && runtime->loudnessContourParked) {
        memset(&runtime->loudnessLowShelfLeft, 0, sizeof(runtime->loudnessLowShelfLeft));
        memset(&runtime->loudnessLowShelfRight, 0, sizeof(runtime->loudnessLowShelfRight));
        memset(&runtime->loudnessHighShelfLeft, 0, sizeof(runtime->loudnessHighShelfLeft));
        memset(&runtime->loudnessHighShelfRight, 0, sizeof(runtime->loudnessHighShelfRight));
        memset(&runtime->loudnessLowBandLeft, 0, sizeof(runtime->loudnessLowBandLeft));
        memset(&runtime->loudnessLowBandRight, 0, sizeof(runtime->loudnessLowBandRight));
        memset(&runtime->loudnessHighBandLeft, 0, sizeof(runtime->loudnessHighBandLeft));
        memset(&runtime->loudnessHighBandRight, 0, sizeof(runtime->loudnessHighBandRight));
        runtime->loudnessMix = 0.0f;
        runtime->loudnessLowGainDB = 0.0f;
        runtime->loudnessHighGainDB = 0.0f;
        runtime->loudnessContourParked = false;
    }

    if (!config->perBandMode) {
        float wetLeft = N60BiquadProcessSample(config->lowShelf, &runtime->loudnessLowShelfLeft, dryLeft);
        wetLeft = N60BiquadProcessSample(config->highShelf, &runtime->loudnessHighShelfLeft, wetLeft);
        float wetRight = N60BiquadProcessSample(config->lowShelf, &runtime->loudnessLowShelfRight, dryRight);
        wetRight = N60BiquadProcessSample(config->highShelf, &runtime->loudnessHighShelfRight, wetRight);
        float volumeScale = 0.0f;
        if (masterGainLinear <= config->fullContourMasterGainLinear) volumeScale = 1.0f;
        else if (masterGainLinear < config->flatContourMasterGainLinear) {
            float masterDB = linear_to_db(masterGainLinear);
            volumeScale = (N60_LOUDNESS_FLAT_CONTOUR_DB - masterDB) / (N60_LOUDNESS_FLAT_CONTOUR_DB - N60_LOUDNESS_FULL_CONTOUR_DB);
            volumeScale = clampf(volumeScale, 0.0f, 1.0f);
        }
        float target = config->enabled ? volumeScale : 0.0f;
        runtime->loudnessMix = smooth_toward(runtime->loudnessMix, target, snapshot->bypassTransitionCoefficient);
        runtime->loudnessLowGainDB = N60_LOUDNESS_MAX_BASS_DB * config->strength * runtime->loudnessMix;
        runtime->loudnessHighGainDB = N60_LOUDNESS_MAX_TREBLE_DB * config->strength * runtime->loudnessMix;
        runtime->loudnessEstimatedPhons = config->referencePhons;
        if (!config->enabled && near_zero(runtime->loudnessMix)) {
            runtime->loudnessMix = 0.0f;
            runtime->loudnessLowGainDB = 0.0f;
            runtime->loudnessHighGainDB = 0.0f;
            runtime->loudnessEstimatedPhons = 0.0f;
            memset(&runtime->loudnessLowShelfLeft, 0, sizeof(runtime->loudnessLowShelfLeft));
            memset(&runtime->loudnessLowShelfRight, 0, sizeof(runtime->loudnessLowShelfRight));
            memset(&runtime->loudnessHighShelfLeft, 0, sizeof(runtime->loudnessHighShelfLeft));
            memset(&runtime->loudnessHighShelfRight, 0, sizeof(runtime->loudnessHighShelfRight));
            runtime->loudnessContourParked = true;
            return;
        }
        *left = dryLeft + (wetLeft - dryLeft) * runtime->loudnessMix;
        *right = dryRight + (wetRight - dryRight) * runtime->loudnessMix;
        return;
    }

    float lowLeft = N60BiquadProcessSample(config->lowBandLowPass, &runtime->loudnessLowBandLeft, dryLeft);
    float lowRight = N60BiquadProcessSample(config->lowBandLowPass, &runtime->loudnessLowBandRight, dryRight);
    float highLeft = N60BiquadProcessSample(config->highBandHighPass, &runtime->loudnessHighBandLeft, dryLeft);
    float highRight = N60BiquadProcessSample(config->highBandHighPass, &runtime->loudnessHighBandRight, dryRight);
    float measuredLUFS = -0.691f + 10.0f * log10f(fmaxf(runtime->loudnessMeanSquare, N60_DYNAMICS_EPSILON));
    float estimatedPhons;
    if (config->levelSource == N60LoudnessLevelSourceIntegrated) {
        estimatedPhons = config->referencePhons + (measuredLUFS - N60_LOUDNESS_INTEGRATED_REFERENCE_LUFS);
    } else {
        float masterDB = linear_to_db(fmaxf(masterGainLinear, N60_DYNAMICS_EPSILON));
        estimatedPhons = config->referencePhons + (masterDB - N60_LOUDNESS_FLAT_CONTOUR_DB);
    }
    runtime->loudnessEstimatedPhons = estimatedPhons;
    float phonDelta = config->referencePhons - estimatedPhons;
    float lowTargetDB = 0.0f, highTargetDB = 0.0f;
    if (config->enabled && phonDelta >= 0.0f) {
        lowTargetDB = fminf(config->maxBoostDB, phonDelta * N60_LOUDNESS_LOW_DB_PER_PHON) * config->strength;
        highTargetDB = fminf(config->maxBoostDB, phonDelta * N60_LOUDNESS_HIGH_DB_PER_PHON) * config->strength;
    } else if (config->enabled) {
        float surplus = -phonDelta;
        lowTargetDB = -fminf(config->maxCutDB, surplus * N60_LOUDNESS_LOW_CUT_DB_PER_PHON) * config->strength;
        highTargetDB = -fminf(config->maxCutDB, surplus * N60_LOUDNESS_HIGH_CUT_DB_PER_PHON) * config->strength;
    }
    float coefficient = config->enabled ? config->responseCoefficient : snapshot->bypassTransitionCoefficient;
    runtime->loudnessLowGainDB = smooth_toward(runtime->loudnessLowGainDB, lowTargetDB, coefficient);
    runtime->loudnessHighGainDB = smooth_toward(runtime->loudnessHighGainDB, highTargetDB, coefficient);
    if (!config->enabled && near_zero(runtime->loudnessLowGainDB) && near_zero(runtime->loudnessHighGainDB)) {
        runtime->loudnessLowGainDB = 0.0f;
        runtime->loudnessHighGainDB = 0.0f;
        runtime->loudnessMix = 0.0f;
        runtime->loudnessEstimatedPhons = 0.0f;
        memset(&runtime->loudnessLowBandLeft, 0, sizeof(runtime->loudnessLowBandLeft));
        memset(&runtime->loudnessLowBandRight, 0, sizeof(runtime->loudnessLowBandRight));
        memset(&runtime->loudnessHighBandLeft, 0, sizeof(runtime->loudnessHighBandLeft));
        memset(&runtime->loudnessHighBandRight, 0, sizeof(runtime->loudnessHighBandRight));
        runtime->loudnessContourParked = true;
        return;
    }
    float lowGain = db_to_linear(runtime->loudnessLowGainDB);
    float highGain = db_to_linear(runtime->loudnessHighGainDB);
    *left = dryLeft + lowLeft * (lowGain - 1.0f) + highLeft * (highGain - 1.0f);
    *right = dryRight + lowRight * (lowGain - 1.0f) + highRight * (highGain - 1.0f);
    float normalization = fmaxf(config->maxBoostDB, fmaxf(config->maxCutDB, 1.0f));
    runtime->loudnessMix = clampf(fmaxf(fabsf(runtime->loudnessLowGainDB), fabsf(runtime->loudnessHighGainDB)) / normalization, 0.0f, 1.0f);
}

''',
)

replace_span(
    source,
    "static void process_de_harsh(",
    "static void process_dialogue_leveler(",
    r'''static void process_de_harsh(N60DynamicsRuntime *runtime, const N60DynamicsSnapshot *snapshot, float *left, float *right) {
    if (!snapshot->deHarsh.enabled && runtime->deHarshParked) return;
    if (snapshot->deHarsh.enabled && runtime->deHarshParked) {
        memset(&runtime->deHarshLeft, 0, sizeof(runtime->deHarshLeft));
        memset(&runtime->deHarshRight, 0, sizeof(runtime->deHarshRight));
        runtime->deHarshMix = 0.0f;
        runtime->deHarshParked = false;
    }
    float dryLeft = *left, dryRight = *right;
    float wetLeft = N60BiquadProcessSample(snapshot->deHarsh.highShelf, &runtime->deHarshLeft, dryLeft);
    float wetRight = N60BiquadProcessSample(snapshot->deHarsh.highShelf, &runtime->deHarshRight, dryRight);
    float target = snapshot->deHarsh.enabled ? 1.0f : 0.0f;
    runtime->deHarshMix = smooth_toward(runtime->deHarshMix, target, snapshot->bypassTransitionCoefficient);
    if (!snapshot->deHarsh.enabled && near_zero(runtime->deHarshMix)) {
        runtime->deHarshMix = 0.0f;
        memset(&runtime->deHarshLeft, 0, sizeof(runtime->deHarshLeft));
        memset(&runtime->deHarshRight, 0, sizeof(runtime->deHarshRight));
        runtime->deHarshParked = true;
        return;
    }
    *left = dryLeft + (wetLeft - dryLeft) * runtime->deHarshMix;
    *right = dryRight + (wetRight - dryRight) * runtime->deHarshMix;
}

''',
)

replace_span(
    source,
    "static void process_dialogue_leveler(",
    "static void process_de_esser(",
    r'''static void process_dialogue_leveler(N60DynamicsRuntime *runtime, const N60DynamicsSnapshot *snapshot, float *left, float *right) {
    const N60DialogueLevelerSnapshot *config = &snapshot->dialogueLeveler;
    if (!config->enabled && runtime->dialogueLevelerParked) return;
    if (config->enabled && runtime->dialogueLevelerParked) {
        memset(&runtime->dialogueHighPassLeft, 0, sizeof(runtime->dialogueHighPassLeft));
        memset(&runtime->dialogueHighPassRight, 0, sizeof(runtime->dialogueHighPassRight));
        memset(&runtime->dialogueLowPassLeft, 0, sizeof(runtime->dialogueLowPassLeft));
        memset(&runtime->dialogueLowPassRight, 0, sizeof(runtime->dialogueLowPassRight));
        runtime->dialogueProgramMeanSquare = 0.0f;
        runtime->dialogueBandMeanSquare = 0.0f;
        runtime->dialogueVoiceEnvelope = 0.0f;
        runtime->dialogueModulationPreviousInput = 0.0f;
        runtime->dialogueModulationHighPassOutput = 0.0f;
        runtime->dialogueModulationLowPassOutput = 0.0f;
        runtime->dialogueModulationMeanSquare = 0.0f;
        runtime->dialogueBoostDB = 0.0f;
        runtime->dialogueLevelerParked = false;
    }
    float dryLeft = *left, dryRight = *right;
    float dialogueLeft = N60BiquadProcessSample(config->bandHighPass, &runtime->dialogueHighPassLeft, dryLeft);
    dialogueLeft = N60BiquadProcessSample(config->bandLowPass, &runtime->dialogueLowPassLeft, dialogueLeft);
    float dialogueRight = N60BiquadProcessSample(config->bandHighPass, &runtime->dialogueHighPassRight, dryRight);
    dialogueRight = N60BiquadProcessSample(config->bandLowPass, &runtime->dialogueLowPassRight, dialogueRight);
    float programPower = 0.5f * (dryLeft * dryLeft + dryRight * dryRight);
    float dialoguePower = 0.5f * (dialogueLeft * dialogueLeft + dialogueRight * dialogueRight);
    runtime->dialogueProgramMeanSquare = smooth_toward(runtime->dialogueProgramMeanSquare, programPower, config->detectorCoefficient);
    runtime->dialogueBandMeanSquare = smooth_toward(runtime->dialogueBandMeanSquare, dialoguePower, config->detectorCoefficient);
    runtime->dialogueProgramLevelDBFS = 10.0f * log10f(fmaxf(runtime->dialogueProgramMeanSquare, N60_DYNAMICS_EPSILON));
    runtime->dialogueBandLevelDBFS = 10.0f * log10f(fmaxf(runtime->dialogueBandMeanSquare, N60_DYNAMICS_EPSILON));
    runtime->dialogueGapDB = runtime->dialogueProgramLevelDBFS - runtime->dialogueBandLevelDBFS;
    float dialogueEnvelopeInput = sqrtf(fmaxf(dialoguePower, 0.0f));
    runtime->dialogueVoiceEnvelope = smooth_toward(runtime->dialogueVoiceEnvelope, dialogueEnvelopeInput, config->voiceEnvelopeCoefficient);
    float modulationHP = runtime->dialogueVoiceEnvelope - runtime->dialogueModulationPreviousInput + config->modulationHighPassPole * runtime->dialogueModulationHighPassOutput;
    runtime->dialogueModulationPreviousInput = runtime->dialogueVoiceEnvelope;
    runtime->dialogueModulationHighPassOutput = modulationHP;
    float modulationLP = (1.0f - config->modulationLowPassPole) * modulationHP + config->modulationLowPassPole * runtime->dialogueModulationLowPassOutput;
    runtime->dialogueModulationLowPassOutput = modulationLP;
    float modulationPower = modulationLP * modulationLP;
    runtime->dialogueModulationMeanSquare = smooth_toward(runtime->dialogueModulationMeanSquare, modulationPower, config->voiceMeasurementCoefficient);
    float modulationIndex = sqrtf(fmaxf(runtime->dialogueModulationMeanSquare, 0.0f)) / fmaxf(runtime->dialogueVoiceEnvelope, 1.0e-6f);
    float mappedConfidence = (modulationIndex - config->confidenceFloorIndex) / fmaxf(config->confidenceCeilingIndex - config->confidenceFloorIndex, 1.0e-6f);
    mappedConfidence = clampf(mappedConfidence, 0.0f, 1.0f);
    runtime->dialogueVoiceConfidence = config->voiceGateEnabled ? config->minConfidence + (1.0f - config->minConfidence) * mappedConfidence : 1.0f;
    float targetBoostDB = 0.0f;
    if (config->enabled && runtime->dialogueProgramLevelDBFS >= config->programGateThresholdDB) {
        float excessGap = fmaxf(0.0f, runtime->dialogueGapDB - config->targetGapDB);
        float correctionFraction = config->boostRatio > 1.0f ? (1.0f - 1.0f / config->boostRatio) : 0.0f;
        targetBoostDB = fminf(config->maxBoostDB, excessGap * correctionFraction) * runtime->dialogueVoiceConfidence;
    }
    float coefficient = !config->enabled ? snapshot->bypassTransitionCoefficient : (targetBoostDB > runtime->dialogueBoostDB ? config->attackCoefficient : config->releaseCoefficient);
    runtime->dialogueBoostDB = smooth_toward(runtime->dialogueBoostDB, targetBoostDB, coefficient);
    if (!config->enabled && near_zero(runtime->dialogueBoostDB)) {
        runtime->dialogueBoostDB = 0.0f;
        runtime->dialogueProgramMeanSquare = 0.0f;
        runtime->dialogueBandMeanSquare = 0.0f;
        runtime->dialogueVoiceEnvelope = 0.0f;
        runtime->dialogueModulationPreviousInput = 0.0f;
        runtime->dialogueModulationHighPassOutput = 0.0f;
        runtime->dialogueModulationLowPassOutput = 0.0f;
        runtime->dialogueModulationMeanSquare = 0.0f;
        runtime->dialogueProgramLevelDBFS = 0.0f;
        runtime->dialogueBandLevelDBFS = 0.0f;
        runtime->dialogueGapDB = 0.0f;
        runtime->dialogueVoiceConfidence = 0.0f;
        memset(&runtime->dialogueHighPassLeft, 0, sizeof(runtime->dialogueHighPassLeft));
        memset(&runtime->dialogueHighPassRight, 0, sizeof(runtime->dialogueHighPassRight));
        memset(&runtime->dialogueLowPassLeft, 0, sizeof(runtime->dialogueLowPassLeft));
        memset(&runtime->dialogueLowPassRight, 0, sizeof(runtime->dialogueLowPassRight));
        runtime->dialogueLevelerParked = true;
        return;
    }
    float bandGain = db_to_linear(runtime->dialogueBoostDB);
    *left = dryLeft + dialogueLeft * (bandGain - 1.0f);
    *right = dryRight + dialogueRight * (bandGain - 1.0f);
}

''',
)

replace_span(
    source,
    "static void process_de_esser(",
    "static void process_multiband_compressor(",
    r'''static void process_de_esser(N60DynamicsRuntime *runtime, const N60DynamicsSnapshot *snapshot, float *left, float *right) {
    if (!snapshot->deEsser.enabled && runtime->deEsserParked) return;
    if (snapshot->deEsser.enabled && runtime->deEsserParked) {
        memset(&runtime->deEsserHighPassLeft, 0, sizeof(runtime->deEsserHighPassLeft));
        memset(&runtime->deEsserHighPassRight, 0, sizeof(runtime->deEsserHighPassRight));
        memset(&runtime->deEsserLowPassLeft, 0, sizeof(runtime->deEsserLowPassLeft));
        memset(&runtime->deEsserLowPassRight, 0, sizeof(runtime->deEsserLowPassRight));
        runtime->deEsserGainDB = 0.0f;
        runtime->deEsserParked = false;
    }
    float dryLeft = *left, dryRight = *right;
    float bandLeft = N60BiquadProcessSample(snapshot->deEsser.sidechainHighPass, &runtime->deEsserHighPassLeft, dryLeft);
    bandLeft = N60BiquadProcessSample(snapshot->deEsser.sidechainLowPass, &runtime->deEsserLowPassLeft, bandLeft);
    float bandRight = N60BiquadProcessSample(snapshot->deEsser.sidechainHighPass, &runtime->deEsserHighPassRight, dryRight);
    bandRight = N60BiquadProcessSample(snapshot->deEsser.sidechainLowPass, &runtime->deEsserLowPassRight, bandRight);
    float detector = fmaxf(fabsf(bandLeft), fabsf(bandRight));
    float targetDB = dynamics_compression_target(detector, snapshot->deEsser.enabled, snapshot->deEsser.thresholdDB, snapshot->deEsser.ratio, 3.0f);
    targetDB = fmaxf(targetDB, snapshot->deEsser.rangeDB);
    float coefficient = !snapshot->deEsser.enabled ? snapshot->bypassTransitionCoefficient : (targetDB < runtime->deEsserGainDB ? snapshot->deEsser.attackCoefficient : snapshot->deEsser.releaseCoefficient);
    runtime->deEsserGainDB = smooth_toward(runtime->deEsserGainDB, targetDB, coefficient);
    if (!snapshot->deEsser.enabled && near_zero(runtime->deEsserGainDB)) {
        runtime->deEsserGainDB = 0.0f;
        memset(&runtime->deEsserHighPassLeft, 0, sizeof(runtime->deEsserHighPassLeft));
        memset(&runtime->deEsserHighPassRight, 0, sizeof(runtime->deEsserHighPassRight));
        memset(&runtime->deEsserLowPassLeft, 0, sizeof(runtime->deEsserLowPassLeft));
        memset(&runtime->deEsserLowPassRight, 0, sizeof(runtime->deEsserLowPassRight));
        runtime->deEsserParked = true;
        return;
    }
    float gain = db_to_linear(runtime->deEsserGainDB);
    if (snapshot->deEsser.dynamicEQMode) {
        *left = dryLeft + (gain - 1.0f) * bandLeft;
        *right = dryRight + (gain - 1.0f) * bandRight;
    } else {
        *left = dryLeft * gain;
        *right = dryRight * gain;
    }
}

''',
)

replace_span(
    source,
    "static void process_multiband_compressor(",
    "void N60DynamicsProcessDynamicEQStereoFrame(",
    r'''static void process_multiband_compressor(N60DynamicsRuntime *runtime, const N60DynamicsSnapshot *snapshot, float *left, float *right) {
    const N60MultibandCompressorSnapshot *multiband = &snapshot->multibandCompressor;
    if (!multiband->enabled && runtime->multibandParked) return;
    if (multiband->enabled && runtime->multibandParked) {
        memset(runtime->multibandSidechainLeft, 0, sizeof(runtime->multibandSidechainLeft));
        memset(runtime->multibandSidechainRight, 0, sizeof(runtime->multibandSidechainRight));
        memset(runtime->multibandLowPassLeft, 0, sizeof(runtime->multibandLowPassLeft));
        memset(runtime->multibandLowPassRight, 0, sizeof(runtime->multibandLowPassRight));
        memset(runtime->multibandHighPassLeft, 0, sizeof(runtime->multibandHighPassLeft));
        memset(runtime->multibandHighPassRight, 0, sizeof(runtime->multibandHighPassRight));
        for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) runtime->multibandGainDB[band] = 0.0f;
        runtime->multibandParked = false;
    }
    if (multiband->lowSectionCount == 0 || multiband->highSectionCount == 0) {
        if (!multiband->enabled) runtime->multibandParked = true;
        return;
    }
    float dryLeft = *left, dryRight = *right;
    float lowLeft = process_filter_cascade(multiband->lowPass, runtime->multibandLowPassLeft, multiband->lowSectionCount, dryLeft);
    float lowRight = process_filter_cascade(multiband->lowPass, runtime->multibandLowPassRight, multiband->lowSectionCount, dryRight);
    float highLeft = process_filter_cascade(multiband->highPass, runtime->multibandHighPassLeft, multiband->highSectionCount, dryLeft);
    float highRight = process_filter_cascade(multiband->highPass, runtime->multibandHighPassRight, multiband->highSectionCount, dryRight);
    float midLeft = dryLeft - lowLeft - highLeft;
    float midRight = dryRight - lowRight - highRight;
    const float bandLeft[N60_MULTIBAND_BAND_COUNT] = {lowLeft, midLeft, highLeft};
    const float bandRight[N60_MULTIBAND_BAND_COUNT] = {lowRight, midRight, highRight};
    float outputLeft = 0.0f, outputRight = 0.0f;
    bool neutral = true;
    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        float targetDB = 0.0f;
        if (multiband->enabled) {
            float detectorLeft = N60BiquadProcessSample(multiband->sidechainHighPass[band], &runtime->multibandSidechainLeft[band], bandLeft[band]);
            float detectorRight = N60BiquadProcessSample(multiband->sidechainHighPass[band], &runtime->multibandSidechainRight[band], bandRight[band]);
            float detector = fmaxf(fabsf(detectorLeft), fabsf(detectorRight));
            targetDB = dynamics_compression_target(detector, true, multiband->thresholdDB[band], multiband->ratio[band], multiband->kneeWidthDB[band]);
            targetDB += multiband->makeupGainDB[band];
        }
        float coefficient = !multiband->enabled ? snapshot->bypassTransitionCoefficient : (targetDB < runtime->multibandGainDB[band] ? multiband->attackCoefficient[band] : multiband->releaseCoefficient[band]);
        runtime->multibandGainDB[band] = smooth_toward(runtime->multibandGainDB[band], targetDB, coefficient);
        if (near_zero(runtime->multibandGainDB[band])) runtime->multibandGainDB[band] = 0.0f;
        else neutral = false;
        float gain = db_to_linear(runtime->multibandGainDB[band]);
        outputLeft += bandLeft[band] * gain;
        outputRight += bandRight[band] * gain;
    }
    if (!multiband->enabled && neutral) {
        memset(runtime->multibandSidechainLeft, 0, sizeof(runtime->multibandSidechainLeft));
        memset(runtime->multibandSidechainRight, 0, sizeof(runtime->multibandSidechainRight));
        memset(runtime->multibandLowPassLeft, 0, sizeof(runtime->multibandLowPassLeft));
        memset(runtime->multibandLowPassRight, 0, sizeof(runtime->multibandLowPassRight));
        memset(runtime->multibandHighPassLeft, 0, sizeof(runtime->multibandHighPassLeft));
        memset(runtime->multibandHighPassRight, 0, sizeof(runtime->multibandHighPassRight));
        runtime->multibandParked = true;
        return;
    }
    *left = outputLeft;
    *right = outputRight;
}

''',
)

replace_exact(
    source,
    """    runtime->gateOpen = true;\n    runtime->preEQParked = true;\n    runtime->coreParked = true;""",
    """    runtime->gateOpen = true;\n    runtime->preEQParked = true;\n    runtime->coreParked = true;\n    runtime->dcParked = true;\n    runtime->infrasonicParked = true;\n    runtime->mainsNotchParked = true;\n    runtime->mainsDetectorParked = true;\n    runtime->stereoModeParked = true;\n    runtime->widenerParked = true;\n    runtime->loudnessMatchParked = true;\n    runtime->loudnessContourParked = true;\n    runtime->dialogueLevelerParked = true;\n    runtime->deHarshParked = true;\n    runtime->deEsserParked = true;\n    runtime->multibandParked = true;\n    runtime->compressorParked = true;\n    runtime->expanderParked = true;\n    runtime->pauseGateParked = true;""",
)

replace_span(
    source,
    "    float detectorFeedGain = snapshot->compressor.topology == N60CompressorTopologyFeedBack",
    "}\n\nvoid N60DynamicsProcessCoreStereoFrame(",
    r'''    if (snapshot->compressor.enabled) {
        if (runtime->compressorParked) {
            memset(&runtime->compressorSidechainLeft, 0, sizeof(runtime->compressorSidechainLeft));
            memset(&runtime->compressorSidechainRight, 0, sizeof(runtime->compressorSidechainRight));
            runtime->compressorGainDB = 0.0f;
            runtime->compressorParked = false;
        }
        float detectorFeedGain = snapshot->compressor.topology == N60CompressorTopologyFeedBack ? db_to_linear(runtime->compressorGainDB) : 1.0f;
        float compressorDetectorLeft = N60BiquadProcessSample(snapshot->compressor.sidechainHighPass, &runtime->compressorSidechainLeft, *left * detectorFeedGain);
        float compressorDetectorRight = N60BiquadProcessSample(snapshot->compressor.sidechainHighPass, &runtime->compressorSidechainRight, *right * detectorFeedGain);
        float detector = fmaxf(fabsf(compressorDetectorLeft), fabsf(compressorDetectorRight));
        float detectorDB = linear_to_db(detector);
        float compressorTargetDB = compressor_target_gain_db(detectorDB, &snapshot->compressor);
        float compressorCoefficient;
        if (compressorTargetDB < runtime->compressorGainDB) compressorCoefficient = snapshot->compressor.attackCoefficient;
        else if (snapshot->compressor.programDependentRelease) {
            float depth = clampf(-runtime->compressorGainDB / 12.0f, 0.0f, 1.0f);
            compressorCoefficient = snapshot->compressor.releaseFastCoefficient + depth * (snapshot->compressor.releaseSlowCoefficient - snapshot->compressor.releaseFastCoefficient);
        } else compressorCoefficient = snapshot->compressor.releaseCoefficient;
        runtime->compressorGainDB = smooth_toward(runtime->compressorGainDB, compressorTargetDB, compressorCoefficient);
        float compressorGain = db_to_linear(runtime->compressorGainDB);
        *left *= compressorGain;
        *right *= compressorGain;
    } else if (!runtime->compressorParked) {
        runtime->compressorGainDB = smooth_toward(runtime->compressorGainDB, 0.0f, snapshot->bypassTransitionCoefficient);
        if (near_zero(runtime->compressorGainDB)) {
            runtime->compressorGainDB = 0.0f;
            memset(&runtime->compressorSidechainLeft, 0, sizeof(runtime->compressorSidechainLeft));
            memset(&runtime->compressorSidechainRight, 0, sizeof(runtime->compressorSidechainRight));
            runtime->compressorParked = true;
        } else {
            float compressorGain = db_to_linear(runtime->compressorGainDB);
            *left *= compressorGain;
            *right *= compressorGain;
        }
    }

    if (snapshot->expander.enabled) {
        if (runtime->expanderParked) {
            runtime->expanderGainDB = 0.0f;
            runtime->expanderParked = false;
        }
        float detector = fmaxf(fabsf(*left), fabsf(*right));
        float detectorDB = linear_to_db(detector);
        float expanderTargetDB = expander_target_gain_db(detectorDB, &snapshot->expander);
        float expanderCoefficient = expanderTargetDB < runtime->expanderGainDB ? snapshot->expander.attackCoefficient : snapshot->expander.releaseCoefficient;
        runtime->expanderGainDB = smooth_toward(runtime->expanderGainDB, expanderTargetDB, expanderCoefficient);
        float expanderGain = db_to_linear(runtime->expanderGainDB);
        *left *= expanderGain;
        *right *= expanderGain;
    } else if (!runtime->expanderParked) {
        runtime->expanderGainDB = smooth_toward(runtime->expanderGainDB, 0.0f, snapshot->bypassTransitionCoefficient);
        if (near_zero(runtime->expanderGainDB)) {
            runtime->expanderGainDB = 0.0f;
            runtime->expanderParked = true;
        } else {
            float expanderGain = db_to_linear(runtime->expanderGainDB);
            *left *= expanderGain;
            *right *= expanderGain;
        }
    }
''',
)

replace_span(
    source,
    "void N60DynamicsProcessPauseGateStereoFrame(",
    "void N60DynamicsProcessStereoFrame(",
    r'''void N60DynamicsProcessPauseGateStereoFrame(N60DynamicsRuntime *runtime, const N60DynamicsSnapshot *snapshot, float *left, float *right) {
    if (runtime == NULL || snapshot == NULL || left == NULL || right == NULL) return;
    if (!snapshot->pauseGate.enabled && runtime->pauseGateParked) return;
    if (snapshot->pauseGate.enabled && runtime->pauseGateParked) {
        runtime->pauseGateGain = 1.0f;
        runtime->gateDetectorEnvelope = 0.0f;
        runtime->gateBelowThresholdFrames = 0u;
        runtime->gateOpen = true;
        runtime->pauseGateParked = false;
    }
    if (!snapshot->pauseGate.enabled && near_one(runtime->pauseGateGain)) {
        runtime->pauseGateGain = 1.0f;
        runtime->gateDetectorEnvelope = 0.0f;
        runtime->gateBelowThresholdFrames = 0u;
        runtime->gateOpen = true;
        runtime->pauseGateParked = true;
        return;
    }
    float gateDetectorInput = fmaxf(fabsf(*left), fabsf(*right));
    float detectorCoefficient = gateDetectorInput > runtime->gateDetectorEnvelope ? snapshot->pauseGate.detectorAttackCoefficient : snapshot->pauseGate.detectorReleaseCoefficient;
    runtime->gateDetectorEnvelope = smooth_toward(runtime->gateDetectorEnvelope, gateDetectorInput, detectorCoefficient);
    float gateTarget = 1.0f;
    float gateCoefficient = snapshot->bypassTransitionCoefficient;
    if (snapshot->pauseGate.enabled) {
        float gateLevelDB = linear_to_db(runtime->gateDetectorEnvelope);
        float openThresholdDB = snapshot->pauseGate.thresholdDBFS + snapshot->pauseGate.hysteresisDB;
        if (!runtime->gateOpen) {
            if (gateLevelDB >= openThresholdDB) {
                runtime->gateOpen = true;
                runtime->gateBelowThresholdFrames = 0;
            }
        } else if (gateLevelDB <= snapshot->pauseGate.thresholdDBFS) {
            if (runtime->gateBelowThresholdFrames < snapshot->pauseGate.holdFrames) runtime->gateBelowThresholdFrames += 1;
            if (runtime->gateBelowThresholdFrames >= snapshot->pauseGate.holdFrames) runtime->gateOpen = false;
        } else runtime->gateBelowThresholdFrames = 0;
        gateTarget = runtime->gateOpen ? 1.0f : 0.0f;
        gateCoefficient = gateTarget < runtime->pauseGateGain ? snapshot->pauseGate.fadeOutCoefficient : snapshot->pauseGate.fadeInCoefficient;
    } else {
        runtime->gateOpen = true;
        runtime->gateBelowThresholdFrames = 0;
    }
    runtime->pauseGateGain = smooth_toward(runtime->pauseGateGain, gateTarget, gateCoefficient);
    if (!snapshot->pauseGate.enabled && near_one(runtime->pauseGateGain)) {
        runtime->pauseGateGain = 1.0f;
        runtime->gateDetectorEnvelope = 0.0f;
        runtime->pauseGateParked = true;
        return;
    }
    *left *= runtime->pauseGateGain;
    *right *= runtime->pauseGateGain;
}

''',
)

print("PR35 individual Dynamics stage parking patch applied")
