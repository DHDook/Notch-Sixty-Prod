from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"pattern not found in {path}: {old[:140]!r}")
    p.write_text(text.replace(old, new, 1))

h = 'NotchSixty/Audio/Realtime/N60Dynamics.h'
# Dialogue snapshot before compressor.
replace_once(h,
'''typedef enum {
    N60CompressorTopologyFeedForward = 0,
''',
'''typedef struct {
    bool enabled;
    bool voiceGateEnabled;
    double bandLowHz;
    double bandHighHz;
    float targetGapDB;
    float boostRatio;
    float maxBoostDB;
    float programGateThresholdDB;
    float detectorCoefficient;
    float attackCoefficient;
    float releaseCoefficient;
    float voiceEnvelopeCoefficient;
    float voiceMeasurementCoefficient;
    float modulationHighPassPole;
    float modulationLowPassPole;
    float confidenceFloorIndex;
    float confidenceCeilingIndex;
    float minConfidence;
    N60BiquadCoefficients bandHighPass;
    N60BiquadCoefficients bandLowPass;
} N60DialogueLevelerSnapshot;

typedef enum {
    N60CompressorTopologyFeedForward = 0,
''')
replace_once(h,
'''    N60LoudnessContourSnapshot loudnessContour;
    N60DeEsserSnapshot deEsser;
''',
'''    N60LoudnessContourSnapshot loudnessContour;
    N60DialogueLevelerSnapshot dialogueLeveler;
    N60DeEsserSnapshot deEsser;
''')
replace_once(h,
'''    N60BiquadState loudnessHighShelfRight;
    float loudnessMix;
    float deEsserGainDB;
''',
'''    N60BiquadState loudnessHighShelfRight;
    float loudnessMix;
    N60BiquadState dialogueHighPassLeft;
    N60BiquadState dialogueHighPassRight;
    N60BiquadState dialogueLowPassLeft;
    N60BiquadState dialogueLowPassRight;
    float dialogueProgramMeanSquare;
    float dialogueBandMeanSquare;
    float dialogueVoiceEnvelope;
    float dialogueModulationPreviousInput;
    float dialogueModulationHighPassOutput;
    float dialogueModulationLowPassOutput;
    float dialogueModulationMeanSquare;
    float dialogueBoostDB;
    float dialogueProgramLevelDBFS;
    float dialogueBandLevelDBFS;
    float dialogueGapDB;
    float dialogueVoiceConfidence;
    float deEsserGainDB;
''')
replace_once(h,
'''    float loudnessContourScale;
    float compressorGainReductionDB;
''',
'''    float loudnessContourScale;
    float dialogueProgramLevelDBFS;
    float dialogueBandLevelDBFS;
    float dialogueGapDB;
    float dialogueVoiceConfidence;
    float dialogueBoostDB;
    float compressorGainReductionDB;
''')
# Setter declaration before de-esser.
replace_once(h,
'''bool N60DynamicsSnapshotSetDeEsser(
''',
'''bool N60DynamicsSnapshotSetDialogueLeveler(
    N60DynamicsSnapshot * _Nonnull snapshot,
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
);

bool N60DynamicsSnapshotSetDeEsser(
''')

c = 'NotchSixty/Audio/Realtime/N60Dynamics.c'
# Defaults immediately after loudness contour defaults.
replace_once(c,
'''    snapshot.loudnessContour.lowShelf = N60BiquadCoefficientsMakeIdentity();
    snapshot.loudnessContour.highShelf = N60BiquadCoefficientsMakeIdentity();

    snapshot.deEsser.enabled = false;
''',
'''    snapshot.loudnessContour.lowShelf = N60BiquadCoefficientsMakeIdentity();
    snapshot.loudnessContour.highShelf = N60BiquadCoefficientsMakeIdentity();

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

    snapshot.deEsser.enabled = false;
''')

# Add setter before de-esser setter.
marker = 'bool N60DynamicsSnapshotSetDeEsser(\n'
text = Path(c).read_text()
idx = text.find(marker)
if idx < 0: raise SystemExit('de-esser setter marker not found')
setter = r'''bool N60DynamicsSnapshotSetDialogueLeveler(
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

'''
Path(c).write_text(text[:idx] + setter + text[idx:])

