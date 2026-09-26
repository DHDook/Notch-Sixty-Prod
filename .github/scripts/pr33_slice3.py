from pathlib import Path

ROOT = Path('.')
def read(path): return (ROOT / path).read_text()
def write(path, text): (ROOT / path).write_text(text)
def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f'anchor not found: {label}')
    return text.replace(old, new, 1)

# ---------- N60Dynamics.h ----------
p = 'NotchSixty/Audio/Realtime/N60Dynamics.h'
s = read(p)
s = replace_once(s, '''typedef struct {\n    bool enabled;\n    float strength;\n    float fullContourMasterGainLinear;\n    float flatContourMasterGainLinear;\n    N60BiquadCoefficients lowShelf;\n    N60BiquadCoefficients highShelf;\n} N60LoudnessContourSnapshot;\n''', '''typedef enum {\n    N60LoudnessLevelSourceSystemVolume = 0,\n    N60LoudnessLevelSourceIntegrated = 1,\n} N60LoudnessLevelSource;\n\ntypedef struct {\n    bool enabled;\n    float strength;\n    // Legacy PR29 contour state retained so the original setter stays source-\n    // and behavior-compatible. Swift now publishes per-band mode below.\n    bool perBandMode;\n    float fullContourMasterGainLinear;\n    float flatContourMasterGainLinear;\n    N60BiquadCoefficients lowShelf;\n    N60BiquadCoefficients highShelf;\n\n    N60LoudnessLevelSource levelSource;\n    float referencePhons;\n    float maxBoostDB;\n    float maxCutDB;\n    float responseCoefficient;\n    N60BiquadCoefficients lowBandLowPass;\n    N60BiquadCoefficients highBandHighPass;\n} N60LoudnessContourSnapshot;\n\ntypedef struct {\n    bool enabled;\n    double frequencyHz;\n    float amountDB;\n    N60BiquadCoefficients highShelf;\n} N60DeHarshSnapshot;\n''', 'loudness/deharsh snapshot types')
s = replace_once(s, '''    N60DialogueLevelerSnapshot dialogueLeveler;\n    N60DynamicEQSnapshot dynamicEQ;\n    N60DeEsserSnapshot deEsser;\n''', '''    N60DialogueLevelerSnapshot dialogueLeveler;\n    N60DynamicEQSnapshot dynamicEQ;\n    N60DeHarshSnapshot deHarsh;\n    N60DeEsserSnapshot deEsser;\n''', 'deharsh snapshot placement')
s = replace_once(s, '''    N60BiquadState loudnessHighShelfLeft;\n    N60BiquadState loudnessHighShelfRight;\n    float loudnessMix;\n''', '''    N60BiquadState loudnessHighShelfLeft;\n    N60BiquadState loudnessHighShelfRight;\n    float loudnessMix;\n    N60BiquadState loudnessLowBandLeft;\n    N60BiquadState loudnessLowBandRight;\n    N60BiquadState loudnessHighBandLeft;\n    N60BiquadState loudnessHighBandRight;\n    float loudnessLowGainDB;\n    float loudnessHighGainDB;\n    float loudnessEstimatedPhons;\n''', 'perband runtime')
s = replace_once(s, '''    N60DynamicEQRuntime dynamicEQ;\n    float deEsserGainDB;\n''', '''    N60DynamicEQRuntime dynamicEQ;\n    N60BiquadState deHarshLeft;\n    N60BiquadState deHarshRight;\n    float deHarshMix;\n    float deEsserGainDB;\n''', 'deharsh runtime')
s = replace_once(s, '''    float loudnessMatchGainDB;\n    float loudnessContourScale;\n''', '''    float loudnessMatchGainDB;\n    float loudnessContourScale;\n    float loudnessLowCompensationDB;\n    float loudnessHighCompensationDB;\n    float loudnessEstimatedPhons;\n    float deHarshMix;\n''', 'loudness/deharsh telemetry')
s = replace_once(s, '''bool N60DynamicsSnapshotSetLoudnessContour(\n    N60DynamicsSnapshot * _Nonnull snapshot,\n    double sampleRate,\n    bool enabled,\n    float strength\n);\n''', '''bool N60DynamicsSnapshotSetLoudnessContour(\n    N60DynamicsSnapshot * _Nonnull snapshot,\n    double sampleRate,\n    bool enabled,\n    float strength\n);\n\nbool N60DynamicsSnapshotSetPerBandLoudness(\n    N60DynamicsSnapshot * _Nonnull snapshot,\n    double sampleRate,\n    bool enabled,\n    float strength,\n    float referencePhons,\n    float maxBoostDB,\n    float maxCutDB,\n    N60LoudnessLevelSource levelSource\n);\n''', 'perband setter prototype')
s = replace_once(s, '''bool N60DynamicsSnapshotSetDynamicEQBand(\n    N60DynamicsSnapshot * _Nonnull snapshot,\n''', '''bool N60DynamicsSnapshotSetDeHarsh(\n    N60DynamicsSnapshot * _Nonnull snapshot,\n    double sampleRate,\n    bool enabled,\n    float amountDB,\n    double frequencyHz\n);\n\nbool N60DynamicsSnapshotSetDynamicEQBand(\n    N60DynamicsSnapshot * _Nonnull snapshot,\n''', 'deharsh prototype')
write(p, s)

