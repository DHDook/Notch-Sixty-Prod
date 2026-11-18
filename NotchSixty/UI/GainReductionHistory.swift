import Foundation

/// E28 S5 (design 11): what the gain-reduction display remembers. A bar with a peak hold (1 s), and a ring of
/// the last 10 s at 30 points a second (300 points; E32 S3 lowered the view rate from 60 to 30 Hz). Plain Swift; time is passed in, so tests are deterministic.
///
/// Values are reduction in dB, 0 or more. The readback is a maximum since the previous read (the hub keeps
/// the maximum per subscriber), so a short transient is never lost between frames.
struct GainReductionHistory: Equatable, Sendable {
    static let pointsPerSecond = 30.0
    static let capacity = 300
    static let holdSeconds = 1.0

    /// E33 S6: the hold time from the one Peak hold preference (`.infinity` holds until reset). 1 s by default.
    var holdSeconds = GainReductionHistory.holdSeconds
    private(set) var points: [Float] = []
    private(set) var current: Float = 0
    private var holdValue: Float = 0
    private var holdSetAt: Double = -.infinity
    private var lastPointTime: Double = -.infinity

    /// Records a reading taken at `time` (seconds, monotonic). Points are added at most 30 times a second, each the
    /// largest reduction seen since the last point.
    mutating func ingest(_ reduction: Float, at time: Double) {
        let value = reduction.isFinite ? max(0, reduction) : 0
        current = max(current, value)
        if value >= holdValue || time - holdSetAt >= holdSeconds {
            holdValue = value
            holdSetAt = time
        }
        guard time - lastPointTime >= 1 / Self.pointsPerSecond - 1e-9 else { return }
        lastPointTime = time
        points.append(current)
        if points.count > Self.capacity { points.removeFirst(points.count - Self.capacity) }
        current = 0
    }

    /// The most recent value, as drawn in the bar.
    var latest: Float { points.last ?? 0 }

    /// The held maximum (falls after one second without a higher value).
    func held(at time: Double) -> Float {
        time - holdSetAt < holdSeconds ? holdValue : latest
    }

    /// The largest reduction in the window.
    var maximum: Float { points.max() ?? 0 }

    mutating func reset() {
        var fresh = GainReductionHistory()
        fresh.holdSeconds = holdSeconds
        self = fresh
    }

    /// Clears the held tick only (the Reset menu's "Peak hold"); the bar and the 10 s history stay.
    mutating func resetHold() {
        holdValue = 0
        holdSetAt = -.infinity
    }

    /// Spoken value for the bar: refreshed by the caller at most every 2 s.
    static func spoken(_ reduction: Float) -> String {
        reduction < 0.05 ? "no reduction" : String(format: "%.1f decibels of reduction", Double(reduction))
    }
}
