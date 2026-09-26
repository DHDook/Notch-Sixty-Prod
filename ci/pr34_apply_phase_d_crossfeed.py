from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# Spatial control-plane contract.
spatial_path = Path("NotchSixty/Audio/Realtime/N60Spatial.h")
spatial = spatial_path.read_text()
anchor = "typedef struct {\n    bool enabled;\n    double position;\n    float leftGainLinear;\n    float rightGainLinear;\n} N60SymmetryBalanceSnapshot;\n"
block = anchor + '''

typedef struct {
    bool enabled;
    float amount;
} N60SpeakerCrossfeedSnapshot;

static inline bool N60SpeakerCrossfeedSnapshotIsValid(N60SpeakerCrossfeedSnapshot snapshot) {
    return isfinite(snapshot.amount)
        && snapshot.amount >= 0.0f
        && snapshot.amount <= 0.5f;
}

static inline bool N60SpeakerCrossfeedDesign(
    double amount,
    bool enabled,
    N60SpeakerCrossfeedSnapshot *snapshotOut
) {
    if (snapshotOut == NULL || !isfinite(amount) || amount < 0.0 || amount > 0.5) return false;
    N60SpeakerCrossfeedSnapshot snapshot = {
        .enabled = enabled,
        .amount = (float)amount,
    };
    if (!N60SpeakerCrossfeedSnapshotIsValid(snapshot)) return false;
    *snapshotOut = snapshot;
    return true;
}
'''
spatial = replace_once(spatial, anchor, block, "speaker crossfeed spatial contract")
spatial_path.write_text(spatial)


# Realtime graph and smoothed matrix coefficient.
header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
header = header_path.read_text()
header = replace_once(
    header,
    "    N60SymmetryBalanceSnapshot symmetryBalance;\n    bool bypassed;",
    "    N60SymmetryBalanceSnapshot symmetryBalance;\n    N60SpeakerCrossfeedSnapshot speakerCrossfeed;\n    bool bypassed;",
    "speaker crossfeed graph state",
)
header = replace_once(
    header,
    "bool N60DSPGraphSnapshotSetSymmetryBalance(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double position,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetInterChannelDelay(",
    "bool N60DSPGraphSnapshotSetSymmetryBalance(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double position,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetSpeakerCrossfeed(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double amount,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetInterChannelDelay(",
    "speaker crossfeed setter declaration",
)
header_path.write_text(header)

