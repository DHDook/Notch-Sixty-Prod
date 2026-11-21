import XCTest
@testable import NotchSixty

/// E33 S11b part 3 (G92, G69, S14, S15, S26, S27): end-to-end and lab cases through production wiring at the eight rates, with
/// `e33.page-enhancements` on. Same harness as `E33ShipEndToEndTests` (page model, engine publish path, `UnifiedGraphHost`).
extension E33ShipEndToEndTests {
    private func peakDB(_ x: ArraySlice<Float>) -> Double {
        20 * log10(Double(x.map { abs($0) }.max() ?? 0))
    }

    private func settledGainDB(_ host: UnifiedGraphHost, hz: Double, amplitude: Double, rate: Double) throws -> Double {
        let n = Int(rate * 0.5)
        let input = tone(hz, amplitude: amplitude, rate: rate, frames: n)
        let out = try run(host, input: input)
        let tail = (n - Int(rate * 0.1))..<n
        return 20 * log10(rms(out[tail]) / rms(input[tail]))
    }

    // MARK: S26 matched filters (G92)

    /// A new band with "Use matched filters" on, set the way the page sets it, renders through the published graph with the
    /// analogue bell's gain at its centre at every rate that carries it, and keeps the bell's shape at 20 kHz at 44.1 and 48 kHz
    /// where the cookbook bell has collapsed (G51). A cookbook band at the same settings is the control.
    func testMatchedBandReachesTheGraphAtEveryRate() throws {
        for rate in rates where rate * 0.42 > 15_000 {
            var matched = EQBand(type: .peaking, frequencyHz: 15_000, gainDB: 6, q: 1)
            matched.filterMethod = .matched
            var cookbook = matched
            cookbook.filterMethod = nil
            var gains: [Double] = [], edge: [Double] = []
            for band in [matched, cookbook] {
                let e = try engine(rate: rate)
                try e.replaceStereoEQConfiguration(StereoEQConfiguration(linkedBands: [band]))
                let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
                defer { host.release() }
                gains.append(try settledGainDB(host, hz: 15_000, amplitude: 0.05, rate: rate))
                if rate <= 48_000 { edge.append(try settledGainDB(host, hz: 20_000, amplitude: 0.05, rate: rate)) }
            }
            XCTAssertEqual(gains[0], 6, accuracy: 0.3, "matched +6 dB at its centre, \(rate)")
            XCTAssertEqual(gains[1], 6, accuracy: 0.3, "cookbook +6 dB at its centre, \(rate)")
            if rate <= 48_000 {
                XCTAssertEqual(edge[0], 4.4, accuracy: 0.8, "matched bell at 20 kHz, \(rate)")
                XCTAssertGreaterThan(edge[0] - edge[1], 2.5, "matched keeps its shape where the cookbook collapses, \(rate)")
            }
        }
    }

    // MARK: S27 linear-phase lengths

