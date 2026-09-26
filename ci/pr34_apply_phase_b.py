from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# C coefficient helpers and bounded compiled-section capacity
# ---------------------------------------------------------------------------
biquad_path = Path("NotchSixty/Audio/Realtime/N60Biquad.h")
biquad = biquad_path.read_text()
biquad = replace_once(
    biquad,
    "    N60BiquadFilterTypeLinkwitzTransform = 9,\n} N60BiquadFilterType;",
    "    N60BiquadFilterTypeLinkwitzTransform = 9,\n    N60BiquadFilterTypeTilt = 10,\n} N60BiquadFilterType;",
    "Tilt filter metadata enum",
)

helpers = r'''static inline uint32_t N60BiquadButterworthSectionCount(uint32_t order) {
    if (order < 1u || order > 16u) return 0u;
    return (order + 1u) / 2u;
}

static inline bool N60BiquadDesignFirstOrderLowHighPass(
    N60BiquadFilterType type,
    double sampleRate,
    double frequencyHz,
    N60BiquadCoefficients * _Nonnull coefficients
) {
    if (coefficients == NULL
        || (type != N60BiquadFilterTypeLowPass && type != N60BiquadFilterTypeHighPass)
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz <= 0.0 || frequencyHz >= sampleRate * 0.5) {
        return false;
    }
    double c = tan(M_PI * frequencyHz / sampleRate);
    double a0 = 1.0 + c;
    double b0 = type == N60BiquadFilterTypeLowPass ? c : 1.0;
    double b1 = type == N60BiquadFilterTypeLowPass ? c : -1.0;
    N60BiquadCoefficients normalized = N60BiquadNormalize(
        b0, b1, 0.0, a0, c - 1.0, 0.0
    );
    if (!N60BiquadCoefficientsAreFinite(normalized)) return false;
    *coefficients = normalized;
    return true;
}

static inline bool N60BiquadDesignButterworthSection(
    N60BiquadFilterType type,
    double sampleRate,
    double frequencyHz,
    uint32_t order,
    uint32_t sectionIndex,
    N60BiquadCoefficients * _Nonnull coefficients
) {
    uint32_t sectionCount = N60BiquadButterworthSectionCount(order);
    if (coefficients == NULL || sectionCount == 0u || sectionIndex >= sectionCount
        || (type != N60BiquadFilterTypeLowPass && type != N60BiquadFilterTypeHighPass)) {
        return false;
    }

    bool hasFirstOrder = (order & 1u) != 0u;
    if (hasFirstOrder && sectionIndex == 0u) {
        return N60BiquadDesignFirstOrderLowHighPass(type, sampleRate, frequencyHz, coefficients);
    }

    uint32_t pairIndex = sectionIndex - (hasFirstOrder ? 1u : 0u);
    double angle = ((2.0 * (double)pairIndex) + 1.0) * M_PI / (2.0 * (double)order);
    double q = 1.0 / (2.0 * sin(angle));
    return N60BiquadDesign(type, sampleRate, frequencyHz, 0.0, q, coefficients);
}

static inline bool N60BiquadDesignFirstOrderShelf(
    N60BiquadFilterType type,
    double sampleRate,
    double frequencyHz,
    double gainDB,
    N60BiquadCoefficients * _Nonnull coefficients
) {
    if (coefficients == NULL
        || (type != N60BiquadFilterTypeLowShelf && type != N60BiquadFilterTypeHighShelf)
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz <= 0.0 || frequencyHz >= sampleRate * 0.5
        || !isfinite(gainDB) || gainDB < N60_EQ_MIN_GAIN_DB || gainDB > N60_EQ_MAX_GAIN_DB) {
        return false;
    }
    double c = tan(M_PI * frequencyHz / sampleRate);
    double gain = pow(10.0, gainDB / 20.0);
    double b0;
    double b1;
    if (type == N60BiquadFilterTypeLowShelf) {
        b0 = 1.0 + gain * c;
        b1 = gain * c - 1.0;
    } else {
        b0 = gain + c;
        b1 = c - gain;
    }
    N60BiquadCoefficients normalized = N60BiquadNormalize(
        b0, b1, 0.0, 1.0 + c, c - 1.0, 0.0
    );
    if (!N60BiquadCoefficientsAreFinite(normalized)) return false;
    *coefficients = normalized;
    return true;
}

'''
if helpers not in biquad:
    marker = "static inline bool N60BiquadDesignLinkwitzTransform(\n"
    if marker not in biquad:
        raise SystemExit("Expected compiled-EQ helper insertion point was not found")
    biquad = biquad.replace(marker, helpers + marker, 1)
