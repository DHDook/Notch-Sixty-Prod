import Foundation
import SwiftUI

struct ProductionGlassPickerChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Picker owns pointer/press interaction. Keep the surrounding Liquid Glass
            // visual-only so hover/click state cannot perturb layout. A constant inset
            // keeps text and segmented labels clear of the capsule edge in every state.
            .padding(.horizontal, 6)
            .glassEffect(.regular, in: .capsule)
    }
}

extension View {
    func productionGlassPickerChrome() -> some View {
        modifier(ProductionGlassPickerChromeModifier())
    }
}

enum ProductionSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case equalizer
    case dynamics
    case meters
    case activeCrossover
    case headphones
    case speakerCalibration
    case roomCorrection

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .equalizer: return "Equalizer"
        case .dynamics: return "Dynamics"
        case .meters: return "Meters"
        case .activeCrossover: return "Active Crossover"
        case .headphones: return "Headphones"
        case .speakerCalibration: return "Speaker Calibration"
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
        case .headphones: return "headphones"
        case .speakerCalibration: return "speaker.wave.3.fill"
        case .roomCorrection: return "waveform.badge.magnifyingglass"
        }
    }
}

enum ProductionVUScale {
    static let referenceDBFS = -18.0
    static let minimumVU = -40.0
    static let maximumVU = 3.0

    // Compress the quiet end and devote progressively more angular
    // resolution to the working range around 0 VU, like an analog face.
    static let scaleAnchors: [(vu: Double, position: Double)] = [
        (-40, 0.000),
        (-30, 0.090),
        (-20, 0.215),
        (-10, 0.400),
        (-7, 0.475),
        (-5, 0.545),
        (-3, 0.625),
        (-2, 0.675),
        (-1, 0.730),
        (0, 0.790),
        (1, 0.855),
        (2, 0.925),
        (3, 1.000),
    ]

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
        for index in 0..<(scaleAnchors.count - 1) {
            let lower = scaleAnchors[index]
            let upper = scaleAnchors[index + 1]
            guard value <= upper.vu else { continue }
            let span = upper.vu - lower.vu
            let fraction = span > 0 ? (value - lower.vu) / span : 0
            return lower.position + fraction * (upper.position - lower.position)
        }
        return 1
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
    #if DEBUG
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var selection: ProductionSection? = .dashboard

    private var engine: AudioIOEngine { product.audioEngine }

