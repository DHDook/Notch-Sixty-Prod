import Foundation
import XCTest
@testable import NotchSixty

/// E4 S23: two one-channel captures on two devices joined into one pair, against a fake with
/// per-device rate, drift, anchor jitter and an optional anchor jump.
final class CrossDevicePairCaptureTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let tones: [(hz: Double, amp: Double, phase: Double)] = [
        (23, 1.0, 0.3), (47, 0.8, 1.1), (71, 0.7, 2.0), (97, 0.6, 0.7), (123, 0.6, 4.1), (150, 0.9, 5.2), (181, 0.4, 3.3),
    ]
    private func signal(_ t: Double) -> Double {
        tones.reduce(0) { $0 + $1.amp * sin(2 * .pi * $1.hz * t + $1.phase) } * 0.1
    }

    func testPairMatchesTheAnalyticSignalAtEightRatesAndMixedMonitorRates() throws {
        for (k, rate) in rates.enumerated() {
            let monitorRate = k % 2 == 0 ? 48_000.0 : 44_100.0
            let (frames, error, exact) = try run(
                referenceRate: rate, monitorRate: monitorRate, referenceDrift: 40e-6, monitorDrift: -50e-6,
                jitter: 50e-6, seconds: 4)
            XCTAssertGreaterThan(frames.count, Int(rate), "rate \(rate)")
            XCTAssertEqual(frames.count, error.count)
            // Coherence stand-in: normalised correlation of the aligned monitor with the expected one.
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for i in frames.indices {
                let x = Double(error[i]), y = exact(frames[i])
                sxy += x * y; sxx += x * x; syy += y * y
            }
            XCTAssertGreaterThan(sxy / (sxx * syy).squareRoot(), 0.99, "rate \(rate)")
            // Phase of the 150 Hz component against the expected one: within 2 degrees.
            var xr = 0.0, xi = 0.0, yr = 0.0, yi = 0.0
            for i in frames.indices {
                let t = Double(frames[i].firstFrameSampleTime + Double(frames[i].frameOffset)) / rate
                let w = 2 * Double.pi * 150 * t
                let x = Double(error[i]), y = exact(frames[i])
                xr += x * cos(w); xi -= x * sin(w); yr += y * cos(w); yi -= y * sin(w)
            }
            let re = xr * yr + xi * yi, im = xi * yr - xr * yi
            let degrees = atan2(im, re) * 180 / .pi
            XCTAssertLessThan(abs(degrees), 2, "rate \(rate)")
        }
    }

    func testReportedLatencyShiftsTheAlignment() throws {
        // The monitor device reports 2 ms more input latency; its stamps trail by that, and the join removes it.
        let (frames, error, exact) = try run(
            referenceRate: 48_000, monitorRate: 48_000, referenceDrift: 0, monitorDrift: 0, jitter: 0, seconds: 4,
            monitorStampDelay: 0.002, monitorLatency: 0.002)
        var worst = 0.0
        for i in frames.indices { worst = max(worst, abs(Double(error[i]) - exact(frames[i]))) }
        XCTAssertLessThan(worst, 0.002)
    }

    func testDriftOverTheLimitRefusesThePair() {
        XCTAssertThrowsError(try run(
            referenceRate: 48_000, monitorRate: 48_000, referenceDrift: 0, monitorDrift: 300e-6, jitter: 0, seconds: 4)
        ) { XCTAssertTrue(($0 as? CrossDeviceCaptureError).map { if case .clockRefused = $0 { return true } else { return false } } ?? false) }
    }

    func testAnAnchorJumpRefusesThePair() {
        XCTAssertThrowsError(try run(
            referenceRate: 48_000, monitorRate: 48_000, referenceDrift: 0, monitorDrift: 0, jitter: 0, seconds: 4,
            jumpAtCallback: 20, jumpSeconds: 0.001)
        ) { XCTAssertTrue(($0 as? CrossDeviceCaptureError).map { if case .clockRefused = $0 { return true } else { return false } } ?? false) }
    }

    func testALostMonitorCallbackIsAFault() {
        XCTAssertThrowsError(try run(
            referenceRate: 48_000, monitorRate: 48_000, referenceDrift: 0, monitorDrift: 0, jitter: 0, seconds: 4,
            monitorDropsCallback: 10)
        ) { XCTAssertEqual($0 as? CrossDeviceCaptureError, .monitorGap) }
    }

    func testLagrangeInterpolatesALowFrequencySineAccurately() {
        let samples = (0..<64).map { Float(sin(2 * Double.pi * 100 * Double($0) / 48_000)) }
        let value = CrossDevicePairCapture.lagrange(samples, base: 0, j: 30, mu: 0.37)
        XCTAssertEqual(Double(value), sin(2 * .pi * 100 * 30.37 / 48_000), accuracy: 1e-5)
    }

    // MARK: Harness

    /// The reference hears `signal(t)`; the monitor hears `0.5 * signal(t - 3 ms)`. Returns the joined pair and
    /// the expected monitor value for a reference frame.
    private func run(
        referenceRate: Double, monitorRate: Double, referenceDrift: Double, monitorDrift: Double, jitter: Double,
        seconds: Double, monitorStampDelay: Double = 0, monitorLatency: Double = 0,
        jumpAtCallback: Int? = nil, jumpSeconds: Double = 0, monitorDropsCallback: Int? = nil
    ) throws -> ([N60FeedForwardReferenceFrame], [Float], (N60FeedForwardReferenceFrame) -> Double) {
        let delay = 0.003
        let reference = FakeSingleCapture(
            rate: referenceRate, drift: referenceDrift, jitter: jitter, stampDelay: 0, hostOffset: 100,
            jumpAtCallback: jumpAtCallback, jumpSeconds: jumpSeconds, dropsCallback: nil) { 1.0 * self.signal($0) }
        let monitor = FakeSingleCapture(
            rate: monitorRate, drift: monitorDrift, jitter: jitter, stampDelay: monitorStampDelay, hostOffset: 100,
            jumpAtCallback: nil, jumpSeconds: 0, dropsCallback: monitorDropsCallback) { 0.5 * self.signal($0 - delay) }
        let pair = CrossDevicePairCapture(
            reference: reference, monitor: monitor, referenceLatencySeconds: 0,
            monitorLatencySeconds: monitorLatency, hostSeconds: { Double($0) * 1.0e-9 })
        try pair.start()
        var frames: [N60FeedForwardReferenceFrame] = []
        var error: [Float] = []
        let chunk = 4096
        var produced = 0.0
        while produced < seconds {
            reference.produce(frames: chunk)
            monitor.produce(frames: Int((Double(chunk) * monitorRate / referenceRate).rounded(.up)))
            produced += Double(chunk) / referenceRate
            let got = try pair.readPair(maximumFrames: 1 << 20)
            frames += got.reference
            error += got.error
        }
        let exact: (N60FeedForwardReferenceFrame) -> Double = { frame in
            let t = (frame.firstFrameSampleTime + Double(frame.frameOffset)) / referenceRate / (1 + referenceDrift)
            return 0.5 * self.signal(t - delay)
        }
        return (frames, error, exact)
    }
}

