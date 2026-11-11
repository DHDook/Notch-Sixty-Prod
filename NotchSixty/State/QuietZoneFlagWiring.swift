import AppKit
import Foundation

/// E4 S32: how the Quiet Zone feature flags turn into engine switches and attached controllers. `ProductController.init()`
/// calls these, and `E4GraduationTests` calls the same functions with a release-style flag store, so the graduated
/// configuration is tested as shipped. Nothing here arms anything: `LiveTreatmentArm` stays off until the user's Turn On.
@MainActor
enum QuietZoneFlagWiring {
    /// Sets the engine's flag-gated switches. Returns whether the adaptive tonal canceller is available (it needs the lease).
    @discardableResult
    static func configureEngine(_ engine: AudioIOEngine, flags: FeatureFlags) -> Bool {
        engine.activeQuietZoneLeaseEnabled = flags.isEnabled(.ancEngineLease)
        // E4 S18b: the adaptive tonal canceller needs the lease; with either flag off the engine
        // stamps no arm token and the gain mailbox stays shut.
        let adaptiveTonalLive = flags.isEnabled(.adaptiveTonalLive) && engine.activeQuietZoneLeaseEnabled
        engine.adaptiveTonalMailboxEnabled = adaptiveTonalLive
        // E4 S22b1: only this flag lets the speaker-drive recording be requested at all.
        engine.speakerDriveFeatureEnabled = flags.isEnabled(.feedForwardLive)
        return adaptiveTonalLive
    }

    /// E4 S26b: head follow needs the ear survey it chooses between, so it exists only with both flags on. The camera is
    /// not touched until the listener switches head follow on.
    static func attachHeadFollow(
        to survey: QuietZoneVirtualMicSurveyController?,
        flags: FeatureFlags,
        source: @escaping QuietZoneHeadFollowController.SourceFactory,
        clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        appCenter: NotificationCenter = .default
    ) {
        guard flags.isEnabled(.headPositionCamera), let survey else { return }
        survey.attachHeadFollow(QuietZoneHeadFollowController(
            makeSource: source, clock: clock, workspaceCenter: workspaceCenter, appCenter: appCenter))
    }

    static func attachControllers(
        to activeQuietZone: ActiveQuietZoneController,
        engine audioEngine: AudioIOEngine,
        ambient ambientCompensation: AmbientCompensationController,
        roomProjects: RoomCorrectionProjectController,
        adaptiveTonalLive: Bool,
        flags: FeatureFlags,
        headPoseSource: @escaping QuietZoneHeadFollowController.SourceFactory = QuietZoneHeadFollowController.cameraSourceFactory()
    ) {
        if adaptiveTonalLive {
            activeQuietZone.attachAdaptiveLive(AdaptiveTonalLiveCoordinator(
                ambient: ambientCompensation,
                linkProvider: { [weak audioEngine] in audioEngine?.adaptiveTonalLink }
            ))
        }
        if flags.isEnabled(.noiseSurvey) {
            let survey = QuietZoneNoiseSurveyController()
            survey.attach(to: ambientCompensation)
            activeQuietZone.attachNoiseSurvey(survey)
        }
        if flags.isEnabled(.virtualMicrophone) {
            activeQuietZone.attachVirtualMicrophone(QuietZoneVirtualMicSurveyController())
        }
        attachHeadFollow(to: activeQuietZone.virtualMic, flags: flags, source: headPoseSource)
        if flags.isEnabled(.overnight) {
            activeQuietZone.attachOvernightPower(OvernightPowerAssertion())
        }
        if adaptiveTonalLive, flags.isEnabled(.earnedCap) {
            activeQuietZone.attachEarnedCap(EarnedCapPolicy(store: EarnedCapStore()))
            // E4 S21: limits from the Room Correction aggregate's -10 dB point
            // (`ExcursionLimits.lowerLimitHz`), the bass-management crossover and the speaker's role.
            activeQuietZone.attachExcursionCap { [weak audioEngine, weak roomProjects] in
                let bass = audioEngine?.bassManagementConfiguration
                return ExcursionLimits.resolve(
                    aggregate: roomProjects?.aggregate,
                    subwooferEnabled: bass?.enabled == true,
                    crossoverHz: bass?.frequencyHz ?? 80
                )
            }
        }
    }
}
