from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Spatial control-plane snapshot: independently designed, bounded feed-forward
# cancellation with a one-pole far-ear/head-shadow low-pass model.
# ---------------------------------------------------------------------------
spatial_path = Path("NotchSixty/Audio/Realtime/N60Spatial.h")
spatial = spatial_path.read_text()
anchor = '''typedef struct {
    bool enabled;
    float amount;
} N60SpeakerCrossfeedSnapshot;
'''
block = anchor + '''

typedef struct {
    bool enabled;
    float amount;
    double headShadowFrequencyHz;
    float headShadowAlpha;
} N60CrosstalkCancellationSnapshot;

static inline bool N60CrosstalkCancellationSnapshotIsValid(N60CrosstalkCancellationSnapshot snapshot) {
    return isfinite(snapshot.amount)
        && snapshot.amount >= 0.0f
        && snapshot.amount <= 1.0f
        && isfinite(snapshot.headShadowFrequencyHz)
        && snapshot.headShadowFrequencyHz >= 200.0
        && snapshot.headShadowFrequencyHz <= 2000.0
        && isfinite(snapshot.headShadowAlpha)
        && snapshot.headShadowAlpha > 0.0f
        && snapshot.headShadowAlpha <= 1.0f;
}

static inline bool N60CrosstalkCancellationDesign(
    double sampleRate,
    double amount,
    double headShadowFrequencyHz,
    bool enabled,
    N60CrosstalkCancellationSnapshot *snapshotOut
) {
    if (snapshotOut == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(amount) || amount < 0.0 || amount > 1.0
        || !isfinite(headShadowFrequencyHz)
        || headShadowFrequencyHz < 200.0 || headShadowFrequencyHz > 2000.0
        || headShadowFrequencyHz >= sampleRate * 0.5) {
        return false;
    }
    const double pi = 3.14159265358979323846264338327950288;
    const double alpha = 1.0 - exp(-2.0 * pi * headShadowFrequencyHz / sampleRate);
    N60CrosstalkCancellationSnapshot snapshot = {
        .enabled = enabled,
        .amount = (float)amount,
        .headShadowFrequencyHz = headShadowFrequencyHz,
        .headShadowAlpha = (float)alpha,
    };
    if (!N60CrosstalkCancellationSnapshotIsValid(snapshot)) return false;
    *snapshotOut = snapshot;
    return true;
}
'''
spatial = replace_once(spatial, anchor, block, "crosstalk spatial contract")
spatial_path.write_text(spatial)


# ---------------------------------------------------------------------------
# Realtime graph + smoothed feed-forward stage.
# ---------------------------------------------------------------------------
header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
header = header_path.read_text()
header = replace_once(
    header,
    "    N60SpeakerCrossfeedSnapshot speakerCrossfeed;\n    bool bypassed;",
    "    N60SpeakerCrossfeedSnapshot speakerCrossfeed;\n    N60CrosstalkCancellationSnapshot crosstalkCancellation;\n    bool bypassed;",
    "crosstalk graph state",
)
header = replace_once(
    header,
    "bool N60DSPGraphSnapshotSetSpeakerCrossfeed(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double amount,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetInterChannelDelay(",
    "bool N60DSPGraphSnapshotSetSpeakerCrossfeed(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double amount,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetCrosstalkCancellation(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    double amount,\n    double headShadowFrequencyHz,\n    bool enabled\n);\nbool N60DSPGraphSnapshotSetInterChannelDelay(",
    "crosstalk setter declaration",
)
header_path.write_text(header)

