import SwiftUI

private struct AmbientCompensationResponseCurveView: View {
    let points: [AmbientCompensationResponsePoint]
    let minimumGainDB: Double
    let maximumGainDB: Double

    private let minimumFrequencyHz = 20.0
    private let maximumFrequencyHz = 20_000.0

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let plot = CGRect(
                    x: 46,
                    y: 12,
                    width: max(size.width - 60, 1),
                    height: max(size.height - 40, 1)
                )
                var yMinimum = min(
                    floor(minimumGainDB - 0.5),
                    0
                )
                var yMaximum = max(
                    ceil(maximumGainDB + 0.5),
                    0
                )
                if yMaximum - yMinimum < 2 {
                    yMaximum += 1
                    yMinimum -= 1
                }

                drawGrid(
                    context: &context,
                    plot: plot,
                    minimumGainDB: yMinimum,
                    maximumGainDB: yMaximum
                )
                drawResponse(
                    context: &context,
                    plot: plot,
                    minimumGainDB: yMinimum,
                    maximumGainDB: yMaximum
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Active Acoustics adaptation response curve")
        .accessibilityValue(
            String(
                format: "Applied response ranges from %.2f to %.2f decibels",
                minimumGainDB,
                maximumGainDB
            )
        )
    }

    private func drawGrid(
        context: inout GraphicsContext,
        plot: CGRect,
        minimumGainDB: Double,
        maximumGainDB: Double
    ) {
        let frequencyGuides = [
            20.0, 100, 1_000, 10_000, 20_000,
        ]
        for frequency in frequencyGuides {
            let x = xPosition(
                frequencyHz: frequency,
                plot: plot
            )
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(
                path,
                with: .color(Color.secondary.opacity(0.13)),
                lineWidth: 1
            )

            let label: String
            switch frequency {
            case 1_000:
                label = "1k"
            case 10_000:
                label = "10k"
            case 20_000:
                label = "20k"
            default:
                label = String(format: "%.0f", frequency)
            }
            context.draw(
                Text(label)
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: x, y: plot.maxY + 13),
                anchor: .center
            )
        }

        let horizontalGuides = 4
        for index in 0...horizontalGuides {
            let fraction =
                Double(index) / Double(horizontalGuides)
            let gain =
                maximumGainDB
                - (maximumGainDB - minimumGainDB) * fraction
            let y =
                plot.minY + plot.height * CGFloat(fraction)
            let isZero = abs(gain) < 0.01
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(
                path,
                with: .color(
                    Color.secondary.opacity(
                        isZero ? 0.34 : 0.13
                    )
                ),
                lineWidth: isZero ? 1.25 : 1
            )
            context.draw(
                Text(String(format: "%+.1f", gain))
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary),
                at: CGPoint(x: plot.minX - 7, y: y),
                anchor: .trailing
            )
        }
    }

    private func drawResponse(
        context: inout GraphicsContext,
        plot: CGRect,
        minimumGainDB: Double,
        maximumGainDB: Double
    ) {
        guard !points.isEmpty else { return }

        var fill = Path()
        var line = Path()
        let zeroY = yPosition(
            gainDB: 0,
            plot: plot,
            minimumGainDB: minimumGainDB,
            maximumGainDB: maximumGainDB
        )

        for (index, point) in points.enumerated() {
            let x = xPosition(
                frequencyHz: point.frequencyHz,
                plot: plot
            )
            let y = yPosition(
                gainDB: point.gainDB,
                plot: plot,
                minimumGainDB: minimumGainDB,
                maximumGainDB: maximumGainDB
            )
            let position = CGPoint(x: x, y: y)

            if index == 0 {
                line.move(to: position)
                fill.move(to: CGPoint(x: x, y: zeroY))
                fill.addLine(to: position)
            } else {
                line.addLine(to: position)
                fill.addLine(to: position)
            }
        }

        if let last = points.last {
            fill.addLine(
                to: CGPoint(
                    x: xPosition(
                        frequencyHz: last.frequencyHz,
                        plot: plot
                    ),
                    y: zeroY
                )
            )
            fill.closeSubpath()
        }

        context.fill(
            fill,
            with: .color(Color.accentColor.opacity(0.10))
        )
        context.stroke(
            line,
            with: .color(Color.accentColor),
            lineWidth: 2
        )
    }

    private func yPosition(
        gainDB: Double,
        plot: CGRect,
        minimumGainDB: Double,
        maximumGainDB: Double
    ) -> CGFloat {
        let range = max(maximumGainDB - minimumGainDB, 0.001)
        let normalized = min(
            max((gainDB - minimumGainDB) / range, 0),
            1
        )
        return plot.maxY - CGFloat(normalized) * plot.height
    }

    private func xPosition(
        frequencyHz: Double,
        plot: CGRect
    ) -> CGFloat {
        let clamped = min(
            max(frequencyHz, minimumFrequencyHz),
            maximumFrequencyHz
        )
        let fraction =
            log(clamped / minimumFrequencyHz)
            / log(maximumFrequencyHz / minimumFrequencyHz)
        return plot.minX + plot.width * CGFloat(fraction)
    }
}

enum ActiveAcousticsTab: String, CaseIterable, Identifiable {
    case ambientAnalysis
    case quietZone
    case roomTreatment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ambientAnalysis: return "Playback Adaptation"
        case .quietZone: return "Quiet Zone"
        case .roomTreatment: return "Room Treatment"
        }
    }
}

struct ProductionActiveAcousticsWorkspace: View {
    var engine: AudioIOEngine
    @ObservedObject var ambient: AmbientCompensationController
    @ObservedObject var quietZone: ActiveQuietZoneController
    @ObservedObject var adaptiveQuietZone: AdaptiveQuietZoneShadow
    @ObservedObject var feedForwardSurvey: QuietZoneFeedForwardSurveyController
    @ObservedObject var feedForwardShadow: QuietZoneFeedForwardShadow
    /// E4 S25: nil unless `e4.feedforward-live` is on.
    var feedForwardArming: FeedForwardLiveArmingController?
    /// E19 S8: the Room Treatment controls, shown only behind `e19.mimo-treatment`.
    var mimoTreatment: MIMOTreatmentController?
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    @ObservedObject var projects: RoomCorrectionProjectController

    init(
        engine: AudioIOEngine,
        ambient: AmbientCompensationController,
        quietZone: ActiveQuietZoneController,
        adaptiveQuietZone: AdaptiveQuietZoneShadow,
        feedForwardSurvey: QuietZoneFeedForwardSurveyController,
        feedForwardShadow: QuietZoneFeedForwardShadow,
        feedForwardArming: FeedForwardLiveArmingController?,
        mimoTreatment: MIMOTreatmentController?,
        microphone: RoomCorrectionCalibrationController,
        projects: RoomCorrectionProjectController,
        initialTab: ActiveAcousticsTab = .ambientAnalysis
    ) {
        self.engine = engine
        self.ambient = ambient
        self.quietZone = quietZone
        self.adaptiveQuietZone = adaptiveQuietZone
        self.feedForwardSurvey = feedForwardSurvey
        self.feedForwardShadow = feedForwardShadow
        self.feedForwardArming = feedForwardArming
        self.mimoTreatment = mimoTreatment
        self.microphone = microphone
        self.projects = projects
        _selection = State(initialValue: initialTab)
    }

    @State private var selection: ActiveAcousticsTab
    @State private var transportSnapshot: ProductionTransportMeterSnapshot?
    @State private var ambientActionError: String?
    @State private var quietZoneActionError: String?
    @State private var advancedExpanded = false
    /// E12 S8 (G98): the Advanced disclosure shows in expert mode only.
    @Environment(\.interfaceMode) private var interfaceMode
    /// E12 S20: results kept for the "Earlier results" list.
    @StateObject private var results = AcousticsResultsStore()

    /// E12 S19 (`e12.active-acoustics-page`): the one Quiet Zone card. Swift only.
    private var onePageFlag: Bool { FeatureFlags().isEnabled(.activeAcousticsPage) }

