import XCTest
@testable import NotchSixty

/// E32 S5: the Swift side of the dynamics sound fixes (flag, protection word, expander timing value, rate-based latency).
final class DynamicsSoundFixesTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    func testFlagIsRegisteredAndDefaultsOff() {
        let flag = FeatureFlag.dynamicsSound
        XCTAssertTrue(FeatureFlag.all.contains(flag))
        XCTAssertFalse(flag.defaultEnabled)
        XCTAssertEqual(flag.id, "e32.dynamics-sound")
    }

    func testTruePeakFactorFollowsTheRate() {
        let expected: [UInt32] = [4, 4, 2, 2, 1, 1, 1, 1]
        for (rate, factor) in zip(rates, expected) {
            XCTAssertEqual(DynamicsSoundFixes.truePeakFactor(sampleRate: rate), factor, "rate \(rate)")
            XCTAssertGreaterThanOrEqual(rate * Double(factor), 176_399)
        }
    }

    func testLimiterLatencyUsesTheFactor() {
        // 1x has no half-band delay; look-ahead 5 ms at 192 kHz is 960 frames.
        XCTAssertEqual(DynamicsSoundFixes.limiterLatencyFrames(factor: 1, lookAheadMilliseconds: 5, limiterEnabled: true, sampleRate: 192_000), 960)
        // 4x at 48 kHz: 48 + 240 look-ahead frames.
        XCTAssertEqual(DynamicsSoundFixes.limiterLatencyFrames(factor: 4, lookAheadMilliseconds: 5, limiterEnabled: true, sampleRate: 48_000), 48 + 240)
        XCTAssertEqual(DynamicsSoundFixes.limiterLatencyFrames(factor: 2, lookAheadMilliseconds: 0, limiterEnabled: true, sampleRate: 96_000), 32)
    }

    func testAttackNoteAppliesOnlyWhenAttackExceedsLookAhead() {
        XCTAssertTrue(DynamicsSoundFixes.attackIsLimited(attackMs: 5, lookAheadMs: 1))
        XCTAssertFalse(DynamicsSoundFixes.attackIsLimited(attackMs: 1, lookAheadMs: 5))
    }

    func testProtectionParametersAppendTheWordOnlyWhenOn() {
        let p = UnifiedGraphProtection(ceilingDB: -1, attackMilliseconds: 5, releaseMilliseconds: 100, lookAheadMilliseconds: 5,
                                       truePeakGuard: true, oversampling: 4)
        let off = UnifiedGraphConfiguration.protectionParameters(p, soundFixes: false)
        let on = UnifiedGraphConfiguration.protectionParameters(p, soundFixes: true)
        XCTAssertEqual(off.count, 7)
        XCTAssertEqual(on.count, 8)
        XCTAssertEqual(Array(on.dropLast()), off)
        XCTAssertEqual(on.last, DynamicsSoundFixes.protectionWord)
    }

    func testExpanderExtrasCarryTheSwapOnlyWhenAsked() {
        var e = ExpanderConfiguration()
        e.enabled = true
        XCTAssertEqual(e.coreExtras().count, 7)
        XCTAssertEqual(e.coreExtras(sampleRate: 48_000, lookahead: true).count, 8)
        let swapped = e.coreExtras(sampleRate: 48_000, lookahead: false, swapTiming: true)
        XCTAssertEqual(swapped.count, 9)
        XCTAssertEqual(swapped[7], 0)
        XCTAssertEqual(swapped[8], 1)
    }

    func testLatencyWithFixesOffIsTheFixedFourTimesFigure() {
        let p = UnifiedGraphProtection(ceilingDB: -1, attackMilliseconds: 5, releaseMilliseconds: 100, lookAheadMilliseconds: 5,
                                       truePeakGuard: true, oversampling: 4)
        for rate in rates {
            let off = p.latencyFrames(sampleRate: rate, soundFixes: false)
            let on = p.latencyFrames(sampleRate: rate, soundFixes: true)
            XCTAssertLessThanOrEqual(on, off, "rate \(rate)")
            if rate <= 48_000 { XCTAssertEqual(on, off, "rate \(rate)") }
        }
    }
}
