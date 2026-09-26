from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"anchor not found: {label}")
    return text.replace(old, new, 1)

# ---- N60Dynamics.h -------------------------------------------------------------
h = Path('NotchSixty/Audio/Realtime/N60Dynamics.h')
text = h.read_text()
text = replace_once(text,
    '#define N60_MAX_MAINS_HARMONICS 16\n',
    '#define N60_MAX_MAINS_HARMONICS 16\n#define N60_MAINS_DETECTOR_BIN_COUNT 25\n',
    'detector define')

notch_struct = '''typedef struct {
    bool enabled;
    double fundamentalHz;
    uint32_t harmonicCount;
    float q;
    float depthsDB[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchCoefficients filters[N60_MAX_MAINS_HARMONICS];
} N60MainsNotchSnapshot;
'''
detector_struct = notch_struct + '''
typedef struct {
    bool enabled;
    double searchCenterHz;
    double searchStartHz;
    double binSpacingHz;
    uint32_t decimationFactor;
    uint32_t windowSamples;
    float oscillatorStepCos[N60_MAINS_DETECTOR_BIN_COUNT];
    float oscillatorStepSin[N60_MAINS_DETECTOR_BIN_COUNT];
} N60MainsHumDetectorSnapshot;
'''
text = replace_once(text, notch_struct, detector_struct, 'detector snapshot')
text = replace_once(text,
    '    N60MainsNotchSnapshot mainsNotch;\n    N60LoudnessMatchSnapshot loudnessMatch;\n',
    '    N60MainsNotchSnapshot mainsNotch;\n    N60MainsHumDetectorSnapshot mainsHumDetector;\n    N60LoudnessMatchSnapshot loudnessMatch;\n',
    'detector snapshot member')

runtime_anchor = '''    N60MainsNotchState mainsNotchLeft[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchState mainsNotchRight[N60_MAX_MAINS_HARMONICS];
    float mainsNotchMix;
'''
runtime_repl = '''    N60MainsNotchCoefficients mainsNotchCurrentFilters[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchCoefficients mainsNotchPendingFilters[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchState mainsNotchLeft[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchState mainsNotchRight[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchState mainsNotchPendingLeft[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchState mainsNotchPendingRight[N60_MAX_MAINS_HARMONICS];
    double mainsNotchCurrentFundamentalHz;
    double mainsNotchPendingFundamentalHz;
    float mainsNotchCurrentQ;
    float mainsNotchPendingQ;
    uint32_t mainsNotchCurrentHarmonicCount;
    uint32_t mainsNotchPendingHarmonicCount;
    float mainsNotchCurrentDepthsDB[N60_MAX_MAINS_HARMONICS];
    float mainsNotchPendingDepthsDB[N60_MAX_MAINS_HARMONICS];
    uint32_t mainsNotchTransitionFramesTotal;
    uint32_t mainsNotchTransitionFramesRemaining;
    bool mainsNotchInitialized;
    float mainsNotchMix;
    uint32_t mainsDetectorDecimationCounter;
    uint32_t mainsDetectorSampleCount;
    double mainsDetectorOscCos[N60_MAINS_DETECTOR_BIN_COUNT];
    double mainsDetectorOscSin[N60_MAINS_DETECTOR_BIN_COUNT];
    double mainsDetectorReal[N60_MAINS_DETECTOR_BIN_COUNT];
    double mainsDetectorImag[N60_MAINS_DETECTOR_BIN_COUNT];
    double mainsDetectorWindowEnergy;
    float mainsDetectedFrequencyHz;
    float mainsDetectionConfidence;
'''
text = replace_once(text, runtime_anchor, runtime_repl, 'detector runtime')

telemetry_anchor = '''typedef struct {
    float deEsserGainReductionDB;
'''
telemetry_repl = '''typedef struct {
    float mainsDetectedFrequencyHz;
    float mainsDetectionConfidence;
    float deEsserGainReductionDB;
'''
text = replace_once(text, telemetry_anchor, telemetry_repl, 'detector telemetry')

setter_decl_anchor = '''bool N60DynamicsSnapshotSetMainsNotch(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double fundamentalHz,
    uint32_t harmonicCount,
    float q,
    const float * _Nonnull depthsDB,
    uint32_t depthCount
);
'''
setter_decl_repl = setter_decl_anchor + '''
bool N60DynamicsSnapshotSetMainsHumDetector(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double searchCenterHz
);
'''
text = replace_once(text, setter_decl_anchor, setter_decl_repl, 'detector setter declaration')
h.write_text(text)

