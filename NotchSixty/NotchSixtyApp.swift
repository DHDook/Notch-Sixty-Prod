import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct ProductDSPConfiguration: Equatable, Sendable {
    var eq: EQConfiguration
    var stereoEQ: StereoEQConfiguration
    var playback: PlaybackControlConfiguration
    var gain: DSPGainConfiguration
    var bassManagement: BassManagementConfiguration
    var dynamics: DynamicsConfiguration
    var roomCorrection: RoomCorrectionConfiguration
    var speakerIR: SpeakerIRConfiguration

    init(
        eq: EQConfiguration = EQConfiguration(),
        stereoEQ: StereoEQConfiguration = StereoEQConfiguration(),
        playback: PlaybackControlConfiguration = PlaybackControlConfiguration(),
        gain: DSPGainConfiguration = DSPGainConfiguration(),
        bassManagement: BassManagementConfiguration = BassManagementConfiguration(),
        dynamics: DynamicsConfiguration = DynamicsConfiguration(),
        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration(),
        speakerIR: SpeakerIRConfiguration = SpeakerIRConfiguration()
    ) {
        self.eq = eq
        self.stereoEQ = stereoEQ
        self.playback = playback
        self.gain = gain
        self.bassManagement = bassManagement
        self.dynamics = dynamics
        self.roomCorrection = roomCorrection
        self.speakerIR = speakerIR
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
    let profiles: ProductProfileController
    let calibration: RoomCorrectionCalibrationController
    let multichannelCalibration: MultichannelCalibrationController
    let roomCorrectionProjects: RoomCorrectionProjectController
    private var audioEngineObservation: AnyCancellable?
    private var calibrationObservation: AnyCancellable?
    private var multichannelCalibrationObservation: AnyCancellable?

    init() {
        let audioEngine = AudioIOEngine()
        let profiles = ProductProfileController(engine: audioEngine)
        let calibration = RoomCorrectionCalibrationController(engine: audioEngine)
        self.audioEngine = audioEngine
        self.profiles = profiles
        self.calibration = calibration
        self.multichannelCalibration = MultichannelCalibrationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration
        )
        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)
        observeAudioEngine()
    }

    init(audioEngine: AudioIOEngine) {
        let profiles = ProductProfileController(engine: audioEngine)
        let calibration = RoomCorrectionCalibrationController(engine: audioEngine)
        self.audioEngine = audioEngine
        self.profiles = profiles
        self.calibration = calibration
        self.multichannelCalibration = MultichannelCalibrationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration
        )
        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)
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
                roomCorrection: audioEngine.roomCorrectionConfiguration,
                speakerIR: audioEngine.speakerIRConfiguration
            )
        )
    }

    func prepareForUse() {
        audioEngine.prepareForUse()
        profiles.restoreSelectedLayers()
        roomCorrectionProjects.prepareForUse()
        calibration.prepareForUse()
        multichannelCalibration.prepareForUse()
    }

    func shutdownForTermination() {
        multichannelCalibration.cancelMeasurement()
        calibration.cancelMeasurement()
        audioEngine.shutdownForTermination()
    }

    private func observeAudioEngine() {
        audioEngineObservation = audioEngine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        calibrationObservation = calibration.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        multichannelCalibrationObservation = multichannelCalibration.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

#if DEBUG
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
                    TimelineView(.periodic(from: .now, by: engine.lifecycleState == .running ? 1.0 : 3_600.0)) { _ in
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
                    TimelineView(.periodic(from: .now, by: engine.lifecycleState == .running ? 1.0 : 3_600.0)) { _ in
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
                    TimelineView(.periodic(from: .now, by: engine.lifecycleState == .running ? 1.0 : 3_600.0)) { _ in
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
    private let trackingTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

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

    private var denoiserEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.dynamicsConfiguration.spectralDenoiser.enabled },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.spectralDenoiser.enabled = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var denoiserPresetBinding: Binding<SpectralDenoiserPreset> {
        Binding(
            get: { engine.dynamicsConfiguration.spectralDenoiser.preset },
            set: { value in try? engine.applySpectralDenoiserPreset(value) }
        )
    }

    private func denoiserBinding<Value>(
        _ keyPath: WritableKeyPath<SpectralDenoiserConfiguration, Value>,
        marksCustom: Bool = true
    ) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration.spectralDenoiser[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.spectralDenoiser[keyPath: keyPath] = value
                if marksCustom { updated.spectralDenoiser.markCustom() }
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
                Text("PR31 now includes mains-frequency detection/tracking plus the new clean-room spectral denoiser. The denoiser is deliberately conservative: linked-stereo WOLA processing, threshold-gated adaptive learning, explicit noise Capture, protected bands, and measurable latency.")
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
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Spectral Denoiser", isOn: denoiserEnabledBinding)
                            .toggleStyle(.switch)

                        Picker("Preset", selection: denoiserPresetBinding) {
                            ForEach(SpectralDenoiserPreset.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Text("Reduction").frame(width: 105, alignment: .leading)
                            Slider(value: denoiserBinding(\.reductionAmount), in: SpectralDenoiserConfiguration.reductionRange, step: 0.01)
                            Text("\(engine.dynamicsConfiguration.spectralDenoiser.reductionAmount * 100, specifier: "%.0f")%")
                                .monospacedDigit().frame(width: 58)
                        }

                        HStack(spacing: 12) {
                            Text("Threshold").frame(width: 105, alignment: .leading)
                            Slider(value: denoiserBinding(\.thresholdDBFS), in: SpectralDenoiserConfiguration.thresholdRange, step: 1)
                            Text("\(engine.dynamicsConfiguration.spectralDenoiser.thresholdDBFS, specifier: "%.0f") dBFS")
                                .monospacedDigit().frame(width: 78)
                        }

                        Picker("Quality", selection: denoiserBinding(\.quality)) {
                            ForEach(SpectralDenoiserQuality.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)

                        Toggle("Protect Frequency Range", isOn: denoiserBinding(\.protectedRangeEnabled))
                            .toggleStyle(.switch)

                        if engine.dynamicsConfiguration.spectralDenoiser.protectedRangeEnabled {
                            let rate = mainsDiagnostics?.sampleRate ?? 48_000
                            let maximum = max(200.0, min(20_000.0, rate * 0.5 - 1.0))
                            HStack(spacing: 12) {
                                Text("Protected Low").frame(width: 105, alignment: .leading)
                                Slider(value: denoiserBinding(\.protectedLowHz), in: 0...maximum, step: 10)
                                Text("\(engine.dynamicsConfiguration.spectralDenoiser.protectedLowHz, specifier: "%.0f") Hz")
                                    .monospacedDigit().frame(width: 78)
                            }
                            HStack(spacing: 12) {
                                Text("Protected High").frame(width: 105, alignment: .leading)
                                Slider(value: denoiserBinding(\.protectedHighHz), in: 0...maximum, step: 10)
                                Text("\(engine.dynamicsConfiguration.spectralDenoiser.protectedHighHz, specifier: "%.0f") Hz")
                                    .monospacedDigit().frame(width: 78)
                            }
                        }

                        Divider()
                        HStack(spacing: 12) {
                            Button("Capture Noise Profile") { try? engine.captureSpectralNoiseProfile() }
                            Button("Reset Profile") { try? engine.resetSpectralNoiseProfile() }
                        }
                        Text("Capture listens for about one second. Use a noise-only passage if possible. Reset returns to conservative adaptive learning. Learned profile/configuration state is preserved while bypassed; ordinary disabled playback parks the spectral FFT path until the denoiser or an explicit profile capture is enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Denoiser Telemetry") {
                    let diagnostics = mainsDiagnostics
                    let status: String = {
                        if diagnostics?.denoiserCaptureActive == true { return "Capturing" }
                        if diagnostics?.denoiserCapturedProfile == true { return "Captured Profile" }
                        if diagnostics?.denoiserProfileReady == true { return "Adaptive Ready" }
                        return "Learning"
                    }()
                    let rate = diagnostics?.sampleRate ?? 0
                    let denoiserFrames = diagnostics?.denoiserLatencyFrames ?? 0
                    let denoiserMS = rate > 0 ? Double(denoiserFrames) * 1000.0 / rate : 0
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        GridRow { Text("Profile state").foregroundStyle(.secondary); Text(status) }
                        GridRow { Text("Capture progress").foregroundStyle(.secondary); Text("\((diagnostics?.denoiserCaptureProgress ?? 0) * 100, specifier: "%.0f")%") }
                        GridRow { Text("Estimated noise").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserEstimatedNoiseDBFS ?? -120, specifier: "%.1f") dBFS") }
                        GridRow { Text("Mean suppression").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserMeanSuppressionDB ?? 0, specifier: "%.2f") dB") }
                        GridRow { Text("Max suppression").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserMaxSuppressionDB ?? 0, specifier: "%.2f") dB") }
                        GridRow { Text("FFT / hop").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserFFTSize ?? 0) / \(diagnostics?.denoiserHopSize ?? 0) frames") }
                        GridRow { Text("Denoiser latency").foregroundStyle(.secondary); Text("\(denoiserFrames) frames  (\(denoiserMS, specifier: "%.2f") ms)") }
                        GridRow { Text("Total DSP latency").foregroundStyle(.secondary); Text("\(diagnostics?.latencyFrames ?? 0) frames") }
                        GridRow { Text("Spectral frames").foregroundStyle(.secondary); Text("\(diagnostics?.denoiserSpectralFramesProcessed ?? 0)") }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                }

                Text("Denoiser acceptance focus: start with Natural or Standard. Listen for real noise-floor reduction without pumping, chirping/musical-noise artifacts, softened transients, vocal smearing, or stereo-image movement. Compare Capture against adaptive learning, exercise the protected range, and compare Quality / High / Ultra. Reference and Delta must remain latency aligned. Aggressive is intentionally the stress case, not the default recommendation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
        .onAppear { mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics }
        .onReceive(trackingTimer) { _ in
            guard engine.lifecycleState == .running else { return }
            mainsDiagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
            if engine.dynamicsConfiguration.mainsNotch.continuousTracking {
                engine.pollMainsHumTracking()
            }
        }
    }
}

private struct EngineeringValidationView: View {
    @ObservedObject var engine: AudioIOEngine

    var body: some View {
        TabView {
            ContentView(engine: engine)
                .tabItem { Label("Main Validation", systemImage: "slider.horizontal.3") }

            PR27ProtectionValidationView(engine: engine)
                .tabItem { Label("PR27 Protection", systemImage: "waveform.path.ecg") }

            PR28AdvancedDynamicsValidationView(engine: engine)
                .tabItem { Label("PR28 Advanced Dynamics", systemImage: "waveform.badge.plus") }

            PR30PhaseTimeValidationView(engine: engine)
                .tabItem { Label("PR30 Phase / Time", systemImage: "timeline.selection") }

            PR31NoiseHumValidationView(engine: engine)
                .tabItem { Label("PR31 Noise / Hum", systemImage: "waveform.slash") }
        }
        .frame(minWidth: 900, minHeight: 720)
    }
}

#endif

private enum ApplicationAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

private enum ApplicationPresenceMode: String, CaseIterable, Identifiable {
    case dock
    case tray
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dock: return "Dock"
        case .tray: return "Menu Bar"
        case .both: return "Both"
        }
    }
}

@MainActor
private final class ApplicationPreferences: ObservableObject {
    private enum Key {
        static let appearance = "application.appearance"
        static let presence = "application.presence"
    }

    private let defaults: UserDefaults

    @Published var appearance: ApplicationAppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    @Published var presence: ApplicationPresenceMode {
        didSet {
            defaults.set(presence.rawValue, forKey: Key.presence)
            applyActivationPolicy()
        }
    }

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginError: String?
    private var appearanceObservation: NSKeyValueObservation?
    private var didApplyInitialPreferences = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = ApplicationAppearanceMode(
            rawValue: defaults.string(forKey: Key.appearance) ?? ""
        ) ?? .system
        presence = ApplicationPresenceMode(
            rawValue: defaults.string(forKey: Key.presence) ?? ""
        ) ?? .both
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginError = nil
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyApplicationIcon()
            }
        }
    }

    var isTrayInserted: Bool { presence != .dock }

    var launchAtLoginStatusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires approval in System Settings"
        case .notRegistered:
            return "Off"
        case .notFound:
            return "Unavailable"
        @unknown default:
            return "Unknown"
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    func setTrayInserted(_ inserted: Bool) {
        if inserted {
            if presence == .dock { presence = .both }
        } else if presence != .dock {
            // Never strand a tray-only app with no visible app surface.
            presence = .dock
        }
    }

    func apply() {
        guard !didApplyInitialPreferences else { return }
        didApplyInitialPreferences = true
        applyAppearance()
        applyActivationPolicy()
    }

    private func applyAppearance() {
        switch appearance {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        applyApplicationIcon()
    }

    private func applyApplicationIcon() {
        let useDarkIcon: Bool
        switch appearance {
        case .light:
            useDarkIcon = false
        case .dark:
            useDarkIcon = true
        case .system:
            useDarkIcon = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let assetName = NSImage.Name(useDarkIcon ? "DockIconDark" : "DockIconLight")
        if let icon = NSImage(named: assetName) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = presence == .tray ? .accessory : .regular
        _ = NSApplication.shared.setActivationPolicy(policy)
    }
}

private struct ProductionMenuBarView: View {
    let product: ProductController
    @ObservedObject private var profiles: ProductProfileController
    @ObservedObject private var engine: AudioIOEngine
    @Environment(\.openWindow) private var openWindow
    @State private var commandError: String?

    init(product: ProductController) {
        self.product = product
        _profiles = ObservedObject(wrappedValue: product.profiles)
        _engine = ObservedObject(wrappedValue: product.audioEngine)
    }

    private var presetSelection: Binding<UUID?> {
        Binding(
            get: { profiles.selectedContentPresetID },
            set: { id in
                guard let id else { return }
                profiles.selectContentPreset(id)
            }
        )
    }

    private var processingActive: Bool {
        switch engine.lifecycleState {
        case .starting, .running, .reconfiguring, .recoveringOutput:
            return true
        default:
            return false
        }
    }

    private var canToggleProcessing: Bool {
        switch engine.lifecycleState {
        case .idle, .running, .reconfiguring, .recoveringOutput, .failed:
            return true
        default:
            return false
        }
    }

    private var processingBinding: Binding<Bool> {
        Binding(
            get: { processingActive },
            set: { enabled in
                Task { @MainActor in
                    await Task.yield()
                    if enabled {
                        if engine.lifecycleState == .failed { engine.stop() }
                        guard engine.lifecycleState == .idle else { return }
                        do {
                            try engine.start()
                            commandError = nil
                        } catch {
                            commandError = error.localizedDescription
                        }
                    } else {
                        engine.stop()
                        commandError = nil
                    }
                }
            }
        )
    }

    private var statusLabel: String {
        switch engine.lifecycleState {
        case .idle: return "Stopped"
        case .running: return "Processing"
        case .failed: return "Failed"
        case .requestingPermission: return "Requesting Permission"
        case .creatingTap, .creatingAggregate, .openingOutput, .starting: return "Starting"
        case .reconfiguring: return "Reconfiguring"
        case .recoveringOutput: return "Recovering Output"
        case .stopping: return "Stopping"
        }
    }

    private var statusSymbol: String {
        switch engine.lifecycleState {
        case .running: return "waveform.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "stop.circle"
        default: return "arrow.triangle.2.circlepath.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOTCH SIXTY")
                        .font(.headline)
                    Label(statusLabel, systemImage: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(engine.lifecycleState == .failed ? .red : .secondary)
                }
                Spacer(minLength: 16)
            }

            Divider()

            Toggle("Processing", isOn: processingBinding)
                .toggleStyle(.switch)
                .disabled(!canToggleProcessing)

            HStack(spacing: 8) {
                Label("Preset", systemImage: "music.note.list")
                    .fixedSize()

                Picker("", selection: presetSelection) {
                    ForEach(profiles.contentPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .productionGlassPickerChrome()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }

            if profiles.selectedContentPresetIsDirty {
                Text("Current preset has unsaved changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Notch Sixty", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button(role: .destructive) {
                    product.shutdownForTermination()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .foregroundStyle(.red)
                .help("Quit Notch Sixty")
            }
        }
        .padding(14)
        .frame(width: 300)
        .alert(
            "Processing Error",
            isPresented: Binding(
                get: { commandError != nil },
                set: { if !$0 { commandError = nil } }
            )
        ) {
            Button("OK") { commandError = nil }
        } message: {
            Text(commandError ?? "")
        }
    }
}

private struct ProductionSettingsView: View {
    @ObservedObject var preferences: ApplicationPreferences
    @ObservedObject var product: ProductController

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var diagnosticsReport: String {
        let engine = product.audioEngine
        let output = engine.selectedOutputDevice
        let kernel = engine.diagnosticsSnapshot().renderKernelDiagnostics

        let outputName = output?.name ?? "None selected"
        let outputUID = output?.uid ?? "None"
        let outputRate = output.map {
            String(format: "%.1f kHz", $0.nominalSampleRate / 1_000.0)
        } ?? "Unavailable"
        let latency: String
        if let kernel, kernel.sampleRate > 0 {
            latency = String(
                format: "%u frames / %.3f ms",
                kernel.latencyFrames,
                Double(kernel.latencyFrames) / kernel.sampleRate * 1_000.0
            )
        } else {
            latency = "Unavailable"
        }

        return [
            "Notch Sixty Diagnostics",
            "Version: \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: Apple Silicon",
            "Lifecycle: \(engine.lifecycleState.rawValue)",
            "Output: \(outputName)",
            "Output UID: \(outputUID)",
            "Output Rate: \(outputRate)",
            "Content Preset: \(product.profiles.selectedContentPresetName)",
            "Playback System: \(product.profiles.selectedSystemProfileName)",
            "Global Bypass: \(engine.playbackControlConfiguration.globalBypassed ? "On" : "Off")",
            "EQ Phase: \(engine.stereoEQConfiguration.phaseMode.displayName)",
            "EQ Bands Enabled: \(engine.stereoEQConfiguration.enabledBandCount)",
            "Bass Management: \(engine.bassManagementConfiguration.enabled ? "On" : "Off")",
            "Room Correction: \(engine.roomCorrectionConfiguration.enabled ? "On" : "Off")",
            "DSP Latency: \(latency)",
        ].joined(separator: "\n")
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport, forType: .string)
    }

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    settingsCard(title: "About", systemImage: "info.circle") {
                        LabeledContent("Version") {
                            Text(version).monospacedDigit()
                        }
                        LabeledContent("Build") {
                            Text(build).monospacedDigit()
                        }
                    }

                    settingsCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
                        HStack(spacing: 10) {
                            Text("Appearance")
                            Picker("", selection: $preferences.appearance) {
                                ForEach(ApplicationAppearanceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .productionGlassPickerChrome()
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    }

                    settingsCard(title: "App Presence", systemImage: "macwindow.on.rectangle") {
                        HStack(spacing: 10) {
                            Text("Show Notch Sixty in")
                            Picker("", selection: $preferences.presence) {
                                ForEach(ApplicationPresenceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .productionGlassPickerChrome()
                            .pickerStyle(.segmented)
                            .frame(width: 250)
                        }

                        Text("Menu Bar mode keeps processing and preset controls available without a Dock icon. Both shows the app in both places.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Startup", systemImage: "power") {
                        Toggle(
                            "Launch at Login",
                            isOn: Binding(
                                get: { preferences.launchAtLoginEnabled },
                                set: { preferences.setLaunchAtLogin($0) }
                            )
                        )

                        LabeledContent("Status") {
                            Text(preferences.launchAtLoginStatusDescription)
                                .foregroundStyle(.secondary)
                        }

                        if let error = preferences.launchAtLoginError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }

                        Text("Launch at Login is optional and does not automatically start audio processing. Processing remains an explicit user action in v1.0.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Permissions", systemImage: "lock.shield") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("System Audio")
                                .font(.subheadline.weight(.medium))
                            Text("Requested by macOS when processing needs system-audio capture.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Measurement Microphone")
                                .font(.subheadline.weight(.medium))
                            Text("Requested only from Room Correction when you choose Request Access.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("If processing starts but receives no system audio after permission was denied, allow Notch Sixty under Privacy & Security → Screen & System Audio Recording, then relaunch the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    settingsCard(title: "Support", systemImage: "wrench.and.screwdriver") {
                        Button {
                            copyDiagnostics()
                        } label: {
                            Label("Copy Diagnostics", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.glass)

                        Text("Copies app/build, macOS, audio device/rate, active preset/system, bypass state, and DSP latency. It does not include captured audio or room-measurement samples.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
        .task { preferences.refreshLaunchAtLoginStatus() }
        .frame(width: 540)
        .frame(minHeight: 580)
    }

    private func settingsCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

}

private final class NotchSixtyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct NotchSixtyApp: App {
    @NSApplicationDelegateAdaptor(NotchSixtyAppDelegate.self) private var appDelegate
    @StateObject private var product: ProductController
    @StateObject private var preferences: ApplicationPreferences

    init() {
        _product = StateObject(wrappedValue: ProductController())
        _preferences = StateObject(wrappedValue: ApplicationPreferences())
    }

    private var trayInserted: Binding<Bool> {
        Binding(
            get: { preferences.isTrayInserted },
            set: { preferences.setTrayInserted($0) }
        )
    }

    var body: some Scene {
        Window("Notch Sixty", id: "main") {
            ProductionRootView(product: product)
                .task {
                    product.prepareForUse()
                    preferences.apply()
                }
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))

        MenuBarExtra(
            "Notch Sixty",
            image: "TrayIcon",
            isInserted: trayInserted
        ) {
            ProductionMenuBarView(product: product)
                .task { product.prepareForUse() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            ProductionSettingsView(preferences: preferences, product: product)
        }

        #if DEBUG
        Window("Engineering Validation", id: "engineering-validation") {
            EngineeringValidationView(engine: product.audioEngine)
                .task { product.prepareForUse() }
        }
        .defaultSize(width: 1000, height: 760)
        #endif
    }
}
