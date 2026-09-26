from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)

# ---- Xcode project ----
p = Path("NotchSixty.xcodeproj/project.pbxproj")
text = p.read_text()
text = replace_once(text,
    "\t\tA30000000000000000000015 /* N60SpectralDenoiser.c in Sources */ = {isa = PBXBuildFile; fileRef = A30000000000000000000029 /* N60SpectralDenoiser.c */; };\n",
    "\t\tA30000000000000000000015 /* N60SpectralDenoiser.c in Sources */ = {isa = PBXBuildFile; fileRef = A30000000000000000000029 /* N60SpectralDenoiser.c */; };\n\t\tA30000000000000000000016 /* N60DynamicEQ.c in Sources */ = {isa = PBXBuildFile; fileRef = A3000000000000000000002B /* N60DynamicEQ.c */; };\n",
    "pbx build file")
text = replace_once(text,
    "\t\tA3000000000000000000002A /* N60SpectralDenoiser.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = N60SpectralDenoiser.h; sourceTree = \"<group>\"; };\n",
    "\t\tA3000000000000000000002A /* N60SpectralDenoiser.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = N60SpectralDenoiser.h; sourceTree = \"<group>\"; };\n\t\tA3000000000000000000002B /* N60DynamicEQ.c */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = N60DynamicEQ.c; sourceTree = \"<group>\"; };\n\t\tA3000000000000000000002C /* N60DynamicEQ.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = N60DynamicEQ.h; sourceTree = \"<group>\"; };\n",
    "pbx refs")
text = replace_once(text,
    "\t\t\t\tA3000000000000000000002A /* N60SpectralDenoiser.h */,\n",
    "\t\t\t\tA3000000000000000000002A /* N60SpectralDenoiser.h */,\n\t\t\t\tA3000000000000000000002B /* N60DynamicEQ.c */,\n\t\t\t\tA3000000000000000000002C /* N60DynamicEQ.h */,\n",
    "pbx group")
text = replace_once(text,
    "\t\t\t\tA30000000000000000000015 /* N60SpectralDenoiser.c in Sources */,\n",
    "\t\t\t\tA30000000000000000000015 /* N60SpectralDenoiser.c in Sources */,\n\t\t\t\tA30000000000000000000016 /* N60DynamicEQ.c in Sources */,\n",
    "pbx sources")
p.write_text(text)

# ---- C dynamics header ----
p = Path("NotchSixty/Audio/Realtime/N60Dynamics.h")
text = p.read_text()
text = replace_once(text,
    '#include "N60Crossover.h"\n#include "N60SpectralDenoiser.h"\n',
    '#include "N60Crossover.h"\n#include "N60DynamicEQ.h"\n#include "N60SpectralDenoiser.h"\n',
    "dynamics include")
text = replace_once(text,
    "    N60DialogueLevelerSnapshot dialogueLeveler;\n    N60DeEsserSnapshot deEsser;\n",
    "    N60DialogueLevelerSnapshot dialogueLeveler;\n    N60DynamicEQSnapshot dynamicEQ;\n    N60DeEsserSnapshot deEsser;\n",
    "snapshot field")
text = replace_once(text,
    "    float dialogueVoiceConfidence;\n    float deEsserGainDB;\n",
    "    float dialogueVoiceConfidence;\n    N60DynamicEQRuntime dynamicEQ;\n    float deEsserGainDB;\n",
    "runtime field")
text = replace_once(text,
    "    float dialogueBoostDB;\n    float compressorGainReductionDB;\n",
    "    float dialogueBoostDB;\n    uint32_t dynamicEQActiveBandCount;\n    float dynamicEQMaxAbsGainDB;\n    float compressorGainReductionDB;\n",
    "telemetry fields")
marker = "bool N60DynamicsSnapshotSetDeEsser(\n"
insert = """bool N60DynamicsSnapshotSetDynamicEQEnabled(
    N60DynamicsSnapshot * _Nonnull snapshot,
    bool enabled
);

bool N60DynamicsSnapshotSetDynamicEQBand(
    N60DynamicsSnapshot * _Nonnull snapshot,
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
);

"""
text = replace_once(text, marker, insert + marker, "dynamic eq declarations")
p.write_text(text)

# ---- C dynamics implementation ----
p = Path("NotchSixty/Audio/Realtime/N60Dynamics.c")
text = p.read_text()
text = replace_once(text,
    "    snapshot.dialogueLeveler.bandHighPass = N60BiquadCoefficientsMakeIdentity();\n    snapshot.dialogueLeveler.bandLowPass = N60BiquadCoefficientsMakeIdentity();\n\n    snapshot.deEsser.enabled = false;\n",
    "    snapshot.dialogueLeveler.bandHighPass = N60BiquadCoefficientsMakeIdentity();\n    snapshot.dialogueLeveler.bandLowPass = N60BiquadCoefficientsMakeIdentity();\n\n    snapshot.dynamicEQ = N60DynamicEQSnapshotMakeBypassed(sampleRate);\n\n    snapshot.deEsser.enabled = false;\n",
    "dynamic eq bypass snapshot")

