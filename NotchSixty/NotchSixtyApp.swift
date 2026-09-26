import Combine
import SwiftUI

struct ProductDSPConfiguration: Equatable, Sendable {
    var eq: EQConfiguration
    var stereoEQ: StereoEQConfiguration
    var playback: PlaybackControlConfiguration
    var gain: DSPGainConfiguration
    var bassManagement: BassManagementConfiguration
    var dynamics: DynamicsConfiguration
    var roomCorrection: RoomCorrectionConfiguration

    init(
        eq: EQConfiguration = EQConfiguration(),
        stereoEQ: StereoEQConfiguration = StereoEQConfiguration(),
        playback: PlaybackControlConfiguration = PlaybackControlConfiguration(),
        gain: DSPGainConfiguration = DSPGainConfiguration(),
        bassManagement: BassManagementConfiguration = BassManagementConfiguration(),
        dynamics: DynamicsConfiguration = DynamicsConfiguration(),
        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration()
    ) {
        self.eq = eq
        self.stereoEQ = stereoEQ
        self.playback = playback
        self.gain = gain
        self.bassManagement = bassManagement
        self.dynamics = dynamics
        self.roomCorrection = roomCorrection
    }
}

struct ProductConfiguration: Equatable, Sendable {
    static let currentSchemaVersion = 6

    var schemaVersion: Int
    var selectedOutputUID: String?
    var masterVolume: MasterVolumeConfiguration
    var dsp: ProductDSPConfiguration

    init(
        schemaVersion: Int = ProductConfiguration.currentSchemaVersion,
        selectedOutputUID: String? = nil,
        masterVolume: MasterVolumeConfiguration = MasterVolumeConfiguration(),
        dsp: ProductDSPConfiguration = ProductDSPConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.selectedOutputUID = selectedOutputUID
        self.masterVolume = masterVolume
        self.dsp = dsp
    }
}