kernel_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
kernel = kernel_path.read_text()
kernel = replace_once(
    kernel,
    "    N60SmoothedGain speakerCrossfeedAmount;\n    N60InterChannelDelayRuntime interChannelDelayRuntime;",
    "    N60SmoothedGain speakerCrossfeedAmount;\n    N60SmoothedGain crosstalkCancellationAmount;\n    N60SmoothedGain crosstalkHeadShadowAlpha;\n    float crosstalkShadowLeft;\n    float crosstalkShadowRight;\n    N60InterChannelDelayRuntime interChannelDelayRuntime;",
    "crosstalk runtime state",
)
kernel = replace_once(
    kernel,
    "        || !N60SpeakerCrossfeedSnapshotIsValid(snapshot.speakerCrossfeed)\n        || snapshot.auditionMode < N60AuditionModeProcessed",
    "        || !N60SpeakerCrossfeedSnapshotIsValid(snapshot.speakerCrossfeed)\n        || !N60CrosstalkCancellationSnapshotIsValid(snapshot.crosstalkCancellation)\n        || snapshot.auditionMode < N60AuditionModeProcessed",
    "crosstalk snapshot validation",
)
kernel = replace_once(
    kernel,
    "        reset_smoothed_gain(&kernel->speakerCrossfeedAmount, snapshot->speakerCrossfeed.enabled ? snapshot->speakerCrossfeed.amount : 0.0f);\n        N60InterChannelDelayRuntimeReset",
    "        reset_smoothed_gain(&kernel->speakerCrossfeedAmount, snapshot->speakerCrossfeed.enabled ? snapshot->speakerCrossfeed.amount : 0.0f);\n        reset_smoothed_gain(&kernel->crosstalkCancellationAmount, snapshot->crosstalkCancellation.enabled ? snapshot->crosstalkCancellation.amount : 0.0f);\n        reset_smoothed_gain(&kernel->crosstalkHeadShadowAlpha, snapshot->crosstalkCancellation.headShadowAlpha);\n        kernel->crosstalkShadowLeft = 0.0f;\n        kernel->crosstalkShadowRight = 0.0f;\n        N60InterChannelDelayRuntimeReset",
    "crosstalk initial runtime preparation",
)
kernel = replace_once(
    kernel,
    "        schedule_gain_transition(&kernel->speakerCrossfeedAmount, snapshot->speakerCrossfeed.enabled ? snapshot->speakerCrossfeed.amount : 0.0f, gainFrames);\n        N60InterChannelDelayRuntimeSchedule",
    "        schedule_gain_transition(&kernel->speakerCrossfeedAmount, snapshot->speakerCrossfeed.enabled ? snapshot->speakerCrossfeed.amount : 0.0f, gainFrames);\n        schedule_gain_transition(&kernel->crosstalkCancellationAmount, snapshot->crosstalkCancellation.enabled ? snapshot->crosstalkCancellation.amount : 0.0f, gainFrames);\n        schedule_gain_transition(&kernel->crosstalkHeadShadowAlpha, snapshot->crosstalkCancellation.headShadowAlpha, gainFrames);\n        N60InterChannelDelayRuntimeSchedule",
    "crosstalk runtime transition",
)
kernel = replace_once(
    kernel,
    "    snapshot.speakerCrossfeed.enabled = false;\n    snapshot.speakerCrossfeed.amount = 0.0f;\n    snapshot.bypassed = false;",
    "    snapshot.speakerCrossfeed.enabled = false;\n    snapshot.speakerCrossfeed.amount = 0.0f;\n    (void)N60CrosstalkCancellationDesign(sampleRate, 0.5, 700.0, false, &snapshot.crosstalkCancellation);\n    snapshot.bypassed = false;",
    "crosstalk unity state",
)
kernel = replace_once(
    kernel,
    "bool N60DSPGraphSnapshotSetInterChannelDelay(\n    N60DSPGraphSnapshot *snapshot,",
    "bool N60DSPGraphSnapshotSetCrosstalkCancellation(\n    N60DSPGraphSnapshot *snapshot,\n    double amount,\n    double headShadowFrequencyHz,\n    bool enabled\n) {\n    if (snapshot == NULL) return false;\n    N60CrosstalkCancellationSnapshot cancellation = {0};\n    if (!N60CrosstalkCancellationDesign(\n            snapshot->sampleRate, amount, headShadowFrequencyHz, enabled, &cancellation)) return false;\n    snapshot->crosstalkCancellation = cancellation;\n    return true;\n}\n\nbool N60DSPGraphSnapshotSetInterChannelDelay(\n    N60DSPGraphSnapshot *snapshot,",
    "crosstalk graph setter",
)
kernel = replace_once(
    kernel,
    "        left = direct * spatialLeft + crossfeed * spatialRight;\n        right = direct * spatialRight + crossfeed * spatialLeft;\n\n        left *= next_gain_value(&kernel->balanceGainLeft);",
    "        left = direct * spatialLeft + crossfeed * spatialRight;\n        right = direct * spatialRight + crossfeed * spatialLeft;\n\n        // Gentle feed-forward speaker crosstalk cancellation. The opposite-channel\n        // cancellation signal is frequency-shaped by a first-order far-ear/head-\n        // shadow model; there is no recursive feedback loop in the realtime path.\n        const float shadowAlpha = next_gain_value(&kernel->crosstalkHeadShadowAlpha);\n        kernel->crosstalkShadowLeft += shadowAlpha * (left - kernel->crosstalkShadowLeft);\n        kernel->crosstalkShadowRight += shadowAlpha * (right - kernel->crosstalkShadowRight);\n        const float cancellationAmount = next_gain_value(&kernel->crosstalkCancellationAmount);\n        const float cancellationLeft = left;\n        const float cancellationRight = right;\n        left = cancellationLeft - cancellationAmount * kernel->crosstalkShadowRight;\n        right = cancellationRight - cancellationAmount * kernel->crosstalkShadowLeft;\n\n        left *= next_gain_value(&kernel->balanceGainLeft);",
    "crosstalk render stage",
)
kernel_path.write_text(kernel)


