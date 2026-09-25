from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"missing insertion point: {label}")
    return text.replace(old, new, 1)

# N60Dynamics.c: defaults, setters, validation, processing.
path = Path("NotchSixty/Audio/Realtime/N60Dynamics.c")
text = path.read_text()

text = replace_once(
    text,
    "#define N60_MULTIBAND_RELEASE_MS 150.0f\n",
    "#define N60_MULTIBAND_RELEASE_MS 150.0f\n#define N60_DC_CUTOFF_HZ 0.5\n#define N60_LOUDNESS_LOW_SHELF_HZ 120.0\n#define N60_LOUDNESS_HIGH_SHELF_HZ 8000.0\n#define N60_LOUDNESS_MAX_BASS_DB 6.0\n#define N60_LOUDNESS_MAX_TREBLE_DB 3.0\n",
    "conditioning constants",
)

text = replace_once(
    text,
    "N60DynamicsSnapshot N60DynamicsSnapshotMakeBypassed(double sampleRate) {\n    N60DynamicsSnapshot snapshot = {0};\n\n    snapshot.deEsser.enabled = false;",
    "N60DynamicsSnapshot N60DynamicsSnapshotMakeBypassed(double sampleRate) {\n    N60DynamicsSnapshot snapshot = {0};\n\n    snapshot.dcOffsetFilter.enabled = false;\n    snapshot.dcOffsetFilter.poleCoefficient = (float)exp(-2.0 * M_PI * N60_DC_CUTOFF_HZ / sampleRate);\n\n    snapshot.infrasonicFilter.enabled = false;\n    snapshot.infrasonicFilter.cutoffHz = 18.0;\n    snapshot.infrasonicFilter.slope = N60InfrasonicSlope48DBPerOctave;\n    snapshot.infrasonicFilter.sectionCount = 0;\n    for (uint32_t index = 0; index < N60_MAX_INFRASONIC_SECTIONS; ++index) {\n        snapshot.infrasonicFilter.highPass[index] = N60BiquadCoefficientsMakeIdentity();\n    }\n\n    snapshot.loudnessContour.enabled = false;\n    snapshot.loudnessContour.strength = 1.0f;\n    snapshot.loudnessContour.lowShelf = N60BiquadCoefficientsMakeIdentity();\n    snapshot.loudnessContour.highShelf = N60BiquadCoefficientsMakeIdentity();\n\n    snapshot.deEsser.enabled = false;",
    "conditioning defaults",
)

insert = r'''
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

    // Cascaded Butterworth-style biquads. Each section uses Q=1/sqrt(2),
    // yielding deterministic steep protection with no control-plane work in RT.
    for (uint32_t index = 0; index < sectionCount; ++index) {
        if (!N60BiquadDesign(
                N60BiquadFilterTypeHighPass,
                sampleRate,
                cutoffHz,
                0.0,
                0.7071067811865476,
                &configured.highPass[index])) return false;
    }
    snapshot->infrasonicFilter = configured;
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
    double bassDB = N60_LOUDNESS_MAX_BASS_DB * strength;
    double trebleDB = N60_LOUDNESS_MAX_TREBLE_DB * strength;
    if (!N60BiquadDesign(N60BiquadFilterTypeLowShelf, sampleRate, N60_LOUDNESS_LOW_SHELF_HZ, bassDB, 0.7071067811865476, &configured.lowShelf)
        || !N60BiquadDesign(N60BiquadFilterTypeHighShelf, sampleRate, N60_LOUDNESS_HIGH_SHELF_HZ, trebleDB, 0.7071067811865476, &configured.highShelf)) return false;
    snapshot->loudnessContour = configured;
    return true;
}

'''
text = replace_once(text, "bool N60DynamicsSnapshotSetDeEsser(\n", insert + "bool N60DynamicsSnapshotSetDeEsser(\n", "conditioning setters")

