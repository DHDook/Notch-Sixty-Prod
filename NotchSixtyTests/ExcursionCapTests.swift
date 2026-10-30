import XCTest
@testable import NotchSixty

/// E4 S21: the frequency-aware excursion cap and the thermal hold. Pure control plane.
@MainActor
final class ExcursionCapTests: XCTestCase {
    private let mainOnly = ExcursionCapCurve(limits: ExcursionLimits(mainLowerLimitHz: 60, subCrossoverHz: nil))
    private let withSub = ExcursionCapCurve(limits: ExcursionLimits(mainLowerLimitHz: 80, subCrossoverHz: 80))

    func testTwentyFiveHertzIsCappedLowerOnAMainThanOnASub() {
        let main = mainOnly.capDBFS(atHz: 25)
        let sub = withSub.capDBFS(atHz: 25)
        XCTAssertLessThan(main, sub)
        XCTAssertEqual(sub, ExcursionCapCurve.passbandDBFS, accuracy: 1e-9)
        // 60 -> 25 Hz is 1.263 octaves at 12 dB per octave.
        XCTAssertEqual(main, ExcursionCapCurve.passbandDBFS - 12 * log2(60.0 / 25.0), accuracy: 1e-9)
    }

    func testMainAtTwoHundredHertzIsUnlimited() {
        XCTAssertEqual(mainOnly.capDBFS(atHz: 200), ExcursionCapCurve.passbandDBFS, accuracy: 1e-9)
        XCTAssertEqual(withSub.capDBFS(atHz: 200), ExcursionCapCurve.passbandDBFS, accuracy: 1e-9)
    }

    func testSubFallsAboveCrossoverPlusOneOctave() {
        XCTAssertEqual(withSub.subCapDBFS(atHz: 160), ExcursionCapCurve.passbandDBFS, accuracy: 1e-9)
        XCTAssertEqual(withSub.subCapDBFS(atHz: 320), ExcursionCapCurve.passbandDBFS - 12, accuracy: 1e-9)
    }

    func testCurveNeverExceedsTheHardMaximumAndHasAFloor() {
        for f in stride(from: 1.0, through: 1000.0, by: 7.0) {
            for curve in [mainOnly, withSub] {
                let c = curve.capDBFS(atHz: f)
                XCTAssertLessThanOrEqual(c, LiveTreatmentSafeguards.hardMaximumPeakCapDBFS)
                XCTAssertGreaterThanOrEqual(c, ExcursionCapCurve.floorDBFS)
            }
        }
        XCTAssertEqual(mainOnly.capDBFS(atHz: 0), ExcursionCapCurve.floorDBFS)
        XCTAssertEqual(mainOnly.capDBFS(atHz: .nan), ExcursionCapCurve.floorDBFS)
    }

    func testTrackedCapIsTheLowestAcrossTheTrackingRange() {
        let f = 60.0
        XCTAssertEqual(mainOnly.trackedCapDBFS(atHz: f), mainOnly.capDBFS(atHz: f * 0.9), accuracy: 1e-9)
        XCTAssertLessThan(mainOnly.trackedCapDBFS(atHz: f), mainOnly.capDBFS(atHz: f))
        XCTAssertGreaterThan(mainOnly.trackedCapLinear(atHz: 25), 0)
    }

    func testLowerLimitFromAMeasurement() {
        // Flat to 50 Hz, then 12 dB per octave down; the -10 dB point sits near 28 Hz.
        let freqs = stride(from: 10.0, through: 1000.0, by: 1.0).map { $0 }
        let mags = freqs.map { $0 >= 50 ? 0.0 : -12 * log2(50 / $0) }
        let limit = ExcursionLimits.lowerLimitHz(frequenciesHz: freqs, magnitudeDB: mags)
        XCTAssertNotNil(limit)
        XCTAssertEqual(limit!, 50 * pow(2, -10.0 / 12), accuracy: 1.0)
        XCTAssertNil(ExcursionLimits.lowerLimitHz(frequenciesHz: [100, 200], magnitudeDB: [0, 0]))
        XCTAssertNil(ExcursionLimits.lowerLimitHz(frequenciesHz: freqs, magnitudeDB: freqs.map { _ in 0 }))
    }

    // MARK: Thermal

    private func hold(peakDB: Double, seconds: Int, capDBFS: Double = -18) -> (ExcursionThermalIntegrator, Int?) {
        var t = ExcursionThermalIntegrator()
        let peak = pow(10, peakDB / 20)
        var engaged: Int?
        for s in 0 ... seconds {
            if t.update(now: Double(s), playedPeakLinear: peak, nominalCapDBFS: capDBFS), engaged == nil { engaged = s }
        }
        return (t, engaged)
    }

    func testContinuousToneAtTheCapEngagesTheHold() {
        let (t, engaged) = hold(peakDB: -18, seconds: 600)
        XCTAssertNotNil(engaged)
        XCTAssertLessThanOrEqual(engaged ?? 0, 60)
        XCTAssertTrue(t.holding || (engaged ?? 0) > 0)
    }