biquad_path.write_text(biquad)

render_header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
render_header = render_header_path.read_text()
render_header = replace_once(
    render_header,
    "#define N60_MAX_EQ_BANDS 64\n#define N60_MAX_EQ_RENDER_SLOTS (N60_MAX_EQ_BANDS * 2)",
    "#define N60_MAX_EQ_BANDS 64\n#define N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND 8\n#define N60_MAX_EQ_RENDER_SLOTS (N60_MAX_EQ_BANDS * 2 * N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND)",
    "compiled EQ capacity",
)
render_header_path.write_text(render_header)

linear_path = Path("NotchSixty/Audio/Realtime/N60LinearPhaseEQ.h")
linear = linear_path.read_text()
linear = replace_once(
    linear,
    "#define N60_LINEAR_PHASE_MAX_BANDS 64u",
    "#define N60_LINEAR_PHASE_MAX_BANDS (N60_MAX_EQ_BANDS * N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND)",
    "Linear-Phase compiled section capacity",
)
linear_path.write_text(linear)


# ---------------------------------------------------------------------------
# Swift logical-band model and clean-room compilation
# ---------------------------------------------------------------------------
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
engine = replace_once(engine, "    case linkwitzTransform\n    case notch", "    case linkwitzTransform\n    case tilt\n    case notch", "Tilt Swift filter case")
engine = replace_once(engine, '        case .linkwitzTransform: return "Linkwitz Transform"\n        case .notch: return "Notch"', '        case .linkwitzTransform: return "Linkwitz Transform"\n        case .tilt: return "Tilt"\n        case .notch: return "Notch"', "Tilt display name")
engine = replace_once(engine, "        case .linkwitzTransform: return N60BiquadFilterTypeLinkwitzTransform\n        case .notch: return N60BiquadFilterTypeNotch", "        case .linkwitzTransform: return N60BiquadFilterTypeLinkwitzTransform\n        case .tilt: return N60BiquadFilterTypeTilt\n        case .notch: return N60BiquadFilterTypeNotch", "Tilt C metadata mapping")

supports_slope = '''
    var supportsSlope: Bool {
        switch self {
        case .lowShelf, .highShelf, .lowPass, .highPass: return true
        default: return false
        }
    }
'''
if supports_slope not in engine:
    marker = "    var cType: N60BiquadFilterType {\n"
    if marker not in engine:
        raise SystemExit("Expected supportsSlope insertion point was not found")
    engine = engine.replace(marker, supports_slope + "\n" + marker, 1)

slope_enum = '''enum EQFilterSlope: Int, CaseIterable, Identifiable, Sendable {
    case db6 = 6
    case db12 = 12
    case db18 = 18
    case db24 = 24
    case db36 = 36
    case db48 = 48
    case db60 = 60
    case db72 = 72
    case db84 = 84
    case db96 = 96

    var id: Int { rawValue }
    var displayName: String { "\(rawValue) dB/oct" }
    var order: Int { rawValue / 6 }
}

'''
if slope_enum not in engine:
    marker = "enum EQPhaseMode: String, CaseIterable, Identifiable, Sendable {\n"
    if marker not in engine:
        raise SystemExit("Expected EQFilterSlope insertion point was not found")
    engine = engine.replace(marker, slope_enum + marker, 1)

engine = replace_once(engine, "    var q: Double\n    var constantQ: Bool", "    var q: Double\n    var slope: EQFilterSlope\n    var constantQ: Bool", "EQBand slope storage")
engine = replace_once(engine, "        q: Double = 0.707,\n        constantQ: Bool = false,", "        q: Double = 0.707,\n        slope: EQFilterSlope = .db12,\n        constantQ: Bool = false,", "EQBand slope initializer parameter")
engine = replace_once(engine, "        self.q = q\n        self.constantQ = constantQ", "        self.q = q\n        self.slope = slope\n        self.constantQ = constantQ", "EQBand slope initializer assignment")

