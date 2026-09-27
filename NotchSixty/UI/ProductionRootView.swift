import Foundation
import SwiftUI

enum ProductionSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case equalizer
    case dynamics
    case meters
    case activeCrossover
    case roomCorrection

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .equalizer: return "Equalizer"
        case .dynamics: return "Dynamics"
        case .meters: return "Meters"
        case .activeCrossover: return "Active Crossover"
        case .roomCorrection: return "Room Correction"
        }
    }
    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .equalizer: return "slider.horizontal.3"
        case .dynamics: return "waveform.path.ecg"
        case .meters: return "chart.xyaxis.line"
        case .activeCrossover: return "hifispeaker.2.fill"
        case .roomCorrection: return "waveform.badge.magnifyingglass"
        }
    }
}

enum ProductionVUScale {
    static let referenceDBFS = -18.0
    static let minimumVU = -30.0
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
        // 20 Hz UI updates with mechanical-style attack/release.
        current + (target - current) * (target > current ? 0.39 : 0.15)
    }

    static func angle(forVU vu: Double) -> Double {
        205 + normalizedPosition(forVU: vu) * 130
    }

    static func point(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }
}

@MainActor
private enum ProductionOutputVUMeterDemand {
    private static var activeRequests: Set<UUID> = []

    static func acquire() -> UUID {
        let token = UUID()
        let wasInactive = activeRequests.isEmpty
        activeRequests.insert(token)
        if wasInactive {
            N60RealtimeAudioBridgeSetOutputVUMeterDemand(true)
        }
        return token
    }