# ---------------------------------------------------------------------------
# Product state + graph publication.
# ---------------------------------------------------------------------------
stereo_path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
stereo = stereo_path.read_text()
stereo = replace_once(
    stereo,
    "    static let speakerCrossfeedRange = 0.0...0.5\n    static let interChannelDelayRange = -20.0...20.0",
    "    static let speakerCrossfeedRange = 0.0...0.5\n    static let crosstalkCancellationAmountRange = 0.0...1.0\n    static let crosstalkHeadShadowFrequencyRange = 200.0...2000.0\n    static let interChannelDelayRange = -20.0...20.0",
    "crosstalk product ranges",
)
stereo = replace_once(
    stereo,
    "    var speakerCrossfeedEnabled: Bool\n    var speakerCrossfeedAmount: Double\n    var interChannelDelayMs: Double",
    "    var speakerCrossfeedEnabled: Bool\n    var speakerCrossfeedAmount: Double\n    var crosstalkCancellationEnabled: Bool\n    var crosstalkCancellationAmount: Double\n    var crosstalkHeadShadowFrequencyHz: Double\n    var interChannelDelayMs: Double",
    "crosstalk product state",
)
stereo = replace_once(
    stereo,
    "        speakerCrossfeedEnabled: Bool = false,\n        speakerCrossfeedAmount: Double = 0,\n        interChannelDelayMs: Double = 0,",
    "        speakerCrossfeedEnabled: Bool = false,\n        speakerCrossfeedAmount: Double = 0,\n        crosstalkCancellationEnabled: Bool = false,\n        crosstalkCancellationAmount: Double = 0.5,\n        crosstalkHeadShadowFrequencyHz: Double = 700,\n        interChannelDelayMs: Double = 0,",
    "crosstalk initializer parameters",
)
stereo = replace_once(
    stereo,
    "        self.speakerCrossfeedEnabled = speakerCrossfeedEnabled\n        self.speakerCrossfeedAmount = speakerCrossfeedAmount\n        self.interChannelDelayMs = interChannelDelayMs",
    "        self.speakerCrossfeedEnabled = speakerCrossfeedEnabled\n        self.speakerCrossfeedAmount = speakerCrossfeedAmount\n        self.crosstalkCancellationEnabled = crosstalkCancellationEnabled\n        self.crosstalkCancellationAmount = crosstalkCancellationAmount\n        self.crosstalkHeadShadowFrequencyHz = crosstalkHeadShadowFrequencyHz\n        self.interChannelDelayMs = interChannelDelayMs",
    "crosstalk initializer state",
)
stereo = replace_once(
    stereo,
    "    case invalidSpeakerCrossfeed(Double)\n    case invalidInterChannelDelay(Double)",
    "    case invalidSpeakerCrossfeed(Double)\n    case invalidCrosstalkCancellationAmount(Double)\n    case invalidCrosstalkHeadShadowFrequency(Double)\n    case invalidInterChannelDelay(Double)",
    "crosstalk configuration errors",
)
stereo = replace_once(
    stereo,
    "        case .invalidSpeakerCrossfeed(let value):\n            return \"Speaker crossfeed \\(value) is outside the supported 0...0.5 range.\"\n        case .invalidInterChannelDelay(let value):",
    "        case .invalidSpeakerCrossfeed(let value):\n            return \"Speaker crossfeed \\(value) is outside the supported 0...0.5 range.\"\n        case .invalidCrosstalkCancellationAmount(let value):\n            return \"Crosstalk cancellation amount \\(value) is outside the supported 0...1 range.\"\n        case .invalidCrosstalkHeadShadowFrequency(let value):\n            return \"Crosstalk head-shadow frequency \\(value) Hz is outside the supported 200...2000 Hz range.\"\n        case .invalidInterChannelDelay(let value):",
    "crosstalk error descriptions",
)
stereo = replace_once(
    stereo,
    "        guard N60DSPGraphSnapshotSetSpeakerCrossfeed(\n            &graph,\n            playbackConfiguration.speakerCrossfeedAmount,\n            playbackConfiguration.speakerCrossfeedEnabled\n        ) else {\n            throw PlaybackControlConfigurationError.invalidSpeakerCrossfeed(\n                playbackConfiguration.speakerCrossfeedAmount\n            )\n        }\n        graph.bypassed = playbackConfiguration.globalBypassed",
    "        guard N60DSPGraphSnapshotSetSpeakerCrossfeed(\n            &graph,\n            playbackConfiguration.speakerCrossfeedAmount,\n            playbackConfiguration.speakerCrossfeedEnabled\n        ) else {\n            throw PlaybackControlConfigurationError.invalidSpeakerCrossfeed(\n                playbackConfiguration.speakerCrossfeedAmount\n            )\n        }\n        guard PlaybackControlConfiguration.crosstalkCancellationAmountRange.contains(\n            playbackConfiguration.crosstalkCancellationAmount\n        ) else {\n            throw PlaybackControlConfigurationError.invalidCrosstalkCancellationAmount(\n                playbackConfiguration.crosstalkCancellationAmount\n            )\n        }\n        guard PlaybackControlConfiguration.crosstalkHeadShadowFrequencyRange.contains(\n            playbackConfiguration.crosstalkHeadShadowFrequencyHz\n        ) else {\n            throw PlaybackControlConfigurationError.invalidCrosstalkHeadShadowFrequency(\n                playbackConfiguration.crosstalkHeadShadowFrequencyHz\n            )\n        }\n        guard N60DSPGraphSnapshotSetCrosstalkCancellation(\n            &graph,\n            playbackConfiguration.crosstalkCancellationAmount,\n            playbackConfiguration.crosstalkHeadShadowFrequencyHz,\n            playbackConfiguration.crosstalkCancellationEnabled\n        ) else {\n            throw PlaybackControlConfigurationError.invalidCrosstalkHeadShadowFrequency(\n                playbackConfiguration.crosstalkHeadShadowFrequencyHz\n            )\n        }\n        graph.bypassed = playbackConfiguration.globalBypassed",
    "crosstalk graph publication",
)
stereo_path.write_text(stereo)


