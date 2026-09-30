#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]

# 1) Typed logical-bus processing model.
route_path = root / "NotchSixty" / "Audio" / "Routing" / "AudioRouteConfiguration.swift"
route = route_path.read_text(encoding="utf-8")
if "struct SpeakerDriverProcessingConfiguration:" not in route:
    route += r'''

// MARK: - PR43 per-driver Playback System processing

/// Validation errors for processing that belongs to a logical speaker bus.
/// Mandatory crossover filtering is intentionally not represented here and
/// therefore cannot be bypassed by this configuration.
enum SpeakerDriverProcessingError: Error, Equatable, LocalizedError {
    case tooManyBusEntries(Int)
    case duplicateBus(SpeakerOutputBus)
    case tooManyEQBands(bus: SpeakerOutputBus, count: Int)
    case unsupportedEQShape(bus: SpeakerOutputBus, type: EQFilterType)
    case invalidEQBand(bus: SpeakerOutputBus, index: Int)
    case invalidTrim(bus: SpeakerOutputBus, value: Double)
    case invalidDelay(bus: SpeakerOutputBus, value: Double)
    case invalidLimiterThreshold(bus: SpeakerOutputBus, value: Double)
    case changesRequireIdle

    var errorDescription: String? {
        switch self {
        case .tooManyBusEntries(let count):
            return "Per-driver processing supports at most \(SpeakerOutputBus.allCases.count) logical speaker buses; configuration contains \(count)."
        case .duplicateBus(let bus):
            return "Per-driver processing contains more than one entry for \(bus.displayName)."
        case .tooManyEQBands(let bus, let count):
            return "\(bus.displayName) supports at most \(SpeakerDriverBusProcessingConfiguration.maximumEQBandCount) driver EQ bands; configuration contains \(count)."
        case .unsupportedEQShape(let bus, let type):
            return "\(type.displayName) is not a supported per-driver EQ shape on \(bus.displayName)."
        case .invalidEQBand(let bus, let index):
            return "Driver EQ band \(index + 1) on \(bus.displayName) is invalid."
        case .invalidTrim(let bus, let value):
            return "\(bus.displayName) trim \(value) dB is outside the supported range."
        case .invalidDelay(let bus, let value):
            return "\(bus.displayName) alignment delay \(value) ms is outside the supported range."
        case .invalidLimiterThreshold(let bus, let value):
            return "\(bus.displayName) limiter threshold \(value) dBFS is outside the supported range."
        case .changesRequireIdle:
            return "Stop processing before changing per-driver EQ, trim, polarity, delay, or protection."
        }
    }
}

struct SpeakerDriverBusProcessingConfiguration: Identifiable, Codable, Equatable, Sendable {
    static let maximumEQBandCount = 8
    static let trimRange = -24.0 ... 12.0
    static let delayRangeMilliseconds = 0.0 ... 50.0
    static let limiterThresholdRange = -30.0 ... 0.0
    static let supportedEQTypes: Set<EQFilterType> = [
        .peaking, .lowShelf, .highShelf, .notch, .allPass,
    ]

    var bus: SpeakerOutputBus
    var enabled: Bool
    var eqBands: [EQBand]
    var trimDB: Double
    var polarityInverted: Bool
    var delayMilliseconds: Double
    var limiterEnabled: Bool
    var limiterThresholdDBFS: Double

    var id: String { bus.rawValue }

    init(
        bus: SpeakerOutputBus,
        enabled: Bool = true,
        eqBands: [EQBand] = [],
        trimDB: Double = 0,
        polarityInverted: Bool = false,
        delayMilliseconds: Double = 0,
        limiterEnabled: Bool = false,
        limiterThresholdDBFS: Double = -3
    ) {
        self.bus = bus
        self.enabled = enabled
        self.eqBands = eqBands
        self.trimDB = trimDB
        self.polarityInverted = polarityInverted
        self.delayMilliseconds = delayMilliseconds
        self.limiterEnabled = limiterEnabled
        self.limiterThresholdDBFS = limiterThresholdDBFS
    }

    var isNeutral: Bool {
        enabled
            && eqBands.isEmpty
            && trimDB == 0
            && !polarityInverted
            && delayMilliseconds == 0
            && !limiterEnabled
            && limiterThresholdDBFS == -3
    }

    func validateStructure() throws {
        guard eqBands.count <= Self.maximumEQBandCount else {
            throw SpeakerDriverProcessingError.tooManyEQBands(bus: bus, count: eqBands.count)
        }
        guard trimDB.isFinite, Self.trimRange.contains(trimDB) else {
            throw SpeakerDriverProcessingError.invalidTrim(bus: bus, value: trimDB)
        }
        guard delayMilliseconds.isFinite,
              Self.delayRangeMilliseconds.contains(delayMilliseconds) else {
            throw SpeakerDriverProcessingError.invalidDelay(bus: bus, value: delayMilliseconds)
        }
        guard limiterThresholdDBFS.isFinite,
              Self.limiterThresholdRange.contains(limiterThresholdDBFS) else {
            throw SpeakerDriverProcessingError.invalidLimiterThreshold(
                bus: bus,
                value: limiterThresholdDBFS
            )
        }
        for (index, band) in eqBands.enumerated() {
            guard Self.supportedEQTypes.contains(band.type) else {
                throw SpeakerDriverProcessingError.unsupportedEQShape(bus: bus, type: band.type)
            }
            guard band.firKernel == nil,
                  !band.dynamic.enabled,
                  band.frequencyHz.isFinite,
                  band.frequencyHz > 0,
                  band.gainDB.isFinite,
                  band.gainDB >= -24,
                  band.gainDB <= 24,
                  band.q.isFinite,
                  band.q > 0 else {
                throw SpeakerDriverProcessingError.invalidEQBand(bus: bus, index: index)
            }
        }
    }
}

/// Playback-System-owned DSP keyed to logical speaker buses rather than physical
/// device/channel endpoints. Physical route changes therefore do not discard a
/// driver's acoustic calibration.
struct SpeakerDriverProcessingConfiguration: Codable, Equatable, Sendable {
    var buses: [SpeakerDriverBusProcessingConfiguration]

    init(buses: [SpeakerDriverBusProcessingConfiguration] = []) {
        self.buses = buses
    }

    var isNeutral: Bool { buses.isEmpty || buses.allSatisfy(\.isNeutral) }

    func configuration(for bus: SpeakerOutputBus) -> SpeakerDriverBusProcessingConfiguration {
        buses.first(where: { $0.bus == bus })
            ?? SpeakerDriverBusProcessingConfiguration(bus: bus)
    }

    mutating func replace(_ configuration: SpeakerDriverBusProcessingConfiguration) {
        if let index = buses.firstIndex(where: { $0.bus == configuration.bus }) {
            buses[index] = configuration
        } else {
            buses.append(configuration)
        }
        buses.sort { $0.bus.rawValue < $1.bus.rawValue }
    }

    mutating func remove(bus: SpeakerOutputBus) {
        buses.removeAll { $0.bus == bus }
    }

    func validateStructure() throws {
        guard buses.count <= SpeakerOutputBus.allCases.count else {
            throw SpeakerDriverProcessingError.tooManyBusEntries(buses.count)
        }
        var seen = Set<SpeakerOutputBus>()
        for configuration in buses {
            guard seen.insert(configuration.bus).inserted else {
                throw SpeakerDriverProcessingError.duplicateBus(configuration.bus)
            }
            try configuration.validateStructure()
        }
    }
}
'''
    route_path.write_text(route, encoding="utf-8")