    static func release(_ token: UUID) {
        guard activeRequests.remove(token) != nil else { return }
        if activeRequests.isEmpty {
            N60RealtimeAudioBridgeSetOutputVUMeterDemand(false)
        }
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
            ProductionDashboardView(engine: engine)
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
        case .meters:
            ProductionPlaceholderPage(
                title: "Meters",
                subtitle: "Detailed signal, loudness, protection, and analysis telemetry.",
                systemImage: "chart.xyaxis.line",
                detail: "Each detailed meter or analyzer will request only its own pipeline so hidden analysis remains parked."
            )
        case .activeCrossover:
            ProductionActiveCrossoverView(engine: engine)
        case .roomCorrection:
            ProductionRoomCorrectionView(engine: engine)
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

                StereoSignatureVUMeterPanel(engine: engine)

                audioControls
                masterControls

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
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
                        title: "Active Crossover",
                        text: crossoverSummary,
                        systemImage: "hifispeaker.2.fill"
                    )
                    summaryCard(
                        title: "Room Correction",
                        text: roomCorrectionSummary,
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .topLeading)
        }
        .navigationTitle("Dashboard")
    }

    private var outputSummary: String {
        guard let output = engine.selectedOutputDevice else { return "Choose an output below to begin." }
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

    private var crossoverSummary: String {
        let c = engine.bassManagementConfiguration
        guard c.enabled else { return "Off" }
        return "\(c.frequencyHz, specifier: "%.0f") Hz · \(c.topology.displayName)"
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("Output Device").font(.subheadline.bold())
                Picker("Output Device", selection: Binding(
                    get: { engine.routeConfiguration.selectedOutputUID },
                    set: { try? engine.selectOutput(uid: $0) }
                )) {
                    Text("No Output").tag(String?.none)
                    ForEach(engine.outputDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                .disabled(engine.lifecycleState != .idle)

                Button {
                    try? engine.refreshOutputDevices()
                } label: {
                    Label("Refresh Outputs", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(engine.lifecycleState != .idle)

                Spacer()
                Text(engine.lifecycleState.rawValue.capitalized)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            if let error = engine.lastErrorDescription {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 18))
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
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))
    }
}

private struct StereoSignatureVUMeterPanel: View {
    @ObservedObject var engine: AudioIOEngine
    @AppStorage("production.vuMetersEnabled") private var vuMetersEnabled = true
    @State private var leftVU = ProductionVUScale.minimumVU
    @State private var rightVU = ProductionVUScale.minimumVU

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("OUTPUT").font(.caption.bold()).tracking(1.8).foregroundStyle(.secondary)
                Spacer()
                Toggle("VU Meters", isOn: $vuMetersEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("0 VU = −18 dBFS").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }

            StereoSignatureVUMeter(leftVU: leftVU, rightVU: rightVU)
                .frame(minHeight: 285)
        }
        .task(id: "\(engine.lifecycleState.rawValue)|\(vuMetersEnabled)") { await runMeterLoop() }
    }

    @MainActor
    private func runMeterLoop() async {
        guard engine.lifecycleState == .running, vuMetersEnabled else {
            resetMeters()
            return
        }

        let demandToken = ProductionOutputVUMeterDemand.acquire()
        defer {
            ProductionOutputVUMeterDemand.release(demandToken)
            resetMeters()
        }

        while !Task.isCancelled && engine.lifecycleState == .running && vuMetersEnabled {
            if let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics {
                let meter = diagnostics.outputMeter
                leftVU = ProductionVUScale.smoothed(
                    current: leftVU,
                    target: ProductionVUScale.vu(fromLinearRMS: meter.rmsLeft)
                )
                rightVU = ProductionVUScale.smoothed(
                    current: rightVU,
                    target: ProductionVUScale.vu(fromLinearRMS: meter.rmsRight)
                )
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func resetMeters() {
        leftVU = ProductionVUScale.minimumVU
        rightVU = ProductionVUScale.minimumVU
    }
}

private struct StereoSignatureVUMeter: View {
    let leftVU: Double
    let rightVU: Double

    var body: some View {
        GeometryReader { proxy in
            let leftCenter = CGPoint(x: proxy.size.width * 0.28, y: proxy.size.height * 0.87)
            let rightCenter = CGPoint(x: proxy.size.width * 0.72, y: proxy.size.height * 0.87)
            let radius = min(proxy.size.width * 0.205, proxy.size.height * 0.74)

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.94, green: 0.89, blue: 0.73),
                            Color(red: 0.82, green: 0.75, blue: 0.57),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .overlay { RoundedRectangle(cornerRadius: 26).stroke(.black.opacity(0.28)) }
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)

                StereoSignatureVUScaleFace(
                    leftCenter: leftCenter,
                    rightCenter: rightCenter,
                    radius: radius
                )
                .equatable()

                Canvas { context, _ in
                    drawNeedle(
                        context: &context,
                        center: leftCenter,
                        radius: radius,
                        vu: leftVU
                    )
                    drawNeedle(
                        context: &context,
                        center: rightCenter,
                        radius: radius,
                        vu: rightVU
                    )
                }

                Text("LEFT")
                    .font(.caption.bold())
                    .tracking(1.5)
                    .foregroundStyle(.black.opacity(0.64))
                    .position(x: proxy.size.width * 0.28, y: proxy.size.height * 0.67)

                Text("RIGHT")
                    .font(.caption.bold())
                    .tracking(1.5)
                    .foregroundStyle(.black.opacity(0.64))
                    .position(x: proxy.size.width * 0.72, y: proxy.size.height * 0.67)

                VStack(spacing: 3) {
                    Text("NOTCH SIXTY")
                        .font(.subheadline.bold())
                        .tracking(3)
                    Text("STEREO VU")
                        .font(.caption2.bold())
                        .tracking(1.7)
                }
                .foregroundStyle(.black.opacity(0.72))
                .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.80)
            }
        }
        .aspectRatio(3.2, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stereo output VU meter")
        .accessibilityValue("Left \(leftVU, specifier: "%.1f") VU, right \(rightVU, specifier: "%.1f") VU")
    }

    private func drawNeedle(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        vu: Double
    ) {
        let angle = ProductionVUScale.angle(forVU: vu)
        var path = Path()
        path.move(to: ProductionVUScale.point(center: center, radius: -radius * 0.10, angle: angle))
        path.addLine(to: ProductionVUScale.point(center: center, radius: radius * 0.92, angle: angle))
        context.stroke(path, with: .color(.red.opacity(0.92)), lineWidth: 2.2)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)),
            with: .color(.black.opacity(0.8))
        )
    }
}

