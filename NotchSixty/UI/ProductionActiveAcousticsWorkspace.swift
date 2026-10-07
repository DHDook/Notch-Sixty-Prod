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
                    .font(.caption2)
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
                    .font(.caption2)
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

private enum ActiveAcousticsTab: String, CaseIterable, Identifiable {
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
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var ambient: AmbientCompensationController
    @ObservedObject var quietZone: ActiveQuietZoneController
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    @ObservedObject var projects: RoomCorrectionProjectController

    @State private var selection: ActiveAcousticsTab = .ambientAnalysis
    @State private var transportSnapshot: ProductionTransportMeterSnapshot?
    @State private var ambientActionError: String?
    @State private var quietZoneActionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                Picker("Active Acoustics", selection: $selection) {
                    ForEach(ActiveAcousticsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .productionGlassPickerChrome()
                .frame(maxWidth: 520)

                switch selection {
                case .ambientAnalysis:
                    ambientAnalysis
                case .quietZone:
                    quietZoneView
                case .roomTreatment:
                    roomTreatment
                }
            }
            .padding(28)
            .frame(maxWidth: 1_080, alignment: .topLeading)
        }
        .task(id: engine.lifecycleState.rawValue) {
            await refreshTransportLoop()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Active Acoustics")
                    .font(.largeTitle.bold())
                Text("Adapt playback to the room, preserve conversation, and optionally suppress stable low-frequency noise.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("SYSTEM")
                .font(.caption.bold())
                .tracking(1.3)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var ambientAnalysis: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Playback Adaptation")
                            .font(.headline)
                        Text(playbackAdaptationDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ambient.monitorStatus.displayName.uppercased())
                        .font(.caption.bold())
                        .tracking(1.0)
                        .foregroundStyle(
                            ambient.monitorStatus == .failed
                                ? .red
                                : ambient.monitorStatus == .compensating
                                    ? .green
                                    : .secondary
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
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
                .productionGlassPickerChrome()

                Divider()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Active Quiet Zone")
                            .font(.subheadline.bold())
                        Text(
                            "Independently suppress eligible stable 25–150 Hz environmental tones."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(quietZone.status.displayName.uppercased())
                        .font(.caption.bold())
                        .foregroundStyle(
                            quietZone.status == .fault
                                ? .red
                                : quietZone.status == .cancelling
                                    ? .green
                                    : .secondary
                        )
                    Toggle(
                        "Active Quiet Zone",
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
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            if microphone.permissionStatus != .authorized {
                statusBanner(
                    title: "Microphone access required",
                    detail: "Ambient Compensation needs a live room microphone. Playback is never adapted until access is authorized and a microphone is selected.",
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
                .buttonStyle(.borderedProminent)
            } else {
                ambientSetupCard
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: 14
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

            if let analysis = ambient.latestAnalysis {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ],
                    spacing: 12
                ) {
                    metricCard(
                        title: "Low Support",
                        value: String(
                            format: "+%.2f dB",
                            ambient.appliedTarget.lowSupportDB
                        ),
                        detail: "Broad 30–250 Hz masking support."
                    )
                    metricCard(
                        title: "Presence",
                        value: String(
                            format: "+%.2f dB",
                            ambient.appliedTarget.presenceSupportDB
                        ),
                        detail: "Broad vocal/intelligibility support."
                    )
                    metricCard(
                        title: "Detail",
                        value: String(
                            format: "+%.2f dB",
                            ambient.appliedTarget.detailSupportDB
                        ),
                        detail: "Bounded high-frequency masking support."
                    )
                }

                adaptationDetailCard

                HStack(spacing: 20) {
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
                .font(.subheadline)
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }

            if let reason = ambient.appliedTarget.holdReason {
                Label(
                    holdReasonText(reason),
                    systemImage: "pause.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }

            if let error =
                ambientActionError ?? ambient.lastErrorDescription {
                Label(
                    error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }

            safetyNote(activeAcousticsSafetyNote)
        }
    }

    private var ambientSetupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Monitoring & Adaptation")
                .font(.headline)

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
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 18) {
                Button("Set Current Room as Quiet Baseline") {
                    performAmbient {
                        try ambient.captureQuietBaseline()
                    }
                }
                .buttonStyle(.bordered)
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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button("Clear") {
                        performAmbient {
                            try ambient.clearQuietBaseline()
                        }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text("Baseline required before automatic adaptation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 12) {
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

            HStack(spacing: 12) {
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
                Text(
                    "\(ambient.configuration.maximumLevelCompensationDB, specifier: "%.1f") dB"
                )
                .monospacedDigit()
                .frame(width: 62)
            }

                Text(
                    "Available Content Preset headroom: \(engine.ambientCompensationAvailableHeadroomDB, specifier: "%.1f") dB. Music Focus level lift is clamped to the smaller of this reserve and the maximum above."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if ambient.playbackAdaptationMode == .conversationFocus {
                let social =
                    ambient.configuration
                        .effectiveConversationPreservation
                VStack(alignment: .leading, spacing: 6) {
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Adaptation Detail")
                        .font(.headline)
                    Text(
                        adaptationDetailDescription
                    )
                    .font(.caption)
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
                .font(.caption.bold().monospacedDigit())
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
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
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("Shape")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("Applied")
                        .font(.caption.bold())
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

            HStack(spacing: 8) {
                Image(
                    systemName:
                        ambient.playbackAdaptationMode == .conversationFocus
                            ? "person.2.wave.2"
                            : "plus.circle"
                )
                Text(adaptationPolicyNote)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                "The curve is the exact combined live transfer function of the shared Active Acoustics overlay. It excludes the user's normal EQ, Room Correction and other DSP."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
        .font(.subheadline)
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
            return "Exact PR89 response, including bounded full-band recovery and the three masking-compensation filters."
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active Quiet Zone")
                        .font(.headline)
                    Text(
                        "Closed-loop low-frequency anti-noise for stable 25–150 Hz environmental tones."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(quietZone.status.displayName.uppercased())
                    .font(.caption.bold())
                    .tracking(1)
                    .foregroundStyle(
                        quietZone.status == .fault
                            ? .red
                            : quietZone.status == .cancelling
                                ? .green
                                : .secondary
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)

                Toggle(
                    "Enable",
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
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

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

            VStack(alignment: .leading, spacing: 12) {
                Text("Error Microphone & Acoustic Model")
                    .font(.headline)

                HStack(spacing: 12) {
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
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }

                Text(
                    "Quiet Zone reuses PR89's playback separation and the retained Room Correction impulse responses. The live error microphone—not the acoustic prediction—is the commit authority."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: 14
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
                    detail: "Remaining anti-noise source peak after Content Preset headroom and PR89 level recovery."
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
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Live Cancellation Detail")
                            .font(.headline)
                        Spacer()
                        Text("ERROR MIC VERIFIED")
                            .font(.caption.bold())
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
                        .font(.caption.bold())

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
                            .font(.caption.monospacedDigit())
                        }
                    }
                }
                .padding(18)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }

            if let reason = quietZone.holdReason {
                Label(
                    quietZoneHoldReasonText(reason),
                    systemImage:
                        quietZone.status == .fault
                            ? "exclamationmark.octagon.fill"
                            : "pause.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(
                    quietZone.status == .fault
                        ? .red
                        : .secondary
                )
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (quietZone.status == .fault
                        ? Color.red
                        : Color.secondary)
                        .opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }

            if let error =
                quietZoneActionError
                    ?? quietZone.lastErrorDescription {
                Label(
                    error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            }

            safetyNote(
                "Active Quiet Zone is deliberately limited to stable low-frequency components. It does not cancel speech, claps or broadband room sound and makes no claim of whole-room silence. A low-level probe must measurably improve the physical error microphone before full cancellation is allowed."
            )
        }
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
        VStack(alignment: .leading, spacing: 16) {
            roomTreatmentStatusCard

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 14
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

            VStack(alignment: .leading, spacing: 12) {
                Text("Acceptance Path")
                    .font(.headline)

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
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            safetyNote(
                "PR78 intentionally exposes status only. Room Treatment has no Arm, Bypass, or Stage control in the production UI until the real-hardware acceptance workflow is completed."
            )
        }
    }

    private var roomTreatmentStatusCard: some View {
        let treatment = transportSnapshot?.roomTreatment

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("MIMO Room Treatment", systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
                Spacer()
                Text(treatmentStatus)
                    .font(.caption.bold())
                    .tracking(1.0)
                    .foregroundStyle(treatment?.faulted == true ? .red : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }

            if let treatment {
                HStack(spacing: 18) {
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
                .font(.subheadline)

                Text(
                    treatment.faulted
                        ? "A runtime/protection fault is latched. The transition substrate returns toward latency-matched identity rather than leaving a partial treatment topology."
                        : "The live transport is reporting the hardware-gated treatment substrate. Authorization and arming remain separate states."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if engine.roomTreatmentStagedForNextStart {
                Text("A hardware-accepted treatment is staged for the next semantic-speaker start. It remains default-bypassed until the internal control plane explicitly arms it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No treatment is staged. The normal speaker path runs without PR77's additional treatment latency.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func metricCard(
        title: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func informationCard(
        title: String,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.headline)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .padding(.top, 6)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func readinessRow(
        title: String,
        detail: String,
        state: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(state)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func safetyNote(_ text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.16), in: .rect(cornerRadius: 14))
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
