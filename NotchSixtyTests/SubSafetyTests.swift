import XCTest
@testable import NotchSixty

// E26 S4: caps through a receiver, the measured summing law, the path watch and the combined-leakage bound.
@MainActor
final class SubSafetyTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func z(_ r: Double, _ i: Double = 0) -> ActiveQuietZoneComplex { ActiveQuietZoneComplex(real: r, imaginary: i) }

    /// A sub path at `hz` for a delay of `samples` at `rate`, as level (dB) and phase (degrees).
    private func twin(rate: Double, hz: Double, samples: Double, gainDB: Double = 0, flipped: Bool = false)
        -> BassPathWatch.Sample {
        var phase = -360 * hz * samples / rate
        if flipped { phase += 180 }
        return .init(frequencyHz: hz, levelDB: gainDB, phaseDegrees: phase)
    }

    private func sharedBand(_ hz: Double, leakage: Double = 0.2, disturbance: Double = 0.02, right: ActiveQuietZoneComplex = ActiveQuietZoneComplex(real: 0.9, imaginary: 0.1))
        -> QuietZoneVirtualSeatBand {
        QuietZoneVirtualSeatBand(
            frequencyHz: hz, sourceToReference: z(1), sourceToListener: z(disturbance),
            leftSecondaryAtListener: z(1), rightSecondaryAtListener: right,
            leftLeakageAtReference: z(leakage), rightLeakageAtReference: z(leakage) * right, measuredCoherence: 0.98)
    }

    // MARK: Excursion limits

    func testCalibratedLFEUsesDeclaredCrossoverForSubAndMains() {
        let base = ExcursionLimits(mainLowerLimitHz: 45, subCrossoverHz: 80)
        let refined = base.refined(for: .downstream(.calibratedLFE(crossoverHz: 120)), appCrossoverHz: 80)
        XCTAssertEqual(refined.mainLowerLimitHz, 120)
        XCTAssertEqual(refined.subCrossoverHz, 120)
    }

    func testOpenPreoutUsesAppCrossoverAndNeverLoosens() {
        let base = ExcursionLimits(mainLowerLimitHz: 60, subCrossoverHz: nil)
        let refined = base.refined(for: .downstream(.openPreout), appCrossoverHz: 90)
        XCTAssertEqual(refined.mainLowerLimitHz, 90)
        XCTAssertEqual(refined.subCrossoverHz, 90)
        let higher = ExcursionLimits(mainLowerLimitHz: 100, subCrossoverHz: 100)
        XCTAssertEqual(higher.refined(for: .downstream(.openPreout), appCrossoverHz: 90).mainLowerLimitHz, 100)
    }

    func testUndeclaredAndOtherPathsAreCautiousOrUnchanged() {
        let base = ExcursionLimits(mainLowerLimitHz: 60, subCrossoverHz: nil)
        XCTAssertEqual(base.refined(for: .downstream(.undeclared), appCrossoverHz: nil).subCrossoverHz, 80)
        XCTAssertEqual(base.refined(for: .none, appCrossoverHz: 90), base)
        XCTAssertEqual(base.refined(for: .monoBassOnPair, appCrossoverHz: 90), base)
        XCTAssertEqual(base.refined(for: .subOutput, appCrossoverHz: 90), base)
    }

    func testTwentyFiveHertzIsCappedBySubCurveThroughAReceiver() {
        let base = ExcursionLimits(mainLowerLimitHz: 60, subCrossoverHz: nil)
        let before = ExcursionCapCurve(limits: base).capDBFS(atHz: 25)
        let limits = base.refined(for: .downstream(.calibratedLFE(crossoverHz: 80)), appCrossoverHz: nil)
        let curve = ExcursionCapCurve(limits: limits)
        XCTAssertEqual(curve.capDBFS(atHz: 25), ExcursionCapCurve.passbandDBFS, accuracy: 1e-9)
        XCTAssertGreaterThan(curve.capDBFS(atHz: 25), before)
        // The mains stop at the crossover: a 200 Hz tone is unlimited, a tone far above falls on the sub curve.
        XCTAssertEqual(curve.capDBFS(atHz: 200), ExcursionCapCurve.passbandDBFS, accuracy: 1e-9)
    }

    // MARK: Summing law

    func testSummingFactorFromMeasuredGains() {
        XCTAssertEqual(SubSummingLaw.factor(left: z(1), right: z(1)) ?? 0, 2, accuracy: 1e-12)
        XCTAssertEqual(SubSummingLaw.factor(left: z(1), right: z(0.01)) ?? 0, 1.01, accuracy: 1e-12)
        XCTAssertNil(SubSummingLaw.factor(left: z(0), right: z(0)))
    }

    func testSummingFactorOverPlantAtEveryRate() {
        for rate in rates {
            let delay = 0.004 * rate
            let angle = -2 * Double.pi * 50 * delay.rounded() / rate
            let sub = z(cos(angle), sin(angle))
            let band = QuietZoneVirtualSeatBand(
                frequencyHz: 50, sourceToReference: z(1), sourceToListener: z(0.02),
                leftSecondaryAtListener: sub, rightSecondaryAtListener: sub * z(1.0005, 0),
                leftLeakageAtReference: sub * z(0.2), rightLeakageAtReference: sub * z(0.2005), measuredCoherence: 0.98)
            let factor = SubSummingLaw.factor(plant: BassPlantMap(bands: [band]), subInPath: true, upperHz: 80)
            XCTAssertEqual(factor, 2, accuracy: 0.01, "rate \(rate)")
        }
        // No usable measurement counts the worst case; no sub counts one.
        XCTAssertEqual(SubSummingLaw.factor(plant: BassPlantMap(bands: []), subInPath: true, upperHz: 80), 2)
        XCTAssertEqual(SubSummingLaw.factor(plant: BassPlantMap(bands: []), subInPath: false, upperHz: 80), 1)
    }

    // MARK: Path watch

    func testReceiverTrimStepOfSixDBDisarmsAndOneDBDoesNot() {
        for rate in rates {
            var watch = BassPathWatch(upperHz: 80)
            XCTAssertEqual(watch.observe([twin(rate: rate, hz: 40, samples: 100)]), .ok)
            XCTAssertEqual(watch.observe([twin(rate: rate, hz: 40, samples: 100, gainDB: 1)]), .ok, "\(rate)")
            XCTAssertEqual(watch.observe([twin(rate: rate, hz: 40, samples: 100, gainDB: -5.9)]), .ok)
            if case .changed = watch.observe([twin(rate: rate, hz: 40, samples: 100, gainDB: 6.5)]) {} else {
                XCTFail("6.5 dB step must change at \(rate)")
            }
        }
    }

    func testPolarityFlipAndPhaseWrap() {
        for rate in rates {
            var watch = BassPathWatch(upperHz: 80)
            _ = watch.observe([twin(rate: rate, hz: 30, samples: 50)])
            if case .changed = watch.observe([twin(rate: rate, hz: 30, samples: 50, flipped: true)]) {} else {
                XCTFail("polarity flip must change at \(rate)")
            }
        }
        var wrap = BassPathWatch(upperHz: 80)
        _ = wrap.observe([.init(frequencyHz: 40, levelDB: 0, phaseDegrees: 170)])
        // 170 -> -170 is 20 degrees across the wrap.
        XCTAssertEqual(wrap.observe([.init(frequencyHz: 40, levelDB: 0, phaseDegrees: -170)]), .ok)
    }

    func testWatchIgnoresTonesAboveTheSubBandAndBadSamples() {
        var watch = BassPathWatch(upperHz: 80)
        _ = watch.observe([.init(frequencyHz: 200, levelDB: 0, phaseDegrees: 0)])
        XCTAssertEqual(watch.observe([.init(frequencyHz: 200, levelDB: 30, phaseDegrees: 170)]), .ok)
        XCTAssertEqual(watch.observe([.init(frequencyHz: 40, levelDB: .nan, phaseDegrees: 0)]), .ok)
        XCTAssertTrue(watch.baselines.isEmpty)
        watch.reset()
        XCTAssertTrue(watch.baselines.isEmpty)
    }

    func testChangedFingerprintDisarmsAtTheNextObservation() throws {
        let arm = LiveTreatmentArm(feature: .quietZone)
        var env = LiveTreatmentEnvironment(
            outputDeviceUID: "out", sampleRate: 48_000, engineRunning: true, inputAvailable: true,
            microphoneLevelDBFS: nil)
        env.bassPathFingerprint = "abc"
        try arm.arm(environment: env)
        arm.observe(env)
        XCTAssertTrue(arm.isArmed)
        env.bassPathFingerprint = "def"
        arm.observe(env)
        XCTAssertFalse(arm.isArmed)
        XCTAssertEqual(arm.lastDisarmReason, .bassPathChanged)
        XCTAssertNotNil(arm.statusMessage)
        // Not compared when the arm began without one (flag off).
        let plain = LiveTreatmentArm(feature: .quietZone)
        env.bassPathFingerprint = nil
        try plain.arm(environment: env)
        env.bassPathFingerprint = "zzz"
        plain.observe(env)
        XCTAssertTrue(plain.isArmed)
    }

    // MARK: Combined-leakage bound

    func testSharedBandsGetTheTighterLeakageLimit() {
        let base = QuietZoneVirtualSeatDesigner.maximumLeakageFraction
        let shared = sharedBand(60)
        XCTAssertEqual(
            CombinedLeakageStabilityBound.fractionLimit(for: shared, bassConditioning: true),
            base / pow(10, 6.0 / 20), accuracy: 1e-12)
        XCTAssertEqual(CombinedLeakageStabilityBound.fractionLimit(for: shared, bassConditioning: false), base)
        let free = QuietZoneVirtualSeatBand(
            frequencyHz: 60, sourceToReference: z(1), sourceToListener: z(0.4, 0.1),
            leftSecondaryAtListener: z(1), rightSecondaryAtListener: z(0.2, 0.1),
            leftLeakageAtReference: z(0.1), rightLeakageAtReference: z(0.9), measuredCoherence: 0.98)
        XCTAssertEqual(CombinedLeakageStabilityBound.fractionLimit(for: free, bassConditioning: true), base)
    }

    func testStrongSubToReferenceCouplingIsRefusedOnlyWithTheRulesOn() throws {
        let budget = QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible, acousticPreviewSeconds: 0.016, conservativePreviewSeconds: 0.015,
            antiNoisePathSeconds: 0.008, conservativeReserveSeconds: 0.006, geometryOnly: false,
            runtimeAvailable: false, explanation: "Fixture")
        var refusedOnly = 0
        for leakage in stride(from: 0.01, through: 0.6, by: 0.01) {
            let bands = [sharedBand(40, leakage: leakage, disturbance: 1), sharedBand(60, leakage: leakage, disturbance: 1)]
            let off = try? QuietZoneVirtualSeatDesigner().design(measurements: bands, budget: budget)
            var rules = QuietZoneVirtualSeatDesigner()
            rules.bassConditioning = true
            let on = try? rules.design(measurements: bands, budget: budget)
            if on != nil { XCTAssertNotNil(off, "the rules never accept what the old bound refuses (\(leakage))") }
            if off != nil, on == nil { refusedOnly += 1 }
        }
        XCTAssertGreaterThan(refusedOnly, 0, "some coupling must sit between the tight and the old limit")
    }
}