marker = "bool N60DynamicsSnapshotSetDeEsser(\n"
impl = """bool N60DynamicsSnapshotSetDynamicEQEnabled(
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

"""
text = replace_once(text, marker, impl + marker, "dynamic eq setters")
text = replace_once(text,
    "        || !N60BiquadCoefficientsAreFinite(snapshot.dialogueLeveler.bandHighPass)\n        || !N60BiquadCoefficientsAreFinite(snapshot.dialogueLeveler.bandLowPass)) return false;\n\n    if (!isfinite(snapshot.deEsser.frequencyHz)\n",
    "        || !N60BiquadCoefficientsAreFinite(snapshot.dialogueLeveler.bandHighPass)\n        || !N60BiquadCoefficientsAreFinite(snapshot.dialogueLeveler.bandLowPass)) return false;\n\n    if (!N60DynamicEQSnapshotIsValid(snapshot.dynamicEQ)) return false;\n\n    if (!isfinite(snapshot.deEsser.frequencyHz)\n",
    "dynamic eq validation")
text = replace_once(text,
    "    runtime->pauseGateGain = 1.0f;\n    runtime->gateOpen = true;\n",
    "    runtime->pauseGateGain = 1.0f;\n    runtime->gateOpen = true;\n    N60DynamicEQRuntimeReset(&runtime->dynamicEQ);\n",
    "dynamic eq reset")
text = replace_once(text,
    "    process_dialogue_leveler(runtime, snapshot, left, right);\n    process_de_esser(runtime, snapshot, left, right);\n",
    "    process_dialogue_leveler(runtime, snapshot, left, right);\n    N60DynamicEQProcessStereoFrame(&runtime->dynamicEQ, snapshot.dynamicEQ, left, right);\n    process_de_esser(runtime, snapshot, left, right);\n",
    "dynamic eq processing")
text = replace_once(text,
    "    telemetry.dialogueVoiceConfidence = runtime->dialogueVoiceConfidence;\n    telemetry.dialogueBoostDB = runtime->dialogueBoostDB;\n",
    "    telemetry.dialogueVoiceConfidence = runtime->dialogueVoiceConfidence;\n    telemetry.dialogueBoostDB = runtime->dialogueBoostDB;\n    N60DynamicEQTelemetry dynamicEQ = N60DynamicEQRuntimeTelemetry(&runtime->dynamicEQ);\n    telemetry.dynamicEQActiveBandCount = dynamicEQ.activeBandCount;\n    telemetry.dynamicEQMaxAbsGainDB = dynamicEQ.maxAbsDynamicGainDB;\n",
    "dynamic eq telemetry")
p.write_text(text)

# ---- Swift configuration ----
p = Path("NotchSixty/Audio/DynamicsConfiguration.swift")
text = p.read_text()
text = replace_once(text,
    "    case invalidDialogueLeveler\n    case invalidDeEsser\n",
    "    case invalidDialogueLeveler\n    case invalidDynamicEQ\n    case invalidDeEsser\n",
    "swift error case")
text = replace_once(text,
    "        case .invalidDialogueLeveler:\n            return \"Dialogue Relative Leveler parameters are outside the supported production range.\"\n        case .invalidDeEsser:\n",
    "        case .invalidDialogueLeveler:\n            return \"Dialogue Relative Leveler parameters are outside the supported production range.\"\n        case .invalidDynamicEQ:\n            return \"Dynamic EQ parameters are outside the supported production range.\"\n        case .invalidDeEsser:\n",
    "swift error description")

