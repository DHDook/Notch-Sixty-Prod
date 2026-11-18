import Foundation
import SwiftUI

enum ProductionMetersPage: String, CaseIterable, Identifiable {
    case levels
    case spectrum
    case stereo
    case dynamics
    case transport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .levels: return "Levels"
        case .spectrum: return "Spectrum"
        case .stereo: return "Stereo"
        case .dynamics: return "Dynamics"
        case .transport: return "Transport"
        }
    }

    var systemImage: String {
        switch self {
        case .levels: return "chart.bar.fill"
        case .spectrum: return "waveform.path"
        case .stereo: return "circle.grid.cross"
        case .dynamics: return "waveform.path.ecg"
        case .transport: return "point.3.connected.trianglepath.dotted"
        }
    }
}

enum ProductionMeterMath {
    static let floorDB = -60.0

    static func decibels(_ linear: Float) -> Double {
        guard linear.isFinite, linear > 0 else { return floorDB }
        return max(20.0 * log10(Double(linear)), floorDB)
    }

    static func formattedDB(_ value: Double, suffix: String = "dBFS") -> String {
        guard value.isFinite else { return "−∞ \(suffix)" }
        return DesignFormat.level(value, unit: suffix)
    }

    static func formattedGain(_ value: Float) -> String {
        DesignFormat.db(Double(value))
    }
}

private struct ProductionStereoLevelSnapshot: Equatable {
    var peakLeft = ProductionMeterMath.floorDB
    var peakRight = ProductionMeterMath.floorDB
    var rmsLeft = ProductionMeterMath.floorDB
    var rmsRight = ProductionMeterMath.floorDB
    var overRangeSamples: UInt64 = 0
}

private struct ProductionMetersSnapshot: Equatable {
    var input = ProductionStereoLevelSnapshot()
    var postEQ = ProductionStereoLevelSnapshot()
    var output = ProductionStereoLevelSnapshot()

    var inputTruePeakDBTP = ProductionMeterMath.floorDB
    var outputTruePeakDBTP = ProductionMeterMath.floorDB
    var sampleRate = 0.0
    var latencyFrames: UInt32 = 0
    var meteringEnabled = false

    var compressorGainReductionDB: Float = 0
    var deEsserGainReductionDB: Float = 0
    var multibandLowGainReductionDB: Float = 0
    var multibandMidGainReductionDB: Float = 0
    var multibandHighGainReductionDB: Float = 0
    var expanderAttenuationDB: Float = 0
    var limiterGainReductionDB: Float = 0
    var gainRiderAttenuationDB: Float = 0
    var loudnessShortTermLUFS: Float = 0
    var loudnessMatchGainDB: Float = 0
    var dialogueBoostDB: Float = 0
    var dialogueVoiceConfidence: Float = 0
    var denoiserMeanSuppressionDB: Float = 0
}

@MainActor
private enum ProductionDetailedMeterDemand {
    private static var activeRequests: Set<UUID> = []

    static func acquire(engine: AudioIOEngine) -> UUID {
        let token = UUID()
        let wasInactive = activeRequests.isEmpty
        activeRequests.insert(token)
        if wasInactive {
            try? engine.setDetailedMeteringDemand(true)
        }
        return token
    }

    static func release(_ token: UUID, engine: AudioIOEngine) {
        guard activeRequests.remove(token) != nil else { return }
        if activeRequests.isEmpty {
            try? engine.setDetailedMeteringDemand(false)
        }
    }
}

/// E33: the modes of Meters > Spectrum when `e33.page-enhancements` is on.
enum SpectrumPageMode: String, CaseIterable {
    case spectrum, rta, spectrogram

    var title: String {
        switch self {
        case .spectrum: return "Spectrum"
        case .rta: return "RTA"
        case .spectrogram: return "Spectrogram"
        }
    }
}

/// E32 S3 (R19): the per-tick values of the Meters page. Every stored change tells observers once; only
/// `MeterTickScope` observes it, so the page body is not re-evaluated per tick.
@MainActor
private final class MeterTickModel: ObservableObject {
    var snapshot = ProductionMetersSnapshot() { didSet { objectWillChange.send() } }
    var analysisSnapshot = ProductionAnalysisSnapshot.empty { didSet { objectWillChange.send() } }
    var transportMeterSnapshot: ProductionTransportMeterSnapshot? { didSet { objectWillChange.send() } }
    var routeMeters: [ProductionRouteMeter] = [] { didSet { objectWillChange.send() } }
    var protectionReadings: [Int: UnifiedGraphOutputProtectionReading] = [:] { didSet { objectWillChange.send() } }
    var transportDiagnostics: AudioDiagnosticsSnapshot? { didSet { objectWillChange.send() } }
    var windowVisible = true { didSet { if windowVisible != oldValue { objectWillChange.send() } } }
    var inputTruePeakHold = TruePeakMaxHold() { didSet { objectWillChange.send() } }
    var outputTruePeakHold = TruePeakMaxHold() { didSet { objectWillChange.send() } }
    var headroomStrip = HeadroomStripModel() { didSet { objectWillChange.send() } }
    var inputOvers = InputOversReading() { didSet { objectWillChange.send() } }
    let bank = MeterBankDisplay()
}

/// Re-evaluates its content when the tick model changes, and nothing else does.
private struct MeterTickScope<Content: View>: View {
    @ObservedObject var model: MeterTickModel
    let content: () -> Content

    init(model: MeterTickModel, @ViewBuilder content: @escaping () -> Content) {
        self.model = model
        self.content = content
    }

    var body: some View { content() }
}