# ---- N60Dynamics.c -------------------------------------------------------------
c = Path('NotchSixty/Audio/Realtime/N60Dynamics.c')
text = c.read_text()
text = replace_once(text,
    '#define N60_LOUDNESS_FLAT_CONTOUR_DB -6.0f\n',
    '#define N60_LOUDNESS_FLAT_CONTOUR_DB -6.0f\n#define N60_MAINS_DETECTOR_SPAN_HZ 3.0\n#define N60_MAINS_DETECTOR_BIN_SPACING_HZ 0.25\n#define N60_MAINS_DETECTOR_TARGET_RATE 1000.0\n#define N60_MAINS_DETECTOR_WINDOW_SECONDS 1.0\n#define N60_MAINS_DETECTOR_MIN_LEVEL_DBFS -78.0\n#define N60_MAINS_NOTCH_RETUNE_SECONDS 0.010\n',
    'detector constants')

helper_anchor = '''static float process_mains_notch_cascade(
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
'''
helper_repl = helper_anchor + r'''
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
    double normalizedTonePower = 4.0 * bestPower / fmax(n * n, 1.0);
    double levelDBFS = 10.0 * log10(fmax(normalizedTonePower, 1.0e-20));
    double prominence = bestPower > 1.0e-20 ? 1.0 - backgroundMean / bestPower : 0.0;
    prominence = fmin(fmax(prominence, 0.0), 1.0);
    if (levelDBFS < N60_MAINS_DETECTOR_MIN_LEVEL_DBFS) prominence = 0.0;

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
    runtime->mainsDetectionConfidence = (float)prominence;
    reset_mains_detector_window(runtime);
}
'''
text = replace_once(text, helper_anchor, helper_repl, 'detector helpers')

# defaults
mains_default = '''    snapshot.mainsNotch.enabled = false;
    snapshot.mainsNotch.fundamentalHz = 60.0;
    snapshot.mainsNotch.harmonicCount = 8;
    snapshot.mainsNotch.q = 30.0f;
    for (uint32_t index = 0; index < N60_MAX_MAINS_HARMONICS; ++index) {
        snapshot.mainsNotch.depthsDB[index] = 0.0f;
        snapshot.mainsNotch.filters[index] = mains_notch_identity();
    }
'''
mains_default_repl = mains_default + '''
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
'''
text = replace_once(text, mains_default, mains_default_repl, 'detector defaults')

# setter
setter_anchor = '''    snapshot->mainsNotch = configured;
    return true;
}

bool N60DynamicsSnapshotSetLoudnessMatch(
'''
setter_repl = r'''    snapshot->mainsNotch = configured;
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

bool N60DynamicsSnapshotSetLoudnessMatch(
'''
text = replace_once(text, setter_anchor, setter_repl, 'detector setter')

# validation
valid_anchor = '''    for (uint32_t index = 0; index < snapshot.mainsNotch.harmonicCount; ++index) {
        if (!isfinite(snapshot.mainsNotch.depthsDB[index])
            || snapshot.mainsNotch.depthsDB[index] < -40.0f || snapshot.mainsNotch.depthsDB[index] > 0.0f
            || !mains_notch_coefficients_are_finite(snapshot.mainsNotch.filters[index])) return false;
    }
    if (!isfinite(snapshot.loudnessMatch.targetLUFS)'''
valid_repl = '''    for (uint32_t index = 0; index < snapshot.mainsNotch.harmonicCount; ++index) {
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
    if (!isfinite(snapshot.loudnessMatch.targetLUFS)'''
text = replace_once(text, valid_anchor, valid_repl, 'detector validity')

# reset detector oscillators
reset_anchor = '''    runtime->pauseGateGain = 1.0f;
    runtime->gateOpen = true;
}
'''
reset_repl = '''    runtime->pauseGateGain = 1.0f;
    runtime->gateOpen = true;
    reset_mains_detector_window(runtime);
}
'''
text = replace_once(text, reset_anchor, reset_repl, 'detector reset')

