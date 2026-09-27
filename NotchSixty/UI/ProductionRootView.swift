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
        return 20.0 * log10(Double(linear))
    }

    static func vu(fromLinearRMS linear: Float) -> Double {
        let dbFS = decibelsFS(fromLinear: linear)
        guard dbFS.isFinite else { return minimumVU }
        return min(max(dbFS - referenceDBFS, minimumVU), maximumVU)
    }

    static func normalizedPosition(forVU vu: Double) -> Double {
        let clamped = min(max(vu, minimumVU), maximumVU)
        return (clamped - minimumVU) / (maximumVU - minimumVU)
    }

    static func smoothed(current: Double, target: Double) -> Double {
        let coefficient = target > current ? 0.28 : 0.10
        return current + (target - current) * coefficient
    }
}

struct ProductionRootView: View {
    @ObservedObject var product: ProductController
    @State private var selection: ProductionSection? = .dashboard

    private var engine: AudioIOEngine { product.audioEngine }

    var body: some View {
        NavigationSplitView {
            List(ProductionSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Notch Sixty")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detailView(for: selection ?? .dashboard)
                .toolbar { productionToolbar }
        }
        .frame(minWidth: 980, minHeight: 680)
        .task { product.prepareForUse() }
    }

    @ViewBuilder
    private func detailView(for section: ProductionSection) -> some View {
        switch section {
        case .dashboard:
            ProductionDashboardView(engine: engine, navigate: { selection = $0 })
        case .equalizer:
            ProductionEqualizerView(engine: engine)
        case .dynamics:
            ProductionDynamicsView(engine: engine)
        case .speakerSetup:
            ProductionSpeakerSetupView(engine: engine)
        case .audio:
            ProductionAudioView(engine: engine)
        }
    }

    @ToolbarContentBuilder
    private var productionToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let selectedOutput = engine.selectedOutputDevice {
                Text("\(selectedOutput.name) · \(selectedOutput.nominalSampleRate / 1_000, specifier: "%.1f") kHz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                if engine.lifecycleState == .running {
                    engine.stop()
                } else {
                    try? engine.start()
                }
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
    @State private var leftPeakDBFS = -120.0
    @State private var rightPeakDBFS = -120.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                meterDeck
                masterStrip
                summaryGrid
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .topLeading)
        }
        .navigationTitle("Dashboard")
        .task(id: engine.lifecycleState) {
            await runMeterLoop()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Listening Dashboard")
                    .font(.largeTitle.bold())
                Text(statusLine)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            lifecycleBadge
        }
    }

    private var statusLine: String {
        if let output = engine.selectedOutputDevice {
            return "\(output.name)  ·  \(output.nominalSampleRate / 1_000, specifier: "%.1f") kHz"
        }
        return "Choose an output in Audio to begin."
    }

    private var lifecycleBadge: some View {
        Label(
            engine.lifecycleState == .running ? "Processing" : engine.lifecycleState.rawValue.capitalized,
            systemImage: engine.lifecycleState == .running ? "waveform.circle.fill" : "circle"
        )
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var meterDeck: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OUTPUT")
                    .font(.caption.weight(.semibold))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("0 VU = −18 dBFS")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 18) {
                SignatureVUMeter(channel: "LEFT", vu: leftVU, peakDBFS: leftPeakDBFS)
                SignatureVUMeter(channel: "RIGHT", vu: rightVU, peakDBFS: rightPeakDBFS)
            }
            .frame(minHeight: 285)
        }
    }

    private var masterStrip: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                Button {
                    try? engine.setMasterMuted(!engine.masterVolumeConfiguration.muted)
                } label: {
                    Image(systemName: engine.masterVolumeConfiguration.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .help(engine.masterVolumeConfiguration.muted ? "Unmute" : "Mute")

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Master Volume")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(engine.masterVolumeConfiguration.level * 100, specifier: "%.0f")%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
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

    private var summaryGrid: some View {
        HStack(alignment: .top, spacing: 16) {
            ProductionSummaryCard(
                title: "Equalizer",
                subtitle: eqSummary,
                systemImage: "slider.horizontal.3",
                actionTitle: "Open EQ",
                action: { navigate(.equalizer) }
            )
            ProductionSummaryCard(
                title: "Dynamics",
                subtitle: dynamicsSummary,
                systemImage: "waveform.path.ecg",
                actionTitle: "Open Dynamics",
                action: { navigate(.dynamics) }
            )
            ProductionSummaryCard(
                title: "Speaker Setup",
                subtitle: "Crossover and room correction live in a dedicated system-calibration workspace.",
                systemImage: "hifispeaker.2.fill",
                actionTitle: "Open Setup",
                action: { navigate(.speakerSetup) }
            )
        }
    }

    private var eqSummary: String {
        let config = engine.stereoEQConfiguration
        if config.bypassed { return "Bypassed · \(config.phaseMode.displayName)" }
        return "\(config.enabledBandCount) active bands · \(config.phaseMode.displayName) · \(config.channelMode.displayName)"
    }

    private var dynamicsSummary: String {
        let d = engine.dynamicsConfiguration
        var enabled: [String] = []
        if d.compressor.enabled { enabled.append("Compressor") }
        if d.expander.enabled { enabled.append("Expander") }
        if d.pauseGate.enabled { enabled.append("Pause Gate") }
        if d.spectralDenoiser.enabled { enabled.append("Denoiser") }
        if d.limiter.enabled { enabled.append("Limiter") }
        return enabled.isEmpty ? "No dynamics processors enabled." : enabled.joined(separator: " · ")
    }

    @MainActor
    private func runMeterLoop() async {
        guard engine.lifecycleState == .running else {
            leftVU = ProductionVUScale.minimumVU
            rightVU = ProductionVUScale.minimumVU
            leftPeakDBFS = -120
            rightPeakDBFS = -120
            return
        }

        while !Task.isCancelled && engine.lifecycleState == .running {
            if let meter = engine.diagnosticsSnapshot().renderKernelDiagnostics?.outputMeter {
                let targetLeft = ProductionVUScale.vu(fromLinearRMS: meter.rmsLeft)
                let targetRight = ProductionVUScale.vu(fromLinearRMS: meter.rmsRight)
                leftVU = ProductionVUScale.smoothed(current: leftVU, target: targetLeft)
                rightVU = ProductionVUScale.smoothed(current: rightVU, target: targetRight)
                leftPeakDBFS = ProductionVUScale.decibelsFS(fromLinear: meter.peakLeft)
                rightPeakDBFS = ProductionVUScale.decibelsFS(fromLinear: meter.peakRight)
            }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }
}

private struct SignatureVUMeter: View {
    let channel: String
    let vu: Double
    let peakDBFS: Double

    private let startAngle = -52.0
    private let endAngle = 52.0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = size.width
            let height = size.height
            let center = CGPoint(x: width * 0.5, y: height * 0.82)
            let radius = min(width * 0.43, height * 0.72)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.93, green: 0.88, blue: 0.72),
                                Color(red: 0.82, green: 0.75, blue: 0.57),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.black.opacity(0.28), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)

                Canvas { context, _ in
                    drawScale(context: &context, center: center, radius: radius)
                    drawNeedle(context: &context, center: center, radius: radius)
                    drawPivot(context: &context, center: center)
                }

                VStack(spacing: 2) {
                    Text("NOTCH SIXTY")
                        .font(.caption2.weight(.semibold))
                        .tracking(2.0)
                    Text(channel)
                        .font(.headline.weight(.bold))
                }
                .foregroundStyle(.black.opacity(0.72))
                .position(x: width * 0.5, y: height * 0.58)

                Text(peakText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.black.opacity(0.62))
                    .position(x: width * 0.5, y: height * 0.70)
            }
        }
        .aspectRatio(1.65, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(channel) VU meter")
        .accessibilityValue("\(vu, specifier: "%.1f") VU, peak \(peakText)")
    }

    private var peakText: String {
        peakDBFS.isFinite && peakDBFS > -119
            ? "PEAK \(peakDBFS, specifier: "%.1f") dBFS"
            : "PEAK −∞ dBFS"
    }

    private func drawScale(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let scaleValues: [Double] = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
        let majorLabels: Set<Double> = [-20, -10, -7, -5, -3, 0, 3]

        var arc = Path()
        arc.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180 + startAngle),
            endAngle: .degrees(180 + endAngle),
            clockwise: false
        )
        context.stroke(arc, with: .color(.black.opacity(0.62)), lineWidth: 1.3)

        for value in scaleValues {
            let angle = meterAngle(for: value)
            let inner = point(center: center, radius: radius * (majorLabels.contains(value) ? 0.88 : 0.91), angle: angle)
            let outer = point(center: center, radius: radius, angle: angle)
            var tick = Path()
            tick.move(to: inner)
            tick.addLine(to: outer)
            context.stroke(tick, with: .color(value > 0 ? .red.opacity(0.78) : .black.opacity(0.72)), lineWidth: majorLabels.contains(value) ? 2 : 1)

            if majorLabels.contains(value) {
                let labelPoint = point(center: center, radius: radius * 0.77, angle: angle)
                let label = value > 0 ? "+\(Int(value))" : "\(Int(value))"
                context.draw(
                    Text(label)
                        .font(.system(size: 12, weight: value == 0 ? .bold : .medium, design: .rounded))
                        .foregroundStyle(value > 0 ? Color.red.opacity(0.82) : Color.black.opacity(0.72)),
                    at: labelPoint
                )
            }
        }

        let vuPoint = CGPoint(x: center.x, y: center.y - radius * 0.43)
        context.draw(
            Text("VU")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.72)),
            at: vuPoint
        )
    }

    private func drawNeedle(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let angle = meterAngle(for: vu)
        let tip = point(center: center, radius: radius * 0.92, angle: angle)
        let tail = point(center: center, radius: radius * -0.12, angle: angle)
        var needle = Path()
        needle.move(to: tail)
        needle.addLine(to: tip)
        context.stroke(needle, with: .color(.red.opacity(0.92)), lineWidth: 2.2)
    }

    private func drawPivot(context: inout GraphicsContext, center: CGPoint) {
        let rect = CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
        context.fill(Path(ellipseIn: rect), with: .color(.black.opacity(0.78)))
        let highlight = CGRect(x: center.x - 4, y: center.y - 5, width: 8, height: 8)
        context.fill(Path(ellipseIn: highlight), with: .color(.white.opacity(0.35)))
    }

    private func meterAngle(for value: Double) -> Double {
        let normalized = ProductionVUScale.normalizedPosition(forVU: value)
        return 180.0 + startAngle + normalized * (endAngle - startAngle)
    }

    private func point(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }
}

