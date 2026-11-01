import Foundation
import XCTest
@testable import NotchSixty

/// E4 S25c: the live feed-forward reference pump against simulated reference and output clocks.
@MainActor
final class FeedForwardLiveReferencePumpTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let tones: [(hz: Double, amp: Double, phase: Double)] = [
        (23, 1.0, 0.3), (47, 0.8, 1.1), (71, 0.7, 2.0), (97, 0.6, 0.7), (123, 0.6, 4.1), (150, 0.9, 5.2), (181, 0.4, 3.3),
    ]
    private let wallStart = 100.0
    private func signal(_ t: Double) -> Double {
        tones.reduce(0) { $0 + $1.amp * sin(2 * .pi * $1.hz * t + $1.phase) } * 0.1
    }

    private final class FakeReference: QuietZoneFeedForwardSingleCapturing {
        let sampleRate: Double
        let drift: Double
        let wallStart: Double
        let signal: (Double) -> Double
        var gapAtBlock: Int?
        private var nextFrame = 0
        private var blocks = 0
        private let block = 256
        var pending: [N60FeedForwardReferenceFrame] = []
        init(rate: Double, drift: Double, wallStart: Double, signal: @escaping (Double) -> Double) {
            sampleRate = rate; self.drift = drift; self.wallStart = wallStart; self.signal = signal
        }
        func wall(_ k: Int) -> Double { wallStart + Double(k) / (sampleRate * (1 + drift)) }
        func advance(to t: Double) {
            while wall(nextFrame + block - 1) <= t {
                if gapAtBlock == blocks { nextFrame += 40 }
                blocks += 1
                let jitter = 20e-6 * sin(Double(blocks) * 1.7)
                let host = UInt64(((wall(nextFrame) + jitter) * 1e9).rounded())
                for o in 0..<block {
                    pending.append(N60FeedForwardReferenceFrame(
                        sample: Float(signal(wall(nextFrame + o))), firstFrameHostTime: host,
                        firstFrameSampleTime: Double(1000 + nextFrame), frameOffset: UInt32(o)))
                }
                nextFrame += block
            }
        }
        func start() throws {}
        func readFrames(maximumFrames: Int) throws -> [N60FeedForwardReferenceFrame] {
            let out = Array(pending.prefix(maximumFrames))
            pending.removeFirst(out.count)
            return out
        }
        func close() {}
    }

    private final class FakeSink: FeedForwardLiveReferenceSink {
        var attached = true
        var outputIndex: UInt64 = 0
        var ring: [UInt64: Float] = [:]
        var lost = 0
        func liveReferenceOutputIndex() -> UInt64? { attached ? outputIndex : nil }
        func pushLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
            for (k, v) in samples.enumerated() { ring[startIndex + UInt64(k)] = v }
            return startIndex + UInt64(samples.count)
        }
        func markLiveReferenceLost() { lost += 1 }
    }

    private struct Run {
        var pump: FeedForwardLiveReferencePump
        var sink: FakeSink
        var worstError: Double
        var checked: Int
        var finalState: FeedForwardLiveReferencePump.State
    }

    private func run(
        referenceRate: Double, outputRate: Double, referenceDrift: Double, outputDrift: Double,
        delay: Double = 0.08, referenceLatency: Double = 0, stampLatency: Double = 0,
        seconds: Double = 6, gapAtBlock: Int? = nil, attached: Bool = true
    ) throws -> Run {
        let reference = FakeReference(rate: referenceRate, drift: referenceDrift, wallStart: wallStart) {
            [signal] t in signal(t - stampLatency)
        }
        reference.gapAtBlock = gapAtBlock
        let sink = FakeSink()
        sink.attached = attached
        let pump = FeedForwardLiveReferencePump(
            reference: reference, sink: sink, outputRate: outputRate, delaySeconds: delay,
            referenceLatencySeconds: referenceLatency, hostSeconds: { Double($0) * 1e-9 })
        try pump.start()
        let callback: UInt64 = 512
        func outWall(_ i: UInt64) -> Double { wallStart + Double(i) / (outputRate * (1 + outputDrift)) }
        var nextCallback: UInt64 = 0
        var t = wallStart
        while t < wallStart + seconds {
            t += 0.005
            reference.advance(to: t)
            sink.outputIndex = UInt64(max(0, (t - wallStart) * outputRate * (1 + outputDrift)))
            var anchors: [N60SpeakerDriveAnchor] = []
            while nextCallback + callback <= sink.outputIndex {
                let jitter = 15e-6 * sin(Double(nextCallback) * 0.001)
                anchors.append(N60SpeakerDriveAnchor(
                    outputHostTime: UInt64(((outWall(nextCallback) + jitter) * 1e9).rounded()),
                    firstFrameIndex: nextCallback, frames: UInt32(callback),
                    reserved: UInt32(truncatingIfNeeded: nextCallback)))
                nextCallback += callback
            }
            pump.step(anchors: anchors)
        }
        var worst = 0.0
        var checked = 0
        for (i, v) in sink.ring where i > UInt64(outputRate * 3.5) {
            let expected = signal(outWall(i) - delay)
            worst = max(worst, abs(Double(v) - expected))
            checked += 1
        }
        return Run(pump: pump, sink: sink, worstError: worst, checked: checked, finalState: pump.state)
    }

    func testReferenceLandsOnTheOutputClockAtEightRatesWithDrift() throws {
        for (k, outRate) in rates.enumerated() {
            let refRate = rates[(k + 3) % rates.count]
            let r = try run(referenceRate: refRate, outputRate: outRate, referenceDrift: 40e-6, outputDrift: -30e-6)
            XCTAssertEqual(r.finalState, .running, "ref \(refRate) out \(outRate)")
            XCTAssertGreaterThan(r.checked, Int(outRate), "ref \(refRate) out \(outRate)")
            XCTAssertLessThan(r.worstError, 0.003, "ref \(refRate) out \(outRate)")
            XCTAssertEqual(r.sink.lost, 0)
            XCTAssertEqual(r.pump.lateJumps, 0)
        }
    }

    func testReportedInputLatencyShiftsTheReference() throws {
        // The capture stamps sound 3 ms late; the reported latency removes it.
        let r = try run(
            referenceRate: 48_000, outputRate: 96_000, referenceDrift: 0, outputDrift: 0,
            referenceLatency: 0.003, stampLatency: 0.003)
        XCTAssertEqual(r.finalState, .running)
        XCTAssertLessThan(r.worstError, 0.003)
    }

    func testDriftOverTheLimitStopsAndMarksTheReferenceLost() throws {
        let r = try run(referenceRate: 48_000, outputRate: 48_000, referenceDrift: 0, outputDrift: 300e-6)
        guard case .stopped(let reason) = r.finalState else { return XCTFail("expected stop, got \(r.finalState)") }
        XCTAssertTrue(reason.contains("drift"), reason)
        XCTAssertEqual(r.sink.lost, 1)
    }

    func testLostReferenceSamplesStopThePump() throws {
        let r = try run(referenceRate: 48_000, outputRate: 48_000, referenceDrift: 0, outputDrift: 0, gapAtBlock: 100)
        guard case .stopped = r.finalState else { return XCTFail("expected stop, got \(r.finalState)") }
        XCTAssertEqual(r.sink.lost, 1)
    }

    func testNothingIsWrittenWhileTheLiveFilterIsDetached() throws {
        let r = try run(referenceRate: 48_000, outputRate: 48_000, referenceDrift: 0, outputDrift: 0, attached: false)
        XCTAssertEqual(r.finalState, .aligning)
        XCTAssertTrue(r.sink.ring.isEmpty)
        XCTAssertEqual(r.sink.lost, 0)
    }

    func testOutputIndexUnwrapsAcrossThe32BitBoundary() {
        let wrap: UInt64 = 1 << 32
        XCTAssertEqual(FeedForwardLiveReferencePump.unwrap(low: 5, near: wrap - 10), wrap + 5)
        XCTAssertEqual(FeedForwardLiveReferencePump.unwrap(low: UInt32.max - 2, near: wrap + 10), wrap - 3)
        XCTAssertEqual(FeedForwardLiveReferencePump.unwrap(low: 100, near: 90), 100)
        XCTAssertEqual(FeedForwardLiveReferencePump.unwrap(low: 7, near: 3 * wrap + 7), 3 * wrap + 7)
    }

    func testResamplerAveragesWhenTheReferenceIsFaster() {
        XCTAssertEqual(FeedForwardReferenceResampler.averaging(referenceRate: 48_000, outputRate: 96_000), 1)
        XCTAssertEqual(FeedForwardReferenceResampler.averaging(referenceRate: 384_000, outputRate: 44_100), 9)
        let x = (0..<64).map { Float(sin(Double($0) * 0.05)) }
        XCTAssertNotNil(FeedForwardReferenceResampler.value(x, base: 10, position: 40.3, averaging: 9))
        XCTAssertNil(FeedForwardReferenceResampler.value(x, base: 10, position: 12.0, averaging: 9))
        XCTAssertNil(FeedForwardReferenceResampler.value(x, base: 10, position: 72.0, averaging: 9))
    }
}