# replace mains processing block
mains_process = '''    dryLeft = *left;
    dryRight = *right;
    float notchLeft = process_mains_notch_cascade(
        snapshot.mainsNotch.filters,
        runtime->mainsNotchLeft,
        snapshot.mainsNotch.harmonicCount,
        dryLeft
    );
    float notchRight = process_mains_notch_cascade(
        snapshot.mainsNotch.filters,
        runtime->mainsNotchRight,
        snapshot.mainsNotch.harmonicCount,
        dryRight
    );
    float mainsTarget = snapshot.mainsNotch.enabled ? 1.0f : 0.0f;
    runtime->mainsNotchMix = smooth_toward(runtime->mainsNotchMix, mainsTarget, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (notchLeft - dryLeft) * runtime->mainsNotchMix;
    *right = dryRight + (notchRight - dryRight) * runtime->mainsNotchMix;
'''
mains_process_repl = r'''    dryLeft = *left;
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
'''
text = replace_once(text, mains_process, mains_process_repl, 'detector + retune processing')

# telemetry function anchor near end
telemetry_anchor = '''N60DynamicsTelemetry N60DynamicsRuntimeTelemetry(const N60DynamicsRuntime *runtime) {
    N60DynamicsTelemetry telemetry = {0};
    if (runtime == NULL) return telemetry;
'''
telemetry_repl = telemetry_anchor + '''    telemetry.mainsDetectedFrequencyHz = runtime->mainsDetectedFrequencyHz;
    telemetry.mainsDetectionConfidence = runtime->mainsDetectionConfidence;
'''
text = replace_once(text, telemetry_anchor, telemetry_repl, 'detector telemetry output')
c.write_text(text)

# ---- DynamicsConfiguration.swift ----------------------------------------------
sw = Path('NotchSixty/Audio/DynamicsConfiguration.swift')
text = sw.read_text()
text = replace_once(text,
    '    case invalidMainsNotch\n    case invalidLoudnessMatch\n',
    '    case invalidMainsNotch\n    case invalidMainsHumDetector\n    case invalidLoudnessMatch\n',
    'detector error enum')
text = replace_once(text,
    '        case .invalidMainsNotch:\n            return "Mains Hum Notch parameters are outside the supported production range."\n        case .invalidLoudnessMatch:\n',
    '        case .invalidMainsNotch:\n            return "Mains Hum Notch parameters are outside the supported production range."\n        case .invalidMainsHumDetector:\n            return "Mains Hum detector parameters are outside the supported production range."\n        case .invalidLoudnessMatch:\n',
    'detector error text')

old_mains = '''struct MainsNotchConfiguration: Equatable, Sendable {
    static let harmonicCountRange = 1...16
    static let qRange = 5.0...60.0
    static let depthRange = -40.0...0.0
    static let maximumHarmonics = 16

    var enabled = false
    var region: MainsRegion = .hz60
    var harmonicCount = 8
    var q = 30.0
    var harmonicDepthsDB: [Double] = [
        -24, -18, -15, -12, -10, -8, -6, -6,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]

    var fundamentalHz: Double { region.fundamentalHz }

    func validate() throws {
        guard Self.harmonicCountRange.contains(harmonicCount),
              q.isFinite, Self.qRange.contains(q),
              harmonicDepthsDB.count == Self.maximumHarmonics,
              harmonicDepthsDB.allSatisfy({ $0.isFinite && Self.depthRange.contains($0) }) else {
            throw DynamicsConfigurationError.invalidMainsNotch
        }
    }
}
'''
new_mains = '''struct MainsNotchConfiguration: Equatable, Sendable {
    static let harmonicCountRange = 1...16
    static let qRange = 5.0...60.0
    static let depthRange = -40.0...0.0
    static let detectedFrequencyRange = 40.0...70.0
    static let maximumHarmonics = 16

    var enabled = false
    var region: MainsRegion = .hz60
    var detectedFundamentalHz: Double? = nil
    var continuousTracking = false
    var harmonicCount = 8
    var q = 30.0
    var harmonicDepthsDB: [Double] = [
        -24, -18, -15, -12, -10, -8, -6, -6,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]

    var fundamentalHz: Double { detectedFundamentalHz ?? region.fundamentalHz }

    mutating func selectRegion(_ newRegion: MainsRegion) {
        region = newRegion
        detectedFundamentalHz = nil
    }

    func validate() throws {
        guard Self.harmonicCountRange.contains(harmonicCount),
              q.isFinite, Self.qRange.contains(q),
              detectedFundamentalHz.map({ $0.isFinite && Self.detectedFrequencyRange.contains($0) }) ?? true,
              harmonicDepthsDB.count == Self.maximumHarmonics,
              harmonicDepthsDB.allSatisfy({ $0.isFinite && Self.depthRange.contains($0) }) else {
            throw DynamicsConfigurationError.invalidMainsNotch
        }
    }
}
'''
text = replace_once(text, old_mains, new_mains, 'Swift tracked mains config')

