import AppKit
import Foundation
import SwiftUI

// E12 S12: the legacy Dashboard (used while `e12.dashboard-remote` is off), moved out of ProductionRootView.swift
// unchanged. S14 deletes it when the flag graduates.
struct ProductionDashboardView: View {
    var engine: AudioIOEngine
    var entryCard = AnyView(EmptyView())
    @AppStorage(PreferenceKeys.Application.volumeStepResolution)
    private var storedVolumeStepResolution = ApplicationVolumeStepResolution.standard.rawValue
    @State private var actionError: String?

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
                // Processing state lives in the toolbar's status readout and
                // its Bypass and Start/Stop buttons, so the dashboard spends
                // no line on it.
                if engine.selectedOutputDevice == nil {
                    Text("Choose an output below to begin.")
                        .foregroundStyle(.secondary)
                }

                entryCard

                StereoSignatureVUMeterPanel(engine: engine)

                ProductionActionErrorBanner(message: $actionError)

                // Output and volume share one row; equal heights keep the
                // two glass panels aligned.
                HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                    audioControls
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .designSurface(.large)
                    masterControls
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                levelControls

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSpacing.l.pt) {
                    summaryCard(
                        title: "Playback Path",
                        text: playbackPathSummary,
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                    summaryCard(
                        title: "Equalizer",
                        text: "\(engine.stereoEQConfiguration.enabledBandCount) bands · \(engine.stereoEQConfiguration.phaseMode.displayName)",
                        systemImage: "slider.horizontal.3"
                    )
                    summaryCard(
                        title: "Dynamics",
                        text: dynamicsSummary,
                        systemImage: "waveform.path.ecg"
                    )
                    summaryCard(
                        title: "Speakers",
                        text: speakerSummary,
                        systemImage: "hifispeaker.2.fill"
                    )
                    summaryCard(
                        title: "Room Correction",
                        text: roomCorrectionSummary,
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                    summaryCard(
                        title: "Active Acoustics",
                        text: activeAcousticsSummary,
                        systemImage: "waveform.and.mic"
                    )
                }
            }
            .padding(DesignSpacing.xl.pt)
            .frame(maxWidth: 1180, alignment: .topLeading)
        }
    }

    /// dB key steps on a software-DSP output: the readout shows dB, as on a
    /// console or monitor controller.
    private var masterVolumeUsesDecibelScale: Bool {
        engine.masterVolumeCapabilities.controlMode == .softwareDSP
            && ApplicationVolumeStepResolution(storedValue: storedVolumeStepResolution)?.usesDecibels == true
    }

    /// In the dB step modes the fader is linear in dB; otherwise its
    /// position is the loudness-taper level itself.
    private var masterVolumeSliderPosition: Binding<Double> {
        let decibelLinear = masterVolumeUsesDecibelScale
        return Binding(
            get: {
                let level = engine.masterVolumeConfiguration.level
                return decibelLinear
                    ? MasterVolumeConfiguration.decibelFaderPosition(forLevel: level)
                    : level
            },
            set: { position in
                let level = decibelLinear
                    ? MasterVolumeConfiguration.level(forDecibelFaderPosition: position)
                    : position
                perform { try engine.setMasterVolumeLevel(level) }
            }
        )
    }

    private var masterVolumeReadout: String {
        let level = engine.masterVolumeConfiguration.level
        if masterVolumeUsesDecibelScale {
            return VolumeFeedbackPresentation.decibelReadout(
                MasterVolumeConfiguration.softwareTaperDB(forLevel: level),
                alwaysTenths: true
            )
        }
        let percent = String(format: "%.1f%%", level * 100)
        guard engine.masterVolumeCapabilities.controlMode == .softwareDSP else {
            return percent
        }
        guard let db = MasterVolumeConfiguration.softwareTaperDB(forLevel: level) else {
            return percent + " · −∞ dB"
        }
        return percent + String(format: " · %.1f dB", db)
    }

    private var playbackPathSummary: String {
        if engine.liveBinauralHeadphoneActive {
            let layout = engine.headphoneDeviceProfileConfiguration?.programLayout.displayName ?? "2.0"
            return "Virtual \(layout) → Headphones"
        }
        if engine.liveNChannelActive {
            return engine.outputDeviceProfileConfiguration?.systemDisplayName ?? "Semantic speakers"
        }
        if engine.headphoneDeviceProfileConfiguration?.enabled == true {
            return "Headphones · Stereo"
        }
        return "Stereo speakers"
    }

    private var dynamicsSummary: String {
        let d = engine.dynamicsConfiguration
        var names: [String] = []
        if d.stereoMode != .stereo { names.append(d.stereoMode.displayName) }
        if d.stereoWidener.enabled { names.append("Widener") }
        if d.dcOffsetFilter.enabled { names.append("DC Filter") }
        if d.infrasonicFilter.enabled { names.append("Infrasonic Filter") }
        if d.mainsNotch.enabled { names.append("Hum Notch") }
        if d.spectralDenoiser.enabled { names.append("Denoiser") }
        if d.loudnessMatch.enabled { names.append("Loudness Match") }
        if d.loudnessContour.enabled { names.append("Loudness Contour") }
        if d.deHarsh.enabled { names.append("De-Harsh") }
        if d.dialogueRelativeLeveler.enabled { names.append("Dialogue Leveler") }
        if d.deEsser.enabled { names.append("De-Esser") }
        if d.multibandCompressor.enabled { names.append("Multiband") }
        if d.compressor.enabled { names.append("Compressor") }
        if d.expander.enabled { names.append("Expander") }
        if d.gainRider.enabled { names.append("Gain Rider") }
        if d.automaticHeadroom.enabled { names.append("Auto Headroom") }
        if d.softClipper.enabled { names.append("Soft Clipper") }
        if d.pauseGate.enabled { names.append("Pause Gate") }
        if d.limiter.enabled { names.append("Limiter") }
        return names.isEmpty ? "No dynamics processors enabled." : names.joined(separator: " · ")
    }

    private var speakerSummary: String {
        let systemName = engine.outputDeviceProfileConfiguration?.systemDisplayName
            ?? (engine.headphoneDeviceProfileConfiguration?.enabled == true
                ? "Headphones"
                : "Stereo")
        let crossover = engine.bassManagementConfiguration
        guard crossover.enabled else {
            return "\(systemName) · Bass management off"
        }
        return "\(systemName) · \(Int(crossover.frequencyHz.rounded())) Hz · \(crossover.topology.displayName)"
    }

    private var activeAcousticsSummary: String {
        if let treatment = engine.productionTransportMeterSnapshot()?.roomTreatment {
            if treatment.faulted {
                return "Room Treatment faulted · safely bypassing"
            }
            if treatment.active {
                return "Room Treatment active · \(treatment.treatmentSourceCount) sources · \(treatment.latencyFrames) frames"
            }
            if treatment.transitioning {
                return "Room Treatment transitioning · \(Int((treatment.treatmentMix * 100).rounded()))%"
            }
            return "Room Treatment configured · latency-matched bypass"
        }
        if engine.roomTreatmentStagedForNextStart {
            return "Room Treatment staged · hardware-gated"
        }
        return "Ambient Analysis ready · Room Treatment not staged"
    }

    private var roomCorrectionSummary: String {
        let r = engine.roomCorrectionConfiguration
        if r.enabled {
            return r.filter?.name ?? "Enabled"
        }
        if let filter = r.filter {
            return "\(filter.name) loaded · Off"
        }
        return "No correction filter loaded."
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Text("Output Device").font(DesignType.sectionTitle.font)
                Spacer()
                Text(engine.lifecycleState.rawValue.capitalized)
                    .font(DesignType.caption.font.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: DesignSpacing.m.pt) {
                Picker("Output Device", selection: Binding(
                    get: { engine.routeConfiguration.selectedOutputUID },
                    set: { uid in perform { try engine.selectOutput(uid: uid) } }
                )) {
                    Text("No Output").tag(String?.none)
                    ForEach(engine.outputDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(engine.lifecycleState != .idle)

                Button {
                    perform { try engine.refreshOutputDevices() }
                } label: {
                    Label("Refresh Outputs", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .help("Refresh Outputs")
                .disabled(engine.lifecycleState != .idle)
            }
            if let error = engine.lastErrorDescription {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(DesignSpacing.m.pt)
    }

    private var masterControls: some View {
        GlassEffectContainer(spacing: DesignSpacing.m.pt) {
            HStack(spacing: DesignSpacing.l.pt) {
                Button {
                    perform { try engine.setMasterMuted(!engine.masterVolumeConfiguration.muted) }
                } label: {
                    Image(systemName: engine.masterVolumeConfiguration.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)

                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    HStack {
                        Text("Master Volume").font(DesignType.sectionTitle.font)
                        Spacer()
                        Text(masterVolumeReadout)
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: masterVolumeSliderPosition,
                        in: MasterVolumeConfiguration.levelRange
                    )
                    MasterVolumeFaderScale(decibelLinear: masterVolumeUsesDecibelScale)
                }

            }
            .padding(DesignSpacing.m.pt)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignRadius.large.pt))
        }
    }

    /// Everyday trims beside volume: input and output gain in one card,
    /// L/R balance in its own. Gain steps in 0.5 dB or takes a typed value;
    /// balance is a centre-detent bar. Double-clicking balance recentres it.
    private var levelControls: some View {
        HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
            gainControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .designSurface(.large)
            balanceControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .designSurface(.large)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var gainControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Gain").font(DesignType.sectionTitle.font)
            HStack(spacing: DesignSpacing.xl.pt) {
                ProductionGainStepper(
                    title: "Input",
                    value: engine.gainConfiguration.inputPreampDB,
                    range: DSPGainConfiguration.inputPreampRange,
                    set: { value in perform { try engine.setInputPreampDB(value) } }
                )
                .help("Gain before all processing. Lower it to leave headroom for EQ boosts.")
                ProductionGainStepper(
                    title: "Output",
                    value: engine.gainConfiguration.outputGainDB,
                    range: DSPGainConfiguration.outputGainRange,
                    set: { value in perform { try engine.setOutputGainDB(value) } }
                )
                .help("Gain after all processing, before the output device.")
            }
        }
        .padding(DesignSpacing.m.pt)
    }

    private var balanceControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                Text("Balance").font(DesignType.sectionTitle.font)
                Spacer()
                Text(Self.balanceReadout(engine.playbackControlConfiguration.balance))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("L").font(DesignType.caption.font.weight(.semibold)).foregroundStyle(.secondary)
                ProductionBalanceBar(
                    balance: Binding(
                        get: { engine.playbackControlConfiguration.balance },
                        set: { value in perform { try engine.setChannelBalance(value) } }
                    )
                )
                Text("R").font(DesignType.caption.font.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.m.pt)
        .help("Left/right balance. Centre is unity on both channels. Double-click to recentre.")
    }

    static func decibelReadout(_ db: Double) -> String {
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0.0 dB" }
        return String(format: "%@%.1f dB", rounded > 0 ? "+" : "−", abs(rounded))
    }

    static func balanceReadout(_ balance: Double) -> String {
        let percent = Int((abs(balance) * 100).rounded())
        if percent == 0 { return "Centre" }
        return balance < 0 ? "L \(percent)" : "R \(percent)"
    }

    private func summaryCard(
        title: String,
        text: String,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Label(title, systemImage: systemImage).font(DesignType.sectionTitle.font)
            Text(text).font(DesignType.body.font).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designSurface(.large)
    }
}
