import AppKit
import Combine
import Foundation

/// E15 S7: the production pieces of the schedule that `ProductController` builds once, only while `e15.follow-output`
/// is on (flag off constructs no scheduler). No `Unconnected*` defaults.

/// The real host: content-preset selection goes through `ProductController.selectContentPreset(_:keeping:)`, the same
/// path as a manual pick. It has no method that changes the output, the Playback System or an arm (Q3).
@MainActor
final class ProductScheduleHost: ScheduleContentHost {
    private let profiles: ProductProfileController
    /// Set by `ProductController` once it is initialised.
    var select: ((UUID) async throws -> Void)?

    init(profiles: ProductProfileController) { self.profiles = profiles }

    var selectedContentPresetID: UUID? { profiles.selectedContentPresetID }
    var selectedSystemProfileID: UUID? { profiles.selectedSystemProfileID }
    var hasUnsavedContentEdits: Bool { profiles.selectedContentPresetIsDirty }

    func contentPresetName(_ id: UUID) -> String? {
        profiles.contentPresets.first { $0.id == id }?.name
    }

    func selectContentPreset(_ id: UUID) async throws {
        try await select?(id)
    }
}

@MainActor
enum ProfileSchedulerWiring {
    /// Builds the scheduler, or nil while the flag is off. The returned observers (notifications, block-end signals)
    /// live as long as `ProductController`.
    static func make(
        flagEnabled: Bool,
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        recovery: ProductRecoveryController,
        calibration: RoomCorrectionCalibrationController,
        multichannel: MultichannelCalibrationController,
        hardwareAcceptance: HardwareAcceptanceController? = nil,
        host: ProductScheduleHost
    ) -> (scheduler: ProfileScheduler, observers: [AnyObject])? {
        guard flagEnabled else { return nil }
        let external = OutputFollowWiring.externalBlocks(
            recovery: recovery, calibration: calibration, multichannel: multichannel, hardwareAcceptance: hardwareAcceptance)
        let scheduler = ProfileScheduler(
            profiles: profiles, host: host,
            blocks: { [weak engine] in
                var blocks = external()
                if engine?.lifecycleState == .failed { blocks.insert(.engineFailed) }
                return blocks
            })

        var observers: [AnyObject] = []
        let send: (ScheduleEvent) -> Void = { [weak scheduler] event in
            Task { @MainActor in await scheduler?.handle(event) }
        }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let tokens: [(NotificationCenter, Notification.Name, ScheduleEvent)] = [
            (workspace, NSWorkspace.didWakeNotification, .wake),
            (center, .NSSystemClockDidChange, .clockChanged),
            (center, .NSSystemTimeZoneDidChange, .timeZoneChanged),
        ]
        for (source, name, event) in tokens {
            observers.append(source.addObserver(forName: name, object: nil, queue: .main) { _ in send(event) } as AnyObject)
        }
        // A block ending applies the boundary it deferred (the same signals follow mode watches).
        observers.append(ObservationSubscription(
            value: { engine.lifecycleState },
            onChange: { state in if state != .failed { send(.blockEnded) } }))
        let ended: (AnyCancellable) -> Void = { observers.append($0) }
        ended(calibration.$state.dropFirst().sink { _ in send(.blockEnded) })
        ended(multichannel.$state.dropFirst().sink { _ in send(.blockEnded) })
        if let hardwareAcceptance { ended(hardwareAcceptance.$pageOpen.dropFirst().sink { _ in send(.blockEnded) }) }
        ended(recovery.objectWillChange.sink { _ in send(.blockEnded) })
        return (scheduler, observers)
    }
}