compiled_method = r'''
    func compiledSections(sampleRate: Double) throws -> [N60BiquadBandSnapshot] {
        func snapshot(
            type: N60BiquadFilterType,
            gainDB: Double,
            q: Double,
            coefficients: N60BiquadCoefficients
        ) -> N60BiquadBandSnapshot {
            var result = N60BiquadBandSnapshot()
            result.enabled = true
            result.type = type
            result.frequencyHz = frequencyHz
            result.gainDB = gainDB
            result.q = q
            result.coefficients = coefficients
            return result
        }

        if type == .linkwitzTransform {
            guard let coefficients = linkwitzCoefficients(sampleRate: sampleRate) else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            return [snapshot(type: compiledCType, gainDB: 0, q: q, coefficients: coefficients)]
        }

        if type == .tilt {
            // Commercial convention: gainDB is the total low-to-high differential.
            // Positive tilt raises highs and lowers lows symmetrically by half.
            var low = N60BiquadCoefficients()
            var high = N60BiquadCoefficients()
            let half = gainDB * 0.5
            guard N60BiquadDesign(N60BiquadFilterTypeLowShelf, sampleRate, frequencyHz, -half, 0.707, &low),
                  N60BiquadDesign(N60BiquadFilterTypeHighShelf, sampleRate, frequencyHz, half, 0.707, &high) else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            return [
                snapshot(type: N60BiquadFilterTypeLowShelf, gainDB: -half, q: 0.707, coefficients: low),
                snapshot(type: N60BiquadFilterTypeHighShelf, gainDB: half, q: 0.707, coefficients: high),
            ]
        }

        if type == .lowPass || type == .highPass {
            let order = UInt32(slope.order)
            let count = N60BiquadButterworthSectionCount(order)
            guard count > 0, count <= UInt32(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND) else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            return try (0..<count).map { sectionIndex in
                var coefficients = N60BiquadCoefficients()
                guard N60BiquadDesignButterworthSection(
                    type.cType, sampleRate, frequencyHz, order, sectionIndex, &coefficients
                ) else { throw EQConfigurationError.invalidBand(index: Int(sectionIndex)) }
                return snapshot(type: type.cType, gainDB: 0, q: q, coefficients: coefficients)
            }
        }

        if type == .lowShelf || type == .highShelf {
            let order = slope.order
            let pairCount = order / 2
            let hasFirst = order.isMultiple(of: 2) == false
            var result: [N60BiquadBandSnapshot] = []
            result.reserveCapacity((order + 1) / 2)
            if hasFirst {
                var coefficients = N60BiquadCoefficients()
                let sectionGain = gainDB / Double(order)
                guard N60BiquadDesignFirstOrderShelf(
                    type.cType, sampleRate, frequencyHz, sectionGain, &coefficients
                ) else { throw EQConfigurationError.invalidBand(index: 0) }
                result.append(snapshot(type: type.cType, gainDB: sectionGain, q: q, coefficients: coefficients))
            }
            if pairCount > 0 {
                let sectionGain = gainDB * 2.0 / Double(order)
                for pair in 0..<pairCount {
                    var coefficients = N60BiquadCoefficients()
                    guard N60BiquadDesign(type.cType, sampleRate, frequencyHz, sectionGain, q, &coefficients) else {
                        throw EQConfigurationError.invalidBand(index: pair)
                    }
                    result.append(snapshot(type: type.cType, gainDB: sectionGain, q: q, coefficients: coefficients))
                }
            }
            guard result.count <= Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND) else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            return result
        }

        var coefficients = N60BiquadCoefficients()
        guard N60BiquadDesign(compiledCType, sampleRate, frequencyHz, gainDB, q, &coefficients) else {
            throw EQConfigurationError.invalidBand(index: 0)
        }
        return [snapshot(type: compiledCType, gainDB: gainDB, q: q, coefficients: coefficients)]
    }
'''
if compiled_method not in engine:
    marker = "    func linkwitzCoefficients(sampleRate: Double) -> N60BiquadCoefficients? {\n"
    idx = engine.find(marker)
    if idx < 0:
        raise SystemExit("Expected compiledSections insertion anchor was not found")
    # append after linkwitzCoefficients function by matching its known closing block
    closing = '''        ) else { return nil }
        return coefficients
    }
}'''
    replacement = '''        ) else { return nil }
        return coefficients
    }
''' + compiled_method + "}"
    if closing not in engine:
        raise SystemExit("Expected EQBand closing block was not found")
    engine = engine.replace(closing, replacement, 1)

