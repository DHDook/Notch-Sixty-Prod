from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Realtime graph + smoothed render stage.
# ---------------------------------------------------------------------------
header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
header = header_path.read_text()
header = replace_once(
    header,
    '#include "N60MixedPhase.h"\n#include "N60Protection.h"',
    '#include "N60MixedPhase.h"\n#include "N60Spatial.h"\n#include "N60Protection.h"',
    "spatial header include",
)
header = replace_once(
    header,
    "    float balanceGainLeftLinear;\n    float balanceGainRightLinear;\n    bool bypassed;",
    "    float balanceGainLeftLinear;\n    float balanceGainRightLinear;\n    N60SymmetryBalanceSnapshot symmetryBalance;\n    bool bypassed;",
    "Symmetry Balance graph state",
)
header = replace_once(
    header,
    "void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot * _Nonnull snapshot);\nbool N60DSPGraphSnapshotSetInterChannelDelay(",
    "void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot * _Nonnull snapshot);\nbool N60DSPGraphSnapshotSetSymmetryBalance(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double position,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetInterChannelDelay(",
    "Symmetry Balance graph setter declaration",
)
header_path.write_text(header)

kernel_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
kernel = kernel_path.read_text()
kernel = replace_once(
    kernel,
    "    N60SmoothedGain balanceGainLeft;\n    N60SmoothedGain balanceGainRight;\n    N60InterChannelDelayRuntime interChannelDelayRuntime;",
    "    N60SmoothedGain balanceGainLeft;\n    N60SmoothedGain balanceGainRight;\n    N60SmoothedGain symmetryBalanceGainLeft;\n    N60SmoothedGain symmetryBalanceGainRight;\n    N60InterChannelDelayRuntime interChannelDelayRuntime;",
    "Symmetry Balance runtime gains",
)
kernel = replace_once(
    kernel,
    "        || !isfinite(snapshot.balanceGainRightLinear)\n        || snapshot.balanceGainRightLinear < 0.0f\n        || snapshot.balanceGainRightLinear > 1.0f\n        || snapshot.auditionMode < N60AuditionModeProcessed",
    "        || !isfinite(snapshot.balanceGainRightLinear)\n        || snapshot.balanceGainRightLinear < 0.0f\n        || snapshot.balanceGainRightLinear > 1.0f\n        || !N60SymmetryBalanceSnapshotIsValid(snapshot.symmetryBalance)\n        || snapshot.auditionMode < N60AuditionModeProcessed",
    "Symmetry Balance snapshot validation",
)
kernel = replace_once(
    kernel,
    "        reset_smoothed_gain(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear);\n        reset_smoothed_gain(&kernel->balanceGainRight, snapshot->balanceGainRightLinear);\n        N60InterChannelDelayRuntimeReset",
    "        reset_smoothed_gain(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear);\n        reset_smoothed_gain(&kernel->balanceGainRight, snapshot->balanceGainRightLinear);\n        reset_smoothed_gain(&kernel->symmetryBalanceGainLeft, snapshot->symmetryBalance.leftGainLinear);\n        reset_smoothed_gain(&kernel->symmetryBalanceGainRight, snapshot->symmetryBalance.rightGainLinear);\n        N60InterChannelDelayRuntimeReset",
    "Symmetry Balance initial runtime preparation",
)
kernel = replace_once(
    kernel,
    "        schedule_gain_transition(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear, gainFrames);\n        schedule_gain_transition(&kernel->balanceGainRight, snapshot->balanceGainRightLinear, gainFrames);\n        N60InterChannelDelayRuntimeSchedule",
    "        schedule_gain_transition(&kernel->balanceGainLeft, snapshot->balanceGainLeftLinear, gainFrames);\n        schedule_gain_transition(&kernel->balanceGainRight, snapshot->balanceGainRightLinear, gainFrames);\n        schedule_gain_transition(&kernel->symmetryBalanceGainLeft, snapshot->symmetryBalance.leftGainLinear, gainFrames);\n        schedule_gain_transition(&kernel->symmetryBalanceGainRight, snapshot->symmetryBalance.rightGainLinear, gainFrames);\n        N60InterChannelDelayRuntimeSchedule",
    "Symmetry Balance runtime transition",
)
kernel = replace_once(
    kernel,
    "    snapshot.balanceGainLeftLinear = 1.0f;\n    snapshot.balanceGainRightLinear = 1.0f;\n    snapshot.bypassed = false;",
    "    snapshot.balanceGainLeftLinear = 1.0f;\n    snapshot.balanceGainRightLinear = 1.0f;\n    snapshot.symmetryBalance.enabled = false;\n    snapshot.symmetryBalance.position = 0.0;\n    snapshot.symmetryBalance.leftGainLinear = 1.0f;\n    snapshot.symmetryBalance.rightGainLinear = 1.0f;\n    snapshot.bypassed = false;",
    "Symmetry Balance unity state",
)
kernel = replace_once(
    kernel,
    "bool N60DSPGraphSnapshotSetInterChannelDelay(\n    N60DSPGraphSnapshot *snapshot,",
    "bool N60DSPGraphSnapshotSetSymmetryBalance(\n    N60DSPGraphSnapshot *snapshot,\n    double position,\n    bool enabled\n) {\n    if (snapshot == NULL) return false;\n    N60SymmetryBalanceSnapshot symmetry = {0};\n    if (!N60SymmetryBalanceDesign(position, enabled, &symmetry)) return false;\n    snapshot->symmetryBalance = symmetry;\n    return true;\n}\n\nbool N60DSPGraphSnapshotSetInterChannelDelay(\n    N60DSPGraphSnapshot *snapshot,",
    "Symmetry Balance graph setter",
)
kernel = replace_once(
    kernel,
    "        N60DynamicsProcessCoreStereoFrameWithMasterGain(&kernel->dynamicsRuntime, context->snapshot.dynamics, context->snapshot.masterGainLinear, &left, &right);\n\n        left *= next_gain_value(&kernel->balanceGainLeft);",
    "        N60DynamicsProcessCoreStereoFrameWithMasterGain(&kernel->dynamicsRuntime, context->snapshot.dynamics, context->snapshot.masterGainLinear, &left, &right);\n\n        // Listening-position symmetry compensation is intentionally separate\n        // from ordinary attenuation-style Balance. It feeds the speaker-spatial\n        // chain and is gain-smoothed so live position changes remain click-free.\n        left *= next_gain_value(&kernel->symmetryBalanceGainLeft);\n        right *= next_gain_value(&kernel->symmetryBalanceGainRight);\n\n        left *= next_gain_value(&kernel->balanceGainLeft);",
    "Symmetry Balance render stage",
)
kernel_path.write_text(kernel)