text = replace_once(
    text,
    "bool N60DynamicsSnapshotIsValid(N60DynamicsSnapshot snapshot) {\n    if (!valid_coefficient(snapshot.bypassTransitionCoefficient)) return false;\n\n    if (!isfinite(snapshot.deEsser.frequencyHz)",
    "bool N60DynamicsSnapshotIsValid(N60DynamicsSnapshot snapshot) {\n    if (!valid_coefficient(snapshot.bypassTransitionCoefficient)) return false;\n    if (!isfinite(snapshot.dcOffsetFilter.poleCoefficient) || snapshot.dcOffsetFilter.poleCoefficient <= 0.0f || snapshot.dcOffsetFilter.poleCoefficient >= 1.0f) return false;\n    if (!isfinite(snapshot.infrasonicFilter.cutoffHz) || snapshot.infrasonicFilter.cutoffHz < 10.0 || snapshot.infrasonicFilter.cutoffHz > 30.0 || snapshot.infrasonicFilter.sectionCount > N60_MAX_INFRASONIC_SECTIONS) return false;\n    for (uint32_t index = 0; index < snapshot.infrasonicFilter.sectionCount; ++index) {\n        if (!N60BiquadCoefficientsAreFinite(snapshot.infrasonicFilter.highPass[index])) return false;\n    }\n    if (!isfinite(snapshot.loudnessContour.strength) || snapshot.loudnessContour.strength < 0.0f || snapshot.loudnessContour.strength > 1.0f\n        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.lowShelf)\n        || !N60BiquadCoefficientsAreFinite(snapshot.loudnessContour.highShelf)) return false;\n\n    if (!isfinite(snapshot.deEsser.frequencyHz)",
    "conditioning validation",
)

processing = r'''
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

static void process_loudness_contour(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    float dryLeft = *left;
    float dryRight = *right;
    float wetLeft = N60BiquadProcessSample(snapshot.loudnessContour.lowShelf, &runtime->loudnessLowShelfLeft, dryLeft);
    wetLeft = N60BiquadProcessSample(snapshot.loudnessContour.highShelf, &runtime->loudnessHighShelfLeft, wetLeft);
    float wetRight = N60BiquadProcessSample(snapshot.loudnessContour.lowShelf, &runtime->loudnessLowShelfRight, dryRight);
    wetRight = N60BiquadProcessSample(snapshot.loudnessContour.highShelf, &runtime->loudnessHighShelfRight, wetRight);
    float target = snapshot.loudnessContour.enabled ? 1.0f : 0.0f;
    runtime->loudnessMix = smooth_toward(runtime->loudnessMix, target, snapshot.bypassTransitionCoefficient);
    *left = dryLeft + (wetLeft - dryLeft) * runtime->loudnessMix;
    *right = dryRight + (wetRight - dryRight) * runtime->loudnessMix;
}

'''
text = replace_once(text, "static void process_de_esser(\n", processing + "static void process_de_esser(\n", "conditioning processing")
text = replace_once(
    text,
    "    process_de_esser(runtime, snapshot, left, right);\n",
    "    process_loudness_contour(runtime, snapshot, left, right);\n    process_de_esser(runtime, snapshot, left, right);\n",
    "loudness order",
)
path.write_text(text)

# DynamicsConfiguration.swift: product configuration surface and snapshot wiring.
path = Path("NotchSixty/Audio/DynamicsConfiguration.swift")
text = path.read_text()
text = replace_once(
    text,
    "    case invalidDeEsser\n",
    "    case invalidDCOffsetFilter\n    case invalidInfrasonicFilter\n    case invalidLoudnessContour\n    case invalidDeEsser\n",
    "config errors",
)
text = replace_once(
    text,
    "        switch self {\n        case .invalidDeEsser:",
    "        switch self {\n        case .invalidDCOffsetFilter:\n            return \"DC Offset Filter configuration is invalid.\"\n        case .invalidInfrasonicFilter:\n            return \"Infrasonic Filter parameters are outside the supported production range.\"\n        case .invalidLoudnessContour:\n            return \"Loudness Contour parameters are outside the supported production range.\"\n        case .invalidDeEsser:",
    "config error descriptions",
)