# 2) Engine owns live configuration, initially control-plane only.
engine_path = root / "NotchSixty" / "Audio" / "AudioIOEngine.swift"
engine = engine_path.read_text(encoding="utf-8")
published_anchor = "    @Published private(set) var multiOutputRoutingConfiguration: MultiOutputRoutingConfiguration?\n"
if "@Published private(set) var speakerDriverProcessingConfiguration" not in engine:
    if published_anchor not in engine:
        raise SystemExit("AudioIOEngine published-state anchor not found")
    engine = engine.replace(
        published_anchor,
        published_anchor + "    @Published private(set) var speakerDriverProcessingConfiguration = SpeakerDriverProcessingConfiguration()\n",
        1,
    )

method_anchor = "    func replaceBassManagementConfiguration(_ configuration: BassManagementConfiguration) throws {\n"
if "func replaceSpeakerDriverProcessingConfiguration(" not in engine:
    method = r'''    func replaceSpeakerDriverProcessingConfiguration(
        _ configuration: SpeakerDriverProcessingConfiguration
    ) throws {
        try configuration.validateStructure()
        guard lifecycle.state == .idle || configuration == speakerDriverProcessingConfiguration else {
            throw SpeakerDriverProcessingError.changesRequireIdle
        }
        speakerDriverProcessingConfiguration = configuration
        lastErrorDescription = nil
    }

'''
    if method_anchor not in engine:
        raise SystemExit("AudioIOEngine driver-processing method anchor not found")
    engine = engine.replace(method_anchor, method + method_anchor, 1)
engine_path.write_text(engine, encoding="utf-8")

