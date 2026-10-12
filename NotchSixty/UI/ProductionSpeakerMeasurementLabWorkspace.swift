import SwiftUI
import UniformTypeIdentifiers

private struct SpeakerMeasurementLabExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.json, .plainText]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ProductionSpeakerMeasurementLabWorkspace: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    @ObservedObject var profiles: ProductProfileController
    @StateObject private var lab: SpeakerMeasurementLabController
    @StateObject private var alignment:
        CoherentSubwooferAlignmentGuidedController

    private let store = SpeakerMeasurementLabSessionStore()
    private let reportBuilder = SpeakerMeasurementLabReportBuilder()
    private let exporter = SpeakerMeasurementLabReportExporter()

    @State private var draft = SpeakerMeasurementLabProtocolDraft()
    @State private var queuedProtocols: [SpeakerMeasurementLabProtocol] = []
    @State private var sharedReferenceEnabled = false
    @State private var referenceInputChannel = 2
    @State private var referenceMinimumSNRDB = 35.0
    @State private var recentSessions: [SpeakerMeasurementLabSession] = []
    @State private var actionError: String?
    @State private var exportDocument: SpeakerMeasurementLabExportDocument?
    @State private var exportContentType: UTType = .json
    @State private var exportFilename = "notch-sixty-speaker-lab"
    @State private var showingExporter = false

    init(
        engine: AudioIOEngine,
        microphone: RoomCorrectionCalibrationController,
        profiles: ProductProfileController
    ) {
        _engine = ObservedObject(wrappedValue: engine)
        _microphone = ObservedObject(wrappedValue: microphone)
        _profiles = ObservedObject(wrappedValue: profiles)
        _lab = StateObject(
            wrappedValue: SpeakerMeasurementLabController(
                engine: engine,
                profiles: profiles,
                microphone: microphone
            )
        )
        _alignment = StateObject(
            wrappedValue:
                CoherentSubwooferAlignmentGuidedController(
                    profileStore: profiles
                )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                environmentCard
                protocolComposerCard
                sessionCard
                reportCard
                coherentAlignmentCard
                historyCard

                if let error = actionError
                    ?? alignment.lastErrorDescription
                    ?? lab.lastErrorDescription
                    ?? microphone.lastErrorDescription {
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
            }
            .padding(28)
            .frame(maxWidth: 1_100, alignment: .topLeading)
        }
        .task {
            microphone.prepareForUse()
            refreshRecentSessions()
        }
        .task(id: lab.state) {
            guard lab.state == .measuring else { return }
            while !Task.isCancelled && lab.state == .measuring {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                do {
                    if try await lab.finishMeasurementIfComplete() {
                        refreshRecentSessions()
                        break
                    }
                } catch {
                    actionError = error.localizedDescription
                    break
                }
            }
        }
        .task(id: lab.session?.modifiedAt) {
            refreshRecentSessions()
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                actionError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Advanced Speaker Measurement Lab")
                        .font(.largeTitle.bold())
                    Text(
                        "Source-specific acoustic diagnostics, protected-driver measurement, and authenticated mains/sub timing evidence."
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    "MEASURE → REVIEW → VERIFY",
                    systemImage: "checkmark.shield"
                )
                    .font(.caption.bold())
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: Capsule())
            }

            Text(
                "Lab analyses never mutate DSP on their own. Coherent Sub Alignment below can turn authenticated Main/Sub timing evidence into an explicit reviewed transaction, followed by mandatory fresh measured verification."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var environmentCard: some View {
        GroupBox("Measurement Environment") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                    status("System", profiles.selectedSystemProfileName)
                    status(
                        "Output",
                        engine.selectedOutputDevice?.name ?? "Not selected"
                    )
                    status(
                        "Rate",
                        engine.selectedOutputDevice.map {
                            String(
                                format: "%.1f kHz",
                                $0.nominalSampleRate / 1_000
                            )
                        } ?? "—"
                    )
                    status(
                        "DSP",
                        engine.lifecycleState.rawValue.capitalized
                    )
                }
                HStack(spacing: 24) {
                    status(
                        "Microphone",
                        microphone.selectedInputDevice?.name
                            ?? "Not selected"
                    )
                    status(
                        "Mic Channel",
                        "\(microphone.selectedInputChannelIndex + 1)"
                    )
                    status(
                        "Calibration",
                        microphone.microphoneCalibration?.sourceName
                            ?? "None"
                    )
                }
                Text(
                    "Normal DSP playback must be stopped for every sweep. The Lab revalidates routing, crossover/limiter protection and reference-clock requirements immediately before acquisition."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var protocolComposerCard: some View {
        GroupBox("Protocol Composer") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Queue measurement protocols")
                        .font(.headline)
                    Spacer()
                    Text("\(queuedProtocols.count) queued")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }

                Grid(
                    alignment: .leading,
                    horizontalSpacing: 14,
                    verticalSpacing: 10
                ) {
                    GridRow {
                        Text("Mode")
                        Picker(
                            "Mode",
                            selection: Binding(
                                get: { draft.mode.rawValue },
                                set: { value in
                                    guard let mode =
                                        SpeakerMeasurementLabMode(
                                            rawValue: value
                                        ) else { return }
                                    draft.applyModeDefaults(mode)
                                }
                            )
                        ) {
                            ForEach(
                                SpeakerMeasurementLabMode.allCases,
                                id: \.rawValue
                            ) { mode in
                                Text(modeTitle(mode))
                                    .tag(mode.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 280)
                    }

                    GridRow {
                        Text("Name")
                        TextField("Protocol name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    }

                    targetEditor

                    GridRow {
                        Text("Distance")
                        HStack {
                            TextField(
                                "Meters",
                                value: $draft.distanceMeters,
                                format: .number.precision(
                                    .fractionLength(2)
                                )
                            )
                            .frame(width: 90)
                            Text("m")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if draft.mode == .wholeSpeakerOffAxis {
                        GridRow {
                            Text("Angles")
                            HStack {
                                Text("H")
                                TextField(
                                    "H",
                                    value:
                                        $draft.horizontalAngleDegrees,
                                    format: .number.precision(
                                        .fractionLength(0)
                                    )
                                )
                                .frame(width: 70)
                                Text("°  V")
                                TextField(
                                    "V",
                                    value:
                                        $draft.verticalAngleDegrees,
                                    format: .number.precision(
                                        .fractionLength(0)
                                    )
                                )
                                .frame(width: 70)
                                Text("°")
                            }
                        }
                    }

                    GridRow {
                        Text("Repeats")
                        Stepper(
                            "\(draft.repeatCount)",
                            value: $draft.repeatCount,
                            in: SpeakerMeasurementLabRequest
                                .minimumRepeatCount...10
                        )
                    }

                    excitationEditor

                    if draft.mode == .subwooferNearField {
                        GridRow {
                            Text("Component")
                            HStack {
                                Picker(
                                    "Component",
                                    selection: Binding(
                                        get: {
                                            draft.nearFieldComponentKind
                                                .rawValue
                                        },
                                        set: { value in
                                            if let kind =
                                                SpeakerMeasurementLabNearFieldComponentKind(
                                                    rawValue: value
                                                ) {
                                                draft.nearFieldComponentKind =
                                                    kind
                                            }
                                        }
                                    )
                                ) {
                                    ForEach(
                                        SpeakerMeasurementLabNearFieldComponentKind
                                            .allCases,
                                        id: \.rawValue
                                    ) { kind in
                                        Text(componentTitle(kind))
                                            .tag(kind.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)
                                TextField(
                                    "Optional label",
                                    text:
                                        $draft.nearFieldComponentLabel
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Add Protocol") {
                        actionError = nil
                        do {
                            queuedProtocols.append(
                                contentsOf: try draft.makeProtocols()
                            )
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddDraft)

                    Button("Clear Queue", role: .destructive) {
                        queuedProtocols.removeAll()
                    }
                    .disabled(queuedProtocols.isEmpty)

                    Spacer()

                    if draft.mode == .coherentMainsSubTiming {
                        Label(
                            "Adds linked Main + Sub legs",
                            systemImage: "link"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if !queuedProtocols.isEmpty {
                    Divider()
                    VStack(spacing: 7) {
                        ForEach(queuedProtocols) { item in
                            HStack(spacing: 10) {
                                Image(
                                    systemName:
                                        modeIcon(item.request.mode)
                                )
                                VStack(
                                    alignment: .leading,
                                    spacing: 2
                                ) {
                                    Text(item.name)
                                        .font(.callout.bold())
                                    Text(protocolSummary(item))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(
                                    "\(item.request.repeatCount)×"
                                )
                                .font(.caption.monospacedDigit())
                                Button {
                                    queuedProtocols.removeAll {
                                        $0.id == item.id
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Divider()

                Toggle(
                    "Simultaneous shared-time electrical reference",
                    isOn: $sharedReferenceEnabled
                )
                .toggleStyle(.switch)

                if sharedReferenceEnabled {
                    HStack(spacing: 16) {
                        LabeledContent("Reference Input Channel") {
                            Stepper(
                                "\(referenceInputChannel)",
                                value: $referenceInputChannel,
                                in: 1...64
                            )
                        }
                        LabeledContent("Minimum Reference SNR") {
                            HStack {
                                Slider(
                                    value: $referenceMinimumSNRDB,
                                    in: 20...80,
                                    step: 1
                                )
                                .frame(width: 150)
                                Text(
                                    "\(referenceMinimumSNRDB, specifier: "%.0f") dB"
                                )
                                .monospacedDigit()
                            }
                        }
                    }
                    Text(
                        "The reference must be a different input channel on the same physical ADC as the microphone. Coherent Main/Sub protocols require this option."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button("Start New Lab Session") {
                    startNewSession()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    queuedProtocols.isEmpty
                        || lab.state == .measuring
                        || lab.state == .analyzing
                        || (queuedProtocols.contains {
                            $0.request.mode == .coherentMainsSubTiming
                        } && !sharedReferenceEnabled)
                )
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var targetEditor: some View {
        switch draft.mode {
        case .wholeSpeakerOnAxis, .wholeSpeakerOffAxis:
            GridRow {
                Text("Speaker")
                speakerPicker
            }
        case .subwooferNearField:
            GridRow {
                Text("Subwoofer")
                subwooferPicker
            }
        case .protectedDriverNearField:
            GridRow {
                Text("Protected Bus")
                Picker(
                    "Protected Bus",
                    selection: Binding(
                        get: { draft.protectedDriverBus.rawValue },
                        set: { value in
                            if let bus = SpeakerOutputBus(
                                rawValue: value
                            ) {
                                draft.protectedDriverBus = bus
                            }
                        }
                    )
                ) {
                    ForEach(
                        protectedDriverBuses,
                        id: \.rawValue
                    ) { bus in
                        Text(bus.displayName).tag(bus.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        case .coherentMainsSubTiming:
            GridRow {
                Text("Main / Sub")
                HStack {
                    speakerPicker
                    subwooferPicker
                }
            }
        }
    }

    private var speakerPicker: some View {
        Picker(
            "Speaker",
            selection: Binding(
                get: { draft.speakerRole.rawValue },
                set: { value in
                    if let role = OutputProgramRole(rawValue: value) {
                        draft.speakerRole = role
                    }
                }
            )
        ) {
            ForEach(speakerRoles, id: \.rawValue) { role in
                Text(role.displayName).tag(role.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 190)
    }

    private var subwooferPicker: some View {
        Picker(
            "Subwoofer",
            selection: $draft.subwooferIndex
        ) {
            ForEach(subwooferIndices, id: \.self) { index in
                Text("Sub \(index + 1)").tag(index)
            }
        }
        .labelsHidden()
        .frame(width: 120)
    }

    @ViewBuilder
    private var excitationEditor: some View {
        let forced =
            draft.mode == .protectedDriverNearField
            || draft.mode == .coherentMainsSubTiming
        GridRow {
            Text("Excitation")
            HStack {
                if !forced {
                    Toggle(
                        "Explicit",
                        isOn: $draft.usesExplicitExcitationLevel
                    )
                    .toggleStyle(.switch)
                } else {
                    Label(
                        "Explicit required",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                }
                if forced || draft.usesExplicitExcitationLevel {
                    Slider(
                        value: $draft.excitationLevelDBFS,
                        in: -48...(-12),
                        step: 1
                    )
                    .frame(width: 190)
                    Text(
                        "\(draft.excitationLevelDBFS, specifier: "%.0f") dBFS"
                    )
                    .monospacedDigit()
                } else {
                    Text("Use measurement default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sessionCard: some View {
        GroupBox("Lab Session") {
            if let session = lab.session {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 22) {
                        status(
                            "Session",
                            String(session.id.uuidString.prefix(8))
                        )
                        if let progress = lab.progress {
                            status(
                                "Captures",
                                "\(progress.completedCaptureCount) / \(progress.requiredCaptureCount)"
                            )
                            status(
                                "Protocols",
                                "\(progress.completedProtocolCount) / \(progress.requiredProtocolCount)"
                            )
                        }
                        status(
                            "Reference",
                            session.sharedClockReferenceConfiguration == nil
                                ? "Off" : "Configured"
                        )
                        status("State", lab.state.rawValue.capitalized)
                    }

                    if let progress = lab.progress {
                        ProgressView(value: progress.fractionComplete)
                    }

                    if let step = lab.activeOrNextStep {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(
                                lab.state == .measuring
                                    ? "Measuring \(step.labProtocol.name)"
                                    : "Next: \(step.labProtocol.name)"
                            )
                            .font(.callout.bold())
                            Text(step.instruction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if lab.progress?.complete == true {
                        Label(
                            "All queued Lab protocols are complete.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }

                    if lab.state == .measuring {
                        ProgressView(value: lab.activeMeasurementProgress) {
                            Text("Current Lab sweep")
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Measure Next Repeat") {
                            actionError = nil
                            do {
                                try lab.beginNextMeasurement()
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!lab.canBeginMeasurement)

                        if lab.state == .measuring
                            || lab.state == .analyzing {
                            Button("Cancel") {
                                lab.cancelMeasurement()
                            }
                        }
                    }

                    Divider()

                    ForEach(session.protocols) { item in
                        let captured = session.captures.filter {
                            $0.protocolID == item.id
                        }.count
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.callout.bold())
                                Text(protocolSummary(item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(
                                "\(captured) / \(item.request.repeatCount)"
                            )
                            .font(.caption.monospacedDigit())
                            if captured > 0
                                && lab.state != .measuring
                                && lab.state != .analyzing {
                                Button("Retry Latest") {
                                    actionError = nil
                                    do {
                                        try lab.retryLatestCapture(
                                            protocolID: item.id
                                        )
                                    } catch {
                                        actionError =
                                            error.localizedDescription
                                    }
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if let blocked =
                            lab.activeCapabilityPlan?.blockReasons.first {
                        Label(
                            blocked.message,
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(6)
            } else {
                Text(
                    "No active Lab session. Compose one above or resume a recent session."
                )
                .foregroundStyle(.secondary)
                .padding(6)
            }
        }
    }

    private var reportCard: some View {
        GroupBox("Analysis & Export") {
            if let report = currentReport {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 22) {
                        status(
                            "Protocols",
                            "\(report.protocolSummaries.count)"
                        )
                        status(
                            "Captures",
                            "\(report.captureSummaries.count)"
                        )
                        status(
                            "Analyses",
                            "\(report.analysisSummaries.filter(\.available).count) / \(report.analysisSummaries.count)"
                        )
                        status(
                            "Deploy",
                            report.canDeploy ? "Allowed" : "Never"
                        )
                    }

                    ForEach(
                        Array(report.analysisSummaries.enumerated()),
                        id: \.offset
                    ) { _, analysis in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(
                                    analysis.title,
                                    systemImage: analysis.available
                                        ? "checkmark.circle.fill"
                                        : "exclamationmark.circle"
                                )
                                .font(.callout.bold())
                                .foregroundStyle(
                                    analysis.available
                                        ? .green : .secondary
                                )
                                Spacer()
                                Text(
                                    analysis.available
                                        ? "AVAILABLE" : "UNAVAILABLE"
                                )
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            }
                            if !analysis.metrics.isEmpty {
                                HStack(spacing: 18) {
                                    ForEach(
                                        Array(
                                            analysis.metrics.enumerated()
                                        ),
                                        id: \.offset
                                    ) { _, metric in
                                        status(metric.name, metric.value)
                                    }
                                }
                            }
                            if let warning =
                                    analysis.warnings.first {
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(
                            .quaternary.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }

                    HStack(spacing: 10) {
                        Button("Export JSON") {
                            prepareExport(json: true)
                        }
                        Button("Export CSV") {
                            prepareExport(json: false)
                        }
                    }

                    Text(
                        "Compact exports intentionally exclude raw impulse arrays and full transfer grids. The persisted Lab session remains the detailed analysis archive."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(6)
            } else {
                Text(
                    "Analysis summaries appear after a valid Lab session exists."
                )
                .foregroundStyle(.secondary)
                .padding(6)
            }
        }
    }

    private var coherentAlignmentCard: some View {
        GroupBox("Coherent Sub Alignment") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PR108 · Crossover timing & polarity")
                            .font(.headline)
                        Text(
                            "Use a completed shared-reference Main/Sub Lab session to review a bounded timing/polarity proposal. Apply is explicit, provisional, and accepted only after a new measured session passes."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(
                        alignment.state.rawValue
                            .replacingOccurrences(
                                of: "([a-z])([A-Z])",
                                with: "$1 $2",
                                options: .regularExpression
                            )
                            .uppercased()
                    )
                    .font(.caption.bold())
                    .tracking(0.8)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                }

                HStack(spacing: 10) {
                    Button("Generate Alignment Proposal") {
                        actionError = nil
                        do {
                            if alignment.state == .rolledBack {
                                alignment.resetAfterRollback()
                            }
                            guard let session = lab.session else {
                                throw CoherentSubwooferAlignmentGuidedError
                                    .coherentEvidenceRequired
                            }
                            try alignment.prepareReview(
                                baselineSession: session
                            )
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canGenerateAlignmentProposal)

                    if alignment.canRollback {
                        Button("Rollback", role: .destructive) {
                            actionError = nil
                            do {
                                try alignment.rollback()
                            } catch {
                                actionError = error.localizedDescription
                            }
                        }
                    }

                    if alignment.state == .rolledBack {
                        Button("Reset Workflow") {
                            alignment.resetAfterRollback()
                            actionError = nil
                        }
                    }
                }

                if let mode = alignment.mode {
                    Divider()

                    HStack(spacing: 22) {
                        status("Mode", mode.displayName)
                        status(
                            "Subs",
                            "\(alignment.subwooferCount)"
                        )
                        status(
                            "Predicted Δ",
                            alignment.predictedImprovementDB.map {
                                String(
                                    format: "%+.2f dB",
                                    $0
                                )
                            } ?? "—"
                        )
                        status(
                            "Common Main Delay",
                            alignment
                                .speakerCommonDelayMilliseconds
                                .map {
                                    String(
                                        format: "%.2f ms",
                                        $0
                                    )
                                } ?? "—"
                        )
                    }

                    alignmentCandidateDetails

                    if alignment.state == .reviewReady {
                        Label(
                            "Preview only. The raw candidate cannot deploy; Apply requires this exact commissioned proposal plus an explicit user action.",
                            systemImage: "hand.raised.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button("Approve & Apply Provisionally") {
                            actionError = nil
                            do {
                                try alignment.approveAndApply(
                                    userInitiated: true
                                )
                            } catch {
                                actionError =
                                    error.localizedDescription
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!alignment.canApproveAndApply)
                    }

                    if alignment.state
                        == .appliedPendingVerification {
                        Divider()

                        Label(
                            "Provisional timing/polarity is live in the Playback System profile. Do not accept by ear alone: capture a fresh coherent verification session.",
                            systemImage:
                                "exclamationmark.shield.fill"
                        )
                        .font(.callout.bold())
                        .foregroundStyle(.orange)

                        HStack(spacing: 10) {
                            Button("Start Fresh Verification Session") {
                                startFreshAlignmentVerificationSession()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                !canStartAlignmentVerificationSession
                            )

                            Button("Verify Current Lab Session") {
                                actionError = nil
                                do {
                                    guard let session = lab.session else {
                                        throw CoherentSubwooferAlignmentGuidedError
                                            .coherentEvidenceRequired
                                    }
                                    try alignment.verify(
                                        freshSession: session
                                    )
                                } catch {
                                    actionError =
                                        error.localizedDescription
                                }
                            }
                            .disabled(
                                !canVerifyCurrentAlignmentSession
                            )
                        }

                        Text(
                            "The verification session clones the approved coherent geometry, repeat count, excitation level and shared electrical-reference configuration, but receives new session and pair identities."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if alignment.state == .measuredAccepted {
                        Divider()
                        Label(
                            "Fresh measured verification accepted. PR108 timing/polarity provenance is persisted as VERIFIED.",
                            systemImage: "checkmark.shield.fill"
                        )
                        .font(.callout.bold())
                        .foregroundStyle(.green)

                        if let improvement =
                                alignmentMeasuredImprovementDB {
                            Text(
                                "Measured aggregate crossover-coherence improvement: \(String(format: "%+.2f dB", improvement))."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if alignment.state == .rolledBack {
                        Divider()
                        Label(
                            "The provisional PR108 alignment was rolled back to the exact pre-Apply Playback System snapshot.",
                            systemImage:
                                "arrow.uturn.backward.circle.fill"
                        )
                        .font(.callout.bold())
                        .foregroundStyle(.secondary)
                    }
                } else if let persisted = persistedAlignmentStatus {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            persisted.verified
                                ? "Persisted PR108 alignment · VERIFIED"
                                : "Persisted PR108 alignment · PROVISIONAL",
                            systemImage: persisted.verified
                                ? "checkmark.shield.fill"
                                : "clock.badge.checkmark"
                        )
                        .font(.callout.bold())
                        .foregroundStyle(
                            persisted.verified ? .green : .orange
                        )

                        Text(persisted.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(
                            "This deployment provenance survived profile reload. A new alignment proposal is blocked while it owns the live timing/polarity calibration. The guided controller does not reconstruct an old Apply receipt after relaunch."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(
                        "Complete a coherent Main/Sub Lab session with simultaneous shared-time electrical reference, then generate a proposal here. One Sub uses the single-Sub path; two or more Subs are solved and applied atomically."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var alignmentCandidateDetails: some View {
        if let candidate = alignment.singleCandidate {
            HStack(spacing: 22) {
                status(
                    "Relative Adjustment",
                    String(
                        format: "%+.2f ms",
                        candidate
                            .signedRelativeDelayAdjustmentMilliseconds
                    )
                )
                status(
                    "Physical Sub Delay",
                    String(
                        format: "+%.2f ms",
                        candidate
                            .subwooferDelayAdjustmentMilliseconds
                    )
                )
                status(
                    "Sub Polarity",
                    candidate.toggleSubwooferPolarity
                        ? "Toggle" : "Keep"
                )
                status(
                    "Predicted",
                    String(
                        format: "%.2f → %.2f dB",
                        candidate.predictedCoherenceBeforeDB,
                        candidate.predictedCoherenceAfterDB
                    )
                )
            }
        } else if let candidate = alignment.multiCandidate {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(
                    candidate.subwoofers,
                    id: \.subwooferIndex
                ) { sub in
                    HStack(spacing: 18) {
                        Text("Sub \(sub.subwooferIndex + 1)")
                            .font(.callout.bold())
                            .frame(width: 70, alignment: .leading)
                        status(
                            "Measured Optimum",
                            String(
                                format: "%+.2f ms",
                                sub
                                    .signedRelativeDelayAdjustmentMilliseconds
                            )
                        )
                        status(
                            "Added Sub Delay",
                            String(
                                format: "+%.2f ms",
                                sub
                                    .subwooferDelayAdjustmentMilliseconds
                            )
                        )
                        status(
                            "Polarity",
                            sub.toggleSubwooferPolarity
                                ? "Toggle" : "Keep"
                        )
                        status(
                            "Predicted Δ",
                            String(
                                format: "%+.2f dB",
                                sub.predictedImprovementDB
                            )
                        )
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var persistedAlignmentStatus:
        (verified: Bool, detail: String)? {
        guard let output = currentProfile else { return nil }

        if let record = output.coherentMultiSubwooferAlignment {
            return (
                verified: record.verified,
                detail:
                    "Coordinated \(record.subwoofers.count)-Sub provenance · crossover \(String(format: "%.0f Hz", record.crossoverFrequencyHz)) · applied \(record.appliedAt.formatted(date: .abbreviated, time: .shortened))."
            )
        }

        if let record = output.coherentSubwooferAlignment {
            return (
                verified: record.verified,
                detail:
                    "Sub \(record.subwooferIndex + 1) provenance · crossover \(String(format: "%.0f Hz", record.crossoverFrequencyHz)) · applied \(record.appliedAt.formatted(date: .abbreviated, time: .shortened))."
            )
        }

        return nil
    }

    private var canGenerateAlignmentProposal: Bool {
        guard lab.progress?.complete == true,
              currentSessionHasCoherentPairs,
              engine.lifecycleState == .idle,
              persistedAlignmentStatus == nil else {
            return false
        }
        switch alignment.state {
        case .idle, .reviewReady, .failed, .rolledBack:
            return true
        case .appliedPendingVerification,
             .measuredAccepted,
             .measuredRejected:
            return false
        }
    }

    private var canStartAlignmentVerificationSession: Bool {
        alignment.state == .appliedPendingVerification
            && engine.lifecycleState == .idle
            && lab.state != .measuring
            && lab.state != .analyzing
            && lab.progress?.complete == true
            && lab.session?.id == alignment.baselineSessionID
    }

    private var canVerifyCurrentAlignmentSession: Bool {
        alignment.canVerify
            && lab.progress?.complete == true
            && currentSessionHasCoherentPairs
            && lab.session?.id != alignment.baselineSessionID
    }

    private var currentSessionHasCoherentPairs: Bool {
        lab.session?.protocols.contains {
            $0.request.mode == .coherentMainsSubTiming
                && $0.coherentPairID != nil
                && $0.coherentLeg != nil
        } == true
    }

    private var alignmentMeasuredImprovementDB: Double? {
        alignment.singleVerificationReport?
            .measuredImprovementDB
            ?? alignment.multiVerificationReport?
                .measuredImprovementDB
    }

    private func startFreshAlignmentVerificationSession() {
        actionError = nil
        do {
            guard let baseline = lab.session,
                  baseline.id == alignment.baselineSessionID,
                  let reference =
                    baseline.sharedClockReferenceConfiguration else {
                throw CoherentSubwooferAlignmentGuidedError
                    .coherentEvidenceRequired
            }

            let coherent = baseline.protocols.filter {
                $0.request.mode == .coherentMainsSubTiming
            }
            let originalPairIDs = Set(
                coherent.compactMap(\.coherentPairID)
            ).sorted {
                $0.uuidString < $1.uuidString
            }
            guard !originalPairIDs.isEmpty else {
                throw CoherentSubwooferAlignmentGuidedError
                    .coherentEvidenceRequired
            }

            var fresh: [SpeakerMeasurementLabProtocol] = []
            for originalPairID in originalPairIDs {
                let pair = coherent.filter {
                    $0.coherentPairID == originalPairID
                }
                guard pair.count == 2 else {
                    throw CoherentSubwooferAlignmentGuidedError
                        .coherentEvidenceShapeMismatch
                }
                let freshPairID = UUID()
                for item in pair.sorted(by: {
                    ($0.coherentLeg == .main ? 0 : 1)
                        < ($1.coherentLeg == .main ? 0 : 1)
                }) {
                    fresh.append(
                        SpeakerMeasurementLabProtocol(
                            name: "Verify · \(item.name)",
                            request: item.request,
                            excitationLevelDBFS:
                                item.excitationLevelDBFS,
                            nearFieldComponent:
                                item.nearFieldComponent,
                            coherentPairID: freshPairID,
                            coherentLeg: item.coherentLeg
                        )
                    )
                }
            }

            try lab.startNewSession(
                protocols: fresh,
                sharedClockReferenceConfiguration: reference
            )
            refreshRecentSessions()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var historyCard: some View {
        GroupBox("Recent Lab Sessions") {
            VStack(alignment: .leading, spacing: 8) {
                if recentSessions.isEmpty {
                    Text("No saved Lab sessions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentSessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    "\(session.protocols.count) protocols · \(session.captures.count) captures"
                                )
                                .font(.callout.bold())
                                Text(
                                    "\(session.modifiedAt.formatted(date: .abbreviated, time: .shortened)) · \(String(session.id.uuidString.prefix(8)))"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Resume") {
                                actionError = nil
                                do {
                                    try lab.resumeSession(session.id)
                                } catch {
                                    actionError =
                                        error.localizedDescription
                                }
                            }
                            .disabled(
                                lab.state == .measuring
                                    || lab.state == .analyzing
                            )
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(6)
        }
    }

    private var currentReport: SpeakerMeasurementLabCompactReport? {
        guard let session = lab.session else { return nil }
        return try? reportBuilder.build(
            session: session,
            generatedAt: session.modifiedAt
        )
    }

    private var currentProfile: OutputDeviceProfileConfiguration? {
        profiles.selectedSystemProfile?.state.outputDeviceProfile
    }

    private var speakerRoles: [OutputProgramRole] {
        currentProfile?.programLayout.roles.filter {
            $0 != .lowFrequencyEffects
        } ?? []
    }

    private var subwooferIndices: [UInt32] {
        currentProfile?.subwooferAssignments
            .map(\.index)
            .sorted() ?? []
    }

    private var protectedDriverBuses: [SpeakerOutputBus] {
        SpeakerOutputBus.allCases.filter {
            SpeakerMeasurementLabProtectedDriverRoutePlanner
                .isProtectedSplitBus($0)
        }
    }

    private var canAddDraft: Bool {
        switch draft.mode {
        case .wholeSpeakerOnAxis, .wholeSpeakerOffAxis:
            return speakerRoles.contains {
                $0.rawValue == draft.speakerRole.rawValue
            }
        case .subwooferNearField:
            return subwooferIndices.contains(draft.subwooferIndex)
        case .protectedDriverNearField:
            return protectedDriverBuses.contains {
                $0.rawValue == draft.protectedDriverBus.rawValue
            }
        case .coherentMainsSubTiming:
            return speakerRoles.contains {
                $0.rawValue == draft.speakerRole.rawValue
            } && subwooferIndices.contains(draft.subwooferIndex)
        }
    }

    private func startNewSession() {
        actionError = nil
        do {
            try lab.startNewSession(
                protocols: queuedProtocols,
                sharedClockReferenceConfiguration:
                    try makeReferenceConfiguration()
            )
            queuedProtocols.removeAll()
            refreshRecentSessions()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func makeReferenceConfiguration() throws
        -> SpeakerMeasurementLabSharedClockReferenceConfiguration? {
        guard sharedReferenceEnabled else { return nil }
        guard let input = microphone.selectedInputDevice else {
            throw SpeakerMeasurementLabControllerError
                .measurementInputRequired
        }
        guard let outputUID =
                currentProfile?.referenceDeviceUID
                ?? engine.routeConfiguration.selectedOutputUID
                ?? engine.selectedOutputDevice?.uid else {
            throw SpeakerMeasurementLabControllerError.outputRequired
        }
        return SpeakerMeasurementLabSharedClockReferenceConfiguration(
            inputDeviceUID: input.uid,
            inputChannelIndex: max(0, referenceInputChannel - 1),
            outputReferenceDeviceUID: outputUID,
            minimumSNRDB: referenceMinimumSNRDB
        )
    }

    private func refreshRecentSessions() {
        recentSessions = (try? store.listRecentSessions(limit: 10)) ?? []
    }

    private func prepareExport(json: Bool) {
        actionError = nil
        guard let report = currentReport else { return }
        do {
            let data = json
                ? try exporter.jsonData(report)
                : try exporter.csvData(report)
            exportDocument =
                SpeakerMeasurementLabExportDocument(data: data)
            exportContentType = json
                ? .json
                : (UTType(filenameExtension: "csv") ?? .plainText)
            exportFilename =
                "notch-sixty-lab-\(String(report.sessionID.uuidString.prefix(8)))"
            showingExporter = true
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func status(
        _ label: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.bold())
        }
    }

    private func modeTitle(
        _ mode: SpeakerMeasurementLabMode
    ) -> String {
        switch mode {
        case .wholeSpeakerOnAxis: return "Whole Speaker · On-Axis"
        case .wholeSpeakerOffAxis: return "Whole Speaker · Off-Axis"
        case .subwooferNearField: return "Subwoofer · Near-Field"
        case .protectedDriverNearField:
            return "Protected Driver · Near-Field"
        case .coherentMainsSubTiming:
            return "Coherent Main / Sub Timing"
        }
    }

    private func modeIcon(
        _ mode: SpeakerMeasurementLabMode
    ) -> String {
        switch mode {
        case .wholeSpeakerOnAxis: return "scope"
        case .wholeSpeakerOffAxis: return "angle"
        case .subwooferNearField: return "waveform"
        case .protectedDriverNearField: return "lock.shield"
        case .coherentMainsSubTiming: return "link"
        }
    }

    private func componentTitle(
        _ kind: SpeakerMeasurementLabNearFieldComponentKind
    ) -> String {
        switch kind {
        case .radiator: return "Radiator"
        case .port: return "Port"
        case .passiveRadiator: return "Passive Radiator"
        case .other: return "Other"
        }
    }

    private func protocolSummary(
        _ item: SpeakerMeasurementLabProtocol
    ) -> String {
        let geometry = item.request.geometry
        var parts = [
            modeTitle(item.request.mode),
            "\(geometry.distanceMeters.formatted(.number.precision(.fractionLength(2)))) m",
        ]
        if item.request.mode == .wholeSpeakerOffAxis {
            parts.append(
                "H \(geometry.horizontalAngleDegrees.formatted(.number.precision(.fractionLength(0))))° / V \(geometry.verticalAngleDegrees.formatted(.number.precision(.fractionLength(0))))°"
            )
        }
        if let level = item.excitationLevelDBFS {
            parts.append(
                "\(level.formatted(.number.precision(.fractionLength(0)))) dBFS"
            )
        }
        if let bus = item.protectedDriverBus {
            parts.append(bus.displayName)
        }
        if let leg = item.coherentLeg {
            parts.append(leg == .main ? "Main leg" : "Sub leg")
        }
        return parts.joined(separator: " · ")
    }
}