marker = "struct DeEsserConfiguration: Equatable, Sendable {\n"
dyn_swift = r'''enum DynamicEQDirection: String, CaseIterable, Identifiable, Sendable {
    case cutOnly
    case boostOnly
    case both

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cutOnly: return "Cut Only"
        case .boostOnly: return "Boost Only"
        case .both: return "Both"
        }
    }
    var cType: N60DynamicEQDirection {
        switch self {
        case .cutOnly: return N60DynamicEQDirectionCutOnly
        case .boostOnly: return N60DynamicEQDirectionBoostOnly
        case .both: return N60DynamicEQDirectionBoth
        }
    }
}

enum DynamicEQDetectorMode: String, CaseIterable, Identifiable, Sendable {
    case peak
    case rms

    var id: String { rawValue }
    var displayName: String { self == .peak ? "Peak" : "RMS" }
    var cType: N60DynamicEQDetectorMode {
        self == .peak ? N60DynamicEQDetectorPeak : N60DynamicEQDetectorRMS
    }
}

struct DynamicEQBandConfiguration: Equatable, Sendable {
    static let frequencyRange = 20.0...20_000.0
    static let qRange = 0.4...8.0
    static let staticGainRange = -18.0...6.0
    static let thresholdRange = -60.0...0.0
    static let ratioRange = 1.0...10.0
    static let rangeRange = -24.0...0.0
    static let attackRange = 1.0...100.0
    static let releaseRange = 10.0...1_000.0
    static let boostThresholdRange = -60.0...0.0
    static let boostRatioRange = 1.0...10.0
    static let maxBoostRange = 0.0...12.0
    static let rmsWindowRange = 5.0...200.0

    var enabled = true
    var frequencyHz = 1_000.0
    var q = 1.0
    var staticGainDB = 0.0
    var thresholdDB = -24.0
    var ratio = 2.0
    var rangeDB = -24.0
    var attackMs = 10.0
    var releaseMs = 100.0
    var direction: DynamicEQDirection = .cutOnly
    var boostThresholdDB = -40.0
    var boostRatio = 2.0
    var maxBoostDB = 6.0
    var detectorMode: DynamicEQDetectorMode = .peak
    var rmsWindowMs = 50.0

    func validate(sampleRate: Double) throws {
        guard frequencyHz.isFinite, Self.frequencyRange.contains(frequencyHz), frequencyHz < sampleRate * 0.5,
              q.isFinite, Self.qRange.contains(q),
              staticGainDB.isFinite, Self.staticGainRange.contains(staticGainDB),
              thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),
              ratio.isFinite, Self.ratioRange.contains(ratio),
              rangeDB.isFinite, Self.rangeRange.contains(rangeDB),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              boostThresholdDB.isFinite, Self.boostThresholdRange.contains(boostThresholdDB),
              boostRatio.isFinite, Self.boostRatioRange.contains(boostRatio),
              maxBoostDB.isFinite, Self.maxBoostRange.contains(maxBoostDB),
              rmsWindowMs.isFinite, Self.rmsWindowRange.contains(rmsWindowMs) else {
            throw DynamicsConfigurationError.invalidDynamicEQ
        }
    }
}

struct DynamicEQConfiguration: Equatable, Sendable {
    static let maximumBandCount = Int(N60_DYNAMIC_EQ_MAX_BANDS)
    var enabled = false
    var bands: [DynamicEQBandConfiguration] = []

    func validate(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0, bands.count <= Self.maximumBandCount else {
            throw DynamicsConfigurationError.invalidDynamicEQ
        }
        try bands.forEach { try $0.validate(sampleRate: sampleRate) }
    }
}

'''
text = replace_once(text, marker, dyn_swift + marker, "swift dynamic eq types")
text = replace_once(text,
    "    var dialogueRelativeLeveler = DialogueRelativeLevelerConfiguration()\n    var deEsser = DeEsserConfiguration()\n",
    "    var dialogueRelativeLeveler = DialogueRelativeLevelerConfiguration()\n    var dynamicEQ = DynamicEQConfiguration()\n    var deEsser = DeEsserConfiguration()\n",
    "swift property")
text = replace_once(text,
    "        try dialogueRelativeLeveler.validate(sampleRate: sampleRate)\n        try deEsser.validate()\n",
    "        try dialogueRelativeLeveler.validate(sampleRate: sampleRate)\n        try dynamicEQ.validate(sampleRate: sampleRate)\n        try deEsser.validate()\n",
    "swift validate")
anchor = "        guard N60DynamicsSnapshotSetDeEsserAdvanced(\n"
configure = r'''        guard N60DynamicsSnapshotSetDynamicEQEnabled(&snapshot, dynamicEQ.enabled) else {
            throw DynamicsConfigurationError.invalidDynamicEQ
        }
        for (index, band) in dynamicEQ.bands.enumerated() {
            guard N60DynamicsSnapshotSetDynamicEQBand(
                &snapshot,
                sampleRate,
                UInt32(index),
                band.enabled,
                band.frequencyHz,
                Float(band.q),
                Float(band.staticGainDB),
                Float(band.thresholdDB),
                Float(band.ratio),
                Float(band.rangeDB),
                Float(band.attackMs),
                Float(band.releaseMs),
                band.direction.cType,
                Float(band.boostThresholdDB),
                Float(band.boostRatio),
                Float(band.maxBoostDB),
                band.detectorMode.cType,
                Float(band.rmsWindowMs)
            ) else { throw DynamicsConfigurationError.invalidDynamicEQ }
        }
'''
text = replace_once(text, anchor, configure + anchor, "swift snapshot config")
p.write_text(text)

