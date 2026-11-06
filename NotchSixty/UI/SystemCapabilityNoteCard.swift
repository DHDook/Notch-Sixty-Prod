import SwiftUI

/// E25 S5: what the selected system's arrangement allows for the features a surface offers, from
/// `SystemCapabilityMatrix`. Empty (and so invisible) when the system has no arrangement.
struct SystemCapabilityNoteCard: View {
    let title: String
    let features: [SystemFeature]
    @ObservedObject var profiles: ProductProfileController
    var deviceChannelCount: Int = 0
    /// Adds the arrangement sentence and receiver advice (room advisor, profile summary).
    var includeArrangement = false

    private var rows: [SystemCapabilityText.Row] {
        SystemCapabilityText.rows(
            features, profile: profiles.selectedSystemProfile,
            deviceChannelCount: deviceChannelCount, subAwareQuietZone: FeatureFlags().isEnabled(.subAwareAnc))
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if includeArrangement,
                   let a = SystemCapabilityText.arrangement(for: profiles.selectedSystemProfile, deviceChannelCount: deviceChannelCount) {
                    Text(SystemCapabilityText.arrangementSentence(a)).font(.caption).foregroundStyle(.secondary)
                    if a.bass.isDownstream {
                        Text(SystemCapabilityMatrix.receiverAdvice).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: row.availability.isUsable ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(row.availability.isUsable ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.feature.displayName).font(.callout)
                            Text(row.availability.text).font(.caption).foregroundStyle(.secondary)
                            if case .unavailable(_, let fix?) = row.availability {
                                Text(fix).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
