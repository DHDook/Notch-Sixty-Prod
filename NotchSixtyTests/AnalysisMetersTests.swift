import XCTest
@testable import NotchSixty

/// E33 S8: PLR/PSR/crest, true peak, balance, per-band correlation, headroom strip, dropout counter and the
/// third-octave RTA, at the eight standard rates.
final class AnalysisMetersTests: XCTestCase {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Signals

    private func sine(frequency: Double, amplitude: Double, rate: Double, seconds: Double, phase: Double = 0) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate + phase)) }
    }

    /// Deterministic white noise in -1...1 (xorshift).
    private func noise(count: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<count).map { _ in
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Float(Double(s >> 11) / Double(1 << 53) * 2 - 1)
        }
    }

    // MARK: D1

    func testPLRPSRAndCrestOfAKnownSine() {
        for rate in Self.rates {
            let tone = sine(frequency: 997, amplitude: 0.5, rate: rate, seconds: 3.6)
            let silence = [Float](repeating: 0, count: tone.count)
            var loudness = LoudnessMeter(sampleRate: rate)
            var peaks = PeakCrestMeter(sampleRate: rate)
            var i = 0
            while i < tone.count {
                let j = min(i + 4_800, tone.count)
                let l = Array(tone[i..<j]), r = Array(silence[i..<j])
                loudness.process(planar: [l, r])
                peaks.process(left: l, right: r)
                i = j
            }
            let readout = loudness.readout()
            let p = peaks.readout()
            let plr = PeakCrestMeter.plr(truePeakMaxDBTP: p.truePeakMaxDBTP, integratedLUFS: readout.integrated)
            XCTAssertEqual(plr ?? .nan, 3.0, accuracy: 0.1, "PLR at \(rate)")
            XCTAssertEqual((p.truePeakRecentDBTP ?? .nan) - (readout.shortTerm ?? .nan), 3.0, accuracy: 0.1, "PSR at \(rate)")
            XCTAssertEqual(p.crestDB ?? .nan, 3.01, accuracy: 0.1, "crest at \(rate)")
            XCTAssertEqual(p.truePeakMaxDBTP ?? .nan, -6.02, accuracy: 0.1, "true peak at \(rate)")
        }
    }

    func testTruePeakOfQuarterRateSineAtFortyFiveDegrees() {
        // Samples sit at +/-0.707 while the waveform peaks at 0 dBTP: the interpolator must find it (BS.1770-4 Annex 2).
        for rate in Self.rates {
            let tone = sine(frequency: rate / 4, amplitude: 1, rate: rate, seconds: 0.5, phase: Double.pi / 4)
            var meter = PeakCrestMeter(sampleRate: rate)
            meter.process(left: tone, right: tone)
            XCTAssertEqual(meter.readout().truePeakMaxDBTP ?? .nan, 0, accuracy: 0.3, "at \(rate)")
        }
    }

    func testPeakCrestResetClearsMaximum() {
        var meter = PeakCrestMeter(sampleRate: 48_000)
        let tone = sine(frequency: 1_000, amplitude: 0.9, rate: 48_000, seconds: 1)
        meter.process(left: tone, right: tone)
        XCTAssertNotNil(meter.readout().truePeakMaxDBTP)
        meter.reset()
        XCTAssertNil(meter.readout().truePeakMaxDBTP)
    }

    // MARK: D5

    func testBalanceReadsSixDecibelsForAQuieterRightChannel() {
        for rate in Self.rates {
            let l = sine(frequency: 1_000, amplitude: 0.5, rate: rate, seconds: 1.5)
            let r = sine(frequency: 1_000, amplitude: 0.25, rate: rate, seconds: 1.5)
            var meter = BalanceMeter(sampleRate: rate)
            meter.process(left: l, right: r)
            XCTAssertEqual(meter.balanceDB() ?? .nan, 6.02, accuracy: 0.1, "at \(rate)")
        }
    }

    func testBalanceIsNilForSilenceAndClampsOneSidedProgram() {
        var meter = BalanceMeter(sampleRate: 48_000)
        let silence = [Float](repeating: 0, count: 96_000)
        meter.process(left: silence, right: silence)
        XCTAssertNil(meter.balanceDB())
        meter.reset()
        meter.process(left: sine(frequency: 1_000, amplitude: 0.5, rate: 48_000, seconds: 2), right: silence)
        XCTAssertEqual(meter.balanceDB(), BalanceMeter.clampDB)
    }

    // MARK: D6

    func testCorrelationIsPlusOneMinusOneAndNearZeroPerBand() {
        for rate in Self.rates {
            let seconds = 1.0
            let n = Int(rate * seconds)
            let a = noise(count: n, seed: 0x9E3779B97F4A7C15)
            let b = noise(count: n, seed: 0xD1B54A32D192ED03)

            var same = BandCorrelationMeter(sampleRate: rate)
            same.process(left: a, right: a)
            for (band, value) in same.correlations().enumerated() {
                XCTAssertEqual(value ?? .nan, 1, accuracy: 0.001, "in-phase band \(band) at \(rate)")
            }
            var inverted = BandCorrelationMeter(sampleRate: rate)
            inverted.process(left: a, right: a.map { -$0 })
            for (band, value) in inverted.correlations().enumerated() {
                XCTAssertEqual(value ?? .nan, -1, accuracy: 0.001, "inverted band \(band) at \(rate)")
            }
            var independent = BandCorrelationMeter(sampleRate: rate)
            independent.process(left: a, right: b)
            for (band, value) in independent.correlations().enumerated() {
                XCTAssertEqual(value ?? .nan, 0, accuracy: 0.35, "independent band \(band) at \(rate)")
            }
        }
    }

    func testCorrelationSeparatesBands() {
        // A 100 Hz tone in phase and a 5 kHz tone inverted: low +1, high -1.
        let rate = 48_000.0
        let low = sine(frequency: 100, amplitude: 0.3, rate: rate, seconds: 1)
        let high = sine(frequency: 5_000, amplitude: 0.3, rate: rate, seconds: 1)
        let left = zip(low, high).map { $0 + $1 }
        let right = zip(low, high).map { $0 - $1 }
        var meter = BandCorrelationMeter(sampleRate: rate)
        meter.process(left: left, right: right)
        let c = meter.correlations()
        XCTAssertEqual(c[0] ?? .nan, 1, accuracy: 0.05)
        XCTAssertEqual(c[2] ?? .nan, -1, accuracy: 0.05)
    }

    // MARK: D7

    func testHeadroomStripHoldsPeaksAndResets() {
        var strip = HeadroomStripModel()
        strip.update(peaks: ["input": 0.5, "postEQ": 0.25, "output": 0.125])
        XCTAssertEqual(strip.points[0].peakDBFS, -6.02, accuracy: 0.01)
        XCTAssertEqual(strip.points[1].peakDBFS, -12.04, accuracy: 0.01)
        XCTAssertEqual(strip.points[2].peakDBFS, -18.06, accuracy: 0.01)
        strip.update(peaks: ["input": 0.1])
        XCTAssertEqual(strip.points[0].peakDBFS, -20, accuracy: 0.01)
        XCTAssertEqual(strip.points[0].holdDBFS, -6.02, accuracy: 0.01)
        XCTAssertEqual(strip.points[0].headroomDB, 6.02, accuracy: 0.01)
        XCTAssertEqual(strip.points[1].holdDBFS, -12.04, accuracy: 0.01, "an absent reading leaves the point alone")
        strip.reset()
        XCTAssertEqual(strip.points[0].holdDBFS, HeadroomStripModel.floorDB)
    }

    // MARK: Dropouts

    func testDropoutCounterCountsEventsFramesAndLastTime() {
        var counter = DropoutCounter()
        let t0 = Date(timeIntervalSince1970: 1_000)
        counter.observe(underrunFrames: 100, overrunFrames: 0, now: t0)
        XCTAssertEqual(counter.events, 0, "the first observation is the baseline")
        counter.observe(underrunFrames: 100, overrunFrames: 0, now: t0 + 1)
        XCTAssertEqual(counter.events, 0)
        counter.observe(underrunFrames: 612, overrunFrames: 0, now: t0 + 2)
        counter.observe(underrunFrames: 612, overrunFrames: 256, now: t0 + 3)
        counter.observe(underrunFrames: 1_124, overrunFrames: 512, now: t0 + 4)
        XCTAssertEqual(counter.events, 3)
        XCTAssertEqual(counter.frames, 512 + 256 + 512 + 256)
        XCTAssertEqual(counter.lastEvent, t0 + 4)
        // A new session starts its counters again: no event.
        counter.observe(underrunFrames: 0, overrunFrames: 0, now: t0 + 5)
        XCTAssertEqual(counter.events, 3)
        counter.reset()
        XCTAssertEqual(counter, DropoutCounter())
    }

    // MARK: D8

    private func decimation(for rate: Double) -> Int {
        var d = 1
        while rate / Double(d) > 50_000 { d *= 2 }
        return d
    }

    func testBandCentresAreTheThirtyOneIECBands() {
        XCTAssertEqual(RTABandMap.bandIndices.count, RTABandMap.bandCount)
        XCTAssertEqual(RTABandMap.nominal.count, RTABandMap.bandCount)
        for (n, nominal) in zip(RTABandMap.bandIndices, RTABandMap.nominal) {
            XCTAssertEqual(RTABandMap.centre(n) / nominal, 1, accuracy: 0.03)
        }
    }

    func testPinkSpectrumIntegratesFlatPerBandAtEveryRate() {
        for rate in Self.rates {
            let lowRate = rate / Double(decimation(for: rate))
            let rta = ThirdOctaveRTA(sampleRate: rate)
            let lowIndices = Array(RTABandMap.bandIndices.prefix(ThirdOctaveRTA.lowBandCount))
            let highIndices = Array(RTABandMap.bandIndices.dropFirst(ThirdOctaveRTA.lowBandCount))
            let lowMap = RTABandMap(indices: lowIndices, size: ThirdOctaveRTA.lowSize, sampleRate: lowRate)
            let highMap = RTABandMap(indices: highIndices, size: rta.highSize, sampleRate: rate)
            // Power per bin of a 1/f density is density times bin width: 1/k, independent of the transform.
            func pink(size: Int, rate: Double) -> [Double] {
                (0...(size / 2)).map { $0 == 0 ? 0 : 1 / Double($0) }
            }
            var low = [Double](repeating: 0, count: lowIndices.count)
            var high = [Double](repeating: 0, count: highIndices.count)
            pink(size: ThirdOctaveRTA.lowSize, rate: lowRate).withUnsafeBufferPointer { lowMap.integrate($0, into: &low) }
            pink(size: rta.highSize, rate: rate).withUnsafeBufferPointer { highMap.integrate($0, into: &high) }
            let levels = (low + high).map { 10 * log10($0) }
            let bandsBelowNyquist = zip(RTABandMap.bandIndices, levels).filter {
                RTABandMap.centre($0.0) * pow(10, 0.05) < rate / 2
            }.map { $0.1 }
            let spread = (bandsBelowNyquist.max() ?? 0) - (bandsBelowNyquist.min() ?? 0)
            XCTAssertLessThan(spread, 1.0, "pink spread \(spread) dB at \(rate)")
            let mean = bandsBelowNyquist.reduce(0, +) / Double(bandsBelowNyquist.count)
            for level in bandsBelowNyquist { XCTAssertEqual(level, mean, accuracy: 0.5, "at \(rate)") }
        }
    }

    func testLowestBandSpansAtLeastThreeBinsAtEveryRate() {
        for rate in Self.rates {
            let lowRate = rate / Double(decimation(for: rate))
            let map = RTABandMap(indices: [-17], size: ThirdOctaveRTA.lowSize, sampleRate: lowRate)
            XCTAssertGreaterThanOrEqual(map.weights[0].filter { $0 > 0 }.count, 3, "at \(rate)")
        }
    }

    func testBandCentreToneReadsItsLevelWithinTwoTenthsOfADecibel() {
        for rate in Self.rates {
            let rta = ThirdOctaveRTA(sampleRate: rate)
            let seconds = Double(ThirdOctaveRTA.lowSize * rta.decimation) / rate + 0.1
            // 20 Hz (index 0), 100 Hz (index 7), 1 kHz (index 17), 10 kHz (index 27).
            for bandIndex in [0, 7, 17, 27] {
                rta.reset()
                let frequency = RTABandMap.centre(RTABandMap.bandIndices[bandIndex])
                let tone = sine(frequency: frequency, amplitude: 0.5, rate: rate, seconds: seconds)
                rta.ingest(left: tone, right: tone)
                guard let levels = rta.bandLevelsDB() else { return XCTFail("rings not full at \(rate)") }
                XCTAssertEqual(Double(levels[bandIndex]), -6.02, accuracy: 0.2, "band \(bandIndex) at \(rate)")
                if bandIndex + 3 < levels.count {
                    XCTAssertLessThan(levels[bandIndex + 3], levels[bandIndex] - 25, "selectivity, band \(bandIndex) at \(rate)")
                }
            }
        }
    }

    // MARK: Worker feed

    private func frames(_ left: [Float], _ right: [Float]) -> [N60AnalysisFrame] {
        zip(left, right).map { N60AnalysisFrame(inputLeft: $0, inputRight: $1, outputLeft: $0, outputRight: $1) }
    }

    func testHiddenFeedDoesNoWorkAndPublishesNothing() {
        let feed = ProductionAnalysisMeterFeed()
        feed.setActive(meters: false, rta: false, sampleRate: 48_000)
        let tone = sine(frequency: 1_000, amplitude: 0.5, rate: 48_000, seconds: 1)
        let input = frames(tone, tone)
        input.withUnsafeBufferPointer { feed.ingest($0) }
        XCTAssertNil(feed.meterReadout(loudness: nil))
        XCTAssertTrue(feed.rtaLevels().isEmpty)
        XCTAssertFalse(feed.isMeterActive)
        XCTAssertFalse(feed.isRTAActive)

        feed.setActive(meters: true, rta: true, sampleRate: 48_000)
        input.withUnsafeBufferPointer { feed.ingest($0) }
        XCTAssertNotNil(feed.meterReadout(loudness: nil))
        // Hiding the card releases its state: the next time it shows it starts empty.
        feed.setActive(meters: false, rta: false, sampleRate: 48_000)
        feed.setActive(meters: true, rta: false, sampleRate: 48_000)
        XCTAssertNil(feed.meterReadout(loudness: nil)?.truePeakMaxDBTP)
        XCTAssertTrue(feed.rtaLevels().isEmpty)
    }

    func testFeedPublishesMetersAndResetClearsThem() {
        let rate = 48_000.0
        let feed = ProductionAnalysisMeterFeed()
        feed.setActive(meters: true, rta: true, sampleRate: rate)
        let l = sine(frequency: 1_000, amplitude: 0.5, rate: rate, seconds: 2)
        let r = sine(frequency: 1_000, amplitude: 0.25, rate: rate, seconds: 2)
        frames(l, r).withUnsafeBufferPointer { feed.ingest($0) }
        let readout = feed.meterReadout(loudness: LoudnessReadout(
            momentary: -20, shortTerm: -20, integrated: -20, range: nil, momentaryMax: nil, shortTermMax: nil,
            isGapped: false, measuredSeconds: 2))
        XCTAssertEqual(readout?.balanceDB ?? .nan, 6.02, accuracy: 0.1)
        XCTAssertEqual(readout?.plr ?? .nan, (readout?.truePeakMaxDBTP ?? .nan) + 20, accuracy: 1e-9)
        XCTAssertEqual(feed.rtaLevels().count, RTABandMap.bandCount)
        feed.reset()
        XCTAssertNil(feed.meterReadout(loudness: nil)?.truePeakMaxDBTP)
    }
}