/// Product-level ownership boundary for application state and services.
///
/// `AudioIOEngine` remains the transport/DSP execution controller. Product-facing
/// configuration is exposed here as a compact snapshot so persistence, presets,
/// and the production UI can grow without turning the transport engine into a
/// replacement for the historical monolithic application store.
@MainActor
final class ProductController: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    let audioEngine: AudioIOEngine
    private var audioEngineObservation: AnyCancellable?

    init() {
        self.audioEngine = AudioIOEngine()
        observeAudioEngine()
    }

    init(audioEngine: AudioIOEngine) {
        self.audioEngine = audioEngine
        observeAudioEngine()
    }

    var configuration: ProductConfiguration {
        ProductConfiguration(
            selectedOutputUID: audioEngine.routeConfiguration.selectedOutputUID,
            masterVolume: audioEngine.masterVolumeConfiguration,
            dsp: ProductDSPConfiguration(
                eq: audioEngine.eqConfiguration,
                stereoEQ: audioEngine.stereoEQConfiguration,
                playback: audioEngine.playbackControlConfiguration,
                gain: audioEngine.gainConfiguration,
                bassManagement: audioEngine.bassManagementConfiguration,
                dynamics: audioEngine.dynamicsConfiguration,
                roomCorrection: audioEngine.roomCorrectionConfiguration
            )
        )
    }

    func prepareForUse() {
        audioEngine.prepareForUse()
    }

    func shutdownForTermination() {
        audioEngine.shutdownForTermination()
    }

    private func observeAudioEngine() {
        audioEngineObservation = audioEngine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

private struct PR27ProtectionValidationView: View {
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
        let oversampling = dynamicsBinding(\.oversampling)
        let clipperEnabled = dynamicsBinding(\.softClipper.enabled)
        let clipperDrive = dynamicsBinding(\.softClipper.driveDB)
        let clipperThreshold = dynamicsBinding(\.softClipper.thresholdDB)
        let clipperCurve = dynamicsBinding(\.softClipper.curve)
        let clipperAutoGain = dynamicsBinding(\.softClipper.autoCompensateGain)
        let limiterEnabled = dynamicsBinding(\.limiter.enabled)
        let limiterCeiling = dynamicsBinding(\.limiter.ceilingDB)
        let limiterAttack = dynamicsBinding(\.limiter.attackMs)
        let limiterRelease = dynamicsBinding(\.limiter.releaseMs)
        let limiterLookAhead = dynamicsBinding(\.limiter.lookAheadMs)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR27 Protection / Oversampling Validation")
                    .font(.title2.bold())

                Text("Hardware validation surface for the oversampling, soft-clipper, true-peak detector, and limiter paths. Use this tab for the PR27 acceptance pass.")
                    .foregroundStyle(.secondary)

                GroupBox("Oversampling") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Factor", selection: oversampling) {
                            ForEach(OversamplingFactor.allCases) { factor in
                                Text(factor.displayName).tag(factor)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        Text("Compare 1×, 2×, and 4× with the clipper and limiter disabled first. There should be no material level change; the historical 4× attenuation bug is a release blocker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Soft Clipper") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Soft Clipper", isOn: clipperEnabled)
                            .toggleStyle(.switch)

                        HStack(spacing: 12) {
                            Text("Drive").frame(width: 90, alignment: .leading)
                            Slider(value: clipperDrive, in: SoftClipperConfiguration.driveRange, step: 0.5)
                            Text("\(engine.dynamicsConfiguration.softClipper.driveDB, specifier: "%.1f") dB")
                                .monospacedDigit().frame(width: 72)
                        }

                        HStack(spacing: 12) {
                            Text("Threshold").frame(width: 90, alignment: .leading)
                            Slider(value: clipperThreshold, in: SoftClipperConfiguration.thresholdRange, step: 0.1)
                            Text("\(engine.dynamicsConfiguration.softClipper.thresholdDB, specifier: "%.1f") dB")
                                .monospacedDigit().frame(width: 72)
                        }

                        HStack(spacing: 12) {
                            Picker("Curve", selection: clipperCurve) {
                                ForEach(SoftClipperCurve.allCases) { curve in
                                    Text(curve.displayName).tag(curve)
                                }
                            }
                            .frame(width: 260)

                            Toggle("Auto gain compensation", isOn: clipperAutoGain)
                                .toggleStyle(.switch)
                        }
                    }
                    .padding(6)
                }

                GroupBox("True-Peak Limiter") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable TP Limiter", isOn: limiterEnabled)
                            .toggleStyle(.switch)

                        HStack(spacing: 12) {
                            Text("Ceiling").frame(width: 90, alignment: .leading)
                            Slider(value: limiterCeiling, in: LimiterConfiguration.ceilingRange, step: 0.1)
                            Text("\(engine.dynamicsConfiguration.limiter.ceilingDB, specifier: "%.1f") dBTP")
                                .monospacedDigit().frame(width: 82)
                        }

                        HStack(spacing: 12) {
                            Text("Look-ahead").frame(width: 90, alignment: .leading)
                            Slider(value: limiterLookAhead, in: LimiterConfiguration.lookAheadRange, step: 0.1)
                            Text("\(engine.dynamicsConfiguration.limiter.lookAheadMs, specifier: "%.1f") ms")
                                .monospacedDigit().frame(width: 72)
                        }

                        HStack(spacing: 12) {
                            Text("Attack").frame(width: 90, alignment: .leading)
                            Slider(value: limiterAttack, in: LimiterConfiguration.attackRange, step: 0.1)
                            Text("\(engine.dynamicsConfiguration.limiter.attackMs, specifier: "%.1f") ms")
                                .monospacedDigit().frame(width: 72)
                        }

                        HStack(spacing: 12) {
                            Text("Release").frame(width: 90, alignment: .leading)
                            Slider(value: limiterRelease, in: LimiterConfiguration.releaseRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.limiter.releaseMs, specifier: "%.0f") ms")
                                .monospacedDigit().frame(width: 72)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Realtime Protection Telemetry") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                            telemetryRow("Requested oversampling", oversamplingName(diagnostics?.oversamplingFactor ?? N60OversamplingFactor1x))
                            telemetryRow("Effective oversampling", oversamplingName(diagnostics?.effectiveOversamplingFactor ?? N60OversamplingFactor1x))
                            telemetryRow("Soft clipper", (diagnostics?.softClipperEnabled ?? false) ? "enabled" : "bypassed")
                            telemetryRow("TP limiter", (diagnostics?.limiterEnabled ?? false) ? "enabled" : "bypassed")
                            telemetryRow("Input true peak", formattedLevel(diagnostics?.inputTruePeakLinear ?? 0))
                            telemetryRow("Output true peak", formattedLevel(diagnostics?.outputTruePeakLinear ?? 0))
                            telemetryRow("Limiter gain reduction", String(format: "%.2f dB", diagnostics?.limiterGainReductionDB ?? 0))
                            telemetryRow("Limiter safety clamps", "\(diagnostics?.limiterSafetyClampSamples ?? 0)")
                            if let diagnostics {
                                telemetryRow("Total DSP latency", formattedLatency(frames: diagnostics.latencyFrames, sampleRate: diagnostics.sampleRate))
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    }
                    .padding(6)
                }

                Text("Test order: protection disabled at 1× → 2× → 4×; then soft clipper; then TP limiter. Also verify Processed / Reference / Delta and Global Bypass from the Main Validation tab after changing latency-producing settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
    }

    @ViewBuilder
    private func telemetryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func oversamplingName(_ factor: N60OversamplingFactor) -> String {
        switch factor {
        case N60OversamplingFactor4x: return "4×"
        case N60OversamplingFactor2x: return "2×"
        default: return "1×"
        }
    }

    private func formattedLevel(_ linear: Float) -> String {
        guard linear > 0 else { return "−∞ dBFS" }
        return String(format: "%.2f dBFS", 20.0 * log10(Double(linear)))
    }

    private func formattedLatency(frames: UInt32, sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "\(frames) frames" }
        return String(format: "%u frames / %.3f ms", frames, Double(frames) / sampleRate * 1_000.0)
    }
}


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
        let dcEnabled = dynamicsBinding(\.dcOffsetFilter.enabled)
        let infrasonicEnabled = dynamicsBinding(\.infrasonicFilter.enabled)
        let infrasonicCutoff = dynamicsBinding(\.infrasonicFilter.cutoffHz)
        let infrasonicSlope = dynamicsBinding(\.infrasonicFilter.slope)
        let contourEnabled = dynamicsBinding(\.loudnessContour.enabled)
        let contourStrength = dynamicsBinding(\.loudnessContour.strength)
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


                GroupBox("Signal Conditioning") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("DC Offset Filter (0.5 Hz)", isOn: dcEnabled).toggleStyle(.switch)
                        Toggle("Infrasonic Filter", isOn: infrasonicEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Cutoff").frame(width: 90, alignment: .leading)
                            Slider(value: infrasonicCutoff, in: InfrasonicFilterConfiguration.cutoffRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.infrasonicFilter.cutoffHz, specifier: "%.0f") Hz")
                                .monospacedDigit().frame(width: 80)
                        }
                        Picker("Slope", selection: infrasonicSlope) {
                            ForEach(InfrasonicSlope.allCases) { value in Text(value.displayName).tag(value) }
                        }.frame(maxWidth: 320)
                        Divider()
                        Toggle("Loudness Contour", isOn: contourEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Strength").frame(width: 90, alignment: .leading)
                            Slider(value: contourStrength, in: LoudnessContourConfiguration.strengthRange, step: 0.05)
                            Text("\(engine.dynamicsConfiguration.loudnessContour.strength, specifier: "%.2f")")
                                .monospacedDigit().frame(width: 70)
                        }
                    }.padding(6)
                }

                GroupBox("De-Esser") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable De-Esser", isOn: deEsserEnabled).toggleStyle(.switch)
                        HStack(spacing: 12) {
                            Text("Frequency").frame(width: 90, alignment: .leading)
                            Slider(value: deEsserFrequency, in: DeEsserConfiguration.frequencyRange, step: 50)
                            Text("\(engine.dynamicsConfiguration.deEsser.frequencyHz, specifier: "%.0f") Hz")
                                .monospacedDigit().frame(width: 90)
                        }
                        HStack(spacing: 12) {
                            Text("Threshold").frame(width: 90, alignment: .leading)
                            Slider(value: deEsserThreshold, in: DeEsserConfiguration.thresholdRange, step: 0.5)
                            Text("\(engine.dynamicsConfiguration.deEsser.thresholdDB, specifier: "%.1f") dB")
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
                            Text("\(engine.dynamicsConfiguration.multibandCompressor.lowMidFrequencyHz, specifier: "%.0f") Hz")
                                .monospacedDigit().frame(width: 80)
                        }
                        HStack(spacing: 12) {
                            Text("Mid / High").frame(width: 90, alignment: .leading)
                            Slider(value: midHigh, in: MultibandCompressorConfiguration.midHighFrequencyRange, step: 25)
                            Text("\(engine.dynamicsConfiguration.multibandCompressor.midHighFrequencyHz, specifier: "%.0f") Hz")
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
            Text("\(value, specifier: "%.1f") dB").monospacedDigit().frame(width: 80)
        }
    }

    @ViewBuilder
    private func telemetryRow(_ label: String, _ value: Float) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text("\(value, specifier: "%.2f") dB")
        }
    }
}


