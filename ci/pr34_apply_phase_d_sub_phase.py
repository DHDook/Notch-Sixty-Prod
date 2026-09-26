from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Crossover snapshot owns the sub-path all-pass. Coefficients are designed on
# the control plane; the realtime path only consumes immutable coefficients.
# ---------------------------------------------------------------------------
crossover_path = Path("NotchSixty/Audio/Realtime/N60Crossover.h")
crossover = crossover_path.read_text()
crossover = replace_once(
    crossover,
    "    float subGainLinear;\n    bool subPolarityInverted;\n    uint32_t sectionCount;",
    "    float subGainLinear;\n    bool subPolarityInverted;\n    bool subPhaseAlignmentEnabled;\n    double subPhaseAlignmentFrequencyHz;\n    double subPhaseAlignmentQ;\n    N60BiquadCoefficients subPhaseAlignmentAllPass;\n    uint32_t sectionCount;",
    "sub phase snapshot fields",
)
crossover = replace_once(
    crossover,
    "    snapshot.subGainLinear = 1.0f;\n    snapshot.subPolarityInverted = false;\n    snapshot.sectionCount = 0;",
    "    snapshot.subGainLinear = 1.0f;\n    snapshot.subPolarityInverted = false;\n    snapshot.subPhaseAlignmentEnabled = false;\n    snapshot.subPhaseAlignmentFrequencyHz = 80.0;\n    snapshot.subPhaseAlignmentQ = 0.7;\n    snapshot.subPhaseAlignmentAllPass = N60BiquadCoefficientsMakeIdentity();\n    snapshot.sectionCount = 0;",
    "sub phase bypass defaults",
)
helper_anchor = "\n#ifdef __cplusplus\n}\n#endif\n\n#endif\n"
helper = '''

static inline bool N60CrossoverSnapshotSetSubPhaseAlignment(
    double sampleRate,
    double frequencyHz,
    double q,
    bool enabled,
    N60CrossoverSnapshot * _Nonnull snapshot
) {
    if (snapshot == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz <= 0.0 || frequencyHz >= sampleRate * 0.5
        || !isfinite(q) || q <= 0.0) {
        return false;
    }

    N60BiquadCoefficients coefficients = N60BiquadCoefficientsMakeIdentity();
    if (enabled && !N60BiquadDesign(
            N60BiquadFilterTypeAllPass,
            sampleRate,
            frequencyHz,
            0.0,
            q,
            &coefficients)) {
        return false;
    }

    snapshot->subPhaseAlignmentEnabled = enabled;
    snapshot->subPhaseAlignmentFrequencyHz = frequencyHz;
    snapshot->subPhaseAlignmentQ = q;
    snapshot->subPhaseAlignmentAllPass = coefficients;
    return true;
}
'''
if "N60CrossoverSnapshotSetSubPhaseAlignment" not in crossover:
    if helper_anchor not in crossover:
        raise SystemExit("Expected crossover helper insertion point was not found")
    crossover = crossover.replace(helper_anchor, helper + helper_anchor, 1)
crossover_path.write_text(crossover)


# ---------------------------------------------------------------------------
# Graph API + crossover runtime state.
# ---------------------------------------------------------------------------
header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
header = header_path.read_text()
header = replace_once(
    header,
    "bool N60DSPGraphSnapshotSetCrossover(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double frequencyHz,\n    N60CrossoverTopology topology,\n    N60CrossoverMonitorMode monitorMode,\n    float subGainLinear,\n    bool subPolarityInverted,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetConvolutionProgram(",
    "bool N60DSPGraphSnapshotSetCrossover(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double frequencyHz,\n    N60CrossoverTopology topology,\n    N60CrossoverMonitorMode monitorMode,\n    float subGainLinear,\n    bool subPolarityInverted,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetSubPhaseAlignment(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double frequencyHz,\n    double q,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetConvolutionProgram(",
    "sub phase graph API declaration",
)
header_path.write_text(header)

