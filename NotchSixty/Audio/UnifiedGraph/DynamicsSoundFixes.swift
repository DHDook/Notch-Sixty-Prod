import Foundation

/// E32 S5 (behind `e32.dynamics-sound`): the three sound changes in the graph's dynamics stages, decided in Swift and
/// published as stage parameters (the core never reads the flag). Off, every stage renders exactly as before.
///
/// - Limiter attack (R7): the core caps the effective attack at the look-ahead, so zero look-ahead is an instant attack.
///   The page shows a note when the cap applies; stored values are not changed.
/// - Expander timing (R9): Attack opens the gain and Release closes it (`ExpanderConfiguration.coreExtras(swapTiming:)`).
/// - True-peak factor (R12): the smallest of 1x, 2x, 4x with rate x factor at least 176.4 kHz, instead of a fixed 4x. The core
///   and the Swift latency totals use the same rule, so the reported latency follows it.
///
enum DynamicsSoundFixes {
    /// Bits of the PROTECTION stage's trailing sound-fixes word (graph ABI v43).
    static let attackCapBit: Float = 1
    static let rateFactorBit: Float = 2
    static let protectionWord: Float = attackCapBit + rateFactorBit

    nonisolated static var isEnabled: Bool {
        FeatureFlags.isEnabledProcessWide(.dynamicsSound)
    }

    /// The true-peak oversampling factor at `sampleRate` when the limiter and the guard are both on.
    static func truePeakFactor(sampleRate: Double) -> UInt32 {
        guard sampleRate.isFinite else { return 4 }
        if sampleRate >= 176_399 { return 1 }
        return sampleRate * 2 >= 176_399 ? 2 : 4
    }

    /// The limiter's latency in frames as the core computes it: half-band delay plus the look-ahead at the oversampled rate.
    static func limiterLatencyFrames(factor: UInt32, lookAheadMilliseconds: Double, limiterEnabled: Bool, sampleRate: Double) -> UInt32 {
        let highRate = sampleRate * Double(factor)
        let lookAheadHigh = limiterEnabled ? UInt32((Double(Float(lookAheadMilliseconds)) * 0.001 * highRate).rounded(.up)) : 0
        let osLatency: UInt32 = factor == 2 ? 32 : (factor == 4 ? 48 : 0)
        return osLatency + (lookAheadHigh + factor - 1) / factor
    }

    /// True when the attack is longer than the look-ahead, so the core shortens it (the page note).
    static func attackIsLimited(attackMs: Double, lookAheadMs: Double) -> Bool {
        attackMs > lookAheadMs
    }

    /// The protection latency to count for a snapshot made by the frozen C code: its own figure, except that with the true-peak
    /// guard on the graph's factor follows the rate.
    static func protectionLatencyFrames(_ p: N60ProtectionSnapshot, sampleRate: Double) -> UInt32 {
        guard isEnabled, p.limiterEnabled, p.truePeakGuardEnabled else { return p.latencyFrames }
        return limiterLatencyFrames(
            factor: truePeakFactor(sampleRate: sampleRate), lookAheadMilliseconds: Double(p.limiterLookAheadMs),
            limiterEnabled: true, sampleRate: sampleRate)
    }
}
