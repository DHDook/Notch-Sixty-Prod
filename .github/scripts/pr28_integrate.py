from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"missing insertion point: {label}")
    return text.replace(old, new, 1)

# --- Realtime render diagnostics -------------------------------------------------
path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
text = path.read_text()
text = replace_once(
    text,
    '''    _Atomic uint64_t roomCorrectionProgramMisses;\n\n    _Atomic uint32_t compressorGainReductionBits;''',
    '''    _Atomic uint64_t roomCorrectionProgramMisses;\n\n    _Atomic uint32_t deEsserGainReductionBits;\n    _Atomic uint32_t multibandLowGainReductionBits;\n    _Atomic uint32_t multibandMidGainReductionBits;\n    _Atomic uint32_t multibandHighGainReductionBits;\n    _Atomic uint32_t compressorGainReductionBits;''',
    "render atomics",
)
text = replace_once(
    text,
    '''        N60DynamicsTelemetry telemetry = N60DynamicsRuntimeTelemetry(&kernel->dynamicsRuntime);\n        atomic_store_explicit(&kernel->compressorGainReductionBits, float_to_bits(telemetry.compressorGainReductionDB), memory_order_relaxed);''',
    '''        N60DynamicsTelemetry telemetry = N60DynamicsRuntimeTelemetry(&kernel->dynamicsRuntime);\n        atomic_store_explicit(&kernel->deEsserGainReductionBits, float_to_bits(telemetry.deEsserGainReductionDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->multibandLowGainReductionBits, float_to_bits(telemetry.multibandLowGainReductionDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->multibandMidGainReductionBits, float_to_bits(telemetry.multibandMidGainReductionDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->multibandHighGainReductionBits, float_to_bits(telemetry.multibandHighGainReductionDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->compressorGainReductionBits, float_to_bits(telemetry.compressorGainReductionDB), memory_order_relaxed);''',
    "telemetry publish",
)
text = replace_once(
    text,
    '''        diagnostics.compressorEnabled = context.snapshot.dynamics.compressor.enabled;\n        diagnostics.expanderEnabled = context.snapshot.dynamics.expander.enabled;''',
    '''        diagnostics.deEsserEnabled = context.snapshot.dynamics.deEsser.enabled;\n        diagnostics.deEsserDynamicEQMode = context.snapshot.dynamics.deEsser.dynamicEQMode;\n        diagnostics.deEsserFrequencyHz = context.snapshot.dynamics.deEsser.frequencyHz;\n        diagnostics.multibandCompressorEnabled = context.snapshot.dynamics.multibandCompressor.enabled;\n        diagnostics.multibandLowMidFrequencyHz = context.snapshot.dynamics.multibandCompressor.lowMidFrequencyHz;\n        diagnostics.multibandMidHighFrequencyHz = context.snapshot.dynamics.multibandCompressor.midHighFrequencyHz;\n        diagnostics.multibandTopology = context.snapshot.dynamics.multibandCompressor.topology;\n        diagnostics.compressorEnabled = context.snapshot.dynamics.compressor.enabled;\n        diagnostics.expanderEnabled = context.snapshot.dynamics.expander.enabled;''',
    "snapshot diagnostics",
)
text = replace_once(
    text,
    '''    diagnostics.compressorGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->compressorGainReductionBits, memory_order_relaxed));\n    diagnostics.expanderAttenuationDB = bits_to_float(atomic_load_explicit(&kernel->expanderAttenuationBits, memory_order_relaxed));''',
    '''    diagnostics.deEsserGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->deEsserGainReductionBits, memory_order_relaxed));\n    diagnostics.multibandLowGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->multibandLowGainReductionBits, memory_order_relaxed));\n    diagnostics.multibandMidGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->multibandMidGainReductionBits, memory_order_relaxed));\n    diagnostics.multibandHighGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->multibandHighGainReductionBits, memory_order_relaxed));\n    diagnostics.compressorGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->compressorGainReductionBits, memory_order_relaxed));\n    diagnostics.expanderAttenuationDB = bits_to_float(atomic_load_explicit(&kernel->expanderAttenuationBits, memory_order_relaxed));''',
    "telemetry diagnostics",
)
path.write_text(text)

