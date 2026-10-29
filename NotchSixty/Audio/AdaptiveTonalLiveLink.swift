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

/// The link onto one Core Audio transport session. The session's bridge calls are lock-free and
/// safe from the worker thread.
final class CoreAudioAdaptiveTonalLink: AdaptiveTonalLiveLink, @unchecked Sendable {
    private let session: CoreAudioTransportSession

    init(session: CoreAudioTransportSession) { self.session = session }

    func popTelemetry() -> N60ActiveQuietZoneTelemetryRecord? { session.popActiveQuietZoneTelemetry() }

    @discardableResult
    func publish(_ record: N60ActiveQuietZoneGainRecord) -> UInt64 {
        session.publishActiveQuietZoneGainRecord(record)
    }

    func requestHowlTrip() { session.requestHowlTrip() }
}