# ---------- N60Dynamics.c ----------
p = 'NotchSixty/Audio/Realtime/N60Dynamics.c'
s = read(p)
s = replace_once(s, '#define N60_LOUDNESS_FLAT_CONTOUR_DB -6.0f\n', '''#define N60_LOUDNESS_FLAT_CONTOUR_DB -6.0f\n#define N60_LOUDNESS_INTEGRATED_REFERENCE_LUFS -16.0f\n#define N60_LOUDNESS_LOW_DB_PER_PHON 0.25f\n#define N60_LOUDNESS_HIGH_DB_PER_PHON 0.125f\n#define N60_LOUDNESS_LOW_CUT_DB_PER_PHON 0.15f\n#define N60_LOUDNESS_HIGH_CUT_DB_PER_PHON 0.075f\n#define N60_LOUDNESS_GAIN_RESPONSE_MS 50.0f\n''', 'loudness constants')
s = replace_once(s, '''    snapshot.loudnessContour.enabled = false;\n    snapshot.loudnessContour.strength = 1.0f;\n    snapshot.loudnessContour.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);\n    snapshot.loudnessContour.flatContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FLAT_CONTOUR_DB);\n    snapshot.loudnessContour.lowShelf = N60BiquadCoefficientsMakeIdentity();\n    snapshot.loudnessContour.highShelf = N60BiquadCoefficientsMakeIdentity();\n''', '''    snapshot.loudnessContour.enabled = false;\n    snapshot.loudnessContour.strength = 1.0f;\n    snapshot.loudnessContour.perBandMode = false;\n    snapshot.loudnessContour.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);\n    snapshot.loudnessContour.flatContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FLAT_CONTOUR_DB);\n    snapshot.loudnessContour.lowShelf = N60BiquadCoefficientsMakeIdentity();\n    snapshot.loudnessContour.highShelf = N60BiquadCoefficientsMakeIdentity();\n    snapshot.loudnessContour.levelSource = N60LoudnessLevelSourceSystemVolume;\n    snapshot.loudnessContour.referencePhons = 85.0f;\n    snapshot.loudnessContour.maxBoostDB = 12.0f;\n    snapshot.loudnessContour.maxCutDB = 6.0f;\n    snapshot.loudnessContour.responseCoefficient = coefficient_for_time_ms(sampleRate, N60_LOUDNESS_GAIN_RESPONSE_MS);\n    snapshot.loudnessContour.lowBandLowPass = N60BiquadCoefficientsMakeIdentity();\n    snapshot.loudnessContour.highBandHighPass = N60BiquadCoefficientsMakeIdentity();\n''', 'loudness defaults')
s = replace_once(s, '''    snapshot.dynamicEQ = N60DynamicEQSnapshotMakeBypassed(sampleRate);\n\n    snapshot.deEsser.enabled = false;\n''', '''    snapshot.dynamicEQ = N60DynamicEQSnapshotMakeBypassed(sampleRate);\n\n    snapshot.deHarsh.enabled = false;\n    snapshot.deHarsh.frequencyHz = 3500.0;\n    snapshot.deHarsh.amountDB = -1.5f;\n    snapshot.deHarsh.highShelf = N60BiquadCoefficientsMakeIdentity();\n\n    snapshot.deEsser.enabled = false;\n''', 'deharsh defaults')
# Ensure legacy setter marks old behavior.
s = replace_once(s, '''    configured.enabled = enabled;\n    configured.strength = strength;\n    configured.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);\n''', '''    configured.enabled = enabled;\n    configured.strength = strength;\n    configured.perBandMode = false;\n    configured.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);\n''', 'legacy contour mode')
s = replace_once(s, '''    snapshot->loudnessContour = configured;\n    return true;\n}\n\nbool N60DynamicsSnapshotSetDialogueLeveler(''', '''    snapshot->loudnessContour = configured;\n    return true;\n}\n\nbool N60DynamicsSnapshotSetPerBandLoudness(\n    N60DynamicsSnapshot *snapshot,\n    double sampleRate,\n    bool enabled,\n    float strength,\n    float referencePhons,\n    float maxBoostDB,\n    float maxCutDB,\n    N60LoudnessLevelSource levelSource\n) {\n    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0\n        || !isfinite(strength) || strength < 0.0f || strength > 1.0f\n        || !isfinite(referencePhons) || referencePhons < 60.0f || referencePhons > 95.0f\n        || !isfinite(maxBoostDB) || maxBoostDB < 6.0f || maxBoostDB > 20.0f\n        || !isfinite(maxCutDB) || maxCutDB < 0.0f || maxCutDB > 6.0f\n        || (levelSource != N60LoudnessLevelSourceSystemVolume && levelSource != N60LoudnessLevelSourceIntegrated)\n        || N60_LOUDNESS_HIGH_SHELF_HZ >= sampleRate * 0.45) return false;\n\n    N60LoudnessContourSnapshot configured = {0};\n    configured.enabled = enabled;\n    configured.strength = strength;\n    configured.perBandMode = true;\n    configured.fullContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FULL_CONTOUR_DB);\n    configured.flatContourMasterGainLinear = db_to_linear(N60_LOUDNESS_FLAT_CONTOUR_DB);\n    configured.lowShelf = N60BiquadCoefficientsMakeIdentity();\n    configured.highShelf = N60BiquadCoefficientsMakeIdentity();\n    configured.levelSource = levelSource;\n    configured.referencePhons = referencePhons;\n    configured.maxBoostDB = maxBoostDB;\n    configured.maxCutDB = maxCutDB;\n    configured.responseCoefficient = coefficient_for_time_ms(sampleRate, N60_LOUDNESS_GAIN_RESPONSE_MS);\n    if (!valid_coefficient(configured.responseCoefficient)\n        || !N60BiquadDesign(N60BiquadFilterTypeLowPass, sampleRate, N60_LOUDNESS_LOW_SHELF_HZ, 0.0, 0.7071067811865476, &configured.lowBandLowPass)\n        || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, N60_LOUDNESS_HIGH_SHELF_HZ, 0.0, 0.7071067811865476, &configured.highBandHighPass)) return false;\n    snapshot->loudnessContour = configured;\n    return true;\n}\n\nbool N60DynamicsSnapshotSetDialogueLeveler(''', 'advanced loudness setter')
s = replace_once(s, '''bool N60DynamicsSnapshotSetDynamicEQEnabled(\n    N60DynamicsSnapshot *snapshot,\n''', '''bool N60DynamicsSnapshotSetDeHarsh(\n    N60DynamicsSnapshot *snapshot,\n    double sampleRate,\n    bool enabled,\n    float amountDB,\n    double frequencyHz\n) {\n    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0\n        || !isfinite(amountDB) || amountDB < -6.0f || amountDB > 0.0f\n        || !isfinite(frequencyHz) || frequencyHz < 1500.0 || frequencyHz > 10000.0\n        || frequencyHz >= sampleRate * 0.45) return false;\n    N60DeHarshSnapshot configured = {0};\n    configured.enabled = enabled;\n    configured.frequencyHz = frequencyHz;\n    configured.amountDB = amountDB;\n    if (!N60BiquadDesign(N60BiquadFilterTypeHighShelf, sampleRate, frequencyHz, amountDB, 0.7071067811865476, &configured.highShelf)) return false;\n    snapshot->deHarsh = configured;\n    return true;\n}\n\nbool N60DynamicsSnapshotSetDynamicEQEnabled(\n    N60DynamicsSnapshot *snapshot,\n''', 'deharsh setter')
# validity: replace contour validity with expanded checks, then add deharsh after dynamic EQ.
s = replace_once(s, '''    if (!isfinite(snapshot.loudnessContour.strength) || snapshot.loudnessContour.strength < 0.0f || snapshot.loudnessContour.strength > 1.0f\n        || !isfinite(snapshot.loudnessContour.fullContourMasterGainLinear) || snapshot.loudnessContour.fullContourMasterGainLinear <= 0.0f\n        || !isfinite(snapshot.loudnessContour.flatContourMasterGainLinear) || snapshot.loudnessContour.flatContourMasterGainLinear <= snapshot.loudnessContour.fullContourMasterGainLinear\n        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.lowShelf)\n        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.highShelf)) return false;\n''', '''    if (!isfinite(snapshot.loudnessContour.strength) || snapshot.loudnessContour.strength < 0.0f || snapshot.loudnessContour.strength > 1.0f\n        || !isfinite(snapshot.loudnessContour.fullContourMasterGainLinear) || snapshot.loudnessContour.fullContourMasterGainLinear <= 0.0f\n        || !isfinite(snapshot.loudnessContour.flatContourMasterGainLinear) || snapshot.loudnessContour.flatContourMasterGainLinear <= snapshot.loudnessContour.fullContourMasterGainLinear\n        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.lowShelf)\n        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.highShelf)\n        || (snapshot.loudnessContour.levelSource != N60LoudnessLevelSourceSystemVolume && snapshot.loudnessContour.levelSource != N60LoudnessLevelSourceIntegrated)\n        || !isfinite(snapshot.loudnessContour.referencePhons) || snapshot.loudnessContour.referencePhons < 60.0f || snapshot.loudnessContour.referencePhons > 95.0f\n        || !isfinite(snapshot.loudnessContour.maxBoostDB) || snapshot.loudnessContour.maxBoostDB < 6.0f || snapshot.loudnessContour.maxBoostDB > 20.0f\n        || !isfinite(snapshot.loudnessContour.maxCutDB) || snapshot.loudnessContour.maxCutDB < 0.0f || snapshot.loudnessContour.maxCutDB > 6.0f\n        || !valid_coefficient(snapshot.loudnessContour.responseCoefficient)\n        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.lowBandLowPass)\n        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.highBandHighPass)) return false;\n''', 'expanded loudness validity')
s = replace_once(s, '''    if (!N60DynamicEQSnapshotIsValid(snapshot.dynamicEQ)) return false;\n\n    if (!isfinite(snapshot.deEsser.frequencyHz)\n''', '''    if (!N60DynamicEQSnapshotIsValid(snapshot.dynamicEQ)) return false;\n\n    if (!isfinite(snapshot.deHarsh.frequencyHz) || snapshot.deHarsh.frequencyHz < 1500.0 || snapshot.deHarsh.frequencyHz > 10000.0\n        || !isfinite(snapshot.deHarsh.amountDB) || snapshot.deHarsh.amountDB < -6.0f || snapshot.deHarsh.amountDB > 0.0f\n        || !N60BiquadCoefficientsAreFinite(snapshot.deHarsh.highShelf)) return false;\n\n    if (!isfinite(snapshot.deEsser.frequencyHz)\n''', 'deharsh validity')
# Replace loudness process with dual-mode version.
old_start = s.index('static void process_loudness_contour(')
old_end = s.index('static void process_dialogue_leveler(', old_start)
new_proc = r'''static void process_loudness_contour(
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

'''
s = s[:old_start] + new_proc + s[old_end:]
s = replace_once(s, '''    process_dialogue_leveler(runtime, snapshot, left, right);\n    N60DynamicEQProcessStereoFrame(&runtime->dynamicEQ, snapshot.dynamicEQ, left, right);\n    process_de_esser(runtime, snapshot, left, right);\n''', '''    process_dialogue_leveler(runtime, snapshot, left, right);\n    N60DynamicEQProcessStereoFrame(&runtime->dynamicEQ, snapshot.dynamicEQ, left, right);\n    process_de_harsh(runtime, snapshot, left, right);\n    process_de_esser(runtime, snapshot, left, right);\n''', 'deharsh process order')
s = replace_once(s, '''    telemetry.loudnessMatchGainDB = runtime->loudnessMatchGainDB;\n    telemetry.loudnessContourScale = runtime->loudnessMix;\n''', '''    telemetry.loudnessMatchGainDB = runtime->loudnessMatchGainDB;\n    telemetry.loudnessContourScale = runtime->loudnessMix;\n    telemetry.loudnessLowCompensationDB = runtime->loudnessLowGainDB;\n    telemetry.loudnessHighCompensationDB = runtime->loudnessHighGainDB;\n    telemetry.loudnessEstimatedPhons = runtime->loudnessEstimatedPhons;\n    telemetry.deHarshMix = runtime->deHarshMix;\n''', 'telemetry assignments')
write(p, s)