private struct ProductionSummaryCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            Button(actionTitle, action: action)
                .buttonStyle(.glass)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))
    }
}

private struct ProductionEqualizerView: View {
    @ObservedObject var engine: AudioIOEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProductionPageHeader(
                    title: "Equalizer",
                    subtitle: "Static and dynamic EQ, channel domains, and phase strategy."
                )

                HStack(spacing: 14) {
                    ProductionStat(title: "Mode", value: engine.stereoEQConfiguration.channelMode.displayName)
                    ProductionStat(title: "Phase", value: engine.stereoEQConfiguration.phaseMode.displayName)
                    ProductionStat(title: "Active Bands", value: "\(engine.stereoEQConfiguration.enabledBandCount)")
                }

                ContentUnavailableView(
                    "Production EQ Editor",
                    systemImage: "slider.horizontal.3",
                    description: Text("PR36 establishes the shipping navigation and summary surface. The focused graphical/band editor follows on this production foundation.")
                )
                .frame(maxWidth: .infinity, minHeight: 360)
            }
            .padding(28)
        }
        .navigationTitle("Equalizer")
    }
}

private struct ProductionDynamicsView: View {
    @ObservedObject var engine: AudioIOEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProductionPageHeader(
                    title: "Dynamics",
                    subtitle: "Level control, protection, noise tools, and program-aware processing."
                )

