import SwiftUI

/// E12 S20 (flag `e12.active-acoustics-page`): a plain result line, a short history and a hold-to-compare button for
/// one Active Acoustics tab. The button only reports press and release; the tab's controller decides how the effect
/// fades (the existing fade paths), and nothing here arms or disarms anything.
struct ProductionAcousticsResultCard: View {
    var lines: [AcousticsResultLine]
    var emptyText: String
    var history: [AcousticsResultHistory.Entry]
    /// Nil hides the compare button (a tab with no safe compare path says why in `compareNote`).
    var compare: CompareControl?
    var compareNote: String?

    struct CompareControl {
        var isHeld: Bool
        /// Why compare is unavailable now; nil when it can be used.
        var unavailableReason: String?
        var setHeld: (Bool) -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { resultText; Spacer(minLength: 12); compareControl }
                VStack(alignment: .leading, spacing: 10) { resultText; compareControl }
            }
            if history.count > 1 {
                DisclosureGroup("Earlier results") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(history.dropLast().reversed()) { entry in
                            Text("\(SessionEventText.time(entry.time)) · \(entry.line.displayText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var resultText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Result").font(.caption.bold()).foregroundStyle(.secondary)
            if lines.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(lines) { line in
                    Text(line.displayText).font(.headline)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var compareControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let compare {
                ProductionHoldToCompareButton(
                    isHeld: compare.isHeld, disabledReason: compare.unavailableReason, setHeld: compare.setHeld)
                if let reason = compare.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(compare.isHeld ? "Effect is off while you hold." : "Hold to hear it without the effect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let compareNote {
                Text(compareNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Press and hold; the effect returns on release. VoiceOver gets a toggle, since holding is not practical there.
struct ProductionHoldToCompareButton: View {
    var isHeld: Bool
    var disabledReason: String?
    var setHeld: (Bool) -> Void

    var body: some View {
        Label(isHeld ? "Comparing: effect off" : "Hold to compare", systemImage: isHeld ? "ear.badge.waveform" : "ear")
            .font(.callout.bold())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isHeld ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15), in: Capsule())
            .opacity(disabledReason == nil ? 1 : 0.5)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if disabledReason == nil, !isHeld { setHeld(true) } }
                    .onEnded { _ in setHeld(false) })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hold to compare")
            .accessibilityValue(isHeld ? "Effect off" : "Effect on")
            .accessibilityHint(disabledReason ?? "Switches the effect off while held, then back on.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if disabledReason == nil { setHeld(!isHeld) } }
    }
}