snapshot_anchor = '''        guard mainsConfigured else { throw DynamicsConfigurationError.invalidMainsNotch }
        guard N60DynamicsSnapshotSetLoudnessMatch(
'''
snapshot_repl = '''        guard mainsConfigured else { throw DynamicsConfigurationError.invalidMainsNotch }
        guard N60DynamicsSnapshotSetMainsHumDetector(
            &snapshot,
            sampleRate,
            true,
            mainsNotch.region.fundamentalHz
        ) else { throw DynamicsConfigurationError.invalidMainsHumDetector }
        guard N60DynamicsSnapshotSetLoudnessMatch(
'''
text = replace_once(text, snapshot_anchor, snapshot_repl, 'Swift detector snapshot')
sw.write_text(text)

# ---- AudioIOEngine.swift -------------------------------------------------------
engine = Path('NotchSixty/Audio/AudioIOEngine.swift')
text = engine.read_text()
anchor = '''    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {
'''
methods = r'''    @discardableResult
    func applyDetectedMainsHum(minimumConfidence: Float = 0.55) throws -> Bool {
        guard let diagnostics = diagnosticsSnapshot().renderKernelDiagnostics,
              diagnostics.mainsDetectedFrequencyHz.isFinite,
              diagnostics.mainsDetectionConfidence >= minimumConfidence,
              MainsNotchConfiguration.detectedFrequencyRange.contains(Double(diagnostics.mainsDetectedFrequencyHz)) else {
            return false
        }
        var updated = dynamicsConfiguration
        updated.mainsNotch.detectedFundamentalHz = Double(diagnostics.mainsDetectedFrequencyHz)
        try replaceDynamicsConfiguration(updated)
        return true
    }

    func pollMainsHumTracking(minimumConfidence: Float = 0.70) {
        guard dynamicsConfiguration.mainsNotch.continuousTracking,
              let diagnostics = diagnosticsSnapshot().renderKernelDiagnostics,
              diagnostics.mainsDetectionConfidence >= minimumConfidence else { return }
        let detected = Double(diagnostics.mainsDetectedFrequencyHz)
        guard detected.isFinite,
              MainsNotchConfiguration.detectedFrequencyRange.contains(detected),
              abs(detected - dynamicsConfiguration.mainsNotch.fundamentalHz) >= 0.03 else { return }
        var updated = dynamicsConfiguration
        updated.mainsNotch.detectedFundamentalHz = detected
        try? replaceDynamicsConfiguration(updated)
    }

'''
text = replace_once(text, anchor, methods + anchor, 'engine detector methods')
engine.write_text(text)

# ---- Render diagnostics --------------------------------------------------------
rh = Path('NotchSixty/Audio/Realtime/N60RenderKernel.h')
text = rh.read_text()
text = replace_once(text,
    '    bool deEsserEnabled;\n',
    '    float mainsDetectedFrequencyHz;\n    float mainsDetectionConfidence;\n    bool deEsserEnabled;\n',
    'render diagnostic fields')
rh.write_text(text)

rc = Path('NotchSixty/Audio/Realtime/N60RenderKernel.c')
text = rc.read_text()
text = replace_once(text,
    '    _Atomic uint32_t deEsserGainReductionBits;\n',
    '    _Atomic uint32_t mainsDetectedFrequencyBits;\n    _Atomic uint32_t mainsDetectionConfidenceBits;\n    _Atomic uint32_t deEsserGainReductionBits;\n',
    'render atomics')
text = replace_once(text,
    '        atomic_store_explicit(&kernel->deEsserGainReductionBits, float_to_bits(telemetry.deEsserGainReductionDB), memory_order_relaxed);\n',
    '        atomic_store_explicit(&kernel->mainsDetectedFrequencyBits, float_to_bits(telemetry.mainsDetectedFrequencyHz), memory_order_relaxed);\n        atomic_store_explicit(&kernel->mainsDetectionConfidenceBits, float_to_bits(telemetry.mainsDetectionConfidence), memory_order_relaxed);\n        atomic_store_explicit(&kernel->deEsserGainReductionBits, float_to_bits(telemetry.deEsserGainReductionDB), memory_order_relaxed);\n',
    'publish detector atomics')