                HStack(spacing: 14) {
                    ProductionStat(title: "Compressor", value: engine.dynamicsConfiguration.compressor.enabled ? "On" : "Off")
                    ProductionStat(title: "Denoiser", value: engine.dynamicsConfiguration.spectralDenoiser.enabled ? "On" : "Off")
                    ProductionStat(title: "Limiter", value: engine.dynamicsConfiguration.limiter.enabled ? "On" : "Off")
                }

                ContentUnavailableView(
                    "Production Dynamics Editor",
                    systemImage: "waveform.path.ecg",
                    description: Text("Dense dynamics controls will move from engineering validation into a dedicated production editor in the next focused UI increment.")
                )
                .frame(maxWidth: .infinity, minHeight: 360)
            }
            .padding(28)
        }
        .navigationTitle("Dynamics")
    }
}

private enum SpeakerSetupSection: String, CaseIterable, Identifiable {
    case crossover
    case roomCorrection

    var id: String { rawValue }
    var title: String {
        switch self {
        case .crossover: return "Active Crossover"
        case .roomCorrection: return "Room Correction"
        }
    }
}

private struct ProductionSpeakerSetupView: View {
    @ObservedObject var engine: AudioIOEngine
    @State private var section: SpeakerSetupSection = .crossover

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProductionPageHeader(
                    title: "Speaker Setup",
                    subtitle: "System calibration is intentionally separated from day-to-day listening controls."
                )

