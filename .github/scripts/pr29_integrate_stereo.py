from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"anchor not found in {path}: {old[:100]!r}")
    path.write_text(text.replace(old, new, 1))


header = ROOT / "NotchSixty/Audio/Realtime/N60Dynamics.h"
replace_once(
    header,
    "typedef struct {\n    bool enabled;\n    float poleCoefficient;\n} N60DCOffsetFilterSnapshot;",
    """typedef enum {
    N60StereoModeStereo = 0,
    N60StereoModeWideMono = 1,
    N60StereoModeTrueMono = 2,
} N60StereoMode;

typedef struct {
    N60StereoMode mode;
} N60StereoModeSnapshot;

typedef struct {
    bool enabled;
    bool monoLowBand;
    double lowMidFrequencyHz;
    double midHighFrequencyHz;
    float lowWidth;
    float midWidth;
    float highWidth;
    uint32_t sectionCount;
    N60BiquadCoefficients lowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients highPass[N60_MAX_CROSSOVER_SECTIONS];
} N60StereoWidenerSnapshot;

typedef struct {
    bool enabled;
    float poleCoefficient;
} N60DCOffsetFilterSnapshot;""",
)
replace_once(
    header,
    "typedef struct {\n    N60DCOffsetFilterSnapshot dcOffsetFilter;",
    "typedef struct {\n    N60StereoModeSnapshot stereoMode;\n    N60StereoWidenerSnapshot stereoWidener;\n    N60DCOffsetFilterSnapshot dcOffsetFilter;",
)
replace_once(
    header,
    "typedef struct {\n    float dcPreviousInputLeft;",
    """typedef struct {
    float stereoMatrixLL;
    float stereoMatrixLR;
    float stereoMatrixRL;
    float stereoMatrixRR;
    float widenerLowWidth;
    float widenerMidWidth;
    float widenerHighWidth;
    N60BiquadState widenerLowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState widenerHighPass[N60_MAX_CROSSOVER_SECTIONS];
    float dcPreviousInputLeft;""",
)
replace_once(
    header,
    "N60DynamicsSnapshot N60DynamicsSnapshotMakeBypassed(double sampleRate);\n\nbool N60DynamicsSnapshotSetDCOffsetFilter(",
    """N60DynamicsSnapshot N60DynamicsSnapshotMakeBypassed(double sampleRate);

bool N60DynamicsSnapshotSetStereoMode(
    N60DynamicsSnapshot * _Nonnull snapshot,
    N60StereoMode mode
);

bool N60DynamicsSnapshotSetStereoWidener(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    bool monoLowBand,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    float lowWidth,
    float midWidth,
    float highWidth
);

bool N60DynamicsSnapshotSetDCOffsetFilter(""",
)

source = ROOT / "NotchSixty/Audio/Realtime/N60Dynamics.c"
replace_once(
    source,
    "N60DynamicsSnapshot snapshot = {0};\n\n    snapshot.dcOffsetFilter.enabled = false;",
    """N60DynamicsSnapshot snapshot = {0};

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

    snapshot.dcOffsetFilter.enabled = false;""",
)
replace_once(
    source,
    "\nbool N60DynamicsSnapshotSetDCOffsetFilter(\n",
    """
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
""",
)
replace_once(
    source,
    "bool N60DynamicsSnapshotIsValid(N60DynamicsSnapshot snapshot) {\n    if (!valid_coefficient(snapshot.bypassTransitionCoefficient)) return false;",
    """bool N60DynamicsSnapshotIsValid(N60DynamicsSnapshot snapshot) {
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
    }""",
)
replace_once(
    source,
    "memset(runtime, 0, sizeof(*runtime));\n    runtime->pauseGateGain = 1.0f;",
    """memset(runtime, 0, sizeof(*runtime));
    runtime->stereoMatrixLL = 1.0f;
    runtime->stereoMatrixRR = 1.0f;
    runtime->widenerLowWidth = 1.0f;
    runtime->widenerMidWidth = 1.0f;
    runtime->widenerHighWidth = 1.0f;
    runtime->pauseGateGain = 1.0f;""",
)
replace_once(
    source,
    "\nstatic void process_loudness_contour(\n",
    """
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

static void process_loudness_contour(
""",
)
replace_once(
    source,
    "if (runtime == NULL || left == NULL || right == NULL) return;\n\n    process_loudness_contour(runtime, snapshot, left, right);",
    """if (runtime == NULL || left == NULL || right == NULL) return;

    process_stereo_mode(runtime, snapshot, left, right);
    process_stereo_widener(runtime, snapshot, left, right);
    process_loudness_contour(runtime, snapshot, left, right);""",
)