# ---------- DynamicsConfiguration.swift ----------
p = 'NotchSixty/Audio/DynamicsConfiguration.swift'
s = read(p)
s = replace_once(s, '''    case invalidLoudnessContour\n    case invalidDialogueLeveler\n''', '''    case invalidLoudnessContour\n    case invalidDeHarsh\n    case invalidDialogueLeveler\n''', 'swift deharsh error')
s = replace_once(s, '''        case .invalidLoudnessContour:\n            return "Loudness Contour parameters are outside the supported production range."\n        case .invalidDialogueLeveler:\n''', '''        case .invalidLoudnessContour:\n            return "Per-Band Loudness parameters are outside the supported production range."\n        case .invalidDeHarsh:\n            return "De-Harsh parameters are outside the supported production range."\n        case .invalidDialogueLeveler:\n''', 'swift deharsh description')
old_loud = '''struct LoudnessContourConfiguration: Equatable, Sendable {\n    static let strengthRange = 0.0...1.0\n    var enabled = false\n    var strength = 1.0\n\n    func validate() throws {\n        guard strength.isFinite, Self.strengthRange.contains(strength) else {\n            throw DynamicsConfigurationError.invalidLoudnessContour\n        }\n    }\n}\n'''
new_loud = r'''enum LoudnessLevelSource: String, CaseIterable, Identifiable, Sendable {
    case systemVolume
    case integrated
    var id: String { rawValue }
    var displayName: String { self == .systemVolume ? "System Volume" : "Integrated" }
    var cType: N60LoudnessLevelSource {
        self == .systemVolume ? N60LoudnessLevelSourceSystemVolume : N60LoudnessLevelSourceIntegrated
    }
}

struct LoudnessContourConfiguration: Equatable, Sendable {
    static let strengthRange = 0.0...1.0
    static let referencePhonsRange = 60.0...95.0
    static let maxBoostRange = 6.0...20.0
    static let maxCutRange = 0.0...6.0

    var enabled = false
    var strength = 1.0
    var referencePhons = 85.0
    var maxBoostDB = 12.0
    var maxCutDB = 6.0
    var levelSource: LoudnessLevelSource = .systemVolume

    func validate() throws {
        guard strength.isFinite, Self.strengthRange.contains(strength),
              referencePhons.isFinite, Self.referencePhonsRange.contains(referencePhons),
              maxBoostDB.isFinite, Self.maxBoostRange.contains(maxBoostDB),
              maxCutDB.isFinite, Self.maxCutRange.contains(maxCutDB) else {
            throw DynamicsConfigurationError.invalidLoudnessContour
        }
    }
}

struct DeHarshConfiguration: Equatable, Sendable {
    static let amountRange = -6.0...0.0
    static let frequencyRange = 1_500.0...10_000.0
    var enabled = false
    var amountDB = -1.5
    var frequencyHz = 3_500.0

    func validate(sampleRate: Double) throws {
        guard amountDB.isFinite, Self.amountRange.contains(amountDB),
              frequencyHz.isFinite, Self.frequencyRange.contains(frequencyHz),
              frequencyHz < sampleRate * 0.45 else {
            throw DynamicsConfigurationError.invalidDeHarsh
        }
    }
}
'''
s = replace_once(s, old_loud, new_loud, 'swift loudness config')
s = replace_once(s, '''    var loudnessMatch = LoudnessMatchConfiguration()\n    var loudnessContour = LoudnessContourConfiguration()\n    var dialogueRelativeLeveler = DialogueRelativeLevelerConfiguration()\n''', '''    var loudnessMatch = LoudnessMatchConfiguration()\n    var loudnessContour = LoudnessContourConfiguration()\n    var deHarsh = DeHarshConfiguration()\n    var dialogueRelativeLeveler = DialogueRelativeLevelerConfiguration()\n''', 'swift deharsh config field')
s = replace_once(s, '''        try loudnessMatch.validate()\n        try loudnessContour.validate()\n        try dialogueRelativeLeveler.validate(sampleRate: sampleRate)\n''', '''        try loudnessMatch.validate()\n        try loudnessContour.validate()\n        try deHarsh.validate(sampleRate: sampleRate)\n        try dialogueRelativeLeveler.validate(sampleRate: sampleRate)\n''', 'swift deharsh validation')
s = replace_once(s, '''        guard N60DynamicsSnapshotSetLoudnessContour(&snapshot, sampleRate, loudnessContour.enabled, Float(loudnessContour.strength)) else { throw DynamicsConfigurationError.invalidLoudnessContour }\n        guard N60DynamicsSnapshotSetDialogueLeveler(\n''', '''        guard N60DynamicsSnapshotSetPerBandLoudness(\n            &snapshot, sampleRate, loudnessContour.enabled, Float(loudnessContour.strength),\n            Float(loudnessContour.referencePhons), Float(loudnessContour.maxBoostDB),\n            Float(loudnessContour.maxCutDB), loudnessContour.levelSource.cType\n        ) else { throw DynamicsConfigurationError.invalidLoudnessContour }\n        guard N60DynamicsSnapshotSetDeHarsh(\n            &snapshot, sampleRate, deHarsh.enabled, Float(deHarsh.amountDB), deHarsh.frequencyHz\n        ) else { throw DynamicsConfigurationError.invalidDeHarsh }\n        guard N60DynamicsSnapshotSetDialogueLeveler(\n''', 'swift advanced loudness/deharsh setter')
write(p, s)

