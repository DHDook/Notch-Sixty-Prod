import XCTest
@testable import NotchSixty

/// E28 S7d part 3: the translator emission of the extras (G34, G37, G40), lab cases that run the extras through the
/// production translator and the core at the eight rates (G34, G37, G40), the compressor law against an independent model
/// (G23, G26), the lookahead-only fade law (G34) and the listen repost failure (G37).
@MainActor
final class DynamicsExtrasGapsTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Harness

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_431, uid: "dynextras-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "dynextras-out")
        return engine
    }

    /// The stereo graph configuration the production translator builds for `d`, with the extras as the live path passes them.
    private func configuration(_ d: DynamicsConfiguration, engine: AudioIOEngine, rate: Double, extras: Bool = true) throws -> UnifiedGraphConfiguration {
        try engine.replaceDynamicsConfiguration(d)
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        return try UnifiedGraphTranslator.stereoEligibility(
            snapshot: &snapshot, sampleRate: rate,
            compressorExtras: extras ? d.compressor.coreExtras(sampleRate: rate) : nil,
            expanderExtras: extras ? d.expander.coreExtras() : nil,
            multibandExtras: extras ? d.multibandCompressor.coreExtras(sampleRate: rate) : nil
        ).get()
    }

    private func run(_ host: UnifiedGraphHost, left: [Float], right: [Float], block: Int = 512) throws -> [[Float]] {
        var out: [[Float]] = [[], []]
        var position = 0
        while position < left.count {
            let count = min(block, left.count - position)
            let result = try host.processOffline(
                input: [Array(left[position..<position + count]), Array(right[position..<position + count])], frames: count)
            out[0] += result[0]
            out[1] += result[1]
            position += count
        }
        return out
    }

    private func tone(_ hz: Double, amplitude: Double, rate: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    private func peak(_ x: [Float], _ range: Range<Int>) -> Float { x[range].map { abs($0) }.max() ?? 0 }

    private func dB(_ x: Float) -> Double { 20 * log10(max(Double(x), 1e-12)) }

    private func goertzel(_ x: [Float], hz: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() {
            let phase = 2 * Double.pi * hz * Double(i) / rate
            re += Double(v) * cos(phase)
            im -= Double(v) * sin(phase)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(x.count)
    }

    // MARK: Translator emission (G34, G37, G40)

    func testTranslatorEmitsTheExtendedBlocksAtEveryRate() throws {
        for rate in rates {
            var d = DynamicsConfiguration()
            d.compressor.enabled = true
            d.compressor.mixPercent = 50
            d.compressor.linkPercent = 0
            d.compressor.rmsDetector = true
            d.compressor.lookaheadMs = 5
            d.expander.enabled = true
            d.expander.kneeDB = 6
            d.expander.holdMs = 50
            d.expander.sidechainHighPassHz = 80
            d.multibandCompressor.enabled = true
            d.multibandCompressor.autoReleaseBands = [0, 2]
            d.multibandCompressor.bypassedBands = [1]
            d.multibandCompressor.lookaheadMs = 5
            let e = try engine(rate: rate)
            let on = try configuration(d, engine: e, rate: rate, extras: true).stereoStages
            let off = try configuration(d, engine: e, rate: rate, extras: false).stereoStages

            let comp = try XCTUnwrap(on.compressor), compBase = try XCTUnwrap(off.compressor)
            XCTAssertEqual(compBase.count, 10, "flag off keeps the 10-value block at \(rate)")
            XCTAssertEqual(comp.count, 16)
            XCTAssertEqual(Array(comp[0..<10]), compBase)
            XCTAssertEqual(Array(comp[10...]), d.compressor.coreExtras(sampleRate: rate))
            XCTAssertEqual(comp[10], 50)
            XCTAssertEqual(comp[11], 0)
            XCTAssertEqual(comp[12], 1)
            XCTAssertEqual(Int(comp[14]), CompressorConfiguration.lookaheadFrames(ms: 5, sampleRate: rate))
            XCTAssertEqual(comp[15], 0, "listen is off at build")

            let exp = try XCTUnwrap(on.expander), expBase = try XCTUnwrap(off.expander)
            XCTAssertEqual(expBase.count, 6)
            XCTAssertEqual(exp.count, 13)
            XCTAssertEqual(Array(exp[0..<6]), expBase)
            XCTAssertEqual(Array(exp[6...]), d.expander.coreExtras())
            XCTAssertEqual(exp[6], 50, "hold ms")
            XCTAssertEqual(exp[7], 6, "knee dB")
            XCTAssertEqual(exp[10], 80, "sidechain high-pass Hz")

            let mb = try XCTUnwrap(on.multiband), mbBase = try XCTUnwrap(off.multiband)
            XCTAssertEqual(mbBase.count, 29)
            XCTAssertEqual(mb.count, 44)
            XCTAssertEqual(Array(mb[0..<26]), Array(mbBase[0..<26]))
            XCTAssertEqual(Array(mb[26..<29]), [1, 0, 1], "auto-release flags replace the three zeros")
            XCTAssertEqual(Array(mb[29..<43]), Array(d.multibandCompressor.coreExtras(sampleRate: rate)[3...]))
            XCTAssertEqual(mb[43], 1, "E28 G42: the band-pass split is on with the extras")
            XCTAssertEqual(Int(mb[42]), CompressorConfiguration.lookaheadFrames(ms: 5, sampleRate: rate))
        }
    }

    // MARK: Compressor lab cases (G34)

    /// Mix 50 %, link 0 %, RMS detector, lookahead 5 ms: the impulse delay equals the reported latency, and the settled wet
    /// is the mean of the delayed dry and the processed signal.
    func testCompressorExtrasLabCaseDelayAndMixAtEveryRate() throws {
        for rate in rates {
            var d = DynamicsConfiguration()
            d.compressor.enabled = true
            d.compressor.thresholdDB = -30
            d.compressor.ratio = 4
            d.compressor.kneeWidthDB = 0
            d.compressor.attackMs = 1
            d.compressor.releaseMs = 100
            d.compressor.linkPercent = 0
            d.compressor.rmsDetector = true
            d.compressor.rmsWindowMs = 20
            let e = try engine(rate: rate)

            // Delay: an impulse below the threshold passes at unity, later by the lookahead.
            var plain = d, ahead = d
            plain.compressor.mixPercent = 50
            ahead.compressor.mixPercent = 50
            ahead.compressor.lookaheadMs = 5
            var delays: [Int] = []
            var reported: [Int] = []
            for config in [plain, ahead] {
                let host = try UnifiedGraphHost(spec: try configuration(config, engine: e, rate: rate).makeSpec())
                var impulse = [Float](repeating: 0, count: 4_096 + Int(rate * 0.02))
                impulse[100] = 0.01
                let out = try run(host, left: impulse, right: impulse)
                let index = try XCTUnwrap(out[0].indices.max { abs(out[0][$0]) < abs(out[0][$1]) })
                delays.append(index - 100)
                reported.append(Int(host.latencyFrames))
                XCTAssertEqual(abs(out[0][index]), 0.01, accuracy: 1e-4, "unity below the threshold at \(rate)")
                host.release()
            }
            let frames = CompressorConfiguration.lookaheadFrames(ms: 5, sampleRate: rate)
            XCTAssertEqual(delays[1] - delays[0], frames, "impulse delay at \(rate)")
            XCTAssertEqual(reported[1] - reported[0], frames, "reported latency at \(rate)")
            XCTAssertEqual(delays[1], reported[1], "measured delay equals reported latency at \(rate)")

            // Mix: at 50 % the settled peak is the mean of the dry peak and the 100 % peak.
            let n = Int(rate * 0.8)
            let input = tone(1_000, amplitude: 0.3, rate: rate, frames: n)
            var peaks: [Float] = []
            for mix in [100.0, 50.0] {
                var m = ahead
                m.compressor.mixPercent = mix
                let host = try UnifiedGraphHost(spec: try configuration(m, engine: e, rate: rate).makeSpec())
                let out = try run(host, left: input, right: input)
                peaks.append(peak(out[0], (n - Int(rate * 0.02))..<n))
                host.release()
            }
            XCTAssertLessThan(peaks[0], 0.3 * 0.6, "the compressor reduces the loud tone at \(rate)")
            XCTAssertEqual(peaks[1], (0.3 + peaks[0]) / 2, accuracy: 0.004, "mix 50 % at \(rate)")
        }
    }

    /// Link 0 % (and the compressor's own `linked` switch off) leaves a quiet right lane alone while the left is reduced;
    /// link 100 % reduces both.
    func testLinkZeroKeepsTheQuietLaneOffTheLoudLanesGain() throws {
        for rate in [48_000.0, 96_000.0, 384_000.0] {
            let e = try engine(rate: rate)
            var d = DynamicsConfiguration()
            d.compressor.enabled = true
            d.compressor.thresholdDB = -30
            d.compressor.ratio = 8
            d.compressor.kneeWidthDB = 0
            d.compressor.attackMs = 1
            d.compressor.releaseMs = 100
            let n = Int(rate * 0.5)
            let loud = tone(1_000, amplitude: 0.5, rate: rate, frames: n)
            let quiet = tone(1_000, amplitude: 0.01, rate: rate, frames: n)  // -40 dBFS, under the threshold
            let window = (n - Int(rate * 0.02))..<n
            func rightAndLeftDB(_ config: UnifiedGraphConfiguration) throws -> (left: Double, right: Double) {
                let host = try UnifiedGraphHost(spec: try config.makeSpec())
                defer { host.release() }
                let out = try run(host, left: loud, right: quiet)
                return (dB(peak(out[0], window)) - dB(0.5), dB(peak(out[1], window)) - dB(0.01))
            }
            d.compressor.linkPercent = 100
            let full = try rightAndLeftDB(configuration(d, engine: e, rate: rate))
            XCTAssertLessThan(full.right, -6, "linked: the quiet lane follows the loud lane's gain at \(rate)")
            d.compressor.linkPercent = 0
            let zero = try rightAndLeftDB(configuration(d, engine: e, rate: rate))
            XCTAssertEqual(zero.right, 0, accuracy: 0.01, "link 0 % at \(rate)")
            XCTAssertLessThan(zero.left, -6, "the loud lane is still reduced at \(rate)")
            // The compressor's own linked switch (parameter 9) off is the same as link 0 %.
            d.compressor.linkPercent = 100
            var config = try configuration(d, engine: e, rate: rate)
            var block = try XCTUnwrap(config.stereoStages.compressor)
            block[9] = 0
            config.stereoStages.compressor = block
            let unlinked = try rightAndLeftDB(config)
            XCTAssertEqual(unlinked.right, 0, accuracy: 0.01, "linked = 0 at \(rate)")
            XCTAssertEqual(unlinked.left, zero.left, accuracy: 0.05)
        }
    }

    // MARK: Expander and multiband lab cases (G37, G40)

    /// Knee 6 dB, hold 50 ms, sidechain high-pass 80 Hz through the production translator.
    func testExpanderExtrasLabCaseHoldAndHighPassAtEveryRate() throws {
        for rate in rates {
            let e = try engine(rate: rate)
            var d = DynamicsConfiguration()
            d.expander.enabled = true
            d.expander.thresholdDB = -35
            d.expander.ratio = 4
            d.expander.rangeDB = -24
            d.expander.attackMs = 1
            d.expander.releaseMs = 20
            d.expander.kneeDB = 6
            // Loud for 0.3 s then quiet (-54 dBFS, under the threshold): the held expander stays open a while longer.
            let loudFrames = Int(rate * 0.3), quietFrames = Int(rate * 0.4)
            let input = tone(1_000, amplitude: 0.1, rate: rate, frames: loudFrames)
                + tone(1_000, amplitude: 0.002, rate: rate, frames: quietFrames)
            func gainAfterLoud(hold: Double, atMs: Double) throws -> Double {
                var c = d
                c.expander.holdMs = hold
                let host = try UnifiedGraphHost(spec: try configuration(c, engine: e, rate: rate).makeSpec())
                defer { host.release() }
                let out = try run(host, left: input, right: input)
                let start = loudFrames + Int(rate * atMs / 1000)
                return dB(peak(out[0], start..<start + Int(rate * 0.005))) - dB(0.002)
            }
            let held = try gainAfterLoud(hold: 50, atMs: 20)
            let unheld = try gainAfterLoud(hold: 0, atMs: 20)
            XCTAssertGreaterThan(held, -1.5, "inside the 50 ms hold the gain is still open at \(rate): \(held)")
            XCTAssertLessThan(unheld, held - 3, "without hold the expander has closed by 20 ms at \(rate): \(unheld) vs \(held)")
            XCTAssertLessThan(try gainAfterLoud(hold: 50, atMs: 250), -6, "after the hold it closes at \(rate)")

            // The sidechain filter: a 20 Hz tone at -25 dBFS opens an unfiltered expander (above -35) and not one filtered at 80 Hz.
            func lowToneGain(filter: Double) throws -> Double {
                var c = d
                c.expander.sidechainHighPassHz = filter
                let host = try UnifiedGraphHost(spec: try configuration(c, engine: e, rate: rate).makeSpec())
                defer { host.release() }
                let n = Int(rate * 0.8)
                let low = tone(20, amplitude: 0.056, rate: rate, frames: n)
                let out = try run(host, left: low, right: low)
                return dB(peak(out[0], (n - Int(rate * 0.1))..<n)) - dB(0.056)
            }
            let open = try lowToneGain(filter: 0)
            let filtered = try lowToneGain(filter: 80)
            // The peak detector follows the rectified 20 Hz sine, so even unfiltered the gain ripples and the peak sits a few
            // dB under open (about -12 dB at threshold +10 dB, 1 ms attack, 20 ms release): compare filtered against that.
            print("NUMBERS expander 20 Hz open \(open) filtered \(filtered) rate \(rate)")
            XCTAssertLessThan(filtered, open - 3, "the 80 Hz filter keeps 20 Hz from opening it at \(rate): \(filtered) vs \(open)")
        }
    }

    /// G42: the band-pass split is IIR and adds no latency; the reported graph latency is the multiband lookahead only.
    func testMultibandSplitLatencyIsLookaheadOnlyAtEveryRate() throws {
        for rate in rates {
            let e = try engine(rate: rate)
            var d = DynamicsConfiguration()
            d.multibandCompressor.enabled = true
            var latencies: [Int] = []
            for ms in [0.0, 5.0] {
                d.multibandCompressor.lookaheadMs = ms
                let host = try UnifiedGraphHost(spec: try configuration(d, engine: e, rate: rate).makeSpec())
                latencies.append(Int(host.latencyFrames))
                host.release()
            }
            XCTAssertEqual(latencies[1] - latencies[0], CompressorConfiguration.lookaheadFrames(ms: 5, sampleRate: rate), "lookahead only at \(rate)")
            XCTAssertEqual(latencies[0], Int(CompressorConfiguration.lookaheadFrames(ms: 0, sampleRate: rate)), "split adds none at \(rate)")
        }
    }

    /// Three bands soloed one at a time through the production translator: the soloed tone passes, the others fall away.
    func testMultibandSoloLabCaseAtEveryRate() throws {
        for rate in rates {
            let e = try engine(rate: rate)
            var d = DynamicsConfiguration()
            d.multibandCompressor.enabled = true
            d.multibandCompressor.lowThresholdDB = 0
            d.multibandCompressor.midThresholdDB = 0
            d.multibandCompressor.highThresholdDB = 0
            d.multibandCompressor.lowKneeDB = 0
            d.multibandCompressor.midKneeDB = 0
            d.multibandCompressor.highKneeDB = 0
            let n = Int(rate * 0.6)
            let tones: [(hz: Double, band: Int)] = [(50, 0), (800, 1), (9_000, 2)]
            var mix = [Float](repeating: 0, count: n)
            for t in tones { for (i, v) in tone(t.hz, amplitude: 0.1, rate: rate, frames: n).enumerated() { mix[i] += v } }
            for soloed in 0..<3 {
                let host = try UnifiedGraphHost(spec: try configuration(d, engine: e, rate: rate).makeSpec())
                defer { host.release() }
                try host.setSoloBands([soloed])
                let settle = try run(host, left: mix, right: mix)  // the 5 ms solo ramp settles well inside the first 0.1 s
                let tail = Array(settle[0][(n - Int(rate * 0.3))...])
                for t in tones {
                    let level = goertzel(tail, hz: t.hz, rate: rate)
                    if t.band == soloed {
                        XCTAssertEqual(level, 0.1, accuracy: 0.015, "soloed band \(soloed) tone passes at \(rate)")
                    } else if soloed == 1 {
                        // G42: the mid band is a true band-pass (allpass-compensated tree), so the 0.1 tone at 50 Hz and
                        // 9 kHz no longer leaks into it (the old dry-minus-low-minus-high residual left about 0.1).
                        print("NUMBERS mid solo leak tone \(t.hz) level \(level) rate \(rate)")
                        XCTAssertLessThan(level, 0.005, "mid soloed: the \(t.hz) Hz tone falls away at \(rate): \(level)")
                    } else {
                        print("NUMBERS solo \(soloed) tone \(t.hz) level \(level) rate \(rate)")
                        XCTAssertLessThan(level, 0.005, "band \(soloed) soloed: the \(t.hz) Hz tone falls away at \(rate): \(level)")
                    }
                }
            }
        }
    }

    // MARK: The detector law (G23, G26)

    /// An independent model of the compressor's law: a peak detector (the rectified input), the static curve as the target in
    /// dB, and a one-pole attack or release towards it. Returns the largest reduction in the final half second, as the
    /// read-and-reset maximum reads it.
    private func modelReductionDB(rate: Double, input: [Float], thr: Float, ratio: Float, knee: Float, attackMs: Double, releaseMs: Double) -> Double {
        let atk = Float(exp(-1.0 / (rate * attackMs / 1000))), rel = Float(exp(-1.0 / (rate * releaseMs / 1000)))
        let slope = 1 / ratio - 1
        var gain: Float = 0
        var maxReduction: Float = 0
        let window = input.count - Int(rate * 0.5)
        for (i, x) in input.enumerated() {
            let detDB = 20 * log10(max(abs(x), 1e-12))
            let over = detDB - thr
            var target: Float = 0
            if knee <= 0 {
                if over > 0 { target = slope * over }
            } else if over >= knee * 0.5 {
                target = slope * over
            } else if over > -knee * 0.5 {
                let k = over + knee * 0.5
                target = slope * k * k / (2 * knee)
            }
            let c = target < gain ? atk : rel
            gain = target + c * (gain - target)
            if i >= window { maxReduction = max(maxReduction, -gain) }
        }
        return Double(maxReduction)
    }

    /// 0 to -60 dBFS in 6 dB steps at knee 0, 6 and 24 dB, all eight rates. The core follows the model of its own law within
    /// 0.1 dB. The settled sine sits at most 0.3 dB under the static curve: the gain follows the rectified sine, attacking on
    /// each rise and releasing on each fall, so it ripples and the read-and-reset maximum lands a little under the curve's
    /// figure for the peak (G26: the 0.245 dB gap at -20 dBFS, threshold -30 dB, ratio 4).
    func testCompressorSweepAgreesWithTheLawAtKneesAndRates() throws {
        var widestGap = 0.0
        for rate in rates {
            let e = try engine(rate: rate)
            for knee in [0.0, 6.0, 24.0] {
                var d = DynamicsConfiguration()
                d.compressor.enabled = true
                d.compressor.thresholdDB = -30
                d.compressor.ratio = 4
                d.compressor.kneeWidthDB = knee
                d.compressor.attackMs = 1
                d.compressor.releaseMs = 100
                let configuration = try configuration(d, engine: e, rate: rate, extras: false)
                let curve = DynamicsTransferCurve(d.compressor)
                let frames = Int(rate * 1.0)
                for level in stride(from: -60.0, through: 0.0, by: 6.0) {
                    let amplitude = pow(10, level / 20)
                    let input = tone(1_000, amplitude: amplitude, rate: rate, frames: frames)
                    let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
                    var position = 0
                    var diagnostics = N60RenderKernelDiagnostics()
                    while position < frames {
                        let count = min(512, frames - position)
                        let block = Array(input[position..<position + count])
                        _ = try host.processOffline(input: [block, block], frames: count)
                        position += count
                        if position < frames - Int(rate * 0.5) { host.overlayStereoReadbacks(&diagnostics, latencyFrames: 0, includeOutput: true) }
                    }
                    host.overlayStereoReadbacks(&diagnostics, latencyFrames: 0, includeOutput: true)
                    host.release()
                    let measured = Double(diagnostics.compressorGainReductionDB)
                    let model = modelReductionDB(rate: rate, input: input, thr: -30, ratio: 4, knee: Float(knee), attackMs: 1, releaseMs: 100)
                    XCTAssertEqual(measured, model, accuracy: 0.1, "core vs model at \(level) dBFS, knee \(knee), \(rate)")
                    let gap = curve.reductionDB(atInput: level) - measured
                    widestGap = max(widestGap, abs(gap))
                    XCTAssertLessThan(abs(gap), 0.35, "core vs curve at \(level) dBFS, knee \(knee), \(rate): \(gap)")
                }
            }
        }
        print("NUMBERS widest gap to the curve \(widestGap)")
    }

    // MARK: Fade law (G34)

    func testALookaheadOnlyEditIsTheOnlyOneThatUsesTheLinearFade() {
        var a = DynamicsConfiguration()
        a.compressor.enabled = true
        var b = a
        XCTAssertFalse(a.differsOnlyInLookahead(from: b), "identical is not a lookahead edit")
        b.compressor.lookaheadMs = 5
        XCTAssertTrue(a.differsOnlyInLookahead(from: b))
        XCTAssertTrue(b.differsOnlyInLookahead(from: a))
        var c = b
        c.multibandCompressor.lookaheadMs = 10
        XCTAssertTrue(b.differsOnlyInLookahead(from: c))
        c.compressor.thresholdDB = -20
        XCTAssertFalse(b.differsOnlyInLookahead(from: c), "a threshold change alongside is an ordinary edit")
        var d = b
        d.compressor.mixPercent = 50
        XCTAssertFalse(b.differsOnlyInLookahead(from: d))
    }

    // MARK: Listen post failure (G37)

    func testAFailedRepostIsReportedOnceAndAFailedClearIsRetried() throws {
        let rate = 48_000.0
        var d = DynamicsConfiguration()
        d.compressor.enabled = true
        let e = try engine(rate: rate)
        var config = try configuration(d, engine: e, rate: rate)
        let host = try UnifiedGraphHost(spec: try config.makeSpec())
        defer { host.release() }
        XCTAssertFalse(host.takeListenRepostFailure())
        try host.setListener(DynamicsListener(stage: .compressor, mode: .sidechain))

        host.listenPostFaultForTesting = true
        d.expander.enabled = true  // a new stage is a topology change: the host rebuilds and re-posts the listener
        config = try configuration(d, engine: e, rate: rate)
        _ = try host.apply(try config.makeSpec())
        XCTAssertTrue(host.takeListenRepostFailure(), "the failed repost is remembered")
        XCTAssertFalse(host.takeListenRepostFailure(), "and reported once")

        XCTAssertFalse(host.clearListener(), "a clear that cannot post says so")
        host.listenPostFaultForTesting = false
        XCTAssertTrue(host.clearListener(), "and is retried until it lands")
        XCTAssertNil(host.listenSession.listener)
    }

    func testEngineReportsALostListenerOnlyWhenOneWasLost() {
        let engine = AudioIOEngine()
        engine.surfaceDynamicsListenRepostFailure()
        XCTAssertNil(engine.lastErrorDescription)
    }

    // MARK: Readout words (G21)

    func testLoudnessReadoutWords() {
        XCTAssertEqual(LoudnessReadouts.match(shortTermLUFS: -23, gainDB: 0.05, maxCorrectionDB: 12).status, "At target")
        XCTAssertEqual(LoudnessReadouts.match(shortTermLUFS: -30, gainDB: 4, maxCorrectionDB: 12).status, "Boosting 4.0 dB")
        XCTAssertEqual(LoudnessReadouts.match(shortTermLUFS: -10, gainDB: -6.5, maxCorrectionDB: 12).status, "Cutting 6.5 dB")
        let limit = LoudnessReadouts.match(shortTermLUFS: -50, gainDB: 12, maxCorrectionDB: 12)
        XCTAssertTrue(limit.atLimit)
        XCTAssertTrue(limit.status.contains("maximum correction"))
        XCTAssertEqual(LoudnessReadouts.match(shortTermLUFS: .nan, gainDB: 3, maxCorrectionDB: 12).status, "Measuring")
        XCTAssertEqual(LoudnessReadouts.contour(scale: 0).scale, 0)
        XCTAssertTrue(LoudnessReadouts.contour(scale: 0).status.contains("idle"))
        XCTAssertEqual(LoudnessReadouts.contour(scale: 0.63).status, "Contour at 63% of its full curve")
        XCTAssertEqual(LoudnessReadouts.contour(scale: 7).scale, 1)
        XCTAssertEqual(LoudnessReadouts.contour(scale: .nan).scale, 0)
    }
}
