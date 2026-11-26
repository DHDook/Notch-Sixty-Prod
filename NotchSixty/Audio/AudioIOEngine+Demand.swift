import CoreAudio
import Foundation

// E23 S4 part 3: metering, analyser, ambient and quiet zone reference demand, speaker-drive and feed-forward pass-throughs, moved verbatim from AudioIOEngine.swift (no behaviour change).
extension AudioIOEngine {
    func setDetailedMeteringDemand(_ enabled: Bool) throws {
        if let session = nChannelTransportSession {
            session.setDetailedMeteringDemand(enabled)
            return
        }
        if let session = binauralHeadphoneTransportSession {
            session.setDetailedMeteringDemand(enabled)
            return
        }
        // E28 S6: the per-route meters of a same-device speaker map share the detailed-meter demand.
        N60RealtimeAudioBridgeSetRouteMeterDemand(enabled)
        let previousDemand = N60RealtimeAudioBridgeMeteringDemand()
        guard previousDemand != enabled else { return }

        N60RealtimeAudioBridgeSetMeteringDemand(enabled)
    }

    func setAnalysisDemand(_ demandMask: UInt32) {
        // E28 S6b, E33 S17: wide sessions run the same analysis on the capture ring they own.
        if let session = nChannelTransportSession { session.setAnalysisDemand(demandMask) }
        else if let session = binauralHeadphoneTransportSession { session.setAnalysisDemand(demandMask) }
        else { transportSession?.setAnalysisDemand(demandMask) }
    }

    func setAnalyserTapsInstalled(_ installed: Bool) {
        guard installed != analyserTapsInstalled else { return }
        speakerDrive.setAnalyserTapsInstalled(installed)
        transportSession?.setAnalyserTapsInstalled(installed)
    }

    /// Bit 0 records the EQ tap, bit 1 the after-dynamics tap; 0 releases both.
    func setAnalyserTapDemand(_ mask: UInt8) {
        transportSession?.setAnalyserTapDemand(mask)
    }

    /// True when a tap can be read now: installed, and the core graph (not the kernel) is rendering.
    var analyserTapsAvailable: Bool { transportSession?.analyserTapsAvailable ?? false }

    func analyserTapWindow(afterDynamics: Bool, frames: Int) -> EQAnalyserTapWindow? {
        guard let session = transportSession,
              let window = session.readAnalyserTap(afterDynamics: afterDynamics, frames: frames) else { return nil }
        return EQAnalyserTapWindow(left: window.left, right: window.right, sampleRate: session.outputSampleRate)
    }

    func analysisCaptureSnapshot() -> N60AnalysisCaptureSnapshot? {
        transportSession?.analysisCaptureSnapshot()
    }

    /// E26 S7b2c (G26): true for the stereo session and for a profile session whose graph carries the Quiet Zone feed
    /// (class A); the references come from the live `quietZoneHost` either way.
    var ambientPlaybackReferenceAvailable: Bool {
        (transportSession != nil
            && nChannelTransportSession == nil
            && binauralHeadphoneTransportSession == nil)
            || activeQuietZoneProfileRuntimeAvailable
    }

    var ambientPlaybackReferenceSampleRate: Double? {
        guard ambientPlaybackReferenceAvailable else { return nil }
        return quietZoneHost?.ambientReferenceSampleRate
    }

    func setAmbientPlaybackReferenceDemand(_ enabled: Bool) {
        guard ambientPlaybackReferenceAvailable else {
            quietZoneHost?.setAmbientReferenceDemand(false)
            return
        }
        quietZoneHost?.setAmbientReferenceDemand(enabled)
    }

    func ambientPlaybackReferenceSnapshot()
        -> N60AmbientPlaybackReferenceSnapshot? {
        guard ambientPlaybackReferenceAvailable else { return nil }
        return quietZoneHost?.ambientReferenceSnapshot()
    }

    func discardAmbientPlaybackReferenceFrames() {
        quietZoneHost?.discardAmbientReferenceFrames()
    }

    func readAmbientPlaybackReferenceFrames(
        maximumFrames: Int =
            Int(N60_AMBIENT_REFERENCE_CAPACITY_FRAMES)
    ) -> [N60AmbientPlaybackReferenceFrame] {
        guard ambientPlaybackReferenceAvailable else { return [] }
        return quietZoneHost?.readAmbientReferenceFrames(
            maximumFrames: maximumFrames
        ) ?? []
    }

    func setSpeakerDriveDemand(_ requested: Bool) {
        speakerDrive.setShadowDemand(requested)
        applySpeakerDriveDemand()
    }

    /// E4 S25 follow-up: the live reference pump needs the output anchors.
    func setPumpDriveDemand(_ requested: Bool) {
        speakerDrive.setPumpDemand(requested)
        applySpeakerDriveDemand()
    }

    func applySpeakerDriveDemand() {
        let allowed = SpeakerDriveDemandPolicy.demand(
            requested: speakerDriveDemandMux.requested,
            featureEnabled: speakerDriveFeatureEnabled,
            transportAvailable: ambientPlaybackReferenceAvailable
        )
        quietZoneHost?.setSpeakerDriveDemand(allowed)
    }