kernel_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
kernel = kernel_path.read_text()
kernel = replace_once(
    kernel,
    "    N60SmoothedGain symmetryBalanceGainLeft;\n    N60SmoothedGain symmetryBalanceGainRight;\n    N60InterChannelDelayRuntime interChannelDelayRuntime;",
    "    N60SmoothedGain symmetryBalanceGainLeft;\n    N60SmoothedGain symmetryBalanceGainRight;\n    N60SmoothedGain speakerCrossfeedAmount;\n    N60InterChannelDelayRuntime interChannelDelayRuntime;",
    "speaker crossfeed runtime state",
)
kernel = replace_once(
    kernel,
    "        || !N60SymmetryBalanceSnapshotIsValid(snapshot.symmetryBalance)\n        || snapshot.auditionMode < N60AuditionModeProcessed",
    "        || !N60SymmetryBalanceSnapshotIsValid(snapshot.symmetryBalance)\n        || !N60SpeakerCrossfeedSnapshotIsValid(snapshot.speakerCrossfeed)\n        || snapshot.auditionMode < N60AuditionModeProcessed",
    "speaker crossfeed snapshot validation",
)
kernel = replace_once(
    kernel,
    "        reset_smoothed_gain(&kernel->symmetryBalanceGainLeft, snapshot->symmetryBalance.leftGainLinear);\n        reset_smoothed_gain(&kernel->symmetryBalanceGainRight, snapshot->symmetryBalance.rightGainLinear);\n        N60InterChannelDelayRuntimeReset",
    "        reset_smoothed_gain(&kernel->symmetryBalanceGainLeft, snapshot->symmetryBalance.leftGainLinear);\n        reset_smoothed_gain(&kernel->symmetryBalanceGainRight, snapshot->symmetryBalance.rightGainLinear);\n        reset_smoothed_gain(&kernel->speakerCrossfeedAmount, snapshot->speakerCrossfeed.enabled ? snapshot->speakerCrossfeed.amount : 0.0f);\n        N60InterChannelDelayRuntimeReset",
    "speaker crossfeed initial runtime preparation",
)
kernel = replace_once(
    kernel,
    "        schedule_gain_transition(&kernel->symmetryBalanceGainLeft, snapshot->symmetryBalance.leftGainLinear, gainFrames);\n        schedule_gain_transition(&kernel->symmetryBalanceGainRight, snapshot->symmetryBalance.rightGainLinear, gainFrames);\n        N60InterChannelDelayRuntimeSchedule",
    "        schedule_gain_transition(&kernel->symmetryBalanceGainLeft, snapshot->symmetryBalance.leftGainLinear, gainFrames);\n        schedule_gain_transition(&kernel->symmetryBalanceGainRight, snapshot->symmetryBalance.rightGainLinear, gainFrames);\n        schedule_gain_transition(&kernel->speakerCrossfeedAmount, snapshot->speakerCrossfeed.enabled ? snapshot->speakerCrossfeed.amount : 0.0f, gainFrames);\n        N60InterChannelDelayRuntimeSchedule",
    "speaker crossfeed runtime transition",
)
kernel = replace_once(
    kernel,
    "    snapshot.symmetryBalance.leftGainLinear = 1.0f;\n    snapshot.symmetryBalance.rightGainLinear = 1.0f;\n    snapshot.bypassed = false;",
    "    snapshot.symmetryBalance.leftGainLinear = 1.0f;\n    snapshot.symmetryBalance.rightGainLinear = 1.0f;\n    snapshot.speakerCrossfeed.enabled = false;\n    snapshot.speakerCrossfeed.amount = 0.0f;\n    snapshot.bypassed = false;",
    "speaker crossfeed unity state",
)
kernel = replace_once(
    kernel,
    "bool N60DSPGraphSnapshotSetInterChannelDelay(\n    N60DSPGraphSnapshot *snapshot,",
    "bool N60DSPGraphSnapshotSetSpeakerCrossfeed(\n    N60DSPGraphSnapshot *snapshot,\n    double amount,\n    bool enabled\n) {\n    if (snapshot == NULL) return false;\n    N60SpeakerCrossfeedSnapshot crossfeed = {0};\n    if (!N60SpeakerCrossfeedDesign(amount, enabled, &crossfeed)) return false;\n    snapshot->speakerCrossfeed = crossfeed;\n    return true;\n}\n\nbool N60DSPGraphSnapshotSetInterChannelDelay(\n    N60DSPGraphSnapshot *snapshot,",
    "speaker crossfeed graph setter",
)
kernel = replace_once(
    kernel,
    "        left *= next_gain_value(&kernel->symmetryBalanceGainLeft);\n        right *= next_gain_value(&kernel->symmetryBalanceGainRight);\n\n        left *= next_gain_value(&kernel->balanceGainLeft);",
    "        left *= next_gain_value(&kernel->symmetryBalanceGainLeft);\n        right *= next_gain_value(&kernel->symmetryBalanceGainRight);\n\n        // Speaker crossfeed / Panning Gain Matrix. The audited effective range\n        // is 0...0.5: zero is identity and 0.5 is exact mono.\n        const float crossfeed = next_gain_value(&kernel->speakerCrossfeedAmount);\n        const float direct = 1.0f - crossfeed;\n        const float spatialLeft = left;\n        const float spatialRight = right;\n        left = direct * spatialLeft + crossfeed * spatialRight;\n        right = direct * spatialRight + crossfeed * spatialLeft;\n\n        left *= next_gain_value(&kernel->balanceGainLeft);",
    "speaker crossfeed render matrix",
)
kernel_path.write_text(kernel)


