import Foundation
import SwiftUI

// E12 S12 (behind `e12.dashboard-remote`): the Dashboard as the status page. It shows what is running, whether it is
// healthy and what needs attention, links to the page that changes each thing, and carries no everyday control
// (volume, mute, balance and output live in the menu bar panel, S13). Text and state come from `DashboardModel`.

/// Telemetry the page polls at a low rate while it is visible and processing runs.
struct DashboardTelemetry: Equatable {
    var meanLoad: Float?
    var peakLoad: Float?
    var latencyMilliseconds: Double?
    /// Output device latency and I/O buffer (G71), read from Core Audio on the control plane.
    var deviceLatencyMilliseconds: Double?
    var bufferMilliseconds: Double?
    var integratedLUFS: Double?
    var roomTreatment: ProductionRoomTreatmentDiagnostics?
}

extension DashboardInputs {
    static func dynamicsNames(_ d: DynamicsConfiguration) -> [String] {
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
        return names
    }

    @MainActor
    static func make(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        history: SessionEventHistory,
        telemetry: DashboardTelemetry,
        failsafeMessage: String?,
        usesDecibels: Bool,
        now: Date = Date()
    ) -> DashboardInputs {
        var i = DashboardInputs()
        i.lifecycle = engine.lifecycleState
        i.outputName = engine.selectedOutputDevice?.name
        i.sampleRate = engine.selectedOutputDevice?.nominalSampleRate
        i.volumeReadout = DashboardModel.volumeReadout(
            level: engine.masterVolumeConfiguration.level,
            softwareControl: engine.masterVolumeCapabilities.controlMode == .softwareDSP, usesDecibels: usesDecibels)
        i.muted = engine.masterVolumeConfiguration.muted
        i.presetName = profiles.selectedContentPresetName
        i.presetDirty = profiles.selectedContentPresetIsDirty

        if engine.liveBinauralHeadphoneActive {
            i.path = .virtualHeadphones(layout: engine.headphoneDeviceProfileConfiguration?.programLayout.displayName ?? "2.0")
        } else if engine.liveNChannelActive {
            i.path = .multichannel(system: engine.outputDeviceProfileConfiguration?.systemDisplayName ?? "Semantic speakers")
        } else if engine.headphoneDeviceProfileConfiguration?.enabled == true {
            i.path = .headphones
        }
        if let routing = engine.speakerRoutingConfiguration, routing.enabled {
            i.routing = DashboardRouting(speakers: routing.speakers.count, ways: routing.speakers.reduce(0) { $0 + $1.ways.count })
        }
        i.systemName = engine.outputDeviceProfileConfiguration?.systemDisplayName
            ?? (engine.headphoneDeviceProfileConfiguration?.enabled == true ? "Headphones" : "Stereo")
        let bass = engine.bassManagementConfiguration
        i.bassManagementEnabled = bass.enabled
        i.crossoverHz = Int(bass.frequencyHz.rounded())
        i.crossoverName = bass.topology.displayName

        i.eqBandCount = engine.stereoEQConfiguration.enabledBandCount
        i.eqPhaseName = engine.stereoEQConfiguration.phaseMode.displayName
        i.dynamicsNames = dynamicsNames(engine.dynamicsConfiguration)
        let correction = engine.roomCorrectionConfiguration
        i.correctionEnabled = correction.enabled
        i.correctionFilterName = correction.filter?.name

        if let treatment = telemetry.roomTreatment {
            if treatment.faulted { i.acoustics = .faulted }
            else if treatment.active { i.acoustics = .active(sources: Int(treatment.treatmentSourceCount)) }
            else if treatment.transitioning { i.acoustics = .transitioning(percent: Int((treatment.treatmentMix * 100).rounded())) }
            else { i.acoustics = .ready }
        } else if engine.roomTreatmentStagedForNextStart {
            i.acoustics = .staged
        }

        if FeatureFlags().isEnabled(.systemPages) {
            let reasons = SystemChecklistModel.outOfDateReasons(.make(engine: engine, profiles: profiles))
            if !reasons.isEmpty { i.calibrationOutOfDate = reasons.map(\.reason).joined(separator: ", ") }
        }
        i.lastError = engine.lastErrorDescription
        i.failsafeMessage = failsafeMessage
        i.eventsInLastDay = history.eventsSince(now.addingTimeInterval(-86_400)).count

        i.clippedSamples = history.health.clippedSamples
        i.peakLimiterReductionDB = history.health.peakLimiterReductionDB
        i.remainingHeadroomDB = history.health.remainingHeadroomDB
        i.dropoutEvents = history.dropouts.events
        i.meanLoad = telemetry.meanLoad
        i.peakLoad = telemetry.peakLoad
        i.latencyMilliseconds = telemetry.latencyMilliseconds
        i.deviceLatencyMilliseconds = telemetry.deviceLatencyMilliseconds
        i.bufferMilliseconds = telemetry.bufferMilliseconds
        i.integratedLUFS = telemetry.integratedLUFS
        let peak = history.health.peakOutputLinear
        i.truePeakDBTP = peak > 0 ? 20 * log10(Double(peak)) : nil
        return i
    }
}