# Snapshot validation before de-esser validation.
replace_once(c,
'''    if (!isfinite(snapshot.deEsser.frequencyHz)
''',
'''    if (!isfinite(snapshot.dialogueLeveler.bandLowHz) || !isfinite(snapshot.dialogueLeveler.bandHighHz)
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

    if (!isfinite(snapshot.deEsser.frequencyHz)
''')

# Processing function before de-esser.
text = Path(c).read_text()
idx = text.find('static void process_de_esser(\n')
if idx < 0: raise SystemExit('process_de_esser marker not found')
process = r'''static void process_dialogue_leveler(
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

'''
Path(c).write_text(text[:idx] + process + text[idx:])

replace_once(c,
'''    process_loudness_contour(runtime, snapshot, masterGainLinear, left, right);
    process_de_esser(runtime, snapshot, left, right);
''',
'''    process_loudness_contour(runtime, snapshot, masterGainLinear, left, right);
    process_dialogue_leveler(runtime, snapshot, left, right);
    process_de_esser(runtime, snapshot, left, right);
''')

# Telemetry.
replace_once(c,
'''    telemetry.loudnessContourScale = runtime->loudnessMix;
    telemetry.deEsserGainReductionDB = fmaxf(0.0f, -runtime->deEsserGainDB);
''',
'''    telemetry.loudnessContourScale = runtime->loudnessMix;
    telemetry.dialogueProgramLevelDBFS = runtime->dialogueProgramLevelDBFS;
    telemetry.dialogueBandLevelDBFS = runtime->dialogueBandLevelDBFS;
    telemetry.dialogueGapDB = runtime->dialogueGapDB;
    telemetry.dialogueVoiceConfidence = runtime->dialogueVoiceConfidence;
    telemetry.dialogueBoostDB = runtime->dialogueBoostDB;
    telemetry.deEsserGainReductionDB = fmaxf(0.0f, -runtime->deEsserGainDB);
''')