# 3) Persist as an optional field for backward-compatible archive decoding.
profile_path = root / "NotchSixty" / "State" / "ProductProfiles.swift"
profiles = profile_path.read_text(encoding="utf-8")
if "var speakerDriverProcessing: SpeakerDriverProcessingConfiguration?" not in profiles:
    field_anchor = "    var outputRouting: MultiOutputRoutingConfiguration?\n    var speakerIR: SpeakerIRConfiguration\n"
    if field_anchor not in profiles:
        raise SystemExit("PlaybackSystemState field anchor not found")
    profiles = profiles.replace(
        field_anchor,
        "    var outputRouting: MultiOutputRoutingConfiguration?\n    var speakerDriverProcessing: SpeakerDriverProcessingConfiguration?\n    var speakerIR: SpeakerIRConfiguration\n",
        1,
    )

    init_anchor = "        outputRouting: MultiOutputRoutingConfiguration? = nil,\n        speakerIR: SpeakerIRConfiguration = SpeakerIRConfiguration()\n"
    if init_anchor not in profiles:
        raise SystemExit("PlaybackSystemState init parameter anchor not found")
    profiles = profiles.replace(
        init_anchor,
        "        outputRouting: MultiOutputRoutingConfiguration? = nil,\n        speakerDriverProcessing: SpeakerDriverProcessingConfiguration? = nil,\n        speakerIR: SpeakerIRConfiguration = SpeakerIRConfiguration()\n",
        1,
    )

    assign_anchor = "        self.outputRouting = outputRouting\n        self.speakerIR = speakerIR\n"
    if assign_anchor not in profiles:
        raise SystemExit("PlaybackSystemState assignment anchor not found")
    profiles = profiles.replace(
        assign_anchor,
        "        self.outputRouting = outputRouting\n        self.speakerDriverProcessing = speakerDriverProcessing\n        self.speakerIR = speakerIR\n",
        1,
    )

if "func replaceSelectedSystemSpeakerDriverProcessing(" not in profiles:
    routing_method_anchor = "    func replaceSelectedSystemBassManagement(\n"
    transaction = r'''    func replaceSelectedSystemSpeakerDriverProcessing(
        _ configuration: SpeakerDriverProcessingConfiguration
    ) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }
        try configuration.validateStructure()

        let previousEngineConfiguration = engine.speakerDriverProcessingConfiguration
        let previousState = systemProfiles[index].state
        do {
            try engine.replaceSpeakerDriverProcessingConfiguration(configuration)
            systemProfiles[index].state.speakerDriverProcessing = configuration.isNeutral ? nil : configuration
            try persistThrowing()
            lastErrorDescription = nil
        } catch {
            systemProfiles[index].state = previousState
            try? engine.replaceSpeakerDriverProcessingConfiguration(previousEngineConfiguration)
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

'''
    if routing_method_anchor not in profiles:
        raise SystemExit("ProductProfiles transaction insertion anchor not found")
    profiles = profiles.replace(routing_method_anchor, transaction + routing_method_anchor, 1)

capture_anchor = "            outputRouting: engine.multiOutputRoutingConfiguration,\n            speakerIR: engine.speakerIRConfiguration\n"
if "speakerDriverProcessing: engine.speakerDriverProcessingConfiguration.isNeutral" not in profiles:
    if capture_anchor not in profiles:
        raise SystemExit("captureSystemState anchor not found")
    profiles = profiles.replace(
        capture_anchor,
        "            outputRouting: engine.multiOutputRoutingConfiguration,\n            speakerDriverProcessing: engine.speakerDriverProcessingConfiguration.isNeutral\n                ? nil\n                : engine.speakerDriverProcessingConfiguration,\n            speakerIR: engine.speakerIRConfiguration\n",
        1,
    )

apply_anchor = "            try engine.replaceMultiOutputRoutingConfiguration(state.outputRouting)\n            try engine.replacePlaybackControlConfiguration(playback)\n"
if "state.speakerDriverProcessing ?? SpeakerDriverProcessingConfiguration()" not in profiles:
    if apply_anchor not in profiles:
        raise SystemExit("applySystemState anchor not found")
    profiles = profiles.replace(
        apply_anchor,
        "            try engine.replaceMultiOutputRoutingConfiguration(state.outputRouting)\n            try engine.replaceSpeakerDriverProcessingConfiguration(\n                state.speakerDriverProcessing ?? SpeakerDriverProcessingConfiguration()\n            )\n            try engine.replacePlaybackControlConfiguration(playback)\n",
        1,
    )

rollback_anchor = "            try? engine.replaceMultiOutputRoutingConfiguration(previous.outputRouting)\n            try? engine.replacePlaybackControlConfiguration(playback)\n"
if "previous.speakerDriverProcessing ?? SpeakerDriverProcessingConfiguration()" not in profiles:
    if rollback_anchor not in profiles:
        raise SystemExit("applySystemState rollback anchor not found")
    profiles = profiles.replace(
        rollback_anchor,
        "            try? engine.replaceMultiOutputRoutingConfiguration(previous.outputRouting)\n            try? engine.replaceSpeakerDriverProcessingConfiguration(\n                previous.speakerDriverProcessing ?? SpeakerDriverProcessingConfiguration()\n            )\n            try? engine.replacePlaybackControlConfiguration(playback)\n",
        1,
    )
