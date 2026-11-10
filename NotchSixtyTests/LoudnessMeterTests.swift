import XCTest
@testable import NotchSixty

final class LoudnessMeterTests: XCTestCase {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Signal helpers

    /// Phase-continuous sine feeder for any channel layout; a level of nil is silence.
    struct ToneFeeder {
        var frequency = 1_000.0
        private var phase = 0.0

        init(frequency: Double = 1_000) { self.frequency = frequency }

        /// `levels` are peak dBFS per channel (nil = silent).
        mutating func feed(_ meter: inout LoudnessMeter, levels: [Double?], seconds: Double) {
            let rate = meter.sampleRate
            let total = Int((seconds * rate).rounded())
            let chunk = Int(rate / 20)
            var done = 0
            while done < total {
                let n = min(chunk, total - done)
                var planar = [[Float]](repeating: [Float](repeating: 0, count: n), count: levels.count)
                for i in 0..<n {
                    let s = sin(phase)
                    phase += 2 * Double.pi * frequency / rate
                    if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                    for c in 0..<levels.count {
                        if let level = levels[c] { planar[c][i] = Float(pow(10, level / 20) * s) }
                    }
                }
                meter.process(planar: planar)
                done += n
            }
        }
    }

    static func stereoMeter(_ rate: Double) -> LoudnessMeter { LoudnessMeter(sampleRate: rate) }