configs = r'''
struct DCOffsetFilterConfiguration: Equatable, Sendable {
    var enabled = false
}

enum InfrasonicSlope: String, CaseIterable, Identifiable, Sendable {
    case db24
    case db48
    case db96

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .db24: return "24 dB/oct"
        case .db48: return "48 dB/oct"
        case .db96: return "96 dB/oct"
        }
    }
    var cType: N60InfrasonicSlope {
        switch self {
        case .db24: return N60InfrasonicSlope24DBPerOctave
        case .db48: return N60InfrasonicSlope48DBPerOctave
        case .db96: return N60InfrasonicSlope96DBPerOctave
        }
    }
}

struct InfrasonicFilterConfiguration: Equatable, Sendable {
    static let cutoffRange = 10.0...30.0
    var enabled = false
    var cutoffHz = 18.0
    var slope: InfrasonicSlope = .db48

    func validate() throws {
        guard cutoffHz.isFinite, Self.cutoffRange.contains(cutoffHz) else {
            throw DynamicsConfigurationError.invalidInfrasonicFilter
        }
    }
}

struct LoudnessContourConfiguration: Equatable, Sendable {
    static let strengthRange = 0.0...1.0
    var enabled = false
    var strength = 1.0

    func validate() throws {
        guard strength.isFinite, Self.strengthRange.contains(strength) else {
            throw DynamicsConfigurationError.invalidLoudnessContour
        }
    }
}

'''
text = replace_once(text, "struct DeEsserConfiguration: Equatable, Sendable {\n", configs + "struct DeEsserConfiguration: Equatable, Sendable {\n", "conditioning configs")
text = replace_once(
    text,
    "struct DynamicsConfiguration: Equatable, Sendable {\n    var deEsser",
    "struct DynamicsConfiguration: Equatable, Sendable {\n    var dcOffsetFilter = DCOffsetFilterConfiguration()\n    var infrasonicFilter = InfrasonicFilterConfiguration()\n    var loudnessContour = LoudnessContourConfiguration()\n    var deEsser",
    "conditioning state",
)
text = replace_once(
    text,
    "    func makeSnapshot(sampleRate: Double) throws -> N60DynamicsSnapshot {\n        try deEsser.validate()",
    "    func makeSnapshot(sampleRate: Double) throws -> N60DynamicsSnapshot {\n        try infrasonicFilter.validate()\n        try loudnessContour.validate()\n        try deEsser.validate()",
    "conditioning validation calls",
)
text = replace_once(
    text,
    "        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)\n        guard N60DynamicsSnapshotSetDeEsser(",
    "        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)\n        guard N60DynamicsSnapshotSetDCOffsetFilter(&snapshot, sampleRate, dcOffsetFilter.enabled) else { throw DynamicsConfigurationError.invalidDCOffsetFilter }\n        guard N60DynamicsSnapshotSetInfrasonicFilter(&snapshot, sampleRate, infrasonicFilter.enabled, infrasonicFilter.cutoffHz, infrasonicFilter.slope.cType) else { throw DynamicsConfigurationError.invalidInfrasonicFilter }\n        guard N60DynamicsSnapshotSetLoudnessContour(&snapshot, sampleRate, loudnessContour.enabled, Float(loudnessContour.strength)) else { throw DynamicsConfigurationError.invalidLoudnessContour }\n        guard N60DynamicsSnapshotSetDeEsser(",
    "conditioning snapshot wiring",
)
path.write_text(text)

# Render placement: conditioning before EQ.
path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
text = path.read_text()
text = replace_once(
    text,
    "        left *= inputGain * headroomGain;\n        right *= inputGain * headroomGain;\n\n        if (!context->snapshot.eqBypassed) {",
    "        left *= inputGain * headroomGain;\n        right *= inputGain * headroomGain;\n\n        N60DynamicsProcessPreEQStereoFrame(&kernel->dynamicsRuntime, context->snapshot.dynamics, &left, &right);\n\n        if (!context->snapshot.eqBypassed) {",
    "pre-EQ conditioning placement",
)
path.write_text(text)