# ---------------------------------------------------------------------------
# Product state + graph publication.
# ---------------------------------------------------------------------------
stereo_path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
stereo = stereo_path.read_text()
stereo = replace_once(
    stereo,
    "struct PlaybackControlConfiguration: Equatable, Sendable {\n    static let balanceRange = -1.0...1.0\n    static let interChannelDelayRange = -20.0...20.0\n\n    var balance: Double\n    var interChannelDelayMs: Double",
    "struct PlaybackControlConfiguration: Equatable, Sendable {\n    static let balanceRange = -1.0...1.0\n    static let symmetryBalanceRange = -1.0...1.0\n    static let interChannelDelayRange = -20.0...20.0\n\n    var balance: Double\n    var symmetryBalanceEnabled: Bool\n    var symmetryBalancePosition: Double\n    var interChannelDelayMs: Double",
    "Symmetry Balance product state",
)
stereo = replace_once(
    stereo,
    "    init(\n        balance: Double = 0,\n        interChannelDelayMs: Double = 0,",
    "    init(\n        balance: Double = 0,\n        symmetryBalanceEnabled: Bool = false,\n        symmetryBalancePosition: Double = 0,\n        interChannelDelayMs: Double = 0,",
    "Symmetry Balance initializer parameters",
)
stereo = replace_once(
    stereo,
    "        self.balance = balance\n        self.interChannelDelayMs = interChannelDelayMs",
    "        self.balance = balance\n        self.symmetryBalanceEnabled = symmetryBalanceEnabled\n        self.symmetryBalancePosition = symmetryBalancePosition\n        self.interChannelDelayMs = interChannelDelayMs",
    "Symmetry Balance initializer state",
)
stereo = replace_once(
    stereo,
    "enum PlaybackControlConfigurationError: Error, LocalizedError, Equatable {\n    case invalidBalance(Double)\n    case invalidInterChannelDelay(Double)",
    "enum PlaybackControlConfigurationError: Error, LocalizedError, Equatable {\n    case invalidBalance(Double)\n    case invalidSymmetryBalance(Double)\n    case invalidInterChannelDelay(Double)",
    "Symmetry Balance configuration error",
)
stereo = replace_once(
    stereo,
    "        case .invalidBalance(let value):\n            return \"Channel balance \\(value) is outside the supported -1...+1 range.\"\n        case .invalidInterChannelDelay(let value):",
    "        case .invalidBalance(let value):\n            return \"Channel balance \\(value) is outside the supported -1...+1 range.\"\n        case .invalidSymmetryBalance(let value):\n            return \"Listening-position symmetry \\(value) is outside the supported -1...+1 range.\"\n        case .invalidInterChannelDelay(let value):",
    "Symmetry Balance error description",
)
stereo = replace_once(
    stereo,
    "        graph.balanceGainLeftLinear = balance.left\n        graph.balanceGainRightLinear = balance.right\n        graph.bypassed = playbackConfiguration.globalBypassed",
    "        graph.balanceGainLeftLinear = balance.left\n        graph.balanceGainRightLinear = balance.right\n        guard N60DSPGraphSnapshotSetSymmetryBalance(\n            &graph,\n            playbackConfiguration.symmetryBalancePosition,\n            playbackConfiguration.symmetryBalanceEnabled\n        ) else {\n            throw PlaybackControlConfigurationError.invalidSymmetryBalance(\n                playbackConfiguration.symmetryBalancePosition\n            )\n        }\n        graph.bypassed = playbackConfiguration.globalBypassed",
    "Symmetry Balance graph publication",
)
stereo_path.write_text(stereo)