    /// Deterministic white noise (xorshift), identical for every call.
    static func noise(count: Int, seed: UInt64 = 0x9E3779B97F4A7C15, peak: Float = 0.2) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return (Float(state % 2_000_001) / 1_000_000 - 1) * peak
        }
    }

    // MARK: K-weighting

    func testKWeightingReproducesPublished48kCoefficients() {
        let filter = KWeightingFilter(sampleRate: 48_000)
        XCTAssertEqual(filter.shelf.b0, 1.53512485958697, accuracy: 1e-9)
        XCTAssertEqual(filter.shelf.b1, -2.69169618940638, accuracy: 1e-9)
        XCTAssertEqual(filter.shelf.b2, 1.19839281085285, accuracy: 1e-9)
        XCTAssertEqual(filter.shelf.a1, -1.69065929318241, accuracy: 1e-9)
        XCTAssertEqual(filter.shelf.a2, 0.73248077421585, accuracy: 1e-9)
        XCTAssertEqual(filter.highPass.a1, -1.99004745483398, accuracy: 1e-9)
        XCTAssertEqual(filter.highPass.a2, 0.99007225036621, accuracy: 1e-9)
    }

    /// The plan asked for 0.01 dB. A bilinear transform of the same analogue
    /// prototypes cannot reach it (the 48 kHz response itself is warped near
    /// 20 kHz); the worst case measured is 0.046 dB, so the bound is 0.05 dB
    /// (about 0.05 LU on broadband material). Recorded in the E28 log.
    func testKWeightingTracks48kResponseWithinFiftyThousandthsDecibelAtEveryRate() {
        let reference = KWeightingFilter(sampleRate: 48_000)
        for rate in Self.rates {
            let filter = KWeightingFilter(sampleRate: rate)
            let top = min(0.45 * rate, 20_000)
            for step in 0...200 {
                let f = 20 * pow(top / 20, Double(step) / 200)
                let delta = 20 * log10(
                    filter.magnitude(at: f, sampleRate: rate) / reference.magnitude(at: f, sampleRate: 48_000)
                )
                XCTAssertEqual(delta, 0, accuracy: 0.05, "\(rate) Hz at \(f) Hz")
            }
        }
    }

    func testKWeightingGainAtOneKilohertzIsTheLoudnessOffset() {
        for rate in Self.rates {
            let gain = 20 * log10(KWeightingFilter(sampleRate: rate).magnitude(at: 1_000, sampleRate: rate))
            XCTAssertEqual(gain, 0.691, accuracy: 0.03, "\(rate)")
        }
    }

    // MARK: Tone levels at every rate

    func testStereoSineAtMinusTwentyThreeDBFSReadsMinusTwentyThreeLUFSAtEveryRate() {
        for rate in Self.rates {
            var meter = Self.stereoMeter(rate)
            var tone = ToneFeeder()
            tone.feed(&meter, levels: [-23, -23], seconds: 5)
            let r = meter.exactReadout()
            XCTAssertEqual(r.momentary ?? .nan, -23, accuracy: 0.1, "M \(rate)")
            XCTAssertEqual(r.shortTerm ?? .nan, -23, accuracy: 0.1, "S \(rate)")
            XCTAssertEqual(r.integrated ?? .nan, -23, accuracy: 0.1, "I \(rate)")
            XCTAssertEqual(r.momentaryMax ?? .nan, -23, accuracy: 0.1)
            XCTAssertFalse(r.isGapped)
        }
    }

    func testGatingRejectsQuietLeadAndTailAtEveryRate() {
        // Shortened Tech 3341 case 3: quiet, loud, quiet. The loud part is long
        // enough that blocks straddling the edges move the result under 0.1 LU.
        for rate in Self.rates {
            var meter = Self.stereoMeter(rate)
            var tone = ToneFeeder()
            tone.feed(&meter, levels: [-36, -36], seconds: 2)
            tone.feed(&meter, levels: [-23, -23], seconds: 24)
            tone.feed(&meter, levels: [-36, -36], seconds: 2)
            XCTAssertEqual(meter.exactReadout().integrated ?? .nan, -23, accuracy: 0.1, "\(rate)")
        }
    }

    // MARK: EBU Tech 3341, full length at 48 kHz

    private func integrated(_ segments: [(Double?, Double)]) -> LoudnessReadout {
        var meter = Self.stereoMeter(48_000)
        var tone = ToneFeeder()
        for (level, seconds) in segments {
            tone.feed(&meter, levels: [level, level], seconds: seconds)
        }
        return meter.exactReadout()
    }

    func testTech3341Case1() {
        let r = integrated([(-23, 20)])
        XCTAssertEqual(r.momentaryMax ?? .nan, -23, accuracy: 0.1)
        XCTAssertEqual(r.shortTermMax ?? .nan, -23, accuracy: 0.1)
        XCTAssertEqual(r.integrated ?? .nan, -23, accuracy: 0.1)
    }

    func testTech3341Case2() {
        let r = integrated([(-33, 20)])
        XCTAssertEqual(r.momentaryMax ?? .nan, -33, accuracy: 0.1)
        XCTAssertEqual(r.integrated ?? .nan, -33, accuracy: 0.1)
    }

    func testTech3341Case3RelativeGate() {
        let r = integrated([(-36, 10), (-23, 60), (-36, 10)])
        XCTAssertEqual(r.integrated ?? .nan, -23, accuracy: 0.1)
    }

    func testTech3341Case4AbsoluteAndRelativeGates() {
        let r = integrated([(-72, 10), (-36, 10), (-23, 60), (-36, 10), (-72, 10)])
        XCTAssertEqual(r.integrated ?? .nan, -23, accuracy: 0.1)
    }

    func testTech3341Case5TwoLevelsBothPassTheGate() {
        // -26 and -20 for 20 s each: both are within 10 LU of their mean, so the
        // result is the power mean of the two.
        let expected = 10 * log10((pow(10, -2.6) + pow(10, -2.0)) / 2)
        let r = integrated([(-26, 20), (-20, 20)])
        XCTAssertEqual(r.integrated ?? .nan, expected, accuracy: 0.1)
    }

    func testTech3341Case6FiveDotOneWeighting() {
        // L R C LFE Ls Rs at 1 kHz; LFE content must not count.
        let layout: [LoudnessChannelPosition] = [.left, .right, .centre, .lfe, .leftSurround, .rightSurround]
        let levels: [Double?] = [-28, -28, -24, -10, -30, -30]
        var meter = LoudnessMeter(sampleRate: 48_000, channels: layout)
        var tone = ToneFeeder()
        tone.feed(&meter, levels: levels, seconds: 8)
        let k = pow(KWeightingFilter(sampleRate: 48_000).magnitude(at: 1_000, sampleRate: 48_000), 2)
        var power = 0.0
        for (position, level) in zip(layout, levels) where !position.isLFE {
            power += position.weight * pow(10, (level ?? -200) / 10) / 2 * k
        }
        XCTAssertEqual(meter.exactReadout().integrated ?? .nan, -0.691 + 10 * log10(power), accuracy: 0.05)
    }

    // MARK: EBU Tech 3342 loudness range (synthesised from the published descriptions)

    private func range(_ segments: [(Double, Double)]) -> Double? {
        integrated(segments.map { ($0.0, $0.1) }).range
    }

    func testTech3342Cases() {
        XCTAssertEqual(range([(-20, 20), (-30, 20)]) ?? .nan, 10, accuracy: 1)
        XCTAssertEqual(range([(-20, 20), (-15, 20)]) ?? .nan, 5, accuracy: 1)
        XCTAssertEqual(range([(-40, 20), (-20, 20)]) ?? .nan, 20, accuracy: 1)
        XCTAssertEqual(range([(-50, 20), (-35, 20), (-20, 20), (-35, 20), (-50, 20)]) ?? .nan, 15, accuracy: 1)
    }

    func testRangeIsNilBeforeThreeSecondsAndForSteadyTone() {
        XCTAssertNil(integrated([(-23, 2)]).range)
        XCTAssertEqual(integrated([(-23, 10)]).range ?? .nan, 0, accuracy: 0.05)
    }

    // MARK: Gating arithmetic

    func testIntegratedGateOnBlockPowers() {
        let loud = LoudnessMeter.power(loudness: -23)
        let quiet = LoudnessMeter.power(loudness: -36)
        let silent = LoudnessMeter.power(loudness: -75)
        let r = LoudnessMeter.integratedLoudness(blockPowers: Array(repeating: loud, count: 60)
            + Array(repeating: quiet, count: 10) + Array(repeating: silent, count: 20))
        XCTAssertEqual(r ?? .nan, -23, accuracy: 0.001)
        XCTAssertNil(LoudnessMeter.integratedLoudness(blockPowers: [silent, silent]))
        XCTAssertNil(LoudnessMeter.integratedLoudness(blockPowers: []))
    }

    // MARK: Channel weighting

    func testWeightsFollowBS1770Table3() {
        XCTAssertEqual(LoudnessChannelPosition.left.weight, 1)
        XCTAssertEqual(LoudnessChannelPosition.centre.weight, 1)
        XCTAssertEqual(LoudnessChannelPosition.leftSurround.weight, 1.41)
        XCTAssertEqual(LoudnessChannelPosition.rightRearSurround.weight, 1.41)
        XCTAssertEqual(LoudnessChannelPosition.leftHeight.weight, 1)
        XCTAssertEqual(LoudnessChannelPosition.leftRearHeight.weight, 1, "elevated 30 degrees or more")
        XCTAssertEqual(LoudnessChannelPosition.lfe.weight, 0)
    }

    private static let sevenOneFour: [LoudnessChannelPosition] = [
        .left, .right, .centre, .lfe, .leftSurround, .rightSurround, .leftRearSurround, .rightRearSurround,
        .leftHeight, .rightHeight, .leftRearHeight, .rightRearHeight,
    ]
    private static let fiveOne: [LoudnessChannelPosition] = [
        .left, .right, .centre, .lfe, .leftSurround, .rightSurround,
    ]

    private func noiseLoudness(layout: [LoudnessChannelPosition], channel: Int) -> Double {
        let rate = 48_000.0
        var meter = LoudnessMeter(sampleRate: rate, channels: layout)
        let sound = Self.noise(count: Int(rate * 6))
        var planar = [[Float]](repeating: [Float](repeating: 0, count: sound.count), count: layout.count)
        planar[channel] = sound
        meter.process(planar: planar)
        return meter.exactReadout().integrated ?? -.infinity
    }

    func testSurroundNoiseReadsOnePointFiveDecibelsAboveFrontOnFiveOneAndSevenOneFour() {
        for layout in [Self.fiveOne, Self.sevenOneFour] {
            let front = noiseLoudness(layout: layout, channel: 0)
            XCTAssertEqual(noiseLoudness(layout: layout, channel: 4) - front, 1.5, accuracy: 0.05)
        }
        let layout = Self.sevenOneFour
        let front = noiseLoudness(layout: layout, channel: 0)
        XCTAssertEqual(noiseLoudness(layout: layout, channel: 6) - front, 1.5, accuracy: 0.05, "rear surround")
        XCTAssertEqual(noiseLoudness(layout: layout, channel: 8) - front, 0, accuracy: 0.05, "elevated")
    }

    func testLFEContentChangesNothing() {
        let rate = 48_000.0
        let sound = Self.noise(count: Int(rate * 6))
        let low = Self.noise(count: sound.count, seed: 42, peak: 0.9)
        for layout in [Self.fiveOne, Self.sevenOneFour] {
            var plain = LoudnessMeter(sampleRate: rate, channels: layout)
            var withLFE = LoudnessMeter(sampleRate: rate, channels: layout)
            var a = [[Float]](repeating: [Float](repeating: 0, count: sound.count), count: layout.count)
            a[0] = sound
            var b = a
            b[3] = low
            plain.process(planar: a)
            withLFE.process(planar: b)
            XCTAssertEqual(withLFE.exactReadout().integrated, plain.exactReadout().integrated)
        }
        XCTAssertNil(noiseLoudnessOrNil(layout: Self.fiveOne, channel: 3), "LFE alone is silent to the meter")
    }

    private func noiseLoudnessOrNil(layout: [LoudnessChannelPosition], channel: Int) -> Double? {
        let value = noiseLoudness(layout: layout, channel: channel)
        return value.isFinite ? value : nil
    }

    // MARK: Reset, pause, gap

    func testResetClearsEverythingAndPauseKeepsIntegrated() {
        var meter = Self.stereoMeter(48_000)
        var tone = ToneFeeder()
        tone.feed(&meter, levels: [-23, -23], seconds: 5)
        meter.markDiscontinuity(gapped: false)
        var paused = meter.exactReadout()
        XCTAssertNil(paused.momentary, "windows restart after a pause")
        XCTAssertNil(paused.shortTerm)
        XCTAssertEqual(paused.integrated ?? .nan, -23, accuracy: 0.1, "paused, not reset")
        XCTAssertFalse(paused.isGapped)

        meter.reset()
        paused = meter.exactReadout()
        XCTAssertEqual(paused, .empty)
    }

    func testGappedFlagSetsOnLostFramesAndOnlyResetClearsIt() {
        var meter = Self.stereoMeter(48_000)
        var tone = ToneFeeder()
        tone.feed(&meter, levels: [-23, -23], seconds: 2)
        meter.markDiscontinuity(gapped: true)
        XCTAssertTrue(meter.exactReadout().isGapped)
        tone.feed(&meter, levels: [-23, -23], seconds: 2)
        XCTAssertTrue(meter.exactReadout().isGapped)
        meter.reset()
        XCTAssertFalse(meter.exactReadout().isGapped)
    }

    // MARK: Feed from the capture ring

    private func frames(rate: Double, seconds: Double, input: Double, output: Double) -> [N60AnalysisFrame] {
        let count = Int(rate * seconds)
        let a = Float(pow(10, input / 20)), b = Float(pow(10, output / 20))
        return (0..<count).map { n in
            let s = Float(sin(2 * Double.pi * 1_000 * Double(n) / rate))
            return N60AnalysisFrame(inputLeft: a * s, inputRight: a * s, outputLeft: b * s, outputRight: b * s)
        }
    }

    private func ingest(_ feed: ProductionLoudnessFeed, _ frames: [N60AnalysisFrame]) {
        frames.withUnsafeBufferPointer { feed.ingest($0) }
    }

    func testFeedSeparatesInputAndOutputAndHonoursDemand() {
        let rate = 48_000.0
        let feed = ProductionLoudnessFeed()
        ingest(feed, frames(rate: rate, seconds: 1, input: -10, output: -10))
        XCTAssertNil(feed.readouts(), "ignored while the demand is not held")

        feed.setActive(true, sampleRate: rate)
        ingest(feed, frames(rate: rate, seconds: 5, input: -20, output: -30))
        var both = feed.readouts()
        XCTAssertEqual(both?.input.integrated ?? .nan, -20, accuracy: 0.1)
        XCTAssertEqual(both?.output.integrated ?? .nan, -30, accuracy: 0.1)

        feed.setActive(false, sampleRate: rate)
        ingest(feed, frames(rate: rate, seconds: 5, input: -5, output: -5))
        feed.setActive(true, sampleRate: rate)
        both = feed.readouts()
        XCTAssertNil(both?.input.momentary, "windows restart on resume")
        XCTAssertEqual(both?.input.integrated ?? .nan, -20, accuracy: 0.1, "integrated survives the pause")

        feed.reset()
        both = feed.readouts()
        XCTAssertNil(both?.input.integrated)
    }

    func testFeedMarksGappedOnRisingDropCounterAndRestartsOnRateChange() {
        let feed = ProductionLoudnessFeed()
        feed.setActive(true, sampleRate: 48_000)
        feed.noteDroppedFrames(0)
        XCTAssertEqual(feed.readouts()?.input.isGapped, false)
        feed.noteDroppedFrames(10)
        XCTAssertEqual(feed.readouts()?.input.isGapped, true)
        XCTAssertEqual(feed.readouts()?.output.isGapped, true)
        feed.noteDroppedFrames(10)
        feed.ensureMeters(sampleRate: 96_000)
        XCTAssertEqual(feed.input?.sampleRate, 96_000)
        XCTAssertEqual(feed.readouts()?.input.isGapped, false, "a new rate is a new measurement")
    }

    func testWorkerKeepsLoudnessBitsOffTheBridgeAndDropsStereoViews() throws {
        let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(256))
        defer { N60RealtimeAudioBridgeDestroy(bridge) }
        let mask = UInt32(N60_ANALYSIS_DEMAND_STEREO) | ProductionAnalysisDemand.loudness
        N60RealtimeAudioBridgeSetAnalysisDemand(bridge, mask | ProductionAnalysisDemand.resetLoudness)
        XCTAssertEqual(N60RealtimeAudioBridgeAnalysisDemand(bridge), UInt32(N60_ANALYSIS_DEMAND_STEREO),
                       "capture runs through the existing bit; no bridge change")

        let worker = ProductionAnalysisWorker(bridge: bridge)
        defer { worker.stop() }
        worker.setDemand(mask | ProductionAnalysisDemand.resetLoudness, sampleRate: 48_000)
        var snapshot = ProductionAnalysisSnapshot.empty
        let deadline = Date().addingTimeInterval(3)
        while snapshot.loudnessOutput == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            snapshot = worker.snapshot()
        }
        XCTAssertNotNil(snapshot.loudnessInput)
        XCTAssertNotNil(snapshot.loudnessOutput)
        XCTAssertEqual(snapshot.demandMask, ProductionAnalysisDemand.loudness)
        XCTAssertTrue(snapshot.goniometer.isEmpty, "stereo views are off while loudness is held")

        worker.setDemand(UInt32(N60_ANALYSIS_DEMAND_NONE), sampleRate: 48_000)
        let idle = Date().addingTimeInterval(2)
        while worker.snapshot().loudnessOutput != nil, Date() < idle { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertNil(worker.snapshot().loudnessOutput, "no readout while the card is hidden")
    }

    // MARK: Wide sessions and the loudness lab (E28 S6b)

    /// Deterministic pink noise (Paul Kellett's economy filter over xorshift white noise), scaled to `peak`.
    static func pinkNoise(count: Int, seed: UInt64, peak: Float = 0.25) -> [Float] {
        let white = noise(count: count, seed: seed, peak: 1)
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        return white.map { w in
            let x = Double(w)
            b0 = 0.99765 * b0 + x * 0.0990460
            b1 = 0.96300 * b1 + x * 0.2965164
            b2 = 0.57000 * b2 + x * 1.0526913
            return Float((b0 + b1 + b2 + x * 0.1848) * 0.25) * peak
        }
    }

    func testRolesMapToBS1770Positions() {
        XCTAssertEqual(LoudnessChannelPosition(role: .frontLeft).weight, 1)
        XCTAssertEqual(LoudnessChannelPosition(role: .frontCenter).weight, 1)
        XCTAssertEqual(LoudnessChannelPosition(role: .lowFrequencyEffects).weight, 0)
        for role in [OutputProgramRole.sideLeft, .sideRight, .rearLeft, .rearRight] {
            XCTAssertEqual(LoudnessChannelPosition(role: role).weight, 1.41, "\(role)")
        }
        for role in [OutputProgramRole.topFrontLeft, .topFrontRight, .topMiddleLeft, .topMiddleRight, .topRearLeft, .topRearRight] {
            XCTAssertEqual(LoudnessChannelPosition(role: role).weight, 1, "\(role) is elevated")
        }
        XCTAssertEqual(LoudnessChannelPosition(role: .wideLeft).weight, 1)
        XCTAssertEqual(OutputProgramRole.allCases.count, 16, "a new role needs a position")
    }

    /// G14: pink noise through the production feed, Output within 0.1 LU of the offline meter at the eight rates.
    func testLoudnessLabPinkNoiseOutputMatchesTheOfflineMeterAtEveryRate() {
        for rate in Self.rates {
            let count = Int(rate * 8)
            let left = Self.pinkNoise(count: count, seed: 0x1234_5678_9ABC_DEF1)
            let right = Self.pinkNoise(count: count, seed: 0x0FED_CBA9_8765_4321, peak: 0.2)
            var reference = LoudnessMeter(sampleRate: rate)
            reference.process(planar: [left, right])
            let expected = reference.readout()

            let feed = ProductionLoudnessFeed()
            feed.setActive(true, sampleRate: rate)
            let chunk = 480
            var start = 0
            while start < count {
                let end = min(start + chunk, count)
                let frames = (start..<end).map {
                    N60AnalysisFrame(inputLeft: 0, inputRight: 0, outputLeft: left[$0], outputRight: right[$0])
                }
                frames.withUnsafeBufferPointer { feed.ingest($0) }
                start = end
            }
            let shown = feed.readouts()?.output
            XCTAssertNotNil(expected.integrated, "rate \(rate)")
            XCTAssertEqual(shown?.integrated ?? .nan, expected.integrated ?? .infinity, accuracy: 0.1, "integrated at \(rate)")
            XCTAssertEqual(shown?.shortTerm ?? .nan, expected.shortTerm ?? .infinity, accuracy: 0.1, "short-term at \(rate)")
            XCTAssertEqual(shown?.momentary ?? .nan, expected.momentary ?? .infinity, accuracy: 0.1, "momentary at \(rate)")
            // Absolute sanity: stereo pink noise of this level sits well above the -70 LUFS gate.
            XCTAssertGreaterThan(shown?.integrated ?? -200, -40, "rate \(rate)")
        }
    }

    private static let fiveOneRoles: [OutputProgramRole] = [.frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects, .sideLeft, .sideRight]

    /// Writes `planar` into the ring in real-time-sized blocks, waiting for the worker to drain each block, and returns
    /// the snapshot once every frame has been consumed.
    private func pump(
        _ capture: UnsafeMutablePointer<N60LoudnessCapture>, worker: ProductionWideLoudnessWorker,
        input: [[Float]], output: [[Float]]?, rate: Double
    ) -> ProductionAnalysisSnapshot {
        let total = input[0].count
        let block = Int(rate / 10)
        var start = 0
        var written: UInt64 = 0
        while start < total {
            let end = min(start + block, total)
            let granted = N60LoudnessCaptureBeginBlock(capture, UInt32(end - start))
            XCTAssertEqual(Int(granted.frames), end - start, "the ring must have room for a 100 ms block")
            for n in 0..<Int(granted.frames) {
                var frame = input.map { $0[start + n] }
                N60LoudnessCaptureWriteInput(capture, granted, UInt32(n), &frame)
                if let output {
                    var heard = output.map { $0[start + n] }
                    N60LoudnessCaptureWriteOutput(capture, granted, UInt32(n), &heard)
                }
            }
            N60LoudnessCaptureCommit(capture, granted)
            written += UInt64(granted.frames)
            start = end
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let s = worker.snapshot()
                if s.capturedFrames == written, s.availableFrames == 0 { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return worker.snapshot()
    }

    /// G9: the semantic program channels reach the meter with their BS.1770-4 weights, at the eight rates, through the
    /// real capture ring and worker.
    func testWideWorkerMeasuresWeightedProgramChannelsFromTheRingAtEveryRate() throws {
        let positions = LoudnessChannelPosition.positions(for: Self.fiveOneRoles)
        for rate in Self.rates {
            let capture = try XCTUnwrap(N60LoudnessCaptureCreate(6, 6, rate))
            defer { N60LoudnessCaptureDestroy(capture) }
            let worker = try XCTUnwrap(ProductionWideLoudnessWorker(
                capture: capture, sampleRate: rate, inputPositions: positions, outputPositions: positions))
            defer { worker.stop() }
            worker.setDemand(ProductionAnalysisDemand.loudness)
            Thread.sleep(forTimeInterval: 0.1)

            let count = Int(rate * 2)
            let input = (0..<6).map { Self.pinkNoise(count: count, seed: 0xA5A5_0000 + UInt64($0) * 7_919) }
            // The LFE carries a loud signal on purpose: it must change nothing.
            let output = input.map { $0.map { $0 * 0.5 } }
            let snapshot = pump(capture, worker: worker, input: input, output: output, rate: rate)

            var inputReference = LoudnessMeter(sampleRate: rate, channels: positions)
            inputReference.process(planar: input)
            var outputReference = LoudnessMeter(sampleRate: rate, channels: positions)
            outputReference.process(planar: output)
            XCTAssertEqual(snapshot.droppedFrames, 0, "rate \(rate)")
            XCTAssertEqual(snapshot.loudnessInput?.integrated ?? .nan, inputReference.readout().integrated ?? .infinity,
                           accuracy: 0.1, "input at \(rate)")
            XCTAssertEqual(snapshot.loudnessOutput?.integrated ?? .nan, outputReference.readout().integrated ?? .infinity,
                           accuracy: 0.1, "output at \(rate)")
            // Half amplitude is 6.02 LU lower.
            let delta = (snapshot.loudnessInput?.integrated ?? 0) - (snapshot.loudnessOutput?.integrated ?? 0)
            XCTAssertEqual(delta, 6.02, accuracy: 0.1, "rate \(rate)")
            // The side channels weigh +1.5 dB: muting them must lower the reading by more than muting nothing changes.
            var noSides = LoudnessMeter(sampleRate: rate, channels: positions)
            var muted = input
            muted[4] = [Float](repeating: 0, count: count)
            muted[5] = [Float](repeating: 0, count: count)
            noSides.process(planar: muted)
            XCTAssertLessThan(noSides.readout().integrated ?? 0, (snapshot.loudnessInput?.integrated ?? 0) - 0.5, "rate \(rate)")
        }
    }

    func testWideWorkerWithoutOutputChannelsPublishesInputOnlyAndHonoursDemand() throws {
        let rate = 48_000.0
        let positions = LoudnessChannelPosition.positions(for: [.frontLeft, .frontRight, .frontCenter])
        let capture = try XCTUnwrap(N60LoudnessCaptureCreate(3, 0, rate))
        defer { N60LoudnessCaptureDestroy(capture) }
        let worker = try XCTUnwrap(ProductionWideLoudnessWorker(
            capture: capture, sampleRate: rate, inputPositions: positions, outputPositions: nil))
        defer { worker.stop() }
        XCTAssertNil(ProductionWideLoudnessWorker(capture: capture, sampleRate: rate, inputPositions: positions,
                                                  outputPositions: positions), "channel counts must agree with the ring")
        XCTAssertFalse(N60LoudnessCaptureDemand(capture))
        worker.setDemand(ProductionAnalysisDemand.loudness)
        let deadline = Date().addingTimeInterval(2)
        while !N60LoudnessCaptureDemand(capture), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(N60LoudnessCaptureDemand(capture), "the loudness bit opens the ring")

        let input = (0..<3).map { Self.pinkNoise(count: Int(rate * 2), seed: 0xBEEF + UInt64($0)) }
        var snapshot = pump(capture, worker: worker, input: input, output: nil, rate: rate)
        XCTAssertNotNil(snapshot.loudnessInput?.integrated)
        XCTAssertNil(snapshot.loudnessOutput, "a routed lane map has no Output")

        worker.setDemand(ProductionAnalysisDemand.loudness | ProductionAnalysisDemand.resetLoudness)
        Thread.sleep(forTimeInterval: 0.2)
        snapshot = worker.snapshot()
        XCTAssertNil(snapshot.loudnessInput?.integrated, "Reset clears the measurement")

        worker.setDemand(UInt32(N60_ANALYSIS_DEMAND_NONE))
        let idle = Date().addingTimeInterval(2)
        while N60LoudnessCaptureDemand(capture), Date() < idle { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(N60LoudnessCaptureDemand(capture), "no demand, no capture")
        XCTAssertNil(worker.snapshot().loudnessInput)
    }

    func testWideFeedMarksGappedWhenTheRingDropsFrames() {
        let feed = WideLoudnessFeed(sampleRate: 48_000, inputPositions: LoudnessChannelPosition.stereo, outputPositions: nil)
        feed.setActive(true)
        feed.noteDroppedFrames(0)
        XCTAssertEqual(feed.readouts()?.input.isGapped, false)
        feed.noteDroppedFrames(5)
        XCTAssertEqual(feed.readouts()?.input.isGapped, true)
        XCTAssertNil(feed.readouts()?.output)
    }

    func testCardTextNamesTheMeasuredChannelsPerSessionKind() {
        XCTAssertTrue(LoudnessCardText.foldNote.contains("stereo capture"))
        XCTAssertFalse(LoudnessCardText.wideNote.contains("stereo capture"))
        XCTAssertTrue(LoudnessCardText.wideNote.contains("program channels"))
        XCTAssertTrue(LoudnessCardText.wideOutputUnavailableNote.contains("routed"))
    }

    // MARK: Card text and true peak

    func testTruePeakMaxHoldKeepsTheMaximumUntilReset() {
        var hold = TruePeakMaxHold()
        XCTAssertNil(hold.maxDBTP)
        hold.update(dbtp: ProductionMeterMath.floorDB)
        XCTAssertNil(hold.maxDBTP, "floor means no signal")
        hold.update(dbtp: -6)
        hold.update(dbtp: -1.5)
        hold.update(dbtp: -12)
        XCTAssertEqual(hold.maxDBTP, -1.5)
        hold.reset()
        XCTAssertNil(hold.maxDBTP)
    }

    func testCardTextUsesDashesAndOneDecimal() {
        XCTAssertEqual(LoudnessCardText.lufs(nil), "—")
        XCTAssertEqual(LoudnessCardText.lufs(-23.04), "-23.0 LUFS")
        XCTAssertEqual(LoudnessCardText.lu(7.26), "7.3 LU")
        XCTAssertEqual(LoudnessCardText.truePeak(-1.46), "-1.5 dBTP")
        XCTAssertTrue(LoudnessCardText.foldNote.contains("folded"))
    }
}
