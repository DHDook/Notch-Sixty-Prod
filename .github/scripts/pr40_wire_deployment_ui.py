from pathlib import Path

path = Path("NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift")
text = path.read_text()

old_daily = '''    private var dailyPlaybackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Daily Playback").font(.headline)
                    Text(engine.roomCorrectionConfiguration.filter?.name ?? "No correction filter deployed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "Correction Enabled",
                    isOn: Binding(
                        get: { engine.roomCorrectionConfiguration.enabled },
                        set: { try? engine.setRoomCorrectionEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .disabled(engine.roomCorrectionConfiguration.filter == nil)
            }

            HStack(spacing: 22) {
                statusValue(
                    "Playback System Output",
                    calibration.selectedOutputDevice?.name ?? "Not selected"
                )
                statusValue(
                    "Native Rate",
                    calibration.selectedOutputDevice.map { formattedRate($0.nominalSampleRate) } ?? "—"
                )
                statusValue(
                    "DSP State",
                    engine.lifecycleState.rawValue.capitalized
                )
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
'''

new_daily = '''    private var dailyPlaybackCard: some View {
        let deployed = deployedRoomCorrection
        let summary = deployedCalibrationSummary
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Daily Playback").font(.headline)
                    Text(deployed.filter?.name ?? "No correction filter deployed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "Correction Enabled",
                    isOn: Binding(
                        get: { deployed.enabled },
                        set: { setDailyPlaybackEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .disabled(deployed.filter == nil)
            }

            HStack(spacing: 22) {
                statusValue("Playback System", profiles.selectedSystemProfileName)
                statusValue(
                    "Playback System Output",
                    calibration.selectedOutputDevice?.name ?? "Not selected"
                )
                statusValue(
                    "Native Rate",
                    deployed.filter?.sampleRate.map(formattedRate)
                        ?? calibration.selectedOutputDevice.map { formattedRate($0.nominalSampleRate) }
                        ?? "—"
                )
                statusValue("DSP State", engine.lifecycleState.rawValue.capitalized)
            }

            if let summary {
                Divider()
                HStack(spacing: 22) {
                    statusValue("Target", summary.targetName)
                    statusValue(
                        "Positions",
                        "\\(summary.positionCount) position\\(summary.positionCount == 1 ? "" : "s")"
                    )
                    statusValue(
                        "Correction Range",
                        "\\(formattedFrequency(summary.correctionLowHz)) – \\(formattedFrequency(summary.correctionHighHz))"
                    )
                    statusValue(
                        "Embedded Safety",
                        String(format: "%.1f dB", summary.recommendedHeadroomDB)
                    )
                }
                HStack(spacing: 22) {
                    statusValue("Measured", formattedDate(summary.measurementDate))
                    statusValue("Designed", formattedDate(summary.designDate))
                    statusValue("Algorithm", summary.algorithmVersion)
                }
                Text("This summary comes from the deployed Playback System profile. Project edits, design selection, and Content Preset changes do not alter daily room correction until you explicitly deploy again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No room-correction design is deployed to this Playback System. Generated project candidates remain offline until you deploy one explicitly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
'''

if old_daily not in text:
    raise SystemExit("daily playback card anchor not found")
text = text.replace(old_daily, new_daily, 1)

old_selected = '''            if let selected = projects.selectedDesign {
                Divider()
                Label("Selected candidate: \\(selected.name). Deployment remains a separate explicit step and daily playback is unchanged.", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
'''

new_selected = '''            if let selected = projects.selectedDesign {
                Divider()
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected candidate: \\(selected.name)")
                            .font(.callout.weight(.semibold))
                        if selectedDesignIsDeployed {
                            Label("This exact design is deployed to \\(profiles.selectedSystemProfileName).", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if let deployedName = deployedRoomCorrection.filter?.name {
                            Text("Daily playback is still using \\(deployedName) until you deploy this candidate.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Daily playback is unchanged until you deploy this candidate.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        deploySelectedDesign()
                    } label: {
                        Label(
                            selectedDesignIsDeployed ? "Deployed" : "Deploy to \\(profiles.selectedSystemProfileName)",
                            systemImage: selectedDesignIsDeployed ? "checkmark.circle.fill" : "arrow.down.to.line"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDesignIsDeployed || profiles.selectedSystemProfile == nil)
                }
                Text("Deployment embeds the design's recommended safety attenuation in the room-owned FIR. Content Preset preamp/headroom remain unchanged, and the deployed filter remains available even if the room-project sidecar is later unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
'''

if old_selected not in text:
    raise SystemExit("selected design anchor not found")
text = text.replace(old_selected, new_selected, 1)

anchor = '''    private var currentDesignParameters: RoomCorrectionDesignParameters {
'''
insert = '''    private var deployedRoomCorrection: RoomCorrectionConfiguration {
        profiles.selectedSystemProfile?.state.roomCorrection ?? RoomCorrectionConfiguration()
    }

    private var deployedCalibrationSummary: RoomCorrectionCalibrationSummary? {
        profiles.selectedSystemProfile?.state.roomCorrectionCalibration
    }

    private var selectedDesignIsDeployed: Bool {
        guard let selected = projects.selectedDesign,
              let summary = deployedCalibrationSummary else { return false }
        return summary.activeDesignID == selected.id
    }

    private func deploySelectedDesign() {
        actionError = nil
        guard let selected = projects.selectedDesign else {
            actionError = "Select a generated room-correction design before deploying."
            return
        }
        do {
            let filter = try selected.deploymentFilter()
            let summary = try projects.deploymentSummary(for: selected)
            try profiles.replaceSelectedSystemRoomCorrection(
                RoomCorrectionConfiguration(enabled: true, filter: filter),
                calibrationSummary: summary
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func setDailyPlaybackEnabled(_ enabled: Bool) {
        actionError = nil
        do {
            try profiles.setSelectedSystemRoomCorrectionEnabled(enabled)
        } catch {
            actionError = error.localizedDescription
        }
    }

'''
if anchor not in text:
    raise SystemExit("current design parameters anchor not found")
text = text.replace(anchor, insert + anchor, 1)

format_anchor = '''    private func formattedRate(_ rate: Double) -> String {
        if rate >= 1_000 {
            return String(format: "%.1f kHz", rate / 1_000)
        }
        return String(format: "%.0f Hz", rate)
    }
'''
format_replacement = format_anchor + '''
    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
'''
if format_anchor not in text:
    raise SystemExit("formatted rate anchor not found")
text = text.replace(format_anchor, format_replacement, 1)

path.write_text(text)
