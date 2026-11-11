import SwiftUI

/// E4 S26a: survey the monitor-to-ear ratio and design the quiet zone at the ear.
/// Shown when flag `e4.virtual-microphone` is on. The survey only measures; switching the zone to the ear
/// changes the design Quiet Zone uses while it is running, and never arms anything.
struct ProductionVirtualMicrophoneCard: View {
    @ObservedObject var survey: QuietZoneVirtualMicSurveyController
    var quietZoneRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quiet Zone at the Ear")
                .font(.headline)
            Text("Quiet Zone normally quiets the error microphone. Measure how the noise at your ear differs from the noise at the microphone, and it quiets your ear instead. The microphone at the monitor position still checks that the room is not getting louder.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Ear position")
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)
                Picker("Ear position", selection: Binding(
                    get: { survey.ear?.id },
                    set: { survey.selectEar($0) }
                )) {
                    Text("Select…").tag(UUID?.none)
                    ForEach(survey.earPositionCandidates, id: \.id) { entry in
                        Text(entry.name).tag(UUID?.some(entry.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(survey.isCapturing)
            }

            HStack(spacing: 12) {
                Button("Capture at monitor") { survey.beginVisit(.monitor) }
                    .disabled(survey.ear == nil || survey.isCapturing || !quietZoneRunning)
                Button("Capture at ear") { survey.beginVisit(.ear) }
                    .disabled(!survey.monitorCaptured || survey.isCapturing || !quietZoneRunning)
                if survey.isCapturing {
                    ProgressView(value: Double(survey.progress), total: Double(QuietZoneVirtualMicSurveyController.windowsPerVisit))
                        .frame(width: 120)
                    Button("Cancel") { survey.cancelVisit() }
                }
                Spacer()
                if !survey.tones.isEmpty {
                    Button("Discard survey") { survey.discardSurvey() }
                }
            }

            if !quietZoneRunning {
                Text("Turn Quiet Zone on first: the survey reads the noise against its locked tone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(survey.message)
                .font(.callout)
                .foregroundStyle(.secondary)

            if !survey.tones.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["Tone", "Ear vs monitor", "Authority at ear"], id: \.self) {
                            Text($0).font(.caption.bold()).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(survey.tones) { tone in
                        GridRow {
                            Text(String(format: "%.1f Hz", tone.frequencyHz))
                            Text(String(format: "%+.1f dB, %.0f°", tone.ratio.magnitudeDB, tone.ratio.phaseRadians * 180 / .pi))
                            Text(String(format: "%.1f dB", tone.effectiveSecondary.magnitudeDB))
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                Toggle("Quiet the ear position", isOn: $survey.useAtEar)
                    .disabled(survey.isCapturing)
                Text("Tones not in this survey keep the monitor-microphone design. Redo the survey after the noise or the speakers change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