# ---------- DynamicsTests.swift ----------
p = 'NotchSixtyTests/DynamicsTests.swift'
s = read(p)
insert = s.rfind('\n}')
new_tests = r'''

    func testPerBandLoudnessIsFlatAtSystemReferencePoint() {
        let rate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetPerBandLoudness(
            &snapshot, rate, true, 1, 85, 12, 6, N60LoudnessLevelSourceSystemVolume))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        let master = Float(pow(10.0, -6.0 / 20.0))
        for frame in 0..<48_000 {
            let input = Float(0.2 * sin(2 * Double.pi * 1_000 * Double(frame) / rate))
            var left = input
            var right = -input * 0.5
            N60DynamicsProcessCoreStereoFrameWithMasterGain(&runtime, snapshot, master, &left, &right)
            if frame > 20_000 {
                XCTAssertEqual(left, input, accuracy: 0.000_01)
                XCTAssertEqual(right, -input * 0.5, accuracy: 0.000_01)
            }
        }
        let t = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertEqual(t.loudnessLowCompensationDB, 0, accuracy: 0.02)
        XCTAssertEqual(t.loudnessHighCompensationDB, 0, accuracy: 0.02)
        XCTAssertEqual(t.loudnessEstimatedPhons, 85, accuracy: 0.05)
    }

    func testPerBandLoudnessLowVolumeReachesHistoricalSixAndThreeDBAnchors() {
        let rate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetPerBandLoudness(
            &snapshot, rate, true, 1, 85, 12, 6, N60LoudnessLevelSourceSystemVolume))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        let master = Float(pow(10.0, -30.0 / 20.0))
        for frame in 0..<(48_000 / 2) {
            var left = Float(0.15 * sin(2 * Double.pi * 200 * Double(frame) / rate))
            var right = left
            N60DynamicsProcessCoreStereoFrameWithMasterGain(&runtime, snapshot, master, &left, &right)
        }
        let t = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertEqual(t.loudnessLowCompensationDB, 6.0, accuracy: 0.05)
        XCTAssertEqual(t.loudnessHighCompensationDB, 3.0, accuracy: 0.05)
        XCTAssertEqual(t.loudnessEstimatedPhons, 61.0, accuracy: 0.05)
    }

    func testPerBandLoudnessAboveReferenceUsesBoundedCut() {
        let rate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetPerBandLoudness(
            &snapshot, rate, true, 1, 85, 12, 0.5, N60LoudnessLevelSourceSystemVolume))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        for frame in 0..<(48_000 / 2) {
            var left = Float(0.1 * sin(2 * Double.pi * 1_000 * Double(frame) / rate))
            var right = left
            N60DynamicsProcessCoreStereoFrameWithMasterGain(&runtime, snapshot, 1.0, &left, &right)
        }
        let t = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertLessThan(t.loudnessLowCompensationDB, 0)
        XCTAssertGreaterThanOrEqual(t.loudnessLowCompensationDB, -0.501)
        XCTAssertLessThan(t.loudnessHighCompensationDB, 0)
        XCTAssertGreaterThanOrEqual(t.loudnessHighCompensationDB, -0.501)
    }

    func testPerBandLoudnessIntegratedSourceRespondsToProgramLevel() {
        let rate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetPerBandLoudness(
            &snapshot, rate, true, 1, 85, 12, 6, N60LoudnessLevelSourceIntegrated))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        for frame in 0..<(48_000 * 4) {
            var left = Float(0.01 * sin(2 * Double.pi * 1_000 * Double(frame) / rate))
            var right = left
            N60DynamicsProcessCoreStereoFrameWithMasterGain(&runtime, snapshot, 1.0, &left, &right)
        }
        let t = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertLessThan(t.loudnessEstimatedPhons, 85)
        XCTAssertGreaterThan(t.loudnessLowCompensationDB, 0)
        XCTAssertGreaterThan(t.loudnessHighCompensationDB, 0)
        XCTAssertLessThanOrEqual(t.loudnessLowCompensationDB, 12.01)
    }

    func testDeHarshDisabledIsTransparentAndEnabledReducesHighFrequencyMoreThanLow() {
        let rate = 48_000.0
        var disabled = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetDeHarsh(&disabled, rate, false, -6, 3_500))
        var dryRuntime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&dryRuntime)
        for frame in 0..<20_000 {
            let input = Float(0.3 * sin(2 * Double.pi * 8_000 * Double(frame) / rate))
            var left = input
            var right = -input
            N60DynamicsProcessCoreStereoFrame(&dryRuntime, disabled, &left, &right)
            XCTAssertEqual(left, input, accuracy: 0.000_001)
            XCTAssertEqual(right, -input, accuracy: 0.000_001)
        }

        func measuredGain(frequency: Double) -> Double {
            var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
            XCTAssertTrue(N60DynamicsSnapshotSetDeHarsh(&snapshot, rate, true, -6, 3_500))
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)
            var inputSq = 0.0, outputSq = 0.0
            for frame in 0..<48_000 {
                let input = Float(0.25 * sin(2 * Double.pi * frequency * Double(frame) / rate))
                var left = input
                var right = input
                N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
                if frame >= 24_000 {
                    inputSq += Double(input * input)
                    outputSq += Double(left * left)
                }
            }
            return 20 * log10(sqrt(outputSq / inputSq))
        }
        let lowDB = measuredGain(frequency: 1_000)
        let highDB = measuredGain(frequency: 8_000)
        XCTAssertGreaterThan(lowDB, -1.5)
        XCTAssertLessThan(highDB, -3.5)
        XCTAssertLessThan(highDB, lowDB - 2.5)
    }

    func testPR33PerBandLoudnessAndDeHarshValidThrough384k() throws {
        for rate in [48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            var config = DynamicsConfiguration()
            config.loudnessContour.enabled = true
            config.loudnessContour.levelSource = .integrated
            config.loudnessContour.referencePhons = 90
            config.loudnessContour.maxBoostDB = 20
            config.loudnessContour.maxCutDB = 6
            config.deHarsh.enabled = true
            config.deHarsh.amountDB = -6
            config.deHarsh.frequencyHz = 3_500
            var snapshot = try config.makeSnapshot(sampleRate: rate)
            XCTAssertTrue(N60DynamicsSnapshotIsValid(snapshot))
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)
            for frame in 0..<10_000 {
                var left = Float(0.1 * sin(2 * Double.pi * 1_000 * Double(frame) / rate))
                var right = left * 0.7
                N60DynamicsProcessCoreStereoFrameWithMasterGain(&runtime, snapshot, 0.25, &left, &right)
                XCTAssertTrue(left.isFinite && right.isFinite)
            }
        }
    }
'''
s = s[:insert] + new_tests + s[insert:]
write(p, s)

