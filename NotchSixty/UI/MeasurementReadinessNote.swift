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