                Picker("Speaker Setup", selection: $section) {
                    ForEach(SpeakerSetupSection.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                switch section {
                case .crossover:
                    crossoverPanel
                case .roomCorrection:
                    roomCorrectionPanel
                }
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
                set: { updateCrossover { $0.enabled = $1 }($0) }
            ))
            .toggleStyle(.switch)

            LabeledContent("Crossover Frequency") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { engine.bassManagementConfiguration.frequencyHz },
                            set: { value in updateCrossover { $0.frequencyHz = value } }
                        ),
                        in: BassManagementConfiguration.frequencyRange,
                        step: 1
                    )
                    .frame(width: 300)
                    Text("\(engine.bassManagementConfiguration.frequencyHz, specifier: "%.0f") Hz")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }

            LabeledContent("Topology") {
                Picker("Topology", selection: Binding(
                    get: { engine.bassManagementConfiguration.topology },
                    set: { value in updateCrossover { $0.topology = value } }
                )) {
                    ForEach(CrossoverTopology.allCases) { topology in
                        Text(topology.displayName).tag(topology)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            LabeledContent("Sub Gain") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { engine.bassManagementConfiguration.subGainDB },
                            set: { value in updateCrossover { $0.subGainDB = value } }
                        ),
                        in: BassManagementConfiguration.subGainRange,
                        step: 0.5
                    )
                    .frame(width: 300)
                    Text("\(engine.bassManagementConfiguration.subGainDB, specifier: "%+.1f") dB")
                        .monospacedDigit()
                        .frame(width: 78, alignment: .trailing)
                }
            }

            Toggle("Invert Sub Polarity", isOn: Binding(
                get: { engine.bassManagementConfiguration.subPolarityInverted },
                set: { value in updateCrossover { $0.subPolarityInverted = value } }
            ))
            .toggleStyle(.switch)
        }
        .padding(20)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))
    }

    private var roomCorrectionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Correction Filter").font(.headline)
                    Text(engine.roomCorrectionConfiguration.filter?.name ?? "No correction filter loaded")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { engine.roomCorrectionConfiguration.enabled },
                    set: { value in try? engine.setRoomCorrectionEnabled(value) }
                ))
                .toggleStyle(.switch)
                .disabled(engine.roomCorrectionConfiguration.filter == nil)
            }

            Divider()

            ContentUnavailableView(
                "Measurement & Filter Import",
                systemImage: "waveform.badge.magnifyingglass",
                description: Text("The production measurement, multi-seat averaging, target-curve, and correction-filter import workflow will live here rather than on the main Dashboard.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        }
        .padding(20)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 18))
    }

    private func updateCrossover(_ mutate: (inout BassManagementConfiguration) -> Void) {
        var updated = engine.bassManagementConfiguration
        mutate(&updated)
        try? engine.replaceBassManagementConfiguration(updated)
    }
}

private struct ProductionAudioView: View {
    @ObservedObject var engine: AudioIOEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProductionPageHeader(
                    title: "Audio",
                    subtitle: "Physical output routing and processing transport."
                )

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
                        .labelsHidden()
                        .frame(width: 340)
                        .disabled(engine.lifecycleState != .idle)
                    }

                    if let output = engine.selectedOutputDevice {
                        LabeledContent("Nominal Sample Rate", value: "\(output.nominalSampleRate / 1_000, specifier: "%.1f") kHz")
                    }
                    LabeledContent("Processing State", value: engine.lifecycleState.rawValue.capitalized)

                    if let error = engine.lastErrorDescription {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button("Refresh Devices") { try? engine.refreshOutputDevices() }
                            .buttonStyle(.glass)
                        Button(engine.lifecycleState == .running ? "Stop Processing" : "Start Processing") {
                            if engine.lifecycleState == .running { engine.stop() } else { try? engine.start() }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(engine.lifecycleState != .idle && engine.lifecycleState != .running)
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

private struct ProductionPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

private struct ProductionStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 16))
    }
}
