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

# ---- C DSP: Linkwitz Transform from the public pole/zero transfer contract ----
header = replace_once(
    header,
    "    N60BiquadFilterTypePeakingConstantQ = 8,\n} N60BiquadFilterType;",
    "    N60BiquadFilterTypePeakingConstantQ = 8,\n    N60BiquadFilterTypeLinkwitzTransform = 9,\n} N60BiquadFilterType;",
    "Linkwitz Transform enum",
)

linkwitz_design = '''static inline bool N60BiquadDesignLinkwitzTransform(
    double sampleRate,
    double f0Hz,
    double q0,
    double fpHz,
    double qp,
    N60BiquadCoefficients * _Nonnull coefficients
) {
    if (coefficients == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(f0Hz) || f0Hz <= 0.0 || f0Hz >= sampleRate * 0.5
        || !isfinite(fpHz) || fpHz <= 0.0 || fpHz >= sampleRate * 0.5
        || !isfinite(q0) || q0 <= 0.0
        || !isfinite(qp) || qp <= 0.0) {
        return false;
    }

    // Linkwitz's published transform cancels the original sealed-box pole pair
    // (f0,Q0) with zeros and installs a target pole pair (fp,Qp). Pre-warp both
    // natural frequencies, then apply the bilinear transform. The leading s^2
    // terms are equal, preserving unity gain at high frequency.
    double k = 2.0 * sampleRate;
    double w0 = k * tan(M_PI * f0Hz / sampleRate);
    double wp = k * tan(M_PI * fpHz / sampleRate);
    double k2 = k * k;
    double w02 = w0 * w0;
    double wp2 = wp * wp;
    double numeratorDamping = (w0 / q0) * k;
    double denominatorDamping = (wp / qp) * k;

    N60BiquadCoefficients normalized = N60BiquadNormalize(
        k2 + numeratorDamping + w02,
        2.0 * (w02 - k2),
        k2 - numeratorDamping + w02,
        k2 + denominatorDamping + wp2,
        2.0 * (wp2 - k2),
        k2 - denominatorDamping + wp2
    );
    if (!N60BiquadCoefficientsAreFinite(normalized)) return false;
    *coefficients = normalized;
    return true;
}

'''
if linkwitz_design not in header:
    marker = "static inline bool N60BiquadBandSnapshotMake(\n"
    if marker not in header:
        raise SystemExit("Expected Linkwitz design insertion point was not found")
    header = header.replace(marker, linkwitz_design + marker, 1)
header_path.write_text(header)


# ---- Prepared coefficient support: structural precursor to compiled EQ ----
render_header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
render_header = render_header_path.read_text()
prepared_declarations = '''bool N60DSPGraphSnapshotSetEQPreparedBandForChannels(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t bandIndex,
    uint8_t channelMask,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
);
bool N60DSPGraphSnapshotSetEQPreparedBand(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
);
'''
if prepared_declarations not in render_header:
    marker = '''bool N60DSPGraphSnapshotSetCrossover(
'''
    if marker not in render_header:
        raise SystemExit("Expected prepared-EQ declaration insertion point was not found")
    render_header = render_header.replace(marker, prepared_declarations + marker, 1)
render_header_path.write_text(render_header)

render_c_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
render_c = render_c_path.read_text()
prepared_functions = '''bool N60DSPGraphSnapshotSetEQPreparedBandForChannels(
    N60DSPGraphSnapshot *snapshot,
    uint32_t bandIndex,
    uint8_t channelMask,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
) {
    if (snapshot == NULL || bandIndex >= N60_MAX_EQ_RENDER_SLOTS) return false;
    if (enabled && !channel_mask_is_valid(channelMask)) return false;
    if (enabled && (!isfinite(frequencyHz) || frequencyHz <= 0.0 || frequencyHz >= snapshot->sampleRate * 0.5
        || !isfinite(gainDB) || !isfinite(q) || q <= 0.0 || !coefficients_are_finite(coefficients))) {
        return false;
    }
    N60BiquadBandSnapshot band = {0};
    band.enabled = enabled;
    band.type = type;
    band.frequencyHz = frequencyHz;
    band.gainDB = gainDB;
    band.q = q;
    band.coefficients = enabled ? coefficients : N60BiquadCoefficientsMakeIdentity();
    snapshot->eqBands[bandIndex] = band;
    snapshot->eqBandChannelMasks[bandIndex] = enabled ? channelMask : 0;
    if (snapshot->eqBandCount <= bandIndex) snapshot->eqBandCount = bandIndex + 1;
    return true;
}

bool N60DSPGraphSnapshotSetEQPreparedBand(
    N60DSPGraphSnapshot *snapshot,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
) {
    return N60DSPGraphSnapshotSetEQPreparedBandForChannels(
        snapshot, bandIndex, N60_EQ_CHANNEL_STEREO, type,
        frequencyHz, gainDB, q, coefficients, enabled
    );
}

'''
if prepared_functions not in render_c:
    marker = '''bool N60DSPGraphSnapshotSetEQBandForChannels(
'''
    if marker not in render_c:
        raise SystemExit("Expected prepared-EQ function insertion point was not found")
    render_c = render_c.replace(marker, prepared_functions + marker, 1)