# --- Swift diagnostics bridge ----------------------------------------------------
path = Path("NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift")
text = path.read_text()
text = replace_once(
    text,
    '''    let crossoverSectionCount: UInt32\n    let compressorEnabled: Bool''',
    '''    let crossoverSectionCount: UInt32\n    let deEsserEnabled: Bool\n    let deEsserDynamicEQMode: Bool\n    let deEsserFrequencyHz: Double\n    let multibandCompressorEnabled: Bool\n    let multibandLowMidFrequencyHz: Double\n    let multibandMidHighFrequencyHz: Double\n    let multibandTopology: N60CrossoverTopology\n    let deEsserGainReductionDB: Float\n    let multibandLowGainReductionDB: Float\n    let multibandMidGainReductionDB: Float\n    let multibandHighGainReductionDB: Float\n    let compressorEnabled: Bool''',
    "swift diagnostic fields",
)
text = replace_once(
    text,
    '''        crossoverSectionCount = diagnostics.crossoverSectionCount\n        compressorEnabled = diagnostics.compressorEnabled''',
    '''        crossoverSectionCount = diagnostics.crossoverSectionCount\n        deEsserEnabled = diagnostics.deEsserEnabled\n        deEsserDynamicEQMode = diagnostics.deEsserDynamicEQMode\n        deEsserFrequencyHz = diagnostics.deEsserFrequencyHz\n        multibandCompressorEnabled = diagnostics.multibandCompressorEnabled\n        multibandLowMidFrequencyHz = diagnostics.multibandLowMidFrequencyHz\n        multibandMidHighFrequencyHz = diagnostics.multibandMidHighFrequencyHz\n        multibandTopology = diagnostics.multibandTopology\n        deEsserGainReductionDB = diagnostics.deEsserGainReductionDB\n        multibandLowGainReductionDB = diagnostics.multibandLowGainReductionDB\n        multibandMidGainReductionDB = diagnostics.multibandMidGainReductionDB\n        multibandHighGainReductionDB = diagnostics.multibandHighGainReductionDB\n        compressorEnabled = diagnostics.compressorEnabled''',
    "swift diagnostic mapping",
)
path.write_text(text)

# --- Product schema + PR28 engineering tab --------------------------------------
path = Path("NotchSixty/NotchSixtyApp.swift")
text = path.read_text()
text = replace_once(text, "static let currentSchemaVersion = 5", "static let currentSchemaVersion = 6", "schema v6")