# ---------------------------------------------------------------------------
# Engine setters.
# ---------------------------------------------------------------------------
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
engine_marker = "    func setChannelBalance(_ value: Double) throws {\n"
engine_methods = '''    func setSymmetryBalanceEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.symmetryBalanceEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setSymmetryBalancePosition(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.symmetryBalanceRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidSymmetryBalance(value)
        }
        var updated = playbackControlConfiguration
        updated.symmetryBalancePosition = value
        try applyPlaybackControlConfiguration(updated)
    }

'''
if "func setSymmetryBalanceEnabled" not in engine:
    if engine_marker not in engine:
        raise SystemExit("Expected playback setter insertion point was not found")
    engine = engine.replace(engine_marker, engine_methods + engine_marker, 1)
engine_path.write_text(engine)


# ---------------------------------------------------------------------------
# Validation UI: separate from ordinary Balance.
# ---------------------------------------------------------------------------
view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()
binding_marker = "    private var balanceBinding: Binding<Double> {\n"
bindings = '''    private var symmetryBalanceEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.playbackControlConfiguration.symmetryBalanceEnabled },
            set: { try? engine.setSymmetryBalanceEnabled($0) }
        )
    }

    private var symmetryBalancePositionBinding: Binding<Double> {
        Binding(
            get: { engine.playbackControlConfiguration.symmetryBalancePosition },
            set: { try? engine.setSymmetryBalancePosition($0) }
        )
    }

'''
if "symmetryBalanceEnabledBinding" not in view:
    if binding_marker not in view:
        raise SystemExit("Expected Symmetry Balance binding insertion point was not found")
    view = view.replace(binding_marker, bindings + binding_marker, 1)

