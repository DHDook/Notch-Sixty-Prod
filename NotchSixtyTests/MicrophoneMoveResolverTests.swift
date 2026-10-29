import XCTest
@testable import NotchSixty

/// E4 S18b: the supervised re-solve after the microphone moved (design decision 6).
final class MicrophoneMoveResolverTests: XCTestCase {
    private func observation(
        _ now: Double,
        latched: Bool = false,
        over: Double = -5,
        reduction: Double = 0,
        rise: Double = 0,
        drop: Double = 0,
        capped: Bool = false,
        step: Double = 0,
        rate: Double = 0,
        baselineReady: Bool = false
    ) -> MicrophoneMoveObservation {
        MicrophoneMoveObservation(
            now: now, moveLatched: latched, seatOverBaselineDB: over, seatMinimumReductionDB: reduction,
            antiNoiseRiseDB: rise, seatDropDB: drop, atAttemptCap: capped,
            pathStepDegrees: step, pathRateDegreesPerSecond: rate, newBaselineReady: baselineReady
        )
    }

    /// Drives a resolver through trigger, reduce and re-identify, to the start of the baseline.
    private func toRebaselining(_ r: inout MicrophoneMoveResolver, from start: Double = 100) -> Double {
        XCTAssertEqual(r.step(observation(start, latched: true)), .reduceGains)
        XCTAssertEqual(r.step(observation(start + 0.25)), .beginReidentify)
        XCTAssertEqual(r.step(observation(start + 3.25)), .rampOutAndBaseline)
        return start + 3.25
    }

    func testIdleWithoutALatchedMoveDoesNothing() {
        var r = MicrophoneMoveResolver()
        XCTAssertEqual(r.step(observation(0)), .none)
        XCTAssertFalse(r.isRunning)
    }

    func testTheFullSequenceSucceedsAndStepsThroughTheTimeline() {
        var r = MicrophoneMoveResolver()
        let t = toRebaselining(&r)
        XCTAssertTrue(r.holdsOutputSilent)
        XCTAssertEqual(r.step(observation(t + 2.9, baselineReady: true)), .none, "ramp-out plus baseline take 3 s")
        XCTAssertEqual(r.step(observation(t + 3.0, baselineReady: true)), .reseedAndRampIn)
        XCTAssertEqual(r.step(observation(t + 4)), .none)
        XCTAssertEqual(r.step(observation(t + 6.1, reduction: 1)), .none, "adaptation, not yet 3 dB")
        XCTAssertEqual(r.step(observation(t + 8, reduction: 3.5)), .succeeded)
        XCTAssertFalse(r.isRunning)
        XCTAssertEqual(r.resolveCount, 1)
    }

    func testTheBaselineMustBeReadyBeforeRampingIn() {
        var r = MicrophoneMoveResolver()
        let t = toRebaselining(&r)
        XCTAssertEqual(r.step(observation(t + 3.5, baselineReady: false)), .none)
        XCTAssertEqual(r.step(observation(t + 3.6, baselineReady: true)), .reseedAndRampIn)
    }

    func testMoreThanOneDBAboveTheArmingBaselineForASecondDisarms() {
        var r = MicrophoneMoveResolver()
        XCTAssertEqual(r.step(observation(0, latched: true)), .reduceGains)
        XCTAssertEqual(r.step(observation(0.25)), .beginReidentify)
        XCTAssertEqual(r.step(observation(0.3, over: 1.2)), .none)
        XCTAssertEqual(r.step(observation(1.2, over: 1.2)), .none)
        XCTAssertEqual(r.step(observation(1.3, over: 1.2)), .disarm(.aboveArmingBaseline))
    }

    func testAnExcursionShorterThanASecondIsForgiven() {
        var r = MicrophoneMoveResolver()
        _ = r.step(observation(0, latched: true))
        _ = r.step(observation(0.1, over: 2))
        _ = r.step(observation(0.8, over: 2))
        XCTAssertEqual(r.step(observation(0.9, over: 0)), .none)
        XCTAssertEqual(r.step(observation(1.5, over: 2)), .none)
        XCTAssertTrue(r.isRunning)
    }

    func testHalfADBAboveTheNewBaselineForASecondDisarms() {
        var r = MicrophoneMoveResolver()
        let t = toRebaselining(&r)
        XCTAssertEqual(r.step(observation(t + 3, baselineReady: true)), .reseedAndRampIn)
        XCTAssertEqual(r.step(observation(t + 3.1, over: 0.7)), .none)
        XCTAssertEqual(r.step(observation(t + 4.2, over: 0.7)), .disarm(.aboveNewBaseline))
    }