swift = ROOT / "NotchSixty/Audio/DynamicsConfiguration.swift"
replace_once(
    swift,
    "case invalidDCOffsetFilter\n",
    "case invalidStereoWidener\n    case invalidDCOffsetFilter\n",
)
replace_once(
    swift,
    "switch self {\n        case .invalidDCOffsetFilter:",
    """switch self {
        case .invalidStereoWidener:
            return "Stereo Widener parameters are outside the supported production range."
        case .invalidDCOffsetFilter:""",
)
replace_once(
    swift,
    "\nstruct DCOffsetFilterConfiguration: Equatable, Sendable {",
    """
enum StereoProcessingMode: String, CaseIterable, Identifiable, Sendable {
    case stereo
    case wideMono
    case trueMono

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .stereo: return "Stereo"
        case .wideMono: return "Wide Mono"
        case .trueMono: return "True Mono"
        }
    }
    var cType: N60StereoMode {
        switch self {
        case .stereo: return N60StereoModeStereo
        case .wideMono: return N60StereoModeWideMono
        case .trueMono: return N60StereoModeTrueMono
        }
    }
}

struct StereoWidenerConfiguration: Equatable, Sendable {
    static let lowWidthRange = 0.0...1.0
    static let midWidthRange = 1.0...2.0
    static let highWidthRange = 1.0...2.0
    static let lowMidFrequencyRange = 80.0...500.0
    static let midHighFrequencyRange = 1_500.0...8_000.0

    var enabled = false
    var monoLowBand = true
    var lowWidth = 0.0
    var midWidth = 1.0
    var highWidth = 1.0
    var lowMidFrequencyHz = 200.0
    var midHighFrequencyHz = 4_000.0

    func validate() throws {
        guard lowWidth.isFinite, Self.lowWidthRange.contains(lowWidth),
              midWidth.isFinite, Self.midWidthRange.contains(midWidth),
              highWidth.isFinite, Self.highWidthRange.contains(highWidth),
              lowMidFrequencyHz.isFinite, Self.lowMidFrequencyRange.contains(lowMidFrequencyHz),
              midHighFrequencyHz.isFinite, Self.midHighFrequencyRange.contains(midHighFrequencyHz),
              lowMidFrequencyHz < midHighFrequencyHz else {
            throw DynamicsConfigurationError.invalidStereoWidener
        }
    }
}

struct DCOffsetFilterConfiguration: Equatable, Sendable {""",
)
replace_once(
    swift,
    "struct DynamicsConfiguration: Equatable, Sendable {\n    var dcOffsetFilter",
    """struct DynamicsConfiguration: Equatable, Sendable {
    var stereoMode: StereoProcessingMode = .stereo
    var stereoWidener = StereoWidenerConfiguration()
    var dcOffsetFilter""",
)
replace_once(
    swift,
    "func makeSnapshot(sampleRate: Double) throws -> N60DynamicsSnapshot {\n        try infrasonicFilter.validate()",
    """func makeSnapshot(sampleRate: Double) throws -> N60DynamicsSnapshot {
        try stereoWidener.validate()
        try infrasonicFilter.validate()""",
)
replace_once(
    swift,
    "var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)\n        guard N60DynamicsSnapshotSetDCOffsetFilter",
    """var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        guard N60DynamicsSnapshotSetStereoMode(&snapshot, stereoMode.cType) else { throw DynamicsConfigurationError.invalidStereoWidener }
        guard N60DynamicsSnapshotSetStereoWidener(
            &snapshot,
            sampleRate,
            stereoWidener.enabled,
            stereoWidener.monoLowBand,
            stereoWidener.lowMidFrequencyHz,
            stereoWidener.midHighFrequencyHz,
            Float(stereoWidener.lowWidth),
            Float(stereoWidener.midWidth),
            Float(stereoWidener.highWidth)
        ) else { throw DynamicsConfigurationError.invalidStereoWidener }
        guard N60DynamicsSnapshotSetDCOffsetFilter""",
)

print("PR29 stereo mode + widener integration applied")
