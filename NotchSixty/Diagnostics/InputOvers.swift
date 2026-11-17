import Foundation

/// E33 S10 (behind `e33.page-enhancements`, graph ABI v44): the Levels card's input-over reading. The core counts, per
/// input lane, the frames whose reconstructed signal exceeds 0 dBTP while Swift publishes detect = 1 (the Levels page is
/// visible); the counts are monotonic, so this model keeps the baseline of when the page was shown and a reset.
struct InputOversReading: Equatable, Sendable {
    /// Monotonic core counts per lane (index 0 is the first program lane), as last read.
    var counts: [UInt64] = []
    /// The counts when the card was shown or last reset; the card shows the difference.
    var baseline: [UInt64] = []
    var sampleRate: Double = 0
    var shownSince: Date?

    /// Interpolation factor of the core's detector: 4x at 44.1 and 48 kHz, 2x at 88.2 and 96 kHz, 1x above.
    static func factor(sampleRate: Double) -> UInt32 {
        guard sampleRate.isFinite else { return 4 }
        if sampleRate >= 176_399 { return 1 }
        return sampleRate * 2 >= 176_399 ? 2 : 4
    }

    /// At 1x only sample overs are counted, and the card says so.
    var title: String { Self.factor(sampleRate: sampleRate) == 1 ? "Sample overs" : "Input overs" }

    mutating func update(counts new: [UInt64], sampleRate rate: Double, now: Date) {
        if shownSince == nil || baseline.count != new.count { baseline = new; shownSince = now }
        // A core reset (the generation changed, or a counter went backwards) rebaselines.
        if zip(new, baseline).contains(where: { $0.0 < $0.1 }) { baseline = new }
        counts = new
        sampleRate = rate
    }

    /// Overs per lane since shown or reset.
    var perLane: [UInt64] { zip(counts, baseline).map { $0.0 &- $0.1 } }
    var total: UInt64 { perLane.reduce(0, &+) }

    mutating func reset() { baseline = counts; shownSince = nil }

    /// Hidden page: the next show starts from zero.
    mutating func hide() { self = InputOversReading() }

    var note: String {
        let base = "Frames whose reconstructed peak exceeded 0 dBTP at the chain input, counted since this page was shown or reset. "
        if Self.factor(sampleRate: sampleRate) == 1 {
            return base + "At this sample rate only sample overs are counted; audio-band content can read up to about 0.56 dB low."
        }
        return base + "Counted at \(Self.factor(sampleRate: sampleRate))x oversampling."
    }
}