/// One device: frames sampled from an acoustic signal at its own (drifting) clock, in 512-frame callbacks whose
/// host stamps carry jitter.
private final class FakeSingleCapture: QuietZoneFeedForwardSingleCapturing {
    let sampleRate: Double
    private let drift: Double, jitter: Double, stampDelay: Double, hostOffset: Double
    private let jumpAtCallback: Int?, jumpSeconds: Double, dropsCallback: Int?
    private let source: (Double) -> Double
    private var next = 0
    private var target = 0
    private var available: [N60FeedForwardReferenceFrame] = []
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    private let callback = 512

    init(rate: Double, drift: Double, jitter: Double, stampDelay: Double, hostOffset: Double,
         jumpAtCallback: Int?, jumpSeconds: Double, dropsCallback: Int?, source: @escaping (Double) -> Double) {
        sampleRate = rate; self.drift = drift; self.jitter = jitter; self.stampDelay = stampDelay
        self.hostOffset = hostOffset; self.jumpAtCallback = jumpAtCallback; self.jumpSeconds = jumpSeconds
        self.dropsCallback = dropsCallback; self.source = source
    }

    func start() throws {}
    func close() {}

    private func noise() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(Int64(bitPattern: state >> 11) % 2_000_001 - 1_000_000) / 1_000_000
    }

    func produce(frames: Int) {
        target += frames
        while next + callback <= target {
            let number = next / callback
            if let dropsCallback, number == dropsCallback { next += callback; continue }
            var stamp = Double(next) / sampleRate / (1 + drift) + hostOffset + stampDelay + jitter * noise()
            if let jumpAtCallback, number == jumpAtCallback { stamp += jumpSeconds }
            for o in 0..<callback {
                var f = N60FeedForwardReferenceFrame()
                f.sample = Float(source(Double(next + o) / sampleRate / (1 + drift)))
                f.firstFrameHostTime = UInt64((stamp * 1.0e9).rounded())
                f.firstFrameSampleTime = Double(next)
                f.frameOffset = UInt32(o)
                available.append(f)
            }
            next += callback
        }
    }

    func readFrames(maximumFrames: Int) throws -> [N60FeedForwardReferenceFrame] {
        let n = min(maximumFrames, available.count)
        let out = Array(available.prefix(n))
        available.removeFirst(n)
        return out
    }
}
