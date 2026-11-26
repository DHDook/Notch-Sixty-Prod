import Foundation

/// E23 S4 part 4 (G20): the speaker-drive demand, the anchor fan-out, the live-driver feature switch and the analyser
/// tap switch of `AudioIOEngine`. Fields are `private(set)`; the demand and fan-out change only through these methods.
///
/// Main actor only. Never touched from an audio callback.
@MainActor
@Observable
final class SpeakerDriveState {
    /// Set from `e4.feedforward-live`; while false nothing ever sets the demand.
    @ObservationIgnored private(set) var featureEnabled = false
    @ObservationIgnored private(set) var demandMux = SpeakerDriveDemandMux()
    @ObservationIgnored private(set) var anchorFanout = SpeakerDriveAnchorFanout()
    /// Whether stereo graphs carry the Equalizer analyser taps.
    private(set) var analyserTapsInstalled = false

    func setFeatureEnabled(_ value: Bool) { featureEnabled = value }
    func setShadowDemand(_ requested: Bool) { demandMux.shadow = requested }
    func setPumpDemand(_ requested: Bool) { demandMux.pump = requested }
    func setAnalyserTapsInstalled(_ value: Bool) { analyserTapsInstalled = value }
    func resetAnchorFanout() { anchorFanout.reset() }

    /// The anchor ring has one consumer; this gives the shadow and the live pump each anchor once.
    func pull(_ anchors: [N60SpeakerDriveAnchor], for consumer: SpeakerDriveAnchorFanout.Consumer) -> [N60SpeakerDriveAnchor] {
        anchorFanout.ingest(anchors)
        return anchorFanout.drain(consumer)
    }
}

extension AudioIOEngine {
    var speakerDriveFeatureEnabled: Bool { speakerDrive.featureEnabled }
    var speakerDriveDemandMux: SpeakerDriveDemandMux { speakerDrive.demandMux }
    var analyserTapsInstalled: Bool { speakerDrive.analyserTapsInstalled }

    /// Set once at launch from `e4.feedforward-live` by the app shell.
    func setSpeakerDriveFeatureEnabled(_ enabled: Bool) { speakerDrive.setFeatureEnabled(enabled) }
}