render_c_path.write_text(render_c)


# ---- Linear Phase accepts control-plane prepared biquad magnitude ----
linear_path = Path("NotchSixty/Audio/Realtime/N60LinearPhaseEQ.h")
linear = linear_path.read_text()
linear = replace_once(
    linear,
    '''    double gainDB;
    double q;
} N60LinearPhaseEQBand;''',
    '''    double gainDB;
    double q;
    bool usesPreparedCoefficients;
    N60BiquadCoefficients preparedCoefficients;
} N60LinearPhaseEQBand;''',
    "Linear-Phase prepared coefficient fields",
)
old_design = '''        N60BiquadBandSnapshot snapshot = {0};
        if (!N60BiquadBandSnapshotMake(
                bands[index].type,
                sampleRate,
                bands[index].frequencyHz,
                bands[index].gainDB,
                bands[index].q,
                true,
                &snapshot)) {
            return false;
        }
        designedBands[designedCount++] = snapshot;
'''
new_design = '''        N60BiquadBandSnapshot snapshot = {0};
        if (bands[index].usesPreparedCoefficients) {
            if (!isfinite(bands[index].frequencyHz) || bands[index].frequencyHz <= 0.0
                || bands[index].frequencyHz >= sampleRate * 0.5
                || !isfinite(bands[index].gainDB)
                || !isfinite(bands[index].q) || bands[index].q <= 0.0
                || !N60BiquadCoefficientsAreFinite(bands[index].preparedCoefficients)) {
                return false;
            }
            snapshot.enabled = true;
            snapshot.type = bands[index].type;
            snapshot.frequencyHz = bands[index].frequencyHz;
            snapshot.gainDB = bands[index].gainDB;
            snapshot.q = bands[index].q;
            snapshot.coefficients = bands[index].preparedCoefficients;
        } else if (!N60BiquadBandSnapshotMake(
                bands[index].type,
                sampleRate,
                bands[index].frequencyHz,
                bands[index].gainDB,
                bands[index].q,
                true,
                &snapshot)) {
            return false;
        }
        designedBands[designedCount++] = snapshot;
'''
linear = replace_once(linear, old_design, new_design, "Linear-Phase prepared design branch")
linear_path.write_text(linear)


# ---- Swift model: Band Pass, Constant-Q, and typed Linkwitz parameters ----
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()

# Constant-Q storage is retained idempotently.
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

# Linkwitz filter picker/type metadata.
engine = replace_once(
    engine,
    "    case bandPass\n    case notch",
    "    case bandPass\n    case linkwitzTransform\n    case notch",
    "Linkwitz Swift filter case",
)
engine = replace_once(
    engine,
    '''        case .bandPass: return "Band Pass"
        case .notch: return "Notch"''',
    '''        case .bandPass: return "Band Pass"
        case .linkwitzTransform: return "Linkwitz Transform"
        case .notch: return "Notch"''',
    "Linkwitz display name",
)
engine = replace_once(
    engine,
    '''        case .bandPass: return N60BiquadFilterTypeBandPass
        case .notch: return N60BiquadFilterTypeNotch''',
    '''        case .bandPass: return N60BiquadFilterTypeBandPass
        case .linkwitzTransform: return N60BiquadFilterTypeLinkwitzTransform
        case .notch: return N60BiquadFilterTypeNotch''',
    "Linkwitz C type mapping",
)