    func testAntiNoiseRisingMoreThan3DBWithoutBenefitDisarms() {
        var r = MicrophoneMoveResolver()
        _ = r.step(observation(0, latched: true))
        _ = r.step(observation(0.25))
        XCTAssertEqual(r.step(observation(0.3, rise: 3.5, drop: 0.5)), .none)
        XCTAssertEqual(r.step(observation(1.4, rise: 3.5, drop: 0.5)), .disarm(.antiNoiseRoseWithoutBenefit))
        var ok = MicrophoneMoveResolver()
        _ = ok.step(observation(0, latched: true))
        _ = ok.step(observation(0.25))
        _ = ok.step(observation(0.3, rise: 3.5, drop: 1.5))
        XCTAssertEqual(ok.step(observation(1.4, rise: 3.5, drop: 1.5)), .none, "at least 1 dB less at the seat")
    }

    func testSittingAtTheCapWithoutThreeDBOfBenefitDisarms() {
        var r = MicrophoneMoveResolver()
        _ = r.step(observation(0, latched: true))
        XCTAssertEqual(r.step(observation(0.25)), .beginReidentify)
        XCTAssertEqual(r.step(observation(0.5, reduction: 1, capped: true)), .none)
        XCTAssertEqual(r.step(observation(1.6, reduction: 1, capped: true)), .disarm(.cappedWithoutBenefit))
    }

    func testAPathStillMovingAfterThreeSecondsDisarms() {
        var r = MicrophoneMoveResolver()
        _ = r.step(observation(0, latched: true))
        _ = r.step(observation(0.25))
        XCTAssertEqual(r.step(observation(3.3, step: 12)), .disarm(.pathNotConverged))
        var fast = MicrophoneMoveResolver()
        _ = fast.step(observation(0, latched: true))
        _ = fast.step(observation(0.25))
        XCTAssertEqual(fast.step(observation(3.3, step: 4, rate: 6)), .disarm(.pathStillMoving))
    }

    func testTwentySecondsWithoutSuccessDisarms() {
        var r = MicrophoneMoveResolver()
        let t = toRebaselining(&r)
        XCTAssertEqual(r.step(observation(t + 3, baselineReady: true)), .reseedAndRampIn)
        XCTAssertEqual(r.step(observation(t + 10, reduction: 2)), .none)
        XCTAssertEqual(r.step(observation(100 + 20, reduction: 2)), .disarm(.timeLimit))
    }

    func testASecondMoveWithin60SecondsOfASuccessDisarms() {
        var r = MicrophoneMoveResolver()
        let t = toRebaselining(&r)
        _ = r.step(observation(t + 3, baselineReady: true))
        XCTAssertEqual(r.step(observation(t + 6.1, reduction: 4)), .none)
        XCTAssertEqual(r.step(observation(t + 7, reduction: 4)), .succeeded)
        XCTAssertEqual(r.step(observation(t + 30, latched: true)), .disarm(.secondMoveSoon))
    }

    func testASecondMoveAfter60SecondsIsResolvedAgainAndAFourthDisarms() {
        var r = MicrophoneMoveResolver()
        var time = 0.0
        for expected in 1...3 {
            let t = toRebaselining(&r, from: time)
            _ = r.step(observation(t + 3, baselineReady: true))
            XCTAssertEqual(r.step(observation(t + 6.1, reduction: 4)), .none)
            XCTAssertEqual(r.step(observation(t + 7, reduction: 4)), .succeeded)
            XCTAssertEqual(r.resolveCount, expected)
            time = t + 80
        }
        XCTAssertEqual(r.step(observation(time, latched: true)), .disarm(.tooManyResolves))
    }

    func testAfterADisarmTheResolverStaysQuietUntilReset() {
        var r = MicrophoneMoveResolver()
        _ = r.step(observation(0, latched: true))
        _ = r.step(observation(0.1, over: 2))
        _ = r.step(observation(1.2, over: 2))
        XCTAssertEqual(r.lastFailure, .aboveArmingBaseline)
        XCTAssertEqual(r.step(observation(5, latched: true)), .none)
        r.reset()
        XCTAssertEqual(r.step(observation(6, latched: true)), .reduceGains)
    }

    func testEveryFailureHasAnExplanationForTheFlightRecorder() {
        let all: [MicrophoneMoveFailure] = [
            .aboveArmingBaseline, .aboveNewBaseline, .antiNoiseRoseWithoutBenefit, .cappedWithoutBenefit,
            .pathNotConverged, .pathStillMoving, .timeLimit, .secondMoveSoon, .tooManyResolves,
        ]
        for failure in all { XCTAssertFalse(failure.explanation.isEmpty) }
    }
}