ui_marker = '''            HStack(spacing: 12) {
                Text("L/R delay").frame(width: 90, alignment: .leading)
'''
ui = '''            HStack(spacing: 12) {
                Toggle("Listening symmetry", isOn: symmetryBalanceEnabledBinding).toggleStyle(.switch)
                Text("L").foregroundStyle(.secondary)
                Slider(
                    value: symmetryBalancePositionBinding,
                    in: PlaybackControlConfiguration.symmetryBalanceRange,
                    step: 0.01
                )
                .disabled(!engine.playbackControlConfiguration.symmetryBalanceEnabled)
                Text("R").foregroundStyle(.secondary)
                Text(engine.playbackControlConfiguration.symmetryBalancePosition.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                    .frame(width: 55)
            }
            Text("Listening symmetry is constant-power compensation for an off-center listening position. It is separate from ordinary attenuation-style Balance; center is unity on both channels.")
                .font(.caption)
                .foregroundStyle(.secondary)
'''
if "Toggle(\"Listening symmetry\"" not in view:
    if ui_marker not in view:
        raise SystemExit("Expected Symmetry Balance UI insertion point was not found")
    view = view.replace(ui_marker, ui + ui_marker, 1)
view_path.write_text(view)


# ---------------------------------------------------------------------------
# XCTest coverage around model publication and realtime behavior.
# ---------------------------------------------------------------------------
test_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = test_path.read_text()
test_marker = "    func testBootstrapTestBundleRuns() {\n"
test_block = '''    func testSymmetryBalanceGraphUsesSeparateConstantPowerStage() throws {
        let playback = PlaybackControlConfiguration(
            balance: 0,
            symmetryBalanceEnabled: true,
            symmetryBalancePosition: -1
        )
        let graph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: playback
        )
        XCTAssertTrue(graph.symmetryBalance.enabled)
        XCTAssertEqual(graph.symmetryBalance.position, -1, accuracy: 0.000_001)
        XCTAssertEqual(graph.symmetryBalance.leftGainLinear, Float.squareRoot(2), accuracy: 0.000_01)
        XCTAssertEqual(graph.symmetryBalance.rightGainLinear, 0, accuracy: 0.000_01)
        XCTAssertEqual(graph.balanceGainLeftLinear, 1)
        XCTAssertEqual(graph.balanceGainRightLinear, 1)
    }

    func testSymmetryBalanceCenterIsUnityAndDisabledPathIsTransparent() throws {
        for enabled in [false, true] {
            let playback = PlaybackControlConfiguration(
                symmetryBalanceEnabled: enabled,
                symmetryBalancePosition: 0
            )
            let graph = try StereoEQConfiguration().makeGraphSnapshot(
                sampleRate: 384_000,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                playbackConfiguration: playback
            )
            XCTAssertEqual(graph.symmetryBalance.leftGainLinear, 1, accuracy: 0.000_01)
            XCTAssertEqual(graph.symmetryBalance.rightGainLinear, 1, accuracy: 0.000_01)
        }
    }

    func testSymmetryBalanceRealtimeExtremePreservesConstantPower() throws {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetSymmetryBalance(&graph, -1, true))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        N60RenderKernelProcessStereoFrame(kernel, 0.25, 0.25, &left, &right)
        XCTAssertEqual(left, 0.25 * Float.squareRoot(2), accuracy: 0.000_01)
        XCTAssertEqual(right, 0, accuracy: 0.000_01)
    }

    func testSymmetryBalanceRejectsInvalidPosition() throws {
        let invalid = PlaybackControlConfiguration(
            symmetryBalanceEnabled: true,
            symmetryBalancePosition: 1.1
        )
        XCTAssertThrowsError(try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: invalid
        )) { error in
            XCTAssertEqual(error as? PlaybackControlConfigurationError, .invalidSymmetryBalance(1.1))
        }
    }

'''
if "testSymmetryBalanceGraphUsesSeparateConstantPowerStage" not in tests:
    if test_marker not in tests:
        raise SystemExit("Expected Symmetry Balance XCTest insertion point was not found")
    tests = tests.replace(test_marker, test_block + test_marker, 1)
test_path.write_text(tests)

print("PR34 Phase D Symmetry Balance integration is present.")
