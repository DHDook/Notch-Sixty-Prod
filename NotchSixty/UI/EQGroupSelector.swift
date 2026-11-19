import SwiftUI

/// E33 S20 part 2 (G39): the Equalizer page's group selector. "All" is the session's own EQ; each speaker group the
/// layout has carries one more list on top of it. The pure model decides what the chips say and which are usable, so a
/// test can check it without a view. Control plane only; nothing here touches the audio thread.
struct EQGroupSelectorModel: Equatable {
    struct Item: Identifiable, Equatable {
        /// nil is "All".
        var group: EQChannelGroup?
        var title: String
        var enabled: Bool
        var selected: Bool
        /// The reason a chip is unavailable, or "" when it is usable.
        var unavailableReason: String
        var id: String { group?.rawValue ?? "all" }
    }

    var items: [Item]
    /// One line under the chips: what the selected group does, or why a chip is off. Nil under All.
    var note: String?

    /// Chips for `shape`'s layout: All, then only the groups the layout has. Empty on a stereo session. In Mid/Side the
    /// groups on a left/right pair are unavailable (their lanes carry the encoded signal); Centre and LFE stay.
    static func make(
        configuration: StereoEQConfiguration, shape: UnifiedGraphLayoutShape?, sampleRate: Double
    ) -> EQGroupSelectorModel {
        guard let shape, shape.laneCount > 2 else { return EQGroupSelectorModel(items: [], note: nil) }
        let codes = shape.roleCodes
        let chosen = configuration.editGroup(roleCodes: codes)
        var items = [Item(group: nil, title: "All", enabled: true, selected: chosen == nil, unavailableReason: "")]
        for group in EQChannelGroup.available(roleCodes: codes) {
            let blocked = configuration.channelMode == .midSide && !group.isUnpaired(shape: shape)
            let count = configuration.groupBands(group, roleCodes: codes).filter(\.enabled).count
            items.append(Item(
                group: group, title: count > 0 ? "\(group.displayName) (\(count))" : group.displayName,
                enabled: !blocked, selected: chosen == group,
                unavailableReason: blocked
                    ? "Mid/Side applies to left/right pairs, so \(group.displayName) cannot have its own list. Use Linked or Independent."
                    : ""))
        }
        var note: String?
        if let chosen {
            let boost = configuration.groupPeakBoostDB(chosen, roleCodes: codes, sampleRate: sampleRate)
            let lanes = chosen.lanes(roleCodes: codes).count
            note = "\(chosen.displayName) EQ runs on \(lanes) channel\(lanes == 1 ? "" : "s"), after the All curve."
                + (boost >= 0.05 ? String(format: " Adds up to +%.1f dB.", boost) : "")
                + " Ordinary filters only; the response graph shows this list alone."
        }
        return EQGroupSelectorModel(items: items, note: note)
    }
}

struct EQGroupSelector: View {
    let model: EQGroupSelectorModel
    let choose: (EQChannelGroup?) -> Void

    var body: some View {
        if !model.items.isEmpty {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text("SPEAKER GROUP")
                    .font(DesignType.caption.font.bold())
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                HStack(spacing: DesignSpacing.s.pt) {
                    ForEach(model.items) { item in
                        Button { choose(item.group) } label: {
                            Text(item.title)
                        }
                        .buttonStyle(.glass)
                        .tint(item.selected ? .accentColor : nil)
                        .disabled(!item.enabled)
                        .help(item.unavailableReason.isEmpty ? "Edit \(item.title)" : item.unavailableReason)
                        .accessibilityLabel(item.title)
                        .accessibilityValue(item.selected ? "Selected" : "")
                        .accessibilityAddTraits(item.selected ? .isSelected : [])
                        .accessibilityIdentifier("eq.group.\(item.id)")
                    }
                }
                if let note = model.note {
                    Text(note)
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("eq.group.note")
                }
            }
        }
    }
}
