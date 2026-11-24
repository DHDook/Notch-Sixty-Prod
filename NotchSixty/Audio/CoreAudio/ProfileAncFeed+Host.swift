import Foundation

/// E23 S1c (E6 G48): the one feed-backed Quiet Zone host surface. The stereo session's `StereoHostedQuietZone` and the
/// N-channel session's `QuietZoneRuntimeHost` conformance both route here, so the feed routing (gain mailbox,
/// telemetry, lease, feed-forward filter and the three reference taps) exists once. The sessions keep only what
/// differs: which feed they hold, how they arm and trip it, and the kernel fallback of the stereo session.
///
/// Control plane only (never called from the audio callback). The feed itself is the realtime part and is unchanged.
extension ProfileAncFeed {
    @discardableResult
    func publishGainRecord(_ record: N60ActiveQuietZoneGainRecord) -> UInt64 {
        var copy = record
        return N60ActiveQuietZoneGainMailboxPublish(N60AncLaneFeedMailbox(pointer), &copy)
    }

    func popTelemetry() -> N60ActiveQuietZoneTelemetryRecord? {
        var record = N60ActiveQuietZoneTelemetryRecord()
        return N60ActiveQuietZoneTelemetryPop(N60AncLaneFeedTelemetry(pointer), &record) ? record : nil
    }

    var mailboxStats: N60ActiveQuietZoneMailboxStats {
        N60ActiveQuietZoneGainMailboxStats(N60AncLaneFeedMailbox(pointer))
    }

    func renewLease(seconds: Double, sampleRate: Double) {
        guard seconds > 0 else { return }
        N60AncLaneFeedRenewLease(pointer, UInt64((sampleRate * seconds).rounded(.up)))
    }

    func releaseLease() { N60AncLaneFeedReleaseLease(pointer) }

    // MARK: Feed-forward filter

    func setFeedForwardWeights(left: [Float], right: [Float]) -> Bool {
        guard !left.isEmpty, left.count == right.count else { return false }
        return N60AncLaneFeedSetFeedForwardWeights(pointer, left, right, UInt32(left.count))
    }

    func armFeedForward(gate: FeedForwardLiveArmGate.Inputs) -> UInt32? {
        guard FeedForwardLiveArmGate.decide(gate).isAllowed else { return nil }
        return N60AncLaneFeedFeedForwardArm(pointer, gate.leadSeconds, gate.requiredLeadSeconds)
    }

    func setFeedForwardEcho(_ payload: FeedForwardLiveEchoPayload?, timingFrames: UInt32) -> Bool {
        guard let payload else { return N60AncLaneFeedSetFeedForwardEcho(pointer, nil) }
        guard payload.isValid else { return false }
        let bulk = payload.bulk
        let ok = payload.left.withUnsafeBufferPointer { left in
            payload.right.withUnsafeBufferPointer { right in
                var echo = N60FeedForwardLiveEcho(
                    bulkDelay: (bulk[0], bulk[1]),
                    tapCount: (UInt32(left.count), UInt32(right.count)),
                    taps: (left.baseAddress, right.baseAddress))
                return N60AncLaneFeedSetFeedForwardEcho(pointer, &echo)
            }
        }
        return ok && N60AncLaneFeedSetFeedForwardEchoTiming(pointer, timingFrames)
    }

    func disarmFeedForward() { N60AncLaneFeedFeedForwardDisarm(pointer) }

    func feedForwardStatus() -> N60RenderKernelFeedForwardLiveStatus {
        var status = N60RenderKernelFeedForwardLiveStatus()
        status.attached = true
        status.filter = N60AncLaneFeedFeedForwardStatus(pointer)
        status.outputIndex = N60AncLaneFeedReferenceOutputIndex(pointer)
        status.referenceUnderruns = N60AncLaneFeedGetStatus(pointer).referenceUnderruns
        return status
    }