struct ProductionMetersView: View {
    var engine: AudioIOEngine
    @ObservedObject var assistant: HeadroomAssistantController
    @State private var page: ProductionMetersPage = .levels
    @State private var assistantCommandError: String?
    /// E32 S3 (R19, design 7): everything that changes per tick lives in `tick`, which only `MeterTickScope`
    /// observes, so the page body (header, picker, cards that do not move) does not re-run at the poll rate.
    @State private var tick = MeterTickModel()
    @AppStorage("meters.ballistics") private var ballisticsRaw = MeterBallistics.peak.rawValue
    @State private var meterRevision = 0
    @State private var grAttachment: UUID?
    @AppStorage("meters.loudnessSource") private var loudnessSourceRaw = LoudnessSource.output.rawValue
    /// E33 S8 (behind `e33.page-enhancements`): analysis cards, headroom strip, dropout counter and RTA mode.
    private let enhanced = FeatureFlags().isEnabled(.eqPageEnhancements)
    @ObservedObject private var history = ProductionMeterHub.eventHistory
    @State private var spectrumMode = SpectrumPageMode.spectrum
    @State private var spectrogramWindow = SpectrogramWindow.tenSeconds


    private var snapshot: ProductionMetersSnapshot { get { tick.snapshot } nonmutating set { tick.snapshot = newValue } }
    private var analysisSnapshot: ProductionAnalysisSnapshot { get { tick.analysisSnapshot } nonmutating set { tick.analysisSnapshot = newValue } }
    private var transportMeterSnapshot: ProductionTransportMeterSnapshot? { get { tick.transportMeterSnapshot } nonmutating set { tick.transportMeterSnapshot = newValue } }
    private var routeMeters: [ProductionRouteMeter] { get { tick.routeMeters } nonmutating set { tick.routeMeters = newValue } }
    private var protectionReadings: [Int: UnifiedGraphOutputProtectionReading] { get { tick.protectionReadings } nonmutating set { tick.protectionReadings = newValue } }
    private var transportDiagnostics: AudioDiagnosticsSnapshot? { get { tick.transportDiagnostics } nonmutating set { tick.transportDiagnostics = newValue } }
    private var bank: MeterBankDisplay { tick.bank }
    private var windowVisible: Bool { get { tick.windowVisible } nonmutating set { tick.windowVisible = newValue } }
    private var inputTruePeakHold: TruePeakMaxHold { get { tick.inputTruePeakHold } nonmutating set { tick.inputTruePeakHold = newValue } }
    private var outputTruePeakHold: TruePeakMaxHold { get { tick.outputTruePeakHold } nonmutating set { tick.outputTruePeakHold = newValue } }
    private var headroomStrip: HeadroomStripModel { get { tick.headroomStrip } nonmutating set { tick.headroomStrip = newValue } }
    private var inputOvers: InputOversReading { get { tick.inputOvers } nonmutating set { tick.inputOvers = newValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
                header
                pagePicker

                MeterTickScope(model: tick) {
                switch page {
                case .levels:
                    levelsPage
                case .spectrum:
                    if enhanced {
                        Picker("Spectrum Mode", selection: $spectrumMode) {
                            ForEach(SpectrumPageMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                        .accessibilityIdentifier("meters.spectrum.mode")
                    }
                    if enhanced && spectrumMode == .spectrogram {
                        ProductionSpectrogramView(
                            snapshot: analysisSnapshot.spectrogram,
                            isRunning: engine.lifecycleState == .running,
                            window: $spectrogramWindow
                        )
                    } else if enhanced && spectrumMode == .rta {
                        ProductionRTABarsView(
                            levelsDB: analysisSnapshot.rtaBandsDB,
                            isRunning: engine.lifecycleState == .running
                        )
                    } else {
                        ProductionSpectrumView(
                            snapshot: analysisSnapshot,
                            isRunning: engine.lifecycleState == .running,
                            resetPeakHold: { engine.resetSpectrumPeakHold() }
                        )
                    }
                case .stereo:
                    ProductionStereoAnalysisView(
                        snapshot: analysisSnapshot,
                        isRunning: engine.lifecycleState == .running
                    )
                case .dynamics:
                    dynamicsPage
                case .transport:
                    transportPage
                }
                }
            }
            .padding(DesignSpacing.xl.pt)
            .frame(maxWidth: 1180, alignment: .topLeading)
        }
        .task(id: "\(engine.lifecycleState.rawValue)|\(page.rawValue)|\(spectrumMode.rawValue)|\(spectrogramWindow.rawValue)") {
            await runVisiblePageLoop()
        }
        .alert(
            "Headroom Assistant",
            isPresented: Binding(
                get: { assistantCommandError != nil },
                set: { if !$0 { assistantCommandError = nil } }
            )
        ) {
            Button("OK") { assistantCommandError = nil }
        } message: {
            Text(assistantCommandError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                Text("Signal levels, spectrum, stereo field, and gain structure — with hidden analysis parked.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            DesignStatusBadge(
                level: engine.lifecycleState == .running ? .good : .off,
                text: engine.lifecycleState == .running ? "LIVE" : "IDLE")
        }
    }

    private var pagePicker: some View {
        Picker("Meter Page", selection: $page) {
            ForEach(ProductionMetersPage.allCases) { page in
                Label(page.title, systemImage: page.systemImage).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 720)
    }

    @ViewBuilder
    private var levelsPage: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack(spacing: DesignSpacing.m.pt) {
                Picker("Ballistics", selection: $ballisticsRaw) {
                    ForEach(MeterBallistics.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .accessibilityIdentifier("meters.ballistics")
                Button("Reset Clip Latches") {
                    bank.resetAllLatches()
                    meterRevision &+= 1
                }
                .accessibilityIdentifier("meters.resetLatches")
                Spacer()
            }
            ProductionLoudnessCard(
                snapshot: analysisSnapshot,
                source: loudnessSource,
                truePeak: loudnessSource == .output ? outputTruePeakHold : inputTruePeakHold,
                isRunning: engine.lifecycleState == .running,
                unavailableReason: nil,
                isWide: transportMeterSnapshot != nil,
                onSource: { loudnessSourceRaw = $0.rawValue },
                onReset: resetLoudness
            )
            if enhanced {
                ProductionAnalysisMetersCard(
                    readout: analysisSnapshot.analysisMeters,
                    isRunning: engine.lifecycleState == .running,
                    onReset: resetAnalysisMeters
                )
                ProductionHeadroomStripCard(
                    strip: headroomStrip,
                    isAvailable: transportMeterSnapshot == nil,
                    isRunning: engine.lifecycleState == .running,
                    onReset: { headroomStrip.reset() }
                )
                ProductionBitActivityCard(
                    channels: analysisSnapshot.bitActivity,
                    isRunning: engine.lifecycleState == .running,
                    onReset: resetBitActivity
                )
                ProductionDropoutCard(counter: history.dropouts, onReset: { history.resetDropouts() })
                ProductionInputOversCard(reading: inputOvers, isRunning: engine.lifecycleState == .running, onReset: resetInputOvers)
            }
            if let transportMeterSnapshot {
                semanticLevelsPage(transportMeterSnapshot)
            } else {
                legacyLevelsPage
            }
        }
    }

    private var legacyLevelsPage: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            if engine.lifecycleState != .running {
                statusBanner("Start processing to view live detailed meters. The detailed meter pipeline remains parked while processing is stopped.")
            } else if !snapshot.meteringEnabled {
                statusBanner("Detailed metering is activating…")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSpacing.l.pt) {
                stereoLevelCard(title: "Input", subtitle: "Render input", stage: "input", levels: snapshot.input)
                stereoLevelCard(title: "Post-EQ", subtitle: "After the main EQ stage", stage: "postEQ", levels: snapshot.postEQ)
                stereoLevelCard(title: "Output", subtitle: "Final DSP output", stage: "output", levels: snapshot.output)
            }

            if !routeMeters.isEmpty {
                Text("Speaker Outputs").font(DesignType.sectionTitle.font)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                    ForEach(routeMeters) { route in routeCard(route) }
                }
            }

            HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                metricCard(
                    title: "Input True Peak",
                    value: ProductionMeterMath.formattedDB(snapshot.inputTruePeakDBTP, suffix: peakSuffix),
                    detail: "Authoritative protection detector"
                )
                metricCard(
                    title: "Output True Peak",
                    value: ProductionMeterMath.formattedDB(snapshot.outputTruePeakDBTP, suffix: peakSuffix),
                    detail: "Authoritative protection detector"
                )
                metricCard(
                    title: "Processing",
                    value: snapshot.sampleRate > 0 ? DesignFormat.hz(snapshot.sampleRate) : "—",
                    detail: snapshot.sampleRate > 0
                        ? "Float32 stereo · \(snapshot.latencyFrames) frame published latency"
                        : "No active render format"
                )
            }

            Text("Peak and RMS are shown in dBFS. True Peak is sourced from the existing protection telemetry rather than a second meter implementation. Detailed level accumulation is enabled only while this Levels page is visible.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    private func semanticLevelsPage(_ transport: ProductionTransportMeterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            if engine.lifecycleState != .running {
                statusBanner("Start processing to view live semantic meters.")
            } else if !transport.meteringEnabled {
                statusBanner("Detailed semantic metering is activating…")
            }

            HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                metricCard(title: "Mode", value: transport.kind.displayName, detail: transport.displayName)
                metricCard(
                    title: "Processing",
                    value: DesignFormat.hz(transport.sampleRate),
                    detail: "\(transport.latencyFrames) frame maximum configured path latency"
                )
                metricCard(
                    title: "Realtime Health",
                    value: transport.renderFailures == 0 && transport.outputWriteFailures == 0 ? "Clean" : "Attention",
                    detail: "\(transport.renderFailures) render · \(transport.outputWriteFailures) output failures"
                )
            }

