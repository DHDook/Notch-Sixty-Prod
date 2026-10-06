import Foundation
import SwiftUI

private enum ProductionMetersPage: String, CaseIterable, Identifiable {
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

private enum ProductionMeterMath {
    static let floorDB = -60.0

    static func decibels(_ linear: Float) -> Double {
        guard linear.isFinite, linear > 0 else { return floorDB }
        return max(20.0 * log10(Double(linear)), floorDB)
    }

    static func formattedDB(_ value: Double, suffix: String = "dBFS") -> String {
        guard value.isFinite else { return "−∞ \(suffix)" }
        return String(format: "%.1f %@", value, suffix)
    }

    static func formattedGain(_ value: Float) -> String {
        String(format: "%.1f dB", Double(value))
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

struct ProductionMetersView: View {
    @ObservedObject var engine: AudioIOEngine
    @State private var page: ProductionMetersPage = .levels
    @State private var snapshot = ProductionMetersSnapshot()
    @State private var analysisSnapshot = ProductionAnalysisSnapshot.empty
    @State private var transportMeterSnapshot: ProductionTransportMeterSnapshot?
    @State private var transportDiagnostics: AudioDiagnosticsSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                pagePicker

                switch page {
                case .levels:
                    levelsPage
                case .spectrum:
                    ProductionSpectrumView(
                        snapshot: analysisSnapshot,
                        isRunning: engine.lifecycleState == .running,
                        resetPeakHold: { engine.resetSpectrumPeakHold() }
                    )
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
            .padding(28)
            .frame(maxWidth: 1180, alignment: .topLeading)
        }
        .task(id: "\(engine.lifecycleState.rawValue)|\(page.rawValue)") {
            await runVisiblePageLoop()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Meters & Analysis").font(.largeTitle.bold())
                Text("Signal levels, spectrum, stereo field, and gain structure — with hidden analysis parked.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(engine.lifecycleState == .running ? "LIVE" : "IDLE")
                .font(.caption.bold())
                .tracking(1.2)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var pagePicker: some View {
        Picker("Meter Page", selection: $page) {
            ForEach(ProductionMetersPage.allCases) { page in
                Label(page.title, systemImage: page.systemImage).tag(page)
            }
        }
        .productionGlassPickerChrome()
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 720)
    }

    @ViewBuilder
    private var levelsPage: some View {
        if let transportMeterSnapshot {
            semanticLevelsPage(transportMeterSnapshot)
        } else {
            legacyLevelsPage
        }
    }

    private var legacyLevelsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if engine.lifecycleState != .running {
                statusBanner("Start processing to view live detailed meters. The detailed meter pipeline remains parked while processing is stopped.")
            } else if !snapshot.meteringEnabled {
                statusBanner("Detailed metering is activating…")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                stereoLevelCard(title: "Input", subtitle: "Render input", levels: snapshot.input)
                stereoLevelCard(title: "Post-EQ", subtitle: "After the main EQ stage", levels: snapshot.postEQ)
                stereoLevelCard(title: "Output", subtitle: "Final DSP output", levels: snapshot.output)
            }

            HStack(alignment: .top, spacing: 14) {
                metricCard(
                    title: "Input True Peak",
                    value: ProductionMeterMath.formattedDB(snapshot.inputTruePeakDBTP, suffix: "dBTP"),
                    detail: "Authoritative protection detector"
                )
                metricCard(
                    title: "Output True Peak",
                    value: ProductionMeterMath.formattedDB(snapshot.outputTruePeakDBTP, suffix: "dBTP"),
                    detail: "Authoritative protection detector"
                )
                metricCard(
                    title: "Processing",
                    value: snapshot.sampleRate > 0 ? String(format: "%.1f kHz", snapshot.sampleRate / 1_000.0) : "—",
                    detail: snapshot.sampleRate > 0
                        ? "Float32 stereo · \(snapshot.latencyFrames) frame published latency"
                        : "No active render format"
                )
            }

            Text("Peak and RMS are shown in dBFS. True Peak is sourced from the existing protection telemetry rather than a second meter implementation. Detailed level accumulation is enabled only while this Levels page is visible.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func semanticLevelsPage(_ transport: ProductionTransportMeterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if engine.lifecycleState != .running {
                statusBanner("Start processing to view live semantic meters.")
            } else if !transport.meteringEnabled {
                statusBanner("Detailed semantic metering is activating…")
            }

            HStack(alignment: .top, spacing: 14) {
                metricCard(title: "Mode", value: transport.kind.displayName, detail: transport.displayName)
                metricCard(
                    title: "Processing",
                    value: String(format: "%.1f kHz", transport.sampleRate / 1_000.0),
                    detail: "\(transport.latencyFrames) frame maximum configured path latency"
                )
                metricCard(
                    title: "Realtime Health",
                    value: transport.renderFailures == 0 && transport.outputWriteFailures == 0 ? "Clean" : "Attention",
                    detail: "\(transport.renderFailures) render · \(transport.outputWriteFailures) output failures"
                )
            }

            if !transport.programChannels.isEmpty {
                Text("Semantic Program Channels").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(transport.programChannels) { channel in transportChannelCard(channel) }
                }
            }

            Text(transport.kind == .virtualSpeakers ? "Headphone Output" : "Physical Outputs")
                .font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(transport.physicalOutputs) { channel in transportChannelCard(channel) }
            }

            if let input = transport.inputTruePeakLinear, let output = transport.outputTruePeakLinear {
                HStack(alignment: .top, spacing: 14) {
                    metricCard(
                        title: "Spatial Input True Peak",
                        value: ProductionMeterMath.formattedDB(ProductionMeterMath.decibels(input), suffix: "dBTP"),
                        detail: "Downstream protection detector"
                    )
                    metricCard(
                        title: "Headphone Output True Peak",
                        value: ProductionMeterMath.formattedDB(ProductionMeterMath.decibels(output), suffix: "dBTP"),
                        detail: "After headphone correction and protection"
                    )
                }
            }

            Text("Semantic program meters are measured after per-channel lane processing. Physical meters are measured after bass management, optional hardware-gated room treatment, Sub N routing, startup fade, and master output gain. Meter work is demand-driven and parked when this Levels page is hidden.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transportPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            let diagnostics = transportDiagnostics
            let current = transportMeterSnapshot
            Text("Transport & Recovery").font(.title2.bold())
            Text("Live transport state, published latency, buffer health, and selected-device recovery policy.")
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
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
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Text("Recovery remains pinned to the selected stable device UID. Notch Sixty does not silently follow the macOS default output or substitute a different device after disconnect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dynamicsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gain Structure")
                .font(.title2.bold())
            Text("Existing processor telemetry is summarized here without enabling the detailed Input / Post-EQ / Output meter accumulator.")
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                dynamicsMetric("Compressor GR", snapshot.compressorGainReductionDB)
                dynamicsMetric("De-Esser GR", snapshot.deEsserGainReductionDB)
                dynamicsMetric("Multiband Low GR", snapshot.multibandLowGainReductionDB)
                dynamicsMetric("Multiband Mid GR", snapshot.multibandMidGainReductionDB)
                dynamicsMetric("Multiband High GR", snapshot.multibandHighGainReductionDB)
                dynamicsMetric("Expander Attenuation", snapshot.expanderAttenuationDB)
                dynamicsMetric("Limiter GR", snapshot.limiterGainReductionDB)
                dynamicsMetric("Gain Rider", snapshot.gainRiderAttenuationDB)
                dynamicsMetric("Denoiser Suppression", snapshot.denoiserMeanSuppressionDB)

                metricCard(
                    title: "Short-Term Loudness",
                    value: String(format: "%.1f LUFS", Double(snapshot.loudnessShortTermLUFS)),
                    detail: String(format: "Loudness Match %.1f dB", Double(snapshot.loudnessMatchGainDB))
                )
                metricCard(
                    title: "Dialogue",
                    value: String(format: "%+.1f dB", Double(snapshot.dialogueBoostDB)),
                    detail: String(format: "Voice confidence %.0f%%", Double(snapshot.dialogueVoiceConfidence * 100))
                )
            }

            Text("This page intentionally avoids the historical misleading ISP, fake bit-stream, and pseudo-standard DR-factor displays. Those are not part of the commercial meter contract.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func transportChannelCard(_ channel: ProductionTransportChannelMeter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(channel.label).font(.headline)
                Spacer()
                Text("CH \(channel.channelIndex + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            channelLevelRow(
                label: "",
                peak: ProductionMeterMath.decibels(channel.peakLinear),
                rms: ProductionMeterMath.decibels(channel.rmsLinear)
            )
            HStack {
                Text("Over-range").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(channel.overRangeSamples)").font(.caption.monospacedDigit())
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 16))
    }