# ---------- Docs / provenance / final audit ----------
p = 'docs/PR33_RESIDUAL_DYNAMICS_PARITY.md'
s = read(p)
s += r'''

## Slice 3 commercial semantics

### Per-band loudness compensation
The commercial implementation supersedes the shallow PR29 volume-aware contour while retaining its useful anchor points and the old C setter for compatibility. The advanced Swift path exposes the legacy observable controls: reference phons (60–95), maximum boost (6–20 dB), maximum cut (0–6 dB), and System Volume / Integrated level source.

The implementation is independently authored and does not claim calibrated SPL. In System Volume mode, master −6 dB is the configured reference-phons point and master −30 dB is 24 phons below reference. With the default response slopes this reproduces PR29's accepted +6 dB bass / +3 dB treble low-volume anchor. Integrated mode maps −16 LUFS to the configured reference-phons point. Low and high bands use fixed, precomputed filters with dynamically smoothed gains, so no coefficients are designed in the callback.

### De-Harsh
De-Harsh is an independently authored RBJ-style high-shelf conditioning stage. Observable contract: enable, amount −6…0 dB (default −1.5 dB), frequency 1.5–10 kHz (default 3.5 kHz). Coefficients are designed on the control plane, runtime state is fixed/preallocated, enable transitions are smoothed, and algorithmic latency is zero.
'''
write(p, s)

