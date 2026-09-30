from pathlib import Path

path = Path("NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift")
text = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Unexpected {label}: found {count} anchors")
    text = text.replace(old, new, 1)


# Add durable project/profile ownership to the workspace.
if "    @ObservedObject var projects: RoomCorrectionProjectController\n" not in text:
    replace_once(
        "    @ObservedObject var calibration: RoomCorrectionCalibrationController\n",
        "    @ObservedObject var calibration: RoomCorrectionCalibrationController\n"
        "    @ObservedObject var projects: RoomCorrectionProjectController\n"
        "    @ObservedObject var profiles: ProductProfileController\n",
        "workspace observed-object property",
    )

if "    @State private var positionName = \"\"\n" not in text:
    replace_once(
        "    @State private var actionError: String?\n",
        "    @State private var actionError: String?\n"
        "    @State private var positionName = \"\"\n",
        "position-name state",
    )

# Show retained positions after the current measurement review.
review_block = """                if calibration.state == .reviewing, let analysis = calibration.latestAnalysis {
                    reviewCard(analysis)
                }
"""
if "                    positionsCard\n" not in text:
    replace_once(
        review_block,
        review_block
        + """
                if !projects.positions.isEmpty {
                    positionsCard
                }
""",
        "review block",
    )

replace_once(
    "                if let error = actionError ?? calibration.lastErrorDescription {\n",
    "                if let error = actionError ?? calibration.lastErrorDescription ?? projects.lastErrorDescription {\n",
    "combined error line",
)

# Reload the sidecar whenever the selected Playback System changes.
if ".task(id: profiles.selectedSystemProfileID)" not in text:
    replace_once(
        "        .task { calibration.prepareForUse() }\n",
        "        .task { calibration.prepareForUse() }\n"
        "        .task(id: profiles.selectedSystemProfileID) {\n"
        "            projects.prepareForUse()\n"
        "        }\n",
        "prepare task",
    )

# Replace the old Review footer with a retain action and accurate downstream scope.
old_footer = """            Text("This review is the measured response for the current position only. Named positions, inclusion/weighting, spatial aggregation, target shaping, and FIR design remain separate downstream stages; none are inferred here.")
                .font(.caption)
                .foregroundStyle(.secondary)
"""
new_footer = """            Divider()

            if projects.contains(analysis) {
                Label("Current measurement retained in the Playback System project", systemImage: "tray.and.arrow.down.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    TextField(projects.suggestedPositionName, text: $positionName)
                        .frame(maxWidth: 280)
                    Button {
                        retainReviewedMeasurement(analysis)
                    } label: {
                        Label("Keep Position", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Leave the name blank to use \\(projects.suggestedPositionName). Raw capture, impulse response, transfer function, and quality metadata are retained together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("This review is the measured response for the current position only. Target shaping and FIR design remain separate downstream stages; none are inferred here.")
                .font(.caption)
                .foregroundStyle(.secondary)
"""
replace_once(old_footer, new_footer, "review footer")

methods = r'''    private var positionsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("4. Positions").font(.headline)
                    Text(projects.project?.name ?? "No room-correction project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start New Project") {
                    actionError = nil
                    do {
                        try projects.startNewProject()
                        positionName = ""
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
            }

            ForEach(projects.positions) { position in
                RoomCorrectionPositionRow(
                    position: position,
                    projects: projects,
                    onError: { actionError = $0 }
                )
            }

            Divider()
            if let aggregate = projects.aggregate {
                Label(
                    "Weighted magnitude aggregate ready from \(aggregate.includedPositionIDs.count) included position\(aggregate.includedPositionIDs.count == 1 ? "" : "s")",
                    systemImage: "sum"
                )
                .font(.callout.weight(.semibold))
                Text("Weights are normalized before averaging magnitude in dB. Seat phase and timing remain attached to each individual measurement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No aggregate is active. Include at least one retained position with weight greater than zero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func retainReviewedMeasurement(_ analysis: RoomCorrectionMeasurementAnalysis) {
        actionError = nil
        guard let input = calibration.selectedInputDevice,
              let sweep = calibration.activePlan?.program.settings else {
            actionError = "The reviewed measurement no longer has its originating microphone or sweep metadata. Measure the position again before retaining it."
            return
        }

        let microphone = RoomCorrectionMicrophone(
            stableID: input.uid,
            displayName: input.name,
            manufacturer: nil,
            inputChannelIndex: calibration.selectedInputChannelIndex,
            calibration: projects.project?.microphone?.calibration
        )
        let proposed = positionName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try projects.retainMeasurement(
                analysis,
                sweep: sweep,
                microphone: microphone,
                name: proposed.isEmpty ? nil : proposed
            )
            positionName = ""
        } catch {
            actionError = error.localizedDescription
        }
    }

'''
if "    private var positionsCard: some View {" not in text:
    badge_anchor = "    private var calibrationStateBadge: some View {\n"
    if text.count(badge_anchor) != 1:
        raise SystemExit("Unexpected calibration-state badge anchor")
    text = text.replace(badge_anchor, methods + badge_anchor, 1)

if "private struct RoomCorrectionPositionRow: View {" not in text:
    text += r'''

private struct RoomCorrectionPositionRow: View {
    let positionID: UUID
    @ObservedObject var projects: RoomCorrectionProjectController
    let onError: (String) -> Void
    @State private var nameDraft: String

    init(
        position: RoomCorrectionMeasurementPosition,
        projects: RoomCorrectionProjectController,
        onError: @escaping (String) -> Void
    ) {
        positionID = position.id
        self.projects = projects
        self.onError = onError
        _nameDraft = State(initialValue: position.name)
    }

    private var position: RoomCorrectionMeasurementPosition? {
        projects.positions.first { $0.id == positionID }
    }

    var body: some View {
        if let position {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Toggle("Included", isOn: includedBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    TextField("Position name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit { commitName() }

                    Button("Rename") { commitName() }
                        .buttonStyle(.bordered)
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == position.name)

                    Spacer()

                    Stepper(value: weightBinding, in: 0...10, step: 0.25) {
                        Text("Weight \(position.weight, specifier: "%.2f")")
                            .monospacedDigit()
                    }
                    .frame(width: 170)
                }

                HStack(spacing: 18) {
                    Text("L SNR \(formattedDB(position.left.quality.estimatedSNRDB))")
                    Text("R SNR \(formattedDB(position.right.quality.estimatedSNRDB))")
                    Text("\(position.sampleRate / 1_000, specifier: "%.1f") kHz")
                    Text(position.included ? "Included in aggregate" : "Retained · excluded")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: position.name) { _, newName in
                if nameDraft != newName { nameDraft = newName }
            }
        }
    }

    private var includedBinding: Binding<Bool> {
        Binding(
            get: { position?.included ?? false },
            set: { included in
                do { try projects.setMeasurementIncluded(id: positionID, included: included) }
                catch { onError(error.localizedDescription) }
            }
        )
    }

    private var weightBinding: Binding<Double> {
        Binding(
            get: { position?.weight ?? 0 },
            set: { weight in
                do { try projects.setMeasurementWeight(id: positionID, weight: weight) }
                catch { onError(error.localizedDescription) }
            }
        )
    }

    private func commitName() {
        do {
            try projects.renameMeasurement(id: positionID, to: nameDraft)
        } catch {
            onError(error.localizedDescription)
            if let position { nameDraft = position.name }
        }
    }

    private func formattedDB(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f dB", value)
    }
}
'''

path.write_text(text)
