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

    /// Seeded, band-limited noise (white noise through a one-pole low-pass at about 4 kHz), uniform level `amplitude`, as a
    /// stand-in for programme material: the K-weighting sees a real spectrum, not one tone. Same samples at every rate.
    func programmeNoise(amplitude: Double, rate: Double, seconds: Double, seed: UInt64) -> [Float] {
        var state = seed, lp = 0.0
        let k = 1 - exp(-2 * Double.pi * 4_000 / rate)
        return (0..<Int(rate * seconds)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Double(Int64(bitPattern: state) >> 11) / Double(1 << 52)   // uniform in [-1, 1)
            lp += k * (white - lp)
            return Float(amplitude * lp / (k / 2).squareRoot())   // unit-variance-ratio scaling: the same level at every rate
        }
    }

    /// Renders `input` (same on both channels) through a starting point's published graph and returns the left output.
    func renderStartingPoint(_ point: DynamicsStartingPoint?, input: [Float], rate: Double) throws -> [Float] {
        let e = try engine(rate: rate)
        if let point { try e.replaceDynamicsConfiguration(point.applying(to: e.dynamicsConfiguration)) }
        let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
        defer { host.release() }
        return try run(host, input: input, block: 4096)
    }

    /// G69, Even volume window (S11d): a loud and a quiet programme (the same band-limited noise 26 dB apart) through the
    /// Even volume recipe, measured with the BS.1770-4 reference meter (`BS1770ReferenceMeter`, integrated loudness over the
    /// last 6 s, after the 1 s attack and 3 s release have settled), at the eight rates.
    func testEvenVolumeWindowLabCaseAtEveryRate() throws {
        for rate in rates {
            var inLUFS: [Double] = [], outLUFS: [Double] = []
            for amplitude in [0.2, 0.01] {
                let input = programmeNoise(amplitude: amplitude, rate: rate, seconds: 14, seed: 7)
                let out = try renderStartingPoint(.evenVolume, input: input, rate: rate)
                let tail = (input.count - Int(rate * 6))..<input.count
                inLUFS.append(BS1770ReferenceMeter.integratedLoudness([Array(input[tail])], rate: rate) + 3.0103)
                outLUFS.append(BS1770ReferenceMeter.integratedLoudness([Array(out[tail])], rate: rate) + 3.0103)
            }
            let inGap = inLUFS[0] - inLUFS[1], outGap = outLUFS[0] - outLUFS[1]
            // Measured at every rate: loud -14.6 to -15.0 LUFS, quiet -25.6 to -26.5 LUFS (the quiet one is held by the
            // recipe's 12 dB correction limit), so a 26 LU gap becomes about 11 LU.
            XCTAssertEqual(inGap, 26, accuracy: 0.1, "the programmes are 26 LU apart at \(rate)")
            XCTAssertEqual(outLUFS[0], -16, accuracy: 2, "the loud programme settles near the -16 LUFS target at \(rate): \(outLUFS[0])")
            XCTAssertGreaterThan(outLUFS[1] - inLUFS[1], 11, "the quiet programme is lifted by about the 12 dB limit at \(rate)")
            XCTAssertLessThan(outGap, 13, "the window is under 13 LU at \(rate): \(outGap)")
            XCTAssertGreaterThan(outGap, 0, "and the programmes are not inverted at \(rate)")
        }
    }

    /// G69, Late night loudness range (S11d): programme with a real range (6 s sections of the same noise alternating
    /// between loud and 15 dB lower, inside the 20 LU relative gate of Tech 3342), with and without the recipe. The BS.1770-4 / Tech 3342 loudness range of the output
    /// is measured against the unprocessed programme at the eight rates.
    func testLateNightLoudnessRangeLabCaseAtEveryRate() throws {
        for rate in rates {
            let sections = (0..<4).map { programmeNoise(amplitude: $0 % 2 == 0 ? 0.2 : 0.035, rate: rate, seconds: 6, seed: UInt64(11 + $0)) }
            let input = sections.flatMap { $0 }
            let out = try renderStartingPoint(.lateNight, input: input, rate: rate)
            let before = BS1770ReferenceMeter.loudnessRange([input, input], rate: rate)
            let after = BS1770ReferenceMeter.loudnessRange([out, out], rate: rate)
            // Measured: 15.15 LU in, 6.4 to 6.8 LU out (a drop of 8.4 to 8.8 LU) at every rate.
            XCTAssertEqual(before, 15.15, accuracy: 0.3, "the programme has a real range at \(rate): \(before)")
            XCTAssertLessThan(after, before - 8, "Late night cuts the loudness range by more than 8 LU at \(rate): \(before) to \(after)")
            XCTAssertGreaterThan(after, 3, "and keeps a range at \(rate): \(after)")
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
