import Foundation

/// E4 S18b: the worker's only doors into the render path: pop the render thread's telemetry,
/// write the gain mailbox, and latch the 20 ms howl fade. Single consumer / single writer: only
/// the adaptive worker calls these. A fake implements it in tests.
protocol AdaptiveTonalLiveLink: AnyObject, Sendable {
    func popTelemetry() -> N60ActiveQuietZoneTelemetryRecord?
    /// Returns the assigned sequence, 0 when rejected outright.
    @discardableResult
    func publish(_ record: N60ActiveQuietZoneGainRecord) -> UInt64
    func requestHowlTrip()
}

/// E26 S7b2: the Quiet Zone control surface of a live transport session. The stereo session implements it on the render
/// kernel; the profile (N-channel) session implements it on an `N60AncLaneFeed` registered in its graph. The engine
/// routes Quiet Zone controls to whichever session is live, so the controller does not care which one renders.
protocol QuietZoneRuntimeHost: AnyObject {
    @discardableResult
    func publishActiveQuietZoneGainRecord(_ record: N60ActiveQuietZoneGainRecord) -> UInt64
    func popActiveQuietZoneTelemetry() -> N60ActiveQuietZoneTelemetryRecord?
    var activeQuietZoneMailboxStats: N60ActiveQuietZoneMailboxStats { get }
    func requestHowlTrip()
    var howlGuardTripCount: UInt64 { get }
    func rearmHowlGuard()
    func renewActiveQuietZoneLease(seconds: Double)
    func releaseActiveQuietZoneLease()
    func setFeedForwardLiveWeights(left: [Float], right: [Float]) -> Bool
    func armFeedForwardLive(gate: FeedForwardLiveArmGate.Inputs) -> UInt32?
    func setFeedForwardLiveEcho(_ payload: FeedForwardLiveEchoPayload?, timingFrames: UInt32) -> Bool
    func disarmFeedForwardLive()
    func markFeedForwardLiveReferenceLost()
    func feedForwardLiveStatus() -> N60RenderKernelFeedForwardLiveStatus?
    func pushFeedForwardLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64?
    var ambientReferenceSampleRate: Double { get }
    /// E26 S7b2b (G20): control-thread poll that turns a graph guard trip into a feed fade. No-op for the kernel session,
    /// whose guards run inside the kernel.
    func pollQuietZoneGuards()
}

extension QuietZoneRuntimeHost {
    func pollQuietZoneGuards() {}
}

/// Owns one `N60AncLaneFeed` for the life of a graph host (see `UnifiedGraphHost.retainedResource`).
final class ProfileAncFeed: @unchecked Sendable {
    let pointer: OpaquePointer
    static let channelCount: UInt32 = 5

    init?(sampleRate: Double, splitter: N60SpeakerBusSplitterSnapshot, peakLimit: Float = 0.5, fadeInSeconds: Double? = nil) {
        var config = N60AncLaneFeedConfig()
        config.sampleRate = sampleRate
        config.maxBlockFrames = UInt32(N60AncLaneFeedMaxBlockFrames)
        config.channels = Self.channelCount
        config.programmeLeft = 0; config.programmeRight = 1
        config.sourceLeft = 2; config.sourceRight = 3; config.sourceSub = 4
        config.splitter = splitter
        config.peakLimit = peakLimit
        config.feedForward = true
        if let fadeInSeconds { config.fadeInSeconds = fadeInSeconds }
        guard let created = N60AncLaneFeedCreate(&config) else { return nil }
        pointer = created
    }

    deinit { N60AncLaneFeedDestroy(pointer) }
}

extension CoreAudioTransportSession: QuietZoneRuntimeHost {}

/// The link onto one Core Audio transport session. The session's bridge calls are lock-free and
/// safe from the worker thread.
final class CoreAudioAdaptiveTonalLink: AdaptiveTonalLiveLink, @unchecked Sendable {
    private let session: QuietZoneRuntimeHost

    init(session: QuietZoneRuntimeHost) { self.session = session }

    func popTelemetry() -> N60ActiveQuietZoneTelemetryRecord? { session.popActiveQuietZoneTelemetry() }

    @discardableResult
    func publish(_ record: N60ActiveQuietZoneGainRecord) -> UInt64 {
        session.publishActiveQuietZoneGainRecord(record)
    }

    func requestHowlTrip() { session.requestHowlTrip() }
}