kernel_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
kernel = kernel_path.read_text()
kernel = replace_once(
    kernel,
    "    N60BiquadState subMono[N60_MAX_CROSSOVER_SECTIONS];\n} N60CrossoverPathRuntime;",
    "    N60BiquadState subMono[N60_MAX_CROSSOVER_SECTIONS];\n    N60BiquadState subPhaseAlignment;\n} N60CrossoverPathRuntime;",
    "sub phase runtime state",
)
kernel = replace_once(
    kernel,
    "        || crossover.monitorMode < N60CrossoverMonitorModeRecombined\n        || crossover.monitorMode > N60CrossoverMonitorModeSubOnly) {",
    "        || crossover.monitorMode < N60CrossoverMonitorModeRecombined\n        || crossover.monitorMode > N60CrossoverMonitorModeSubOnly\n        || !isfinite(crossover.subPhaseAlignmentFrequencyHz)\n        || crossover.subPhaseAlignmentFrequencyHz <= 0.0\n        || crossover.subPhaseAlignmentFrequencyHz >= sampleRate * 0.5\n        || !isfinite(crossover.subPhaseAlignmentQ)\n        || crossover.subPhaseAlignmentQ <= 0.0\n        || !coefficients_are_finite(crossover.subPhaseAlignmentAllPass)) {",
    "sub phase crossover validation",
)
kernel = replace_once(
    kernel,
    "        || lhs.subGainLinear != rhs.subGainLinear\n        || lhs.subPolarityInverted != rhs.subPolarityInverted\n        || lhs.sectionCount != rhs.sectionCount) {",
    "        || lhs.subGainLinear != rhs.subGainLinear\n        || lhs.subPolarityInverted != rhs.subPolarityInverted\n        || lhs.subPhaseAlignmentEnabled != rhs.subPhaseAlignmentEnabled\n        || lhs.subPhaseAlignmentFrequencyHz != rhs.subPhaseAlignmentFrequencyHz\n        || lhs.subPhaseAlignmentQ != rhs.subPhaseAlignmentQ\n        || !coefficients_equal(lhs.subPhaseAlignmentAllPass, rhs.subPhaseAlignmentAllPass)\n        || lhs.sectionCount != rhs.sectionCount) {",
    "sub phase crossover equality",
)
kernel = replace_once(
    kernel,
    "    }\n    subMono *= path->snapshot.subGainLinear;\n    if (path->snapshot.subPolarityInverted) subMono = -subMono;",
    "    }\n    if (path->snapshot.subPhaseAlignmentEnabled) {\n        subMono = N60BiquadProcessSample(\n            path->snapshot.subPhaseAlignmentAllPass,\n            &path->subPhaseAlignment,\n            subMono\n        );\n    }\n    subMono *= path->snapshot.subGainLinear;\n    if (path->snapshot.subPolarityInverted) subMono = -subMono;",
    "sub phase realtime insertion",
)
kernel = replace_once(
    kernel,
    "bool N60DSPGraphSnapshotSetConvolutionProgram(\n    N60DSPGraphSnapshot *snapshot,",
    "bool N60DSPGraphSnapshotSetSubPhaseAlignment(\n    N60DSPGraphSnapshot *snapshot,\n    double frequencyHz,\n    double q,\n    bool enabled\n) {\n    if (snapshot == NULL) return false;\n    return N60CrossoverSnapshotSetSubPhaseAlignment(\n        snapshot->sampleRate, frequencyHz, q, enabled, &snapshot->crossover\n    );\n}\n\nbool N60DSPGraphSnapshotSetConvolutionProgram(\n    N60DSPGraphSnapshot *snapshot,",
    "sub phase graph API definition",
)
kernel_path.write_text(kernel)