# ---- Tests ----
p = Path("NotchSixtyTests/DynamicsTests.swift")
text = p.read_text()
tests = r'''

    func testDynamicEQDisabledIsTransparentWithConfiguredBand() {
        let sampleRate = 96_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetDynamicEQEnabled(&snapshot, false))
        XCTAssertTrue(N60DynamicsSnapshotSetDynamicEQBand(
            &snapshot, sampleRate, 0, true, 1_000, 1.0, 3.0, -30, 4.0, -12, 5, 100,
            N60DynamicEQDirectionCutOnly, -40, 2.0, 6.0, N60DynamicEQDetectorPeak, 50
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        for frame in 0..<20_000 {
            let input = Float(0.4 * sin(2.0 * Double.pi * 1_000.0 * Double(frame) / sampleRate))
            var left = input
            var right = -input * 0.7
            N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
            XCTAssertEqual(left, input, accuracy: 0.000_001)
            XCTAssertEqual(right, -input * 0.7, accuracy: 0.000_001)
        }
    }

    func testDynamicEQCutOnlyAttenuatesInBandAndStaysLinked() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetDynamicEQEnabled(&snapshot, true))
        XCTAssertTrue(N60DynamicsSnapshotSetDynamicEQBand(
            &snapshot, sampleRate, 0, true, 1_000, 2.0, 0.0, -30, 4.0, -12, 2, 80,
            N60DynamicEQDirectionCutOnly, -50, 2.0, 6.0, N60DynamicEQDetectorPeak, 50
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        var inSq = 0.0
        var outSq = 0.0
        var ratioSamples: [Double] = []
        for frame in 0..<96_000 {
            let input = Float(0.35 * sin(2.0 * Double.pi * 1_000.0 * Double(frame) / sampleRate))
            var left = input
            var right = input * 0.5
            N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
            if frame >= 48_000 {
                inSq += Double(input * input)
                outSq += Double(left * left)
                if abs(right) > 0.0001 { ratioSamples.append(Double(left / right)) }
            }
        }
        XCTAssertLessThan(sqrt(outSq / 48_000.0), sqrt(inSq / 48_000.0) * 0.9)
        XCTAssertGreaterThan(N60DynamicsRuntimeTelemetry(&runtime).dynamicEQMaxAbsGainDB, 2.0)
        if let ratio = ratioSamples.last { XCTAssertEqual(ratio, 2.0, accuracy: 0.02) }
    }

    func testDynamicEQBoostIsBounded() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetDynamicEQEnabled(&snapshot, true))
        XCTAssertTrue(N60DynamicsSnapshotSetDynamicEQBand(
            &snapshot, sampleRate, 0, true, 1_000, 2.0, 0.0, -10, 1.0, -24, 2, 80,
            N60DynamicEQDirectionBoostOnly, -30, 4.0, 6.0, N60DynamicEQDetectorPeak, 50
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        for frame in 0..<96_000 {
            let input = Float(0.005 * sin(2.0 * Double.pi * 1_000.0 * Double(frame) / sampleRate))
            var left = input
            var right = input
            N60DynamicsProcessCoreStereoFrame(&runtime, snapshot, &left, &right)
        }
        let telemetry = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertGreaterThan(telemetry.dynamicEQMaxAbsGainDB, 1.0)
        XCTAssertLessThanOrEqual(telemetry.dynamicEQMaxAbsGainDB, 6.01)
    }

    func testDynamicEQConfigurationRejectsInvalidBandAndSupportsSixteenBandsAt384k() throws {
        var invalid = DynamicsConfiguration()
        invalid.dynamicEQ.enabled = true
        invalid.dynamicEQ.bands = [DynamicEQBandConfiguration()]
        invalid.dynamicEQ.bands[0].q = 9.0
        XCTAssertThrowsError(try invalid.makeSnapshot(sampleRate: 96_000))

        var config = DynamicsConfiguration()
        config.dynamicEQ.enabled = true
        config.dynamicEQ.bands = (0..<16).map { index in
            var band = DynamicEQBandConfiguration()
            band.frequencyHz = 40.0 * pow(1.35, Double(index))
            band.frequencyHz = min(band.frequencyHz, 18_000.0)
            band.q = 1.2
            band.thresholdDB = -24
            return band
        }
        let snapshot = try config.makeSnapshot(sampleRate: 384_000)
        XCTAssertEqual(snapshot.dynamicEQ.bandCount, 16)
        XCTAssertTrue(N60DynamicEQSnapshotIsValid(snapshot.dynamicEQ))
    }
'''
pos = text.rfind("\n}")
if pos < 0:
    raise RuntimeError("tests: class closing brace not found")
text = text[:pos] + tests + text[pos:]
p.write_text(text)

print("PR33 Slice 1 integration applied")