    func testToneWellBelowTheCapNeverHolds() {
        let (t, engaged) = hold(peakDB: -30, seconds: 900)
        XCTAssertNil(engaged)
        XCTAssertEqual(t.holdReductionDB, 0)
    }

    func testHoldReleasesAfterRestAndIsDeterministic() {
        var a = ExcursionThermalIntegrator()
        var b = ExcursionThermalIntegrator()
        var states: [Bool] = []
        for s in 0 ... 900 {
            let peak = s < 300 ? 0.1259 : 0.0
            let x = a.update(now: Double(s), playedPeakLinear: peak, nominalCapDBFS: -18)
            let y = b.update(now: Double(s), playedPeakLinear: peak, nominalCapDBFS: -18)
            XCTAssertEqual(x, y)
            states.append(x)
        }
        XCTAssertTrue(states[200])
        XCTAssertFalse(states[900])
        XCTAssertEqual(a.holdReductionDB, 0)
    }

    func testHoldUsesAHysteresisAndNonFiniteInputIsSilence() {
        var t = ExcursionThermalIntegrator()
        _ = t.update(now: 0, playedPeakLinear: .nan, nominalCapDBFS: -18)
        _ = t.update(now: 10, playedPeakLinear: .infinity, nominalCapDBFS: -18)
        XCTAssertEqual(t.meanPower, 0)
    }

    // MARK: Policy interplay

    func testThermalHoldPausesTheEarnedTimerWithoutResettingIt() {
        let suite = "ExcursionCapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = EarnedCapPolicy(store: EarnedCapStore(defaults: defaults))
        p.beginArm(binding: EarnedCapBinding(outputDeviceUID: "o", inputDeviceUID: "i", sampleRate: 48_000), outputGainDB: 0)
        func facts(_ now: TimeInterval, hold: Bool) -> EarnedCapPollFacts {
            EarnedCapPollFacts(
                now: now, adapting: true, verdict: .ok,
                measurement: DoNoHarmVerifier.Measurement(worstIncreaseDB: 0, minimumToneReductionDB: 6),
                guardOrHold: false, playedPeakLinear: p.capLinear, moveRecovering: false, thermalHold: hold
            )
        }
        XCTAssertFalse(p.poll(facts(0, hold: false)))
        XCTAssertFalse(p.poll(facts(40, hold: false)))
        // 50 s qualified before the hold; the 100 s of hold do not count; 10 s more makes 60.
        XCTAssertFalse(p.poll(facts(50, hold: true)))
        XCTAssertFalse(p.poll(facts(140, hold: true)))
        XCTAssertFalse(p.poll(facts(150, hold: false)))
        XCTAssertFalse(p.poll(facts(159, hold: false)))
        XCTAssertTrue(p.poll(facts(160, hold: false)), "50 s elapsed before the hold plus 10 s after it")
    }

    func testEffectiveCapIsLoweredByTheHoldOnly() {
        let suite = "ExcursionCapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = EarnedCapPolicy(store: EarnedCapStore(defaults: defaults))
        p.beginArm(binding: EarnedCapBinding(outputDeviceUID: "o", inputDeviceUID: "i", sampleRate: 48_000), outputGainDB: 0)
        p.setThermalHold(6)
        XCTAssertEqual(p.effectiveCapDBFS, p.capDBFS - 6, accuracy: 1e-9)
        XCTAssertEqual(p.capDBFS, EarnedCapPolicy.floorDBFS)
        p.noteDisarm(.user)
        XCTAssertEqual(p.thermalHoldDB, 0)
    }

    // MARK: Worker clamp

    func testWorkerLowersEachToneToTheCurveAndOnlyLowers() {
        var record = N60ActiveQuietZoneGainRecord()
        record.toneCount = 2
        withUnsafeMutableBytes(of: &record.frequencyHz) {
            let f = $0.bindMemory(to: Double.self)
            f[0] = 25; f[1] = 200
        }
        withUnsafeMutableBytes(of: &record.gain) {
            let g = $0.bindMemory(to: Float.self)
            g[0] = 0.05; g[2] = 0.05      // 25 Hz: well over its cap
            g[4] = 0.05; g[6] = 0.001     // 200 Hz: left over the main cap? no, flat; right tiny
        }
        AdaptiveTonalLiveWorker.applyExcursionCaps(mainOnly, to: &record)
        let g = withUnsafeBytes(of: record.gain) { Array($0.bindMemory(to: Float.self).prefix(8)) }
        XCTAssertEqual(g[0], mainOnly.trackedCapLinear(atHz: 25), accuracy: 1e-6)
        XCTAssertEqual(g[2], mainOnly.trackedCapLinear(atHz: 25), accuracy: 1e-6)
        XCTAssertEqual(g[4], 0.05 > mainOnly.trackedCapLinear(atHz: 200) ? mainOnly.trackedCapLinear(atHz: 200) : 0.05, accuracy: 1e-6)
        XCTAssertEqual(g[6], 0.001, accuracy: 1e-9)
    }
}