# ---------------------------------------------------------------------------
# Product model + graph compilation.
# ---------------------------------------------------------------------------
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
engine = replace_once(
    engine,
    "    static let frequencyRange = 20.0...500.0\n    static let subGainRange = -24.0...12.0\n\n    var enabled = false",
    "    static let frequencyRange = 20.0...500.0\n    static let subGainRange = -24.0...12.0\n    static let subPhaseAlignmentQRange = 0.1...10.0\n\n    var enabled = false",
    "sub phase product range",
)
engine = replace_once(
    engine,
    "    var subGainDB: Double = 0\n    var subPolarityInverted = false\n}",
    "    var subGainDB: Double = 0\n    var subPolarityInverted = false\n    var subPhaseAlignmentEnabled = false\n    var subPhaseAlignmentFrequencyHz: Double = 80\n    var subPhaseAlignmentQ: Double = 0.7\n}",
    "sub phase product state",
)
engine = replace_once(
    engine,
    "    case invalidFrequency(Double)\n    case invalidSubGain(Double)\n    case graphDesignFailed",
    "    case invalidFrequency(Double)\n    case invalidSubGain(Double)\n    case invalidSubPhaseAlignmentFrequency(Double)\n    case invalidSubPhaseAlignmentQ(Double)\n    case graphDesignFailed",
    "sub phase configuration errors",
)
engine = replace_once(
    engine,
    "        case .invalidSubGain(let value):\n            return \"Sub gain \\(value) dB is outside the supported -24...+12 dB range.\"\n        case .graphDesignFailed:",
    "        case .invalidSubGain(let value):\n            return \"Sub gain \\(value) dB is outside the supported -24...+12 dB range.\"\n        case .invalidSubPhaseAlignmentFrequency(let value):\n            return \"Sub phase-alignment frequency \\(value) Hz is outside the supported 20...500 Hz range.\"\n        case .invalidSubPhaseAlignmentQ(let value):\n            return \"Sub phase-alignment Q \\(value) is outside the supported 0.1...10 range.\"\n        case .graphDesignFailed:",
    "sub phase error descriptions",
)
# Both EQ configuration compilers contain the same bass validation. Replacing all
# occurrences intentionally keeps compatibility and live StereoEQ paths aligned.
old_validation = '''        guard bassManagementConfiguration.subGainDB.isFinite,
              BassManagementConfiguration.subGainRange.contains(bassManagementConfiguration.subGainDB) else {
            throw BassManagementConfigurationError.invalidSubGain(bassManagementConfiguration.subGainDB)
        }
'''
new_validation = old_validation + '''        guard bassManagementConfiguration.subPhaseAlignmentFrequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(bassManagementConfiguration.subPhaseAlignmentFrequencyHz) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentFrequency(
                bassManagementConfiguration.subPhaseAlignmentFrequencyHz
            )
        }
        guard bassManagementConfiguration.subPhaseAlignmentQ.isFinite,
              BassManagementConfiguration.subPhaseAlignmentQRange.contains(bassManagementConfiguration.subPhaseAlignmentQ) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(
                bassManagementConfiguration.subPhaseAlignmentQ
            )
        }
'''
if "invalidSubPhaseAlignmentFrequency(\n                bassManagementConfiguration.subPhaseAlignmentFrequencyHz" not in engine:
    if old_validation not in engine:
        raise SystemExit("Expected bass-management validation block was not found")
    engine = engine.replace(old_validation, new_validation)

old_crossover = '''        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        return graph
'''
new_crossover = '''        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        guard N60DSPGraphSnapshotSetSubPhaseAlignment(
            &graph,
            bassManagementConfiguration.subPhaseAlignmentFrequencyHz,
            bassManagementConfiguration.subPhaseAlignmentQ,
            bassManagementConfiguration.subPhaseAlignmentEnabled
        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        return graph
'''
# Two graph compilers may contain this exact tail; align both.
if "N60DSPGraphSnapshotSetSubPhaseAlignment(" not in engine:
    if old_crossover not in engine:
        raise SystemExit("Expected crossover graph tail was not found")
    engine = engine.replace(old_crossover, new_crossover)

# Offline configuration replacement validates before state storage as well.
replace_marker = '''        guard configuration.subGainDB.isFinite,
              BassManagementConfiguration.subGainRange.contains(configuration.subGainDB) else {
            throw BassManagementConfigurationError.invalidSubGain(configuration.subGainDB)
        }
'''
replace_extra = replace_marker + '''        guard configuration.subPhaseAlignmentFrequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(configuration.subPhaseAlignmentFrequencyHz) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentFrequency(
                configuration.subPhaseAlignmentFrequencyHz
            )
        }
        guard configuration.subPhaseAlignmentQ.isFinite,
              BassManagementConfiguration.subPhaseAlignmentQRange.contains(configuration.subPhaseAlignmentQ) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(configuration.subPhaseAlignmentQ)
        }
'''
if "configuration.subPhaseAlignmentQ.isFinite" not in engine:
    if replace_marker not in engine:
        raise SystemExit("Expected replaceBassManagementConfiguration validation block was not found")
    engine = engine.replace(replace_marker, replace_extra, 1)
engine_path.write_text(engine)


