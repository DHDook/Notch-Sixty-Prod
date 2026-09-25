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
    static let currentSchemaVersion = 5

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
            }
        }
    }
}
