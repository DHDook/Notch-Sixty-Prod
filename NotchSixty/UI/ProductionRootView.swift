import Foundation
import SwiftUI

enum ProductionSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case equalizer
    case dynamics
    case speakerSetup
    case audio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .equalizer: return "Equalizer"
        case .dynamics: return "Dynamics"
        case .speakerSetup: return "Speaker Setup"
        case .audio: return "Audio"
        }
    }
    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .equalizer: return "slider.horizontal.3"
        case .dynamics: return "waveform.path.ecg"
        case .speakerSetup: return "hifispeaker.2.fill"
        case .audio: return "speaker.wave.3.fill"
        }
    }
}

enum ProductionVUScale {
    static let referenceDBFS = -18.0
    static let minimumVU = -20.0
    static let maximumVU = 3.0

    static func decibelsFS(fromLinear linear: Float) -> Double {
        guard linear.isFinite, linear > 0 else { return -.infinity }
        return 20 * log10(Double(linear))
    }

    static func vu(fromLinearRMS linear: Float) -> Double {
        let dbFS = decibelsFS(fromLinear: linear)
        guard dbFS.isFinite else { return minimumVU }
        return min(max(dbFS - referenceDBFS, minimumVU), maximumVU)
    }

    static func normalizedPosition(forVU vu: Double) -> Double {
        let value = min(max(vu, minimumVU), maximumVU)
        return (value - minimumVU) / (maximumVU - minimumVU)
    }

    static func smoothed(current: Double, target: Double) -> Double {
        current + (target - current) * (target > current ? 0.28 : 0.10)
    }
}

@MainActor
private enum ProductionMeteringDemand {
    private static var activeRequests: Set<UUID> = []

    static func acquire(for engine: AudioIOEngine) -> UUID {
        let token = UUID()
        let wasInactive = activeRequests.isEmpty
        activeRequests.insert(token)
        if wasInactive {
            apply(true, to: engine)
        }
        return token
    }

    static func release(_ token: UUID, for engine: AudioIOEngine) {
        guard activeRequests.remove(token) != nil else { return }
        if activeRequests.isEmpty {
            apply(false, to: engine)
        }
    }

    private static func apply(_ enabled: Bool, to engine: AudioIOEngine) {
        N60RealtimeAudioBridgeSetMeteringDemand(enabled)
        guard engine.lifecycleState == .running else { return }
        // Republish the current graph through an existing neutral control path.
        // The bridge injects the demand bit at publication time, so later DSP
        // updates preserve the visible-only metering state automatically.
        try? engine.setChannelBalance(engine.playbackControlConfiguration.balance)
    }
}

struct ProductionRootView: View {
    @ObservedObject var product: ProductController
    @Environment(\.openWindow) private var openWindow
    @State private var selection: ProductionSection? = .dashboard

    private var engine: AudioIOEngine { product.audioEngine }