text = replace_once(text,
    '        diagnostics.deEsserEnabled = context.snapshot.dynamics.deEsser.enabled;\n',
    '        diagnostics.mainsDetectedFrequencyHz = bits_to_float(atomic_load_explicit(&kernel->mainsDetectedFrequencyBits, memory_order_relaxed));\n        diagnostics.mainsDetectionConfidence = bits_to_float(atomic_load_explicit(&kernel->mainsDetectionConfidenceBits, memory_order_relaxed));\n        diagnostics.deEsserEnabled = context.snapshot.dynamics.deEsser.enabled;\n',
    'snapshot detector diagnostics')
# Also load after render context for consistency
text = replace_once(text,
    '    diagnostics.deEsserGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->deEsserGainReductionBits, memory_order_relaxed));\n',
    '    diagnostics.mainsDetectedFrequencyHz = bits_to_float(atomic_load_explicit(&kernel->mainsDetectedFrequencyBits, memory_order_relaxed));\n    diagnostics.mainsDetectionConfidence = bits_to_float(atomic_load_explicit(&kernel->mainsDetectionConfidenceBits, memory_order_relaxed));\n    diagnostics.deEsserGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->deEsserGainReductionBits, memory_order_relaxed));\n',
    'load detector diagnostics')
rc.write_text(text)

# ---- PR31 UI ------------------------------------------------------------------
app = Path('NotchSixty/NotchSixtyApp.swift')
text = app.read_text()
text = replace_once(text,
    'private struct PR31NoiseHumValidationView: View {\n    @ObservedObject var engine: AudioIOEngine\n',
    'private struct PR31NoiseHumValidationView: View {\n    @ObservedObject var engine: AudioIOEngine\n    @State private var mainsDiagnostics: N60RenderKernelDiagnostics?\n    private let trackingTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()\n',
    'PR31 state')

region_binding_anchor = '''    private var harmonicCountBinding: Binding<Double> {
'''
region_binding = r'''    private var regionBinding: Binding<MainsRegion> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.region },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.selectRegion(value)
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var trackingBinding: Binding<Bool> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.continuousTracking },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.continuousTracking = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

'''
text = replace_once(text, region_binding_anchor, region_binding + region_binding_anchor, 'PR31 region/tracking bindings')
text = replace_once(text,
    '        let region = mainsBinding(\\.region)\n',
    '        let region = regionBinding\n',
    'PR31 region binding use')
text = replace_once(text,
    '                Text("First PR31 slice: independently authored static mains-hum harmonic suppression. Detection/tracking and spectral denoising follow in the same PR.")\n',
    '                Text("PR31 Slice 2 adds independent mains-frequency detection, confidence telemetry, one-shot Detect, and bounded Continuous Tracking with click-safe notch retuning. Spectral denoising follows below in Slice 3.")\n',
    'PR31 subtitle')

old_detection = '''                GroupBox("Detection / Tracking") {
                    Text("One-shot Detect and Continuous Tracking are the next PR31 slice. The static 50/60 Hz processor is intentionally validated first so detector behavior cannot hide filter-path errors.")
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
'''
new_detection = r'''                GroupBox("Detection / Tracking") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Button("Detect") {
                                _ = try? engine.applyDetectedMainsHum()
                                mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                            }
                            Toggle("Continuous Tracking", isOn: trackingBinding).toggleStyle(.switch)
                        }
                        let detected = mainsDiagnostics?.mainsDetectedFrequencyHz ?? 0
                        let confidence = mainsDiagnostics?.mainsDetectionConfidence ?? 0
                        Text("Detected: \(detected, specifier: "%.2f") Hz   Confidence: \(confidence * 100, specifier: "%.0f")%")
                            .monospacedDigit()
                        Text("Active notch fundamental: \(engine.dynamicsConfiguration.mainsNotch.fundamentalHz, specifier: "%.2f") Hz")
                            .monospacedDigit()
                        Text("Detector searches ±3 Hz around the selected 50/60 Hz region. One-shot Detect applies the latest confident estimate; Continuous Tracking only republishes bounded, confident changes and the realtime notch crossfades old/new coefficients.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
'''
text = replace_once(text, old_detection, new_detection, 'PR31 detector UI')
text = replace_once(text,
    '        .frame(minWidth: 880, minHeight: 700)\n    }\n}\n\n@main\nstruct NotchSixtyApp: App {',
    '''        .frame(minWidth: 880, minHeight: 700)
        .onAppear { mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics }
        .onReceive(trackingTimer) { _ in
            mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
            engine.pollMainsHumTracking()
        }
    }
}

@main
struct NotchSixtyApp: App {''',
    'PR31 timer wiring')
app.write_text(text)

