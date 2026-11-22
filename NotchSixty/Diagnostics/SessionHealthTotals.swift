import Foundation

// E12 S12 (behind `e12.dashboard-remote`): the Dashboard health strip's session totals, built from the same hub poll
// samples as the event log. Pure value type on the main actor; nothing here touches the audio thread.

struct SessionHealthTotals: Equatable, Sendable {
    /// Samples beyond full scale seen since the session started.
    private(set) var clippedSamples: UInt64 = 0
    /// Deepest limiter gain reduction since the session started, in dB (0 or more).
    private(set) var peakLimiterReductionDB: Float = 0
    /// Samples polled since the session started with the limiter reducing gain at all.
    private(set) var limiterActivePolls = 0
    /// Largest output peak since the session started (linear); 0 until a sample arrives.
    private(set) var peakOutputLinear: Float = 0
    private(set) var polls = 0

    mutating func observe(_ sample: SessionEventSample) {
        polls += 1
        for count in sample.clipSamples.values { clippedSamples &+= count }
        if sample.limiterReductionDB > 0.05 { limiterActivePolls += 1 }
        peakLimiterReductionDB = max(peakLimiterReductionDB, sample.limiterReductionDB)
        peakOutputLinear = max(peakOutputLinear, sample.outputPeakLinear)
    }

    mutating func reset() { self = SessionHealthTotals() }

    /// Room left under full scale in dB (positive); nil until a signal has been seen.
    var remainingHeadroomDB: Double? {
        guard peakOutputLinear > 0 else { return nil }
        return -20 * log10(Double(peakOutputLinear))
    }
}
