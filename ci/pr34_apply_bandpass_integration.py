from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found; refusing a non-deterministic edit")
    return text.replace(old, new, 1)


# ---- C DSP: independently authored Constant-Q peaking mode ----
header_path = Path("NotchSixty/Audio/Realtime/N60Biquad.h")
header = header_path.read_text()
header = replace_once(
    header,
    "    N60BiquadFilterTypeBandPass = 7,\n} N60BiquadFilterType;",
    "    N60BiquadFilterTypeBandPass = 7,\n    N60BiquadFilterTypePeakingConstantQ = 8,\n} N60BiquadFilterType;",
    "Constant-Q enum",
)

constant_q_case = '''    case N60BiquadFilterTypePeakingConstantQ: {
        // W3C Audio EQ Cookbook defines peaking-EQ Q such that A*Q is the
        // classic electrical-engineering Q. The product's Constant-Q control
        // exposes that classic Q directly, so hold it fixed by using
        // Qcookbook = Qclassic / A. This is control-plane coefficient design.
        double A = pow(10.0, gainDB / 40.0);
        double constantAlpha = A * sinOmega / (2.0 * q);
        b0 = 1.0 + constantAlpha * A;
        b1 = -2.0 * cosOmega;
        b2 = 1.0 - constantAlpha * A;
        a0 = 1.0 + constantAlpha / A;
        a1 = -2.0 * cosOmega;
        a2 = 1.0 - constantAlpha / A;
        break;
    }
'''
peaking_case = '''    case N60BiquadFilterTypePeaking: {
        double A = pow(10.0, gainDB / 40.0);
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cosOmega;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cosOmega;
        a2 = 1.0 - alpha / A;
        break;
    }
'''
if constant_q_case not in header:
    if peaking_case not in header:
        raise SystemExit("Expected peaking case was not found; refusing a non-deterministic Constant-Q edit")
    header = header.replace(peaking_case, peaking_case + constant_q_case, 1)
header_path.write_text(header)


# ---- Swift model: per-Peak Constant-Q flag and compiled type ----
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()

engine = replace_once(
    engine,
    "    var q: Double\n    var dynamic: EQBandDynamicConfiguration",
    "    var q: Double\n    var constantQ: Bool\n    var dynamic: EQBandDynamicConfiguration",
    "EQBand Constant-Q storage",
)
engine = replace_once(
    engine,
    "        q: Double = 0.707,\n        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()",
    "        q: Double = 0.707,\n        constantQ: Bool = false,\n        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()",
    "EQBand Constant-Q initializer parameter",
)
engine = replace_once(
    engine,
    "        self.q = q\n        self.dynamic = dynamic",
    "        self.q = q\n        self.constantQ = constantQ\n        self.dynamic = dynamic",
    "EQBand Constant-Q initializer assignment",
)
compiled_type = '''
    var compiledCType: N60BiquadFilterType {
        if type == .peaking && constantQ {
            return N60BiquadFilterTypePeakingConstantQ
        }
        return type.cType
    }
'''
if compiled_type not in engine:
    marker = "        self.dynamic = dynamic\n    }\n}\n\nenum EQConfigurationError"
    replacement = "        self.dynamic = dynamic\n    }\n" + compiled_type + "}\n\nenum EQConfigurationError"
    if marker not in engine:
        raise SystemExit("Expected EQBand compiled-type insertion point was not found")
    engine = engine.replace(marker, replacement, 1)

engine = engine.replace("                    band.type.cType,\n                    band.frequencyHz,", "                    band.compiledCType,\n                    band.frequencyHz,")
engine = engine.replace("            cBand.type = band.type.cType\n", "            cBand.type = band.compiledCType\n")
engine_path.write_text(engine)


# ---- Validation UI: expose only for Peak bands ----
view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()
constant_q_control = '''                Toggle("Constant Q", isOn: binding.constantQ)
                    .toggleStyle(.switch)
                    .disabled(band.type != .peaking)
'''
if constant_q_control not in view:
    q_marker = '''                TextField("Q", value: binding.q, format: .number.precision(.fractionLength(2...3))).frame(width: 65)
                Text("Q").foregroundStyle(.secondary)
'''
    if q_marker not in view:
        raise SystemExit("Expected EQ Q-control insertion point was not found")
    view = view.replace(q_marker, q_marker + constant_q_control, 1)

view = replace_once(
    view,
    '''                if sanitized.type != .peaking {
                    sanitized.dynamic.enabled = false
                }
''',
    '''                if sanitized.type != .peaking {
                    sanitized.constantQ = false
                    sanitized.dynamic.enabled = false
                }
''',
    "non-Peak sanitizer",
)
view_path.write_text(view)


# ---- Swift regressions: model and linear-phase projection ----
tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
constant_q_test = '''    func testConstantQIsTypedPerPeakAndProjectsIntoLinearPhase() throws {
        let ordinary = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 2.0)
        let constant = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 2.0, constantQ: true)
        XCTAssertEqual(ordinary.compiledCType, N60BiquadFilterTypePeaking)
        XCTAssertEqual(constant.compiledCType, N60BiquadFilterTypePeakingConstantQ)

        let configuration = EQConfiguration(phaseMode: .linearPhase, bands: [constant])
        let projected = try configuration.linearPhaseBands(sampleRate: 48_000)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].type, N60BiquadFilterTypePeakingConstantQ)
        XCTAssertEqual(projected[0].frequencyHz, 1_000, accuracy: 0.001)
        XCTAssertEqual(projected[0].q, 2.0, accuracy: 0.000_001)
    }

'''
if constant_q_test not in tests:
    marker = "    func testAllPassMaintainsUnityMagnitudeAcrossSupportedRates() {\n"
    if marker not in tests:
        raise SystemExit("Expected Constant-Q test insertion point was not found")
    tests = tests.replace(marker, constant_q_test + marker, 1)
tests_path.write_text(tests)