private struct StereoSignatureVUScaleFace: View, Equatable {
    let leftCenter: CGPoint
    let rightCenter: CGPoint
    let radius: CGFloat

    var body: some View {
        Canvas { context, _ in
            drawScale(context: &context, center: leftCenter)
            drawScale(context: &context, center: rightCenter)
        }
    }

    private func drawScale(context: inout GraphicsContext, center: CGPoint) {
        let ticks: [Double] = [-30, -20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
        let labels: Set<Double> = [-30, -20, -10, -5, -3, 0, 3]
        var arc = Path()
        arc.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(205),
            endAngle: .degrees(335),
            clockwise: false
        )
        context.stroke(arc, with: .color(.black.opacity(0.62)), lineWidth: 1.3)

        for value in ticks {
            let angle = ProductionVUScale.angle(forVU: value)
            let inner = ProductionVUScale.point(
                center: center,
                radius: radius * (labels.contains(value) ? 0.87 : 0.91),
                angle: angle
            )
            let outer = ProductionVUScale.point(center: center, radius: radius, angle: angle)
            var path = Path()
            path.move(to: inner)
            path.addLine(to: outer)
            context.stroke(
                path,
                with: .color(value > 0 ? .red.opacity(0.8) : .black.opacity(0.72)),
                lineWidth: labels.contains(value) ? 2 : 1
            )
            if labels.contains(value) {
                let point = ProductionVUScale.point(center: center, radius: radius * 0.76, angle: angle)
                let label = value > 0 ? "+\(Int(value))" : "\(Int(value))"
                context.draw(
                    Text(label)
                        .font(.system(size: 11, weight: value == 0 ? .bold : .medium, design: .rounded))
                        .foregroundStyle(value > 0 ? Color.red : Color.black.opacity(0.72)),
                    at: point
                )
            }
        }

        context.draw(
            Text("VU")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.black.opacity(0.72)),
            at: CGPoint(x: center.x, y: center.y - radius * 0.43)
        )
    }
}

private struct ProductionActiveCrossoverView: View {
    @ObservedObject var engine: AudioIOEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(
                    "Active Crossover",
                    "Bass-management and main/sub integration controls live in their own calibration workspace."
                )

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
                            Text("\(engine.bassManagementConfiguration.frequencyHz, specifier: "%.0f") Hz")
                                .monospacedDigit()
                        }
                    }

                    LabeledContent("Topology") {
                        Picker("Topology", selection: Binding(
                            get: { engine.bassManagementConfiguration.topology },
                            set: { value in updateCrossover { $0.topology = value } }
                        )) {
                            ForEach(CrossoverTopology.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }

                    Toggle("Invert Sub Polarity", isOn: Binding(
                        get: { engine.bassManagementConfiguration.subPolarityInverted },
                        set: { value in updateCrossover { $0.subPolarityInverted = value } }
                    )).toggleStyle(.switch)
                }
                .padding(20)
                .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
        .navigationTitle("Active Crossover")
    }

    private func updateCrossover(_ mutation: (inout BassManagementConfiguration) -> Void) {
        var updated = engine.bassManagementConfiguration
        mutation(&updated)
        try? engine.replaceBassManagementConfiguration(updated)
    }
}

private struct ProductionRoomCorrectionView: View {
    @ObservedObject var engine: AudioIOEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(
                    "Room Correction",
                    "Measurement, target-curve, and correction-filter workflows are isolated from daily playback controls."
                )

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
            .padding(28)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
        .navigationTitle("Room Correction")
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