private struct PR30PhaseTimeValidationView: View {
    @ObservedObject var engine: AudioIOEngine

    private var delayBinding: Binding<Double> {
        Binding(
            get: { engine.playbackControlConfiguration.interChannelDelayMs },
            set: { try? engine.setInterChannelDelayMs($0) }
        )
    }

    private var phaseModeBinding: Binding<EQPhaseMode> {
        Binding(
            get: { engine.stereoEQConfiguration.phaseMode },
            set: { try? engine.setEQPhaseMode($0) }
        )
    }

    private var allPassBands: [EQBand] {
        engine.stereoEQConfiguration.editableBands.filter { $0.type == .allPass }
    }

    private func bandDoubleBinding(_ source: EQBand, _ keyPath: WritableKeyPath<EQBand, Double>) -> Binding<Double> {
        Binding(
            get: {
                engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id })?[keyPath: keyPath]
                    ?? source[keyPath: keyPath]
            },
            set: { value in
                guard var updated = engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id }) else { return }
                updated[keyPath: keyPath] = value
                try? engine.updateEQBand(updated)
            }
        )
    }

    private func bandEnabledBinding(_ source: EQBand) -> Binding<Bool> {
        Binding(
            get: {
                engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id })?.enabled ?? source.enabled
            },
            set: { value in
                guard var updated = engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id }) else { return }
                updated.enabled = value
                try? engine.updateEQBand(updated)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR30 Phase / Time Alignment Validation")
                    .font(.title2.bold())

                Text("Focused hardware validation for the new phase-only All-Pass EQ and signed fractional inter-channel timing alignment.")
                    .foregroundStyle(.secondary)

                GroupBox("All-Pass EQ") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("EQ Phase Mode", selection: phaseModeBinding) {
                            ForEach(EQPhaseMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        HStack {
                            Button("Add All-Pass Test Band") {
                                try? engine.setEQPhaseMode(.minimumPhase)
                                try? engine.addEQBand(
                                    EQBand(type: .allPass, frequencyHz: 1_000, gainDB: 0, q: 0.707)
                                )
                            }
                            Button("Remove All-Pass Bands") {
                                let ids = allPassBands.map(\.id)
                                for id in ids { try? engine.removeEQBand(id: id) }
                            }
                            .disabled(allPassBands.isEmpty)
                        }

                        Text("All-Pass is intentionally available only in Minimum phase/IIR mode. It rotates phase/group delay while preserving steady-state magnitude.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if allPassBands.isEmpty {
                            Text("No All-Pass bands yet. Add one above for the PR30 listening test.")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(allPassBands) { band in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle("Enabled", isOn: bandEnabledBinding(band))
                                        .toggleStyle(.switch)
                                    Spacer()
                                    Button("Remove") { try? engine.removeEQBand(id: band.id) }
                                }

                                HStack(spacing: 12) {
                                    Text("Frequency").frame(width: 90, alignment: .leading)
                                    Slider(value: bandDoubleBinding(band, \.frequencyHz), in: 20...20_000, step: 10)
                                    Text("\(engine.stereoEQConfiguration.editableBands.first(where: { $0.id == band.id })?.frequencyHz ?? band.frequencyHz, specifier: "%.0f") Hz")
                                        .monospacedDigit().frame(width: 92)
                                }

                                HStack(spacing: 12) {
                                    Text("Q").frame(width: 90, alignment: .leading)
                                    Slider(value: bandDoubleBinding(band, \.q), in: 0.10...20.0, step: 0.01)
                                    Text("\(engine.stereoEQConfiguration.editableBands.first(where: { $0.id == band.id })?.q ?? band.q, specifier: "%.2f")")
                                        .monospacedDigit().frame(width: 72)
                                }
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    .padding(6)
                }

                GroupBox("Fractional Inter-Channel Delay") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("Delay L").foregroundStyle(.secondary)
                            Slider(
                                value: delayBinding,
                                in: PlaybackControlConfiguration.interChannelDelayRange,
                                step: 0.01
                            )
                            Text("Delay R").foregroundStyle(.secondary)
                            Text("\(engine.playbackControlConfiguration.interChannelDelayMs, specifier: "%+.2f") ms")
                                .monospacedDigit().frame(width: 84, alignment: .trailing)
                        }

                        HStack {
                            Button("Reset to 0.00 ms") { try? engine.setInterChannelDelayMs(0) }
                            Text("Negative values delay Left; positive values delay Right. Zero is transparent.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("The fractional stage uses phase-preserving all-pass interpolation with a tiny common alignment delay when active, rather than amplitude-interpolating between adjacent samples.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Realtime Alignment Telemetry") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                            GridRow {
                                Text("Published L/R delay").foregroundStyle(.secondary)
                                Text("\(diagnostics?.interChannelDelayMs ?? 0, specifier: "%+.3f") ms")
                            }
                            GridRow {
                                Text("Alignment latency").foregroundStyle(.secondary)
                                Text("\(diagnostics?.interChannelAlignmentLatencyFrames ?? 0) frames")
                            }
                            GridRow {
                                Text("Total DSP latency").foregroundStyle(.secondary)
                                Text("\(diagnostics?.latencyFrames ?? 0) frames")
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    }
                    .padding(6)
                }

                Text("Acceptance focus: All-Pass should alter phase/spatial behavior without an obvious level or tonal shift; ± delay should move the appropriate channel; 0.00 ms should return to transparent behavior; changes should remain click-free. Also verify Processed / Reference / Delta and Global Bypass after exercising both stages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
    }
}


