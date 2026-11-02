import SwiftUI

/// E24 S2: the reason text every disabled measure button shows, plus the notice that a measure
/// path stopped playback. Shared by the setup wizard, Room Correction, multichannel calibration
/// and the Speaker Lab.
struct MeasurementReadinessNote: View {
    let readiness: MeasurementReadiness
    var playbackNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reason = readiness.reason {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("measurement.readiness.reason")
            }
            if let playbackNotice {
                Label(playbackNotice, systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("measurement.playback.notice")
            }
        }
    }
}


/// E24 S4: how many sweeps are played and averaged with rejection. Shared by the setup wizard and
/// Room Correction; the multichannel campaign reads the same setting.
struct SweepRepeatPicker: View {
    @Binding var repeatCount: Int
    var disabled = false

    var body: some View {
        Picker("Repeats", selection: $repeatCount) {
            ForEach(RoomCorrectionSweepSettings.allowedRepeatCounts, id: \.self) { count in
                Text(count == 1 ? "1 (no averaging)" : "\(count)").tag(count)
            }
        }
        .fixedSize()
        .disabled(disabled)
        .help("Each sweep is played this many times and averaged. Repeats that disagree are rejected. More repeats take longer and lower the noise.")
    }
}

/// One caption line under a measurement result: "3 of 4 repeats kept; repeat 2 rejected (low coherence)".
struct RepeatSummaryNote: View {
    let quality: RoomCorrectionMeasurementQuality

    var body: some View {
        if let summary = quality.repeatSummary {
            Text(summary)
                .font(.caption)
                .foregroundStyle((quality.rejectedRepeats ?? []).isEmpty ? Color.secondary : Color.orange)
        }
    }
}
