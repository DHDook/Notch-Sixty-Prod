import Combine
import Foundation

/// E4 S27: the zone chooser. Picks what the quiet zone covers: one fixed seat, one zone that follows the head, or two
/// zones (both sides of a bed). Control plane only; it never arms anything and is never read by the arm path except
/// through the earned-cap binding (a change of mode starts the output again at -40 dBFS).
///
/// Zone A is the ear survey the `QuietZoneVirtualMicSurveyController` already holds; zone B is `second`, a second ear
/// survey taken the same way. Every other surveyed Room Correction position is an S16 other-seat point in the plan.
@MainActor
final class QuietZoneZoneController: ObservableObject {
    @Published private(set) var mode: QuietZoneZoneMode = .fixedSeat
    @Published private(set) var message = "One seat, as before."
    /// Zone B's survey (zone A is the ear survey on the Quiet Zone card).
    let second = QuietZoneVirtualMicSurveyController()

    /// Set by the controller.
    var firstSurvey: () -> QuietZoneVirtualMicSurveyController? = { nil }
    var headFollowReady: () -> Bool = { false }
    var surveyedPointIDs: () -> [UUID] = { [] }
    /// Called after the mode changed, so an armed canceller can disarm (the S20 binding changed).
    var onModeChanged: (() -> Void)?

    /// Why a mode cannot be chosen now; nil when it can.
    func unavailableReason(_ candidate: QuietZoneZoneMode) -> String? {
        switch candidate {
        case .fixedSeat:
            return nil
        case .follow:
            guard let first = firstSurvey(), first.isActive else {
                return "Survey an ear position and switch on “Quiet the ear position” first."
            }
            return headFollowReady() ? nil : "Switch on “Follow my head with the camera” and save at least two seats first."
        case .twoZones:
            guard let first = firstSurvey(), first.isActive else {
                return "Survey the first zone (an ear position) and switch on “Quiet the ear position” first."
            }
            guard second.isActive else { return "Survey the second zone and switch it on first." }
            guard first.ear?.id != second.ear?.id else { return "Choose a different position for the second zone." }
            return nil
        }
    }

    @discardableResult
    func setMode(_ candidate: QuietZoneZoneMode) -> Bool {
        if let why = unavailableReason(candidate) {
            message = why
            return false
        }
        guard candidate != mode else { return true }
        mode = candidate
        message = Self.describe(candidate)
        onModeChanged?()
        return true
    }

    /// A survey or head-follow change that no longer supports the current mode drops back to one fixed seat.
    func revalidate() {
        guard mode != .fixedSeat, unavailableReason(mode) != nil else { return }
        mode = .fixedSeat
        message = "A zone survey changed, so Quiet Zone is back to one seat."
        onModeChanged?()
    }

    /// Plan of zone and other-seat points for the current mode, nil in fixed-seat mode or when a zone has no position.
    var plan: QuietZoneZonePlan? {
        let ids: [UUID]
        switch mode {
        case .fixedSeat: return nil
        case .follow: ids = firstSurvey()?.ear.map { [$0.id] } ?? []
        case .twoZones: ids = [firstSurvey()?.ear?.id, second.ear?.id].compactMap { $0 }
        }
        return try? QuietZoneZonePlan(mode: mode, surveyedPointIDs: surveyedPointIDs(), zonePointIDs: ids)
    }

    /// The zone B ear tone near a controlled frequency, for the 2 x 2 design.
    func secondTone(near frequencyHz: Double) -> QuietZoneEarTone? { second.earTone(near: frequencyHz) }

    /// The zone A ear tone (the fixed survey; two zones do not follow the head).
    func firstTone(near frequencyHz: Double) -> QuietZoneEarTone? {
        guard let first = firstSurvey(), first.isActive,
              let nearest = first.tones.min(by: {
                  abs($0.frequencyHz - frequencyHz) < abs($1.frequencyHz - frequencyHz)
              }),
              abs(nearest.frequencyHz - frequencyHz) <= 0.5 else { return nil }
        return nearest
    }

    static func describe(_ mode: QuietZoneZoneMode) -> String {
        switch mode {
        case .fixedSeat: return "One seat, as before."
        case .follow: return "One zone that follows your head between the seats you saved."
        case .twoZones: return "Two zones. Output restarts at the starting level when you turn Quiet Zone on again."
        }
    }
}
