import SwiftUI
import UniformTypeIdentifiers

private struct HardwareAcceptanceExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [
            .json,
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
    }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ProductionHardwareAcceptanceWorkspace: View {
    var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    @ObservedObject var acceptance: HardwareAcceptanceController

    @State private var showingCampaignForm = false

    private let reportBuilder = HardwareAcceptanceReportBuilder()
    private let reportExporter = HardwareAcceptanceReportExporter()
    @State private var exportDocument: HardwareAcceptanceExportDocument?
    @State private var exportContentType: UTType = .json
    @State private var exportFilename = "notch-sixty-hardware-acceptance"
    @State private var showingExporter = false

    @State private var commitSHA = ""
    @State private var branchName =
        "feature/pr112a-remote-hardware-acceptance-infrastructure"
    @State private var splitDriverIncluded = false
    @State private var splitDriverExclusionReason =
        "No independently amplified split-driver topology in this campaign."
    @State private var coherentSubIncluded = false
    @State private var coherentSubExclusionReason =
        "No independently addressable same-clock Main/Sub test topology in this campaign."
    @State private var liveANCIncluded = false
    @State private var liveANCExclusionReason =
        "Live speaker-connected feed-forward ANC is disabled in this release scope."

    @State private var selectedGate:
        HardwareAcceptanceGateID = .h01DeviceLifecycleRecovery
    @State private var authority:
        HardwareAcceptanceEvidenceAuthority = .remoteSoftware
    @State private var outcome:
        HardwareAcceptanceObservationOutcome = .blocked
    @State private var reviewer = ""
    @State private var notes = ""
    @State private var artifactIdentifier = ""
    @State private var artifactLabel = "Acceptance evidence"
    @State private var splitDriverCovered = false

    @State private var macModel = ""
    @State private var macOSVersion =
        ProcessInfo.processInfo.operatingSystemVersionString
    @State private var sampleRate = 48_000.0
    @State private var ioBufferFrames = 256
    @State private var outputDeviceName = ""
    @State private var outputDeviceUID = ""
    @State private var inputDeviceName = ""
    @State private var inputDeviceUID = ""
    @State private var microphoneIdentifier = ""
    @State private var speakerTopology =
        "Stereo speakers + line-level subwoofer"
    @State private var referencePathDescription = ""

    @State private var physicalAttestation = false
    @State private var independentReviewAttestation = false
    @State private var actionMessage: String?
    @State private var preflightResult:
        HardwareAcceptancePreflightResult?
    @State private var protectedDriverWiringPreflightConfirmed = false
    @State private var sameADCPreflightConfirmed = false
    @State private var commonClockPreflightConfirmed = false
    @State private var safeLineReferencePreflightConfirmed = false

    private var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
    }

    private var selectedSystemID: UUID? {
        profiles.selectedSystemProfileID
    }

    private var selectedGateDefinition:
        HardwareAcceptanceGateDefinition {
        HardwareAcceptanceCatalog.definition(selectedGate)
    }

    private var selectedGateIncluded: Bool {
        acceptance.isGateIncluded(selectedGate)
    }

    var body: some View {
        ProductionPageContainer {
            VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
                header
                authorityBoundaryCard

                if let campaign = acceptance.campaign {
                    campaignSummary(campaign)
                    gateMatrix
                    acceptancePacketCard(campaign)
                    preflightCard
                    evidenceEntry
                } else {
                    noCampaignCard
                }

                if showingCampaignForm
                    || acceptance.campaign == nil {
                    campaignCreationCard
                }

                if let message = actionMessage {
                    messageCard(message)
                }
                if let error = acceptance.errorDescription {
                    messageCard(error, isError: true)
                }
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                actionMessage = error.localizedDescription
            }
        }
        .task {
            acceptance.prepareForUse()
            populatePhysicalDefaults()
            if acceptance.campaign == nil {
                showingCampaignForm = true
            }
        }
        .onChange(of: selectedGate) { _, _ in
            resetObservationAttestations()
            resetPreflight()
        }
        .onChange(of: profiles.selectedSystemProfileID) { _, _ in
            resetPreflight()
        }
        .onChange(of: engine.lifecycleState) { _, _ in
            preflightResult = nil
        }
        .onChange(of: authority) { _, newValue in
            if newValue == .remoteSoftware {
                physicalAttestation = false
                independentReviewAttestation = false
            } else if newValue == .physicalHardware {
                independentReviewAttestation = false
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.l.pt) {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                Text(
                    "Guided H01–H08 evidence collection for the later physical PR112 campaign."
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("EVIDENCE ONLY")
                .font(DesignType.caption.font.bold())
                .tracking(1.1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSpacing.m.pt)
                .padding(.vertical, DesignSpacing.s.pt)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private func acceptancePacketCard(
        _ campaign: HardwareAcceptanceCampaign
    ) -> some View {
        let evaluation = acceptance.evaluation
        return GroupBox("Acceptance Packet & Physical Runbook") {
            VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                Text(
                    "Export the immutable campaign identity, H01-H08 status matrix, unresolved gates, evidence log, artifact manifest, and safety-bounded physical runbook. Export never changes acceptance state."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)

                HStack(spacing: DesignSpacing.m.pt) {
                    Button("Export JSON Packet") {
                        prepareAcceptanceExport(
                            campaign: campaign,
                            json: true
                        )
                    }
                    .buttonStyle(.glassProminent)

                    Button("Export Markdown Runbook") {
                        prepareAcceptanceExport(
                            campaign: campaign,
                            json: false
                        )
                    }
                    .buttonStyle(.glass)
                }

                HStack(spacing: DesignSpacing.l.pt) {
                    summaryMetric(
                        "Unresolved gates",
                        "\(evaluation?.unresolvedGateIDs.count ?? HardwareAcceptanceGateID.allCases.count)"
                    )
                    summaryMetric(
                        "Release acceptance",
                        "BLOCKED"
                    )
                    summaryMetric(
                        "Merge to main",
                        "BLOCKED"
                    )
                }

                Text(
                    "Hard boundary: packet export cannot create physical evidence, release acceptance, ANC authorization, DSP authority, or merge permission."
                )
                .font(DesignType.caption.font.bold())
                .foregroundStyle(.secondary)
            }
            .padding(DesignSpacing.s.pt)
        }
    }

    private var authorityBoundaryCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Label(
                "Remote CI cannot pass physical gates",
                systemImage: "lock.shield.fill"
            )
            .font(DesignType.sectionTitle.font)
            Text(
                "Software tests can validate this workflow, but H01–H08 require the evidence authority shown on each gate. A remote “pass” remains insufficient authority. No control here changes DSP, routing, speaker output, or PR111 commissioning state."
            )
            .font(DesignType.label.font)
            .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private func campaignSummary(
        _ campaign: HardwareAcceptanceCampaign
    ) -> some View {
        let evaluation = acceptance.evaluation
        return VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Current campaign")
                        .font(DesignType.sectionTitle.font)
                    Text(campaign.identity.id.uuidString)
                        .font(DesignType.caption.font.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(
                    evaluation?.physicalAcceptanceComplete == true
                        ? "PHYSICALLY ACCEPTED"
                        : "PHYSICAL ACCEPTANCE INCOMPLETE"
                )
                .font(DesignType.caption.font.bold())
                .tracking(0.7)
                .padding(.horizontal, DesignSpacing.m.pt)
                .padding(.vertical, DesignSpacing.s.pt)
                .background(
                    .secondary.opacity(0.10),
                    in: Capsule()
                )
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 220), spacing: DesignSpacing.m.pt)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                summaryMetric(
                    "Commit",
                    campaign.identity.commitSHA
                )
                summaryMetric(
                    "Branch",
                    campaign.identity.branch
                )
                summaryMetric(
                    "App",
                    "\(campaign.identity.appVersion) (\(campaign.identity.appBuild))"
                )
                summaryMetric(
                    "Playback System",
                    campaign.identity.playbackSystemID.uuidString
                )
                summaryMetric(
                    "Unresolved gates",
                    "\(evaluation?.unresolvedGateIDs.count ?? HardwareAcceptanceGateID.allCases.count)"
                )
                summaryMetric(
                    "Live feed-forward ANC",
                    evaluation?.liveFeedForwardANCAuthorized == true
                        ? "AUTHORIZED BY PHYSICAL REVIEW"
                        : "NOT AUTHORIZED"
                )
            }

            HStack(spacing: DesignSpacing.m.pt) {
                Button("Reload Latest Campaign") {
                    acceptance.prepareForUse()
                    actionMessage = "Reloaded the newest append-only campaign."
                }
                .buttonStyle(.glass)

                Button("Start New Campaign") {
                    showingCampaignForm = true
                    actionMessage =
                        "Existing evidence remains preserved. A new campaign receives a new immutable identity."
                }
                .buttonStyle(.glass)
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var gateMatrix: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Acceptance gates")
                .font(DesignType.sectionTitle.font)
            Text(
                "Select a gate to prepare a new append-only observation. Conditional exclusions are campaign-scope decisions, not synthetic passes."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)

            ForEach(HardwareAcceptanceCatalog.gates, id: \.id) {
                definition in
                gateRow(definition)
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private func gateRow(
        _ definition: HardwareAcceptanceGateDefinition
    ) -> some View {
        let status = acceptance.status(for: definition.id)
        let included = acceptance.isGateIncluded(definition.id)
        return Button {
            selectedGate = definition.id
        } label: {
            HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                Text(definition.id.rawValue)
                    .font(DesignType.caption.font.bold().monospaced())
                    .frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    HStack(spacing: DesignSpacing.s.pt) {
                        Text(definition.title)
                            .font(DesignType.label.font.bold())
                        if !included {
                            Text("EXCLUDED")
                                .font(DesignType.caption.font.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(definition.evidenceSummary)
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    Text(
                        "Minimum authority: \(authorityName(definition.minimumAuthority))"
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusName(status))
                    .font(DesignType.caption.font.bold())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 190, alignment: .trailing)
            }
            .padding(DesignSpacing.m.pt)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedGate == definition.id
                    ? Color.accentColor.opacity(0.10)
                    : Color.secondary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: DesignRadius.small.pt)
            )
        }
        .buttonStyle(.plain)
    }

    private var preflightCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Physical test preflight")
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "Read-only readiness check for \(selectedGate.rawValue). It does not start audio, apply DSP, or create acceptance evidence."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let preflightResult {
                    Text(
                        preflightResult.readyToBeginPhysicalTest
                            ? "READY TO BEGIN"
                            : "BLOCKED"
                    )
                    .font(DesignType.caption.font.bold())
                    .tracking(0.7)
                    .padding(.horizontal, DesignSpacing.m.pt)
                    .padding(.vertical, DesignSpacing.s.pt)
                    .background(
                        .secondary.opacity(0.10),
                        in: Capsule()
                    )
                }
            }

            if selectedGate == .h05AdvancedMeasurementLab,
               acceptance.supplementalCapabilityIsIncluded(
                .protectedSplitDriverMeasurement
               ) {
                Toggle(
                    "I verified the independently amplified Low/Mid/High wiring, mandatory crossover, and limiter topology before exposed-driver testing",
                    isOn: $protectedDriverWiringPreflightConfirmed
                )
                .font(DesignType.caption.font)
            }

            if selectedGate == .h07CoherentMainSubAlignment {
                Toggle(
                    "Microphone and safe electrical reference use separate channels of the same physical ADC",
                    isOn: $sameADCPreflightConfirmed
                )
                .font(DesignType.caption.font)
                Toggle(
                    "Main and independently routed Sub share the required output clock domain",
                    isOn: $commonClockPreflightConfirmed
                )
                .font(DesignType.caption.font)
                Toggle(
                    "Electrical reference is safe line-level — never powered speaker/amplifier output",
                    isOn: $safeLineReferencePreflightConfirmed
                )
                .font(DesignType.caption.font)
            }

            Button("Run Read-Only Preflight") {
                runPreflight()
            }
            .buttonStyle(.glass)
            .disabled(acceptance.campaign == nil)

            if let result = preflightResult {
                if result.blockers.isEmpty {
                    Label(
                        "Software prerequisites are consistent enough to begin the recorded physical procedure. This is NOT a gate pass.",
                        systemImage: "checkmark.shield"
                    )
                    .font(DesignType.caption.font.bold())
                } else {
                    ForEach(result.blockers) { blocker in
                        Label(
                            blocker.message,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(DesignType.caption.font)
                    }
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                if let draftID = result.commissioningDraftID {
                    Text(
                        "PR111 rollback-bound draft: \(draftID.uuidString)"
                    )
                    .font(DesignType.caption.font.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                Text(
                    "Hard boundary: physicalAcceptanceEstablished = false · canApplyDSP = false · canDeploy = false · mayMergeIntoMain = false"
                )
                .font(DesignType.caption.font.bold())
                .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var evidenceEntry: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                Text(
                    "\(selectedGate.rawValue) · \(selectedGateDefinition.title)"
                )
                .font(DesignType.sectionTitle.font)
                Spacer()
                Text(
                    selectedGateIncluded
                        ? "IN CAMPAIGN SCOPE"
                        : "EXCLUDED FROM SCOPE"
                )
                .font(DesignType.caption.font.bold())
                .foregroundStyle(.secondary)
            }

            if !selectedGateIncluded {
                Text(
                    "This gate was explicitly excluded when the campaign was created. Evidence cannot be appended to it. Start a new campaign if release scope changes."
                )
                .font(DesignType.label.font)
                .foregroundStyle(.secondary)
            } else {
                evidenceAuthorityControls
                Divider()
                physicalEnvironmentFields

                if selectedGate == .h05AdvancedMeasurementLab,
                   acceptance.supplementalCapabilityIsIncluded(
                    .protectedSplitDriverMeasurement
                   ) {
                    Toggle(
                        "This H05 observation also covered protected independently routed Low/Mid/High driver testing",
                        isOn: $splitDriverCovered
                    )
                    .font(DesignType.label.font)
                }

                Divider()
                evidenceNotesAndArtifacts
                attestationControls

                Button("Append Evidence Observation") {
                    recordObservation()
                }
                .buttonStyle(.glassProminent)
                .disabled(!canRecordObservation)

                Text(
                    "Appending is irreversible in this campaign. A later observation may supersede the gate status, but prior evidence remains in history."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var evidenceAuthorityControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Observation")
                .font(DesignType.label.font.bold())
            HStack(spacing: DesignSpacing.l.pt) {
                Picker("Authority", selection: $authority) {
                    ForEach(
                        HardwareAcceptanceEvidenceAuthority.allCases,
                        id: \.rawValue
                    ) { value in
                        Text(authorityName(value)).tag(value)
                    }
                }
                .frame(maxWidth: 290)

                Picker("Outcome", selection: $outcome) {
                    ForEach(
                        HardwareAcceptanceObservationOutcome.allCases,
                        id: \.rawValue
                    ) { value in
                        Text(outcomeName(value)).tag(value)
                    }
                }
                .frame(maxWidth: 200)
            }

            if authority == .remoteSoftware {
                Label(
                    "Remote software evidence cannot satisfy this physical gate.",
                    systemImage: "info.circle"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var physicalEnvironmentFields: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Physical environment snapshot")
                .font(DesignType.label.font.bold())

            HStack(spacing: DesignSpacing.m.pt) {
                TextField("Mac model", text: $macModel)
                TextField("macOS", text: $macOSVersion)
            }
            HStack(spacing: DesignSpacing.m.pt) {
                TextField(
                    "Sample rate",
                    value: $sampleRate,
                    format: .number
                )
                TextField(
                    "I/O buffer frames",
                    value: $ioBufferFrames,
                    format: .number
                )
            }
            HStack(spacing: DesignSpacing.m.pt) {
                TextField(
                    "Output device",
                    text: $outputDeviceName
                )
                TextField(
                    "Output UID",
                    text: $outputDeviceUID
                )
            }
            HStack(spacing: DesignSpacing.m.pt) {
                TextField(
                    "Input device (optional)",
                    text: $inputDeviceName
                )
                TextField(
                    "Input UID (optional)",
                    text: $inputDeviceUID
                )
            }
            TextField(
                "Measurement microphone / instrument (optional)",
                text: $microphoneIdentifier
            )
            TextField(
                "Speaker / Sub topology",
                text: $speakerTopology
            )
            TextField(
                "Electrical reference path (optional)",
                text: $referencePathDescription
            )
        }
        .textFieldStyle(.roundedBorder)
    }

    private var evidenceNotesAndArtifacts: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Reviewer & evidence")
                .font(DesignType.label.font.bold())
            TextField("Reviewer", text: $reviewer)
                .textFieldStyle(.roundedBorder)
            TextField(
                "What was physically tested and observed?",
                text: $notes,
                axis: .vertical
            )
            .lineLimit(3...7)
            .textFieldStyle(.roundedBorder)
            HStack(spacing: DesignSpacing.m.pt) {
                TextField(
                    "Artifact label",
                    text: $artifactLabel
                )
                TextField(
                    "Capture / report / build identifier (optional)",
                    text: $artifactIdentifier
                )
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var attestationControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            if authority >= .physicalHardware {
                Toggle(
                    "I confirm this observation was performed on the physical hardware recorded above",
                    isOn: $physicalAttestation
                )
            }
            if authority >= .independentPhysicalReview {
                Toggle(
                    "I confirm the named reviewer independently reviewed the physical result",
                    isOn: $independentReviewAttestation
                )
            }
        }
        .font(DesignType.label.font)
    }

    private var noCampaignCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text("No hardware acceptance campaign")
                .font(DesignType.sectionTitle.font)
            Text(
                "Create a campaign with an exact commit/build, Playback System, and explicit capability scope before recording evidence."
            )
            .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var campaignCreationCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                Text("New acceptance campaign")
                    .font(DesignType.sectionTitle.font)
                Spacer()
                if acceptance.campaign != nil {
                    Button("Cancel") {
                        showingCampaignForm = false
                    }
                    .buttonStyle(.glass)
                }
            }

            Text(
                "Campaign identity and scope are immutable after creation. Existing campaigns are never overwritten."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)

            TextField("Exact commit SHA", text: $commitSHA)
                .textFieldStyle(.roundedBorder)
            TextField("Branch / checkpoint", text: $branchName)
                .textFieldStyle(.roundedBorder)

            LabeledContent("App build") {
                Text("\(appVersion) (\(appBuild))")
                    .monospacedDigit()
            }
            LabeledContent("Playback System") {
                Text(
                    profiles.selectedSystemProfileName
                )
            }

            scopeToggle(
                "Protected split-driver measurement",
                included: $splitDriverIncluded,
                exclusionReason: $splitDriverExclusionReason,
                detail:
                    "Supplemental H05 Low/Mid/High testing. Requires independently amplified/routed drivers, mandatory crossover and limiter."
            )
            scopeToggle(
                "Coherent independently routed Sub alignment",
                included: $coherentSubIncluded,
                exclusionReason: $coherentSubExclusionReason,
                detail:
                    "H07 requires mic + safe electrical reference on the same ADC and the required output-clock topology."
            )
            scopeToggle(
                "Live speaker-connected feed-forward ANC",
                included: $liveANCIncluded,
                exclusionReason: $liveANCExclusionReason,
                detail:
                    "H08 remains unauthorized unless deliberately included and independently physically reviewed."
            )

            Button("Create Immutable Campaign") {
                createCampaign()
            }
            .buttonStyle(.glassProminent)
            .disabled(!canCreateCampaign)
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private func scopeToggle(
        _ title: String,
        included: Binding<Bool>,
        exclusionReason: Binding<String>,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Toggle(title, isOn: included)
            Text(detail)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            if !included.wrappedValue {
                TextField(
                    "Reason excluded from this campaign",
                    text: exclusionReason
                )
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding(DesignSpacing.m.pt)
        .background(
            .secondary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: DesignRadius.small.pt)
        )
    }

    private func summaryMetric(
        _ title: String,
        _ value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text(title)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignType.label.font.monospaced())
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func messageCard(
        _ text: String,
        isError: Bool = false
    ) -> some View {
        Label(
            text,
            systemImage:
                isError
                ? "exclamationmark.triangle.fill"
                : "info.circle"
        )
        .font(DesignType.label.font)
        .foregroundStyle(isError ? .red : .secondary)
        .textSelection(.enabled)
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isError
                ? Color.red.opacity(0.08)
                : Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt)
        )
    }

    private var canCreateCampaign: Bool {
        guard selectedSystemID != nil,
              commitSHA.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).count >= 7,
              !branchName.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            return false
        }
        if !splitDriverIncluded,
           splitDriverExclusionReason.trimmingCharacters(
            in: .whitespacesAndNewlines
           ).isEmpty {
            return false
        }
        if !coherentSubIncluded,
           coherentSubExclusionReason.trimmingCharacters(
            in: .whitespacesAndNewlines
           ).isEmpty {
            return false
        }
        if !liveANCIncluded,
           liveANCExclusionReason.trimmingCharacters(
            in: .whitespacesAndNewlines
           ).isEmpty {
            return false
        }
        return true
    }

    private var canRecordObservation: Bool {
        guard selectedGateIncluded,
              !macModel.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !macOSVersion.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              sampleRate.isFinite,
              sampleRate > 0,
              ioBufferFrames > 0,
              !outputDeviceName.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !outputDeviceUID.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !speakerTopology.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !reviewer.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !notes.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            return false
        }
        if authority >= .physicalHardware,
           !physicalAttestation {
            return false
        }
        if authority >= .independentPhysicalReview,
           !independentReviewAttestation {
            return false
        }
        return true
    }

    private func createCampaign() {
        guard let systemID = selectedSystemID else {
            actionMessage =
                "Select a Playback System before creating a campaign."
            return
        }
        do {
            let identity = HardwareAcceptanceCampaignIdentity(
                commitSHA: commitSHA.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                branch: branchName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                appVersion: appVersion,
                appBuild: appBuild,
                playbackSystemID: systemID
            )
            let decisions: [HardwareAcceptanceCapability:
                HardwareAcceptanceScopeDecision] = [
                .protectedSplitDriverMeasurement:
                    scopeDecision(
                        included: splitDriverIncluded,
                        reason: splitDriverExclusionReason
                    ),
                .coherentIndependentSubAlignment:
                    scopeDecision(
                        included: coherentSubIncluded,
                        reason: coherentSubExclusionReason
                    ),
                .liveFeedForwardANC:
                    scopeDecision(
                        included: liveANCIncluded,
                        reason: liveANCExclusionReason
                    ),
            ]
            try acceptance.createCampaign(
                identity: identity,
                scopeDecisions: decisions
            )
            showingCampaignForm = false
            actionMessage =
                "Created immutable hardware acceptance campaign. No physical gate has been passed."
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func runPreflight() {
        do {
            guard let campaign = acceptance.campaign else {
                throw HardwareAcceptanceWorkflowError
                    .campaignRequired
            }
            let environment = HardwareAcceptanceEnvironment(
                macModel: macModel,
                macOSVersion: macOSVersion,
                sampleRate: sampleRate,
                ioBufferFrames: ioBufferFrames,
                outputDeviceName: outputDeviceName,
                outputDeviceUID: outputDeviceUID,
                inputDeviceName: optionalText(inputDeviceName),
                inputDeviceUID: optionalText(inputDeviceUID),
                microphoneIdentifier:
                    optionalText(microphoneIdentifier),
                speakerTopology: speakerTopology,
                referencePathDescription:
                    optionalText(referencePathDescription)
            )
            _ = try environment.validated()

            var draft: ProtectedDriverCommissioningDraft?
            if selectedGate == .h05AdvancedMeasurementLab,
               acceptance.supplementalCapabilityIsIncluded(
                .protectedSplitDriverMeasurement
               ) {
                draft = try HardwareAcceptanceCommissioningDraftLocator()
                    .latest(
                        for: campaign.identity.playbackSystemID
                    )
            }

            let runtime = HardwareAcceptanceRuntimeSnapshot(
                lifecycleState: engine.lifecycleState,
                selectedPlaybackSystem:
                    profiles.selectedSystemProfile,
                selectedPlaybackSystemIsDirty:
                    profiles.selectedSystemProfileIsDirty,
                engineSelectedOutputUID:
                    engine.routeConfiguration.selectedOutputUID
            )
            let attestations =
                HardwareAcceptancePreflightAttestations(
                    protectedDriverWiringConfirmed:
                        protectedDriverWiringPreflightConfirmed,
                    sameADCMicrophoneAndReferenceConfirmed:
                        sameADCPreflightConfirmed,
                    commonOutputClockConfirmed:
                        commonClockPreflightConfirmed,
                    safeLineLevelReferenceConfirmed:
                        safeLineReferencePreflightConfirmed
                )
            let result = HardwareAcceptancePreflightAnalyzer()
                .evaluate(
                    campaign: campaign,
                    gateID: selectedGate,
                    runtime: runtime,
                    environment: environment,
                    attestations: attestations,
                    commissioningDraft: draft
                )
            preflightResult = result
            actionMessage = result.readyToBeginPhysicalTest
                ? "Preflight is ready to begin the physical procedure; no acceptance status changed."
                : "Preflight found blockers. No acceptance status changed."
        } catch {
            preflightResult = nil
            actionMessage = error.localizedDescription
        }
    }

    private func resetPreflight() {
        preflightResult = nil
        protectedDriverWiringPreflightConfirmed = false
        sameADCPreflightConfirmed = false
        commonClockPreflightConfirmed = false
        safeLineReferencePreflightConfirmed = false
    }

    private func recordObservation() {
        do {
            let environment = HardwareAcceptanceEnvironment(
                macModel: macModel,
                macOSVersion: macOSVersion,
                sampleRate: sampleRate,
                ioBufferFrames: ioBufferFrames,
                outputDeviceName: outputDeviceName,
                outputDeviceUID: outputDeviceUID,
                inputDeviceName:
                    optionalText(inputDeviceName),
                inputDeviceUID:
                    optionalText(inputDeviceUID),
                microphoneIdentifier:
                    optionalText(microphoneIdentifier),
                speakerTopology: speakerTopology,
                referencePathDescription:
                    optionalText(referencePathDescription)
            )
            var artifacts:
                [HardwareAcceptanceArtifactReference] = []
            if let identifier =
                optionalText(artifactIdentifier) {
                artifacts.append(
                    HardwareAcceptanceArtifactReference(
                        label:
                            artifactLabel.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                            ? "Acceptance evidence"
                            : artifactLabel,
                        identifier: identifier
                    )
                )
            }
            let covered:
                [HardwareAcceptanceCapability] =
                selectedGate == .h05AdvancedMeasurementLab
                    && splitDriverCovered
                ? [.protectedSplitDriverMeasurement]
                : []
            let observation = HardwareAcceptanceObservation(
                gateID: selectedGate,
                authority: authority,
                outcome: outcome,
                environment: environment,
                reviewer: reviewer,
                notes: notes,
                coveredCapabilities: covered,
                artifacts: artifacts
            )
            try acceptance.recordObservation(
                observation,
                physicalAttestationConfirmed:
                    physicalAttestation,
                independentReviewAttestationConfirmed:
                    independentReviewAttestation
            )
            actionMessage =
                "Appended \(selectedGate.rawValue) observation. Prior evidence remains preserved."
            notes = ""
            artifactIdentifier = ""
            splitDriverCovered = false
            resetObservationAttestations()
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func prepareAcceptanceExport(
        campaign: HardwareAcceptanceCampaign,
        json: Bool
    ) {
        actionMessage = nil
        do {
            let report = try reportBuilder.build(
                campaign: campaign
            )
            let data = json
                ? try reportExporter.jsonData(report)
                : reportExporter.markdownData(report)
            exportDocument =
                HardwareAcceptanceExportDocument(data: data)
            exportContentType = json
                ? .json
                : (UTType(filenameExtension: "md") ?? .plainText)
            exportFilename =
                "notch-sixty-hardware-acceptance-\(String(campaign.identity.id.uuidString.prefix(8)))"
            showingExporter = true
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    private func populatePhysicalDefaults() {
        guard let output = engine.selectedOutputDevice else {
            return
        }
        outputDeviceName = output.name
        outputDeviceUID = output.uid
        sampleRate = output.nominalSampleRate
    }

    private func resetObservationAttestations() {
        physicalAttestation = false
        independentReviewAttestation = false
        splitDriverCovered = false
    }

    private func scopeDecision(
        included: Bool,
        reason: String
    ) -> HardwareAcceptanceScopeDecision {
        included
            ? .included
            : .excluded(
                reason: reason.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
    }

    private func optionalText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private func authorityName(
        _ value: HardwareAcceptanceEvidenceAuthority
    ) -> String {
        switch value {
        case .remoteSoftware:
            return "Remote software"
        case .physicalHardware:
            return "Physical hardware"
        case .independentPhysicalReview:
            return "Independent physical review"
        }
    }

    private func outcomeName(
        _ value: HardwareAcceptanceObservationOutcome
    ) -> String {
        switch value {
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        }
    }

    private func statusName(
        _ status: HardwareAcceptanceGateStatus
    ) -> String {
        switch status {
        case .missing:
            return "MISSING"
        case .excluded:
            return "EXCLUDED"
        case .blocked:
            return "BLOCKED"
        case .failed:
            return "FAILED"
        case .insufficientAuthority(
            _,
            let actual,
            let required
        ):
            return
                "INSUFFICIENT · \(authorityName(actual)) < \(authorityName(required))"
        case .insufficientScope:
            return "INSUFFICIENT SCOPE"
        case .passed(_, let authority):
            return "PASSED · \(authorityName(authority))"
        }
    }
}