    var body: some View {
        ProductionPageContainer {
            VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
                header

                Picker("Active Acoustics", selection: $selection) {
                    ForEach(ActiveAcousticsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                ProductionAcousticsMicrophoneCard(ambient: ambient, microphone: microphone)

                if onePageFlag { resultCard(for: selection) }

                switch selection {
                case .ambientAnalysis:
                    ambientAnalysis
                case .quietZone:
                    if onePageFlag { quietZonePageView } else { quietZoneView }
                case .roomTreatment:
                    roomTreatment
                }
            }
        }
        .task(id: engine.lifecycleState.rawValue) {
            await refreshTransportLoop()
        }
        // E12 S20: a compare ends on a tab change, when the page goes away and on quit.
        .onChange(of: selection) { _, _ in releaseCompare() }
        .onDisappear { releaseCompare() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            releaseCompare()
        }
        .onChange(of: allResultLines, initial: true) { _, _ in
            guard onePageFlag else { return }
            for tab in ActiveAcousticsTab.allCases { results.record(resultLines(for: tab), tab: tab) }
        }
    }

    // MARK: E12 S20 results and compare

    private var allResultLines: [AcousticsResultLine] {
        ActiveAcousticsTab.allCases.flatMap { resultLines(for: $0) }
    }

    private func resultLines(for tab: ActiveAcousticsTab) -> [AcousticsResultLine] {
        switch tab {
        case .ambientAnalysis:
            return AcousticsResultModel.playbackAdaptation(
                target: ambient.appliedTarget, monitoring: ambient.playbackAdaptationActive).map { [$0] } ?? []
        case .quietZone:
            return AcousticsResultModel.quietZone(tones: quietZone.toneTelemetry).map { [$0] } ?? []
        case .roomTreatment:
            guard let mimoTreatment, mimoTreatment.isAvailable else { return [] }
            return AcousticsResultModel.roomTreatment(
                predicted: mimoTreatment.seatDecays, measured: mimoTreatment.measuredSeatDecays)
        }
    }

    private func releaseCompare() {
        ambient.setCompareHeld(false)
        quietZone.setCompareHeld(false)
    }

    private var quietZoneCompareReason: String? {
        if feedForwardArming?.isRequested == true {
            return "Turn off Feed-forward to compare."
        }
        return quietZone.compareUnavailableReason
    }

    @ViewBuilder private func resultCard(for tab: ActiveAcousticsTab) -> some View {
        switch tab {
        case .ambientAnalysis:
            ProductionAcousticsResultCard(
                lines: resultLines(for: tab),
                emptyText: "No change to your music right now.",
                history: results.history.entries(for: tab),
                compare: .init(
                    isHeld: ambient.compareHeld,
                    unavailableReason: ambient.playbackAdaptationActive ? nil : "Turn Playback Adaptation on to compare.",
                    setHeld: { ambient.setCompareHeld($0) }),
                compareNote: nil)
        case .quietZone:
            ProductionAcousticsResultCard(
                lines: resultLines(for: tab),
                emptyText: "No measurement yet. Arm Quiet Zone to measure the reduction at your seat.",
                history: results.history.entries(for: tab),
                compare: .init(
                    isHeld: quietZone.compareHeld,
                    unavailableReason: quietZoneCompareReason,
                    setHeld: { quietZone.setCompareHeld($0) }),
                compareNote: nil)
        case .roomTreatment:
            ProductionAcousticsResultCard(
                lines: resultLines(for: tab),
                emptyText: "No prediction yet. Design a treatment to see the predicted bass decay.",
                history: results.history.entries(for: tab),
                compare: nil,
                compareNote: "Room Treatment cannot be switched off and back on while you hold: turning it off ends the armed session, and arming again needs a permit. Use Bypass, then arm again, to compare.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                Text("Adapt playback to the room, preserve conversation, and optionally suppress stable low-frequency noise.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var ambientAnalysis: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                HStack(alignment: .center, spacing: DesignSpacing.l.pt) {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text("Playback Adaptation")
                            .font(DesignType.sectionTitle.font)
                        Text(playbackAdaptationDescription)
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ambient.monitorStatus.displayName.uppercased())
                        .font(DesignType.caption.font.bold())
                        .tracking(1.0)
                        .foregroundStyle(
                            ambient.monitorStatus == .failed
                                ? .red
                                : ambient.monitorStatus == .compensating
                                    ? .green
                                    : .secondary
                        )
                        .padding(.horizontal, DesignSpacing.m.pt)
                        .padding(.vertical, DesignSpacing.s.pt)
                        .glassEffect(.regular, in: .capsule)
                }

                Picker(
                    "Playback Adaptation",
                    selection: Binding(
                        get: { ambient.playbackAdaptationMode },
                        set: { mode in
                            performAmbient {
                                try ambient
                                    .setPlaybackAdaptationMode(mode)
                            }
                        }
                    )
                ) {
                    ForEach(
                        ActiveAcousticsPlaybackAdaptationMode.allCases,
                        id: \.self
                    ) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Divider()

                HStack(spacing: DesignSpacing.m.pt) {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text("Active Quiet Zone")
                            .font(DesignType.label.font.bold())
                        Text(
                            "Independently suppress eligible stable 25–150 Hz environmental tones."
                        )
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(quietZone.status.displayName.uppercased())
                        .font(DesignType.caption.font.bold())
                        .foregroundStyle(
                            quietZone.status == .fault
                                ? .red
                                : quietZone.status == .cancelling
                                    ? .green
                                    : .secondary
                        )
                    if onePageFlag {
                        Button("Open Quiet Zone") { selection = .quietZone }
                            .buttonStyle(.glass)
                    } else {
                        if quietZone.arm.isArmed {
                            Button("Disarm", role: .destructive) {
                                quietZone.arm.disarm(.user)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(.red)
                            .accessibilityLabel("Disarm Active Quiet Zone")
                        }
                        Toggle(
                            "Arm Active Quiet Zone",
                            isOn: Binding(
                                get: { quietZone.configuration.enabled },
                                set: { enabled in
                                    performQuietZone {
                                        try quietZone.setEnabled(enabled)
                                    }
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
            .padding(DesignSpacing.l.pt)
            .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))

            if microphone.permissionStatus != .authorized {
                statusBanner(
                    title: "Microphone access required",
                    detail: "Active Acoustics needs a live room microphone for playback adaptation and Quiet Zone verification. Playback is never adapted until access is authorized and a microphone is selected.",
                    systemImage: "mic.slash"
                )
                Button("Request Microphone Access") {
                    Task {
                        await microphone.requestMicrophonePermission()
                        if microphone.permissionStatus == .authorized {
                            ambient.prepareForUse()
                        }
                    }
                }
                .buttonStyle(.glassProminent)
            } else {
                ambientSetupCard
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: DesignSpacing.l.pt
            ) {
                metricCard(
                    title: "Ambient Level",
                    value: ambientLevelValue,
                    detail: ambientLevelDetail
                )
                metricCard(
                    title: "Room Activity",
                    value: ambient.appliedTarget.activity.displayName,
                    detail: String(
                        format: "%+.1f dB from quiet baseline",
                        ambient.appliedTarget.ambientDeltaDB
                    )
                )
                metricCard(
                    title: "Separation Confidence",
                    value: ambient.latestAnalysis.map {
                        "\(Int(($0.separationConfidence * 100).rounded()))%"
                    } ?? "—",
                    detail: separationDetail
                )
                metricCard(
                    title: "Applied Level",
                    value: String(
                        format: "%+.2f dB",
                        ambient.appliedTarget.levelDB
                    ),
                    detail:
                        ambient.playbackAdaptationMode == .conversationFocus
                            ? "Subtractive social-listening adaptation; never a net level boost."
                            : "Never exceeds the Content Preset's available digital headroom."
                )
                if ambient.playbackAdaptationMode == .conversationFocus {
                    metricCard(
                        title: "Conversation Evidence",
                        value: "\(Int((ambient.appliedTarget.conversationEvidence * 100).rounded()))%",
                        detail: "Acoustic speech-likelihood evidence only; no recognition or transcription."
                    )
                    metricCard(
                        title: "Estimated Clearance",
                        value: String(
                            format: "+%.2f dB",
                            ambient.appliedTarget.estimatedClearanceDB
                        ),
                        detail: "Approximate playback reduction through the speech-critical region."
                    )
                }
            }

            if ambient.playbackAdaptationMode == .conversationFocus, let card = ambient.unmaskingCard {
                unmaskingCardView(card)
            }

            if let analysis = ambient.latestAnalysis {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ],
                    spacing: DesignSpacing.m.pt
                ) {
                    metricCard(
                        title:
                            ambient.playbackAdaptationMode == .conversationFocus
                                ? "Bass Preservation"
                                : "Low Support",
                        value: String(
                            format: "%+.2f dB",
                            ambient.appliedTarget.lowSupportDB
                        ),
                        detail:
                            ambient.playbackAdaptationMode == .conversationFocus
                                ? "Relative restoration keeps musical weight while total gain stays below unity."
                                : "Broad 30–250 Hz masking support."
                    )
                    metricCard(
                        title:
                            ambient.playbackAdaptationMode == .conversationFocus
                                ? "Speech-band Carve"
                                : "Presence",
                        value: String(
                            format: "%+.2f dB",
                            ambient.appliedTarget.presenceSupportDB
                        ),
                        detail:
                            ambient.playbackAdaptationMode == .conversationFocus
                                ? "Broad subtractive clearance centered in the intelligibility region."
                                : "Broad vocal/intelligibility support."
                    )
                    metricCard(
                        title:
                            ambient.playbackAdaptationMode == .conversationFocus
                                ? "Air Preservation"
                                : "Detail",
                        value: String(
                            format: "%+.2f dB",
                            ambient.appliedTarget.detailSupportDB
                        ),
                        detail:
                            ambient.playbackAdaptationMode == .conversationFocus
                                ? "Relative high-frequency restoration keeps ambience without a net boost."
                                : "Bounded high-frequency masking support."
                    )
                }

                adaptationDetailCard

                HStack(spacing: DesignSpacing.xl.pt) {
                    LabeledContent("Character") {
                        Text(analysis.character.rawValue)
                    }
                    LabeledContent("Stationarity") {
                        Text(
                            "\(Int((analysis.stationarityScore * 100).rounded()))%"
                        )
                        .monospacedDigit()
                    }
                    LabeledContent("LF Energy") {
                        Text(
                            "\(Int((analysis.lowFrequencyEnergyFraction * 100).rounded()))%"
                        )
                        .monospacedDigit()
                    }
                }
                .font(DesignType.label.font)
                .padding(DesignSpacing.l.pt)
                .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.medium.pt))
            }

            if let reason = ambient.appliedTarget.holdReason {
                Label(
                    holdReasonText(reason),
                    systemImage: "pause.circle.fill"
                )
                .font(DesignType.label.font)
                .foregroundStyle(.secondary)
                .padding(DesignSpacing.l.pt)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt)
                )
            }

            if let error =
                ambientActionError ?? ambient.lastErrorDescription {
                Label(
                    error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(DesignType.label.font)
                .foregroundStyle(StatusLevel.problem.color)
                .textSelection(.enabled)
                .padding(DesignSpacing.l.pt)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt)
                )
            }

            safetyNote(activeAcousticsSafetyNote)
        }
    }

    private var ambientSetupCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Text("Monitoring & Adaptation")
                .font(DesignType.sectionTitle.font)

            Grid(
                alignment: .leading,
                horizontalSpacing: 18,
                verticalSpacing: 12
            ) {
                GridRow {
                    Text("Microphone")
                        .foregroundStyle(.secondary)
                    Picker(
                        "Microphone",
                        selection: Binding(
                            get: {
                                microphone.selectedInputUID
                            },
                            set: { uid in
                                let wasEnabled =
                                    ambient.playbackAdaptationActive
                                    || quietZone.configuration.enabled
                                ambient.stopMonitoring()
                                microphone.selectInput(uid: uid)
                                if wasEnabled {
                                    performAmbient {
                                        try ambient.startMonitoring()
                                    }
                                }
                            }
                        )
                    ) {
                        Text("Select…")
                            .tag(String?.none)
                        ForEach(microphone.inputDevices) { device in
                            Text(device.name)
                                .tag(String?.some(device.uid))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }

                GridRow {
                    Text("Input channel")
                        .foregroundStyle(.secondary)
                    Stepper(
                        "Input \(microphone.selectedInputChannelIndex + 1)",
                        value: Binding(
                            get: {
                                microphone.selectedInputChannelIndex + 1
                            },
                            set: { value in
                                let wasEnabled =
                                    ambient.playbackAdaptationActive
                                    || quietZone.configuration.enabled
                                ambient.stopMonitoring()
                                performAmbient {
                                    try microphone
                                        .selectInputChannel(
                                            index: value - 1
                                        )
                                    if wasEnabled {
                                        try ambient.startMonitoring()
                                    }
                                }
                            }
                        ),
                        in: 1...32
                    )
                    .disabled(
                        microphone.selectedInputDevice == nil
                    )
                }

                GridRow {
                    Text("Playback model")
                        .foregroundStyle(.secondary)
                    Picker(
                        "Playback model",
                        selection: Binding(
                            get: {
                                ambient.configuration
                                    .playbackModelPositionID
                            },
                            set: { id in
                                performAmbient {
                                    try ambient
                                        .setPlaybackModelPosition(id)
                                }
                            }
                        )
                    ) {
                        Text("Observe only")
                            .tag(UUID?.none)
                        ForEach(ambient.availableModelPositions) {
                            position in
                            Text(position.name)
                                .tag(UUID?.some(position.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }
            }

            if !ambient.roomProjectMatchesSelectedMicrophone,
               !projects.positions.isEmpty {
                Label(
                    "The current Room Correction project was measured with a different microphone/channel. Choose the matching microphone or re-measure before enabling modeled playback subtraction.",
                    systemImage: "waveform.badge.exclamationmark"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: DesignSpacing.l.pt) {
                Button("Set Current Room as Quiet Baseline") {
                    performAmbient {
                        try ambient.captureQuietBaseline()
                    }
                }
                .buttonStyle(.glass)
                .disabled(ambient.latestAnalysis == nil)

                if let baseline =
                    ambient.configuration
                        .baselineAmbientLevelDBFS {
                    Text(
                        String(
                            format: "Baseline %.1f dBFS",
                            baseline
                        )
                    )
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button("Clear") {
                        performAmbient {
                            try ambient.clearQuietBaseline()
                        }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text("Baseline required before automatic adaptation.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: DesignSpacing.m.pt) {
                Text("Strength")
                    .frame(width: 100, alignment: .leading)
                Slider(
                    value: Binding(
                        get: {
                            ambient.configuration.strength
                        },
                        set: { value in
                            performAmbient {
                                try ambient.setStrength(value)
                            }
                        }
                    ),
                    in: 0...1,
                    step: 0.05
                )
                .designSlider("Ambient strength", value: ambient.configuration.strength, unit: .percent)
                Text(
                    "\(Int((ambient.configuration.strength * 100).rounded()))%"
                )
                .monospacedDigit()
                .frame(width: 54)
            }

            if ambient.playbackAdaptationMode == .musicFocus {
                Toggle(
                "Allow bounded level compensation",
                isOn: Binding(
                    get: {
                        ambient.configuration
                            .levelCompensationEnabled
                    },
                    set: { value in
                        performAmbient {
                            try ambient
                                .setLevelCompensationEnabled(value)
                        }
                    }
                )
            )
            .toggleStyle(.switch)

            HStack(spacing: DesignSpacing.m.pt) {
                Text("Maximum lift")
                    .frame(width: 100, alignment: .leading)
                Slider(
                    value: Binding(
                        get: {
                            ambient.configuration
                                .maximumLevelCompensationDB
                        },
                        set: { value in
                            performAmbient {
                                try ambient
                                    .setMaximumLevelCompensationDB(
                                        value
                                    )
                            }
                        }
                    ),
                    in: 0...6,
                    step: 0.5
                )
                .designSlider("Maximum lift", value: ambient.configuration.maximumLevelCompensationDB, unit: .db)
                Text(
                    "\(ambient.configuration.maximumLevelCompensationDB, specifier: "%.1f") dB"
                )
                .monospacedDigit()
                .frame(width: 62)
            }

                Text(
                    "Available Content Preset headroom: \(engine.ambientCompensationAvailableHeadroomDB, specifier: "%.1f") dB. Music Focus level lift is clamped to the smaller of this reserve and the maximum above."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            } else if ambient.playbackAdaptationMode == .conversationFocus {
                let social =
                    ambient.configuration
                        .effectiveConversationPreservation
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                    LabeledContent("Maximum music reduction") {
                        Text(
                            "\(social.maximumOverallAttenuationDB, specifier: "%.1f") dB"
                        )
                        .monospacedDigit()
                    }
                    LabeledContent("Maximum speech-band carve") {
                        Text(
                            "\(social.maximumPresenceCutDB, specifier: "%.1f") dB"
                        )
                        .monospacedDigit()
                    }
                    Text(
                        "Conversation Focus never applies net positive playback gain. Bass and air are only restored relative to the bounded full-band reduction."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var ambientResponseSampleRate: Double {
        engine.selectedOutputDevice?.nominalSampleRate ?? 48_000
    }

    private var ambientResponsePoints:
        [AmbientCompensationResponsePoint] {
        AmbientCompensationResponseModel.response(
            target: ambient.appliedTarget,
            sampleRate: ambientResponseSampleRate
        )
    }

    private var minimumAmbientAppliedGainDB: Double {
        AmbientCompensationResponseModel.minimumAppliedGainDB(
            target: ambient.appliedTarget,
            sampleRate: ambientResponseSampleRate
        )
    }

    private var maximumAmbientAppliedGainDB: Double {
        AmbientCompensationResponseModel.maximumAppliedGainDB(
            target: ambient.appliedTarget,
            sampleRate: ambientResponseSampleRate
        )
    }

    private var adaptationDetailCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Adaptation Detail")
                        .font(DesignType.sectionTitle.font)
                    Text(
                        adaptationDetailDescription
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    String(
                        format: "%+.2f / %+.2f dB",
                        minimumAmbientAppliedGainDB,
                        maximumAmbientAppliedGainDB
                    )
                )
                .font(DesignType.caption.font.bold().monospacedDigit())
                .padding(.horizontal, DesignSpacing.s.pt)
                .padding(.vertical, DesignSpacing.xs.pt)
                .glassEffect(.regular, in: .capsule)
            }

            AmbientCompensationResponseCurveView(
                points: ambientResponsePoints,
                minimumGainDB: minimumAmbientAppliedGainDB,
                maximumGainDB: maximumAmbientAppliedGainDB
            )
            .frame(height: 220)

            Grid(
                alignment: .leading,
                horizontalSpacing: 20,
                verticalSpacing: 8
            ) {
                GridRow {
                    Text("Stage")
                        .font(DesignType.caption.font.bold())
                        .foregroundStyle(.secondary)
                    Text("Shape")
                        .font(DesignType.caption.font.bold())
                        .foregroundStyle(.secondary)
                    Text("Applied")
                        .font(DesignType.caption.font.bold())
                        .foregroundStyle(.secondary)
                }

                adaptationRow(
                    name: ambient.playbackAdaptationMode == .conversationFocus
                        ? "Overall level"
                        : "Level recovery",
                    shape: "Full band",
                    gainDB: ambient.appliedTarget.levelDB
                )
                adaptationRow(
                    name: ambient.playbackAdaptationMode == .conversationFocus
                        ? "Bass preservation"
                        : "Low support",
                    shape: String(
                        format: "Low shelf · %.0f Hz · Q %.3f",
                        AmbientCompensationResponseModel
                            .lowShelfFrequencyHz,
                        AmbientCompensationResponseModel.lowShelfQ
                    ),
                    gainDB: ambient.appliedTarget.lowSupportDB
                )
                adaptationRow(
                    name: ambient.playbackAdaptationMode == .conversationFocus
                        ? "Speech-band carve"
                        : "Presence",
                    shape: String(
                        format: "Bell · %.1f kHz · Q %.2f",
                        AmbientCompensationResponseModel
                            .presenceFrequencyHz / 1_000,
                        AmbientCompensationResponseModel.presenceQ
                    ),
                    gainDB:
                        ambient.appliedTarget.presenceSupportDB
                )
                adaptationRow(
                    name: ambient.playbackAdaptationMode == .conversationFocus
                        ? "Air preservation"
                        : "Detail",
                    shape: String(
                        format: "High shelf · %.1f kHz · Q %.3f",
                        AmbientCompensationResponseModel
                            .detailShelfFrequencyHz / 1_000,
                        AmbientCompensationResponseModel.detailShelfQ
                    ),
                    gainDB: ambient.appliedTarget.detailSupportDB
                )
            }

            HStack(spacing: DesignSpacing.s.pt) {
                Image(
                    systemName:
                        ambient.playbackAdaptationMode == .conversationFocus
                            ? "person.2.wave.2"
                            : "plus.circle"
                )
                Text(adaptationPolicyNote)
            }
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)

            Text(
                "The curve is the exact combined live transfer function of the shared Active Acoustics overlay. It excludes the user's normal EQ, Room Correction and other DSP."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    @ViewBuilder
    private func adaptationRow(
        name: String,
        shape: String,
        gainDB: Double
    ) -> some View {
        GridRow {
            Text(name)
            Text(shape)
                .foregroundStyle(.secondary)
            Text(String(format: "%+.2f dB", gainDB))
                .monospacedDigit()
        }
        .font(DesignType.label.font)
    }

    private var playbackAdaptationDescription: String {
        switch ambient.playbackAdaptationMode {
        case .off:
            return "Monitor the room without automatically changing playback."
        case .musicFocus:
            return "Preserve musical clarity and presence as environmental masking rises."
        case .conversationFocus:
            return "Keep music present while reducing interference with nearby conversation."
        }
    }

    private var adaptationDetailDescription: String {
        switch ambient.playbackAdaptationMode {
        case .conversationFocus:
            return "Exact subtractive response used to create conversational clearance while preserving musical weight and air."
        case .musicFocus:
            return "Exact response, including bounded full-band recovery and the three masking-compensation filters."
        case .off:
            return "The shared adaptation overlay is at unity while Playback Adaptation is off."
        }
    }

    private var adaptationPolicyNote: String {
        switch ambient.playbackAdaptationMode {
        case .conversationFocus:
            return "Conversation Focus uses bounded attenuation and a broad speech-band carve. Relative bass/air restoration is constrained so the combined response never intentionally exceeds unity."
        case .musicFocus:
            return "Music Focus only restores energy masked by added room noise; it does not apply automatic subtractive EQ."
        case .off:
            return "Playback Adaptation is off; no automatic boost or cut is requested."
        }
    }

    private var activeAcousticsSafetyNote: String {
        switch ambient.playbackAdaptationMode {
        case .conversationFocus:
            return "Conversation Focus uses only separated acoustic evidence. It performs no speech recognition or transcription, never stores microphone audio, and releases smoothly toward unity when conversation evidence disappears."
        case .musicFocus:
            return "Music Focus reacts over seconds, not milliseconds. Transient events are rejected and automatic level recovery can consume only digital headroom already reserved by the active Content Preset."
        case .off:
            return "Playback Adaptation is off. Active Quiet Zone may still use the shared microphone observation independently when enabled."
        }
    }

    private var ambientLevelValue: String {
        guard let analysis = ambient.latestAnalysis else {
            return "—"
        }
        if let spl = analysis.ambientLevelDBSPL {
            return String(format: "%.1f dB SPL", spl)
        }
        return String(
            format: "%.1f dBFS",
            analysis.ambientLevelDBFS
        )
    }

    private var ambientLevelDetail: String {
        if ambient.currentAmbientDisplayUsesSPL {
            return "Absolute SPL uses the configured microphone level reference."
        }
        return "Relative level; no absolute SPL calibration is claimed."
    }

    private var separationDetail: String {
        guard let analysis = ambient.latestAnalysis else {
            return "Waiting for a complete analysis window."
        }
        switch analysis.separationMode {
        case .microphoneOnly:
            return "Microphone-only observation."
        case .modeledPlaybackSubtraction:
            return "Rendered playback is subtracted through the selected measured room model."
        case .playbackModelUnavailable:
            return "Playback is audible but no trustworthy matching acoustic model is available."
        }
    }

    private func holdReasonText(
        _ reason: AmbientCompensationHoldReason
    ) -> String {
        switch reason {
        case .disabled:
            return "Ambient Compensation is disabled."
        case .baselineRequired:
            return "Set a quiet-room baseline before automatic adaptation."
        case .playbackModelRequired:
            return "Automatic adaptation is held until a matching measured playback-to-microphone model is selected."
        case .lowSeparationConfidence:
            return "Playback subtraction confidence is below the configured threshold; compensation is held."
        case .nonstationaryTransient:
            return "A transient/nonstationary event was detected. Compensation is temporarily held."
        case .invalidEvidence:
            return "Ambient evidence is invalid or stale; compensation is held."
        case .noAvailableHeadroom:
            return "No digital headroom is available for level recovery."
        }
    }

    private func performAmbient(
        _ operation: () throws -> Void
    ) {
        ambientActionError = nil
        do {
            try operation()
        } catch {
            ambientActionError = error.localizedDescription
        }
    }

    private var quietZoneView: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack(alignment: .center, spacing: DesignSpacing.l.pt) {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Active Quiet Zone")
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "Closed-loop low-frequency anti-noise for stable 25–150 Hz environmental tones."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(quietZone.status.displayName.uppercased())
                    .font(DesignType.caption.font.bold())
                    .tracking(1)
                    .foregroundStyle(
                        quietZone.status == .fault
                            ? .red
                            : quietZone.status == .cancelling
                                ? .green
                                : .secondary
                    )
                    .padding(.horizontal, DesignSpacing.m.pt)
                    .padding(.vertical, DesignSpacing.s.pt)
                    .glassEffect(.regular, in: .capsule)

                if let message = quietZone.arm.statusMessage {
                    Text(message).font(DesignType.caption.font).foregroundStyle(StatusLevel.attention.color)
                }
                if quietZone.arm.isArmed {
                    Button("Disarm", role: .destructive) {
                        quietZone.arm.disarm(.user)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                }
                Toggle(
                    "Arm",
                    isOn: Binding(
                        get: { quietZone.configuration.enabled },
                        set: { enabled in
                            performQuietZone {
                                try quietZone.setEnabled(enabled)
                            }
                        }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(DesignSpacing.l.pt)
            .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))

            if engine.lifecycleState != .running {
                statusBanner(
                    title: "Playback engine must be running",
                    detail: "Quiet Zone generates bounded anti-noise through the active stereo speaker route. Start processing before arming it.",
                    systemImage: "speaker.slash"
                )
            }

            if ambient.selectedModelPosition == nil {
                statusBanner(
                    title: "Measured speaker-to-microphone model required",
                    detail: "Choose a retained Room Correction position below. The microphone identity, channel, calibration and sample rate must match.",
                    systemImage: "waveform.badge.exclamationmark"
                )
            }

            VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                Text("Error Microphone & Acoustic Model")
                    .font(DesignType.sectionTitle.font)

                HStack(spacing: DesignSpacing.m.pt) {
                    Text("Playback model")
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Picker(
                        "Playback model",
                        selection: Binding(
                            get: {
                                ambient.configuration
                                    .playbackModelPositionID
                            },
                            set: { id in
                                performQuietZone {
                                    try ambient
                                        .setPlaybackModelPosition(id)
                                }
                            }
                        )
                    ) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(ambient.availableModelPositions) {
                            position in
                            Text(position.name)
                                .tag(UUID?.some(position.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)

                    Spacer()
                    if let model = ambient.selectedModelPosition {
                        Text(
                            "\(model.name) · \(model.sampleRate / 1_000, specifier: "%.1f") kHz"
                        )
                        .font(DesignType.caption.font.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }

                Text(
                    "Quiet Zone reuses the playback separation and the retained Room Correction impulse responses. The live error microphone—not the acoustic prediction—is the commit authority."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }
            .padding(DesignSpacing.l.pt)
            .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))

            if let noiseSurvey = quietZone.noiseSurvey {
                ProductionNoiseSurveyCard(survey: noiseSurvey)
            }
            if let virtualMic = quietZone.virtualMic {
                ProductionVirtualMicrophoneCard(
                    survey: virtualMic,
                    quietZoneRunning: quietZone.configuration.enabled && quietZone.status != .fault)
                if let headFollow = virtualMic.headFollow {
                    ProductionHeadFollowCard(follow: headFollow, survey: virtualMic)
                }
                if let zones = quietZone.zones {
                    ProductionZoneChooserCard(
                        zones: zones, first: virtualMic, second: zones.second,
                        quietZoneRunning: quietZone.configuration.enabled && quietZone.status != .fault)
                }
            }
            spatialQuietZoneCard
            ProductionFeedForwardReadinessCard(quietZone: quietZone)
            ProductionSubAwareQuietZoneCard(quietZone: quietZone, survey: feedForwardSurvey)
            ProductionFeedForwardDesignSurveyCard(survey: feedForwardSurvey)
            ProductionFeedForwardShadowCard(shadow: feedForwardShadow)
            if let feedForwardArming {
                ProductionFeedForwardLiveCard(quietZone: quietZone, arming: feedForwardArming)
            }

            quietZoneResultSections

            ProductionAdaptiveQuietZoneCard(
                shadow: adaptiveQuietZone,
                latencyText: ancLatencyText
            )

            safetyNote(
                "Active Quiet Zone is deliberately limited to stable low-frequency components. It does not cancel speech, claps or broadband room sound and makes no claim of whole-room silence. A low-level probe must measurably improve the physical error microphone before full cancellation is allowed."
            )
        }
    }

    /// E12 S19: the one-card Quiet Zone page. One card (setup list, where to quiet, the two switches), then the
    /// measured result, then everything else under "Advanced".
    private var quietZonePageView: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            if engine.lifecycleState != .running {
                statusBanner(
                    title: "Playback engine must be running",
                    detail: "Quiet Zone generates bounded anti-noise through the active stereo speaker route. Start processing before arming it.",
                    systemImage: "speaker.slash"
                )
            }

            ProductionQuietZoneCard(
                quietZone: quietZone,
                ambient: ambient,
                microphone: microphone,
                engineRunning: engine.lifecycleState == .running,
                perform: { performQuietZone($0) }
            )

            if let reason = quietZone.holdReason {
                Label(
                    quietZoneHoldReasonText(reason),
                    systemImage: quietZone.status == .fault ? "exclamationmark.octagon.fill" : "pause.circle.fill"
                )
                .font(DesignType.label.font)
                .foregroundStyle(quietZone.status == .fault ? Color.red : Color.secondary)
                .padding(DesignSpacing.l.pt)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (quietZone.status == .fault ? Color.red : Color.secondary).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt)
                )
            }
            if let error = quietZoneActionError ?? quietZone.lastErrorDescription {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignType.label.font)
                    .foregroundStyle(StatusLevel.problem.color)
                    .textSelection(.enabled)
            }

            // Setup that the card's "where to quiet" choice and the sub step depend on.
            ProductionSubAwareQuietZoneCard(quietZone: quietZone, survey: feedForwardSurvey)
            if let virtualMic = quietZone.virtualMic {
                ProductionVirtualMicrophoneCard(
                    survey: virtualMic,
                    quietZoneRunning: quietZone.configuration.enabled && quietZone.status != .fault,
                    showsEarSwitch: false)
                if let zones = quietZone.zones {
                    ProductionZoneChooserCard(
                        zones: zones, first: virtualMic, second: zones.second,
                        quietZoneRunning: quietZone.configuration.enabled && quietZone.status != .fault,
                        showsModePicker: false)
                }
            }

            quietZoneResultSections

            if interfaceMode.isExpert {
            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                    if let noiseSurvey = quietZone.noiseSurvey {
                        ProductionNoiseSurveyCard(survey: noiseSurvey)
                    }
                    if let virtualMic = quietZone.virtualMic, let headFollow = virtualMic.headFollow {
                        // The camera consent control: kept out of the main card so it has only its two switches.
                        ProductionHeadFollowCard(follow: headFollow, survey: virtualMic)
                    }
                    spatialQuietZoneCard
                    ProductionFeedForwardDesignSurveyCard(survey: feedForwardSurvey)
                    ProductionFeedForwardShadowCard(shadow: feedForwardShadow)
                    ProductionAdaptiveQuietZoneCard(shadow: adaptiveQuietZone, latencyText: ancLatencyText)
                }
                .padding(.top, DesignSpacing.m.pt)
            }
            .font(DesignType.sectionTitle.font)
            }

            safetyNote(
                "Active Quiet Zone is deliberately limited to stable low-frequency components. It does not cancel speech, claps or broadband room sound and makes no claim of whole-room silence. A low-level probe must measurably improve the physical error microphone before full cancellation is allowed."
            )
        }
    }

    /// The measured results, hold reason and last error, shared by the old and the one-card Quiet Zone page.
    @ViewBuilder private var quietZoneResultSections: some View {
            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: DesignSpacing.l.pt
            ) {
                metricCard(
                    title: "Controlled Frequencies",
                    value: quietZoneFrequencyValue,
                    detail: String(
                        format: "Stable components admitted inside the configured %.0f–%.0f Hz band.",
                        quietZone.configuration.minimumFrequencyHz,
                        quietZone.configuration.maximumFrequencyHz
                    )
                )
                metricCard(
                    title: "Measured Attenuation",
                    value: quietZoneReductionValue,
                    detail: "Physical error-microphone improvement, not predicted cancellation."
                )
                metricCard(
                    title: "Injection Reserve",
                    value: quietZoneInjectionValue,
                    detail: "Remaining anti-noise source peak after Content Preset headroom and level recovery."
                )
                metricCard(
                    title: "Target Reduction",
                    value: String(
                        format: "%.1f dB",
                        quietZone.configuration.targetReductionDB
                    ),
                    detail: "The solver deliberately stops at this bounded target instead of chasing theoretical silence."
                )
            }

            if !quietZone.toneTelemetry.isEmpty {
                VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                    HStack {
                        Text("Live Cancellation Detail")
                            .font(DesignType.sectionTitle.font)
                        Spacer()
                        Text("ERROR MIC VERIFIED")
                            .font(DesignType.caption.font.bold())
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                    }

                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 18,
                        verticalSpacing: 8
                    ) {
                        GridRow {
                            Text("Tone").foregroundStyle(.secondary)
                            Text("Disturbance").foregroundStyle(.secondary)
                            Text("Residual").foregroundStyle(.secondary)
                            Text("Measured").foregroundStyle(.secondary)
                            Text("Predicted").foregroundStyle(.secondary)
                            Text("L source").foregroundStyle(.secondary)
                            Text("R source").foregroundStyle(.secondary)
                        }
                        .font(DesignType.caption.font.bold())

                        ForEach(quietZone.toneTelemetry) { tone in
                            GridRow {
                                Text(
                                    "\(tone.frequencyHz, specifier: "%.1f") Hz"
                                )
                                Text(
                                    "\(tone.disturbanceLevelDBFS, specifier: "%.1f") dBFS"
                                )
                                Text(
                                    "\(tone.residualLevelDBFS, specifier: "%.1f") dBFS"
                                )
                                Text(
                                    "\(tone.measuredReductionDB, specifier: "%+.1f") dB"
                                )
                                .foregroundStyle(
                                    tone.measuredReductionDB >= 1
                                        ? .green
                                        : tone.measuredReductionDB < -1
                                            ? .red
                                            : .secondary
                                )
                                Text(
                                    "\(tone.predictedReductionDB, specifier: "%.1f") dB"
                                )
                                Text(
                                    "\(tone.leftSourceLevelDBFS, specifier: "%.1f") dBFS"
                                )
                                Text(
                                    "\(tone.rightSourceLevelDBFS, specifier: "%.1f") dBFS"
                                )
                            }
                            .font(DesignType.caption.font.monospacedDigit())
                        }
                    }
                }
                .padding(DesignSpacing.l.pt)
                .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
            }

            if let reason = quietZone.holdReason {
                Label(
                    quietZoneHoldReasonText(reason),
                    systemImage:
                        quietZone.status == .fault
                            ? "exclamationmark.octagon.fill"
                            : "pause.circle.fill"
                )
                .font(DesignType.label.font)
                .foregroundStyle(
                    quietZone.status == .fault
                        ? .red
                        : .secondary
                )
                .padding(DesignSpacing.l.pt)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (quietZone.status == .fault
                        ? Color.red
                        : Color.secondary)
                        .opacity(0.08),
                    in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt)
                )
            }

            if let error =
                quietZoneActionError
                    ?? quietZone.lastErrorDescription {
                Label(
                    error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(DesignType.label.font)
                .foregroundStyle(StatusLevel.problem.color)
                .textSelection(.enabled)
            }
    }

    /// E4 S7: measured round trip for the current output, microphone, rate
    /// and buffer, from the bench table or this Mac's own measurements.
    private var ancLatencyText: String {
        guard let output = engine.selectedOutputDevice,
              let mic = microphone.selectedInputDevice else {
            return "Not yet measured (select an output and a microphone)"
        }
        let bufferText = engine.lowLatencyOutputBufferFrames.map { "\($0)-frame low-latency buffer" }
            ?? "low-latency buffer not applied"
        guard let frames = engine.lowLatencyOutputBufferFrames else {
            return "Not yet measured (\(bufferText))"
        }
        let key = QuietZoneLatencyKey(
            outputDeviceUID: output.uid,
            microphoneDeviceUID: mic.uid,
            sampleRate: output.nominalSampleRate,
            bufferFrames: frames
        )
        let status = ANCSupportedHardware.latency(for: key, store: QuietZoneMeasuredLatencyStore())
        return "\(status.displayText), \(bufferText)"
    }

    private var spatialControlToggle: some View {
        Toggle(
                    "Spatial Control",
                    isOn: Binding(
                        get: {
                            quietZone.spatialCalibration?
                                .settings.enabled ?? false
                        },
                        set: { enabled in
                            performQuietZone {
                                try quietZone.setSpatialEnabled(enabled)
                            }
                        }
                    )
                )
                .disabled(
                    quietZone.spatialCalibration?.surveys.isEmpty
                        != false
                )
    }

    private var spatialQuietZoneCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Multi-Position Quiet Zone")
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "Move one microphone between 2–5 positions. Spatial noise cancellation requires a shared phase reference—not just multiple room sweeps."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Preview")
                    .font(DesignType.caption.font.bold())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: DesignSpacing.m.pt) {
                Button {
                    performQuietZone {
                        try quietZone.prepareSpatialPositions()
                    }
                } label: {
                    Label("Save Spatial Positions", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.glass)
                .disabled(
                    ambient.selectedModelPosition == nil
                        || !ambient.roomProjectMatchesSelectedMicrophone
                )

                Button {
                    quietZone.refreshSpatialCalibration()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                Spacer()

                if onePageFlag {
                    spatialControlToggle.toggleStyle(.checkbox)
                } else {
                    spatialControlToggle.toggleStyle(.switch)
                }
            }

            if let calibration = quietZone.spatialCalibration {
                HStack(spacing: DesignSpacing.l.pt) {
                    Label(
                        "\(calibration.positions.count) measured positions",
                        systemImage: "mappin.and.ellipse"
                    )
                    Label(
                        "\(calibration.surveys.count) coherent surveys",
                        systemImage: "waveform.path"
                    )
                }
                .font(DesignType.caption.font.monospacedDigit())
                .foregroundStyle(.secondary)
                if let anchor = ambient.selectedModelPosition,
                   calibration.anchorPositionID != anchor.id {
                    Label(
                        "Live microphone is not at the calibrated anchor; spatial control cannot operate.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(StatusLevel.attention.color)
                }
            }

            Text(quietZone.spatialReadinessMessage)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                Text("One-Microphone Coherent Tone Survey")
                    .font(DesignType.label.font.bold())
                Text(
                    "Stop playback and Quiet Zone. Leave a stable external 25–150 Hz tone running. Capture twice at the anchor, twice at each other measured position, then twice again at the anchor without interrupting the Mac microphone stream."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)

                HStack(spacing: DesignSpacing.m.pt) {
                    Text(
                        String(
                            format: "Survey tone %.0f Hz",
                            quietZone.requestedSpatialSurveyFrequencyHz
                        )
                    )
                    .font(DesignType.caption.font.monospacedDigit())
                    Slider(
                        value: $quietZone.requestedSpatialSurveyFrequencyHz,
                        in: 25...150,
                        step: 1
                    )
                    .designSlider("Survey frequency", value: quietZone.requestedSpatialSurveyFrequencyHz, unit: .hz)
                    .frame(maxWidth: 250)
                    .disabled(quietZone.spatialSurveyActive)

                    if quietZone.spatialSurveyActive {
                        Button {
                            performQuietZone {
                                try quietZone.captureSpatialSurveyWindow()
                            }
                        } label: {
                            Label(
                                "Capture This Position",
                                systemImage: "mic.fill"
                            )
                        }
                        .buttonStyle(.glassProminent)

                        Button("Cancel") {
                            quietZone.cancelSpatialSurvey()
                        }
                        .buttonStyle(.glass)
                    } else {
                        Button {
                            performQuietZone {
                                try quietZone.beginSpatialSurvey()
                            }
                        } label: {
                            Label(
                                "Begin Survey",
                                systemImage: "waveform.badge.mic"
                            )
                        }
                        .buttonStyle(.glass)
                        .disabled(
                            quietZone.spatialCalibration == nil
                                || quietZone.configuration.enabled
                                || engine.lifecycleState == .running
                        )
                    }
                }

                if quietZone.spatialSurveyActive {
                    Text(
                        quietZone.nextSpatialSurveyPositionName
                            ?? "Return microphone to the anchor"
                    )
                    .font(DesignType.label.font.bold())
                    Text(
                        "Capture \(quietZone.spatialSurveyProgress) of \(((quietZone.spatialCalibration?.positions.count ?? 0) + 1) * 2)"
                    )
                    .font(DesignType.caption.font.monospacedDigit())
                }
                Text(quietZone.spatialSurveyMessage)
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
            .padding(DesignSpacing.m.pt)
            .background(
                .secondary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt)
            )

            if !quietZone.spatialPredictions.isEmpty {
                Text("Modeled spatial effect — not simultaneous physical verification")
                    .font(DesignType.caption.font.bold())
                ForEach(quietZone.spatialPredictions) { seat in
                    HStack {
                        Text(
                            quietZone.spatialCalibration?
                                .positions.first(where: {
                                    $0.id == seat.positionID
                                }).flatMap { calibrated in
                                    ambient.availableModelPositions.first {
                                        $0.id == calibrated.id
                                    }?.name
                                } ?? "Measured seat"
                        )
                        Spacer()
                        Text(
                            String(
                                format: "%+.1f dB predicted reduction",
                                seat.predictedReductionDB
                            )
                        )
                        .monospacedDigit()
                    }
                    .font(DesignType.caption.font)
                }
            }

            Text(
                "Ordinary Room Correction sweeps do not establish external-noise phase. The one-mic tone survey attempts to preserve a shared clock and validates stationarity with an anchor-return capture; if it cannot, spatial ANC stays off. One physical mic verifies only its current seat, so re-measure all seats before claiming area-wide improvement."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var quietZoneFrequencyValue: String {
        guard !quietZone.controlledFrequenciesHz.isEmpty else {
            return "—"
        }
        return quietZone.controlledFrequenciesHz
            .map { String(format: "%.1f Hz", $0) }
            .joined(separator: " · ")
    }

    private var quietZoneReductionValue: String {
        guard !quietZone.toneTelemetry.isEmpty else {
            return "—"
        }
        let reduction =
            quietZone.toneTelemetry
                .map(\.measuredReductionDB)
                .reduce(0, +)
                / Double(quietZone.toneTelemetry.count)
        return String(format: "%+.1f dB", reduction)
    }

    private var quietZoneInjectionValue: String {
        guard quietZone.availableInjectionPeak > 0 else {
            return "0 dBFS reserve"
        }
        return String(
            format: "%.1f dBFS peak",
            20 * log10(quietZone.availableInjectionPeak)
        )
    }

    private func quietZoneHoldReasonText(
        _ reason: ActiveQuietZoneHoldReason
    ) -> String {
        switch reason {
        case .disabled:
            return "Active Quiet Zone is disabled."
        case .ambientEvidenceUnavailable:
            return "Waiting for fresh trusted error-microphone evidence."
        case .playbackSeparationUntrusted:
            return "Playback separation is not trustworthy enough to generate anti-noise."
        case .noiseNotStationary:
            return "The environmental sound is changing too quickly for stable cancellation."
        case .noEligibleTone:
            return "No stable low-frequency component currently meets the cancellation gates."
        case .toneNotPersistent:
            return "A candidate tone is present but has not remained frequency-stable long enough."
        case .acousticModelRequired:
            return "Select a matching retained speaker-to-microphone Room Correction model."
        case .insufficientOutputHeadroom:
            return "Not enough reserved digital headroom remains for bounded anti-noise injection."
        case .verificationPending:
            return "A low-level cancellation probe is being verified by the live error microphone."
        case .verificationRegression:
            return "The live probe increased the target component; anti-noise was fault-faded."
        case .phaseReferenceUnavailable:
            return "The rendered anti-noise phase reference is not trustworthy enough to update cancellation."
        case .protectionActive:
            return "Output protection or a realtime safety condition disarmed the Quiet Zone."
        case .unsupportedRoute:
            return "Quiet Zone currently requires the direct stereo speaker transport."
        }
    }

    private func performQuietZone(
        _ operation: () throws -> Void
    ) {
        quietZoneActionError = nil
        do {
            try operation()
        } catch {
            quietZoneActionError = error.localizedDescription
        }
    }

    private var roomTreatment: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            if let mimoTreatment, mimoTreatment.isAvailable {
                ProductionMIMOTreatmentSection(controller: mimoTreatment)
            }
            if let mimoTreatment, mimoTreatment.isAvailable {
                ProductionRoomTreatmentHonestyLive(controller: mimoTreatment)
            } else {
                ProductionRoomTreatmentHonesty(missing: ["Room Treatment is not available in this build."])
            }
            roomTreatmentStatusCard

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: DesignSpacing.l.pt
            ) {
                metricCard(
                    title: "Treatment Band",
                    value: "20–150 Hz",
                    detail: "Conservative low-frequency scope for the current MIMO designer."
                )
                metricCard(
                    title: "Treatment Sources",
                    value: treatmentSourceValue,
                    detail: treatmentSourceDetail
                )
                metricCard(
                    title: "Added Latency",
                    value: treatmentLatencyValue,
                    detail: "All physical outputs are latency-matched whenever a treatment runtime is configured."
                )
                metricCard(
                    title: "Protection",
                    value: protectionValue,
                    detail: protectionDetail
                )
            }

            VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                Text("Acceptance Path")
                    .font(DesignType.sectionTitle.font)

                readinessRow(
                    title: "MIMO design",
                    detail: "Regularized, bounded spatial design and robustness simulation",
                    state: "Ready",
                    systemImage: "checkmark.circle.fill"
                )
                readinessRow(
                    title: "FIR realization",
                    detail: "Causal matrix FIR with dense post-compile safety verification",
                    state: "Ready",
                    systemImage: "checkmark.circle.fill"
                )
                readinessRow(
                    title: "Repeat measurement",
                    detail: "Treated room must measurably improve without a hidden level shift",
                    state: engine.roomTreatmentStagedForNextStart ? "Accepted" : "Required",
                    systemImage: engine.roomTreatmentStagedForNextStart
                        ? "checkmark.circle.fill"
                        : "circle.dashed"
                )
                readinessRow(
                    title: "Hardware acceptance",
                    detail: "Excursion, thermal, protection, lifecycle, and audible-artifact checks",
                    state: hardwareGateLabel,
                    systemImage: engine.roomTreatmentStagedForNextStart
                        ? "checkmark.shield.fill"
                        : "lock.shield"
                )
            }
            .padding(DesignSpacing.l.pt)
            .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))

            safetyNote(
                mimoTreatment?.isAvailable == true
                    ? "Room Treatment is off until you arm it, and arming needs a permit. Without a hardware acceptance or bench qualification no permit is issued."
                    : "Room Treatment intentionally exposes status only. Room Treatment has no Arm, Bypass, or Stage control in the production UI until the real-hardware acceptance workflow is completed."
            )
        }
    }

    private var roomTreatmentStatusCard: some View {
        let treatment = transportSnapshot?.roomTreatment

        return VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                Label("MIMO Room Treatment", systemImage: "waveform.path.ecg.rectangle")
                    .font(DesignType.sectionTitle.font)
                Spacer()
                Text(treatmentStatus)
                    .font(DesignType.caption.font.bold())
                    .tracking(1.0)
                    .foregroundStyle(treatment?.faulted == true ? .red : .secondary)
                    .padding(.horizontal, DesignSpacing.m.pt)
                    .padding(.vertical, DesignSpacing.s.pt)
                    .glassEffect(.regular, in: .capsule)
            }

            if let treatment {
                HStack(spacing: DesignSpacing.l.pt) {
                    LabeledContent("Mix") {
                        Text("\(Double(treatment.treatmentMix * 100), specifier: "%.0f")%")
                            .monospacedDigit()
                    }
                    LabeledContent("Clamps") {
                        Text("\(treatment.protectionClampSamples)")
                            .monospacedDigit()
                    }
                    LabeledContent("Failures") {
                        Text("\(treatment.integrationFailures)")
                            .monospacedDigit()
                    }
                }
                .font(DesignType.label.font)

                Text(
                    treatment.faulted
                        ? "A runtime/protection fault is latched. The transition substrate returns toward latency-matched identity rather than leaving a partial treatment topology."
                        : "The live transport is reporting the hardware-gated treatment substrate. Authorization and arming remain separate states."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            } else if engine.roomTreatmentStagedForNextStart {
                Text("A hardware-accepted treatment is staged for the next speaker start. It remains default-bypassed until the internal control plane explicitly arms it.")
                    .font(DesignType.label.font)
                    .foregroundStyle(.secondary)
            } else {
                Text("No treatment is staged. The normal speaker path runs without the additional treatment latency.")
                    .font(DesignType.label.font)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var treatmentStatus: String {
        guard let treatment = transportSnapshot?.roomTreatment else {
            return engine.roomTreatmentStagedForNextStart ? "STAGED" : "NOT STAGED"
        }
        if treatment.faulted { return "FAULT" }
        if treatment.active { return "ACTIVE" }
        if treatment.transitioning { return "TRANSITIONING" }
        if treatment.authorized { return "BYPASSED · AUTHORIZED" }
        return "BYPASSED"
    }

    private var hardwareGateLabel: String {
        if transportSnapshot?.roomTreatment?.authorized == true {
            return "Accepted"
        }
        return engine.roomTreatmentStagedForNextStart ? "Accepted" : "Required"
    }

    private var treatmentSourceValue: String {
        if let count = transportSnapshot?.roomTreatment?.treatmentSourceCount {
            return "\(count)"
        }
        return engine.roomTreatmentStagedForNextStart ? "Accepted set" : "—"
    }

    private var treatmentSourceDetail: String {
        if transportSnapshot?.roomTreatment != nil {
            return "Exact speaker/Sub N source identities are bound to the accepted physical route."
        }
        return "No live treatment source map is currently installed."
    }

    private var treatmentLatencyValue: String {
        guard let treatment = transportSnapshot?.roomTreatment else { return "0 frames" }
        let milliseconds = transportSnapshot.map {
            Double(treatment.latencyFrames) / max($0.sampleRate, 1) * 1_000
        } ?? 0
        return "\(treatment.latencyFrames) frames · \(String(format: "%.1f", milliseconds)) ms"
    }

    private var protectionValue: String {
        guard let treatment = transportSnapshot?.roomTreatment else {
            return engine.roomTreatmentStagedForNextStart ? "Hardware-gated" : "Not engaged"
        }
        if treatment.faulted { return "FAULT · SAFE BYPASS" }
        if treatment.protectionClampSamples > 0 { return "Clamp observed" }
        return "Normal"
    }

    private var protectionDetail: String {
        guard let treatment = transportSnapshot?.roomTreatment else {
            return "Physical source safety and final protection are prerequisites for staging."
        }
        return "\(treatment.protectionClampSamples) emergency clamp samples · \(treatment.integrationFailures) integration failures."
    }

    private func statusBanner(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
            Image(systemName: systemImage)
                .font(DesignType.sectionTitle.font)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text(title)
                    .font(DesignType.sectionTitle.font)
                Text(detail)
                    .font(DesignType.label.font)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    /// E4 S30c: the Conversation Focus card (`e4.conversation-unmasking`): speech detected, the realised cut curve,
    /// estimated intelligibility before and after, and why per-band unmasking fell back.
    private func unmaskingCardView(_ card: ConversationUnmaskingCardModel) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Conversation unmasking")
                .font(DesignType.sectionTitle.font)
            HStack(spacing: DesignSpacing.xl.pt) {
                LabeledContent("Speech") {
                    Text(card.speechDetected ? "Detected (\(card.speechConfidencePercent)%)" : "Not detected")
                }
                if let before = card.siiBefore, let after = card.siiAfter {
                    LabeledContent("Intelligibility (SII)") {
                        Text(String(format: "%.2f to %.2f", before, after)).monospacedDigit()
                    }
                }
                LabeledContent("Largest cut") {
                    Text(String(format: "%.1f dB in %d bands", card.maximumCutDB, card.cutBandCount)).monospacedDigit()
                }
            }
            .font(DesignType.label.font)
            if !card.curve.isEmpty {
                AmbientCompensationResponseCurveView(
                    points: card.curve,
                    minimumGainDB: card.curve.map(\.gainDB).min() ?? 0,
                    maximumGainDB: 0
                )
                .frame(height: 140)
            }
            if let reason = card.fallbackReason {
                Label(reason, systemImage: "info.circle")
                    .font(DesignType.label.font)
                    .foregroundStyle(.secondary)
            }
            Text(ConversationUnmaskingCardModel.estimateNote + " " + ConversationUnmaskingCardModel.microphoneNote)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.medium.pt))
    }

    private func metricCard(
        title: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text(title)
                .font(DesignType.caption.font.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignType.sectionTitle.font.weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.medium.pt))
    }

    private func informationCard(
        title: String,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text(title)
                .font(DesignType.sectionTitle.font)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: DesignSpacing.s.pt) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .padding(.top, DesignSpacing.s.pt)
                    Text(item)
                        .font(DesignType.label.font)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private func readinessRow(
        title: String,
        detail: String,
        state: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: DesignSpacing.m.pt) {
            Image(systemName: systemImage)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text(title)
                    .font(DesignType.label.font.weight(.semibold))
                Text(detail)
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(state)
                .font(DesignType.caption.font.bold())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignSpacing.xs.pt)
    }

    private func safetyNote(_ text: String) -> some View {
        Label {
            Text(text)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.16), in: .rect(cornerRadius: DesignRadius.medium.pt))
    }

    @MainActor
    private func refreshTransportLoop() async {
        transportSnapshot = engine.productionTransportMeterSnapshot()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { break }
            transportSnapshot = engine.productionTransportMeterSnapshot()
        }
    }
}