    var body: some View {
        NavigationSplitView {
            List(ProductionSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage).tag(section)
            }
            .navigationTitle("Notch Sixty")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail(for: selection ?? .dashboard)
                .toolbar { toolbar }
        }
        .frame(minWidth: 980, minHeight: 680)
        .task { product.prepareForUse() }
    }

    @ViewBuilder
    private func detail(for section: ProductionSection) -> some View {
        switch section {
        case .dashboard:
            ProductionDashboardView(engine: engine) { selection = $0 }
        case .equalizer:
            ProductionPlaceholderPage(
                title: "Equalizer",
                subtitle: "Static and dynamic EQ, channel domains, and phase strategy.",
                systemImage: "slider.horizontal.3",
                detail: "The production graphical EQ editor follows on this UI foundation."
            )
        case .dynamics:
            ProductionPlaceholderPage(
                title: "Dynamics",
                subtitle: "Level control, protection, noise tools, and program-aware processing.",
                systemImage: "waveform.path.ecg",
                detail: "The dense dynamics editor will migrate from validation into this production workspace."
            )
        case .speakerSetup:
            ProductionSpeakerSetupView(engine: engine)
        case .audio:
            ProductionAudioView(engine: engine)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let output = engine.selectedOutputDevice {
                Text("\(output.name) · \(output.nominalSampleRate / 1_000, specifier: "%.1f") kHz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                openWindow(id: "engineering-validation")
            } label: {
                Label("Engineering Validation", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.glass)
            .help("Open the retained engineering validation tools")

            Button {
                if engine.lifecycleState == .running { engine.stop() }
                else { try? engine.start() }
            } label: {
                Label(
                    engine.lifecycleState == .running ? "Stop Processing" : "Start Processing",
                    systemImage: engine.lifecycleState == .running ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.glassProminent)
            .disabled(engine.lifecycleState != .idle && engine.lifecycleState != .running)
        }
    }
}

private struct ProductionDashboardView: View {
    @ObservedObject var engine: AudioIOEngine
    let navigate: (ProductionSection) -> Void
    @State private var leftVU = ProductionVUScale.minimumVU
    @State private var rightVU = ProductionVUScale.minimumVU
    @State private var leftPeak = -120.0
    @State private var rightPeak = -120.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Listening Dashboard").font(.largeTitle.bold())
                        Text(outputSummary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(engine.lifecycleState == .running ? "PROCESSING" : engine.lifecycleState.rawValue.uppercased())
                        .font(.caption.bold())
                        .tracking(1.2)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("OUTPUT").font(.caption.bold()).tracking(1.8).foregroundStyle(.secondary)
                        Spacer()
                        Text("0 VU = −18 dBFS").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 18) {
                        SignatureVUMeter(channel: "LEFT", vu: leftVU, peakDBFS: leftPeak)
                        SignatureVUMeter(channel: "RIGHT", vu: rightVU, peakDBFS: rightPeak)
                    }
                    .frame(minHeight: 285)
                }

                masterControls

                HStack(alignment: .top, spacing: 16) {
                    summaryCard(
                        title: "Equalizer",
                        text: "\(engine.stereoEQConfiguration.enabledBandCount) bands · \(engine.stereoEQConfiguration.phaseMode.displayName)",
                        systemImage: "slider.horizontal.3",
                        destination: .equalizer
                    )
                    summaryCard(
                        title: "Dynamics",
                        text: dynamicsSummary,
                        systemImage: "waveform.path.ecg",
                        destination: .dynamics
                    )
                    summaryCard(
                        title: "Speaker Setup",
                        text: "Active crossover and room correction are kept in a dedicated calibration workspace.",
                        systemImage: "hifispeaker.2.fill",
                        destination: .speakerSetup
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .topLeading)
        }
        .navigationTitle("Dashboard")
        .task(id: engine.lifecycleState) { await runMeterLoop() }
    }

    private var outputSummary: String {
        guard let output = engine.selectedOutputDevice else { return "Choose an output in Audio to begin." }
        return "\(output.name) · \(String(format: "%.1f", output.nominalSampleRate / 1_000)) kHz"
    }

    private var dynamicsSummary: String {
        let d = engine.dynamicsConfiguration
        var names: [String] = []
        if d.compressor.enabled { names.append("Compressor") }
        if d.expander.enabled { names.append("Expander") }
        if d.pauseGate.enabled { names.append("Pause Gate") }
        if d.spectralDenoiser.enabled { names.append("Denoiser") }
        if d.limiter.enabled { names.append("Limiter") }
        return names.isEmpty ? "No dynamics processors enabled." : names.joined(separator: " · ")
    }

    private var masterControls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                Button {
                    try? engine.setMasterMuted(!engine.masterVolumeConfiguration.muted)
                } label: {
                    Image(systemName: engine.masterVolumeConfiguration.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Master Volume").font(.subheadline.bold())
                        Spacer()
                        Text("\(engine.masterVolumeConfiguration.level * 100, specifier: "%.0f")%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { engine.masterVolumeConfiguration.level },
                            set: { try? engine.setMasterVolumeLevel($0) }
                        ),
                        in: MasterVolumeConfiguration.levelRange
                    )
                }

                Divider().frame(height: 34)
                Button {
                    try? engine.setGlobalDSPBypassed(!engine.playbackControlConfiguration.globalBypassed)
                } label: {
                    Label(
                        engine.playbackControlConfiguration.globalBypassed ? "Bypassed" : "DSP Active",
                        systemImage: engine.playbackControlConfiguration.globalBypassed ? "pause.circle" : "waveform.path"
                    )
                }
                .buttonStyle(.glass)
            }
            .padding(14)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        }
    }

    private func summaryCard(
        title: String,
        text: String,
        systemImage: String,
        destination: ProductionSection
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
            Button("Open") { navigate(destination) }.buttonStyle(.glass)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))
    }

    @MainActor
    private func runMeterLoop() async {
        guard engine.lifecycleState == .running else {
            resetMeters()
            return
        }

        let demandToken = ProductionMeteringDemand.acquire(for: engine)
        defer {
            ProductionMeteringDemand.release(demandToken, for: engine)
            resetMeters()
        }

        while !Task.isCancelled && engine.lifecycleState == .running {
            if let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics,
               diagnostics.meteringEnabled {
                let meter = diagnostics.outputMeter
                leftVU = ProductionVUScale.smoothed(
                    current: leftVU,
                    target: ProductionVUScale.vu(fromLinearRMS: meter.rmsLeft)
                )
                rightVU = ProductionVUScale.smoothed(
                    current: rightVU,
                    target: ProductionVUScale.vu(fromLinearRMS: meter.rmsRight)
                )
                leftPeak = ProductionVUScale.decibelsFS(fromLinear: meter.peakLeft)
                rightPeak = ProductionVUScale.decibelsFS(fromLinear: meter.peakRight)
            }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func resetMeters() {
        leftVU = ProductionVUScale.minimumVU
        rightVU = ProductionVUScale.minimumVU
        leftPeak = -120
        rightPeak = -120
    }
}

private struct SignatureVUMeter: View {
    let channel: String
    let vu: Double
    let peakDBFS: Double

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width * 0.5, y: proxy.size.height * 0.82)
            let radius = min(proxy.size.width * 0.43, proxy.size.height * 0.72)
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.94, green: 0.89, blue: 0.73),
                            Color(red: 0.82, green: 0.75, blue: 0.57),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .overlay { RoundedRectangle(cornerRadius: 24).stroke(.black.opacity(0.28)) }
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)

                Canvas { context, _ in
                    drawScale(context: &context, center: center, radius: radius)
                    drawNeedle(context: &context, center: center, radius: radius)
                }

                VStack(spacing: 3) {
                    Text("NOTCH SIXTY").font(.caption2.bold()).tracking(2)
                    Text(channel).font(.headline.bold())
                    Text(peakText).font(.caption.monospacedDigit())
                }
                .foregroundStyle(.black.opacity(0.70))
                .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.62)
            }
        }
        .aspectRatio(1.65, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(channel) VU meter")
        .accessibilityValue("\(vu, specifier: "%.1f") VU")
    }

    private var peakText: String {
        peakDBFS.isFinite && peakDBFS > -119
            ? "PEAK \(String(format: "%.1f", peakDBFS)) dBFS"
            : "PEAK −∞ dBFS"
    }

    private func drawScale(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let ticks: [Double] = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
        let labels: Set<Double> = [-20, -10, -7, -5, -3, 0, 3]
        var arc = Path()
        arc.addArc(center: center, radius: radius, startAngle: .degrees(128), endAngle: .degrees(232), clockwise: false)
        context.stroke(arc, with: .color(.black.opacity(0.62)), lineWidth: 1.3)

        for value in ticks {
            let angle = meterAngle(value)
            let inner = point(center, radius * (labels.contains(value) ? 0.87 : 0.91), angle)
            let outer = point(center, radius, angle)
            var path = Path(); path.move(to: inner); path.addLine(to: outer)
            context.stroke(path, with: .color(value > 0 ? .red.opacity(0.8) : .black.opacity(0.72)), lineWidth: labels.contains(value) ? 2 : 1)
            if labels.contains(value) {
                let p = point(center, radius * 0.76, angle)
                let label = value > 0 ? "+\(Int(value))" : "\(Int(value))"
                context.draw(
                    Text(label)
                        .font(.system(size: 12, weight: value == 0 ? .bold : .medium, design: .rounded))
                        .foregroundStyle(value > 0 ? Color.red : Color.black.opacity(0.72)),
                    at: p
                )
            }
        }
        context.draw(Text("VU").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.72)),
                     at: CGPoint(x: center.x, y: center.y - radius * 0.43))
    }

    private func drawNeedle(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let angle = meterAngle(vu)
        var path = Path()
        path.move(to: point(center, -radius * 0.12, angle))
        path.addLine(to: point(center, radius * 0.92, angle))
        context.stroke(path, with: .color(.red.opacity(0.92)), lineWidth: 2.2)
        context.fill(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)), with: .color(.black.opacity(0.8)))
    }

    private func meterAngle(_ value: Double) -> Double {
        128 + ProductionVUScale.normalizedPosition(forVU: value) * 104
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }
}

