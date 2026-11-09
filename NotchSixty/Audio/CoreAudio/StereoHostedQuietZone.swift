import Foundation

/// E6 S12h part 2b: control-plane record of the stereo session's hosted Quiet Zone feed.
///
/// Realtime notes: this type is control-thread only (it holds a lock, so it is never touched from the audio callback).
/// The feed itself (`N60AncLaneFeed`) is the realtime part: allocation none, wait-free mailboxes and atomics, no added
/// latency, any native rate, four channels (programme L/R and the two anti-noise sources), created disarmed with the
/// graph and recreated disarmed by every session rebuild.
final class StereoAncHostState: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var tripped = false
    private var revision: UInt32 = 0
    private var manualTrips: UInt64 = 0
    private var seenGuardTrips: UInt64 = 0

    /// True when the feed was armed; clears the mark. Used to fade the feed out exactly once.
    func takeArmed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { armed = false }
        return armed
    }

    /// True when this call moved the feed from disarmed to armed. Never while a howl trip is latched.
    func markArmed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tripped { return false }
        defer { armed = true }
        return !armed
    }

    func markTripped() { lock.lock(); tripped = true; lock.unlock() }
    func clearTripped() { lock.lock(); tripped = false; lock.unlock() }

    var rearmRevision: UInt32 {
        lock.lock(); defer { lock.unlock() }
        return revision
    }

    func bumpRearmRevision() {
        lock.lock(); revision = (revision % 1_000_000) + 1; tripped = false; lock.unlock()
    }

    func addManualTrip() {
        lock.lock(); manualTrips &+= 1; lock.unlock()
    }

    var manualTripCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return manualTrips
    }

    /// True when `trips` is newer than the last count seen.
    func noteGuardTrips(_ trips: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let fresh = trips > seenGuardTrips
        seenGuardTrips = trips
        return fresh
    }
}

/// E6 S12h part 2b: the `QuietZoneRuntimeHost` the engine uses for a stereo session. While the session's unified graph
/// carries the Quiet Zone feed (the ANC lane feed as the graph's EXTERNAL stage) every call goes to the feed; when the
/// kernel renders (the graph refused or is off) every call goes to the kernel, exactly as before.
///
/// Authorisation is not a method here: it is the published snapshot's `activeQuietZone.enabled`, which the engine sets
/// only for a target stamped with the current `LiveTreatmentArm` generation. The session arms the feed from that value
/// and from nothing else.
final class StereoHostedQuietZone: QuietZoneRuntimeHost, @unchecked Sendable {
    private weak var session: CoreAudioTransportSession?

    init(session: CoreAudioTransportSession) { self.session = session }

    private var feed: ProfileAncFeed? { session?.hostedQuietZoneFeed }

    @discardableResult
    func publishActiveQuietZoneGainRecord(_ record: N60ActiveQuietZoneGainRecord) -> UInt64 {
        if let feed {
            var copy = record
            return N60ActiveQuietZoneGainMailboxPublish(N60AncLaneFeedMailbox(feed.pointer), &copy)
        }
        return session?.publishActiveQuietZoneGainRecord(record) ?? 0
    }

    func popActiveQuietZoneTelemetry() -> N60ActiveQuietZoneTelemetryRecord? {
        if let feed {
            var record = N60ActiveQuietZoneTelemetryRecord()
            return N60ActiveQuietZoneTelemetryPop(N60AncLaneFeedTelemetry(feed.pointer), &record) ? record : nil
        }
        return session?.popActiveQuietZoneTelemetry()
    }

    var activeQuietZoneMailboxStats: N60ActiveQuietZoneMailboxStats {
        if let feed { return N60ActiveQuietZoneGainMailboxStats(N60AncLaneFeedMailbox(feed.pointer)) }
        return session?.activeQuietZoneMailboxStats ?? N60ActiveQuietZoneMailboxStats()
    }

    /// Latches the 20 ms fade (any thread). The graph's own guards also trip on their own; `howlGuardTripCount` counts
    /// both, so `LiveTreatmentArm` disarms on either.
    func requestHowlTrip() {
        // The kernel bridge first (lock-free), then the feed, so the safety fade never waits on a rebuild for the kernel.
        session?.requestHowlTrip()
        session?.tripHostedQuietZone(manual: true)
    }

    var howlGuardTripCount: UInt64 {
        guard let session else { return 0 }
        return session.howlGuardTripCount &+ session.ancHostState.manualTripCount &+ session.hostedGuardTripCount()
    }

    /// A graph-guard trip newly seen since the last poll disarms the feed at once (20 ms fade).
    func pollQuietZoneGuards() {
        guard let session, session.hostedQuietZoneFeed != nil else { return }
        if session.ancHostState.noteGuardTrips(session.hostedGuardTripCount()) {
            session.tripHostedQuietZone(manual: false)
        }
    }

    func rearmHowlGuard() {
        session?.rearmHowlGuard()
        session?.rearmHostedGuards()
    }