# ---------------------------------------------------------------------------
# Validation UI stays inside Bass Management because this rotates only the sub
# leg near crossover; it is not a generic stereo spatial effect.
# ---------------------------------------------------------------------------
view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()
view = replace_once(
    view,
    "    private var subGainBinding: Binding<Double> { crossoverBinding(\\.subGainDB) }\n    private var subPolarityBinding: Binding<Bool> { crossoverBinding(\\.subPolarityInverted) }",
    "    private var subGainBinding: Binding<Double> { crossoverBinding(\\.subGainDB) }\n    private var subPolarityBinding: Binding<Bool> { crossoverBinding(\\.subPolarityInverted) }\n    private var subPhaseAlignmentEnabledBinding: Binding<Bool> { crossoverBinding(\\.subPhaseAlignmentEnabled) }\n    private var subPhaseAlignmentFrequencyBinding: Binding<Double> { crossoverBinding(\\.subPhaseAlignmentFrequencyHz) }\n    private var subPhaseAlignmentQBinding: Binding<Double> { crossoverBinding(\\.subPhaseAlignmentQ) }",
    "sub phase UI bindings",
)
ui_anchor = '''                Toggle("Invert sub polarity", isOn: subPolarityBinding)
                    .toggleStyle(.switch)
            }

            Text("PR #16 exposes logical mains and mono-sub buses through stereo audition modes. It does not yet create an independently routable physical sub output.")
'''
ui_block = '''                Toggle("Invert sub polarity", isOn: subPolarityBinding)
                    .toggleStyle(.switch)
            }

            HStack(spacing: 12) {
                Toggle("Sub phase alignment", isOn: subPhaseAlignmentEnabledBinding).toggleStyle(.switch)
                Text("Center")
                Slider(
                    value: subPhaseAlignmentFrequencyBinding,
                    in: BassManagementConfiguration.frequencyRange,
                    step: 1
                )
                .disabled(!engine.bassManagementConfiguration.subPhaseAlignmentEnabled)
                Text("\(Int(engine.bassManagementConfiguration.subPhaseAlignmentFrequencyHz.rounded())) Hz")
                    .monospacedDigit().frame(width: 72)
                Text("Q")
                Slider(
                    value: subPhaseAlignmentQBinding,
                    in: BassManagementConfiguration.subPhaseAlignmentQRange,
                    step: 0.1
                )
                .frame(width: 160)
                .disabled(!engine.bassManagementConfiguration.subPhaseAlignmentEnabled)
                Text(engine.bassManagementConfiguration.subPhaseAlignmentQ.formatted(.number.precision(.fractionLength(1))))
                    .monospacedDigit().frame(width: 38)
            }
            Text("Sub phase alignment is a magnitude-transparent all-pass on the mono sub leg after low-pass filtering. It rotates phase near the selected center without changing sub gain, polarity, or the mains path.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("PR #16 exposes logical mains and mono-sub buses through stereo audition modes. It does not yet create an independently routable physical sub output.")
'''
view = replace_once(view, ui_anchor, ui_block, "sub phase validation UI")
view_path.write_text(view)


# ---------------------------------------------------------------------------
# XCTest coverage: configuration/default contract, graph publication and invalid
# controls. Numerical magnitude/phase behavior is covered by the independent C
# validator across every supported high-rate family.
# ---------------------------------------------------------------------------
test_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = test_path.read_text()
marker = "    func testCrosstalkCancellationGraphPublishesAuditedDefaults() throws {\n"
test_block = '''    func testSubBassPhaseAlignmentPublishesAuditedDefaults() throws {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.subPhaseAlignmentEnabled = true
        let graph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bass
        )
        XCTAssertTrue(graph.crossover.subPhaseAlignmentEnabled)
        XCTAssertEqual(graph.crossover.subPhaseAlignmentFrequencyHz, 80, accuracy: 0.000_001)
        XCTAssertEqual(graph.crossover.subPhaseAlignmentQ, 0.7, accuracy: 0.000_001)
        XCTAssertTrue(N60BiquadCoefficientsAreFinite(graph.crossover.subPhaseAlignmentAllPass))
    }

    func testSubBassPhaseAlignmentDisabledIsIdentity() throws {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.subPhaseAlignmentEnabled = false
        let graph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 384_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bass
        )
        XCTAssertFalse(graph.crossover.subPhaseAlignmentEnabled)
        XCTAssertEqual(graph.crossover.subPhaseAlignmentAllPass.b0, 1, accuracy: 0.000_001)
        XCTAssertEqual(graph.crossover.subPhaseAlignmentAllPass.b1, 0, accuracy: 0.000_001)
        XCTAssertEqual(graph.crossover.subPhaseAlignmentAllPass.b2, 0, accuracy: 0.000_001)
    }

    func testSubBassPhaseAlignmentRejectsInvalidControls() throws {
        var bass = BassManagementConfiguration()
        bass.subPhaseAlignmentEnabled = true
        bass.subPhaseAlignmentFrequencyHz = 10
        XCTAssertThrowsError(try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bass
        ))
        bass.subPhaseAlignmentFrequencyHz = 80
        bass.subPhaseAlignmentQ = 0
        XCTAssertThrowsError(try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bass
        ))
    }

'''
if "testSubBassPhaseAlignmentPublishesAuditedDefaults" not in tests:
    if marker not in tests:
        raise SystemExit("Expected sub phase XCTest insertion point was not found")
    tests = tests.replace(marker, test_block + marker, 1)
test_path.write_text(tests)

print("PR34 Phase D sub-bass phase alignment integration is present.")