private struct ProductionSpeakerSetupView: View {
    @ObservedObject var engine: AudioIOEngine
    @State private var roomCorrectionSelected = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Speaker Setup", "System calibration is intentionally separated from day-to-day listening controls.")
                Picker("Workspace", selection: $roomCorrectionSelected) {
                    Text("Active Crossover").tag(false)
                    Text("Room Correction").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                if roomCorrectionSelected { roomCorrectionPanel }
                else { crossoverPanel }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
        .navigationTitle("Speaker Setup")
    }

    private var crossoverPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Enable Active Crossover", isOn: Binding(
                get: { engine.bassManagementConfiguration.enabled },
                set: { value in updateCrossover { $0.enabled = value } }
            )).toggleStyle(.switch)

            LabeledContent("Crossover Frequency") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.frequencyHz },
                        set: { value in updateCrossover { $0.frequencyHz = value } }
                    ), in: BassManagementConfiguration.frequencyRange, step: 1)
                    .frame(width: 300)
                    Text("\(engine.bassManagementConfiguration.frequencyHz, specifier: "%.0f") Hz").monospacedDigit()
                }
            }

            LabeledContent("Topology") {
                Picker("Topology", selection: Binding(
                    get: { engine.bassManagementConfiguration.topology },
                    set: { value in updateCrossover { $0.topology = value } }
                )) {
                    ForEach(CrossoverTopology.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 260)
            }

            Toggle("Invert Sub Polarity", isOn: Binding(
                get: { engine.bassManagementConfiguration.subPolarityInverted },
                set: { value in updateCrossover { $0.subPolarityInverted = value } }
            )).toggleStyle(.switch)
        }
        .padding(20)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))
    }

    private var roomCorrectionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Correction Filter").font(.headline)
                    Text(engine.roomCorrectionConfiguration.filter?.name ?? "No correction filter loaded")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { engine.roomCorrectionConfiguration.enabled },
                    set: { try? engine.setRoomCorrectionEnabled($0) }
                ))
                .disabled(engine.roomCorrectionConfiguration.filter == nil)
            }
            ContentUnavailableView(
                "Measurement & Filter Import",
                systemImage: "waveform.badge.magnifyingglass",
                description: Text("The production multi-seat measurement, target-curve, and correction workflow will live here.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        }
        .padding(20)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))
    }

    private func updateCrossover(_ mutation: (inout BassManagementConfiguration) -> Void) {
        var updated = engine.bassManagementConfiguration
        mutation(&updated)
        try? engine.replaceBassManagementConfiguration(updated)
    }
}