view = r'''
private struct PR28AdvancedDynamicsValidationView: View {
    @ObservedObject var engine: AudioIOEngine

    private func dynamicsBinding<Value>(_ keyPath: WritableKeyPath<DynamicsConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated[keyPath: keyPath] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    var body: some View {
        let deEsserEnabled = dynamicsBinding(\.deEsser.enabled)
        let deEsserFrequency = dynamicsBinding(\.deEsser.frequencyHz)
        let deEsserThreshold = dynamicsBinding(\.deEsser.thresholdDB)
        let deEsserDynamicEQ = dynamicsBinding(\.deEsser.dynamicEQMode)
        let multibandEnabled = dynamicsBinding(\.multibandCompressor.enabled)
        let lowMid = dynamicsBinding(\.multibandCompressor.lowMidFrequencyHz)
        let midHigh = dynamicsBinding(\.multibandCompressor.midHighFrequencyHz)
        let slope = dynamicsBinding(\.multibandCompressor.slope)
        let lowThreshold = dynamicsBinding(\.multibandCompressor.lowThresholdDB)
        let midThreshold = dynamicsBinding(\.multibandCompressor.midThresholdDB)
        let highThreshold = dynamicsBinding(\.multibandCompressor.highThresholdDB)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR28 Advanced Dynamics Validation")
                    .font(.title2.bold())
                Text("Clean-room validation surface for De-Esser and three-band Multiband Compressor parity.")
                    .foregroundStyle(.secondary)

                GroupBox("De-Esser") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable De-Esser", isOn: deEsserEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Frequency").frame(width: 90, alignment: .leading)
                            Slider(value: deEsserFrequency, in: DeEsserConfiguration.frequencyRange, step: 50)
                            Text("\(engine.dynamicsConfiguration.deEsser.frequencyHz, specifier: \"%.0f\") Hz")
                                .monospacedDigit().frame(width: 90)
                        }
                        HStack(spacing: 12) {
                            Text("Threshold").frame(width: 90, alignment: .leading)
                            Slider(value: deEsserThreshold, in: DeEsserConfiguration.thresholdRange, step: 0.5)
                            Text("\(engine.dynamicsConfiguration.deEsser.thresholdDB, specifier: \"%.1f\") dB")
                                .monospacedDigit().frame(width: 80)
                        }
                        Toggle("Dynamic EQ Mode — attenuate only the sibilance band", isOn: deEsserDynamicEQ)
                            .toggleStyle(.switch)
                    }
                    .padding(6)
                }

                GroupBox("3-Band Multiband Compressor") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Multiband Compressor", isOn: multibandEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Low / Mid").frame(width: 90, alignment: .leading)
                            Slider(value: lowMid, in: MultibandCompressorConfiguration.lowMidFrequencyRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.multibandCompressor.lowMidFrequencyHz, specifier: \"%.0f\") Hz")
                                .monospacedDigit().frame(width: 80)
                        }
                        HStack(spacing: 12) {
                            Text("Mid / High").frame(width: 90, alignment: .leading)
                            Slider(value: midHigh, in: MultibandCompressorConfiguration.midHighFrequencyRange, step: 25)
                            Text("\(engine.dynamicsConfiguration.multibandCompressor.midHighFrequencyHz, specifier: \"%.0f\") Hz")
                                .monospacedDigit().frame(width: 80)
                        }
                        Picker("Slope", selection: slope) {
                            ForEach(MultibandSlope.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .frame(maxWidth: 320)
                        thresholdRow("Low threshold", binding: lowThreshold, value: engine.dynamicsConfiguration.multibandCompressor.lowThresholdDB)
                        thresholdRow("Mid threshold", binding: midThreshold, value: engine.dynamicsConfiguration.multibandCompressor.midThresholdDB)
                        thresholdRow("High threshold", binding: highThreshold, value: engine.dynamicsConfiguration.multibandCompressor.highThresholdDB)
                    }
                    .padding(6)
                }

                GroupBox("Realtime Gain Reduction") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                            telemetryRow("De-Esser GR", diagnostics?.deEsserGainReductionDB ?? 0)
                            telemetryRow("Multiband Low GR", diagnostics?.multibandLowGainReductionDB ?? 0)
                            telemetryRow("Multiband Mid GR", diagnostics?.multibandMidGainReductionDB ?? 0)
                            telemetryRow("Multiband High GR", diagnostics?.multibandHighGainReductionDB ?? 0)
                            GridRow {
                                Text("Total DSP latency").foregroundStyle(.secondary)
                                Text("\(diagnostics?.latencyFrames ?? 0) frames")
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                    }
                    .padding(6)
                }

                Text("Acceptance focus: bypass transparency, sibilance-selective reduction, independent band triggering, linked-stereo image stability, click-free toggling, and no change to Reference / Delta / Global Bypass semantics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
    }

    @ViewBuilder
    private func thresholdRow(_ label: String, binding: Binding<Double>, value: Double) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: binding, in: MultibandCompressorConfiguration.thresholdRange, step: 0.5)
            Text("\(value, specifier: \"%.1f\") dB").monospacedDigit().frame(width: 80)
        }
    }

    @ViewBuilder
    private func telemetryRow(_ label: String, _ value: Float) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text("\(value, specifier: \"%.2f\") dB")
        }
    }
}

'''
text = replace_once(text, "@main\nstruct NotchSixtyApp: App {", view + "@main\nstruct NotchSixtyApp: App {", "PR28 validation view")
text = replace_once(
    text,
    '''                PR27ProtectionValidationView(engine: product.audioEngine)\n                    .tabItem { Label("PR27 Protection", systemImage: "waveform.path.ecg") }''',
    '''                PR27ProtectionValidationView(engine: product.audioEngine)\n                    .tabItem { Label("PR27 Protection", systemImage: "waveform.path.ecg") }\n\n                PR28AdvancedDynamicsValidationView(engine: product.audioEngine)\n                    .tabItem { Label("PR28 Advanced Dynamics", systemImage: "waveform.badge.plus") }''',
    "PR28 tab",
)
path.write_text(text)