# Product state and graph publication.
stereo_path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
stereo = stereo_path.read_text()
stereo = replace_once(
    stereo,
    "    static let symmetryBalanceRange = -1.0...1.0\n    static let interChannelDelayRange = -20.0...20.0",
    "    static let symmetryBalanceRange = -1.0...1.0\n    static let speakerCrossfeedRange = 0.0...0.5\n    static let interChannelDelayRange = -20.0...20.0",
    "speaker crossfeed range",
)
stereo = replace_once(
    stereo,
    "    var symmetryBalanceEnabled: Bool\n    var symmetryBalancePosition: Double\n    var interChannelDelayMs: Double",
    "    var symmetryBalanceEnabled: Bool\n    var symmetryBalancePosition: Double\n    var speakerCrossfeedEnabled: Bool\n    var speakerCrossfeedAmount: Double\n    var interChannelDelayMs: Double",
    "speaker crossfeed product state",
)
stereo = replace_once(
    stereo,
    "        symmetryBalanceEnabled: Bool = false,\n        symmetryBalancePosition: Double = 0,\n        interChannelDelayMs: Double = 0,",
    "        symmetryBalanceEnabled: Bool = false,\n        symmetryBalancePosition: Double = 0,\n        speakerCrossfeedEnabled: Bool = false,\n        speakerCrossfeedAmount: Double = 0,\n        interChannelDelayMs: Double = 0,",
    "speaker crossfeed initializer parameters",
)
stereo = replace_once(
    stereo,
    "        self.symmetryBalanceEnabled = symmetryBalanceEnabled\n        self.symmetryBalancePosition = symmetryBalancePosition\n        self.interChannelDelayMs = interChannelDelayMs",
    "        self.symmetryBalanceEnabled = symmetryBalanceEnabled\n        self.symmetryBalancePosition = symmetryBalancePosition\n        self.speakerCrossfeedEnabled = speakerCrossfeedEnabled\n        self.speakerCrossfeedAmount = speakerCrossfeedAmount\n        self.interChannelDelayMs = interChannelDelayMs",
    "speaker crossfeed initializer state",
)
stereo = replace_once(
    stereo,
    "    case invalidSymmetryBalance(Double)\n    case invalidInterChannelDelay(Double)",
    "    case invalidSymmetryBalance(Double)\n    case invalidSpeakerCrossfeed(Double)\n    case invalidInterChannelDelay(Double)",
    "speaker crossfeed configuration error",
)
stereo = replace_once(
    stereo,
    "        case .invalidSymmetryBalance(let value):\n            return \"Listening-position symmetry \\(value) is outside the supported -1...+1 range.\"\n        case .invalidInterChannelDelay(let value):",
    "        case .invalidSymmetryBalance(let value):\n            return \"Listening-position symmetry \\(value) is outside the supported -1...+1 range.\"\n        case .invalidSpeakerCrossfeed(let value):\n            return \"Speaker crossfeed \\(value) is outside the supported 0...0.5 range.\"\n        case .invalidInterChannelDelay(let value):",
    "speaker crossfeed error description",
)
stereo = replace_once(
    stereo,
    "        guard N60DSPGraphSnapshotSetSymmetryBalance(\n            &graph,\n            playbackConfiguration.symmetryBalancePosition,\n            playbackConfiguration.symmetryBalanceEnabled\n        ) else {\n            throw PlaybackControlConfigurationError.invalidSymmetryBalance(\n                playbackConfiguration.symmetryBalancePosition\n            )\n        }\n        graph.bypassed = playbackConfiguration.globalBypassed",
    "        guard N60DSPGraphSnapshotSetSymmetryBalance(\n            &graph,\n            playbackConfiguration.symmetryBalancePosition,\n            playbackConfiguration.symmetryBalanceEnabled\n        ) else {\n            throw PlaybackControlConfigurationError.invalidSymmetryBalance(\n                playbackConfiguration.symmetryBalancePosition\n            )\n        }\n        guard N60DSPGraphSnapshotSetSpeakerCrossfeed(\n            &graph,\n            playbackConfiguration.speakerCrossfeedAmount,\n            playbackConfiguration.speakerCrossfeedEnabled\n        ) else {\n            throw PlaybackControlConfigurationError.invalidSpeakerCrossfeed(\n                playbackConfiguration.speakerCrossfeedAmount\n            )\n        }\n        graph.bypassed = playbackConfiguration.globalBypassed",
    "speaker crossfeed graph publication",
)
stereo_path.write_text(stereo)


# Engine setters.
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
marker = "    func setSymmetryBalanceEnabled(_ enabled: Bool) throws {\n"
methods = '''    func setSpeakerCrossfeedEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.speakerCrossfeedEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setSpeakerCrossfeedAmount(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.speakerCrossfeedRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidSpeakerCrossfeed(value)
        }
        var updated = playbackControlConfiguration
        updated.speakerCrossfeedAmount = value
        try applyPlaybackControlConfiguration(updated)
    }

'''
if "func setSpeakerCrossfeedEnabled" not in engine:
    if marker not in engine:
        raise SystemExit("Expected speaker crossfeed engine insertion point was not found")
    engine = engine.replace(marker, methods + marker, 1)
