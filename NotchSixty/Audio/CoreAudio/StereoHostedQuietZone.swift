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
        if let feed { return feed.publishGainRecord(record) }
        return session?.publishActiveQuietZoneGainRecord(record) ?? 0
    }

    func popActiveQuietZoneTelemetry() -> N60ActiveQuietZoneTelemetryRecord? {
        if let feed { return feed.popTelemetry() }
        return session?.popActiveQuietZoneTelemetry()
    }

    var activeQuietZoneMailboxStats: N60ActiveQuietZoneMailboxStats {
        if let feed { return feed.mailboxStats }
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
        feed?.renewLease(seconds: seconds, sampleRate: session.outputFormat.sampleRate)
        session.renewActiveQuietZoneLease(seconds: seconds)
    }

    func releaseActiveQuietZoneLease() {
        feed?.releaseLease()
        session?.releaseActiveQuietZoneLease()
    }

    func setFeedForwardLiveWeights(left: [Float], right: [Float]) -> Bool {
        if let feed { return feed.setFeedForwardWeights(left: left, right: right) }
        return session?.setFeedForwardLiveWeights(left: left, right: right) ?? false
    }

    func armFeedForwardLive(gate: FeedForwardLiveArmGate.Inputs) -> UInt32? {
        if let feed { return feed.armFeedForward(gate: gate) }
        return session?.armFeedForwardLive(gate: gate)
    }

    func setFeedForwardLiveEcho(_ payload: FeedForwardLiveEchoPayload?, timingFrames: UInt32) -> Bool {
        if let feed { return feed.setFeedForwardEcho(payload, timingFrames: timingFrames) }
        return session?.setFeedForwardLiveEcho(payload, timingFrames: timingFrames) ?? false
    }

    func disarmFeedForwardLive() {
        if let feed { feed.disarmFeedForward() } else { session?.disarmFeedForwardLive() }
    }

    func markFeedForwardLiveReferenceLost() {
        if feed != nil { disarmFeedForwardLive() } else { session?.markFeedForwardLiveReferenceLost() }
    }

    func feedForwardLiveStatus() -> N60RenderKernelFeedForwardLiveStatus? {
        if let feed { return feed.feedForwardStatus() }
        return session?.feedForwardLiveStatus()
    }

    func pushFeedForwardLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
        if let feed { return feed.pushFeedForwardReference(startIndex: startIndex, samples: samples) }
        return session?.pushFeedForwardLiveReference(startIndex: startIndex, samples: samples)
    }

    var ambientReferenceSampleRate: Double { session?.ambientReferenceSampleRate ?? 0 }
    var activeQuietZoneReferenceSampleRate: Double { session?.activeQuietZoneReferenceSampleRate ?? 0 }

    // MARK: Reference taps and speaker drive

    func setAmbientReferenceDemand(_ enabled: Bool) {
        if let feed { feed.setTapDemand(N60AncLaneFeedTapAmbient, enabled) } else { session?.setAmbientReferenceDemand(enabled) }
    }

    func ambientReferenceSnapshot() -> N60AmbientPlaybackReferenceSnapshot? {
        if let feed { return feed.ambientSnapshot() }
        return session?.ambientReferenceSnapshot()
    }

    func discardAmbientReferenceFrames() {
        if let feed { feed.discardTap(N60AncLaneFeedTapAmbient) } else { session?.discardAmbientReferenceFrames() }
    }

    func readAmbientReferenceFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        if let feed { return feed.readAmbientFrames(maximumFrames: maximumFrames) }
        return session?.readAmbientReferenceFrames(maximumFrames: maximumFrames) ?? []
    }

    func setActiveQuietZoneReferenceDemand(_ enabled: Bool) {
        if let feed { feed.setTapDemand(N60AncLaneFeedTapQuietZone, enabled) } else { session?.setActiveQuietZoneReferenceDemand(enabled) }
    }

    func activeQuietZoneReferenceSnapshot() -> N60ActiveQuietZoneReferenceSnapshot? {
        if let feed { return feed.quietZoneReferenceSnapshot() }
        return session?.activeQuietZoneReferenceSnapshot()
    }

    func discardActiveQuietZoneReferenceFrames() {
        if let feed { feed.discardTap(N60AncLaneFeedTapQuietZone) } else { session?.discardActiveQuietZoneReferenceFrames() }
    }

    func readActiveQuietZoneReferenceFrames(maximumFrames: Int) -> [N60ActiveQuietZoneReferenceFrame] {
        if let feed { return feed.readQuietZoneReferenceFrames(maximumFrames: maximumFrames) }
        return session?.readActiveQuietZoneReferenceFrames(maximumFrames: maximumFrames) ?? []
    }

    func setSpeakerDriveDemand(_ enabled: Bool) {
        if let feed { feed.setTapDemand(N60AncLaneFeedTapSpeakerDrive, enabled) } else { session?.setSpeakerDriveDemand(enabled) }
    }

    func speakerDriveSnapshot() -> N60SpeakerDriveSnapshot? {
        if let feed { return feed.speakerDriveSnapshot() }
        return session?.speakerDriveSnapshot()
    }

    func readSpeakerDriveAnchors(maximum: Int) -> [N60SpeakerDriveAnchor] {
        if let feed { return feed.readSpeakerDriveAnchors(maximum: maximum) }
        return session?.readSpeakerDriveAnchors(maximum: maximum) ?? []
    }

    func readSpeakerDriveFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        if let feed { return feed.readSpeakerDriveFrames(maximumFrames: maximumFrames) }
        return session?.readSpeakerDriveFrames(maximumFrames: maximumFrames) ?? []
    }

    /// Feed counters for tests and diagnostics (nil while the kernel renders).
    func quietZoneFeedStatus() -> N60AncLaneFeedStatus? {
        guard let feed else { return nil }
        return N60AncLaneFeedGetStatus(feed.pointer)
    }
}
