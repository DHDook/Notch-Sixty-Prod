import Combine
import Foundation

/// E15 S6 (closes E13 G27): when an output device becomes the selected output, by a followed switch, a manual pick, the
/// remote panel or setup, select the headphone entry linked to it (`HeadphoneList.entry(linkedTo:)`).
///
/// The change goes through `editSelectedSystemHeadphoneList`, the E13 S10 path: a live edit where the planner allows it,
/// a faded reconfigure otherwise, with the engine and the stored list rolled back together on failure. An unlinked device
/// leaves the selection alone; an entry that is already selected causes no edit and no reconfigure. Nothing here arms
/// anything or touches the output. Main actor, control plane only. Behind `e15.follow-output`.

/// What the selector needs from the Playback System store.
@MainActor
protocol LinkedHeadphoneProfiles: AnyObject {
    /// E15 S4 (G18): the selected Playback System; a change re-checks the linked entry.
    var selectedSystemProfileIDPublisher: AnyPublisher<UUID?, Never> { get }
    /// The selected system's headphone list; nil when it has none.
    var selectedSystemHeadphoneList: HeadphoneList? { get }
    func editSelectedSystemHeadphoneList(_ change: (inout HeadphoneList) throws -> Void) throws
}

extension ProductProfileController: LinkedHeadphoneProfiles {
    var selectedSystemProfileIDPublisher: AnyPublisher<UUID?, Never> { $selectedSystemProfileID.eraseToAnyPublisher() }
}

@MainActor
final class LinkedHeadphoneSelector {
    enum Outcome: Equatable {
        case flagOff
        /// No entry names this device, or the system has no list.
        case notLinked
        /// The linked entry is already the selected one: nothing was done.
        case alreadySelected(UUID)
        case selected(UUID)
        case failed(String)
    }

    private let profiles: any LinkedHeadphoneProfiles
    private let flagEnabled: @MainActor () -> Bool
    private(set) var lastOutcome: Outcome?
    /// Set when an edit failed; the headphone page shows it.
    private(set) var lastError: String?

    init(profiles: any LinkedHeadphoneProfiles, flagEnabled: (@MainActor () -> Bool)? = nil) {
        self.profiles = profiles
        self.flagEnabled = flagEnabled ?? { FeatureFlags().isEnabled(.followOutput) }
    }

    /// Call when `uid` became the selected output (after any bound system is applied).
    @discardableResult
    func outputBecameSelected(_ uid: String?) -> Outcome {
        let outcome = decide(uid)
        lastOutcome = outcome
        return outcome
    }

    /// Watches the engine's selected output and calls `outputBecameSelected` one hop after each change (so a followed
    /// switch has applied its bound system first). The starting value is not delivered. Keep the result alive.
    func observeOutput(of engine: AudioIOEngine) -> ObservationSubscription {
        ObservationSubscription(
            value: { engine.routeConfiguration.selectedOutputUID },
            onChange: { [weak self] uid in self?.outputBecameSelected(uid) })
    }

    /// E15 S4 (G18): the user switched Playback System with the output unchanged; the new system's list may link the
    /// current output. One hop later, after the system has been applied. Keep the result alive.
    func observeSystemChange(of engine: AudioIOEngine) -> AnyCancellable {
        profiles.selectedSystemProfileIDPublisher.dropFirst().removeDuplicates()
            .sink { [weak self, weak engine] _ in
                DispatchQueue.main.async {
                    _ = MainActor.assumeIsolated { self?.outputBecameSelected(engine?.routeConfiguration.selectedOutputUID) }
                }
            }
    }

    private func decide(_ uid: String?) -> Outcome {
        guard flagEnabled() else { return .flagOff }
        guard let uid, let list = profiles.selectedSystemHeadphoneList, let entry = list.entry(linkedTo: uid) else {
            return .notLinked
        }
        if list.selectedID == entry.id { return .alreadySelected(entry.id) }
        do {
            lastError = nil
            try profiles.editSelectedSystemHeadphoneList { try $0.select(entry.id) }
            return .selected(entry.id)
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }
}