engine_path.write_text(engine)


# Validation UI.
view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()
binding_marker = "    private var symmetryBalanceEnabledBinding: Binding<Bool> {\n"
bindings = '''    private var speakerCrossfeedEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.playbackControlConfiguration.speakerCrossfeedEnabled },
            set: { try? engine.setSpeakerCrossfeedEnabled($0) }
        )
    }

    private var speakerCrossfeedAmountBinding: Binding<Double> {
        Binding(
            get: { engine.playbackControlConfiguration.speakerCrossfeedAmount },
            set: { try? engine.setSpeakerCrossfeedAmount($0) }
        )
    }

'''
if "speakerCrossfeedEnabledBinding" not in view:
    if binding_marker not in view:
        raise SystemExit("Expected speaker crossfeed binding insertion point was not found")
    view = view.replace(binding_marker, bindings + binding_marker, 1)

ui_marker = '''            Text("Listening symmetry is constant-power compensation for an off-center listening position. It is separate from ordinary attenuation-style Balance; center is unity on both channels.")
                .font(.caption)
                .foregroundStyle(.secondary)
'''
ui = ui_marker + '''            HStack(spacing: 12) {
                Toggle("Speaker crossfeed", isOn: speakerCrossfeedEnabledBinding).toggleStyle(.switch)
                Slider(
                    value: speakerCrossfeedAmountBinding,
                    in: PlaybackControlConfiguration.speakerCrossfeedRange,
                    step: 0.01
                )
                .disabled(!engine.playbackControlConfiguration.speakerCrossfeedEnabled)
                Text(engine.playbackControlConfiguration.speakerCrossfeedAmount.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                    .frame(width: 55)
            }
            Text("Crossfeed uses the speaker Panning Gain Matrix. 0.00 leaves stereo untouched; 0.50 collapses to exact mono. The legacy 0...1 display range is intentionally not reproduced.")
                .font(.caption)
                .foregroundStyle(.secondary)
'''
view = replace_once(view, ui_marker, ui, "speaker crossfeed UI")
view_path.write_text(view)


# XCTest coverage.
test_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = test_path.read_text()
test_marker = "    func testSymmetryBalanceGraphUsesSeparateConstantPowerStage() throws {\n"
test_block = '''    func testSpeakerCrossfeedGraphPublishesAuditedRange() throws {
        let playback = PlaybackControlConfiguration(
            speakerCrossfeedEnabled: true,
            speakerCrossfeedAmount: 0.25
        )
        let graph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: playback
        )
        XCTAssertTrue(graph.speakerCrossfeed.enabled)
        XCTAssertEqual(graph.speakerCrossfeed.amount, 0.25, accuracy: 0.000_001)
    }

    func testSpeakerCrossfeedRealtimeMatrixAndMonoCollapse() {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetSpeakerCrossfeed(&graph, 0.5, true))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        var left: Float = 0
        var right: Float = 0
        N60RenderKernelProcessStereoFrame(kernel, 0.8, -0.2, &left, &right)
        XCTAssertEqual(left, 0.3, accuracy: 0.000_01)
        XCTAssertEqual(right, 0.3, accuracy: 0.000_01)
    }

    func testSpeakerCrossfeedRejectsMisleadingLegacyUpperRange() throws {
        let invalid = PlaybackControlConfiguration(
            speakerCrossfeedEnabled: true,
            speakerCrossfeedAmount: 0.75
        )
        XCTAssertThrowsError(try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: invalid
        )) { error in
            XCTAssertEqual(error as? PlaybackControlConfigurationError, .invalidSpeakerCrossfeed(0.75))
        }
    }

'''
if "testSpeakerCrossfeedGraphPublishesAuditedRange" not in tests:
    if test_marker not in tests:
        raise SystemExit("Expected speaker crossfeed XCTest insertion point was not found")
    tests = tests.replace(test_marker, test_block + test_marker, 1)
test_path.write_text(tests)

print("PR34 Phase D speaker crossfeed integration is present.")