# Engine setters.
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
marker = "    func setSpeakerCrossfeedEnabled(_ enabled: Bool) throws {\n"
methods = '''    func setCrosstalkCancellationEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.crosstalkCancellationEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setCrosstalkCancellationAmount(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.crosstalkCancellationAmountRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkCancellationAmount(value)
        }
        var updated = playbackControlConfiguration
        updated.crosstalkCancellationAmount = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setCrosstalkHeadShadowFrequency(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.crosstalkHeadShadowFrequencyRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkHeadShadowFrequency(value)
        }
        var updated = playbackControlConfiguration
        updated.crosstalkHeadShadowFrequencyHz = value
        try applyPlaybackControlConfiguration(updated)
    }

'''
if "func setCrosstalkCancellationEnabled" not in engine:
    if marker not in engine:
        raise SystemExit("Expected crosstalk engine insertion point was not found")
    engine = engine.replace(marker, methods + marker, 1)
engine_path.write_text(engine)


# Validation UI.
view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()
binding_marker = "    private var speakerCrossfeedEnabledBinding: Binding<Bool> {\n"
bindings = '''    private var crosstalkCancellationEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.playbackControlConfiguration.crosstalkCancellationEnabled },
            set: { try? engine.setCrosstalkCancellationEnabled($0) }
        )
    }

    private var crosstalkCancellationAmountBinding: Binding<Double> {
        Binding(
            get: { engine.playbackControlConfiguration.crosstalkCancellationAmount },
            set: { try? engine.setCrosstalkCancellationAmount($0) }
        )
    }

    private var crosstalkHeadShadowFrequencyBinding: Binding<Double> {
        Binding(
            get: { engine.playbackControlConfiguration.crosstalkHeadShadowFrequencyHz },
            set: { try? engine.setCrosstalkHeadShadowFrequency($0) }
        )
    }

'''
if "crosstalkCancellationEnabledBinding" not in view:
    if binding_marker not in view:
        raise SystemExit("Expected crosstalk binding insertion point was not found")
    view = view.replace(binding_marker, bindings + binding_marker, 1)