profile_path.write_text(profiles, encoding="utf-8")

# 4) Deterministic model/backward-persistence tests in an existing test target file.
tests_path = root / "NotchSixtyTests" / "NotchSixtyTests.swift"
tests = tests_path.read_text(encoding="utf-8")
marker = "testPR43SpeakerDriverProcessingValidationAndBackwardPersistence"
if marker not in tests:
    insertion = r'''

    func testPR43SpeakerDriverProcessingValidationAndBackwardPersistence() throws {
        var low = SpeakerDriverBusProcessingConfiguration(bus: .leftLow)
        low.eqBands = [EQBand(type: .peaking, frequencyHz: 120, gainDB: -2.5, q: 1.2)]
        low.trimDB = -1.5
        low.delayMilliseconds = 0.37
        low.limiterEnabled = true
        low.limiterThresholdDBFS = -4

        let configuration = SpeakerDriverProcessingConfiguration(buses: [low])
        XCTAssertNoThrow(try configuration.validateStructure())
        XCTAssertEqual(configuration.configuration(for: .leftLow), low)
        XCTAssertTrue(configuration.configuration(for: .rightHigh).isNeutral)

        var duplicate = SpeakerDriverProcessingConfiguration(buses: [low, low])
        XCTAssertThrowsError(try duplicate.validateStructure()) { error in
            XCTAssertEqual(error as? SpeakerDriverProcessingError, .duplicateBus(.leftLow))
        }

        var invalidDelay = low
        invalidDelay.delayMilliseconds = 51
        XCTAssertThrowsError(try invalidDelay.validateStructure()) { error in
            XCTAssertEqual(
                error as? SpeakerDriverProcessingError,
                .invalidDelay(bus: .leftLow, value: 51)
            )
        }

        var system = PlaybackSystemState(speakerDriverProcessing: configuration)
        let encoded = try JSONEncoder().encode(system)
        let roundTrip = try JSONDecoder().decode(PlaybackSystemState.self, from: encoded)
        XCTAssertEqual(roundTrip.speakerDriverProcessing, configuration)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "speakerDriverProcessing")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        system = try JSONDecoder().decode(PlaybackSystemState.self, from: legacyData)
        XCTAssertNil(system.speakerDriverProcessing)
    }
'''
    head, sep, _tail = tests.rpartition("\n}")
    if not sep:
        raise SystemExit("NotchSixtyTests closing brace not found")
    tests_path.write_text(head + insertion + "\n}\n", encoding="utf-8")

# 5) Permanent structural guard.
validator = root / "ci" / "validate_pr43_driver_model.py"
validator.write_text(r'''#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ROUTE = (ROOT / "NotchSixty" / "Audio" / "Routing" / "AudioRouteConfiguration.swift").read_text()
ENGINE = (ROOT / "NotchSixty" / "Audio" / "AudioIOEngine.swift").read_text()
PROFILES = (ROOT / "NotchSixty" / "State" / "ProductProfiles.swift").read_text()
TESTS = (ROOT / "NotchSixtyTests" / "NotchSixtyTests.swift").read_text()


def fail(message: str) -> None:
    print(f"PR43 driver-model validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)

for token in [
    "SpeakerDriverBusProcessingConfiguration",
    "SpeakerDriverProcessingConfiguration",
    "maximumEQBandCount = 8",
    "delayRangeMilliseconds = 0.0 ... 50.0",
    "limiterThresholdRange = -30.0 ... 0.0",
    "mandatory crossover filtering",
]:
    if token not in ROUTE:
        fail(f"missing route/model token: {token}")
for token in [
    "speakerDriverProcessingConfiguration = SpeakerDriverProcessingConfiguration()",
    "replaceSpeakerDriverProcessingConfiguration",
    "SpeakerDriverProcessingError.changesRequireIdle",
]:
    if token not in ENGINE:
        fail(f"missing engine ownership token: {token}")
for token in [
    "var speakerDriverProcessing: SpeakerDriverProcessingConfiguration?",
    "replaceSelectedSystemSpeakerDriverProcessing",
    "state.speakerDriverProcessing ?? SpeakerDriverProcessingConfiguration()",
]:
    if token not in PROFILES:
        fail(f"missing Playback System persistence token: {token}")
if "testPR43SpeakerDriverProcessingValidationAndBackwardPersistence" not in TESTS:
    fail("missing deterministic model/backward-persistence test")
print("PR43 per-driver Playback System model guard: PASS")
''', encoding="utf-8")
validator.chmod(0o755)

print("PR43 B1 per-driver model patch applied")
