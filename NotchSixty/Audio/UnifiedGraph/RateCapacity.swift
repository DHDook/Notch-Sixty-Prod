import Foundation

/// E7 S1: capacities are times. A buffer that must hold a user-facing duration (a delay, a look-ahead) is sized as
/// `ceil(seconds * rate)` frames at build time, so the duration holds at every device rate to 384 kHz. A fixed frame
/// constant is allowed only where a test proves it holds the 384 kHz worst case of what it serves (`fixedRings`).
/// The core's twin is `n60::framesFor` (`core/include/n60/rate_capacity.h`). Control plane only; never called from a
/// render callback.
enum RateCapacity {
    /// `ceil(seconds * sampleRate)`, saturating at `UInt32.max`; 0 for a non-finite or non-positive input.
    static func frames(seconds: Double, sampleRate: Double) -> UInt32 {
        let value = (seconds * sampleRate).rounded(.up)
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt32.max) ? UInt32.max : UInt32(value)
    }

    /// The headphone per-ear delay the profile model allows (`HeadphoneChannelCorrection`), in seconds.
    static let headphoneDelayMaximumSeconds = 0.020

    /// Where a single FRAC_DELAY stage stops (its ring holds 8,192 frames; the graph accepts 0..8,190 whole frames).
    static let fractionalStageLimitFrames = 8_190.0
    /// Whole frames a split FRAC_DELAY keeps, so its Thiran all-pass sits on a short line (E25 S2 uses the same 16).
    static let fractionalStageResidualFrames = 16.0

    /// A fractional delay as the graph runs it: `wholeFrames` of plain DELAY ahead of a FRAC_DELAY stage that takes
    /// `stageWhole` whole frames plus `fraction`. `wholeFrames == 0` means the FRAC_DELAY stage alone, the form every
    /// delay below 8,190 frames has always had.
    struct FractionalDelaySplit: Equatable, Sendable {
        var wholeFrames: UInt32
        var stageWhole: Double
        var fraction: Double
    }

    /// Splits a total fractional delay in frames so the FRAC_DELAY ring never limits the time it can serve. Delays
    /// below 8,190 frames stay a single stage (bit-identical to before); longer ones put all but the last 16 whole
    /// frames in a DELAY stage. Returns nil for a negative or non-finite delay or one above
    /// `N60_GRAPH_MAX_DELAY_FRAMES`.
    static func splitFractionalDelay(totalFrames total: Double) -> FractionalDelaySplit? {
        guard total.isFinite, total >= 0, total <= Double(N60_GRAPH_MAX_DELAY_FRAMES) else { return nil }
        let whole = total.rounded(.down)
        guard total >= fractionalStageLimitFrames else {
            return FractionalDelaySplit(wholeFrames: 0, stageWhole: whole, fraction: total - whole)
        }
        let delay = whole - fractionalStageResidualFrames
        return FractionalDelaySplit(
            wholeFrames: UInt32(delay), stageWhole: fractionalStageResidualFrames, fraction: total - whole)
    }

    /// The highest device rate v1 runs (E7 Q6): protection (`N60_PROTECTION_MAX_SAMPLE_RATE`) and the plug-in rack stop
    /// here and nothing above is tested, so a faster device is refused with a named reason.
    static let supportedMaximumSampleRate = 384_000.0

    // MARK: Fixed rings (design note 4)

    /// Frames in every fixed ring and block of the live path: analyser taps, the three transports' bridges, analysis
    /// capture, and the graph's default maximum block.
    static let fixedRingFrames: UInt32 = 65_536
    /// The largest Core Audio buffer any transport renders in one block (matches the AU slice cap).
    static let largestDeviceBufferFrames: UInt32 = 32_768
    /// The largest analysis transform, in frames (E27: 32,768-point at 384 kHz).
    static let largestAnalysisTransformFrames: UInt32 = 32_768
    /// The largest protection look-ahead the UI offers, in seconds.
    static let protectionLookAheadMaximumSeconds = 0.020
}