ui_marker = '''            Text("Crossfeed uses the speaker Panning Gain Matrix. 0.00 leaves stereo untouched; 0.50 collapses to exact mono. The legacy 0...1 display range is intentionally not reproduced.")
                .font(.caption)
                .foregroundStyle(.secondary)
'''
ui = ui_marker + '''            HStack(spacing: 12) {
                Toggle("Crosstalk cancellation", isOn: crosstalkCancellationEnabledBinding).toggleStyle(.switch)
                Text("Amount").frame(width: 60, alignment: .leading)
                Slider(
                    value: crosstalkCancellationAmountBinding,
                    in: PlaybackControlConfiguration.crosstalkCancellationAmountRange,
                    step: 0.01
                )
                .disabled(!engine.playbackControlConfiguration.crosstalkCancellationEnabled)
                Text(engine.playbackControlConfiguration.crosstalkCancellationAmount.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit().frame(width: 55)
            }
            HStack(spacing: 12) {
                Text("Head shadow").frame(width: 90, alignment: .leading)
                Slider(
                    value: crosstalkHeadShadowFrequencyBinding,
                    in: PlaybackControlConfiguration.crosstalkHeadShadowFrequencyRange,
                    step: 10
                )
                .disabled(!engine.playbackControlConfiguration.crosstalkCancellationEnabled)
                Text("\\(Int(engine.playbackControlConfiguration.crosstalkHeadShadowFrequencyHz.rounded())) Hz")
                    .monospacedDigit().frame(width: 75)
            }
            Text("A stable feed-forward opposite-channel cancellation signal is shaped by the Head Shadow low-pass model. 700 Hz is the audited default associated with conventional ~60° speaker spacing.")
                .font(.caption)
                .foregroundStyle(.secondary)
'''
view = replace_once(view, ui_marker, ui, "crosstalk UI")
view_path.write_text(view)


# XCTest coverage.
test_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = test_path.read_text()
test_marker = "    func testSpeakerCrossfeedGraphPublishesAuditedRange() throws {\n"
test_block = '''    func testCrosstalkCancellationGraphPublishesAuditedDefaults() throws {
        let playback = PlaybackControlConfiguration(crosstalkCancellationEnabled: true)
        let graph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: playback
        )
        XCTAssertTrue(graph.crosstalkCancellation.enabled)
        XCTAssertEqual(graph.crosstalkCancellation.amount, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(graph.crosstalkCancellation.headShadowFrequencyHz, 700, accuracy: 0.000_001)
        XCTAssertGreaterThan(graph.crosstalkCancellation.headShadowAlpha, 0)
        XCTAssertLessThan(graph.crosstalkCancellation.headShadowAlpha, 1)
    }

    func testCrosstalkCancellationFeedForwardStageRemainsBounded() {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetCrosstalkCancellation(&graph, 0.5, 700, true))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        var left: Float = 0
        var right: Float = 0
        for _ in 0..<4096 {
            N60RenderKernelProcessStereoFrame(kernel, 0, 1, &left, &right)
            XCTAssertTrue(left.isFinite && right.isFinite)
            XCTAssertLessThanOrEqual(abs(left), 1.000_01)
            XCTAssertLessThanOrEqual(abs(right), 1.000_01)
        }
        XCTAssertEqual(left, -0.5, accuracy: 0.001)
        XCTAssertEqual(right, 1.0, accuracy: 0.001)
    }

    func testCrosstalkCancellationRejectsOutOfRangeControls() throws {
        let invalidAmount = PlaybackControlConfiguration(crosstalkCancellationAmount: 1.1)
        XCTAssertThrowsError(try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: invalidAmount
        ))
        let invalidShadow = PlaybackControlConfiguration(crosstalkHeadShadowFrequencyHz: 199)
        XCTAssertThrowsError(try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: invalidShadow
        ))
    }

'''
if "testCrosstalkCancellationGraphPublishesAuditedDefaults" not in tests:
    if test_marker not in tests:
        raise SystemExit("Expected crosstalk XCTest insertion point was not found")
    tests = tests.replace(test_marker, test_block + test_marker, 1)
test_path.write_text(tests)

print("PR34 Phase D crosstalk cancellation integration is present.")