    private var minimumWindowWidth: CGFloat {
        if selection == .equalizer, engine.stereoEQConfiguration.channelMode != .linked {
            return 1_320
        }
        return 980
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                ProductionSidebarBrand()
                Divider()
                List(ProductionSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 290)
        } detail: {
            detail(for: selection ?? .dashboard)
                .toolbar { toolbar }
        }
        .frame(minWidth: minimumWindowWidth, minHeight: 680)
        .task { product.prepareForUse() }
    }

    @ViewBuilder
    private func detail(for section: ProductionSection) -> some View {
        switch section {
        case .dashboard:
            ProductionDashboardView(engine: engine)
        case .equalizer:
            ProductionEqualizerView(engine: engine)
        case .dynamics:
            ProductionDynamicsView(engine: engine)
        case .meters:
            ProductionMetersView(engine: engine)
        case .activeCrossover:
            ProductionActiveCrossoverView(engine: engine, profiles: product.profiles)
        case .headphones:
            ProductionHeadphoneWorkspace(engine: engine, profiles: product.profiles)
        case .speakerCalibration:
            ProductionMultichannelCalibrationWorkspace(
                engine: engine,
                calibration: product.multichannelCalibration,
                microphone: product.calibration,
                profiles: product.profiles
            )
        case .roomCorrection:
            ProductionRoomCorrectionWorkspace(
            engine: engine,
            calibration: product.calibration,
            projects: product.roomCorrectionProjects,
            profiles: product.profiles
        )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ProductionProfileToolbar(profiles: product.profiles, engine: engine)

            if let output = engine.selectedOutputDevice {
                HStack(spacing: 5) {
                    Image(systemName: "hifispeaker")
                    Text("\(output.name) · \(output.nominalSampleRate / 1_000, specifier: "%.1f") kHz")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Output \(output.name), \(output.nominalSampleRate / 1_000, specifier: "%.1f") kilohertz")
            }
            #if DEBUG
            Button {
                openWindow(id: "engineering-validation")
            } label: {
                Label("Engineering Validation", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.glass)
            .help("Open the retained engineering validation tools")
            #endif

            Button {
                Task { @MainActor in
                    await Task.yield()
                    if engine.lifecycleState == .running { engine.stop() }
                    else if engine.lifecycleState == .idle { try? engine.start() }
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

        ToolbarSpacer(.flexible)

        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.glass)
            .help("Open Notch Sixty Settings")
        }
    }
}


private struct ProductionSidebarBrand: View {
    var body: some View {
        HStack {
            Text("Notch Sixty")
                .textCase(.uppercase)
                .font(.headline.weight(.semibold))
                .tracking(1.5)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notch Sixty")
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
    }

    private var outputSummary: String {
        guard let output = engine.selectedOutputDevice else { return "Choose an output below to begin." }
        return "\(output.name) · \(String(format: "%.1f", output.nominalSampleRate / 1_000)) kHz"
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
        return "\(Int(c.frequencyHz.rounded())) Hz · \(c.topology.displayName)"
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
                .productionGlassPickerChrome()
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
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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

                Text("NOTCH SIXTY")
                    .font(.headline.bold())
                    .tracking(3.2)
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
        let ticks: [Double] = [-40, -35, -30, -25, -20, -15, -10, -7, -5, -4, -3, -2, -1, 0, 1, 2, 3]
        let labels: Set<Double> = [-40, -30, -20, -10, -7, -5, -3, 0, 3]
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
    @ObservedObject var profiles: ProductProfileController
    @State private var actionError: String?

    private var routing: MultiOutputRoutingConfiguration {
        profiles.selectedSystemOutputRouting
    }

    private var physicalRoutingLocked: Bool {
        engine.lifecycleState != .idle
    }

    private var routedDeviceUIDs: [String] {
        var result: [String] = []
        for route in routing.enabledRoutes {
            let uid = route.destination.deviceUID
            if !result.contains(uid) { result.append(uid) }
        }
        return result
    }

    private var supportedRouteBuses: [SpeakerOutputBus] {
        let fullRange: [SpeakerOutputBus] = [.leftFullRange, .rightFullRange]
        guard let mode = engine.bassManagementConfiguration.physicalOutputMode else {
            return fullRange
        }
        return fullRange + SpeakerOutputBus.allCases.filter { !fullRange.contains($0) && mode.supports(bus: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(
                    "Active Crossover",
                    "Stereo program processing with persistent speaker-bus routing across one or more physical Core Audio devices."
                )

                playbackSystemCard
                crossoverCard
                if engine.bassManagementConfiguration.physicalOutputMode == .mainsSub {
                    subAlignmentCard
                }
                physicalRoutingCard
                driverProcessingCard
                verificationCard

                if let error = actionError ?? profiles.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .topLeading)
        }
    }

    private var playbackSystemCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playback System").font(.caption).foregroundStyle(.secondary)
                    Text(profiles.selectedSystemProfileName).font(.headline)
                }
                Spacer()
                if routing.enabled {
                    Label(
                        "\(routing.enabledRoutes.count) routes · \(routing.requiredDeviceUIDs.count) devices",
                        systemImage: routing.usesMultiplePhysicalDevices ? "square.stack.3d.up" : "rectangle.stack"
                    )
                    .font(.caption.bold())
                }
            }
            Text("Crossover and physical-output routing are stored with this Playback System. Content Preset EQ, dynamics, preamp, and headroom remain independent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var crossoverCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Crossover Design").font(.headline)
                    Text("Choose logical stereo bass management or a true physical Mains + Sub / Bi-Amp / Tri-Amp speaker topology.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { engine.bassManagementConfiguration.enabled },
                    set: { value in updateCrossover { $0.enabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            LabeledContent("Physical Speaker Mode") {
                Picker("Physical Speaker Mode", selection: Binding(
                    get: { engine.bassManagementConfiguration.physicalOutputMode },
                    set: { value in updateCrossover { configuration in
                        configuration.physicalOutputMode = value
                        if value == .triAmp {
                            if configuration.frequencyHz >= 20_000 { configuration.frequencyHz = 2_000 }
                            if configuration.upperFrequencyHz == nil
                                || configuration.upperFrequencyHz! <= configuration.frequencyHz {
                                configuration.upperFrequencyHz = min(20_000, max(configuration.frequencyHz + 1, 3_000))
                            }
                            if configuration.upperTopology == nil {
                                configuration.upperTopology = configuration.topology
                            }
                        }
                    } }
                )) {
                    Text("Stereo / logical only").tag(SpeakerCrossoverMode?.none)
                    ForEach(SpeakerCrossoverMode.allCases) { mode in
                        Text(mode.displayName).tag(Optional(mode))
                    }
                }
                .productionGlassPickerChrome()
                .labelsHidden()
                .frame(width: 260)
            }
            .disabled(physicalRoutingLocked && routing.enabled)

            LabeledContent(engine.bassManagementConfiguration.physicalOutputMode == .triAmp ? "Lower Crossover" : "Crossover Frequency") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.frequencyHz },
                        set: { value in updateCrossover { $0.frequencyHz = value } }
                    ), in: lowerFrequencyRange, step: 1)
                    .frame(width: 330)
                    Text("\(engine.bassManagementConfiguration.frequencyHz, specifier: "%.0f") Hz")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }
            .disabled(physicalRoutingLocked && routing.enabled)

            LabeledContent(engine.bassManagementConfiguration.physicalOutputMode == .triAmp ? "Lower Topology" : "Topology") {
                Picker("Topology", selection: Binding(
                    get: { engine.bassManagementConfiguration.topology },
                    set: { value in updateCrossover { $0.topology = value } }
                )) {
                    ForEach(CrossoverTopology.allCases) { topology in
                        Text(topology.displayName).tag(topology)
                    }
                }
                .productionGlassPickerChrome()
                .labelsHidden()
                .frame(width: 280)
            }
            .disabled(physicalRoutingLocked && routing.enabled)

            if engine.bassManagementConfiguration.physicalOutputMode == .triAmp {
                LabeledContent("Upper Crossover") {
                    HStack {
                        Slider(value: Binding(
                            get: {
                                engine.bassManagementConfiguration.upperFrequencyHz
                                    ?? max(engine.bassManagementConfiguration.frequencyHz + 1, 3_000)
                            },
                            set: { value in updateCrossover { $0.upperFrequencyHz = value } }
                        ), in: upperFrequencyRange, step: 1)
                        .frame(width: 330)
                        Text("\((engine.bassManagementConfiguration.upperFrequencyHz ?? 3_000), specifier: "%.0f") Hz")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }
                .disabled(physicalRoutingLocked && routing.enabled)

                LabeledContent("Upper Topology") {
                    Picker("Upper Topology", selection: Binding(
                        get: { engine.bassManagementConfiguration.upperTopology ?? engine.bassManagementConfiguration.topology },
                        set: { value in updateCrossover { $0.upperTopology = value } }
                    )) {
                        ForEach(CrossoverTopology.allCases) { topology in
                            Text(topology.displayName).tag(topology)
                        }
                    }
                    .productionGlassPickerChrome()
                    .labelsHidden()
                    .frame(width: 280)
                }
                .disabled(physicalRoutingLocked && routing.enabled)
            }

            if engine.bassManagementConfiguration.physicalOutputMode == .mainsSub
                || engine.bassManagementConfiguration.physicalOutputMode == nil {
                LabeledContent("Sub Gain") {
                    HStack(spacing: 12) {
                        Slider(value: Binding(
                            get: { engine.bassManagementConfiguration.subGainDB },
                            set: { value in updateCrossover { $0.subGainDB = value } }
                        ), in: BassManagementConfiguration.subGainRange, step: 0.5)
                        .frame(width: 260)
                        Text("\(engine.bassManagementConfiguration.subGainDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 68, alignment: .trailing)
                    }
                }

                Toggle("Invert Sub Polarity", isOn: Binding(
                    get: { engine.bassManagementConfiguration.subPolarityInverted },
                    set: { value in updateCrossover { $0.subPolarityInverted = value } }
                ))
                .toggleStyle(.switch)
            }

            if physicalRoutingLocked && routing.enabled {
                Label("Stop processing before changing physical crossover topology or route assignments.", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var subAlignmentCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sub Phase Alignment").font(.headline)
                    Text("All-pass alignment on the physical Sub Mono bus. Use measurement evidence when available rather than tuning blindly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { engine.bassManagementConfiguration.subPhaseAlignmentEnabled },
                    set: { value in updateCrossover { $0.subPhaseAlignmentEnabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            LabeledContent("Alignment Frequency") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.subPhaseAlignmentFrequencyHz },
                        set: { value in updateCrossover { $0.subPhaseAlignmentFrequencyHz = value } }
                    ), in: BassManagementConfiguration.frequencyRange, step: 1)
                    .frame(width: 260)
                    Text("\(engine.bassManagementConfiguration.subPhaseAlignmentFrequencyHz, specifier: "%.0f") Hz")
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
            }
            .disabled(!engine.bassManagementConfiguration.subPhaseAlignmentEnabled)

            LabeledContent("Alignment Q") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.subPhaseAlignmentQ },
                        set: { value in updateCrossover { $0.subPhaseAlignmentQ = value } }
                    ), in: BassManagementConfiguration.subPhaseAlignmentQRange, step: 0.05)
                    .frame(width: 260)
                    Text("\(engine.bassManagementConfiguration.subPhaseAlignmentQ, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
            }
            .disabled(!engine.bassManagementConfiguration.subPhaseAlignmentEnabled)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var physicalRoutingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Physical Output Matrix").font(.headline)
                    Text("Map up to eight logical speaker buses to Core Audio device channels. Multiple devices are synchronized with a private Aggregate Device and HAL drift compensation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { routing.enabled },
                    set: { value in updateRouting { $0.enabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(physicalRoutingLocked)
            }

            LabeledContent("Synchronization") {
                Picker("Synchronization", selection: Binding(
                    get: { routing.synchronizationMode },
                    set: { value in updateRouting { $0.synchronizationMode = value } }
                )) {
                    Text(MultiOutputSynchronizationMode.automatic.displayName).tag(MultiOutputSynchronizationMode.automatic)
                    Text(MultiOutputSynchronizationMode.aggregateDevice.displayName).tag(MultiOutputSynchronizationMode.aggregateDevice)
                    Text("Software PLL (superseded)")
                        .tag(MultiOutputSynchronizationMode.softwarePLL)
                        .disabled(true)
                }
                .productionGlassPickerChrome()
                .labelsHidden()
                .frame(width: 240)
            }
            .disabled(physicalRoutingLocked)

            if routedDeviceUIDs.count > 1 {
                LabeledContent("Reference Device") {
                    Picker("Reference Device", selection: Binding(
                        get: { routing.referenceDeviceUID },
                        set: { value in updateRouting { $0.referenceDeviceUID = value } }
                    )) {
                        Text("Automatic").tag(String?.none)
                        ForEach(routedDeviceUIDs, id: \.self) { uid in
                            Text(deviceName(uid)).tag(Optional(uid))
                        }
                    }
                    .productionGlassPickerChrome()
                    .labelsHidden()
                    .frame(width: 300)
                }
                .disabled(physicalRoutingLocked)
            }

            Divider()

            if routing.routes.isEmpty {
                ContentUnavailableView(
                    "No Physical Routes",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Add routes to assign speaker buses to physical device channels. Routing stays inactive until at least two routes are enabled.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(spacing: 10) {
                    ForEach(routing.routes) { route in
                        routeRow(route)
                    }
                }
            }

            HStack {
                Button {
                    addRoute()
                } label: {
                    Label("Add Route", systemImage: "plus")
                }
                .buttonStyle(.glass)
                .disabled(physicalRoutingLocked || routing.routes.count >= MultiOutputRoutingConfiguration.maximumRouteCount || engine.outputDevices.isEmpty)

                Spacer()
                Text("\(routing.routes.count)/\(MultiOutputRoutingConfiguration.maximumRouteCount) routes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if routing.synchronizationMode == .softwarePLL {
                Label("Software PLL is retained only for archive compatibility. Select Automatic or Aggregate Device before activation.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private func routeRow(_ route: SpeakerOutputRoute) -> some View {
        HStack(spacing: 10) {
            Toggle("Route enabled", isOn: Binding(
                get: { route.enabled },
                set: { value in updateRoute(route.id) { $0.enabled = value } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Picker("Bus", selection: Binding(
                get: { route.bus },
                set: { value in updateRoute(route.id) { $0.bus = value; $0.name = value.displayName } }
            )) {
                ForEach(supportedRouteBuses) { bus in
                    Text(bus.displayName).tag(bus)
                }
            }
            .productionGlassPickerChrome()
            .labelsHidden()
            .frame(width: 180)

            Picker("Device", selection: Binding(
                get: { route.destination.deviceUID },
                set: { uid in
                    updateRoute(route.id) { updated in
                        updated.destination.deviceUID = uid
                        updated.destination.channelIndex = firstAvailableChannel(on: uid, excluding: route.id)
                    }
                }
            )) {
                ForEach(engine.outputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .productionGlassPickerChrome()
            .labelsHidden()
            .frame(minWidth: 230)

            Picker("Channel", selection: Binding(
                get: { route.destination.channelIndex },
                set: { value in updateRoute(route.id) { $0.destination.channelIndex = value } }
            )) {
                ForEach(0..<Int(max(1, channelCount(for: route.destination.deviceUID))), id: \.self) { channel in
                    Text("Ch \(channel + 1)").tag(UInt32(channel))
                }
            }
            .productionGlassPickerChrome()
            .labelsHidden()
            .frame(width: 80)

            Button(role: .destructive) {
                removeRoute(route.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .disabled(physicalRoutingLocked)
        .padding(10)
        .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 12))
    }

    private var driverProcessingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Per-Driver Processing").font(.headline)
                    Text("Playback-System-owned EQ, trim, polarity, fractional delay, and protection. Mandatory crossover filtering always runs first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if physicalRoutingLocked {
                    Label("Stop processing to edit", systemImage: "stop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            let buses = routedDriverBuses
            if buses.isEmpty {
                Text("Enable and map physical speaker routes to expose per-driver controls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(buses, id: \.self) { bus in
                    driverBusEditor(bus)
                }
            }

            Text("These controls are downstream of the mandatory Mains+Sub / Bi-Amp / Tri-Amp splitter. Global Bypass, audition modes, and driver-processing bypass cannot restore full-range signal to a protected split-driver bus.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var routedDriverBuses: [SpeakerOutputBus] {
        let routed = Set(routing.routes.filter(\.enabled).map(\.bus))
        return SpeakerOutputBus.allCases.filter { routed.contains($0) }
    }

    @ViewBuilder
    private func driverBusEditor(_ bus: SpeakerOutputBus) -> some View {
        let configuration = engine.speakerDriverProcessingConfiguration.configuration(for: bus)
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    Toggle("Processing", isOn: Binding(
                        get: { driverConfiguration(for: bus).enabled },
                        set: { value in updateDriverBus(bus) { $0.enabled = value } }
                    ))
                    .toggleStyle(.switch)

                    Toggle("Invert Polarity", isOn: Binding(
                        get: { driverConfiguration(for: bus).polarityInverted },
                        set: { value in updateDriverBus(bus) { $0.polarityInverted = value } }
                    ))
                    .toggleStyle(.switch)

                    Toggle("Limiter", isOn: Binding(
                        get: { driverConfiguration(for: bus).limiterEnabled },
                        set: { value in updateDriverBus(bus) { $0.limiterEnabled = value } }
                    ))
                    .toggleStyle(.switch)
                }

                LabeledContent("Trim") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { driverConfiguration(for: bus).trimDB },
                                set: { value in updateDriverBus(bus) { $0.trimDB = value } }
                            ),
                            in: SpeakerDriverBusProcessingConfiguration.trimRange,
                            step: 0.1
                        )
                        Text("\(configuration.trimDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 66, alignment: .trailing)
                    }
                }

                LabeledContent("Delay") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { driverConfiguration(for: bus).delayMilliseconds },
                                set: { value in updateDriverBus(bus) { $0.delayMilliseconds = value } }
                            ),
                            in: SpeakerDriverBusProcessingConfiguration.delayRangeMilliseconds,
                            step: 0.01
                        )
                        Text("\(configuration.delayMilliseconds, specifier: "%.2f") ms")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }

                if configuration.limiterEnabled {
                    LabeledContent("Limiter Threshold") {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(
                                    get: { driverConfiguration(for: bus).limiterThresholdDBFS },
                                    set: { value in updateDriverBus(bus) { $0.limiterThresholdDBFS = value } }
                                ),
                                in: SpeakerDriverBusProcessingConfiguration.limiterThresholdRange,
                                step: 0.5
                            )
                            Text("\(configuration.limiterThresholdDBFS, specifier: "%.1f") dBFS")
                                .monospacedDigit()
                                .frame(width: 78, alignment: .trailing)
                        }
                    }
                }

                Divider()
                HStack {
                    Text("Driver EQ").font(.subheadline.weight(.semibold))
                    Text("\(configuration.eqBands.count)/\(SpeakerDriverBusProcessingConfiguration.maximumEQBandCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addDriverEQBand(to: bus)
                    } label: {
                        Label("Add Band", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .disabled(configuration.eqBands.count >= SpeakerDriverBusProcessingConfiguration.maximumEQBandCount)
                }

                ForEach(Array(configuration.eqBands.enumerated()), id: \.element.id) { index, band in
                    driverEQBandEditor(bus: bus, index: index, band: band)
                }
            }
            .padding(.top, 10)
            .disabled(physicalRoutingLocked)
        } label: {
            HStack {
                Label(bus.displayName, systemImage: "hifispeaker.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                let active = configuration.enabled && !configuration.isNeutral
                Text(active ? "Configured" : "Neutral")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private func driverEQBandEditor(bus: SpeakerOutputBus, index: Int, band: EQBand) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Band \(index + 1)", isOn: Binding(
                    get: { driverBand(bus: bus, index: index)?.enabled ?? false },
                    set: { value in updateDriverBand(bus: bus, index: index) { $0.enabled = value } }
                ))
                .toggleStyle(.switch)

                Picker("Type", selection: Binding(
                    get: { driverBand(bus: bus, index: index)?.type ?? .peaking },
                    set: { value in updateDriverBand(bus: bus, index: index) { band in
                        band.type = value
                        band.slope = .db12
                        band.constantQ = false
                        band.firKernel = nil
                    } }
                )) {
                    Text(EQFilterType.peaking.displayName).tag(EQFilterType.peaking)
                    Text(EQFilterType.lowShelf.displayName).tag(EQFilterType.lowShelf)
                    Text(EQFilterType.highShelf.displayName).tag(EQFilterType.highShelf)
                    Text(EQFilterType.notch.displayName).tag(EQFilterType.notch)
                    Text(EQFilterType.allPass.displayName).tag(EQFilterType.allPass)
                }
                .productionGlassPickerChrome()
                .labelsHidden()
                .frame(width: 150)

                Spacer()
                Button(role: .destructive) {
                    removeDriverEQBand(from: bus, index: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove driver EQ band")
            }

            LabeledContent("Frequency") {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { driverBand(bus: bus, index: index)?.frequencyHz ?? 1_000 },
                            set: { value in updateDriverBand(bus: bus, index: index) { $0.frequencyHz = value } }
                        ),
                        in: 20 ... 20_000
                    )
                    Text("\(band.frequencyHz, specifier: "%.0f") Hz")
                        .monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                }
            }

            if band.type != .notch && band.type != .allPass {
                LabeledContent("Gain") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { driverBand(bus: bus, index: index)?.gainDB ?? 0 },
                                set: { value in updateDriverBand(bus: bus, index: index) { $0.gainDB = value } }
                            ),
                            in: -12 ... 12,
                            step: 0.1
                        )
                        Text("\(band.gainDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 66, alignment: .trailing)
                    }
                }
            }

            LabeledContent("Q") {
                HStack(spacing: 10) {
                    Slider(
                        value: Binding(
                            get: { driverBand(bus: bus, index: index)?.q ?? 0.707 },
                            set: { value in updateDriverBand(bus: bus, index: index) { $0.q = value } }
                        ),
                        in: 0.35 ... 10,
                        step: 0.01
                    )
                    Text("\(band.q, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 12))
    }

    private func driverConfiguration(for bus: SpeakerOutputBus) -> SpeakerDriverBusProcessingConfiguration {
        engine.speakerDriverProcessingConfiguration.configuration(for: bus)
    }

    private func driverBand(bus: SpeakerOutputBus, index: Int) -> EQBand? {
        let bands = driverConfiguration(for: bus).eqBands
        guard bands.indices.contains(index) else { return nil }
        return bands[index]
    }

    private func updateDriverBus(
        _ bus: SpeakerOutputBus,
        mutate: (inout SpeakerDriverBusProcessingConfiguration) -> Void
    ) {
        guard !physicalRoutingLocked else { return }
        var all = engine.speakerDriverProcessingConfiguration
        var busConfiguration = all.configuration(for: bus)
        mutate(&busConfiguration)
        all.replace(busConfiguration)
        do {
            try profiles.replaceSelectedSystemSpeakerDriverProcessing(all)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func addDriverEQBand(to bus: SpeakerOutputBus) {
        updateDriverBus(bus) { configuration in
            guard configuration.eqBands.count < SpeakerDriverBusProcessingConfiguration.maximumEQBandCount else { return }
            let initialFrequency: Double
            switch bus {
            case .subMono: initialFrequency = 60
            case .leftLow, .rightLow: initialFrequency = 120
            case .leftMid, .rightMid: initialFrequency = 1_000
            case .leftHigh, .rightHigh: initialFrequency = 5_000
            case .leftFullRange, .rightFullRange: initialFrequency = 1_000
            }
            configuration.eqBands.append(
                EQBand(type: .peaking, frequencyHz: initialFrequency, gainDB: 0, q: 0.707)
            )
        }
    }

    private func removeDriverEQBand(from bus: SpeakerOutputBus, index: Int) {
        updateDriverBus(bus) { configuration in
            guard configuration.eqBands.indices.contains(index) else { return }
            configuration.eqBands.remove(at: index)
        }
    }

    private func updateDriverBand(
        bus: SpeakerOutputBus,
        index: Int,
        mutate: (inout EQBand) -> Void
    ) {
        updateDriverBus(bus) { configuration in
            guard configuration.eqBands.indices.contains(index) else { return }
            mutate(&configuration.eqBands[index])
        }
    }

    private var verificationCard: some View {
        DisclosureGroup("Verification Monitor") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Monitor Path", selection: Binding(
                    get: { engine.bassManagementConfiguration.monitorMode },
                    set: { value in updateCrossover { $0.monitorMode = value } }
                )) {
                    ForEach(CrossoverMonitorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .productionGlassPickerChrome()
                .pickerStyle(.segmented)

                Text("The verification monitor affects the ordinary logical stereo crossover preview. Physical split routes are generated independently after the shared stereo DSP chain and are protected by their mandatory crossover even when raw Global Bypass is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var lowerFrequencyRange: ClosedRange<Double> {
        if engine.bassManagementConfiguration.physicalOutputMode == .triAmp {
            return 20...19_999
        }
        return engine.bassManagementConfiguration.lowerFrequencyRange
    }

    private var upperFrequencyRange: ClosedRange<Double> {
        let lower = min(19_999, max(20, engine.bassManagementConfiguration.frequencyHz + 1))
        return lower...20_000
    }

    private func deviceName(_ uid: String) -> String {
        engine.outputDevices.first(where: { $0.uid == uid })?.name ?? uid
    }

    private func channelCount(for uid: String) -> UInt32 {
        engine.outputDevices.first(where: { $0.uid == uid })?.outputChannelCount ?? 1
    }

    private func firstAvailableChannel(on uid: String, excluding routeID: UUID?) -> UInt32 {
        let used = Set(routing.routes.compactMap { route -> UInt32? in
            guard route.id != routeID, route.destination.deviceUID == uid else { return nil }
            return route.destination.channelIndex
        })
        let count = channelCount(for: uid)
        for channel in 0..<count where !used.contains(channel) {
            return channel
        }
        return 0
    }

    private func addRoute() {
        actionError = nil
        guard routing.routes.count < MultiOutputRoutingConfiguration.maximumRouteCount else { return }
        let used = Set(routing.routes.map(\.destination))
        var endpoint: PhysicalOutputEndpoint?
        outer: for device in engine.outputDevices {
            for channel in 0..<device.outputChannelCount {
                let candidate = PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: channel)
                if !used.contains(candidate) {
                    endpoint = candidate
                    break outer
                }
            }
        }
        guard let endpoint else {
            actionError = "No unused physical output channel is currently available."
            return
        }
        let usedBuses = Set(routing.routes.map(\.bus))
        let bus = supportedRouteBuses.first(where: { !usedBuses.contains($0) }) ?? supportedRouteBuses.first ?? .leftFullRange
        updateRouting { configuration in
            configuration.routes.append(
                SpeakerOutputRoute(name: bus.displayName, bus: bus, destination: endpoint)
            )
        }
    }

    private func removeRoute(_ id: UUID) {
        updateRouting { configuration in
            configuration.routes.removeAll { $0.id == id }
            if let reference = configuration.referenceDeviceUID,
               !configuration.enabledRoutes.contains(where: { $0.destination.deviceUID == reference }) {
                configuration.referenceDeviceUID = nil
            }
        }
    }

    private func updateRoute(_ id: UUID, _ mutation: (inout SpeakerOutputRoute) -> Void) {
        updateRouting { configuration in
            guard let index = configuration.routes.firstIndex(where: { $0.id == id }) else { return }
            mutation(&configuration.routes[index])
        }
    }

    private func updateRouting(_ mutation: (inout MultiOutputRoutingConfiguration) -> Void) {
        actionError = nil
        var updated = routing
        mutation(&updated)
        do {
            try profiles.replaceSelectedSystemOutputRouting(updated)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func updateCrossover(_ mutation: (inout BassManagementConfiguration) -> Void) {
        actionError = nil
        var updated = engine.bassManagementConfiguration
        mutation(&updated)
        do {
            try profiles.replaceSelectedSystemBassManagement(updated)
        } catch {
            actionError = error.localizedDescription
        }
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
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .topLeading)
        }
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
