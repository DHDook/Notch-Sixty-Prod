import AppKit
import Foundation
import SwiftUI

enum ProductionSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case equalizer
    case dynamics
    case meters
    case system
    case speakers
    case headphones
    case speakerCalibration
    case measurementLab
    case roomCorrection
    case activeAcoustics
    case roomAdvisor
    case blindListening
    case acousticResearch
    case hardwareAcceptance
    case plugins

    static let playback: [ProductionSection] = [
        .equalizer,
        .dynamics,
        .meters,
    ]

    static let extensions: [ProductionSection] = [
        .plugins,
    ]

    /// Bench and research workspaces. They are not in the sidebar; they open
    /// from the Developer menu once "Show developer tools" is on in Settings.
    static let developerTools: [ProductionSection] = [
        .hardwareAcceptance,
        .acousticResearch,
    ]

    /// The sidebar's groups, in order. The dashboard is a standalone row
    /// above them. A selected developer tool stays visible in a Developer
    /// group until the user moves to another section.
    static func sidebarGroups(
        selection: ProductionSection? = nil
    ) -> [ProductionSidebarGroup] {
        var groups = [
            ProductionSidebarGroup(title: "Playback", sections: playback),
            ProductionSidebarGroup(title: "System", sections: systemAreaSections),
            ProductionSidebarGroup(title: "Tools", sections: systemAreaTools),
            ProductionSidebarGroup(title: "Extensions", sections: extensions),
        ]
        if let selection, developerTools.contains(selection) {
            groups.append(ProductionSidebarGroup(title: "Developer", sections: [selection]))
        }
        return groups
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .equalizer: return "Equalizer"
        case .dynamics: return "Dynamics"
        case .meters: return "Meters"
        case .system: return "System"
        case .speakers: return "Speakers"
        case .headphones: return "Headphones"
        case .speakerCalibration: return "Speaker Calibration"
        case .measurementLab: return "Measurement Lab"
        case .roomCorrection: return "Room Correction"
        case .activeAcoustics: return "Active Acoustics"
        case .roomAdvisor: return "Room Advisor"
        case .blindListening: return "Blind Listening"
        case .acousticResearch: return "Acoustic Research"
        case .hardwareAcceptance: return "Hardware Acceptance"
        case .plugins: return "Plug-ins"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .equalizer: return "slider.horizontal.3"
        case .dynamics: return "waveform.path.ecg"
        case .meters: return "chart.xyaxis.line"
        case .system: return "slider.horizontal.below.square.and.square.filled"
        case .speakers: return "hifispeaker.2.fill"
        case .headphones: return "headphones"
        case .speakerCalibration: return "speaker.wave.3.fill"
        case .measurementLab: return "waveform.badge.magnifyingglass"
        case .roomCorrection: return "dial.medium"
        case .activeAcoustics: return "waveform.and.mic"
        case .roomAdvisor: return "wand.and.stars.inverse"
        case .blindListening: return "ear.badge.waveform"
        case .acousticResearch: return "waveform.path.ecg.rectangle"
        case .hardwareAcceptance: return "checkmark.shield.fill"
        case .plugins: return "puzzlepiece.extension"
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

    // A shallow 54° sweep on a long needle, like a 1970s receiver meter and
    // the app icon. Scale positions above are unchanged; only the arc is.
    static let startAngleDegrees = 243.0
    static let sweepDegrees = 54.0
    static var endAngleDegrees: Double { startAngleDegrees + sweepDegrees }

    static func angle(forVU vu: Double) -> Double {
        startAngleDegrees + normalizedPosition(forVU: vu) * sweepDegrees
    }

    static func point(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius)
    }
}

/// What the toolbar's processing readout says. Bypass only matters while the
/// tap is running: a stopped engine reads Stopped whatever the bypass switch.
struct ProductionProcessingStatus: Equatable {
    enum Tone: Equatable {
        case active, bypassed, stopped, transitioning, failed
    }

    let title: String
    let systemImage: String
    let tone: Tone

    init(lifecycleState: AudioLifecycleState, bypassed: Bool) {
        switch lifecycleState {
        case .running where bypassed:
            (title, systemImage, tone) = ("Bypassed", "arrow.trianglehead.branch", .bypassed)
        case .running:
            (title, systemImage, tone) = ("Active", "waveform", .active)
        case .idle:
            (title, systemImage, tone) = ("Stopped", "waveform.slash", .stopped)
        case .requestingPermission, .creatingTap, .creatingAggregate, .openingOutput, .starting:
            (title, systemImage, tone) = ("Starting…", "hourglass", .transitioning)
        case .reconfiguring:
            (title, systemImage, tone) = ("Reconfiguring…", "hourglass", .transitioning)
        case .recoveringOutput:
            (title, systemImage, tone) = ("Waiting for Output", "hourglass", .transitioning)
        case .stopping:
            (title, systemImage, tone) = ("Stopping…", "hourglass", .transitioning)
        case .failed:
            (title, systemImage, tone) = ("Failed", "exclamationmark.triangle.fill", .failed)
        }
    }