# ---- Tests --------------------------------------------------------------------
tests = Path('NotchSixtyTests/NotchSixtyTests.swift')
text = tests.read_text()
append = r'''

extension NotchSixtyTests {
    func testMainsHumDetectorFindsOffsetFundamental() throws {
        guard let kernel = N60RenderKernelCreate() else { return XCTFail("Unable to create render kernel") }
        defer { N60RenderKernelDestroy(kernel) }
        let sampleRate = 48_000.0
        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.enabled = false
        dynamics.mainsNotch.region = .hz60
        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        let frequency = 60.75
        for frame in 0..<Int(sampleRate * 2.2) {
            let sample = Float(0.08 * sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
        }
        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertEqual(Double(diagnostics.mainsDetectedFrequencyHz), frequency, accuracy: 0.35)
        XCTAssertGreaterThan(diagnostics.mainsDetectionConfidence, 0.70)
    }

    func testMainsHumDetectorRejectsOutOfBandTone() throws {
        guard let kernel = N60RenderKernelCreate() else { return XCTFail("Unable to create render kernel") }
        defer { N60RenderKernelDestroy(kernel) }
        let sampleRate = 48_000.0
        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.region = .hz60
        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        for frame in 0..<Int(sampleRate * 1.2) {
            let sample = Float(0.1 * sin(2.0 * Double.pi * 1_000.0 * Double(frame) / sampleRate))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
        }
        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertLessThan(diagnostics.mainsDetectionConfidence, 0.25)
    }

    func testMainsNotchRetuneTransitionRemainsFiniteAndBounded() throws {
        guard let kernel = N60RenderKernelCreate() else { return XCTFail("Unable to create render kernel") }
        defer { N60RenderKernelDestroy(kernel) }
        let sampleRate = 48_000.0
        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.enabled = true
        dynamics.mainsNotch.harmonicCount = 1
        dynamics.mainsNotch.harmonicDepthsDB = Array(repeating: 0, count: MainsNotchConfiguration.maximumHarmonics)
        dynamics.mainsNotch.harmonicDepthsDB[0] = -24
        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        var previous: Float = 0
        var maximumJump: Float = 0
        for frame in 0..<12_000 {
            if frame == 6_000 {
                dynamics.mainsNotch.detectedFundamentalHz = 60.8
                graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
                XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
            }
            let sample = Float(0.1 * sin(2.0 * Double.pi * 60.4 * Double(frame) / sampleRate))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            XCTAssertTrue(left.isFinite)
            maximumJump = max(maximumJump, abs(left - previous))
            previous = left
        }
        XCTAssertLessThan(maximumJump, 0.03)
    }
}
'''
if 'testMainsHumDetectorFindsOffsetFundamental' not in text:
    text += append
tests.write_text(text)

# ---- Docs/provenance -----------------------------------------------------------
doc = Path('docs/PR31_NOISE_HUM_SUPPRESSION.md')
text = doc.read_text()
text += r'''

## Slice 2 implementation — mains detection and tracking

The commercial detector is an independently authored fixed-bank quadrature estimator. The realtime path decimates to approximately 1 kHz, evaluates 25 frequencies at 0.25 Hz spacing across a ±3 Hz window around the selected 50/60 Hz region, and publishes the strongest-bin estimate plus a bounded spectral-prominence confidence value once per approximately one-second window. It does not copy or adapt the legacy detector implementation.

One-shot **Detect** is a control-plane operation: it applies the latest estimate only above a confidence threshold. **Continuous Tracking** polls the same telemetry at a bounded cadence, requires a stronger confidence threshold, rejects negligible changes, and republishes coefficients on the control plane. The realtime notch owns dual old/new filter banks and crossfades coefficient retunes over roughly 10 ms so tracking never redesigns filters inside the render callback and does not hard-switch IIR coefficients/state.
'''
doc.write_text(text)

prov = Path('docs/PROVENANCE.md')
text = prov.read_text()
text += r'''

### PR31 Slice 2 — mains detector/tracker

The mains detector/tracker is independently authored. It uses a conventional quadrature/correlation frequency-bank design derived from general Fourier analysis principles, with fixed precomputed oscillator increments, bounded decimation, synthetic test tones, and no reference to the excluded historical `MainsHumDetector` or `GoertzelEstimator` implementations/tests. Detector telemetry is observational; coefficient redesign remains on the Swift/control plane. Realtime notch retuning uses a proprietary dual-bank crossfade rather than coefficient construction in the render callback.
'''
prov.write_text(text)
