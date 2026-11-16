import XCTest
@testable import NotchSixty

/// E33 S9: spectrogram image ring and bit-activity meter at the eight standard rates.
final class SpectrogramBitActivityTests: XCTestCase {
    static let rates = AnalysisMetersTests.rates

    private func feed(_ ring: SpectrogramRing, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { ring.ingest(left: $0, right: $0) }
    }

    /// Argmax row of the column written as `index` (absolute).
    private func peakRow(_ snap: SpectrogramSnapshot, column index: Int) -> Int {
        let base = (index % snap.columns) * snap.rows
        var best = 0
        for r in 0..<snap.rows where snap.image[base + r] > snap.image[base + best] { best = r }
        return best
    }

    func testSteppedTonesDrawTheRightRowAtTheRightTime() {
        for rate in Self.rates {
            let ring = SpectrogramRing(sampleRate: rate, window: .tenSeconds)
            let tones: [Double] = [440, 3_000]
            let seconds = 2.0
            for tone in tones {
                let n = Int(seconds * rate)
                feed(ring, (0..<n).map { Float(0.5 * sin(2 * Double.pi * tone * Double($0) / rate)) })
            }
            let snap = ring.snapshot()
            XCTAssertGreaterThan(snap.totalColumns, 10)
            // The newest column holds the second tone; one whose frame ended well before the change holds the first.
            let tolerance = max(snap.binHz, ring.rowCentreHz(snap.rows / 2) * 0.04)
            let last = peakRow(snap, column: snap.totalColumns - 1)
            XCTAssertEqual(ring.rowCentreHz(last), 3_000, accuracy: 3_000 * 0.04 + snap.binHz, "second tone at \(rate)")
            let changeSample = Int(seconds * rate)
            var checkedEarly = false
            for c in 0..<snap.totalColumns {
                let end = SpectrogramRing.columnEndSample(index: c, fftSize: ring.fftSize, hop: ring.hop)
                if end <= changeSample, end >= ring.fftSize {
                    XCTAssertEqual(ring.rowCentreHz(peakRow(snap, column: c)), 440, accuracy: 440 * 0.04 + snap.binHz,
                                   "first tone at \(rate), column \(c)")
                    checkedEarly = true
                }
            }
            XCTAssertTrue(checkedEarly)
            XCTAssertNotNil(snap.row(forHz: 3_000))
            _ = tolerance
        }
    }

    func testSweepTrackFollowsTheInstantaneousFrequencyWithinOneFrame() {
        for rate in Self.rates {
            let ring = SpectrogramRing(sampleRate: rate, window: .tenSeconds)
            let seconds = 8.0, f0 = 200.0, f1 = 4_000.0
            let n = Int(seconds * rate)
            let k = (f1 - f0) / seconds
            feed(ring, (0..<n).map { i in
                let t = Double(i) / rate
                return Float(0.5 * sin(2 * Double.pi * (f0 * t + 0.5 * k * t * t)))
            })
            let snap = ring.snapshot()
            var checked = 0
            for c in max(0, snap.totalColumns - snap.columns)..<snap.totalColumns {
                let end = SpectrogramRing.columnEndSample(index: c, fftSize: ring.fftSize, hop: ring.hop)
                guard end <= n else { continue }
                let centre = (Double(end) - Double(ring.fftSize) / 2) / rate
                let expected = f0 + k * centre
                let measured = ring.rowCentreHz(peakRow(snap, column: c))
                let rowWidth = expected * 0.037 + 0.5 * k * Double(ring.fftSize) / rate   // half the sweep inside one frame
                XCTAssertEqual(measured, expected, accuracy: max(rowWidth, 2 * snap.binHz) + 1, "column \(c) at \(rate)")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 100)
        }
    }

