import SwiftUI

/// E4 S28: what the room's noise would allow Quiet Zone to do, stated plainly. Measurement only;
/// nothing here plays anything. Shown when flag `e4.noise-survey` is on.
struct ProductionNoiseSurveyCard: View {
    @ObservedObject var survey: QuietZoneNoiseSurveyController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Noise Survey")
                .font(.headline)
            if let report = survey.report {
                ForEach(Array(report.statements.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout)
                }
                let unit = survey.isCalibratedToSPL ? "dB" : "dB (relative, microphone not calibrated)"
                Text(String(
                    format: "Estimated loudness %.1f sone, %.0f dBA, %.0f dBC; with predicted reductions %.1f sone (%@).",
                    report.before.loudnessSone, report.before.dBA, report.before.dBC,
                    report.predictedAfter.loudnessSone, unit))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !survey.isCalibratedToSPL {
                    Text("Set the microphone's SPL calibration for absolute dBA and dBC figures.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(QuietZoneNoiseSurvey.nearFieldGuidance, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Listening to the room (\(survey.snapshotCount) of \(QuietZoneNoiseSurveyAccumulator.minimumCount) readings). Start ambient monitoring with the error microphone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
