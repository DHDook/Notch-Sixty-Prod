import Foundation
import SwiftUI

/// E33 S2 (design 9): what a VoiceOver action on a graph handle does. The adjustable action moves the
/// frequency one `EQNudge` step per increment (the same table as the arrow keys); the named actions move the
/// gain, and the two coarse ones move 3 dB (the Shift step). Clamping is the nudge rule's, so an action can
/// never leave the range the engine accepts.
enum EQHandleAccessibility {
    enum GainAction: String, CaseIterable, Sendable {
        case up = "Raise gain"
        case down = "Lower gain"
        case coarseUp = "Raise gain by 3 dB"
        case coarseDown = "Lower gain by 3 dB"
    }

    static func frequency(
        _ band: EQBand, direction: EQNudge.Direction, maximumFrequency: Double
    ) -> EQBand {
        guard band.type != .fir else { return band }
        var edited = band
        edited.frequencyHz = EQNudge.nudged(
            band.frequencyHz, field: .frequency, direction: direction, step: EQNudge.Step(shift: false, option: false),
            band: band, maximumFrequency: maximumFrequency)
        return edited
    }

    static func gain(_ band: EQBand, action: GainAction, maximumFrequency: Double) -> EQBand {
        guard band.type.productionHasGainControl else { return band }
        var edited = band
        let coarse = action == .coarseUp || action == .coarseDown
        let direction: EQNudge.Direction = (action == .up || action == .coarseUp) ? .up : .down
        edited.gainDB = EQNudge.nudged(
            band.gainDB, field: .gain, direction: direction, step: EQNudge.Step(shift: coarse, option: false),
            band: band, maximumFrequency: maximumFrequency)
        return edited
    }

    /// "1,000 Hz, +3.0 dB" for the handle's accessibility value.
    static func valueText(_ band: EQBand) -> String {
        band.type.productionHasGainControl
            ? "\(EQBandPanelModel.frequencyText(band.frequencyHz)), \(EQBandPanelModel.gainText(band.gainDB))"
            : EQBandPanelModel.frequencyText(band.frequencyHz)
    }

    // MARK: Gesture hint (once per install)

    static let hintShownKey = "eq.graphGestureHintShown"
    static let hintText = "Scroll for Q, hold Option to listen"

    static func shouldShowHint(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: hintShownKey)
    }

    static func markHintShown(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: hintShownKey)
    }
}

/// The VoiceOver surface of one graph handle (E33 S2, design 9): its value, a frequency adjustable action and
/// the named gain actions. Applied only when `e33.page-enhancements` is on.
struct EQHandleAccessibilityActions: ViewModifier {
    let enabled: Bool
    let band: EQBand
    let onAdjustFrequency: (EQNudge.Direction) -> Void
    let onAdjustGain: (EQHandleAccessibility.GainAction) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityValue(EQHandleAccessibility.valueText(band))
                .accessibilityHint("Adjust to change frequency. Use the actions rotor to change gain.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onAdjustFrequency(.up)
                    case .decrement: onAdjustFrequency(.down)
                    @unknown default: break
                    }
                }
                .accessibilityAction(named: EQHandleAccessibility.GainAction.up.rawValue) { onAdjustGain(.up) }
                .accessibilityAction(named: EQHandleAccessibility.GainAction.down.rawValue) { onAdjustGain(.down) }
                .accessibilityAction(named: EQHandleAccessibility.GainAction.coarseUp.rawValue) { onAdjustGain(.coarseUp) }
                .accessibilityAction(named: EQHandleAccessibility.GainAction.coarseDown.rawValue) { onAdjustGain(.coarseDown) }
        } else {
            content
        }
    }
}
