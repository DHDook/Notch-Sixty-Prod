import Foundation
import XCTest
@testable import NotchSixty

/// E4 S25 follow-up: the engine-owned driver for the live reference pump, the shared anchor ring and the
/// drive demand. Nothing here arms anything.
@MainActor
final class FeedForwardLiveDriverTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let wallStart = 100.0

    private final class FakeHost: FeedForwardLiveDriverHost {
        var allowed = true
        var rate: Double? = 48_000
        var outputLatency = 0.012
        var outputIndex: UInt64 = 0
        var attached = true
        var anchors: [N60SpeakerDriveAnchor] = []
        var demandCalls: [Bool] = []
        var ring: [UInt64: Float] = [:]
        var lost = 0
        var liveDriverAllowed: Bool { allowed }
        var liveDriverOutputRate: Double? { rate }
        func liveDriverOutputLatencySeconds() -> Double { outputLatency }
        func pullPumpAnchors() -> [N60SpeakerDriveAnchor] {
            defer { anchors.removeAll() }
            return anchors
        }
        func setPumpDriveDemand(_ requested: Bool) { demandCalls.append(requested) }
        func liveReferenceOutputIndex() -> UInt64? { attached ? outputIndex : nil }
        func pushLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
            for (k, v) in samples.enumerated() { ring[startIndex + UInt64(k)] = v }
            return startIndex + UInt64(samples.count)
        }
        func markLiveReferenceLost() { lost += 1 }
    }

    private struct CaptureFailure: Error {}

    private final class BrokenCapture: QuietZoneFeedForwardSingleCapturing {
        let sampleRate = 48_000.0
        var closed = false
        func start() throws {}
        func readFrames(maximumFrames: Int) throws -> [N60FeedForwardReferenceFrame] { throw CaptureFailure() }
        func close() { closed = true }
    }

    private let latencies = FeedForwardLiveDriver.Latencies(inputBufferingSeconds: 0.005, inputLatencySeconds: 0.002)

    private func signal(_ t: Double) -> Double { 0.1 * sin(2 * .pi * 63 * t + 0.4) + 0.05 * sin(2 * .pi * 110 * t) }

    func testFlagOffOrNoDriveTapNeverOpensTheCapture() {
        let host = FakeHost()
        let driver = FeedForwardLiveDriver(host: host, pollsAutomatically: false)
        var opened = 0
        host.allowed = false
        XCTAssertFalse(driver.start(latencies: latencies) { opened += 1; return BrokenCapture() })
        host.allowed = true
        host.rate = nil
        XCTAssertFalse(driver.start(latencies: latencies) { opened += 1; return BrokenCapture() })
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(driver.state, .idle)
        XCTAssertTrue(host.demandCalls.isEmpty)
    }

    func testCaptureThatCannotOpenLeavesTheDriverStoppedWithNoDemand() {
        let host = FakeHost()
        let driver = FeedForwardLiveDriver(host: host, pollsAutomatically: false)
        XCTAssertFalse(driver.start(latencies: latencies) { throw CaptureFailure() })
        guard case .stopped = driver.state else { return XCTFail("\(driver.state)") }
        XCTAssertTrue(host.demandCalls.isEmpty)
    }

    func testStartRequestsDriveAndStopReleasesItAndMarksTheReferenceLost() {
        let host = FakeHost()
        let driver = FeedForwardLiveDriver(host: host, pollsAutomatically: false)
        XCTAssertTrue(driver.start(latencies: latencies) { BrokenCapture() })
        XCTAssertEqual(driver.state, .running)
        XCTAssertEqual(host.demandCalls, [true])
        XCTAssertEqual(driver.delaySeconds ?? 0, 0.027, accuracy: 1e-12)
        XCTAssertFalse(driver.start(latencies: latencies) { BrokenCapture() }, "second start while running")
        driver.stop()
        XCTAssertEqual(driver.state, .idle)
        XCTAssertEqual(host.demandCalls, [true, false])
        XCTAssertEqual(host.lost, 1)
    }

    func testPumpFailureStopsTheDriverReleasesDemandAndStaysStopped() {
        let host = FakeHost()
        let driver = FeedForwardLiveDriver(host: host, pollsAutomatically: false)
        let capture = BrokenCapture()
        XCTAssertTrue(driver.start(latencies: latencies) { capture })
        driver.tick()
        guard case .stopped(let reason) = driver.state else { return XCTFail("\(driver.state)") }
        XCTAssertTrue(reason.contains("capture failed"), reason)
        XCTAssertEqual(host.demandCalls, [true, false])
        XCTAssertEqual(host.lost, 1)
        XCTAssertTrue(capture.closed)
        XCTAssertFalse(driver.start(latencies: latencies) { BrokenCapture() }, "no automatic restart")
        driver.stop()
        XCTAssertEqual(driver.state, .idle)
    }

    /// Drives the real pump through the driver at every rate, anchors arriving through the host, and
    /// checks the reference lands on the output clock at the driver's delay.
    func testDriverFillsTheRingOnTheOutputClockAtEightRates() throws {
        for (k, outRate) in rates.enumerated() {
            let refRate = rates[(k + 2) % rates.count]
            let host = FakeHost()
            host.rate = outRate
            let reference = FeedForwardLiveReferencePumpTests.FakeReference(
                rate: refRate, drift: 20e-6, wallStart: wallStart, signal: { [signal] in signal($0) })
            let driver = FeedForwardLiveDriver(host: host, pollsAutomatically: false, hostSeconds: { Double($0) * 1e-9 })
            XCTAssertTrue(driver.start(latencies: .init(inputBufferingSeconds: 0.04, inputLatencySeconds: 0)) { reference })
            let delay = try XCTUnwrap(driver.delaySeconds)
            let callback: UInt64 = 512
            var nextCallback: UInt64 = 0
            var t = wallStart
            func outWall(_ i: UInt64) -> Double { wallStart + Double(i) / outRate }
            while t < wallStart + 6 {
                t += 0.01
                reference.advance(to: t)
                host.outputIndex = UInt64(max(0, (t - wallStart) * outRate))
                while nextCallback + callback <= host.outputIndex {
                    host.anchors.append(N60SpeakerDriveAnchor(
                        outputHostTime: UInt64((outWall(nextCallback) * 1e9).rounded()), firstFrameIndex: nextCallback,
                        frames: UInt32(callback), reserved: UInt32(truncatingIfNeeded: nextCallback)))
                    nextCallback += callback
                }
                driver.tick()
            }
            XCTAssertEqual(driver.state, .running, "ref \(refRate) out \(outRate): \(driver.state)")
            var worst = 0.0
            var checked = 0
            for (i, v) in host.ring where i > UInt64(outRate * 3.5) {
                worst = max(worst, abs(Double(v) - signal(outWall(i) - delay)))
                checked += 1
            }
            XCTAssertGreaterThan(checked, Int(outRate), "ref \(refRate) out \(outRate)")
            XCTAssertLessThan(worst, 0.003, "ref \(refRate) out \(outRate)")
            driver.stop()
        }
    }

    private func anchor(_ n: UInt64) -> N60SpeakerDriveAnchor {
        N60SpeakerDriveAnchor(outputHostTime: n, firstFrameIndex: n * 512, frames: 512, reserved: UInt32(n))
    }

    func testAnchorFanoutGivesEveryConsumerEveryAnchorOnce() {
        var fan = SpeakerDriveAnchorFanout()
        fan.ingest([anchor(1), anchor(2)])
        XCTAssertEqual(fan.drain(.pump).map(\.outputHostTime), [1, 2])
        XCTAssertTrue(fan.drain(.pump).isEmpty)
        fan.ingest([anchor(3)])
        XCTAssertEqual(fan.drain(.shadow).map(\.outputHostTime), [1, 2, 3])
        XCTAssertEqual(fan.drain(.pump).map(\.outputHostTime), [3])
        fan.ingest([anchor(4)])
        fan.reset()
        XCTAssertTrue(fan.drain(.shadow).isEmpty)
        XCTAssertTrue(fan.drain(.pump).isEmpty)
    }

    func testAnchorFanoutBoundsAConsumerThatNeverDrains() {
        var fan = SpeakerDriveAnchorFanout()
        for n in 0..<3 {
            fan.ingest((0..<4_096).map { anchor(UInt64(n * 4_096 + $0 + 1)) })
        }
        let kept = fan.drain(.shadow)
        XCTAssertEqual(kept.count, SpeakerDriveAnchorFanout.maximumPending)
        XCTAssertEqual(kept.last?.outputHostTime, 3 * 4_096)
    }

    func testDriveDemandIsEitherRequester() {
        var mux = SpeakerDriveDemandMux()
        XCTAssertFalse(mux.requested)
        mux.pump = true
        XCTAssertTrue(mux.requested)
        mux.shadow = true
        mux.pump = false
        XCTAssertTrue(mux.requested)
        mux.shadow = false
        XCTAssertFalse(mux.requested)
    }

    func testEngineDriverStaysIdleWhileTheFlagIsOff() {
        let engine = AudioIOEngine()
        XCTAssertFalse(engine.speakerDriveFeatureEnabled)
        XCTAssertFalse(engine.liveDriverAllowed)
        let device = AudioInputDevice(
            deviceID: 1, uid: "mic", name: "Mic", nominalSampleRate: 48_000, availableSampleRateRanges: [])
        engine.startLiveReference(device: device, channel: 0)
        XCTAssertEqual(engine.feedForwardLiveDriver.state, .idle)
        engine.stopLiveReference()
        XCTAssertEqual(engine.feedForwardLiveDriver.state, .idle)
        XCTAssertNil(engine.feedForwardLiveStatus())
    }
}