    func pushFeedForwardReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
        guard !samples.isEmpty else { return nil }
        return N60AncLaneFeedPushReference(pointer, startIndex, samples, UInt32(samples.count))
    }

    // MARK: Reference taps and speaker drive

    func setTapDemand(_ tap: N60AncLaneFeedTap, _ enabled: Bool) { N60AncLaneFeedSetTapDemand(pointer, tap, enabled) }
    func discardTap(_ tap: N60AncLaneFeedTap) { N60AncLaneFeedTapDiscard(pointer, tap) }
    func tapSnapshot(_ tap: N60AncLaneFeedTap) -> N60AncLaneFeedTapSnapshot { N60AncLaneFeedTapGetSnapshot(pointer, tap) }

    func readTap(_ tap: N60AncLaneFeedTap, maximumFrames: Int) -> [N60AncLaneFeedFramePair] {
        let capacity = min(maximumFrames, Int(tapSnapshot(tap).availableFrames))
        guard maximumFrames > 0, capacity > 0 else { return [] }
        var result = [N60AncLaneFeedFramePair](repeating: N60AncLaneFeedFramePair(), count: capacity)
        let count = result.withUnsafeMutableBufferPointer {
            N60AncLaneFeedTapRead(pointer, tap, $0.baseAddress!, UInt32($0.count))
        }
        if Int(count) < result.count { result.removeLast(result.count - Int(count)) }
        return result
    }

    func ambientSnapshot() -> N60AmbientPlaybackReferenceSnapshot {
        let s = tapSnapshot(N60AncLaneFeedTapAmbient)
        return N60AmbientPlaybackReferenceSnapshot(
            enabled: s.enabled, availableFrames: s.availableFrames,
            capturedFrames: s.capturedFrames, droppedFrames: s.droppedFrames)
    }

    func quietZoneReferenceSnapshot() -> N60ActiveQuietZoneReferenceSnapshot {
        let s = tapSnapshot(N60AncLaneFeedTapQuietZone)
        return N60ActiveQuietZoneReferenceSnapshot(
            enabled: s.enabled, availableFrames: s.availableFrames,
            capturedFrames: s.capturedFrames, droppedFrames: s.droppedFrames)
    }

    func speakerDriveSnapshot() -> N60SpeakerDriveSnapshot {
        let s = tapSnapshot(N60AncLaneFeedTapSpeakerDrive)
        return N60SpeakerDriveSnapshot(
            enabled: s.enabled, availableFrames: s.availableFrames, availableAnchors: s.availableAnchors,
            capturedFrames: s.capturedFrames, droppedFrames: s.droppedFrames, droppedAnchors: s.droppedAnchors)
    }

    func readAmbientFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        readTap(N60AncLaneFeedTapAmbient, maximumFrames: maximumFrames)
            .map { N60AmbientPlaybackReferenceFrame(left: $0.left, right: $0.right) }
    }

    func readQuietZoneReferenceFrames(maximumFrames: Int) -> [N60ActiveQuietZoneReferenceFrame] {
        readTap(N60AncLaneFeedTapQuietZone, maximumFrames: maximumFrames)
            .map { N60ActiveQuietZoneReferenceFrame(left: $0.left, right: $0.right) }
    }

    func readSpeakerDriveFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        readTap(N60AncLaneFeedTapSpeakerDrive, maximumFrames: maximumFrames)
            .map { N60AmbientPlaybackReferenceFrame(left: $0.left, right: $0.right) }
    }

    func readSpeakerDriveAnchors(maximum: Int) -> [N60SpeakerDriveAnchor] {
        guard maximum > 0 else { return [] }
        var raw = [N60AncLaneFeedAnchor](repeating: N60AncLaneFeedAnchor(), count: maximum)
        let count = raw.withUnsafeMutableBufferPointer {
            N60AncLaneFeedAnchorsRead(pointer, $0.baseAddress!, UInt32($0.count))
        }
        return raw.prefix(Int(count)).map {
            N60SpeakerDriveAnchor(outputHostTime: $0.outputHostTime, firstFrameIndex: $0.firstFrameIndex,
                                  frames: $0.frames, reserved: $0.reserved)
        }
    }
}