    func renewActiveQuietZoneLease(seconds: Double) {
        guard let session else { return }
        if let feed, seconds > 0 {
            N60AncLaneFeedRenewLease(feed.pointer, UInt64((session.outputFormat.sampleRate * seconds).rounded(.up)))
        }
        session.renewActiveQuietZoneLease(seconds: seconds)
    }

    func releaseActiveQuietZoneLease() {
        if let feed { N60AncLaneFeedReleaseLease(feed.pointer) }
        session?.releaseActiveQuietZoneLease()
    }

    func setFeedForwardLiveWeights(left: [Float], right: [Float]) -> Bool {
        if let feed {
            guard !left.isEmpty, left.count == right.count else { return false }
            return N60AncLaneFeedSetFeedForwardWeights(feed.pointer, left, right, UInt32(left.count))
        }
        return session?.setFeedForwardLiveWeights(left: left, right: right) ?? false
    }

    func armFeedForwardLive(gate: FeedForwardLiveArmGate.Inputs) -> UInt32? {
        if let feed {
            guard FeedForwardLiveArmGate.decide(gate).isAllowed else { return nil }
            return N60AncLaneFeedFeedForwardArm(feed.pointer, gate.leadSeconds, gate.requiredLeadSeconds)
        }
        return session?.armFeedForwardLive(gate: gate)
    }

    func setFeedForwardLiveEcho(_ payload: FeedForwardLiveEchoPayload?, timingFrames: UInt32) -> Bool {
        guard let feed else { return session?.setFeedForwardLiveEcho(payload, timingFrames: timingFrames) ?? false }
        guard let payload else { return N60AncLaneFeedSetFeedForwardEcho(feed.pointer, nil) }
        guard payload.isValid else { return false }
        let bulk = payload.bulk
        let ok = payload.left.withUnsafeBufferPointer { left in
            payload.right.withUnsafeBufferPointer { right in
                var echo = N60FeedForwardLiveEcho(
                    bulkDelay: (bulk[0], bulk[1]),
                    tapCount: (UInt32(left.count), UInt32(right.count)),
                    taps: (left.baseAddress, right.baseAddress))
                return N60AncLaneFeedSetFeedForwardEcho(feed.pointer, &echo)
            }
        }
        return ok && N60AncLaneFeedSetFeedForwardEchoTiming(feed.pointer, timingFrames)
    }

    func disarmFeedForwardLive() {
        if let feed { N60AncLaneFeedFeedForwardDisarm(feed.pointer) } else { session?.disarmFeedForwardLive() }
    }

    func markFeedForwardLiveReferenceLost() {
        if feed != nil { disarmFeedForwardLive() } else { session?.markFeedForwardLiveReferenceLost() }
    }

    func feedForwardLiveStatus() -> N60RenderKernelFeedForwardLiveStatus? {
        guard let feed else { return session?.feedForwardLiveStatus() }
        var status = N60RenderKernelFeedForwardLiveStatus()
        status.attached = true
        status.filter = N60AncLaneFeedFeedForwardStatus(feed.pointer)
        status.outputIndex = N60AncLaneFeedReferenceOutputIndex(feed.pointer)
        status.referenceUnderruns = N60AncLaneFeedGetStatus(feed.pointer).referenceUnderruns
        return status
    }

