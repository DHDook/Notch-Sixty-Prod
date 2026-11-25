import SwiftUI

struct ProductionRoomTreatmentAdvisorWorkspace: View {
    @Bindable var advisor: RoomTreatmentAdvisorController
    @ObservedObject var profiles: ProductProfileController

    var body: some View {
        ProductionPageContainer {
            VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
                header
                SystemCapabilityNoteCard(
                    title: "Your speaker arrangement", features: SystemCapabilityText.advisorFeatures,
                    profiles: profiles, includeArrangement: true)
                workflowCard
                measurementSourceCard

                if let report = advisor.report {
                    readinessCard(report)
                    unifiedAcousticIntelligenceCard(report)
                    ProductionRoomGeometrySection(
                        advisor: advisor
                    )
                    ProductionRoomTreatmentDesignSection(
                        advisor: advisor
                    )
                    if !report.actionPriorities.isEmpty {
                        actionPlanCard(report)
                    }
                    findingsSection(report)
                } else if advisor.availableProjects.isEmpty {
                    emptyState
                }

                if let error = advisor.lastErrorDescription {
                    Label(
                        error,
                        systemImage:
                            "exclamationmark.triangle.fill"
                    )
                    .font(DesignType.label.font)
                    .foregroundStyle(StatusLevel.problem.color)
                    .textSelection(.enabled)
                    .padding(DesignSpacing.l.pt)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        .red.opacity(0.08),
                        in: RoundedRectangle(
                            cornerRadius: 12
                        )
                    )
                }

                readOnlyNote
            }
        }
        .task {
            advisor.prepareForUse()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                Text(
                    "Occasional measurement-guided advice for placement, physical treatment, DSP and active acoustics."
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("READ-ONLY TOOL")
                .font(DesignType.caption.font.bold())
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignSpacing.m.pt)
                .padding(.vertical, DesignSpacing.s.pt)
                .glassEffect(.regular, in: .capsule)
        }
    }

    /// This surface consumes ONLY the selected Room Advisor report. It does
    /// not search other projects or silently bind a Playback System. Speaker
    /// and Multi-Sub comparisons must be presented only once their explicit
    /// source/playback/route/clock identities have been authenticated.
    private func unifiedAcousticIntelligenceCard(
        _ room: RoomTreatmentAdvisorReport
    ) -> some View {
        let selected = advisor.unifiedSpeakerBaselines.first {
            $0.id == advisor.unifiedSpeakerBaselineID
        }
        // Only the explicitly selected, qualified Speaker Optimizer baseline
        // can supply source, route, playback system and clock identity.
        let identity = UnifiedAcousticEvidenceIdentity(
            projectID: room.projectID,
            playbackSystemID: selected?.playbackSystemID,
            routingSignature: selected?.routingSignature,
            sampleRate: selected?.sampleRate,
            baselineMeasurementSetID: selected?.id
        )
        let summary = UnifiedAcousticIntelligenceCoordinator().summarize(
            room: room, identity: identity,
            speaker: advisor.unifiedSpeakerComparison,
            physicalSub: advisor.physicalSubComparison
        )
        return VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                Label(
                    "Acoustic Intelligence · Recommended Sequence",
                    systemImage: "waveform.path.ecg.rectangle"
                )
                .font(DesignType.sectionTitle.font)
                Spacer()
                Text("REVIEW ONLY")
                    .font(DesignType.caption.font.bold())
                    .foregroundStyle(.secondary)
            }
            Text(
                "Combines selected room findings into physical-first advice. Speaker Optimizer baselines require explicit selection and verified playback/route identity. Physical Sub comparisons appear only after the existing before/after measurement workflow approves them."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                HStack {
                    Text("Source-specific speaker evidence")
                        .font(DesignType.label.font.bold())
                    Spacer()
                    Button("Find baselines") {
                        advisor.refreshUnifiedSpeakerBaselines()
                    }
                    .buttonStyle(.glass)
                }
                Picker(
                    "Qualified baseline",
                    selection: Binding(
                        get: { advisor.unifiedSpeakerBaselineID },
                        set: {
                            advisor.unifiedSpeakerBaselineID = $0
                            // Revalidate the stored selected identity. The
                            // controller clears a previous unrelated plan.
                            advisor.clearUnifiedSpeakerComparison()
                        }
                    )
                ) {
                    Text("Choose a baseline…").tag(UUID?.none)
                    ForEach(advisor.unifiedSpeakerBaselines) { baseline in
                        Text(
                            "\(baseline.plannedSources.count) sources · "
                            + "\(Int(baseline.sampleRate)) Hz · "
                            + String(baseline.id.uuidString.prefix(8))
                        )
                        .tag(UUID?.some(baseline.id))
                    }
                }
                .frame(maxWidth: 580)
                Button("Review selected baseline") {
                    advisor.reviewUnifiedSpeakerBaseline()
                }
                .buttonStyle(.glassProminent)
                .disabled(advisor.unifiedSpeakerBaselineID == nil)
                if let selected {
                    Text(
                        "Explicitly selected route: " + selected.routingSignature
                        + " · Microphone: " + selected.microphone.deviceUID
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                if let status = advisor.unifiedSpeakerMessage {
                    Text(status)
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                if let comparison = advisor.unifiedSpeakerComparison {
                    VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                        Text("Verified-source candidate tradeoffs · visual review only")
                            .font(DesignType.label.font.bold())
                        Text(
                            "All alternatives use the same explicitly selected qualified Speaker Optimizer baseline. Target error, headroom, seat regression and FIR group delay are modeled—not measured post-correction."
                        )
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                        ForEach(comparison.sources.indices, id: \.self) { row in
                            let source = comparison.sources[row]
                            Text(source.source.displayName)
                                .font(DesignType.label.font.bold())
                            ForEach(source.alternatives.indices, id: \.self) { ix in
                                let alternative = source.alternatives[ix]
                                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                                    HStack(spacing: DesignSpacing.m.pt) {
                                        Text(alternative.kind.rawValue.uppercased())
                                            .font(DesignType.caption.font.bold())
                                        Text(
                                            String(
                                                format: "Target RMSE: %.2f dB",
                                                alternative.predictedWeightedRMSEAfterDB
                                            )
                                        )
                                        .font(DesignType.caption.font.monospacedDigit())
                                        Spacer(minLength: 4)
                                        Text(
                                            alternative.eligibleForVisualPreview
                                                ? "Preview eligible" : "Blocked"
                                        )
                                        .font(DesignType.caption.font.bold())
                                        .foregroundStyle(
                                            alternative.eligibleForVisualPreview
                                                ? Color.secondary : Color.orange
                                        )
                                    }
                                    HStack(spacing: DesignSpacing.m.pt) {
                                        Text(
                                            String(format: "Headroom +%.2f dB", alternative.requiredHeadroomDB)
                                        )
                                        Text(
                                            String(format: "Worst seat +%.2f dB", alternative.worstSeatRegressionDB)
                                        )
                                        Text(
                                            alternative.fixedGroupDelayMilliseconds.map {
                                                String(format: "FIR %.2f ms", $0)
                                            } ?? "No declared fixed FIR delay"
                                        )
                                    }
                                    .font(DesignType.caption.font.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    ForEach(alternative.blockingReasons, id: \.self) { warning in
                                        Text("• " + warning)
                                            .font(DesignType.caption.font)
                                            .foregroundStyle(StatusLevel.attention.color)
                                    }
                                }
                                .padding(DesignSpacing.s.pt)
                                .background(.secondary.opacity(0.055),
                                            in: RoundedRectangle(cornerRadius: DesignRadius.small.pt))
                            }
                        }
                    }
                }
                if let sub = advisor.physicalSubComparison {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text("Physical Sub placement · measured multi-seat LF spread")
                            .font(DesignType.label.font.bold())
                        Text(
                            String(
                                format: "Before: %.2f dB RMS · After: %.2f dB RMS · Improvement: %.2f dB across %d seats",
                                sub.baselineInterseatSpreadRMSDB,
                                sub.candidateInterseatSpreadRMSDB,
                                sub.reductionInInterseatSpreadDB,
                                sub.seatCount
                            )
                        )
                        .font(DesignType.caption.font.monospacedDigit())
                        Text(
                            "Other objectives: target error unavailable · decay unavailable · headroom unavailable · coherent phase/timing unavailable · added latency unavailable. No physical routing changes are authorized."
                        )
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(
                        "For measured Sub placement tradeoffs, use the existing verified before/after placement comparison. Coordinated multi-Sub timing additionally requires independent output mapping and a common phase reference."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
            }
            Divider()
            if summary.advice.isEmpty {
                Text(
                    "No recommendation is available for this project. Capture and include room measurements first."
                )
                .font(DesignType.label.font)
            } else {
                ForEach(summary.advice.indices, id: \.self) { index in
                    let item = summary.advice[index]
                    HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                        Text("\(index + 1)")
                            .font(DesignType.label.font.bold().monospacedDigit())
                            .frame(width: 24, height: 24)
                            .background(.secondary.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                            Text(item.title)
                                .font(DesignType.label.font.bold())
                            Text(item.rationale)
                                .font(DesignType.caption.font)
                                .foregroundStyle(.secondary)
                            ForEach(item.blockers, id: \.self) { blocker in
                                Label(blocker, systemImage: "exclamationmark.shield")
                                    .font(DesignType.caption.font)
                                    .foregroundStyle(StatusLevel.attention.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    if index < summary.advice.count - 1 {
                        Divider()
                    }
                }
            }
            if !summary.warnings.isEmpty {
                Divider()
                ForEach(summary.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
            }
            Text(
                "Modeled recommendations are not verified acoustic improvements. No EQ, room correction, speaker delays or Sub routing can be applied here."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Text("Workflow")
                .font(DesignType.sectionTitle.font)
            HStack(spacing: 0) {
                workflowStep(
                    number: 1,
                    title: "Measurements",
                    detail: "Choose captured room data",
                    active: advisor.report == nil
                )
                workflowConnector
                workflowStep(
                    number: 2,
                    title: "Diagnose",
                    detail: "Find measured problems",
                    active: advisor.report != nil
                )
                workflowConnector
                workflowStep(
                    number: 3,
                    title: "Actions",
                    detail: "Choose the right remedy",
                    active:
                        advisor.report?
                            .actionPriorities.isEmpty
                            == false
                )
                workflowConnector
                workflowStep(
                    number: 4,
                    title: "Verify",
                    detail: "Re-measure after changes",
                    active: false
                )
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: DesignRadius.large.pt)
        )
    }

    private var workflowConnector: some View {
        Rectangle()
            .fill(.secondary.opacity(0.20))
            .frame(height: 1)
            .frame(maxWidth: 42)
    }

    private func workflowStep(
        number: Int,
        title: String,
        detail: String,
        active: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            HStack(spacing: DesignSpacing.s.pt) {
                Text("\(number)")
                    .font(DesignType.caption.font.bold())
                    .frame(width: 24, height: 24)
                    .background(
                        active
                            ? AnyShapeStyle(
                                Color.accentColor.opacity(0.18)
                              )
                            : AnyShapeStyle(
                                Color.secondary.opacity(0.10)
                              ),
                        in: Circle()
                    )
                Text(title)
                    .font(DesignType.label.font.bold())
            }
            Text(detail)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var measurementSourceCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Measurement Source")
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "Advisor selection is independent of the current Content Preset and Playback System."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    advisor.reloadProjects()
                } label: {
                    Label(
                        "Reload",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.glass)
            }

            Picker(
                "Saved measurement project",
                selection: Binding(
                    get: { advisor.selectedProjectID },
                    set: { advisor.selectProject($0) }
                )
            ) {
                Text("Choose a project…")
                    .tag(UUID?.none)
                ForEach(advisor.availableProjects) {
                    project in
                    Text(
                        "\(project.name) · \(project.measurements.count) position\(project.measurements.count == 1 ? "" : "s")"
                    )
                    .tag(UUID?.some(project.id))
                }
            }
            .frame(maxWidth: 520)
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: DesignRadius.large.pt)
        )
    }

    private func readinessCard(
        _ report: RoomTreatmentAdvisorReport
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Text("Measurement Readiness")
                .font(DesignType.sectionTitle.font)

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: 12
            ) {
                metric(
                    title: "Analysis",
                    value: report.analysisMode.displayName,
                    detail:
                        report.analysisMode
                            == .singlePosition
                        ? "Useful for response/reflection clues; spatial conclusions need more positions."
                        : "Uses the retained included positions."
                )
                metric(
                    title: "Included Positions",
                    value:
                        "\(report.includedMeasurementCount)",
                    detail:
                        "\(report.retainedMeasurementCount) retained in the source project."
                )
                metric(
                    title: "Microphone",
                    value:
                        report.microphoneName
                            ?? "Not recorded",
                    detail:
                        report.calibratedMicrophone
                            ? "Calibration curve recorded."
                            : "No calibration curve recorded."
                )
            }

            if !report.qualityWarnings.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                    Label(
                        "Measurement warnings",
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .font(DesignType.label.font.bold())
                    ForEach(
                        report.qualityWarnings,
                        id: \.self
                    ) { warning in
                        Text("• \(warning)")
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: DesignRadius.large.pt)
        )
    }

    private func actionPlanCard(
        _ report: RoomTreatmentAdvisorReport
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text("Recommended Order")
                    .font(DesignType.sectionTitle.font)
                Text(
                    "Priorities combine severity, confidence and measurement readiness. Nothing is applied automatically."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }

            ForEach(
                report.actionPriorities.indices,
                id: \.self
            ) { index in
                let priority =
                    report.actionPriorities[index]
                HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                    Text("\(index + 1)")
                        .font(DesignType.sectionTitle.font.monospacedDigit())
                        .frame(width: 30, height: 30)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text(priority.remedy.displayName)
                            .font(DesignType.label.font.bold())
                        Text(priority.rationale)
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                    Spacer(minLength: 12)
                }

                if index
                    < report.actionPriorities.count - 1 {
                    Divider()
                }
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: DesignRadius.large.pt)
        )
    }

    private func findingsSection(
        _ report: RoomTreatmentAdvisorReport
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Diagnosis & Recommendations")
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "Measured evidence is kept separate from interpretation and advice."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    "\(report.findings.count) FINDING\(report.findings.count == 1 ? "" : "S")"
                )
                .font(DesignType.caption.font.bold())
                .tracking(0.8)
                .foregroundStyle(.secondary)
            }

            ForEach(report.findings) { finding in
                findingCard(finding)
            }
        }
    }

    private func findingCard(
        _ finding: RoomTreatmentAdvisorFinding
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                Image(
                    systemName:
                        findingIcon(finding)
                )
                .font(DesignType.sectionTitle.font)
                .frame(width: 26)
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text(finding.title)
                        .font(DesignType.sectionTitle.font)
                    Text(
                        "\(Int((finding.confidence * 100).rounded()))% advisory confidence"
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    finding.primaryRemedy
                        .displayName.uppercased()
                )
                .font(DesignType.caption.font.bold())
                .tracking(0.7)
                .padding(.horizontal, DesignSpacing.s.pt)
                .padding(.vertical, DesignSpacing.xs.pt)
                .glassEffect(.regular, in: .capsule)
            }

            advisorRow(
                label: "Measured",
                text: finding.measuredEvidence
            )
            advisorRow(
                label: "Meaning",
                text: finding.interpretation
            )
            advisorRow(
                label: "Next step",
                text: finding.recommendation
            )

            if !finding.secondaryRemedies.isEmpty {
                HStack(spacing: DesignSpacing.s.pt) {
                    Text("Also consider")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                    ForEach(
                        finding.secondaryRemedies
                    ) { remedy in
                        Text(remedy.displayName)
                            .font(DesignType.caption.font.bold())
                            .padding(
                                .horizontal,
                                8
                            )
                            .padding(.vertical, DesignSpacing.xs.pt)
                            .background(
                                .secondary.opacity(0.08),
                                in: Capsule()
                            )
                    }
                }
            }
        }
        .padding(DesignSpacing.l.pt)
        .background(
            .secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt)
        )
    }

    private func advisorRow(
        label: String,
        text: String
    ) -> some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: 14,
            verticalSpacing: 0
        ) {
            GridRow {
                Text(label)
                    .font(DesignType.caption.font.bold())
                    .foregroundStyle(.secondary)
                    .frame(
                        width: 72,
                        alignment: .leading
                    )
                Text(text)
                    .font(DesignType.label.font)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Label(
                "No saved room measurements",
                systemImage:
                    "waveform.badge.magnifyingglass"
            )
            .font(DesignType.sectionTitle.font)
            Text(
                "Use Speaker Calibration / Room Correction to capture at least one room sweep. Then return here and reload. A single movable measurement microphone is the expected workflow."
            )
            .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: DesignRadius.large.pt)
        )
    }

    private var readOnlyNote: some View {
        Label(
            "Room Advisor never applies EQ, changes a preset, selects a Playback System, or arms Active Room Treatment. Recommendations remain advisory until you deliberately use the corresponding workflow.",
            systemImage: "lock.shield"
        )
        .font(DesignType.caption.font)
        .foregroundStyle(.secondary)
        .padding(.top, DesignSpacing.xs.pt)
    }

    private func metric(
        title: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text(title)
                .font(DesignType.caption.font.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignType.sectionTitle.font.bold())
            Text(detail)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .padding(DesignSpacing.l.pt)
        .frame(
            maxWidth: .infinity,
            minHeight: 105,
            alignment: .topLeading
        )
        .background(
            .secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt)
        )
    }

    private func findingIcon(
        _ finding: RoomTreatmentAdvisorFinding
    ) -> String {
        switch finding.primaryRemedy {
        case .measureMore:
            return "mic.badge.plus"
        case .placement:
            return "move.3d"
        case .passiveTreatment:
            return "square.grid.3x3.fill"
        case .dspCorrection:
            return "slider.horizontal.3"
        case .activeRoomTreatment:
            return "waveform.path"
        case .activeQuietZone:
            return "speaker.wave.2.bubble"
        case .noAction:
            return "checkmark.circle"
        }
    }
}