private struct ProductionAudioView: View {
    @ObservedObject var engine: AudioIOEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader("Audio", "Physical output routing and processing transport.")
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Output Device") {
                        Picker("Output Device", selection: Binding(
                            get: { engine.routeConfiguration.selectedOutputUID },
                            set: { try? engine.selectOutput(uid: $0) }
                        )) {
                            Text("No Output").tag(String?.none)
                            ForEach(engine.outputDevices) { device in
                                Text(device.name).tag(Optional(device.uid))
                            }
                        }
                        .labelsHidden().frame(width: 340)
                        .disabled(engine.lifecycleState != .idle)
                    }
                    if let output = engine.selectedOutputDevice {
                        LabeledContent("Nominal Sample Rate", value: "\(String(format: "%.1f", output.nominalSampleRate / 1_000)) kHz")
                    }
                    LabeledContent("Processing State", value: engine.lifecycleState.rawValue.capitalized)
                    HStack {
                        Button("Refresh Devices") { try? engine.refreshOutputDevices() }.buttonStyle(.glass)
                        Button(engine.lifecycleState == .running ? "Stop Processing" : "Start Processing") {
                            if engine.lifecycleState == .running { engine.stop() }
                            else { try? engine.start() }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(engine.lifecycleState != .idle && engine.lifecycleState != .running)
                    }
                    if let error = engine.lastErrorDescription {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .padding(20)
                .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
        .navigationTitle("Audio")
    }
}

private struct ProductionPlaceholderPage: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader(title, subtitle)
            ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(28)
        .navigationTitle(title)
    }
}

@ViewBuilder
private func pageHeader(_ title: String, _ subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.largeTitle.bold())
        Text(subtitle).foregroundStyle(.secondary)
    }
}