struct ProductionStatusDashboardView: View {
    var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    @ObservedObject var navigation: ProductionNavigation
    var failsafeMessage: String?
    var entryCard = AnyView(EmptyView())
    @ObservedObject private var history = ProductionMeterHub.eventHistory
    @AppStorage(PreferenceKeys.Application.volumeStepResolution)
    private var storedVolumeStepResolution = ApplicationVolumeStepResolution.standard.rawValue
    @State private var telemetry = DashboardTelemetry()

    private var state: DashboardState {
        DashboardModel.make(DashboardInputs.make(
            engine: engine, profiles: profiles, history: history, telemetry: telemetry,
            failsafeMessage: failsafeMessage,
            usesDecibels: ApplicationVolumeStepResolution(storedValue: storedVolumeStepResolution)?.usesDecibels == true))
    }

    var body: some View {
        let state = self.state
        ProductionPageContainer {
            VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
                if state.needsOutput {
                    Text("Choose an output in the menu bar panel to begin.").foregroundStyle(.secondary)
                }
                if !state.attention.isEmpty { attentionArea(state.attention) }
                nowPlayingRow(state.nowPlaying)
                entryCard
                StereoSignatureVUMeterPanel(engine: engine)
                loudnessLine
                healthStrip(state.health)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: DesignSpacing.l.pt)], spacing: DesignSpacing.l.pt) {
                    ForEach(state.cards) { card in cardView(card) }
                }
            }
        }
        .task(id: engine.lifecycleState) { await runTelemetryLoop() }
    }

    // MARK: Pieces

    private func go(_ destination: DashboardDestination) {
        navigation.requestedMetersPage = destination.metersPage
        navigation.navigate(to: destination.section)
    }

    private func attentionArea(_ items: [DashboardAttentionItem]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            ForEach(items) { item in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DesignSpacing.m.pt) {
                        attentionLabel(item)
                        Spacer(minLength: DesignSpacing.m.pt)
                        attentionButton(item)
                    }
                    VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                        attentionLabel(item)
                        attentionButton(item)
                    }
                }
                .padding(DesignSpacing.m.pt)
                .frame(maxWidth: .infinity, alignment: .leading)
                .designTint(item.isWarning ? .orange : .secondary)
                .accessibilityIdentifier("dashboard.attention.\(item.id)")
            }
        }
    }

    private func attentionLabel(_ item: DashboardAttentionItem) -> some View {
        Label(item.text, systemImage: item.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attentionButton(_ item: DashboardAttentionItem) -> some View {
        Button(item.buttonTitle) { go(item.destination) }.buttonStyle(.glass)
    }

    private func nowPlayingRow(_ n: DashboardNowPlaying) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            HStack(spacing: DesignSpacing.s.pt) {
                Text(n.title).font(DesignType.sectionTitle.font)
                if n.unsavedMark {
                    Text("Unsaved changes").font(DesignType.caption.font).foregroundStyle(.secondary)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            if let reason = n.reason {
                Text(reason).font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            Text("\(n.output) · \(n.sampleRate) · Volume \(n.volume)")
                .font(DesignType.body.font).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboard.nowPlaying")
    }

    private var loudnessLine: some View {
        let peak = history.health.peakOutputLinear
        let peakDB: Double? = peak > 0 ? 20 * log10(Double(peak)) : nil
        return Text("Integrated \(DashboardModel.lufsText(telemetry.integratedLUFS)) · Peak \(DashboardModel.truePeakText(peakDB)) since start")
            .font(DesignType.caption.font.monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityIdentifier("dashboard.loudness")
    }

    private func healthStrip(_ items: [DashboardHealthItem]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text("Health").font(DesignType.sectionTitle.font)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text(item.title).font(DesignType.caption.font).foregroundStyle(.secondary)
                        Text(item.value).font(DesignType.body.font.monospacedDigit())
                            .foregroundStyle(item.state == .warning ? Color.orange : Color.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSpacing.m.pt)
                    .designSurface(.medium)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("dashboard.health.\(item.id)")
                }
            }
        }
    }

    private func cardView(_ card: DashboardCard) -> some View {
        Button { go(card.destination) } label: {
            VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                HStack {
                    Label(card.title, systemImage: card.systemImage).font(DesignType.sectionTitle.font)
                    Spacer(minLength: DesignSpacing.s.pt)
                    Text(card.isOn ? "On" : "Off").font(DesignType.caption.font.weight(.semibold))
                        .foregroundStyle(card.isOn ? Color.green : Color.secondary)
                }
                Text(card.line).font(DesignType.body.font).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            }
            .padding(DesignSpacing.l.pt)
            .frame(maxWidth: .infinity, alignment: .leading)
            .designSurface(.large)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.title), \(card.isOn ? "on" : "off"). \(card.line)")
        .accessibilityHint("Opens \(card.title)")
        .accessibilityIdentifier("dashboard.card.\(card.id)")
    }

    // MARK: Telemetry

    /// A low-rate loop: keeps the shared meter hub polling (it feeds the session totals), and reads load, latency,
    /// room-treatment state and integrated loudness. Idle unless processing runs. Control plane only.
    @MainActor
    private func runTelemetryLoop() async {
        guard engine.lifecycleState == .running else {
            telemetry = DashboardTelemetry()
            return
        }
        let ledger = ProductionMetersView.analysisDemandLedger(for: engine)
        let demand = ledger.acquire(UInt32(N60_ANALYSIS_DEMAND_STEREO) | ProductionAnalysisDemand.loudness)
        let hub = ProductionMeterHub.shared(for: engine)
        let token = hub.subscribe(hertz: 4)
        defer {
            hub.unsubscribe(token)
            ledger.release(demand)
        }
        while !Task.isCancelled && engine.lifecycleState == .running {
            _ = hub.take(token)
            var next = DashboardTelemetry()
            if let context = hub.latestContext {
                let graph = context.diagnostics.unifiedGraph
                next.meanLoad = graph?.renderLoad.flatMap { $0.windowBlocks > 0 ? $0.meanLoad : nil }
                next.peakLoad = graph?.renderLoad.flatMap { $0.windowBlocks > 0 ? $0.peakLoad : nil }
                let frames = graph?.latencyFrames ?? context.diagnostics.renderKernelDiagnostics?.latencyFrames
                    ?? context.transport.map { UInt32(clamping: $0.latencyFrames) }
                if let frames, let rate = context.diagnostics.outputSampleRate, rate > 0 {
                    next.latencyMilliseconds = Double(frames) / rate * 1_000
                }
                next.roomTreatment = context.transport?.roomTreatment
                if let rate = context.diagnostics.outputSampleRate, rate > 0,
                   let uid = engine.routeConfiguration.selectedOutputUID,
                   let output = engine.outputDevices.first(where: { $0.uid == uid }) {
                    let reading = AudioDeviceLatencyReader.read(deviceID: output.deviceID, input: false, fallbackRate: rate)
                    next.deviceLatencyMilliseconds = reading.latencySeconds * 1_000
                    next.bufferMilliseconds = reading.bufferSeconds * 1_000
                }
            }
            next.integratedLUFS = engine.productionAnalysisSnapshot().loudnessOutput?.integrated
            if next != telemetry { telemetry = next }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        telemetry = DashboardTelemetry()
    }
}