private struct PR31NoiseHumValidationView: View {
    @ObservedObject var engine: AudioIOEngine
    @State private var mainsDiagnostics: RenderKernelDiagnostics?
    private let trackingTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private func mainsBinding<Value>(_ keyPath: WritableKeyPath<MainsNotchConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch[keyPath: keyPath] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var regionBinding: Binding<MainsRegion> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.region },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.selectRegion(value)
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var trackingBinding: Binding<Bool> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.continuousTracking },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.continuousTracking = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var harmonicCountBinding: Binding<Double> {
        Binding(
            get: { Double(engine.dynamicsConfiguration.mainsNotch.harmonicCount) },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.harmonicCount = Int(value.rounded())
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private func harmonicDepthBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.harmonicDepthsDB[index] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.harmonicDepthsDB[index] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    var body: some View {
        let enabled = mainsBinding(\.enabled)
        let region = regionBinding
        let q = mainsBinding(\.q)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR31 Noise / Hum Validation")
                    .font(.title2.bold())
                Text("PR31 Slice 2 adds independent mains-frequency detection, confidence telemetry, one-shot Detect, and bounded Continuous Tracking with click-safe notch retuning. Spectral denoising follows below in Slice 3.")
                    .foregroundStyle(.secondary)

                GroupBox("Mains Hum Notch") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Mains Hum Notch", isOn: enabled).toggleStyle(.switch)

                        Picker("Region", selection: region) {
                            ForEach(MainsRegion.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)

                        HStack(spacing: 12) {
                            Text("Harmonics").frame(width: 90, alignment: .leading)
                            Slider(value: harmonicCountBinding, in: 1...16, step: 1)
                            Text("\(engine.dynamicsConfiguration.mainsNotch.harmonicCount)")
                                .monospacedDigit().frame(width: 36)
                        }

                        HStack(spacing: 12) {
                            Text("Q").frame(width: 90, alignment: .leading)
                            Slider(value: q, in: MainsNotchConfiguration.qRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.mainsNotch.q, specifier: "%.0f")")
                                .monospacedDigit().frame(width: 48)
                        }

                        Divider()
                        Text("Per-harmonic depth")
                            .font(.subheadline.bold())
                        ForEach(0..<engine.dynamicsConfiguration.mainsNotch.harmonicCount, id: \.self) { index in
                            HStack(spacing: 12) {
                                let frequency = engine.dynamicsConfiguration.mainsNotch.fundamentalHz * Double(index + 1)
                                Text("H\(index + 1)  \(frequency, specifier: "%.0f") Hz")
                                    .frame(width: 105, alignment: .leading)
                                Slider(value: harmonicDepthBinding(index), in: MainsNotchConfiguration.depthRange, step: 1)
                                Text("\(engine.dynamicsConfiguration.mainsNotch.harmonicDepthsDB[index], specifier: "%.0f") dB")
                                    .monospacedDigit().frame(width: 70)
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("Detection / Tracking") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Button("Detect") {
                                _ = try? engine.applyDetectedMainsHum()
                                mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                            }
                            Toggle("Continuous Tracking", isOn: trackingBinding).toggleStyle(.switch)
                        }
                        let detected = mainsDiagnostics?.mainsDetectedFrequencyHz ?? 0
                        let confidence = mainsDiagnostics?.mainsDetectionConfidence ?? 0
                        Text("Detected: \(detected, specifier: "%.2f") Hz   Confidence: \(confidence * 100, specifier: "%.0f")%")
                            .monospacedDigit()
                        Text("Active notch fundamental: \(engine.dynamicsConfiguration.mainsNotch.fundamentalHz, specifier: "%.2f") Hz")
                            .monospacedDigit()
                        Text("Detector searches ±3 Hz around the selected 50/60 Hz region. One-shot Detect applies the latest confident estimate; Continuous Tracking only republishes bounded, confident changes and the realtime notch crossfades old/new coefficients.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Spectral Denoising") {
                    Text("Natural / Standard / Aggressive / Dehiss presets, profile Capture / Reset, protected-frequency range, and Quality / High / Ultra modes are the following PR31 slice.")
                        .foregroundStyle(.secondary)
                        .padding(6)
                }

                Text("Acceptance focus for this slice: with the filter disabled the path must be transparent; with it enabled, a 50/60 Hz tone and selected harmonics should fall by the configured depth without broad tonal loss. Toggle and parameter changes must remain stable and click-free enough for interactive validation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
        .onAppear { mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics }
        .onReceive(trackingTimer) { _ in
            mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
            engine.pollMainsHumTracking()
        }
    }
}

@main
struct NotchSixtyApp: App {
    @StateObject private var product = ProductController()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(engine: product.audioEngine)
                    .tabItem { Label("Main Validation", systemImage: "slider.horizontal.3") }

                PR27ProtectionValidationView(engine: product.audioEngine)
                    .tabItem { Label("PR27 Protection", systemImage: "waveform.path.ecg") }

                PR28AdvancedDynamicsValidationView(engine: product.audioEngine)
                    .tabItem { Label("PR28 Advanced Dynamics", systemImage: "waveform.badge.plus") }

                PR30PhaseTimeValidationView(engine: product.audioEngine)
                    .tabItem { Label("PR30 Phase / Time", systemImage: "timeline.selection") }

                PR31NoiseHumValidationView(engine: product.audioEngine)
                    .tabItem { Label("PR31 Noise / Hum", systemImage: "waveform.slash") }
            }
        }
    }
}
