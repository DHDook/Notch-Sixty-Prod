from pathlib import Path

engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
old_enum = '''enum EQFilterType: String, CaseIterable, Identifiable, Sendable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch
    case allPass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .notch: return "Notch"
        case .allPass: return "All-Pass"
        }
    }

    var cType: N60BiquadFilterType {
        switch self {
        case .peaking: return N60BiquadFilterTypePeaking
        case .lowShelf: return N60BiquadFilterTypeLowShelf
        case .highShelf: return N60BiquadFilterTypeHighShelf
        case .lowPass: return N60BiquadFilterTypeLowPass
        case .highPass: return N60BiquadFilterTypeHighPass
        case .notch: return N60BiquadFilterTypeNotch
        case .allPass: return N60BiquadFilterTypeAllPass
        }
    }
}
'''
new_enum = '''enum EQFilterType: String, CaseIterable, Identifiable, Sendable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case bandPass
    case notch
    case allPass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .bandPass: return "Band Pass"
        case .notch: return "Notch"
        case .allPass: return "All-Pass"
        }
    }

    var cType: N60BiquadFilterType {
        switch self {
        case .peaking: return N60BiquadFilterTypePeaking
        case .lowShelf: return N60BiquadFilterTypeLowShelf
        case .highShelf: return N60BiquadFilterTypeHighShelf
        case .lowPass: return N60BiquadFilterTypeLowPass
        case .highPass: return N60BiquadFilterTypeHighPass
        case .bandPass: return N60BiquadFilterTypeBandPass
        case .notch: return N60BiquadFilterTypeNotch
        case .allPass: return N60BiquadFilterTypeAllPass
        }
    }
}
'''
if old_enum not in engine:
    raise SystemExit("Expected EQFilterType block was not found; refusing a non-deterministic edit")
engine_path.write_text(engine.replace(old_enum, new_enum, 1))

tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
marker = '''    func testAllPassMaintainsUnityMagnitudeAcrossSupportedRates() {
'''
new_test = '''    func testBandPassIsExposedBySwiftEQModelAndLinearPhaseProjection() throws {
        XCTAssertTrue(EQFilterType.allCases.contains(.bandPass))
        XCTAssertEqual(EQFilterType.bandPass.displayName, "Band Pass")
        XCTAssertEqual(EQFilterType.bandPass.cType, N60BiquadFilterTypeBandPass)

        let configuration = EQConfiguration(
            phaseMode: .linearPhase,
            bands: [EQBand(type: .bandPass, frequencyHz: 1_000, gainDB: 12, q: 0.707)]
        )
        let projected = try configuration.linearPhaseBands(sampleRate: 48_000)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].type, N60BiquadFilterTypeBandPass)
        XCTAssertEqual(projected[0].frequencyHz, 1_000, accuracy: 0.001)
        XCTAssertEqual(projected[0].q, 0.707, accuracy: 0.000_001)
    }

'''
if marker not in tests:
    raise SystemExit("Expected EQ test insertion point was not found; refusing a non-deterministic edit")
if "testBandPassIsExposedBySwiftEQModelAndLinearPhaseProjection" in tests:
    raise SystemExit("Band Pass Swift regression already exists; refusing duplicate insertion")
tests_path.write_text(tests.replace(marker, new_test + marker, 1))