# Wrapper minimum-phase compiler: one logical band -> bounded compiled sections.
old_wrapper = '''                guard N60DSPGraphSnapshotSetEQBand(
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
# Phase A Linkwitz wrapper may have a branch. Replace the whole current branch if present.
old_wrapper_phase_a = '''                if band.type == .linkwitzTransform {
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
new_wrapper = '''                for section in try band.compiledSections(sampleRate: sampleRate) {
                    guard renderIndex < UInt32(N60_MAX_EQ_RENDER_SLOTS),
                          N60DSPGraphSnapshotSetEQPreparedBand(
                            &graph, renderIndex, section.type, section.frequencyHz,
                            section.gainDB, section.q, section.coefficients, true
                          ) else {
                        throw EQConfigurationError.invalidBand(index: modelIndex)
                    }
                    renderIndex += 1
                }
'''
if new_wrapper not in engine:
    if old_wrapper_phase_a in engine:
        engine = engine.replace(old_wrapper_phase_a, new_wrapper, 1)
    elif old_wrapper in engine:
        engine = engine.replace(old_wrapper, new_wrapper, 1)
    else:
        raise SystemExit("Expected wrapper compiled-EQ publication block was not found")

# Wrapper Linear Phase: flatten each logical band to prepared compiled sections.
old_linear_block = '''            var cBand = N60LinearPhaseEQBand()
            cBand.enabled = true
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
new_linear_block = '''            for section in try band.compiledSections(sampleRate: sampleRate) {
                var cBand = N60LinearPhaseEQBand()
                cBand.enabled = true
                cBand.type = section.type
                cBand.frequencyHz = section.frequencyHz
                cBand.gainDB = section.gainDB
                cBand.q = section.q
                cBand.usesPreparedCoefficients = true
                cBand.preparedCoefficients = section.coefficients
                result.append(cBand)
            }
'''
engine = replace_once(engine, old_linear_block, new_linear_block, "wrapper Linear-Phase compiled projection")
engine_path.write_text(engine)


# ---------------------------------------------------------------------------
# Live stereo compiler
# ---------------------------------------------------------------------------
stereo_path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
stereo = stereo_path.read_text()
old_publish = '''    private func publishMinimumPhaseBand(
        _ band: EQBand,
        into graph: inout N60DSPGraphSnapshot,
        renderIndex: UInt32,
        channelMask: UInt8? = nil
    ) throws {
        let ok: Bool
        if band.type == .linkwitzTransform {
            guard let coefficients = band.linkwitzCoefficients(sampleRate: graph.sampleRate) else {
                throw EQConfigurationError.invalidBand(index: Int(renderIndex))
            }
            if let channelMask {
                ok = N60DSPGraphSnapshotSetEQPreparedBandForChannels(
                    &graph, renderIndex, channelMask, band.compiledCType,
                    band.frequencyHz, 0.0, band.q, coefficients, true
                )
            } else {
                ok = N60DSPGraphSnapshotSetEQPreparedBand(
                    &graph, renderIndex, band.compiledCType,
                    band.frequencyHz, 0.0, band.q, coefficients, true
                )
            }
        } else if let channelMask {
            ok = N60DSPGraphSnapshotSetEQBandForChannels(
                &graph, renderIndex, channelMask, band.compiledCType,
                band.frequencyHz, band.gainDB, band.q, true
            )
        } else {
            ok = N60DSPGraphSnapshotSetEQBand(
                &graph, renderIndex, band.compiledCType,
                band.frequencyHz, band.gainDB, band.q, true
            )
        }
        guard ok else { throw EQConfigurationError.invalidBand(index: Int(renderIndex)) }
    }
'''
new_publish = '''    private func publishMinimumPhaseBand(
        _ band: EQBand,
        into graph: inout N60DSPGraphSnapshot,
        renderIndex: inout UInt32,
        channelMask: UInt8? = nil
    ) throws {
        for section in try band.compiledSections(sampleRate: graph.sampleRate) {
            guard renderIndex < UInt32(N60_MAX_EQ_RENDER_SLOTS) else {
                throw EQConfigurationError.invalidBand(index: Int(renderIndex))
            }
            let ok: Bool
            if let channelMask {
                ok = N60DSPGraphSnapshotSetEQPreparedBandForChannels(
                    &graph, renderIndex, channelMask, section.type,
                    section.frequencyHz, section.gainDB, section.q,
                    section.coefficients, true
                )
            } else {
                ok = N60DSPGraphSnapshotSetEQPreparedBand(
                    &graph, renderIndex, section.type,
                    section.frequencyHz, section.gainDB, section.q,
                    section.coefficients, true
                )
            }
            guard ok else { throw EQConfigurationError.invalidBand(index: Int(renderIndex)) }
            renderIndex += 1
        }
    }
'''
stereo = replace_once(stereo, old_publish, new_publish, "live compiled-EQ publisher")
stereo = stereo.replace("try publishMinimumPhaseBand(band, into: &graph, renderIndex: renderIndex)\n                    renderIndex += 1", "try publishMinimumPhaseBand(band, into: &graph, renderIndex: &renderIndex)")
stereo = stereo.replace("band, into: &graph, renderIndex: renderIndex,\n                        channelMask:", "band, into: &graph, renderIndex: &renderIndex,\n                        channelMask:")
stereo = stereo.replace("                    renderIndex += 1\n                }\n                for band in try validatedEnabledBands(rightBands", "                }\n                for band in try validatedEnabledBands(rightBands", 1)
# Remove the right-lane legacy increment as well, if still present.
stereo = stereo.replace("                    renderIndex += 1\n                }\n            }\n        }", "                }\n            }\n        }", 1)

old_live_linear = '''        return try bands.enumerated().map { index, band in
            var cBand = N60LinearPhaseEQBand()
            cBand.enabled = true
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
            return cBand
        }
'''
new_live_linear = '''        var result: [N60LinearPhaseEQBand] = []
        result.reserveCapacity(bands.count * 2)
        for (index, band) in bands.enumerated() {
            do {
                for section in try band.compiledSections(sampleRate: sampleRate) {
                    var cBand = N60LinearPhaseEQBand()
                    cBand.enabled = true
                    cBand.type = section.type
                    cBand.frequencyHz = section.frequencyHz
                    cBand.gainDB = section.gainDB
                    cBand.q = section.q
                    cBand.usesPreparedCoefficients = true
                    cBand.preparedCoefficients = section.coefficients
                    result.append(cBand)
                }
            } catch {
                throw EQConfigurationError.invalidBand(index: index)
            }
        }
        return result
'''
stereo = replace_once(stereo, old_live_linear, new_live_linear, "live Linear-Phase compiled projection")
stereo_path.write_text(stereo)


# ---------------------------------------------------------------------------
# Validation UI: slope picker and explicit Tilt semantics
# ---------------------------------------------------------------------------
view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()
# Tilt has no Q control; slope families expose a dedicated row so the main row stays usable.
view = replace_once(
    view,
    '''                TextField("Q", value: binding.q, format: .number.precision(.fractionLength(2...3))).frame(width: 65)
                Text("Q").foregroundStyle(.secondary)
''',
    '''                TextField("Q", value: binding.q, format: .number.precision(.fractionLength(2...3)))
                    .frame(width: 65)
                    .disabled(band.type == .tilt)
                Text("Q").foregroundStyle(.secondary)
''',
    "Tilt Q-control disabling",
)
slope_ui = '''            if band.type.supportsSlope {
                HStack(spacing: 8) {
                    Text("Slope").frame(width: 82, alignment: .leading).foregroundStyle(.secondary)
                    Picker("Slope", selection: binding.slope) {
                        ForEach(EQFilterSlope.allCases) { slope in
                            Text(slope.displayName).tag(slope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            if band.type == .tilt {
                Text("Tilt amount is the total low-to-high differential around the pivot: positive brightens highs and attenuates lows symmetrically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
            }
'''
if slope_ui not in view:
    marker = '''            if band.type == .linkwitzTransform {
'''
    if marker not in view:
        raise SystemExit("Expected slope/Tilt UI insertion point was not found")
    view = view.replace(marker, slope_ui + "\n" + marker, 1)
view_path.write_text(view)


# ---------------------------------------------------------------------------
# Regression coverage for the product/user-band vs compiled-section contract
# ---------------------------------------------------------------------------
tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
tests_to_add = r'''    func testCompiledEQKeeps64UserBandLimitIndependentOfSectionCount() throws {
        XCTAssertEqual(Int(N60_MAX_EQ_BANDS), 64)
        XCTAssertEqual(Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND), 8)
        XCTAssertGreaterThanOrEqual(Int(N60_MAX_EQ_RENDER_SLOTS), 1_024)

        let steep = EQBand(type: .lowPass, frequencyHz: 8_000, gainDB: 0, q: 0.707, slope: .db96)
        XCTAssertEqual(try steep.compiledSections(sampleRate: 96_000).count, 8)

        let linkedBands = (0..<64).map { index in
            EQBand(type: .lowPass, frequencyHz: 4_000 + Double(index) * 20, gainDB: 0, q: 0.707, slope: .db96)
        }
        let linked = StereoEQConfiguration(channelMode: .linked, phaseMode: .minimumPhase, linkedBands: linkedBands)
        let linkedGraph = try linked.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertEqual(linkedGraph.eqBandCount, 512)

        let independent = StereoEQConfiguration(
            channelMode: .independent,
            editChannel: .left,
            phaseMode: .minimumPhase,
            linkedBands: [],
            leftBands: linkedBands,
            rightBands: linkedBands,
            independentSeeded: true
        )
        let independentGraph = try independent.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertEqual(independentGraph.eqBandCount, 1_024)
    }

    func testSlopeSectionCountsAndTiltCompilation() throws {
        let expectations: [(EQFilterSlope, Int)] = [
            (.db6, 1), (.db12, 1), (.db18, 2), (.db24, 2),
            (.db36, 3), (.db48, 4), (.db60, 5), (.db72, 6),
            (.db84, 7), (.db96, 8),
        ]
        for (slope, count) in expectations {
            let lowPass = EQBand(type: .lowPass, frequencyHz: 2_000, q: 0.707, slope: slope)
            XCTAssertEqual(try lowPass.compiledSections(sampleRate: 48_000).count, count)
        }

        let shelf = EQBand(type: .lowShelf, frequencyHz: 1_000, gainDB: 6, q: 0.8, slope: .db12)
        let shelfSections = try shelf.compiledSections(sampleRate: 48_000)
        XCTAssertEqual(shelfSections.count, 1)
        var legacyCoefficients = N60BiquadCoefficients()
        XCTAssertTrue(N60BiquadDesign(N60BiquadFilterTypeLowShelf, 48_000, 1_000, 6, 0.8, &legacyCoefficients))
        XCTAssertEqual(shelfSections[0].coefficients.b0, legacyCoefficients.b0, accuracy: 1e-7)
        XCTAssertEqual(shelfSections[0].coefficients.a1, legacyCoefficients.a1, accuracy: 1e-7)

        let tilt = EQBand(type: .tilt, frequencyHz: 1_000, gainDB: 8, q: 4.0)
        let tiltSections = try tilt.compiledSections(sampleRate: 48_000)
        XCTAssertEqual(tiltSections.count, 2)
        XCTAssertEqual(tiltSections[0].type, N60BiquadFilterTypeLowShelf)
        XCTAssertEqual(tiltSections[0].gainDB, -4, accuracy: 1e-12)
        XCTAssertEqual(tiltSections[1].type, N60BiquadFilterTypeHighShelf)
        XCTAssertEqual(tiltSections[1].gainDB, 4, accuracy: 1e-12)
    }

    func testLinearPhaseProjectsCompiledHighOrderSections() throws {
        let band = EQBand(type: .highPass, frequencyHz: 80, q: 0.707, slope: .db96)
        let configuration = StereoEQConfiguration(
            channelMode: .linked,
            phaseMode: .linearPhase,
            linkedBands: [band]
        )
        let projected = try configuration.linearPhaseBands(for: .linked, sampleRate: 96_000)
        XCTAssertEqual(projected.count, 8)
        XCTAssertTrue(projected.allSatisfy(\.usesPreparedCoefficients))
    }

'''
if "testCompiledEQKeeps64UserBandLimitIndependentOfSectionCount" not in tests:
    marker = "    func testAllPassMaintainsUnityMagnitudeAcrossSupportedRates() {\n"
    if marker not in tests:
        raise SystemExit("Expected Phase B test insertion point was not found")
    tests = tests.replace(marker, tests_to_add + marker, 1)
tests_path.write_text(tests)

print("PR34 Phase B compiled EQ / slope / Tilt integration applied.")