# Swift control plane.
s = 'NotchSixty/Audio/DynamicsConfiguration.swift'
replace_once(s,
'''    case invalidLoudnessContour
    case invalidDeEsser
''',
'''    case invalidLoudnessContour
    case invalidDialogueLeveler
    case invalidDeEsser
''')
replace_once(s,
'''        case .invalidLoudnessContour:
            return "Loudness Contour parameters are outside the supported production range."
        case .invalidDeEsser:
''',
'''        case .invalidLoudnessContour:
            return "Loudness Contour parameters are outside the supported production range."
        case .invalidDialogueLeveler:
            return "Dialogue Relative Leveler parameters are outside the supported production range."
        case .invalidDeEsser:
''')
# Add config before DeEsser.
replace_once(s,
'''struct DeEsserConfiguration: Equatable, Sendable {
''',
'''struct DialogueVoiceGateConfiguration: Equatable, Sendable {
    static let centerRange = 2.0...10.0
    static let bandwidthRange = 2.0...8.0
    static let envelopeWindowRange = 5.0...30.0
    static let measurementWindowRange = 300.0...1_500.0
    static let confidenceRange = 0.0...1.0

    var enabled = false
    var modulationCenterHz = 5.0
    var modulationBandwidthHz = 5.0
    var envelopeWindowMs = 15.0
    var measurementWindowMs = 700.0
    var confidenceFloorIndex = 0.15
    var confidenceCeilingIndex = 0.45
    var minConfidence = 0.2

    func validate() throws {
        guard modulationCenterHz.isFinite, Self.centerRange.contains(modulationCenterHz),
              modulationBandwidthHz.isFinite, Self.bandwidthRange.contains(modulationBandwidthHz),
              envelopeWindowMs.isFinite, Self.envelopeWindowRange.contains(envelopeWindowMs),
              measurementWindowMs.isFinite, Self.measurementWindowRange.contains(measurementWindowMs),
              confidenceFloorIndex.isFinite, Self.confidenceRange.contains(confidenceFloorIndex),
              confidenceCeilingIndex.isFinite, Self.confidenceRange.contains(confidenceCeilingIndex),
              confidenceCeilingIndex > confidenceFloorIndex,
              minConfidence.isFinite, Self.confidenceRange.contains(minConfidence) else {
            throw DynamicsConfigurationError.invalidDialogueLeveler
        }
    }
}

struct DialogueRelativeLevelerConfiguration: Equatable, Sendable {
    static let bandRange = 100.0...8_000.0
    static let targetGapRange = 3.0...20.0
    static let boostRatioRange = 1.0...6.0
    static let maxBoostRange = 0.0...15.0
    static let detectorWindowRange = 50.0...500.0
    static let attackRange = 10.0...1_000.0
    static let releaseRange = 50.0...3_000.0
    static let programGateRange = -70.0 ... -30.0

    var enabled = false
    var bandLowHz = 300.0
    var bandHighHz = 3_500.0
    var targetGapDB = 10.0
    var boostRatio = 2.0
    var maxBoostDB = 8.0
    var detectorWindowMs = 300.0
    var attackMs = 150.0
    var releaseMs = 900.0
    var programGateThresholdDB = -50.0
    var voiceGate = DialogueVoiceGateConfiguration()

    func validate(sampleRate: Double) throws {
        try voiceGate.validate()
        guard sampleRate.isFinite, sampleRate > 0,
              bandLowHz.isFinite, Self.bandRange.contains(bandLowHz),
              bandHighHz.isFinite, Self.bandRange.contains(bandHighHz),
              bandLowHz < bandHighHz, bandHighHz < sampleRate * 0.45,
              targetGapDB.isFinite, Self.targetGapRange.contains(targetGapDB),
              boostRatio.isFinite, Self.boostRatioRange.contains(boostRatio),
              maxBoostDB.isFinite, Self.maxBoostRange.contains(maxBoostDB),
              detectorWindowMs.isFinite, Self.detectorWindowRange.contains(detectorWindowMs),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              programGateThresholdDB.isFinite, Self.programGateRange.contains(programGateThresholdDB) else {
            throw DynamicsConfigurationError.invalidDialogueLeveler
        }
    }
}

struct DeEsserConfiguration: Equatable, Sendable {
''')
# Dynamics state field.
replace_once(s,
'''    var loudnessContour = LoudnessContourConfiguration()
    var deEsser = DeEsserConfiguration()
''',
'''    var loudnessContour = LoudnessContourConfiguration()
    var dialogueRelativeLeveler = DialogueRelativeLevelerConfiguration()
    var deEsser = DeEsserConfiguration()
''')
# validate and setter after contour.
replace_once(s,
'''        try loudnessContour.validate()
        try deEsser.validate()
''',
'''        try loudnessContour.validate()
        try dialogueRelativeLeveler.validate(sampleRate: sampleRate)
        try deEsser.validate()
''')
replace_once(s,
'''        guard N60DynamicsSnapshotSetLoudnessContour(&snapshot, sampleRate, loudnessContour.enabled, Float(loudnessContour.strength)) else { throw DynamicsConfigurationError.invalidLoudnessContour }
        guard N60DynamicsSnapshotSetDeEsserAdvanced(
''',
'''        guard N60DynamicsSnapshotSetLoudnessContour(&snapshot, sampleRate, loudnessContour.enabled, Float(loudnessContour.strength)) else { throw DynamicsConfigurationError.invalidLoudnessContour }
        guard N60DynamicsSnapshotSetDialogueLeveler(
            &snapshot,
            sampleRate,
            dialogueRelativeLeveler.enabled,
            dialogueRelativeLeveler.bandLowHz,
            dialogueRelativeLeveler.bandHighHz,
            Float(dialogueRelativeLeveler.targetGapDB),
            Float(dialogueRelativeLeveler.boostRatio),
            Float(dialogueRelativeLeveler.maxBoostDB),
            Float(dialogueRelativeLeveler.detectorWindowMs),
            Float(dialogueRelativeLeveler.attackMs),
            Float(dialogueRelativeLeveler.releaseMs),
            Float(dialogueRelativeLeveler.programGateThresholdDB),
            dialogueRelativeLeveler.voiceGate.enabled,
            Float(dialogueRelativeLeveler.voiceGate.modulationCenterHz),
            Float(dialogueRelativeLeveler.voiceGate.modulationBandwidthHz),
            Float(dialogueRelativeLeveler.voiceGate.envelopeWindowMs),
            Float(dialogueRelativeLeveler.voiceGate.measurementWindowMs),
            Float(dialogueRelativeLeveler.voiceGate.confidenceFloorIndex),
            Float(dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex),
            Float(dialogueRelativeLeveler.voiceGate.minConfidence)
        ) else { throw DynamicsConfigurationError.invalidDialogueLeveler }
        guard N60DynamicsSnapshotSetDeEsserAdvanced(
''')

