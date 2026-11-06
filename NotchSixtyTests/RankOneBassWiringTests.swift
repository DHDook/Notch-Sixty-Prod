import XCTest
@testable import NotchSixty

// E26 S3b: the rank-one bass modes reach the offline design, the causal FIR compiler, the S18 tonal core and the
// feed-forward shadow. With the flag off (or no sub) every path is unchanged.
final class RankOneBassWiringTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func z(_ r: Double, _ i: Double = 0) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(real: r, imaginary: i)
    }

    private func budget() -> QuietZoneFeedForwardBudget {
        QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible, acousticPreviewSeconds: 0.016, conservativePreviewSeconds: 0.015,
            antiNoisePathSeconds: 0.008, conservativeReserveSeconds: 0.006, geometryOnly: false,
            runtimeAvailable: false, explanation: "Fixture")
    }

    /// Both speakers reach both points through one sub: the right column is a scaled copy of the left.
    private func rankOneBand(_ hz: Double) -> QuietZoneVirtualSeatBand {
        let k = z(0.9, 0.1)
        return QuietZoneVirtualSeatBand(
            frequencyHz: hz, sourceToReference: z(1), sourceToListener: z(0.02),
            leftSecondaryAtListener: z(1), rightSecondaryAtListener: k,
            leftLeakageAtReference: z(0.2), rightLeakageAtReference: z(0.2) * k, measuredCoherence: 0.98)
    }

    private func wellConditionedBand(_ hz: Double) -> QuietZoneVirtualSeatBand {
        QuietZoneVirtualSeatBand(
            frequencyHz: hz, sourceToReference: z(1), sourceToListener: z(0.4, 0.1),
            leftSecondaryAtListener: z(1), rightSecondaryAtListener: z(0.2, 0.1),
            leftLeakageAtReference: z(0.1), rightLeakageAtReference: z(0.9), measuredCoherence: 0.98)
    }

    func testDesignerCommonModeOnRankOneBandsAndUnchangedWhenOff() throws {
        let bands = [rankOneBand(40), rankOneBand(60), rankOneBand(80)]
        var on = QuietZoneVirtualSeatDesigner()
        on.bassConditioning = true
        let conditioned = try on.design(measurements: bands, budget: budget())
        for band in conditioned.bands {
            XCTAssertEqual(band.leftFilter.real, band.rightFilter.real, accuracy: 1e-9)
            XCTAssertEqual(band.leftFilter.imaginary, band.rightFilter.imaginary, accuracy: 1e-9)
        }
        let off = try QuietZoneVirtualSeatDesigner().design(measurements: bands, budget: budget())
        XCTAssertNotEqual(off.bands.map(\.leftFilter), off.bands.map(\.rightFilter))
    }

    func testDesignerIsBitIdenticalOnWellConditionedPlant() throws {
        let bands = [wellConditionedBand(40), wellConditionedBand(70)]
        var on = QuietZoneVirtualSeatDesigner()
        on.bassConditioning = true
        XCTAssertEqual(
            try on.design(measurements: bands, budget: budget()),
            try QuietZoneVirtualSeatDesigner().design(measurements: bands, budget: budget()))
    }

    func testCompilerTiesLeftAndRightInCommonModeBandsAtEveryRate() throws {
        let bands = [rankOneBand(40), rankOneBand(70), rankOneBand(110)]
        var designer = QuietZoneVirtualSeatDesigner()
        designer.bassConditioning = true
        let design = try designer.design(measurements: bands, budget: budget())
        for rate in rates {
            var compiler = QuietZoneCausalFIRCompiler()
            compiler.bassConditioning = true
            let candidate = try compiler.compile(
                design: design, measurements: bands, budget: budget(), sampleRate: rate, tapCount: 16)
            XCTAssertEqual(candidate.leftTaps.count, candidate.rightTaps.count)
            for (l, r) in zip(candidate.leftTaps, candidate.rightTaps) {
                XCTAssertEqual(l, r, accuracy: 1e-4 * max(1, abs(l)), "\(rate) Hz")
            }
        }
    }

    func testMapLooksUpModeAndReadsFreeWhereNothingIsMeasured() {
        let map = BassPlantMap(bands: [rankOneBand(40), rankOneBand(80), wellConditionedBand(160)])
        XCTAssertEqual(map.mode(atHz: 42), .commonMode)
        XCTAssertEqual(map.mode(atHz: 160), .free)
        XCTAssertEqual(map.mode(atHz: 1_000), .free)
        XCTAssertEqual(map.summary.cardReadout, "Below 80 Hz both channels share your subwoofer.")
        XCTAssertNil(BassPlantMap(bands: [wellConditionedBand(60)]).summary.cardReadout)
        XCTAssertEqual(
            BassPlantConditioningSummary(bands: [rankOneBand(40), rankOneBand(80)]).pairMode(lowHz: 20, highHz: 200),
            .commonMode)
        XCTAssertEqual(
            BassPlantConditioningSummary(bands: [rankOneBand(40), wellConditionedBand(80)]).pairMode(lowHz: 20, highHz: 200),
            .tikhonov(lambdaScale: BassPlantConditioning.maximumLambdaScale))
    }

    func testTonesCarryModeAndTonalCoreValidatesIt() {
        let seeds = [60.0, 80.0].map { hz in
            AdaptiveQuietZoneSeed(
                frequencyHz: hz, leftPath: z(1), rightPath: z(0.9, 0.1), leftOutput: z(0.1, 0.02),
                rightOutput: z(0.1, 0.02), bassMode: .commonMode)
        }
        let tones = AdaptiveQuietZoneShadowTone.tones(from: seeds)
        XCTAssertEqual(tones.map(\.bassMode), [.commonMode, .commonMode])
        for rate in rates {
            var config = N60RemoteTonalConfigDefault(rate, 1.0e9)
            config.toneCount = 1
            withUnsafeMutableBytes(of: &config.toneHz) { $0.bindMemory(to: Float.self)[0] = 60 }
            let equal = N60AncComplex(re: 0.7071, im: 0)
            withUnsafeMutableBytes(of: &config.leftShare) { $0.bindMemory(to: N60AncComplex.self)[0] = equal }
            withUnsafeMutableBytes(of: &config.rightShare) { $0.bindMemory(to: N60AncComplex.self)[0] = equal }
            withUnsafeMutableBytes(of: &config.pathSeed) { $0.bindMemory(to: N60AncComplex.self)[0] = N60AncComplex(re: 1, im: 0) }
            withUnsafeMutableBytes(of: &config.weightSeed) { $0.bindMemory(to: N60AncComplex.self)[0] = N60AncComplex(re: 0.1, im: 0) }
            XCTAssertTrue(N60RemoteTonalConfigIsValid(&config), "free \(rate)")
            withUnsafeMutableBytes(of: &config.bassMode) { $0.bindMemory(to: UInt8.self)[0] = UInt8(N60_REMOTE_TONAL_BASS_COMMON_MODE) }
            XCTAssertTrue(N60RemoteTonalConfigIsValid(&config), "common \(rate)")
            // Unequal shares are not a common mode.
            withUnsafeMutableBytes(of: &config.rightShare) { $0.bindMemory(to: N60AncComplex.self)[0] = N60AncComplex(re: 0.5, im: 0.2) }
            XCTAssertFalse(N60RemoteTonalConfigIsValid(&config), "unequal \(rate)")
        }
    }

    func testShadowConfigValidatesBassModes() throws {
        for rate in [48_000.0, 384_000] {
            var config = N60FeedForwardShadowConfigDefault(rate)
            config.bassMode = N60_FF_BASS_COMMON_MODE
            XCTAssertTrue(N60FeedForwardShadowConfigIsValid(&config), "\(rate)")
            config.bassMode = 9
            XCTAssertFalse(N60FeedForwardShadowConfigIsValid(&config), "\(rate)")
            config.bassMode = N60_FF_BASS_TIKHONOV
            config.leakageScale = 11
            XCTAssertFalse(N60FeedForwardShadowConfigIsValid(&config), "\(rate)")
        }
    }
}