    var help: String {
        switch tone {
        case .active: return "Processing: audio plays through the DSP chain"
        case .bypassed: return "Bypassed: audio keeps playing, unprocessed"
        case .stopped: return "Processing is stopped: audio plays straight to the output"
        case .transitioning: return "Processing is changing state"
        case .failed: return "Processing failed. Switch Processing on to try again."
        }
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

struct ProductionSidebarGroup: Hashable, Identifiable {
    let title: String
    let sections: [ProductionSection]

    var id: String { title }
}

/// The main window's selected section. The app owns it so menu commands can
/// change the selection as well as the sidebar.
@MainActor
final class ProductionNavigation: ObservableObject {
    @Published var selection: ProductionSection? = .dashboard
    /// E12: the System area's tab and the Calibrate tab's section.
    @Published var systemTab: ProductionSystemTab = .overview
    @Published var calibrateSection: ProductionCalibrateSection = .alignment

    /// Selects a section. The old workspace sections resolve to a System tab.
    func navigate(to section: ProductionSection) {
        let destination = section.systemAreaDestination
        if let tab = destination.systemTab { systemTab = tab }
        if let calibrate = destination.calibrateSection { calibrateSection = calibrate }
        selection = destination.section
    }
}

struct ProductionRootView: View {
    @ObservedObject var product: ProductController
    @ObservedObject var navigation: ProductionNavigation
    #if DEBUG
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var commandError: String?
    @State private var showingGuidedSetup = false

    private var engine: AudioIOEngine { product.audioEngine }

    private var selection: ProductionSection? { navigation.selection }

    private var sidebarSelection: Binding<ProductionSection?> {
        Binding(
            get: { navigation.selection },
            set: { newValue in
                if let newValue {
                    navigation.navigate(to: newValue)
                } else {
                    navigation.selection = nil
                }
            }
        )
    }

    private var minimumWindowWidth: CGFloat {
        if selection == .equalizer, engine.stereoEQConfiguration.channelMode != .linked {
            return 1_320
        }
        return 980
    }

    /// The window subtitle carries the active output, the one piece of
    /// context every section shares.
    private var outputSubtitle: String {
        guard let output = engine.selectedOutputDevice else {
            return "No output selected"
        }
        return "\(output.name) · \(String(format: "%.1f", output.nominalSampleRate / 1_000)) kHz"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Label(
                    ProductionSection.dashboard.title,
                    systemImage: ProductionSection.dashboard.systemImage
                )
                .tag(ProductionSection.dashboard)

                ForEach(ProductionSection.sidebarGroups(selection: selection)) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.systemImage)
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 290)
        } detail: {
            detail(for: selection ?? .dashboard)
                .navigationTitle((selection ?? .dashboard).title)
                .navigationSubtitle(outputSubtitle)
                .toolbar { toolbar }
        }
        .frame(minWidth: minimumWindowWidth, minHeight: 680)
        .onChange(of: navigation.selection) { _, new in
            // Programmatic selections of an old section land on its System tab.
            if let new, new.systemAreaDestination.section == .system, new != .system {
                navigation.navigate(to: new)
            }
        }
        .task { product.prepareForUse() }
        .task {
            // E4: shadow-mode adaptive Quiet Zone paths are always on; they never play.
            product.adaptiveQuietZone.setActive(true)
            product.feedForwardShadow.setActive(true)
        }
        .sheet(
            isPresented: Binding(
                get: { product.recovery.safeLaunchActive },
                set: { _ in }
            )
        ) {
            ProductSafeLaunchSheet(product: product)
                .interactiveDismissDisabled()
        }
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
        .sheet(isPresented: $showingGuidedSetup) {
            ProductionSystemSetupFlowView(
                engine: engine,
                profiles: product.profiles,
                microphone: product.calibration,
                calibration: product.multichannelCalibration,
                advisor: product.roomTreatmentAdvisor
            )
        }
    }

    /// E12 S3: the "Set up my system" card.
    private var setupEntryCard: AnyView {
        let status = SystemCalibrationStatus.resolve(
            summary: product.profiles.selectedSystemProfile?.state.roomCorrectionCalibration,
            verifiedDesignID: nil)
        let availability = SystemSetupEntryPolicy.availability(
            outputName: engine.selectedOutputDevice?.name,
            outputUID: engine.selectedOutputDevice?.uid,
            state: product.profiles.selectedSystemProfile?.state,
            calibration: status)
        return AnyView(SystemSetupEntryCard(
            availability: availability,
            start: { showingGuidedSetup = true },
            openHeadphones: { navigation.navigate(to: .headphones) }))
    }

    @ViewBuilder
    private func detail(for section: ProductionSection) -> some View {
        if section.systemAreaDestination.section == .system {
            systemArea
        } else {
            sectionDetail(for: section)
        }
    }

    private var systemArea: some View {
        ProductionSystemAreaView(
            navigation: navigation,
            overview: AnyView(
                ProductionSystemOverviewView(
                    engine: engine, profiles: product.profiles, navigation: navigation,
                    entryCard: setupEntryCard)),
            speakers: AnyView(sectionDetail(for: .speakers)),
            room: AnyView(sectionDetail(for: .roomAdvisor)),
            measure: AnyView(sectionDetail(for: .measurementLab)),
            alignment: AnyView(sectionDetail(for: .speakerCalibration)),
            correction: AnyView(sectionDetail(for: .roomCorrection))
        )
    }

    @ViewBuilder
    private func sectionDetail(for section: ProductionSection) -> some View {
        switch section {
        case .system:
            systemArea
        case .dashboard:
            ProductionDashboardView(engine: engine, entryCard: setupEntryCard)
        case .equalizer:
            ProductionEqualizerView(engine: engine, reference: product.reference)
        case .dynamics:
            ProductionDynamicsView(engine: engine, reference: product.reference)
        case .meters:
            ProductionMetersView(
                engine: engine,
                assistant: product.headroomAssistant
            )
        case .speakers:
            ProductionSpeakersView(engine: engine, profiles: product.profiles)
        case .headphones:
            ProductionHeadphoneWorkspace(engine: engine, profiles: product.profiles)
        case .speakerCalibration:
            ProductionMultichannelCalibrationWorkspace(
                engine: engine,
                calibration: product.multichannelCalibration,
                microphone: product.calibration,
                profiles: product.profiles
            )
        case .measurementLab:
            ProductionSpeakerMeasurementLabWorkspace(
                engine: engine,
                microphone: product.calibration,
                profiles: product.profiles,
                roomCorrectionProjects: product.roomCorrectionProjects
            )
        case .roomCorrection:
            ProductionRoomCorrectionWorkspace(
                engine: engine,
                calibration: product.calibration,
                projects: product.roomCorrectionProjects,
                profiles: product.profiles
            )
        case .activeAcoustics:
            ProductionActiveAcousticsWorkspace(
                engine: engine,
                ambient: product.ambientCompensation,
                quietZone: product.activeQuietZone,
                adaptiveQuietZone: product.adaptiveQuietZone,
                feedForwardSurvey: product.feedForwardSurvey,
                feedForwardShadow: product.feedForwardShadow,
                microphone: product.calibration,
                projects: product.roomCorrectionProjects
            )
        case .roomAdvisor:
            ProductionRoomTreatmentAdvisorWorkspace(
                advisor: product.roomTreatmentAdvisor
            )
        case .blindListening:
            ProductionBlindListeningWorkspace(engine: engine)
        case .acousticResearch:
            ProductionOptionalAudioResearchWorkspace(engine: engine)
        case .hardwareAcceptance:
            ProductionHardwareAcceptanceWorkspace(
                engine: engine,
                profiles: product.profiles,
                acceptance: product.hardwareAcceptance
            )
        case .plugins:
            ProductionPluginWorkspace(product: product)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !(selection == .roomAdvisor || (selection == .system && navigation.systemTab == .room)) {
                ProductionProfileToolbar(product: product)

                #if DEBUG
                Button {
                    openWindow(id: "engineering-validation")
                } label: {
                    Label("Engineering Validation", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.glass)
                .help("Open the retained engineering validation tools")
                #endif
            }
        }

        if !(selection == .roomAdvisor || (selection == .system && navigation.systemTab == .room)) {
            // A readout, not a control: no glass, so it reads as status text.
            ToolbarItem(placement: .primaryAction) {
                ProductionProcessingStatusReadout(
                    status: ProductionProcessingStatus(
                        lifecycleState: engine.lifecycleState,
                        bypassed: engine.playbackControlConfiguration.globalBypassed
                    )
                )
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !(selection == .roomAdvisor || (selection == .system && navigation.systemTab == .room)) {
                // Bypass keeps the tap running and passes audio unprocessed;
                // the Processing switch beside it tears the tap down.
                Button {
                    do {
                        try engine.setGlobalDSPBypassed(
                            !engine.playbackControlConfiguration.globalBypassed
                        )
                        commandError = nil
                    } catch {
                        commandError = error.localizedDescription
                    }
                } label: {
                    Label(
                        engine.playbackControlConfiguration.globalBypassed
                            ? "Bypassed" : "Bypass",
                        // The signal routed around the processing: the usual
                        // picture of a bypass. Tinted orange while engaged.
                        systemImage: "arrow.trianglehead.branch"
                    )
                }
                .buttonStyle(.glass)
                .tint(engine.playbackControlConfiguration.globalBypassed ? .orange : nil)
                .help(
                    engine.playbackControlConfiguration.globalBypassed
                        ? "DSP is bypassed: audio plays unprocessed. Click to process again."
                        : "Bypass all DSP: audio keeps playing, unprocessed"
                )
                .disabled(engine.lifecycleState != .running)

                // A switch, not a button: processing is a standing on/off
                // state, and play/stop or power icons read as transport or
                // app power. Bypass beside it only applies while running.
                // A waveform glyph stands in for the visible label; the
                // toggle keeps "Processing" for VoiceOver and the tooltip.
                // Fixed sizes stop the toolbar stretching the switch.
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(engine.lifecycleState == .running ? .primary : .secondary)
                        .accessibilityHidden(true)
                    Toggle("Processing", isOn: Binding(
                        get: { engine.lifecycleState == .running },
                        set: { on in
                            Task { @MainActor in
                                await Task.yield()
                                if !on {
                                    guard engine.lifecycleState == .running else { return }
                                    engine.stop()
                                    commandError = nil
                                    return
                                }
                                if engine.lifecycleState == .failed {
                                    engine.stop()
                                }
                                guard engine.lifecycleState == .idle else {
                                    return
                                }
                                do {
                                    try await product.startProcessing()
                                    commandError = nil
                                } catch {
                                    commandError =
                                        error.localizedDescription
                                }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .fixedSize()
                    .tint(.green)
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .help(
                    engine.lifecycleState == .running
                        ? "Processing is on. Switch off to stop processing."
                        : "Processing is off. Switch on to start processing."
                )
                .disabled(
                    product.recovery.safeLaunchActive
                        || (
                            engine.lifecycleState != .idle
                                && engine.lifecycleState != .running
                                && engine.lifecycleState != .failed
                        )
                )
            }
        }

        ToolbarSpacer(.flexible)

        // No button style: the toolbar draws the two as one shared glass
        // capsule, help attached to Settings, rather than two buttons.
        ToolbarItemGroup(placement: .primaryAction) {
            ProductionReferenceHelpButton(
                navigator: product.reference,
                articleID: ProductionUserGuideCatalog.articleID(for: selection ?? .dashboard),
                label: "Open \((selection ?? .dashboard).title) in the User Guide"
            )

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open Settings")
        }
    }
}



private struct ProductionProcessingStatusReadout: View {
    let status: ProductionProcessingStatus

    private var color: Color {
        switch status.tone {
        case .active: return .green
        case .bypassed: return .orange
        case .stopped: return .secondary
        case .transitioning: return .yellow
        case .failed: return .red
        }
    }

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .fixedSize()
            .padding(.horizontal, 4)
            .help(status.help)
            .accessibilityLabel("Processing \(status.title)")
    }
}

private struct ProductSafeLaunchSheet: View {
    @ObservedObject var product: ProductController
    @State private var actionError: String?

    private var version: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lifepreserver.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Safe Launch")
                        .font(.title2.bold())
                    Text(
                        "Notch Sixty detected recovery evidence. Audio processing remains stopped until you choose how to continue."
                    )
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(
                    product.recovery.safeLaunchReasons,
                    id: \.self
                ) { reason in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            reason.title,
                            systemImage:
                                "exclamationmark.triangle.fill"
                        )
                        .font(.headline)
                        Text(reason.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    perform {
                        try product.openNormallyFromSafeLaunch()
                    }
                } label: {
                    Label(
                        "Open Normally",
                        systemImage: "arrow.right.circle.fill"
                    )
                }
                .buttonStyle(.glassProminent)

                Button {
                    perform {
                        try product
                            .openWithPlugInsBypassedFromSafeLaunch()
                    }
                } label: {
                    Label(
                        "Open with Plug-ins Bypassed This Launch",
                        systemImage: "puzzlepiece.extension.fill"
                    )
                }
                .buttonStyle(.glass)

                Button {
                    perform {
                        try product
                            .restoreLastKnownGoodFromSafeLaunch()
                    }
                } label: {
                    Label(
                        "Restore Last Known Good",
                        systemImage: "clock.arrow.circlepath"
                    )
                }
                .buttonStyle(.glass)
                .disabled(
                    !product.recovery.lastKnownGoodAvailable
                )

                Button {
                    let report = product.diagnosticsReport(
                        version: version,
                        build: build
                    )
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        report,
                        forType: .string
                    )
                } label: {
                    Label(
                        "Copy Diagnostics",
                        systemImage: "doc.on.doc"
                    )
                }
                .buttonStyle(.glass)
            }

            Text(
                "Plug-in bypass is temporary and does not edit the saved rack. Restore Last Known Good changes saved product profiles only after an explicit choice and never grants hardware-acceptance or release authority."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let actionError {
                Label(
                    actionError,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct ProductionDashboardView: View {
    @ObservedObject var engine: AudioIOEngine
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
            VStack(alignment: .leading, spacing: 24) {
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
                HStack(alignment: .top, spacing: 16) {
                    audioControls
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    masterControls
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                levelControls

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
            .padding(28)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output Device").font(.subheadline.bold())
                Spacer()
                Text(engine.lifecycleState.rawValue.capitalized)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
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
        .padding(14)
    }

    private var masterControls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                Button {
                    perform { try engine.setMasterMuted(!engine.masterVolumeConfiguration.muted) }
                } label: {
                    Image(systemName: engine.masterVolumeConfiguration.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Master Volume").font(.subheadline.bold())
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
            .padding(14)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        }
    }

    /// Everyday trims beside volume: input and output gain in one card,
    /// L/R balance in its own. Gain steps in 0.5 dB or takes a typed value;
    /// balance is a centre-detent bar. Double-clicking balance recentres it.
    private var levelControls: some View {
        HStack(alignment: .top, spacing: 16) {
            gainControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            balanceControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var gainControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gain").font(.subheadline.bold())
            HStack(spacing: 20) {
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
        .padding(14)
    }

    private var balanceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Balance").font(.subheadline.bold())
                Spacer()
                Text(Self.balanceReadout(engine.playbackControlConfiguration.balance))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("L").font(.caption.bold()).foregroundStyle(.secondary)
                ProductionBalanceBar(
                    balance: Binding(
                        get: { engine.playbackControlConfiguration.balance },
                        set: { value in perform { try engine.setChannelBalance(value) } }
                    )
                )
                Text("R").font(.caption.bold()).foregroundStyle(.secondary)
            }
        }
        .padding(14)
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
    @AppStorage(PreferenceKeys.vuMetersEnabled) private var vuMetersEnabled = true
    @State private var leftVU = ProductionVUScale.minimumVU
    @State private var rightVU = ProductionVUScale.minimumVU
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The meter switch and calibration note sit on the housing's lower
        // corners, either side of the branding, like a faceplate's legends.
        let palette = StereoSignatureVUPalette(darkAppearance: colorScheme == .dark)
        StereoSignatureVUMeter(leftVU: leftVU, rightVU: rightVU)
            .frame(minHeight: 250)
            .overlay(alignment: .bottomLeading) {
                Text("OUTPUT  ·  0 VU = −18 dBFS")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .tracking(1.2)
                    .foregroundStyle(palette.branding.opacity(0.75))
                    .padding(.leading, 28)
                    .padding(.bottom, 22)
                    .accessibilityLabel("Output meters, 0 VU equals −18 dBFS")
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    Text("METERS")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(palette.branding.opacity(0.75))
                    Toggle("VU Meters", isOn: $vuMetersEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.trailing, 28)
                .padding(.bottom, 20)
                .help("Turn the output VU meters on or off")
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

// Mirrors the approved app icons (DockIconDark / DockIconLight): dark mode is
// an espresso body with a cream face, light mode an ivory body with a black
// face; both use a glowing gold bezel, a glass lens with a top glare, and an
// orange needle whose pivot sits below the window. Pure SwiftUI presentation:
// no meter DSP, calibration, kinetics, scale geometry or audio changes.
struct StereoSignatureVUPalette {
    let housing: [Color]
    let housingRim: Color
    let face: [Color]
    let faceVignette: Color
    let scale: Color
    let hotScale: Color
    let legend: Color
    let branding: Color
    let brandingHighlight: Color
    let bezelGold: [Color]
    let bezelGlow: Color
    let glassGlare: Double
    let needle = Color(red: 1.00, green: 0.40, blue: 0.06)

    init(darkAppearance: Bool) {
        bezelGold = [
            Color(red: 1.00, green: 0.88, blue: 0.62),
            Color(red: 0.78, green: 0.52, blue: 0.24),
            Color(red: 0.42, green: 0.25, blue: 0.10),
            Color(red: 0.86, green: 0.62, blue: 0.32),
        ]
        bezelGlow = Color(red: 1.00, green: 0.70, blue: 0.32)
        if darkAppearance {
            // DockIconDark: espresso body, cream face, near-black scale.
            housing = [
                Color(red: 0.31, green: 0.24, blue: 0.20),
                Color(red: 0.22, green: 0.17, blue: 0.14),
                Color(red: 0.15, green: 0.11, blue: 0.09),
            ]
            housingRim = Color(red: 0.62, green: 0.52, blue: 0.45)
            face = [
                Color(red: 0.99, green: 0.97, blue: 0.91),
                Color(red: 0.95, green: 0.92, blue: 0.84),
            ]
            faceVignette = Color(red: 0.55, green: 0.47, blue: 0.36)
            scale = Color(red: 0.08, green: 0.06, blue: 0.05)
            hotScale = Color(red: 0.80, green: 0.06, blue: 0.05)
            legend = Color(red: 0.25, green: 0.20, blue: 0.16)
            branding = Color(red: 0.95, green: 0.90, blue: 0.80)
            brandingHighlight = .black.opacity(0.55)
            glassGlare = 0.55
        } else {
            // DockIconLight: ivory body, black face, cream scale.
            housing = [
                Color(red: 0.97, green: 0.96, blue: 0.92),
                Color(red: 0.92, green: 0.90, blue: 0.85),
                Color(red: 0.85, green: 0.82, blue: 0.76),
            ]
            housingRim = .white
            face = [
                Color(red: 0.16, green: 0.155, blue: 0.15),
                Color(red: 0.06, green: 0.06, blue: 0.06),
            ]
            faceVignette = .black
            scale = Color(red: 0.97, green: 0.94, blue: 0.86)
            hotScale = Color(red: 1.00, green: 0.10, blue: 0.08)
            legend = Color(red: 0.86, green: 0.82, blue: 0.74)
            branding = Color(red: 0.36, green: 0.22, blue: 0.12)
            brandingHighlight = .white.opacity(0.85)
            glassGlare = 0.26
        }
    }
}

/// Window geometry for one meter. `unit` sizes the window, ticks and labels;
/// the needle radius is 1.55 units, so the flat arc spans the same width and
/// arc length as a compact meter. The window ends far above the pivot, which
/// stays hidden like the icon's needle.
private struct StereoSignatureVUWindow {
    static let radiusInUnits: CGFloat = 1.55
    static let widthInUnits: CGFloat = 1.64
    static let heightInUnits: CGFloat = 0.55
    /// Window top above the scale arc's crown.
    static let headroomInUnits: CGFloat = 0.095

    let center: CGPoint
    let unit: CGFloat
    var radius: CGFloat { unit * Self.radiusInUnits }
    var scaleRadius: CGFloat { radius * 0.985 }
    var rect: CGRect {
        let width = unit * Self.widthInUnits
        let top = center.y - scaleRadius - unit * Self.headroomInUnits
        return CGRect(x: center.x - width / 2, y: top, width: width, height: unit * Self.heightInUnits)
    }
    var cornerRadius: CGFloat { rect.height * 0.16 }
}

struct StereoSignatureVUMeter: View {
    let leftVU: Double
    let rightVU: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            // Two icon-style windows side by side; the housing is 1.10 units
            // tall: window from 0.15 to 0.70, branding centred at 0.92.
            let unit = min(height / 1.10, width * 0.25)
            let windowTop = unit * 0.15
            let pivotY = windowTop + unit * StereoSignatureVUWindow.headroomInUnits
                + unit * StereoSignatureVUWindow.radiusInUnits * 0.985
            let leftCenter = CGPoint(x: width * 0.263, y: pivotY)
            let rightCenter = CGPoint(x: width * 0.737, y: pivotY)
            let palette = StereoSignatureVUPalette(darkAppearance: colorScheme == .dark)
            let windows = [
                StereoSignatureVUWindow(center: leftCenter, unit: unit),
                StereoSignatureVUWindow(center: rightCenter, unit: unit),
            ]

            ZStack {
                housing(palette: palette)

                ForEach(0..<2, id: \.self) { index in
                    meterWindow(
                        windows[index],
                        vu: index == 0 ? leftVU : rightVU,
                        legend: index == 0 ? "LEFT" : "RIGHT",
                        palette: palette,
                        size: proxy.size
                    )
                }

                Text("NOTCH SIXTY")
                    .font(.system(size: max(13, height * 0.085), weight: .regular, design: .default))
                    .tracking(max(4, height * 0.032))
                    .foregroundStyle(palette.branding)
                    .shadow(color: palette.brandingHighlight, radius: 0, y: colorScheme == .dark ? -0.8 : 0.9)
                    .position(x: width * 0.50, y: height * 0.836)
            }
        }
        .aspectRatio(4 / 1.10, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stereo output VU meter")
        .accessibilityValue("Left \(leftVU, specifier: "%.1f") VU, right \(rightVU, specifier: "%.1f") VU")
    }

    @ViewBuilder
    private func housing(palette: StereoSignatureVUPalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        shape
            .fill(LinearGradient(colors: palette.housing, startPoint: .top, endPoint: .bottom))
            .overlay {
                // Polished top rim, as on the icon body.
                shape.stroke(
                    LinearGradient(
                        colors: [
                            palette.housingRim.opacity(0.85),
                            palette.housingRim.opacity(0.10),
                            .clear,
                            .black.opacity(0.25),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.6
                )
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.22), radius: 14, y: 6)
    }

    @ViewBuilder
    private func meterWindow(
        _ window: StereoSignatureVUWindow,
        vu: Double,
        legend: String,
        palette: StereoSignatureVUPalette,
        size: CGSize
    ) -> some View {
        let rect = window.rect
        let corner = window.cornerRadius
        let windowShape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        ZStack {
            // Face, scale and needle share one clip: the needle runs off the
            // window's lower edge and its pivot is never visible.
            ZStack {
                windowShape
                    .fill(LinearGradient(colors: palette.face, startPoint: .top, endPoint: .bottom))
                    .overlay {
                        windowShape.fill(
                            RadialGradient(
                                colors: [.clear, palette.faceVignette.opacity(0.28)],
                                center: .center,
                                startRadius: rect.height * 0.35,
                                endRadius: rect.width * 0.62
                            )
                        )
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                StereoSignatureVUScaleFace(
                    center: window.center,
                    scaleRadius: window.scaleRadius,
                    unit: window.unit,
                    darkAppearance: colorScheme == .dark
                )
                .equatable()

                Text(legend)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(palette.legend.opacity(0.75))
                    .position(x: window.center.x, y: window.center.y - window.scaleRadius + window.unit * 0.37)

                Canvas { context, _ in
                    drawNeedle(context: &context, center: window.center, radius: window.scaleRadius, vu: vu, color: palette.needle)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(windowShape.path(in: rect))

            // Glass lens: top glare band, soft edge shading and a fine
            // specular line, drawn explicitly so it matches the icon.
            windowShape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(palette.glassGlare), location: 0),
                            .init(color: .white.opacity(palette.glassGlare * 0.35), location: 0.22),
                            .init(color: .white.opacity(0.0), location: 0.46),
                            .init(color: .clear, location: 0.80),
                            .init(color: .black.opacity(0.10), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    windowShape
                        .stroke(.black.opacity(0.45), lineWidth: 5)
                        .blur(radius: 4)
                        .clipShape(windowShape)
                }
                .overlay {
                    // Curved reflection across the upper lens, as on the icon.
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(palette.glassGlare * 0.9),
                                    .white.opacity(palette.glassGlare * 0.25),
                                    .clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: rect.width * 1.5, height: rect.height * 1.1)
                        .offset(y: -rect.height * 0.62)
                        .blendMode(.screen)
                }
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(.white.opacity(0.30))
                        .frame(width: rect.width * 0.70, height: 1.0)
                        .blur(radius: 0.8)
                        .padding(.top, rect.height * 0.05)
                }
                .frame(width: rect.width, height: rect.height)
                .clipShape(windowShape)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // Glowing gold bezel with an inner dark seat, as on the icon.
            windowShape
                .stroke(
                    AngularGradient(
                        colors: palette.bezelGold + [palette.bezelGold[0]],
                        center: .center
                    ),
                    lineWidth: 3.2
                )
                .overlay {
                    windowShape
                        .inset(by: 2.4)
                        .stroke(.black.opacity(0.65), lineWidth: 1.2)
                }
                .overlay {
                    windowShape
                        .inset(by: -2.6)
                        .stroke(.black.opacity(colorScheme == .dark ? 0.55 : 0.25), lineWidth: 1.4)
                }
                .shadow(color: palette.bezelGlow.opacity(0.65), radius: 5)
                .shadow(color: palette.bezelGlow.opacity(0.30), radius: 12)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private func drawNeedle(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        vu: Double,
        color: Color
    ) {
        let angle = ProductionVUScale.angle(forVU: vu)
        var path = Path()
        // Drawn from the hidden pivot; the window clip shows only the upper
        // segment, emerging from the lower edge like the icon's needle.
        path.move(to: center)
        path.addLine(to: ProductionVUScale.point(center: center, radius: radius, angle: angle))
        context.stroke(path, with: .color(.black.opacity(0.18)), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
    }
}

private struct StereoSignatureVUScaleFace: View, Equatable {
    let center: CGPoint
    let scaleRadius: CGFloat
    /// Tick and label insets are in window units, not radius fractions, so
    /// they keep their size on the long-needle arc.
    let unit: CGFloat
    let darkAppearance: Bool

    var body: some View {
        Canvas { context, _ in
            drawScale(context: &context, center: center)
        }
    }

    private func drawScale(context: inout GraphicsContext, center: CGPoint) {
        let palette = StereoSignatureVUPalette(darkAppearance: darkAppearance)
        let ticks: [Double] = [-40, -35, -30, -25, -20, -15, -10, -7, -5, -4, -3, -2, -1, 0, 1, 2, 3]
        // Standard VU face labelling (ANSI C16.5 / classic Weston-Sifam):
        // every dB across the -3...+3 working range, and -15 between -20 and
        // -10 so label spacing stays roughly even (about 9-12% of the sweep)
        // across the compressed quiet end.
        let labels: Set<Double> = [-40, -30, -20, -15, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]

        var arc = Path()
        arc.addArc(
            center: center,
            radius: scaleRadius,
            startAngle: .degrees(ProductionVUScale.startAngleDegrees),
            endAngle: .degrees(ProductionVUScale.endAngleDegrees),
            clockwise: false
        )
        context.stroke(arc, with: .color(palette.scale.opacity(0.75)), lineWidth: 1.25)

        var hotArc = Path()
        hotArc.addArc(
            center: center,
            radius: scaleRadius,
            startAngle: .degrees(ProductionVUScale.angle(forVU: 0)),
            endAngle: .degrees(ProductionVUScale.endAngleDegrees),
            clockwise: false
        )
        context.stroke(
            hotArc,
            with: .color(palette.hotScale.opacity(0.90)),
            lineWidth: 2.0
        )

        for value in ticks {
            let angle = ProductionVUScale.angle(forVU: value)
            let major = labels.contains(value)
            let inner = ProductionVUScale.point(
                center: center,
                radius: scaleRadius - unit * (major ? 0.09 : 0.06),
                angle: angle
            )
            let outer = ProductionVUScale.point(center: center, radius: scaleRadius, angle: angle)
            var path = Path()
            path.move(to: inner)
            path.addLine(to: outer)
            context.stroke(
                path,
                with: .color(value > 0 ? palette.hotScale.opacity(0.94) : palette.scale.opacity(0.85)),
                lineWidth: major ? 1.7 : 0.8
            )

            if major {
                let point = ProductionVUScale.point(center: center, radius: scaleRadius - unit * 0.17, angle: angle)
                let label = value > 0 ? "+\(Int(value))" : "\(Int(value))"
                context.draw(
                    Text(label)
                        .font(.system(size: 10, weight: value == 0 ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(value > 0 ? palette.hotScale : palette.scale),
                    at: point
                )
            }
        }

        context.draw(
            Text("VU")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(palette.legend.opacity(0.82)),
            at: CGPoint(x: center.x, y: center.y - scaleRadius + unit * 0.265)
        )
    }
}

private struct ProductionSpeakersView: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    @State private var actionError: String?

    private var routing: MultiOutputRoutingConfiguration {
        profiles.selectedSystemOutputRouting
    }

    private var physicalRoutingLocked: Bool {
        engine.lifecycleState != .idle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Speaker topology, bass management, crossover design, physical routing, and driver-level processing.")
                    .foregroundStyle(.secondary)

                ProductionRoutingEditorView(engine: engine)
                ProductionProfileSubwooferCard(engine: engine, profiles: profiles)
                playbackSystemCard
                crossoverCard
                if engine.bassManagementConfiguration.physicalOutputMode == .mainsSub {
                    subAlignmentCard
                }
                legacyRoutingSummary
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
                    Text("System").font(.caption).foregroundStyle(.secondary)
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
            Text("Speaker topology, crossover, and physical-output routing are stored with this System profile. Playback EQ, dynamics, preamp, and headroom remain independent.")
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
                    Text("Logical stereo bass management. Physical speaker layouts, crossovers and driver processing are set up in the routing editor above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Crossover Design", isOn: Binding(
                    get: { engine.bassManagementConfiguration.enabled },
                    set: { value in updateCrossover { $0.enabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            LabeledContent("Crossover Frequency") {
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
                .frame(width: 280)
            }
            .disabled(physicalRoutingLocked && routing.enabled)

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
                Toggle("Sub Phase Alignment", isOn: Binding(
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
        engine.bassManagementConfiguration.lowerFrequencyRange
    }

    @ViewBuilder
    private var legacyRoutingSummary: some View {
        if let reason = profiles.selectedSystemProfile?.state.unmigratedLegacyRoutingReason {
            VStack(alignment: .leading, spacing: 10) {
                Text("Legacy routing").font(.headline)
                Text("This profile uses a legacy physical crossover that the routing editor cannot represent: \(reason) It stays as stored and blocks multichannel playback until it is turned off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Turn off legacy routing") { turnOffLegacyRouting() }
                    .buttonStyle(.glass)
                    .disabled(physicalRoutingLocked)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
        }
    }

    private func turnOffLegacyRouting() {
        updateRouting { $0.enabled = false }
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

/// Inline banner for an engine rejection of a direct control edit (for
/// example a change that requires stopping multichannel processing). Controls
/// bound to the engine snap back on failure; this explains why.
struct ProductionActionErrorBanner: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    self.message = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .font(.callout)
            .padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Console-style dB marks under the software-volume fader. On the loudness
/// taper the slider position is the level, so each mark sits at its level;
/// on the dB-linear fader the marks are evenly spaced.
struct MasterVolumeFaderScale: View {
    var decibelLinear = false
    /// Approximate distance from the slider's ends to its knob centre at the
    /// stops, so marks line up with the knob.
    private let trackInset: CGFloat = 10

    /// The scale follows the volume step mode, like the readout: dB marks
    /// evenly spaced on the dB-linear fader, percent marks otherwise.
    private var marks: [(label: String, position: Double)] {
        guard decibelLinear else {
            return VolumeFeedbackPresentation.faderTickPercents.map {
                ("\($0)", Double($0) / 100)
            }
        }
        return [(VolumeFeedbackPresentation.faderTickLabel(nil), 0)]
            + VolumeFeedbackPresentation.decibelFaderTickDecibels.reversed().map {
                (
                    VolumeFeedbackPresentation.faderTickLabel($0),
                    MasterVolumeConfiguration.decibelFaderPosition(
                        forLevel: MasterVolumeConfiguration.level(forSoftwareTaperDB: $0)
                    )
                )
            }
    }

    var body: some View {
        GeometryReader { proxy in
            let track = max(proxy.size.width - 2 * trackInset, 0)
            ForEach(marks, id: \.label) { mark in
                VStack(spacing: 1) {
                    Rectangle().frame(width: 1, height: 4)
                    Text(mark.label).font(.caption2).monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .fixedSize()
                .position(x: trackInset + track * mark.position, y: proxy.size.height / 2)
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}

/// One gain trim: −/+ step 0.5 dB, and the value box takes a typed dB
/// value on Return. Values clamp to the trim's range.
private struct ProductionGainStepper: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void

    static let step = 0.5

    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                commit(value - Self.step)
            } label: {
                Image(systemName: "minus").frame(width: 14, height: 14)
            }
            .buttonStyle(.glass)
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("Decrease \(title.lowercased()) gain")

            TextField(title, text: $draft)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 70)
                .focused($editing)
                .onSubmit { commitDraft() }
                .onChange(of: editing) { _, isEditing in
                    if !isEditing { commitDraft() }
                }
                .accessibilityLabel("\(title) gain in decibels")

            Button {
                commit(value + Self.step)
            } label: {
                Image(systemName: "plus").frame(width: 14, height: 14)
            }
            .buttonStyle(.glass)
            .disabled(value >= range.upperBound)
            .accessibilityLabel("Increase \(title.lowercased()) gain")
        }
        .onAppear { draft = ProductionDashboardView.decibelReadout(value) }
        .onChange(of: value) { _, newValue in
            if !editing { draft = ProductionDashboardView.decibelReadout(newValue) }
        }
    }

    private func commit(_ proposed: Double) {
        let stepped = (proposed / Self.step).rounded() * Self.step
        set(min(max(stepped, range.lowerBound), range.upperBound))
    }

    private func commitDraft() {
        if let typed = Self.parseDecibels(draft) {
            set(min(max(typed, range.lowerBound), range.upperBound))
        }
        draft = ProductionDashboardView.decibelReadout(value)
    }

    /// Accepts "3", "+3.5", "-6 dB" and the readout's own "−6.0 dB".
    static func parseDecibels(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(cleaned), parsed.isFinite else { return nil }
        return parsed
    }
}

/// Balance as a centre-detent bar: the fill runs from the centre toward
/// the side that is favoured, so centre reads as neutral rather than half
/// full. Dragging snaps to centre within 2 %; double-click recentres.
private struct ProductionBalanceBar: View {
    @Binding var balance: Double

    private static let snap = 0.02
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(width - knob, 1)
            let centre = width / 2
            let clamped = min(max(balance, -1), 1)
            let knobX = knob / 2 + CGFloat((clamped + 1) / 2) * travel

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 6)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: abs(knobX - centre), height: 6)
                    .offset(x: min(knobX, centre))
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 2, height: 14)
                    .offset(x: centre - 1)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: knobX - knob / 2)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let position = (drag.location.x - knob / 2) / travel
                    var value = Double(min(max(position, 0), 1)) * 2 - 1
                    if abs(value) < Self.snap { value = 0 }
                    balance = (value * 100).rounded() / 100
                }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { balance = 0 })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Balance")
        .accessibilityValue(ProductionDashboardView.balanceReadout(balance))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: balance = min(balance + 0.05, 1)
            case .decrement: balance = max(balance - 0.05, -1)
            @unknown default: break
            }
        }
    }
}