    func speakerDriveSnapshot() -> N60SpeakerDriveSnapshot? {
        quietZoneHost?.speakerDriveSnapshot()
    }

    /// E4 S25b: live feed-forward passthroughs. Arm needs the gate's inputs; the app supplies
    /// `liveOutputAuthorized` only from `FeedForwardLiveArmingController` (the user's request).
    func setFeedForwardLiveWeights(left: [Float], right: [Float]) -> Bool {
        speakerDriveFeatureEnabled && (quietZoneHost?.setFeedForwardLiveWeights(left: left, right: right) ?? false)
    }

    func armFeedForwardLive(gate: FeedForwardLiveArmGate.Inputs) -> UInt32? {
        var checked = gate
        checked.featureEnabled = speakerDriveFeatureEnabled
        return quietZoneHost?.armFeedForwardLive(gate: checked)
    }

    /// E4 S22b3: the echo stage's model, with the pump delay as timing. Refused (and cleared) with a
    /// subwoofer or bass management (owner decision of 3 Nov 2026, question 18) and while the pump has
    /// no delay yet. Nil clears.
    func setFeedForwardLiveEcho(_ payload: FeedForwardLiveEchoPayload?) -> Bool {
        guard speakerDriveFeatureEnabled, let transport = quietZoneHost else { return false }
        guard let payload, !bassManagementConfiguration.enabled else {
            _ = transport.setFeedForwardLiveEcho(nil, timingFrames: 0)
            return payload == nil
        }
        guard let rate = ambientPlaybackReferenceSampleRate, let delay = feedForwardLiveDriver.delaySeconds,
              delay > 0, delay < 0.1
        else { return false }
        return transport.setFeedForwardLiveEcho(payload, timingFrames: UInt32((delay * rate).rounded()))
    }

    func disarmFeedForwardLive() { quietZoneHost?.disarmFeedForwardLive() }

    func markFeedForwardLiveReferenceLost() { quietZoneHost?.markFeedForwardLiveReferenceLost() }

    func feedForwardLiveStatus() -> N60RenderKernelFeedForwardLiveStatus? {
        quietZoneHost?.feedForwardLiveStatus()
    }

    func pushFeedForwardLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
        guard speakerDriveFeatureEnabled else { return nil }
        return quietZoneHost?.pushFeedForwardLiveReference(startIndex: startIndex, samples: samples)
    }

    func readSpeakerDriveAnchors() -> [N60SpeakerDriveAnchor] {
        quietZoneHost?.readSpeakerDriveAnchors(maximum: Int(N60_SPEAKER_DRIVE_ANCHOR_CAPACITY)) ?? []
    }

    /// The anchor ring has one consumer; the shadow and the live reference pump each get every anchor
    /// through this fan-out.
    func pullSpeakerDriveAnchors(for consumer: SpeakerDriveAnchorFanout.Consumer) -> [N60SpeakerDriveAnchor] {
        speakerDrive.pull(readSpeakerDriveAnchors(), for: consumer)
    }

    func readSpeakerDriveFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        quietZoneHost?.readSpeakerDriveFrames(maximumFrames: maximumFrames) ?? []
    }

    var activeQuietZoneReferenceAvailable: Bool {
        activeQuietZoneStereoSpeakerRuntimeAvailable || activeQuietZoneProfileRuntimeAvailable
    }

    /// E26 S7b2c (G26): the tonal controller may run on the stereo route or on a profile session hosting the feed.
    var activeQuietZoneRuntimeAvailable: Bool {
        activeQuietZoneStereoSpeakerRuntimeAvailable || activeQuietZoneProfileRuntimeAvailable
    }

    var activeQuietZoneReferenceSampleRate: Double? {
        guard activeQuietZoneReferenceAvailable else {
            return nil
        }
        return quietZoneHost?
            .activeQuietZoneReferenceSampleRate
    }

    func setActiveQuietZoneReferenceDemand(_ enabled: Bool) {
        guard activeQuietZoneReferenceAvailable else {
            quietZoneHost?
                .setActiveQuietZoneReferenceDemand(false)
            return
        }
        quietZoneHost?
            .setActiveQuietZoneReferenceDemand(enabled)
    }

    func activeQuietZoneReferenceSnapshot()
        -> N60ActiveQuietZoneReferenceSnapshot? {
        guard activeQuietZoneReferenceAvailable else {
            return nil
        }
        return quietZoneHost?
            .activeQuietZoneReferenceSnapshot()
    }

    func discardActiveQuietZoneReferenceFrames() {
        quietZoneHost?
            .discardActiveQuietZoneReferenceFrames()
    }

    func readActiveQuietZoneReferenceFrames(
        maximumFrames: Int =
            Int(
                N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
            )
    ) -> [N60ActiveQuietZoneReferenceFrame] {
        guard activeQuietZoneReferenceAvailable else {
            return []
        }
        return quietZoneHost?
            .readActiveQuietZoneReferenceFrames(
                maximumFrames: maximumFrames
            )
            ?? []
    }
}