            if !transport.programChannels.isEmpty {
                Text("Semantic Program Channels").font(DesignType.sectionTitle.font)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                    ForEach(transport.programChannels) { channel in transportChannelCard(channel) }
                }
            }

            Text(transport.kind == .virtualSpeakers ? "Headphone Output" : "Physical Outputs")
                .font(DesignType.sectionTitle.font)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                ForEach(transport.physicalOutputs) { channel in transportChannelCard(channel) }
            }

            if let input = transport.inputTruePeakLinear, let output = transport.outputTruePeakLinear {
                HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                    truePeakBarCard(
                        title: "Spatial Input True Peak", id: "input.truePeak", linear: input,
                        detail: "Downstream protection detector")
                    truePeakBarCard(
                        title: "Headphone Output True Peak", id: "output.truePeak", linear: output,
                        detail: "After headphone correction and protection")
                }
            }

            Text("Semantic program meters are measured after per-channel lane processing. Physical meters are measured after bass management, optional hardware-gated room treatment, Sub N routing, startup fade, and master output gain. Meter work is demand-driven and parked when this Levels page is hidden.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    private var transportPage: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            let diagnostics = transportDiagnostics
            let current = transportMeterSnapshot
            Text("Transport & Recovery").font(DesignType.sectionTitle.font)
            Text("Live transport state, published latency, buffer health, and selected-device recovery policy.")
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                metricCard(
                    title: "Active Path",
                    value: current?.kind.displayName ?? "Stereo",
                    detail: current?.displayName ?? "Legacy stereo render graph"
                )
                metricCard(
                    title: "Published Latency",
                    value: "\(current?.latencyFrames ?? UInt64(diagnostics?.renderKernelDiagnostics?.latencyFrames ?? 0)) frames",
                    detail: diagnostics?.outputSampleRate.map { String(format: "%.2f ms at %.1f kHz", Double(current?.latencyFrames ?? UInt64(diagnostics?.renderKernelDiagnostics?.latencyFrames ?? 0)) * 1_000.0 / $0, $0 / 1_000.0) }
                )
                metricCard(
                    title: "Buffered",
                    value: "\(diagnostics?.sessionTransportCounters.bufferedFrames ?? 0) frames",
                    detail: "Startup gate: \(diagnostics?.startupGateOpened == true ? "open" : "closed")"
                )
                metricCard(
                    title: "Underruns",
                    value: "\(diagnostics?.sessionTransportCounters.underrunFrames ?? 0)",
                    detail: "Overruns \(diagnostics?.sessionTransportCounters.overrunFrames ?? 0) frames"
                )
                if let treatment = current?.roomTreatment {
                    metricCard(
                        title: "Room Treatment",
                        value: treatment.faulted
                            ? "FAULT"
                            : (treatment.active
                                ? "ACTIVE"
                                : (treatment.transitioning
                                    ? "TRANSITION"
                                    : "BYPASSED")),
                        detail: String(
                            format: "%.0f%% mix · %u src · %u frames · %llu clamps · %llu failures",
                            Double(treatment.treatmentMix * 100),
                            treatment.treatmentSourceCount,
                            treatment.latencyFrames,
                            treatment.protectionClampSamples,
                            treatment.integrationFailures
                        )
                    )
                }
                if diagnostics?.sessionTransportCounters.adaptiveSampleRateEnabled == true {
                    let transport = diagnostics?.sessionTransportCounters ?? AudioTransportCounters()
                    metricCard(
                        title: "Adaptive SRC",
                        value: String(
                            format: "%.1f → %.1f kHz",
                            transport.adaptiveInputSampleRate / 1_000.0,
                            transport.adaptiveOutputSampleRate / 1_000.0
                        ),
                        detail: String(
                            format: "%+.1f ppm · target %u frames · %llu dropped · %llu starved",
                            transport.adaptiveCorrectionPPM,
                            transport.adaptiveTargetBufferedFrames,
                            transport.adaptiveDroppedInputFrames,
                            transport.adaptiveStarvedOutputFrames
                        )
                    )
                }
                metricCard(
                    title: "Recovery",
                    value: "\(diagnostics?.recoverySuccesses ?? 0) recovered",
                    detail: "\(diagnostics?.recoveryAttempts ?? 0) attempts · \(diagnostics?.recoveryFailures ?? 0) failures"
                )
                metricCard(
                    title: "Selected Output",
                    value: diagnostics?.selectedOutputPresent == true ? "Present" : "Unavailable",
                    detail: diagnostics?.selectedOutputName ?? diagnostics?.selectedOutputUID ?? "No output selected"
                )
            }

            if let error = diagnostics?.lastErrorDescription {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(StatusLevel.attention.color)
                    .textSelection(.enabled)
            }

            if enhanced { ProductionEventHistoryCard(history: history) }

            Text("Recovery remains pinned to the selected stable device UID. Notch Sixty does not silently follow the macOS default output or substitute a different device after disconnect.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    private var dynamicsPage: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Text("Gain Structure")
                .font(DesignType.sectionTitle.font)
            Text("Existing processor telemetry is summarized here without enabling the detailed Input / Post-EQ / Output meter accumulator.")
                .foregroundStyle(.secondary)

            headroomAssistantCard
                .onAppear { grAttachment = GainReductionMonitor.shared(for: engine).attach(hertz: GainReductionMonitor.pageHertz) }
                .onDisappear {
                    if let grAttachment { GainReductionMonitor.shared(for: engine).detach(grAttachment) }
                    grAttachment = nil
                }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                grMetric("Compressor GR", .compressor, snapshot.compressorGainReductionDB)
                grMetric("De-Esser GR", .deEsser, snapshot.deEsserGainReductionDB)
                grMetric("Multiband Low GR", .multibandLow, snapshot.multibandLowGainReductionDB)
                grMetric("Multiband Mid GR", .multibandMid, snapshot.multibandMidGainReductionDB)
                grMetric("Multiband High GR", .multibandHigh, snapshot.multibandHighGainReductionDB)
                grMetric("Expander Attenuation", .expander, snapshot.expanderAttenuationDB)
                grMetric("Limiter GR", .limiter, snapshot.limiterGainReductionDB)
                dynamicsMetric("Gain Rider", snapshot.gainRiderAttenuationDB)
                dynamicsMetric("Denoiser Suppression", snapshot.denoiserMeanSuppressionDB)

                metricCard(
                    title: "Loudness Match Detector (short-term)",
                    value: String(format: "%.1f LUFS", Double(snapshot.loudnessShortTermLUFS)),
                    detail: String(format: "Loudness Match %.1f dB", Double(snapshot.loudnessMatchGainDB))
                )
                metricCard(
                    title: "Dialogue",
                    value: DesignFormat.db(Double(snapshot.dialogueBoostDB), signed: true),
                    detail: String(format: "Voice confidence %.0f%%", Double(snapshot.dialogueVoiceConfidence * 100))
                )
            }

            Text("This page intentionally avoids the historical misleading ISP, fake bit-stream, and pseudo-standard DR-factor displays. Those are not part of the commercial meter contract.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
    }

    private var headroomAssistantCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Label(
                        "Headroom Assistant",
                        systemImage: "gauge.with.dots.needle.50percent"
                    )
                    .font(DesignType.sectionTitle.font)
                    Text(
                        "Observe a representative loud passage and estimate whether the existing Headroom Attenuation needs more reserve."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(headroomAssistantPhaseLabel)
                    .font(DesignType.caption.font.bold())
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }

            if assistant.isObserving {
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                    ProgressView(
                        value: assistant.observationProgress
                    )
                    Text(
                        "Observed \(assistant.evidence.observationSeconds, specifier: "%.1f") s · 10 s minimum · 30 s recommended"
                    )
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Target True Peak")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                    HStack(spacing: DesignSpacing.m.pt) {
                        Slider(
                            value: $assistant.targetPeakDBTP,
                            in: HeadroomAssistantRecommendation
                                .targetPeakRange,
                            step: 0.1
                        )
                        Text(
                            "\(assistant.targetPeakDBTP, specifier: "%.1f") dBTP"
                        )
                        .font(DesignType.caption.font.monospacedDigit())
                        .frame(width: 76, alignment: .trailing)
                    }
                }

                if let recommendation = assistant.recommendation {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text("Headroom Attenuation")
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                        Text(
                            "\(recommendation.currentHeadroomAttenuationDB, specifier: "%+.1f") → \(recommendation.recommendedHeadroomAttenuationDB, specifier: "%+.1f") dB"
                        )
                        .font(.headline.monospacedDigit())
                        Text(headroomRecommendationSummary(recommendation))
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 225, alignment: .leading)
                }
            }

            if assistant.phase != .idle {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 170), spacing: DesignSpacing.m.pt)
                    ],
                    spacing: DesignSpacing.m.pt
                ) {
                    assistantMetric(
                        "Pre-Rider True Peak",
                        formatOptionalDBTP(
                            assistant.evidence
                                .maximumPreRiderTruePeakDBTP
                        )
                    )
                    assistantMetric(
                        "Sustained Limiter GR",
                        String(
                            format: "%.1f dB",
                            assistant.evidence
                                .maximumSustainedLimiterGainReductionDB
                        )
                    )
                    assistantMetric(
                        "Peak Limiter GR",
                        String(
                            format: "%.1f dB",
                            assistant.evidence
                                .maximumLimiterGainReductionDB
                        )
                    )
                    assistantMetric(
                        "Safety Clamps",
                        "\(assistant.evidence.safetyClampSamples)"
                    )
                }
            }

            if let error = assistant.lastErrorDescription {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignType.caption.font)
                    .foregroundStyle(StatusLevel.attention.color)
                    .textSelection(.enabled)
            }

            if assistant.phase == .applied {
                Label(
                    "Applied to live content state · saved Content Preset unchanged",
                    systemImage: "checkmark.circle.fill"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: DesignSpacing.m.pt) {
                if assistant.isObserving {
                    Button("Stop & Review") {
                        assistant.stopObservation()
                    }
                    .buttonStyle(.glassProminent)
                    Button("Cancel") {
                        assistant.cancelObservation()
                    }
                } else {
                    if assistant.phase != .applied {
                        Button(
                            assistant.phase == .idle
                                ? "Observe Program"
                                : "Observe Again"
                        ) {
                            do {
                                try assistant.startObservation()
                            } catch {
                                assistantCommandError =
                                    error.localizedDescription
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(
                            engine.lifecycleState != .running
                        )
                    }

                    if let recommendation =
                        assistant.recommendation,
                       recommendation.canApply,
                       assistant.phase == .review {
                        Button("Apply Additional Headroom") {
                            do {
                                try assistant.applyRecommendation()
                            } catch {
                                assistantCommandError =
                                    error.localizedDescription
                            }
                        }
                        .buttonStyle(.glassProminent)
                    }

                    if assistant.phase == .applied,
                       assistant.canRevertAppliedRecommendation {
                        Button("Undo Applied Headroom") {
                            do {
                                try assistant
                                    .revertAppliedRecommendation()
                            } catch {
                                assistantCommandError =
                                    error.localizedDescription
                            }
                        }
                        Button("Keep & Clear") {
                            assistant.cancelObservation()
                        }
                    } else if assistant.phase != .idle {
                        Button("Clear") {
                            assistant.cancelObservation()
                        }
                    }
                }
            }

            Text(
                "Advisory only: the assistant never removes existing headroom and never auto-adjusts in the background. Apply changes the live content state only; save or update the Content Preset separately if you want to keep it. Use a representative loud passage—short observations cannot prove worst-case program headroom."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.large)
        .accessibilityElement(children: .contain)
    }

    private var headroomAssistantPhaseLabel: String {
        switch assistant.phase {
        case .idle: return "READY"
        case .observing: return "OBSERVING"
        case .review: return "REVIEW"
        case .applied: return "APPLIED"
        case .invalidated: return "INVALIDATED"
        }
    }

    private func headroomRecommendationSummary(
        _ recommendation: HeadroomAssistantRecommendation
    ) -> String {
        switch recommendation.disposition {
        case .insufficientEvidence:
            return "Keep observing: at least 10 seconds of valid true-peak evidence is required."
        case .currentReserveSufficient:
            return "This observation does not justify adding attenuation. Existing reserve is left unchanged."
        case .recommendAdditionalAttenuation:
            return String(
                format: "Recommend %.1f dB of additional reserve.",
                recommendation.additionalAttenuationDB
            )
        case .rangeLimited:
            return "Recommendation reaches the −48 dB headroom limit; review the wider gain structure."
        }
    }

    private func assistantMetric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text(title)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignType.caption.font.monospacedDigit().bold())
        }
        .padding(DesignSpacing.m.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designSurface(.medium)
    }

    /// E32 R20 (design 9): "dBTP" only while the detector's rate times factor reaches 176.4 kHz; the label stays
    /// "dBTP" when no render diagnostics exist (the detector's factor is then unknown).
    private var peakSuffix: String {
        guard let kernel = transportDiagnostics?.renderKernelDiagnostics else { return "dBTP" }
        return PeakLabel.suffix(sampleRate: kernel.sampleRate, detectionFactor: Int(kernel.effectiveOversamplingFactor.rawValue))
    }

    private func formatOptionalDBTP(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f ", value) + peakSuffix
    }

    /// E28 S6: one routed DAC channel of a stereo same-device speaker map, drawn with the shared bar.
    private func routeCard(_ route: ProductionRouteMeter) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Text(route.label).font(DesignType.sectionTitle.font)
                Spacer()
                Text("CH \(route.physicalChannel + 1)")
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            channelLevelRow(
                id: route.id, label: "",
                peak: ProductionMeterMath.decibels(route.peakLinear),
                rms: ProductionMeterMath.decibels(route.rmsLinear))
            HStack {
                Text("Over-range").font(DesignType.caption.font).foregroundStyle(.secondary)
                Spacer()
                Text("\(route.overRangeSamples)").font(DesignType.caption.font.monospacedDigit())
            }
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.medium)
        .accessibilityElement(children: .contain)
    }

    /// E28 S6 (G13): true-peak detectors drawn with the shared bar instead of a text-only card.
    private func truePeakBarCard(title: String, id: String, linear: Float, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text(title).font(DesignType.caption.font).foregroundStyle(.secondary)
            Text(ProductionMeterMath.formattedDB(ProductionMeterMath.decibels(linear), suffix: peakSuffix))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .monospacedDigit()
            MeterBarView(
                channel: bank.channel(id: id, label: "TP"),
                paused: !windowVisible || page != .levels,
                onReset: { bank.channel(id: id, label: "TP").resetLatch(); meterRevision &+= 1 }
            )
            .id("\(id)-\(meterRevision)")
            Text(detail).font(DesignType.caption.font).foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.m.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designSurface(.medium)
    }

    /// E28 S6: the E9 protection readout for the physical output card whose label matches a protection lane.
    private func protectionText(for channel: ProductionTransportChannelMeter) -> String? {
        guard let lane = engine.outputProtectionLanes.first(where: { $0.label == channel.label }),
              let reading = protectionReadings[lane.index] else { return nil }
        var parts: [String] = []
        if let user = reading.userGainReductionDB { parts.append(String(format: "limiter %.1f dB", Double(user))) }
        parts.append(String(format: "hard limit %.1f dB", Double(reading.hardLimitGainReductionDB)))
        parts.append(ProductionOutputProtectionSection.peakDB(reading.outputTruePeakLinear))
        return parts.joined(separator: "  ·  ")
    }

    private func transportChannelCard(_ channel: ProductionTransportChannelMeter) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Text(channel.label).font(DesignType.sectionTitle.font)
                Spacer()
                Text("CH \(channel.channelIndex + 1)")
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            channelLevelRow(
                id: channel.id, label: "",
                peak: ProductionMeterMath.decibels(channel.peakLinear),
                rms: ProductionMeterMath.decibels(channel.rmsLinear)
            )
            HStack {
                Text("Over-range").font(DesignType.caption.font).foregroundStyle(.secondary)
                Spacer()
                Text("\(channel.overRangeSamples)").font(DesignType.caption.font.monospacedDigit())
            }
            if let text = protectionText(for: channel) {
                Text(text).font(DesignType.caption.font.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.medium)
    }

    private func stereoLevelCard(
        title: String,
        subtitle: String,
        stage: String,
        levels: ProductionStereoLevelSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text(title).font(DesignType.sectionTitle.font)
                Text(subtitle).font(DesignType.caption.font).foregroundStyle(.secondary)
            }

            channelLevelRow(id: "\(stage).L", label: "L", peak: levels.peakLeft, rms: levels.rmsLeft)
            channelLevelRow(id: "\(stage).R", label: "R", peak: levels.peakRight, rms: levels.rmsRight)

            Divider()
            HStack {
                Text("Over-range")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(levels.overRangeSamples)")
                    .font(DesignType.caption.font.monospacedDigit())
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designSurface(.large)
    }

    private func channelLevelRow(id: String, label: String, peak: Double, rms: Double) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            HStack {
                Text("Peak \(ProductionMeterMath.formattedDB(peak))")
                    .font(DesignType.caption.font.monospacedDigit())
                Spacer()
                Text("RMS \(ProductionMeterMath.formattedDB(rms))")
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            MeterBarView(
                channel: bank.channel(id: id, label: label.isEmpty ? "Ch" : label),
                paused: !windowVisible || page != .levels,
                onReset: { bank.channel(id: id, label: label).resetLatch(); meterRevision &+= 1 }
            )
            .id("\(id)-\(meterRevision)")
        }
    }

    private func normalizedLevel(_ db: Double) -> Double {
        min(max((db - ProductionMeterMath.floorDB) / -ProductionMeterMath.floorDB, 0), 1)
    }

    /// E28 S5: a gain-reduction card with the shared bar (the hub is the only reader, so the figures match the Dynamics page).
    private func grMetric(_ title: String, _ source: GainReductionSource, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text(title).font(DesignType.caption.font).foregroundStyle(.secondary)
            Text(ProductionMeterMath.formattedGain(value))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .monospacedDigit()
            GainReductionBar(monitor: GainReductionMonitor.shared(for: engine), source: source)
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .designSurface(.medium)
    }

    private func dynamicsMetric(_ title: String, _ value: Float) -> some View {
        metricCard(title: title, value: ProductionMeterMath.formattedGain(value), detail: nil)
    }

    private func metricCard(title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text(title).font(DesignType.caption.font).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .monospacedDigit()
            if let detail {
                Text(detail).font(DesignType.caption.font).foregroundStyle(.tertiary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .designSurface(.medium)
    }

    private func pendingAnalysisPage(title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: DesignSpacing.l.pt) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title).font(DesignType.sectionTitle.font)
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 620)
            Label("Analyzer pipeline parked", systemImage: "pause.circle.fill")
                .font(DesignType.caption.font.bold())
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 340)
        .designSurface(.large)
    }

    private func statusBanner(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(DesignSpacing.m.pt)
            .frame(maxWidth: .infinity, alignment: .leading)
            .designSurface(.medium)
    }

    private var loudnessSource: LoudnessSource {
        LoudnessSource(rawValue: loudnessSourceRaw) ?? .output
    }

    /// Loudness rides the capture ring through the stereo bit plus the worker's
    /// own loudness bit; the reset bit is a one-shot command.
    private static let loudnessDemand = UInt32(N60_ANALYSIS_DEMAND_STEREO) | ProductionAnalysisDemand.loudness

    private func resetLoudness() {
        inputTruePeakHold.reset()
        outputTruePeakHold.reset()
        if engine.lifecycleState == .running {
            engine.setAnalysisDemand(levelsDemand | ProductionAnalysisDemand.resetLoudness)
        }
    }

    /// Loudness plus, when the E33 cards are on, the worker's analysis-meter bit.
    private var levelsDemand: UInt32 {
        Self.loudnessDemand | (enhanced ? ProductionAnalysisDemand.analysisMeters | ProductionAnalysisDemand.bitActivity : 0)
    }

    /// E33 S10: detect is on only while the Levels page is visible and processing runs; the counts feed the card and History.
    @MainActor
    private func pollInputOvers(now: Date) {
        guard engine.lifecycleState == .running, let host = engine.dynamicsListenHost, host.setInputOverDetect(true) else {
            if inputOvers.shownSince != nil { inputOvers.hide() }
            return
        }
        let lanes = transportMeterSnapshot?.programChannels.count ?? 2
        guard let counts = host.inputOvers(lanes: max(lanes, 2)) else { return }
        let rate = transportMeterSnapshot?.sampleRate ?? transportDiagnostics?.outputSampleRate ?? 0
        inputOvers.update(counts: counts, sampleRate: rate, now: now)
        history.observeInputOvers(counts: counts, now: now)
    }

    private func resetInputOvers() {
        engine.dynamicsListenHost?.resetInputOvers()
        inputOvers.reset()
    }

    private func resetBitActivity() {
        if engine.lifecycleState == .running {
            engine.setAnalysisDemand(levelsDemand | ProductionAnalysisDemand.resetBitActivity)
        }
    }

    /// Demand for Spectrum while an E33 mode is selected.
    private var enhancedSpectrumDemand: UInt32 {
        switch spectrumMode {
        case .spectrum:
            return UInt32(N60_ANALYSIS_DEMAND_SPECTRUM)
        case .rta:
            return UInt32(N60_ANALYSIS_DEMAND_STEREO) | ProductionAnalysisDemand.rta
        case .spectrogram:
            return UInt32(N60_ANALYSIS_DEMAND_STEREO) | ProductionAnalysisDemand.spectrogram
                | (spectrogramWindow == .sixtySeconds ? ProductionAnalysisDemand.spectrogramLong : 0)
        }
    }

    private func resetAnalysisMeters() {
        if engine.lifecycleState == .running {
            engine.setAnalysisDemand(levelsDemand | ProductionAnalysisDemand.resetAnalysisMeters)
        }
    }

    private var ballistics: MeterBallistics {
        MeterBallistics(rawValue: ballisticsRaw) ?? .peak
    }

    @MainActor
    private func runVisiblePageLoop() async {
        let activePage = page
        var demandToken: UUID?
        if activePage == .levels, engine.lifecycleState == .running {
            demandToken = ProductionDetailedMeterDemand.acquire(engine: engine)
        }

        let analysisDemand: UInt32
        switch activePage {
        case .spectrum:
            analysisDemand = enhanced ? enhancedSpectrumDemand : UInt32(N60_ANALYSIS_DEMAND_SPECTRUM)
        case .stereo:
            analysisDemand = UInt32(N60_ANALYSIS_DEMAND_STEREO)
        case .levels:
            analysisDemand = levelsDemand
        case .dynamics, .transport:
            analysisDemand = UInt32(N60_ANALYSIS_DEMAND_NONE)
        }
        var analysisToken: UUID?
        if analysisDemand != 0, engine.lifecycleState == .running {
            analysisToken = Self.analysisDemandLedger(for: engine).acquire(analysisDemand)
        }

        let hub = ProductionMeterHub.shared(for: engine)
        let token = hub.subscribe(hertz: MeterPollPolicy.hertz(for: activePage))
        bank.clearTick()

        defer {
            hub.unsubscribe(token)
            if enhanced, activePage == .levels {
                engine.dynamicsListenHost?.setInputOverDetect(false)
                inputOvers.hide()
            }
            if let demandToken {
                ProductionDetailedMeterDemand.release(demandToken, engine: engine)
            }
            if let analysisToken {
                Self.analysisDemandLedger(for: engine).release(analysisToken)
            }
        }

        var lastRevisionBump = 0.0
        var drewOnce = false
        func work(now: Double) {
            bank.ingest(hub.take(token), mode: ballistics, now: now)
            refreshSnapshot(hub: hub)
            if enhanced, activePage == .levels { pollInputOvers(now: Date()) }
            if analysisDemand != 0, engine.lifecycleState == .running {
                analysisSnapshot = engine.productionAnalysisSnapshot()
            } else {
                analysisSnapshot = .empty
            }
            if now - lastRevisionBump >= 0.5 {
                lastRevisionBump = now
                meterRevision &+= 1
            }
        }

        while !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            let visible = hub.isWindowVisible
            windowVisible = visible
            let schedule = MeterPollPolicy.schedule(
                windowVisible: visible, isRunning: engine.lifecycleState == .running, page: activePage)
            let interval: UInt64
            switch schedule {
            case .idle:
                drewOnce = false
                interval = 250_000_000
            case .once:
                // Stopped and visible: one draw, then wait for a lifecycle change (the task id restarts the loop).
                if !drewOnce {
                    drewOnce = true
                    work(now: now)
                }
                interval = 250_000_000
            case .every(let hertz):
                drewOnce = false
                work(now: now)
                interval = UInt64(1_000_000_000.0 / hertz)
            }
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    private static var ledgers: [ObjectIdentifier: AnalysisDemandLedger] = [:]

    private static func analysisDemandLedger(for engine: AudioIOEngine) -> AnalysisDemandLedger {
        let key = ObjectIdentifier(engine)
        if let ledger = ledgers[key] { return ledger }
        let ledger = AnalysisDemandLedger { [weak engine] mask in engine?.setAnalysisDemand(mask) }
        ledgers[key] = ledger
        return ledger
    }

    @MainActor
    private func refreshSnapshot(hub: MeterReadbackHub<ProductionMeterContext>) {
        // While processing runs the hub is the only reader of the read-and-reset meters.
        if engine.lifecycleState == .running, let context = hub.latestContext {
            transportDiagnostics = context.diagnostics
            transportMeterSnapshot = context.transport
            routeMeters = context.routes
            protectionReadings = Dictionary(
                context.protection.map { ($0.lane, $0) }, uniquingKeysWith: { _, new in new })
        } else {
            routeMeters = []
            protectionReadings = [:]
            transportDiagnostics = engine.diagnosticsSnapshot()
            transportMeterSnapshot = engine.productionTransportMeterSnapshot()
        }
        if enhanced, engine.lifecycleState != .running { history.noteStopped() }
        guard engine.lifecycleState == .running else {
            snapshot = ProductionMetersSnapshot()
            return
        }
        if transportMeterSnapshot != nil {
            snapshot = ProductionMetersSnapshot()
            return
        }
        guard let diagnostics = transportDiagnostics?.renderKernelDiagnostics else {
            snapshot = ProductionMetersSnapshot()
            return
        }

        func levels(
            peakLeft: Float,
            peakRight: Float,
            rmsLeft: Float,
            rmsRight: Float,
            overRangeSamples: UInt64
        ) -> ProductionStereoLevelSnapshot {
            ProductionStereoLevelSnapshot(
                peakLeft: ProductionMeterMath.decibels(peakLeft),
                peakRight: ProductionMeterMath.decibels(peakRight),
                rmsLeft: ProductionMeterMath.decibels(rmsLeft),
                rmsRight: ProductionMeterMath.decibels(rmsRight),
                overRangeSamples: overRangeSamples
            )
        }

        if enhanced {
            headroomStrip.update(peaks: [
                "input": max(diagnostics.inputMeter.peakLeft, diagnostics.inputMeter.peakRight),
                "postEQ": max(diagnostics.postEQMeter.peakLeft, diagnostics.postEQMeter.peakRight),
                "output": max(diagnostics.outputMeter.peakLeft, diagnostics.outputMeter.peakRight),
            ])
        }
        inputTruePeakHold.update(dbtp: ProductionMeterMath.decibels(diagnostics.inputTruePeakLinear))
        outputTruePeakHold.update(dbtp: ProductionMeterMath.decibels(diagnostics.outputTruePeakLinear))
        snapshot = ProductionMetersSnapshot(
            input: levels(
                peakLeft: diagnostics.inputMeter.peakLeft,
                peakRight: diagnostics.inputMeter.peakRight,
                rmsLeft: diagnostics.inputMeter.rmsLeft,
                rmsRight: diagnostics.inputMeter.rmsRight,
                overRangeSamples: diagnostics.inputMeter.overRangeSamples
            ),
            postEQ: levels(
                peakLeft: diagnostics.postEQMeter.peakLeft,
                peakRight: diagnostics.postEQMeter.peakRight,
                rmsLeft: diagnostics.postEQMeter.rmsLeft,
                rmsRight: diagnostics.postEQMeter.rmsRight,
                overRangeSamples: diagnostics.postEQMeter.overRangeSamples
            ),
            output: levels(
                peakLeft: diagnostics.outputMeter.peakLeft,
                peakRight: diagnostics.outputMeter.peakRight,
                rmsLeft: diagnostics.outputMeter.rmsLeft,
                rmsRight: diagnostics.outputMeter.rmsRight,
                overRangeSamples: diagnostics.outputMeter.overRangeSamples
            ),
            inputTruePeakDBTP: ProductionMeterMath.decibels(diagnostics.inputTruePeakLinear),
            outputTruePeakDBTP: ProductionMeterMath.decibels(diagnostics.outputTruePeakLinear),
            sampleRate: diagnostics.sampleRate,
            latencyFrames: diagnostics.latencyFrames,
            meteringEnabled: diagnostics.meteringEnabled,
            compressorGainReductionDB: diagnostics.compressorGainReductionDB,
            deEsserGainReductionDB: diagnostics.deEsserGainReductionDB,
            multibandLowGainReductionDB: diagnostics.multibandLowGainReductionDB,
            multibandMidGainReductionDB: diagnostics.multibandMidGainReductionDB,
            multibandHighGainReductionDB: diagnostics.multibandHighGainReductionDB,
            expanderAttenuationDB: diagnostics.expanderAttenuationDB,
            limiterGainReductionDB: diagnostics.limiterGainReductionDB,
            gainRiderAttenuationDB: diagnostics.gainRiderAttenuationDB,
            loudnessShortTermLUFS: diagnostics.loudnessShortTermLUFS,
            loudnessMatchGainDB: diagnostics.loudnessMatchGainDB,
            dialogueBoostDB: diagnostics.dialogueBoostDB,
            dialogueVoiceConfidence: diagnostics.dialogueVoiceConfidence,
            denoiserMeanSuppressionDB: diagnostics.denoiserMeanSuppressionDB
        )
    }
}