    /// A linear-phase EQ at each of the four lengths, set on the page model and designed the way the engine designs it:
    /// the tap count and declared delay are the length's, the response at the band centre is the band's gain, and a length
    /// the FIR engine or the stage budget cannot carry is refused by name instead of designed.
    func testLinearPhaseEQAtEveryLengthAndRate() throws {
        for rate in rates {
            for length in EQLinearPhaseLength.allCases {
                var configuration = StereoEQConfiguration(linkedBands: [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1)])
                configuration.phaseMode = .linearPhase
                configuration.linearPhaseLength = length
                // The expectation comes from the FIR scheme in force (the long-FIR flag raises the tap limit), not from a fixed list.
                let taps = length.tapCount(sampleRate: rate)
                let expectRefused = taps > UnifiedGraphFIRScheme.maxTaps(UnifiedGraphFIRScheme.current())
                    || taps * 2 > EQLinearPhaseLength.tapLaneBudget
                let refusal = length.refusal(sampleRate: rate, laneCount: 2)
                XCTAssertEqual(refusal != nil, expectRefused, "\(length) at \(rate) is refused exactly when it exceeds the FIR scheme or the lane budget")
                if let refusal {
                    XCTAssertTrue(refusal.contains(length.displayName), "the refusal names the length: \(refusal)")
                    continue
                }
                let design = try EQFIRDesigner.design(configuration, sampleRate: rate)
                XCTAssertEqual(design.left.count, length.tapCount(sampleRate: rate), "\(length) at \(rate)")
                XCTAssertEqual(Int(design.declaredLatencyFrames), (design.left.count - 1) / 2)
                var re = 0.0, im = 0.0
                for (k, tap) in design.left.enumerated() {
                    let phase = 2 * Double.pi * 1_000 * Double(k) / rate
                    re += Double(tap) * cos(phase)
                    im -= Double(tap) * sin(phase)
                }
                XCTAssertEqual(20 * log10((re * re + im * im).squareRoot()), 6, accuracy: 0.5, "\(length) at \(rate)")
            }
        }
    }

    // MARK: S14 and S15 limiter Auto Release and starting points

    /// Auto Release set by a starting point reaches the published protection stage with the flag on, and stays off with it off
    /// (the stored fixed release then stays in force).
    func testStartingPointAutoReleaseIsPublishedOnlyWithTheFlag() throws {
        for rate in rates {
            for flagOn in [true, false] {
                flags.setEnabled(flagOn, for: .eqPageEnhancements)
                let e = try engine(rate: rate)
                try e.replaceDynamicsConfiguration(DynamicsStartingPoint.protectSpeakers.applying(to: e.dynamicsConfiguration))
                XCTAssertEqual(try published(e, rate: rate, flagOn: flagOn).protection?.autoRelease, flagOn, "flag \(flagOn) at \(rate)")
            }
        }
    }

    /// G69, Even volume window (S11d): the loudness match in the Even volume recipe pulls a loud and a quiet programme
    /// toward the -16 LUFS target through the published graph, at the eight rates. A 1 kHz tone's loudness is its RMS level
    /// plus 0.7 dB (K-weighting at 1 kHz, ITU-R BS.1770-4, rounded), so the check reads the settled output RMS against the
    /// same quantity at the input. The loud programme (-14 LUFS) is brought down, the quiet one (-34 LUFS) is brought up
    /// by at most the recipe's 12 dB correction limit plus the compressor's make-up, and the gap shrinks.
    func testEvenVolumeWindowLabCaseAtEveryRate() throws {
        for rate in rates {
            var outLUFS: [Double] = [], inLUFS: [Double] = []
            for amplitude in [0.3, 0.03] {
                let e = try engine(rate: rate)
                try e.replaceDynamicsConfiguration(DynamicsStartingPoint.evenVolume.applying(to: e.dynamicsConfiguration))
                let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
                defer { host.release() }
                let n = Int(rate * 12)
                let input = tone(1_000, amplitude: amplitude, rate: rate, frames: n)
                let out = try run(host, input: input, block: 4096)
                let tail = (n - Int(rate * 1))..<n
                inLUFS.append(20 * log10(rms(input[tail])) + 0.7)
                outLUFS.append(20 * log10(rms(out[tail])) + 0.7)
            }
            let inGap = inLUFS[0] - inLUFS[1], outGap = outLUFS[0] - outLUFS[1]
            XCTAssertLessThan(outGap, inGap - 6, "Even volume shrinks the gap between programmes at \(rate): \(inGap) to \(outGap) LU")
            XCTAssertGreaterThan(outGap, 0, "and does not invert them at \(rate)")
            XCTAssertGreaterThan(outLUFS[1] - inLUFS[1], 3, "the quiet programme is brought up at \(rate)")
            XCTAssertEqual(outLUFS[0], -16, accuracy: 2.5, "the loud programme settles near the -16 LUFS target at \(rate)")
            XCTAssertLessThan(outGap, 5, "both programmes sit within a 5 LU window at \(rate)")
        }
    }

    /// G69: the four starting points rendered through the published graph. Late night holds a loud passage down against a
    /// quiet one (the loudness range shrinks); every recipe keeps a full-scale tone under its ceiling; Protect speakers
    /// holds the lower ceiling.
    func testStartingPointLabCasesAtEveryRate() throws {
        for rate in rates {
            for point in DynamicsStartingPoint.allCases {
                let e = try engine(rate: rate)
                try e.replaceDynamicsConfiguration(point.applying(to: e.dynamicsConfiguration))
                let ceiling = point == .protectSpeakers ? -3.0 : -1.0
                let n = Int(rate * 0.6)
                let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
                defer { host.release() }
                let hot = try run(host, input: tone(1_000, amplitude: 1.0, rate: rate, frames: n))
                XCTAssertLessThanOrEqual(peakDB(hot[(n - Int(rate * 0.1))..<n]), ceiling + 0.5, "\(point.title) at \(rate)")
                XCTAssertTrue(hot.allSatisfy(\.isFinite))
            }
            for point in [DynamicsStartingPoint.lateNight] {
                var gains: [Double] = []
                for amplitude in [0.3, 0.003] {
                    let e = try engine(rate: rate)
                    try e.replaceDynamicsConfiguration(point.applying(to: e.dynamicsConfiguration))
                    let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
                    defer { host.release() }
                    gains.append(try settledGainDB(host, hz: 1_000, amplitude: amplitude, rate: rate))
                }
                // The quiet tone gets more gain than the loud one: the range between them shrinks from 40 dB.
                XCTAssertGreaterThan(gains[1] - gains[0], 5, "late night shrinks the loudness range at \(rate): \(gains)")
            }
        }
    }
}