# Tests.
t = Path('NotchSixtyTests/DynamicsTests.swift')
text = t.read_text()
insert = r'''

    func testPR32DialogueLevelerDisabledIsTransparent() throws {
        let rate = 96_000.0
        let snapshot = try DynamicsConfiguration().makeSnapshot(sampleRate: rate)
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        for frame in 0..<20_000 {
            let sourceL = Float(0.22 * sin(2 * Double.pi * 997 * Double(frame) / rate))
            let sourceR = Float(0.13 * sin(2 * Double.pi * 1511 * Double(frame) / rate))
            var left = sourceL
            var right = sourceR
            N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
            XCTAssertEqual(left, sourceL, accuracy: 2e-5)
            XCTAssertEqual(right, sourceR, accuracy: 2e-5)
        }
    }

    func testPR32DialogueLevelerProgramGatePreventsBoost() {
        let rate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetDialogueLeveler(
            &snapshot, rate, true, 300, 3500, 3, 6, 12, 50, 10, 100, -30,
            false, 5, 5, 15, 700, 0.15, 0.45, 0.2
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        for frame in 0..<96_000 {
            var left = Float(0.002 * sin(2 * Double.pi * 1000 * Double(frame) / rate))
            var right = left
            N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
        }
        XCTAssertLessThan(abs(N60DynamicsRuntimeTelemetry(&runtime).dialogueBoostDB), 0.05)
    }

    func testPR32DialogueLevelerRespondsToRelativeMaskingAndIsBounded() {
        let rate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetDialogueLeveler(
            &snapshot, rate, true, 300, 3500, 3, 6, 6, 50, 10, 100, -70,
            false, 5, 5, 15, 700, 0.15, 0.45, 0.2
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        for frame in 0..<96_000 {
            // Strong out-of-band program plus quieter dialogue-band content.
            let t = Double(frame) / rate
            let x = 0.45 * sin(2 * Double.pi * 9000 * t) + 0.035 * sin(2 * Double.pi * 1000 * t)
            var left = Float(x)
            var right = Float(x * 0.5)
            N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
        }
        let telemetry = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertGreaterThan(telemetry.dialogueGapDB, 3)
        XCTAssertGreaterThan(telemetry.dialogueBoostDB, 0.1)
        XCTAssertLessThanOrEqual(telemetry.dialogueBoostDB, 6.05)
    }

    func testPR32DialogueLevelerVoiceGateConfidenceHasFloor() {
        let rate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetDialogueLeveler(
            &snapshot, rate, true, 300, 3500, 3, 4, 8, 50, 10, 100, -70,
            true, 5, 5, 15, 300, 0.15, 0.45, 0.25
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        for frame in 0..<96_000 {
            let t = Double(frame) / rate
            let x = 0.45 * sin(2 * Double.pi * 9000 * t) + 0.03 * sin(2 * Double.pi * 1000 * t)
            var left = Float(x)
            var right = left
            N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
        }
        let telemetry = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertGreaterThanOrEqual(telemetry.dialogueVoiceConfidence, 0.249)
        XCTAssertLessThanOrEqual(telemetry.dialogueVoiceConfidence, 1.001)
        XCTAssertTrue(telemetry.dialogueBoostDB.isFinite)
    }

    func testPR32DialogueLevelerFiniteThrough384k() throws {
        for rate in [48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            var config = DynamicsConfiguration()
            config.dialogueRelativeLeveler.enabled = true
            config.dialogueRelativeLeveler.voiceGate.enabled = true
            let snapshot = try config.makeSnapshot(sampleRate: rate)
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)
            for frame in 0..<Int(min(rate * 0.2, 30_000)) {
                let t = Double(frame) / rate
                var left = Float(0.1 * sin(2 * Double.pi * 1000 * t))
                var right = left * 0.7
                N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
                XCTAssertTrue(left.isFinite && right.isFinite)
            }
        }
    }
'''
pos = text.rfind('\n}')
if pos < 0: raise SystemExit('test class end not found')
t.write_text(text[:pos] + insert + text[pos:])

print('PR32 Slice 2 patch applied')