    func pushFeedForwardLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
        guard let feed else { return session?.pushFeedForwardLiveReference(startIndex: startIndex, samples: samples) }
        guard !samples.isEmpty else { return nil }
        return N60AncLaneFeedPushReference(feed.pointer, startIndex, samples, UInt32(samples.count))
    }

    var ambientReferenceSampleRate: Double { session?.ambientReferenceSampleRate ?? 0 }
    var activeQuietZoneReferenceSampleRate: Double { session?.activeQuietZoneReferenceSampleRate ?? 0 }

    // MARK: Reference taps and speaker drive

    private func readTap(_ feed: ProfileAncFeed, _ tap: N60AncLaneFeedTap, maximumFrames: Int) -> [N60AncLaneFeedFramePair] {
        let snapshot = N60AncLaneFeedTapGetSnapshot(feed.pointer, tap)
        let capacity = min(maximumFrames, Int(snapshot.availableFrames))
        guard maximumFrames > 0, capacity > 0 else { return [] }
        var result = [N60AncLaneFeedFramePair](repeating: N60AncLaneFeedFramePair(), count: capacity)
        let count = result.withUnsafeMutableBufferPointer {
            N60AncLaneFeedTapRead(feed.pointer, tap, $0.baseAddress!, UInt32($0.count))
        }
        if Int(count) < result.count { result.removeLast(result.count - Int(count)) }
        return result
    }

    func setAmbientReferenceDemand(_ enabled: Bool) {
        if let feed { N60AncLaneFeedSetTapDemand(feed.pointer, N60AncLaneFeedTapAmbient, enabled) }
        else { session?.setAmbientReferenceDemand(enabled) }
    }

    func ambientReferenceSnapshot() -> N60AmbientPlaybackReferenceSnapshot? {
        guard let feed else { return session?.ambientReferenceSnapshot() }
        let s = N60AncLaneFeedTapGetSnapshot(feed.pointer, N60AncLaneFeedTapAmbient)
        return N60AmbientPlaybackReferenceSnapshot(
            enabled: s.enabled, availableFrames: s.availableFrames,
            capturedFrames: s.capturedFrames, droppedFrames: s.droppedFrames)
    }

    func discardAmbientReferenceFrames() {
        if let feed { N60AncLaneFeedTapDiscard(feed.pointer, N60AncLaneFeedTapAmbient) }
        else { session?.discardAmbientReferenceFrames() }
    }

    func readAmbientReferenceFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        guard let feed else { return session?.readAmbientReferenceFrames(maximumFrames: maximumFrames) ?? [] }
        return readTap(feed, N60AncLaneFeedTapAmbient, maximumFrames: maximumFrames)
            .map { N60AmbientPlaybackReferenceFrame(left: $0.left, right: $0.right) }
    }

    func setActiveQuietZoneReferenceDemand(_ enabled: Bool) {
        if let feed { N60AncLaneFeedSetTapDemand(feed.pointer, N60AncLaneFeedTapQuietZone, enabled) }
        else { session?.setActiveQuietZoneReferenceDemand(enabled) }
    }

    func activeQuietZoneReferenceSnapshot() -> N60ActiveQuietZoneReferenceSnapshot? {
        guard let feed else { return session?.activeQuietZoneReferenceSnapshot() }
        let s = N60AncLaneFeedTapGetSnapshot(feed.pointer, N60AncLaneFeedTapQuietZone)
        return N60ActiveQuietZoneReferenceSnapshot(
            enabled: s.enabled, availableFrames: s.availableFrames,
            capturedFrames: s.capturedFrames, droppedFrames: s.droppedFrames)
    }

    func discardActiveQuietZoneReferenceFrames() {
        if let feed { N60AncLaneFeedTapDiscard(feed.pointer, N60AncLaneFeedTapQuietZone) }
        else { session?.discardActiveQuietZoneReferenceFrames() }
    }

    func readActiveQuietZoneReferenceFrames(maximumFrames: Int) -> [N60ActiveQuietZoneReferenceFrame] {
        guard let feed else { return session?.readActiveQuietZoneReferenceFrames(maximumFrames: maximumFrames) ?? [] }
        return readTap(feed, N60AncLaneFeedTapQuietZone, maximumFrames: maximumFrames)
            .map { N60ActiveQuietZoneReferenceFrame(left: $0.left, right: $0.right) }
    }

    func setSpeakerDriveDemand(_ enabled: Bool) {
        if let feed { N60AncLaneFeedSetTapDemand(feed.pointer, N60AncLaneFeedTapSpeakerDrive, enabled) }
        else { session?.setSpeakerDriveDemand(enabled) }
    }

    func speakerDriveSnapshot() -> N60SpeakerDriveSnapshot? {
        guard let feed else { return session?.speakerDriveSnapshot() }
        let s = N60AncLaneFeedTapGetSnapshot(feed.pointer, N60AncLaneFeedTapSpeakerDrive)
        return N60SpeakerDriveSnapshot(
            enabled: s.enabled, availableFrames: s.availableFrames, availableAnchors: s.availableAnchors,
            capturedFrames: s.capturedFrames, droppedFrames: s.droppedFrames, droppedAnchors: s.droppedAnchors)
    }

    func readSpeakerDriveAnchors(maximum: Int) -> [N60SpeakerDriveAnchor] {
        guard let feed else { return session?.readSpeakerDriveAnchors(maximum: maximum) ?? [] }
        guard maximum > 0 else { return [] }
        var raw = [N60AncLaneFeedAnchor](repeating: N60AncLaneFeedAnchor(), count: maximum)
        let count = raw.withUnsafeMutableBufferPointer {
            N60AncLaneFeedAnchorsRead(feed.pointer, $0.baseAddress!, UInt32($0.count))
        }
        return raw.prefix(Int(count)).map {
            N60SpeakerDriveAnchor(outputHostTime: $0.outputHostTime, firstFrameIndex: $0.firstFrameIndex,
                                  frames: $0.frames, reserved: $0.reserved)
        }
    }

    func readSpeakerDriveFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        guard let feed else { return session?.readSpeakerDriveFrames(maximumFrames: maximumFrames) ?? [] }
        return readTap(feed, N60AncLaneFeedTapSpeakerDrive, maximumFrames: maximumFrames)
            .map { N60AmbientPlaybackReferenceFrame(left: $0.left, right: $0.right) }
    }

    /// Feed counters for tests and diagnostics (nil while the kernel renders).
    func quietZoneFeedStatus() -> N60AncLaneFeedStatus? {
        guard let feed else { return nil }
        return N60AncLaneFeedGetStatus(feed.pointer)
    }
}