# --- Deterministic tests ---------------------------------------------------------
path = Path("NotchSixtyTests/DynamicsTests.swift")
text = path.read_text()
tests = r'''

    func testConfiguredDisabledMultibandIsUnityForLR4AndLR8() {
        for topology in [N60CrossoverTopologyLinkwitzRiley24, N60CrossoverTopologyLinkwitzRiley48] {
            var snapshot = N60DynamicsSnapshotMakeBypassed(96_000)
            XCTAssertTrue(N60DynamicsSnapshotSetMultibandCompressor(
                &snapshot, 96_000, false, 120, 3_500, topology, -18, -18, -18
            ))
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)

            for frame in 0..<40_000 {
                let leftIn = Float(0.57 * sin(Double(frame) * 0.071) + 0.11 * cos(Double(frame) * 0.017))
                let rightIn = Float(0.31 * cos(Double(frame) * 0.043) - 0.09 * sin(Double(frame) * 0.013))
                var left = leftIn
                var right = rightIn
                N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
                XCTAssertEqual(left, leftIn, accuracy: 0.000_002)
                XCTAssertEqual(right, rightIn, accuracy: 0.000_002)
            }
        }
    }

    func testDeEsserDynamicEQReducesSibilanceBand() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetDeEsser(&snapshot, sampleRate, true, 6_500, -36, true))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        var inputSquare = 0.0
        var outputSquare = 0.0
        let startMeasure = 24_000
        for frame in 0..<48_000 {
            let input = Float(0.5 * sin(2.0 * Double.pi * 6_500.0 * Double(frame) / sampleRate))
            var left = input
            var right = input * 0.5
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
            if frame >= startMeasure {
                inputSquare += Double(input * input)
                outputSquare += Double(left * left)
            }
        }

        let inputRMS = sqrt(inputSquare / 24_000.0)
        let outputRMS = sqrt(outputSquare / 24_000.0)
        XCTAssertLessThan(outputRMS, inputRMS * 0.9)
        XCTAssertGreaterThan(N60DynamicsRuntimeTelemetry(&runtime).deEsserGainReductionDB, 2.0)
    }

    func testMultibandHighBandCompressionTriggersIndependentlyAndStaysLinked() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetMultibandCompressor(
            &snapshot,
            sampleRate,
            true,
            120,
            3_500,
            N60CrossoverTopologyLinkwitzRiley24,
            0,
            0,
            -30
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        var left: Float = 0
        var right: Float = 0
        for frame in 0..<48_000 {
            let input = Float(0.5 * sin(2.0 * Double.pi * 6_000.0 * Double(frame) / sampleRate))
            left = input
            right = input * 0.5
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
        }

        let telemetry = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertGreaterThan(telemetry.multibandHighGainReductionDB, 2.0)
        XCTAssertLessThan(telemetry.multibandLowGainReductionDB, 0.05)
        XCTAssertLessThan(telemetry.multibandMidGainReductionDB, 0.05)
        if abs(right) > 0.000_01 {
            XCTAssertEqual(left / right, 2.0, accuracy: 0.001)
        }
    }

    func testPR28ConfigurationRejectsOutOfRangeControls() {
        var config = DynamicsConfiguration()
        config.deEsser.frequencyHz = 1_999
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))

        config = DynamicsConfiguration()
        config.multibandCompressor.lowMidFrequencyHz = 300
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))

        config = DynamicsConfiguration()
        config.multibandCompressor.highThresholdDB = 1
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))
    }

    func testKernelGlobalBypassOverridesPR28Dynamics() throws {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        var dynamics = N60DynamicsSnapshotMakeBypassed(96_000)
        XCTAssertTrue(N60DynamicsSnapshotSetDeEsser(&dynamics, 96_000, true, 6_500, -50, true))
        XCTAssertTrue(N60DynamicsSnapshotSetMultibandCompressor(
            &dynamics, 96_000, true, 120, 3_500,
            N60CrossoverTopologyLinkwitzRiley48, -40, -40, -40
        ))
        graph.dynamics = dynamics
        graph.bypassed = true
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for _ in 0..<4_000 {
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, 0.5, -0.25, &left, &right)
            XCTAssertEqual(left, 0.5, accuracy: 0.000_001)
            XCTAssertEqual(right, -0.25, accuracy: 0.000_001)
        }
    }
'''
if not text.rstrip().endswith("}"):
    raise RuntimeError("DynamicsTests.swift class closing brace not found")