engine = replace_once(
    engine,
    "    var constantQ: Bool\n    var dynamic: EQBandDynamicConfiguration",
    "    var constantQ: Bool\n    var linkwitzTargetHz: Double\n    var linkwitzTargetQ: Double\n    var dynamic: EQBandDynamicConfiguration",
    "Linkwitz EQBand storage",
)
engine = replace_once(
    engine,
    "        constantQ: Bool = false,\n        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()",
    "        constantQ: Bool = false,\n        linkwitzTargetHz: Double = 40.0,\n        linkwitzTargetQ: Double = 0.707,\n        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()",
    "Linkwitz EQBand initializer parameters",
)
engine = replace_once(
    engine,
    "        self.constantQ = constantQ\n        self.dynamic = dynamic",
    "        self.constantQ = constantQ\n        self.linkwitzTargetHz = linkwitzTargetHz\n        self.linkwitzTargetQ = linkwitzTargetQ\n        self.dynamic = dynamic",
    "Linkwitz EQBand initializer assignments",
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

linkwitz_helper = '''
    func linkwitzCoefficients(sampleRate: Double) -> N60BiquadCoefficients? {
        guard type == .linkwitzTransform else { return nil }
        var coefficients = N60BiquadCoefficients()
        guard N60BiquadDesignLinkwitzTransform(
            sampleRate,
            frequencyHz,
            q,
            linkwitzTargetHz,
            linkwitzTargetQ,
            &coefficients
        ) else { return nil }
        return coefficients
    }
'''
if linkwitz_helper not in engine:
    marker = "    var compiledCType: N60BiquadFilterType {\n"
    idx = engine.find(marker)
    if idx < 0:
        raise SystemExit("Expected Linkwitz helper insertion point was not found")
    # Insert helper before the closing EQBand brace, after compiledCType block.
    end_marker = "        return type.cType\n    }\n}"
    replacement = "        return type.cType\n    }\n" + linkwitz_helper + "}"
    if end_marker not in engine:
        raise SystemExit("Expected compiledCType closing block was not found")
    engine = engine.replace(end_marker, replacement, 1)

# Linkwitz typed validation.
validation_marker = '''        if band.dynamic.enabled {
            guard band.type == .peaking,'''
validation_replacement = '''        if band.type == .linkwitzTransform {
            guard band.linkwitzTargetHz.isFinite,
                  band.linkwitzTargetHz > 0,
                  band.linkwitzTargetHz < sampleRate * 0.5,
                  band.linkwitzTargetQ.isFinite,
                  band.linkwitzTargetQ > 0 else {
                throw EQConfigurationError.invalidBand(index: index)
            }
        }
        if band.dynamic.enabled {
            guard band.type == .peaking,'''
engine = replace_once(engine, validation_marker, validation_replacement, "Linkwitz model validation")

# Minimum-phase graph publication branches to prepared coefficients for Linkwitz.
old_minimum = '''                guard N60DSPGraphSnapshotSetEQBand(
                    &graph,
                    renderIndex,
                    band.compiledCType,
                    band.frequencyHz,
                    band.gainDB,
                    band.q,
                    true
                ) else {
                    throw EQConfigurationError.invalidBand(index: modelIndex)
                }
                renderIndex += 1
'''
new_minimum = '''                if band.type == .linkwitzTransform {
                    guard let coefficients = band.linkwitzCoefficients(sampleRate: sampleRate),
                          N60DSPGraphSnapshotSetEQPreparedBand(
                            &graph,
                            renderIndex,
                            band.compiledCType,
                            band.frequencyHz,
                            0.0,
                            band.q,
                            coefficients,
                            true
                          ) else {
                        throw EQConfigurationError.invalidBand(index: modelIndex)
                    }
                } else {
                    guard N60DSPGraphSnapshotSetEQBand(
                        &graph,
                        renderIndex,
                        band.compiledCType,
                        band.frequencyHz,
                        band.gainDB,
                        band.q,
                        true
                    ) else {
                        throw EQConfigurationError.invalidBand(index: modelIndex)
                    }
                }
                renderIndex += 1
'''
engine = replace_once(engine, old_minimum, new_minimum, "Linkwitz minimum-phase publication")

# Linear phase uses the same prepared coefficients/magnitude contract.
linear_projection_marker = '''            cBand.enabled = true
            cBand.type = band.compiledCType
            cBand.frequencyHz = band.frequencyHz
            cBand.gainDB = band.gainDB
            cBand.q = band.q
            result.append(cBand)
'''
linear_projection_replacement = '''            cBand.enabled = true
            cBand.type = band.compiledCType
            cBand.frequencyHz = band.frequencyHz
            cBand.gainDB = band.type == .linkwitzTransform ? 0.0 : band.gainDB
            cBand.q = band.q
            if band.type == .linkwitzTransform {
                guard let coefficients = band.linkwitzCoefficients(sampleRate: sampleRate) else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
                cBand.usesPreparedCoefficients = true
                cBand.preparedCoefficients = coefficients
            }
            result.append(cBand)
'''
engine = replace_once(engine, linear_projection_marker, linear_projection_replacement, "Linkwitz Linear-Phase projection")
engine_path.write_text(engine)


# ---- Validation UI: Peak Constant-Q + Linkwitz physical target controls ----
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

linkwitz_controls = '''            if band.type == .linkwitzTransform {
                HStack(spacing: 8) {
                    Text("Linkwitz").frame(width: 82, alignment: .leading).foregroundStyle(.secondary)
                    Text("Resonance f0")
                    Text("\(band.frequencyHz, specifier: "%.1f") Hz").monospacedDigit()
                    Text("Box Q0")
                    Text("\(band.q, specifier: "%.3f")").monospacedDigit()
                    Text("Target fp")
                    TextField("Hz", value: binding.linkwitzTargetHz, format: .number.precision(.fractionLength(0...1))).frame(width: 85)
                    Text("Hz").foregroundStyle(.secondary)
                    Text("Target Qp")
                    TextField("Q", value: binding.linkwitzTargetQ, format: .number.precision(.fractionLength(2...3))).frame(width: 70)
                }
            }
'''
if linkwitz_controls not in view:
    marker = '''            if binding.wrappedValue.dynamic.enabled && dynamicSupported {
'''
    if marker not in view:
        raise SystemExit("Expected Linkwitz UI insertion point was not found")
    view = view.replace(marker, linkwitz_controls + "\n" + marker, 1)

# Disable gain semantics for Linkwitz, which is defined by f0/Q0/fp/Qp.
old_gain_field = '''                TextField("dB", value: binding.gainDB, format: .number.precision(.fractionLength(1))).frame(width: 65)
'''
new_gain_field = '''                TextField("dB", value: binding.gainDB, format: .number.precision(.fractionLength(1)))
                    .frame(width: 65)
                    .disabled(band.type == .linkwitzTransform)
'''
view = replace_once(view, old_gain_field, new_gain_field, "Linkwitz gain-field disabling")

# Non-Peak families cannot retain Constant-Q/Dynamic state.
if '''                    sanitized.constantQ = false
                    sanitized.dynamic.enabled = false
''' not in view:
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


# ---- Swift regressions ----
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

linkwitz_test = '''    func testLinkwitzTransformUsesAllFourPhysicalParametersInMinimumAndLinearPhase() throws {
        let band = EQBand(
            type: .linkwitzTransform,
            frequencyHz: 50,
            gainDB: 0,
            q: 0.7,
            linkwitzTargetHz: 32,
            linkwitzTargetQ: 0.577
        )
        XCTAssertEqual(band.compiledCType, N60BiquadFilterTypeLinkwitzTransform)
        XCTAssertNotNil(band.linkwitzCoefficients(sampleRate: 48_000))

        let minimum = EQConfiguration(phaseMode: .minimumPhase, bands: [band])
        let graph = try minimum.makeGraphSnapshot(sampleRate: 48_000)
        XCTAssertEqual(graph.eqBandCount, 1)
        XCTAssertEqual(graph.eqBands.0.type, N60BiquadFilterTypeLinkwitzTransform)
        XCTAssertTrue(N60BiquadCoefficientsAreFinite(graph.eqBands.0.coefficients))

        let linear = EQConfiguration(phaseMode: .linearPhase, bands: [band])
        let projected = try linear.linearPhaseBands(sampleRate: 48_000)
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].type, N60BiquadFilterTypeLinkwitzTransform)
        XCTAssertTrue(projected[0].usesPreparedCoefficients)
        XCTAssertTrue(N60BiquadCoefficientsAreFinite(projected[0].preparedCoefficients))

        var changedTarget = band
        changedTarget.linkwitzTargetHz = 40
        let first = band.linkwitzCoefficients(sampleRate: 48_000)!
        let second = changedTarget.linkwitzCoefficients(sampleRate: 48_000)!
        XCTAssertNotEqual(first.b0, second.b0)
    }

'''
if linkwitz_test not in tests:
    marker = "    func testAllPassMaintainsUnityMagnitudeAcrossSupportedRates() {\n"
    if marker not in tests:
        raise SystemExit("Expected Linkwitz test insertion point was not found")
    tests = tests.replace(marker, linkwitz_test + marker, 1)
tests_path.write_text(tests)
