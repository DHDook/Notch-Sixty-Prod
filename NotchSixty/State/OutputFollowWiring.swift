import AppKit
import Combine
import Foundation

/// E15 S3: the production pieces of Follow macOS output that `ProductController` builds once (no `Unconnected*`
/// defaults): the treatment disarmer over the real arm switches, the excluded-state signals and the Core Audio source.

/// Disarms Quiet Zone, feed-forward and MIMO room treatment before a followed switch tears the transport down. It only
/// ever disarms; arming stays the user's action through its written authorisation path.
@MainActor
final class ProductTreatmentDisarmer: OutputFollowTreatmentDisarming {
    private let quietZone: ActiveQuietZoneController
    private let feedForward: FeedForwardLiveArmingController?
    private let mimo: MIMOTreatmentController

    init(quietZone: ActiveQuietZoneController, feedForward: FeedForwardLiveArmingController?, mimo: MIMOTreatmentController) {
        self.quietZone = quietZone
        self.feedForward = feedForward
        self.mimo = mimo
    }

    func disarmAllForOutputFollow() -> [String] {
        var names: [String] = []
        if quietZone.arm.isArmed {
            names.append("Quiet Zone")
            quietZone.arm.disarm(.outputFollowed)
        }
        if feedForward?.isRequested == true {
            names.append("Feed-forward")
            feedForward?.quietZoneStopped()
        }
        mimo.refreshReadout()
        if mimo.isArmed {
            names.append("Room Treatment")
            mimo.bypass()
        }
        return names
    }
}

@MainActor
enum OutputFollowWiring {
    /// The excluded states other than a failed engine (note 11): Safe Launch and a room capture. E15 S7 schedules reuse
    /// the same signals.
    static func externalBlocks(
        recovery: ProductRecoveryController, calibration: RoomCorrectionCalibrationController,
        multichannel: MultichannelCalibrationController
    ) -> () -> Set<OutputFollowBlock> {
        { [weak recovery, weak calibration, weak multichannel] in
            var blocks: Set<OutputFollowBlock> = []
            if recovery?.safeLaunchActive == true { blocks.insert(.safeLaunch) }
            if let state = calibration?.state, [.arming, .measuring, .analyzing].contains(state) {
                blocks.insert(.measurementCapture)
            }
            if let state = multichannel?.state, [.measuring, .analyzing].contains(state) {
                blocks.insert(.measurementCapture)
            }
            return blocks
        }
    }

    /// Builds the production coordinator and the observers that end an excluded state (note 11): Safe Launch, a room
    /// capture, a failed engine. Held by the returned bag, which `ProductController` keeps for its lifetime.
    static func make(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        recovery: ProductRecoveryController,
        calibration: RoomCorrectionCalibrationController,
        multichannel: MultichannelCalibrationController,
        quietZone: ActiveQuietZoneController,
        feedForward: FeedForwardLiveArmingController?,
        mimo: MIMOTreatmentController
    ) -> (coordinator: OutputFollowCoordinator, observers: [AnyObject]) {
        let coordinator = OutputFollowCoordinator(
            engine: engine,
            profiles: profiles,
            treatments: ProductTreatmentDisarmer(quietZone: quietZone, feedForward: feedForward, mimo: mimo),
            source: CoreAudioFollowOutputEventSource(),
            externalBlocks: Self.externalBlocks(recovery: recovery, calibration: calibration, multichannel: multichannel),
            displayName: { [weak engine] uid in engine?.outputDevices.first { $0.uid == uid }?.name ?? uid })

        // E15 S3b: macOS notifications. The notification center is touched only outside a test host.
        let notifier = UserNotificationFollowNotifier()
        let notifications = FollowNotificationController(
            notifier: notifier, isActive: { [weak coordinator] in coordinator?.isFollowing ?? false })
        coordinator.notifications = notifications
        if !ProductProcessEnvironment.isHostingTests { notifier.installResponseHandling() }

        profiles.ignoresAssociatedOutput = { [weak coordinator] in coordinator?.isFollowing ?? false }

        // An excluded state ending applies the pending default (note 11). Each signal just asks again; the policy
        // defers again while any block is still active.
        var observers: [AnyObject] = [notifier]
        observers.append(ObservationSubscription(
            value: { engine.lifecycleState },
            onChange: { [weak coordinator] state in if state != .failed { coordinator?.exclusionEnded() } }))
        // E15 S6 (E13 G27): any change of the selected output (followed, manual, remote, setup) selects the headphone entry
        // linked to the new device, one hop later so a followed switch has applied its bound system first.
        let linked = LinkedHeadphoneSelector(profiles: profiles)
        observers.append(linked)
        observers.append(linked.observeOutput(of: engine))
        let ended: (AnyCancellable) -> Void = { observers.append($0) }
        ended(calibration.$state.dropFirst().sink { [weak coordinator] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { coordinator?.exclusionEnded() } }
        })
        ended(multichannel.$state.dropFirst().sink { [weak coordinator] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { coordinator?.exclusionEnded() } }
        })
        ended(recovery.objectWillChange.sink { [weak coordinator] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { coordinator?.exclusionEnded() } }
        })
        ended(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { _ in
            MainActor.assumeIsolated { notifications.refreshInBackground() }
        })
        return (coordinator, observers)
    }
}