p = 'docs/PROVENANCE.md'
s = read(p)
s += r'''

## PR33 Slice 3 — per-band loudness and De-Harsh

Classification: **specification-derived / independently authored commercial implementation**.

Observable legacy configuration/UI state was used only to establish controls, ranges, defaults, labels, and intended user-facing semantics for Per-Band Loudness Compensation and De-Harsh. The historical `PerBandLoudnessCompensator` implementation, historical dynamics processor implementation, and historical DSP tests were not used as coding templates.

Commercial Per-Band Loudness uses independently defined reference-point mapping, fixed precomputed low/high analysis bands, smoothed linked-stereo gain offsets, and explicit caps. De-Harsh uses public RBJ-style high-shelf biquad mathematics already used elsewhere in the clean-room commercial engine. Both remain zero-lookahead and fixed/preallocated in realtime.
'''
write(p, s)

p = 'docs/PR33_FINAL_DYNAMICS_PARITY_AUDIT.md'
audit = r'''# PR33 Final Dynamics / Conditioning Parity Audit

This audit closes the residual dynamics inventory identified after PR32. “Closed” means every known observable legacy capability is either implemented/improved in the commercial engine or explicitly assigned to a later milestone/product-scope decision; it does **not** claim that routing-, measurement-, or output-format-dependent work has been prematurely implemented.

## Implemented / improved in PR25–PR33

- Compressor: threshold/ratio/knee/attack/release/makeup, feed-forward/feed-back, program-dependent release, sidechain HPF.
- Downward Expander.
- Pause Gate with Attack=fade-out, Release=fade-in, threshold/hold/hysteresis.
- Soft Clipper, including curve selection, drive/threshold/knee, auto gain compensation, and PR33 ±3 dB asymmetry trim.
- Look-ahead Limiter and explicit PR33 True-Peak Guard semantics.
- 1x/2x/4x oversampling and true-peak detection.
- Dynamic Gain Rider / sustained-limiter auto-headroom.
- Predictive EQ/DSP automatic headroom compensation.
- De-Esser with ratio/range/Q/attack/release and Dynamic-EQ mode.
- Three-band multiband compressor with independent crossover slopes and per-band ratio/timing/knee/sidechain/makeup.
- General Dynamic EQ up to 16 bands with cut/boost/both, Peak/RMS detection, RMS window, timing and bounded range.
- LUFS Loudness Match and Dialogue Gate.
- Dialogue-Relative Leveler with optional voice-confidence gate.
- Volume-aware loudness contour, superseded by PR33 Per-Band Loudness Compensation with reference phons, boost/cut caps, and System Volume / Integrated source.
- De-Harsh high-frequency tilt/conditioning.
- Stereo / Wide Mono / True Mono and three-band M/S widener.
- DC offset filtering, infrasonic filtering, mains-hum notch/detection/tracking, and stationary spectral denoising.

## Explicit later milestones — not silent omissions

- Infrasonic sub-output-only / both routing: Active Crossover / physical-route milestone.
- Independent sub phase/timing and multi-driver alignment: routing + room-correction milestones.
- Excess/mixed-phase correction: room-correction milestone because it requires phase-resolved measurement data.
- Dither / final output-format behavior, if still applicable: output/hardening milestone once the final device/output architecture is fixed.
- Active Crossover Matrix: dedicated post-room-correction parity milestone per current roadmap.

## Explicitly out of current product scope

- Headphone-only spatial/crossfeed/crosstalk features.
- Arbitrary multichannel processing beyond the planned speaker/sub routing model.

## PR33 exit condition

After dedicated engineering validation UI, full CI, provenance review, and focused hardware/listening acceptance, the legacy dynamics/conditioning inventory has no unexplained item remaining. The project can then enter the bounded DSP optimization/enhancement pass without carrying an unknown dynamics-parity debt.
'''
write(p, audit)
print('PR33 Slice 3 patch applied')