    private func stereoLevelCard(
        title: String,
        subtitle: String,
        levels: ProductionStereoLevelSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            channelLevelRow(label: "L", peak: levels.peakLeft, rms: levels.rmsLeft)
            channelLevelRow(label: "R", peak: levels.peakRight, rms: levels.rmsRight)

            Divider()
            HStack {
                Text("Over-range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(levels.overRangeSamples)")
                    .font(.caption.monospacedDigit())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.24), in: .rect(cornerRadius: 18))
    }

    private func channelLevelRow(label: String, peak: Double, rms: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.caption.bold()).frame(width: 18, alignment: .leading)
                Text("Peak \(ProductionMeterMath.formattedDB(peak))")
                    .font(.caption.monospacedDigit())
                Spacer()
                Text("RMS \(ProductionMeterMath.formattedDB(rms))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let rmsWidth = proxy.size.width * normalizedLevel(rms)
                let peakPosition = proxy.size.width * normalizedLevel(peak)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.primary.opacity(0.55)).frame(width: rmsWidth)
                    Rectangle().fill(.primary).frame(width: 2).offset(x: max(0, peakPosition - 1))
                }
            }
            .frame(height: 8)
        }
    }

    private func normalizedLevel(_ db: Double) -> Double {
        min(max((db - ProductionMeterMath.floorDB) / -ProductionMeterMath.floorDB, 0), 1)
    }

    private func dynamicsMetric(_ title: String, _ value: Float) -> some View {
        metricCard(title: title, value: ProductionMeterMath.formattedGain(value), detail: nil)
    }

    private func metricCard(title: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .monospacedDigit()
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 16))
    }

    private func pendingAnalysisPage(title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 620)
            Label("Analyzer pipeline parked", systemImage: "pause.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 340)
        .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 22))
    }

    private func statusBanner(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 12))
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
            analysisDemand = UInt32(N60_ANALYSIS_DEMAND_SPECTRUM)
        case .stereo:
            analysisDemand = UInt32(N60_ANALYSIS_DEMAND_STEREO)
        case .levels, .dynamics, .transport:
            analysisDemand = UInt32(N60_ANALYSIS_DEMAND_NONE)
        }
        if analysisDemand != 0, engine.lifecycleState == .running {
            engine.setAnalysisDemand(analysisDemand)
        }

        defer {
            if let demandToken {
                ProductionDetailedMeterDemand.release(demandToken, engine: engine)
            }
            if analysisDemand != 0 {
                engine.setAnalysisDemand(UInt32(N60_ANALYSIS_DEMAND_NONE))
            }
        }

        while !Task.isCancelled {
            refreshSnapshot()
            if analysisDemand != 0, engine.lifecycleState == .running {
                analysisSnapshot = engine.productionAnalysisSnapshot()
            } else {
                analysisSnapshot = .empty
            }

            let interval: UInt64
            switch activePage {
            case .levels, .stereo:
                interval = 16_666_667
            case .spectrum:
                interval = 50_000_000
            case .dynamics:
                interval = 125_000_000
            case .transport:
                interval = 250_000_000
            }
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    @MainActor
    private func refreshSnapshot() {
        transportDiagnostics = engine.diagnosticsSnapshot()
        transportMeterSnapshot = engine.productionTransportMeterSnapshot()
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