    func testImageRingDoesNotReallocateAfterWarmUp() {
        let rate = 48_000.0
        let ring = SpectrogramRing(sampleRate: rate, window: .tenSeconds)
        let tone = (0..<Int(rate)).map { Float(0.3 * sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
        feed(ring, tone)
        let address = ring.imageStorageAddress
        for _ in 0..<12 { feed(ring, tone) }   // wraps the 480-column ring
        XCTAssertGreaterThan(ring.totalColumns, SpectrogramRing.columns)
        XCTAssertEqual(ring.imageStorageAddress, address)
    }

    func testSixtySecondWindowUsesALongerHop() {
        let short = SpectrogramRing(sampleRate: 48_000, window: .tenSeconds)
        let long = SpectrogramRing(sampleRate: 48_000, window: .sixtySeconds)
        XCTAssertEqual(Double(long.hop) / Double(short.hop), 6, accuracy: 0.01)
    }

    func testSilenceDrawsFloorAndRGBAHasFullSize() {
        let ring = SpectrogramRing(sampleRate: 48_000, window: .tenSeconds)
        feed(ring, [Float](repeating: 0, count: 48_000))
        let snap = ring.snapshot()
        XCTAssertEqual(snap.image.max(), 0)
        let pixels = snap.rgbaPixels()
        XCTAssertEqual(pixels.count, snap.rows * snap.columns * 4)
        XCTAssertEqual(pixels[3], 255)
    }

    func testColourMapRunsDarkToBright() {
        let t = SpectrogramColourMap.table
        func luma(_ i: Int) -> Double { 0.2126 * Double(t[i * 3]) + 0.7152 * Double(t[i * 3 + 1]) + 0.0722 * Double(t[i * 3 + 2]) }
        var last = -1.0
        for i in stride(from: 0, to: 256, by: 8) {
            XCTAssertGreaterThan(luma(i), last)
            last = luma(i)
        }
    }

    // MARK: Bit activity

    private func quantised(_ bits: Int, gain: Double, count: Int, rate: Double = 48_000) -> [Float] {
        let levels = Double(1 << (bits - 1))
        var s: UInt64 = 0x9E3779B97F4A7C15
        return (0..<count).map { i in
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            let noise = Double(s >> 11) / Double(1 << 53) * 2 - 1
            let v = 0.6 * sin(2 * Double.pi * 997 * Double(i) / rate) + 0.3 * noise
            return Float((v * levels).rounded() / levels * gain)
        }
    }

    func testSixteenBitContentInAWordOfTwentyFourReadsSixteen() {
        for rate in Self.rates {
            var meter = BitActivityMeter()
            let x = quantised(16, gain: 1, count: Int(rate * 0.5), rate: rate)
            meter.process(left: x, right: x)
            for channel in meter.readout() {
                XCTAssertEqual(channel.verdict, .exact(bits: 16), "at \(rate)")
                XCTAssertEqual(channel.text, "16-bit content")
                XCTAssertEqual(channel.toggledMask & 0xFF, 0, "low eight bits stay still")
                XCTAssertEqual(channel.toggledMask >> 8, 0xFFFF)
            }
        }
    }

    func testHalfDecibelScaledSignalReadsScaled() {
        let gain = pow(10, -0.5 / 20)
        for rate in Self.rates {
            var meter = BitActivityMeter()
            let x = quantised(16, gain: gain, count: Int(rate * 0.5), rate: rate)
            meter.process(left: x, right: x)
            for channel in meter.readout() {
                guard case .scaled(let approx) = channel.verdict else {
                    return XCTFail("expected scaled at \(rate), got \(channel.verdict)")
                }
                XCTAssertEqual(approx, 16)
                XCTAssertEqual(channel.toggledCount, 24)
                XCTAssertTrue(channel.text.hasPrefix("Scaled, not bit-exact"))
            }
        }
    }

    func testFullTwentyFourBitContentIsNotCalledScaled() {
        var meter = BitActivityMeter()
        let x = quantised(24, gain: 1, count: 48_000)
        meter.process(left: x, right: x)
        XCTAssertEqual(meter.readout()[0].verdict, .exact(bits: 24))
    }

    func testSilenceAndReset() {
        var meter = BitActivityMeter()
        meter.process(left: [Float](repeating: 0, count: 1_000), right: [Float](repeating: 0, count: 1_000))
        XCTAssertEqual(meter.readout()[0].verdict, .silent)
        let x = quantised(16, gain: 1, count: 5_000)
        meter.process(left: x, right: [Float](repeating: 0, count: 5_000))
        XCTAssertEqual(meter.readout()[0].verdict, .exact(bits: 16))
        XCTAssertEqual(meter.readout()[1].verdict, .silent)
        meter.reset()
        XCTAssertEqual(meter.readout()[0].verdict, .silent)
        XCTAssertEqual(meter.readout()[0].samples, 0)
    }

    // MARK: Feed

    func testFeedRunsOnlyWhileTheCardIsVisible() {
        let feed = ProductionSpectrogramFeed()
        feed.setActive(spectrogram: false, window: .tenSeconds, bitActivity: false, sampleRate: 48_000)
        XCTAssertFalse(feed.isSpectrogramActive)
        XCTAssertFalse(feed.isBitActivityActive)
        XCTAssertNil(feed.spectrogramSnapshot())
        XCTAssertTrue(feed.bitActivity().isEmpty)
        feed.setActive(spectrogram: true, window: .tenSeconds, bitActivity: true, sampleRate: 48_000)
        let frames = [N60AnalysisFrame](repeating: N60AnalysisFrame(inputLeft: 0.25, inputRight: -0.25, outputLeft: 0.1, outputRight: 0.1), count: 20_000)
        frames.withUnsafeBufferPointer { feed.ingest($0) }
        XCTAssertGreaterThan(feed.spectrogramSnapshot()?.totalColumns ?? 0, 0)
        XCTAssertEqual(feed.bitActivity().count, 2)
        feed.setActive(spectrogram: false, window: .tenSeconds, bitActivity: false, sampleRate: 48_000)
        XCTAssertNil(feed.spectrogramSnapshot())
        XCTAssertTrue(feed.bitActivity().isEmpty)
    }

    func testWorkerDemandBitsDoNotCollideAndAreAccepted() {
        let bits: [UInt32] = [
            ProductionAnalysisDemand.loudness, ProductionAnalysisDemand.resetLoudness, ProductionAnalysisDemand.analysisMeters,
            ProductionAnalysisDemand.rta, ProductionAnalysisDemand.resetAnalysisMeters, ProductionAnalysisDemand.spectrogram,
            ProductionAnalysisDemand.spectrogramLong, ProductionAnalysisDemand.bitActivity, ProductionAnalysisDemand.resetBitActivity,
        ]
        XCTAssertEqual(bits.reduce(0, |), bits.reduce(0, +))
        for bit in bits { XCTAssertEqual(ProductionAnalysisDemand.workerBits & bit, bit) }
    }
}
