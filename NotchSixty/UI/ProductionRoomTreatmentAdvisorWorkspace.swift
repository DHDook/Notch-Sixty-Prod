import SwiftUI

struct ProductionRoomTreatmentAdvisorWorkspace: View {
    @ObservedObject var advisor: RoomTreatmentAdvisorController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                workflowCard
                measurementSourceCard

                if let report = advisor.report {
                    readinessCard(report)
                    ProductionRoomGeometrySection(
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
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(14)
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
            .padding(28)
            .frame(
                maxWidth: 1_080,
                alignment: .topLeading
            )
        }
        .task {
            advisor.prepareForUse()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Room Advisor")
                    .font(.largeTitle.bold())
                Text(
                    "Occasional measurement-guided advice for placement, physical treatment, DSP and active acoustics."
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("READ-ONLY TOOL")
                .font(.caption.bold())
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Workflow")
                .font(.headline)
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
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("\(number)")
                    .font(.caption.bold())
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
                    .font(.subheadline.bold())
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var measurementSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Measurement Source")
                        .font(.headline)
                    Text(
                        "Advisor selection is independent of the current Content Preset and Playback System."
                    )
                    .font(.caption)
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
                .buttonStyle(.bordered)
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
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }

    private func readinessCard(
        _ report: RoomTreatmentAdvisorReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Measurement Readiness")
                .font(.headline)

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
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "Measurement warnings",
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .font(.subheadline.bold())
                    ForEach(
                        report.qualityWarnings,
                        id: \.self
                    ) { warning in
                        Text("• \(warning)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }

    private func actionPlanCard(
        _ report: RoomTreatmentAdvisorReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recommended Order")
                    .font(.headline)
                Text(
                    "Priorities combine severity, confidence and measurement readiness. Nothing is applied automatically."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(
                report.actionPriorities.indices,
                id: \.self
            ) { index in
                let priority =
                    report.actionPriorities[index]
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.headline.monospacedDigit())
                        .frame(width: 30, height: 30)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(priority.remedy.displayName)
                            .font(.subheadline.bold())
                        Text(priority.rationale)
                            .font(.caption)
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
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }

    private func findingsSection(
        _ report: RoomTreatmentAdvisorReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnosis & Recommendations")
                        .font(.headline)
                    Text(
                        "Measured evidence is kept separate from interpretation and advice."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    "\(report.findings.count) FINDING\(report.findings.count == 1 ? "" : "S")"
                )
                .font(.caption.bold())
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(
                    systemName:
                        findingIcon(finding)
                )
                .font(.title3)
                .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.title)
                        .font(.headline)
                    Text(
                        "\(Int((finding.confidence * 100).rounded()))% advisory confidence"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    finding.primaryRemedy
                        .displayName.uppercased()
                )
                .font(.caption.bold())
                .tracking(0.7)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
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
                HStack(spacing: 7) {
                    Text("Also consider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(
                        finding.secondaryRemedies
                    ) { remedy in
                        Text(remedy.displayName)
                            .font(.caption.bold())
                            .padding(
                                .horizontal,
                                8
                            )
                            .padding(.vertical, 4)
                            .background(
                                .secondary.opacity(0.08),
                                in: Capsule()
                            )
                    }
                }
            }
        }
        .padding(18)
        .background(
            .secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 16)
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
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(
                        width: 72,
                        alignment: .leading
                    )
                Text(text)
                    .font(.callout)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(
                "No saved room measurements",
                systemImage:
                    "waveform.badge.magnifyingglass"
            )
            .font(.headline)
            Text(
                "Use Speaker Calibration / Room Correction to capture at least one room sweep. Then return here and reload. A single movable measurement microphone is the expected workflow."
            )
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }

    private var readOnlyNote: some View {
        Label(
            "Room Advisor never applies EQ, changes a preset, selects a Playback System, or arms Active Room Treatment. Recommendations remain advisory until you deliberately use the corresponding workflow.",
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func metric(
        title: String,
        value: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: 105,
            alignment: .topLeading
        )
        .background(
            .secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 13)
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
