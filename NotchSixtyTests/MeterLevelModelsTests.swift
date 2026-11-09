import XCTest
@testable import NotchSixty

final class MeterLevelModelsTests: XCTestCase {
    // MARK: Ballistics

    func testPeakFallsTwentyDBInOnePointSevenSeconds() {
        var state = MeterBallisticsState()
        state.advance(mode: .peak, peakDB: 0, rmsDB: -60, elapsed: 0.001)
        XCTAssertEqual(state.displayedDB, 0, accuracy: 1e-9, "instant attack")
        let dt = 0.01
        for _ in 0..<170 { state.advance(mode: .peak, peakDB: -60, rmsDB: -60, elapsed: dt) }
        XCTAssertEqual(state.displayedDB, -20, accuracy: 0.2, "20 dB in 1.7 s within 1 % of the 20 dB span")
    }

    func testVUAndRMSReachNinetyNinePercentInThreeHundredMilliseconds() {
        for mode in [MeterBallistics.vu, .rms] {
            var state = MeterBallisticsState()
            let dt = 0.001
            for _ in 0..<300 { state.advance(mode: mode, peakDB: 0, rmsDB: 0, elapsed: dt) }
            let reached = MeterBallisticsState.linear(state.displayedDB)
            XCTAssertEqual(reached, 0.99, accuracy: 0.01, "\(mode)")
        }
    }

    func testStepSizeDoesNotChangeIntegration() {
        var coarse = MeterBallisticsState()
        var fine = MeterBallisticsState()
        for _ in 0..<30 { coarse.advance(mode: .vu, peakDB: 0, rmsDB: 0, elapsed: 0.01) }
        for _ in 0..<300 { fine.advance(mode: .vu, peakDB: 0, rmsDB: 0, elapsed: 0.001) }
        XCTAssertEqual(coarse.displayedDB, fine.displayedDB, accuracy: 0.01)
    }

    // MARK: Hold

    func testHoldKeepsPeakTwoSecondsThenFollows() {
        var hold = MeterPeakHold()
        hold.advance(displayedDB: -6, elapsed: 0.016)
        XCTAssertEqual(hold.heldDB, -6)
        hold.advance(displayedDB: -30, elapsed: 1.9)
        XCTAssertEqual(hold.heldDB, -6)
        hold.advance(displayedDB: -30, elapsed: 0.2)
        XCTAssertEqual(hold.heldDB, -30)
        hold.advance(displayedDB: -3, elapsed: 0.016)
        XCTAssertEqual(hold.heldDB, -3)
    }

    // MARK: Clip latch

    func testLatchSetsOnOneOverRangeSampleAndOnlyResetClears() {
        var latch = MeterClipLatch()
        latch.update(overRangeCount: 5, truePeakDBTP: -3)   // baseline, old count
        XCTAssertFalse(latch.isLatched)
        latch.update(overRangeCount: 6, truePeakDBTP: -3)
        XCTAssertTrue(latch.isLatched)
        latch.update(overRangeCount: 6, truePeakDBTP: -40)
        XCTAssertTrue(latch.isLatched, "stays latched without new clips")
        latch.reset()
        XCTAssertFalse(latch.isLatched)
        latch.update(overRangeCount: 6, truePeakDBTP: -40)
        XCTAssertFalse(latch.isLatched, "old over-range samples do not re-latch")
    }

    func testLatchSetsOnTruePeakAboveZero() {
        var latch = MeterClipLatch()
        latch.update(overRangeCount: nil, truePeakDBTP: 0.0)
        XCTAssertFalse(latch.isLatched)
        latch.update(overRangeCount: nil, truePeakDBTP: 0.1)
        XCTAssertTrue(latch.isLatched)
    }

    // MARK: Throttle

    func testAccessibilityValueThrottleAndLatchOverride() {
        var throttle = MeterValueThrottle()
        XCTAssertEqual(throttle.offer("a", latched: false, now: 0), "a")
        XCTAssertEqual(throttle.offer("b", latched: false, now: 1.0), "a")
        XCTAssertEqual(throttle.offer("b", latched: false, now: 2.1), "b")
        XCTAssertEqual(throttle.offer("c", latched: true, now: 2.2), "c")
    }

    func testChannelDisplayDescribesClipAndHold() {
        MainActor.assumeIsolated {
            let channel = MeterChannelDisplay(id: "output.L", label: "L")
            let over = MeterChannelReading(peakLinear: 1.2, rmsLinear: 0.5, overRangeSamples: 1, truePeakLinear: 1.1)
            channel.ingest(MeterChannelReading(peakLinear: 0.1, rmsLinear: 0.05, overRangeSamples: 0, truePeakLinear: 0.1),
                           mode: .peak, elapsed: 0.016, now: 0)
            XCTAssertFalse(channel.isClipped)
            channel.ingest(over, mode: .peak, elapsed: 0.016, now: 0.1)
            XCTAssertTrue(channel.isClipped)
            XCTAssertTrue(channel.accessibilityValue.contains("clipped"))
            XCTAssertTrue(channel.accessibilityValue.contains("true peak"))
            channel.resetLatch()
            XCTAssertFalse(channel.isClipped)
        }
    }

    // MARK: Hub

    @MainActor
    private final class FakeVisibility: MeterVisibilityProviding {
        var metersAreVisible = true
    }

    @MainActor
    func testTwoSubscribersSeeTheSameMaximumFromOneRead() {
        let visibility = FakeVisibility()
        var reads = 0
        var peaks: [Float] = [0.2, 0.9, 0.4]
        let hub = MeterReadbackHub<Int>(
            visibility: visibility, isProcessing: { true },
            source: {
                reads += 1
                let peak = peaks.removeFirst()
                return MeterFrame(
                    channels: ["out": MeterChannelReading(peakLinear: peak, rmsLinear: peak / 2, overRangeSamples: nil, truePeakLinear: nil)],
                    context: reads)
            })
        let a = hub.subscribe(hertz: 1)
        let b = hub.subscribe(hertz: 1)
        for _ in 0..<3 { hub.pollOnce() }
        XCTAssertEqual(reads, 3, "one hardware read per poll, not per subscriber")
        XCTAssertEqual(hub.take(a)["out"]?.peakLinear, 0.9)
        XCTAssertEqual(hub.take(b)["out"]?.peakLinear, 0.9)
        XCTAssertTrue(hub.take(a).isEmpty, "take clears")
        hub.unsubscribe(a)
        hub.unsubscribe(b)
    }

    @MainActor
    func testPollingStopsWhenHiddenOrProcessingStopsOrNoSubscribers() {
        let visibility = FakeVisibility()
        var processing = true
        var reads = 0
        let hub = MeterReadbackHub<Int>(
            visibility: visibility, isProcessing: { processing },
            source: { reads += 1; return MeterFrame(channels: [:], context: 0) })
        XCTAssertFalse(hub.pollOnce(), "no subscribers")
        let token = hub.subscribe(hertz: 1)
        XCTAssertTrue(hub.pollOnce())
        visibility.metersAreVisible = false
        XCTAssertFalse(hub.pollOnce(), "hidden or occluded window")
        visibility.metersAreVisible = true
        processing = false
        XCTAssertFalse(hub.pollOnce(), "processing stopped")
        processing = true
        XCTAssertTrue(hub.pollOnce())
        XCTAssertEqual(reads, 2)
        hub.unsubscribe(token)
        XCTAssertFalse(hub.pollOnce())
    }
}