text = text.rstrip()[:-1] + tests + "\n}\n"
path.write_text(text)

# --- Permanent architecture / provenance docs ----------------------------------
doc = Path("docs/ADVANCED_DYNAMICS_PR28.md")
doc.write_text('''# PR28 Advanced Dynamics — De-Esser and Multiband Compressor\n\n## Scope\n\nPR28 adds independently authored realtime De-Esser and three-band Multiband Compressor processing to the commercial `N60Dynamics` engine. The observable parity contract is limited to documented user-facing legacy behavior; no legacy implementation or inherited tests are used.\n\n## Signal order\n\nWithin the existing zero-latency core dynamics stage:\n\n`De-Esser -> 3-band Multiband Compressor -> Wideband Compressor -> Expander`\n\nPR27 protection remains later in the graph, and Pause Gate remains after protection. Reference/Delta latency semantics are unchanged because PR28 adds no algorithmic delay.\n\n## De-Esser\n\nProduct controls: 2–10 kHz center frequency, −60–0 dB threshold, enable, and Dynamic-EQ mode. A linked-stereo sidechain is built from precomputed high-pass and low-pass biquads around the selected center. Dynamic-EQ mode applies time-varying attenuation only to that extracted component; full-band mode applies the same linked gain to the whole signal. Attack/release and ratio are commercial implementation constants for this parity slice rather than undocumented user controls.\n\n## Multiband Compressor\n\nProduct controls: enable, 40–250 Hz Low/Mid crossover, 1–8 kHz Mid/High crossover, independent Low/Mid/High thresholds, and LR4/LR8 slope selection. Low and high outer bands use precomputed Linkwitz-Riley legs from the commercial crossover primitives. The mid band is defined as the residual complement (`dry - low - high`), which makes recombination sample-exact at unity gain and avoids a hidden bypass coloration/gain change. Each band uses linked-stereo detection and independent gain smoothing.\n\n## Realtime contract\n\nAll coefficient design occurs on the control plane. The render callback uses fixed-size state only: no allocation/free, locks, logging, I/O, asynchronous work, or filter design.\n\n## Acceptance gates\n\n- configured-disabled LR4 and LR8 multiband paths recombine to unity;\n- de-esser produces measurable reduction in the configured sibilance region;\n- multiband bands trigger independently and preserve linked-stereo image;\n- invalid product ranges are rejected;\n- Global Bypass remains raw;\n- no added latency;\n- hardware pass checks bypass transparency, toggling, imaging, and audible artifacts.\n''')

path = Path("docs/PROVENANCE.md")
text = path.read_text().rstrip()
entry = '''\n\n## PR28 — De-Esser and Multiband Compressor\n\n- **Classification:** independent commercial rewrite.\n- **Behavioral references:** documented user-visible legacy control names/ranges and observable stage ordering only.\n- **Implementation sources:** current proprietary `N60Dynamics`, `N60Biquad`, and `N60Crossover` primitives; standard feed-forward dynamics and digital-filter mathematics independently implemented for this repository.\n- **Legacy implementation reuse:** none. No legacy DSP source, inherited test vectors, or historical implementation structure was copied or adapted.\n- **Architecture review:** fixed-size realtime state, control-plane coefficient preparation, zero added algorithmic latency, linked-stereo detection, exact-unity residual multiband recombination at 0 dB band gains.\n- **Validation:** deterministic tests plus focused hardware/listening acceptance before merge.\n'''
if "## PR28 — De-Esser and Multiband Compressor" not in text:
    text += entry
path.write_text(text + "\n")