# Extend PR28 validation UI after the first integration script has created it.
path = Path("NotchSixty/NotchSixtyApp.swift")
text = path.read_text()
text = replace_once(
    text,
    "        let deEsserEnabled = dynamicsBinding(\\.deEsser.enabled)\n",
    "        let dcEnabled = dynamicsBinding(\\.dcOffsetFilter.enabled)\n        let infrasonicEnabled = dynamicsBinding(\\.infrasonicFilter.enabled)\n        let infrasonicCutoff = dynamicsBinding(\\.infrasonicFilter.cutoffHz)\n        let infrasonicSlope = dynamicsBinding(\\.infrasonicFilter.slope)\n        let contourEnabled = dynamicsBinding(\\.loudnessContour.enabled)\n        let contourStrength = dynamicsBinding(\\.loudnessContour.strength)\n        let deEsserEnabled = dynamicsBinding(\\.deEsser.enabled)\n",
    "conditioning bindings",
)
conditioning_ui = r'''
                GroupBox("Signal Conditioning") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("DC Offset Filter (0.5 Hz)", isOn: dcEnabled).toggleStyle(.switch)
                        Toggle("Infrasonic Filter", isOn: infrasonicEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Cutoff").frame(width: 90, alignment: .leading)
                            Slider(value: infrasonicCutoff, in: InfrasonicFilterConfiguration.cutoffRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.infrasonicFilter.cutoffHz, specifier: \"%.0f\") Hz")
                                .monospacedDigit().frame(width: 80)
                        }
                        Picker("Slope", selection: infrasonicSlope) {
                            ForEach(InfrasonicSlope.allCases) { value in Text(value.displayName).tag(value) }
                        }.frame(maxWidth: 320)
                        Divider()
                        Toggle("Loudness Contour", isOn: contourEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Strength").frame(width: 90, alignment: .leading)
                            Slider(value: contourStrength, in: LoudnessContourConfiguration.strengthRange, step: 0.05)
                            Text("\(engine.dynamicsConfiguration.loudnessContour.strength, specifier: \"%.2f\")")
                                .monospacedDigit().frame(width: 70)
                        }
                    }.padding(6)
                }

'''
text = replace_once(text, "                GroupBox(\"De-Esser\") {\n", conditioning_ui + "                GroupBox(\"De-Esser\") {\n", "conditioning UI")
path.write_text(text)

# Fix stale schema expectation generated by the first integration script.
path = Path("NotchSixtyTests/LiveLinearPhaseTests.swift")
text = path.read_text()
text = text.replace("XCTAssertEqual(ProductConfiguration.currentSchemaVersion, 5)", "XCTAssertEqual(ProductConfiguration.currentSchemaVersion, 6)")
path.write_text(text)

# Add deterministic conditioning tests.
path = Path("NotchSixtyTests/DynamicsTests.swift")
text = path.read_text()
tests = r'''

    func testDCOffsetFilterRemovesConstantBias() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetDCOffsetFilter(&snapshot, sampleRate, true))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        var last: Float = 0
        for _ in 0..<240_000 {
            var left: Float = 0.25
            var right: Float = 0.25
            N60DynamicsProcessPreEQStereoFrame(&runtime, snapshot, &left, &right)
            last = left
        }
        XCTAssertLessThan(abs(last), 0.01)
    }

    func testInfrasonicFilterAttenuatesFiveHzAndPassesOneKHz() {
        let sampleRate = 48_000.0
        func rms(at frequency: Double) -> Double {
            var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
            XCTAssertTrue(N60DynamicsSnapshotSetInfrasonicFilter(&snapshot, sampleRate, true, 18, N60InfrasonicSlope48DBPerOctave))
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)
            var sum = 0.0
            let start = 96_000
            for frame in 0..<192_000 {
                var left = Float(0.5 * sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate))
                var right = left
                N60DynamicsProcessPreEQStereoFrame(&runtime, snapshot, &left, &right)
                if frame >= start { sum += Double(left * left) }
            }
            return sqrt(sum / Double(192_000 - start))
        }
        XCTAssertLessThan(rms(at: 5), 0.03)
        XCTAssertGreaterThan(rms(at: 1_000), 0.30)
    }

    func testLoudnessContourBoostsBassMoreThanMidband() {
        let sampleRate = 48_000.0
        func rms(at frequency: Double) -> Double {
            var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
            XCTAssertTrue(N60DynamicsSnapshotSetLoudnessContour(&snapshot, sampleRate, true, 1.0))
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)
            var sum = 0.0
            let start = 48_000
            for frame in 0..<96_000 {
                var left = Float(0.2 * sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate))
                var right = left
                N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
                if frame >= start { sum += Double(left * left) }
            }
            return sqrt(sum / Double(96_000 - start))
        }
        XCTAssertGreaterThan(rms(at: 60), rms(at: 1_000) * 1.25)
    }
'''
text = replace_once(text, "\n}\n", tests + "\n}\n", "conditioning tests")
path.write_text(text)
