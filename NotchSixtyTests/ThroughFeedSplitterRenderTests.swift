import XCTest
@testable import NotchSixty

/// E26 S2c: sweeps rendered through the app splitter, the bass-path stamp on the secondary path, and echo removal of
/// at least 20 dB with the twin's sub active, run through the stamped record. Eight standard rates. Bench (E22):
/// sweeps through the owner's receiver.
final class ThroughFeedSplitterRenderTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func bass(_ hz: Double = 80) -> BassManagementConfiguration {
        var c = BassManagementConfiguration()
        c.enabled = true
        c.frequencyHz = hz
        c.physicalOutputMode = .mainsSub
        return c
    }

    /// Swift twin of `twin::BassSplit`: feed L -> LR4 mains + 0.5 * LR4 sub (delayed), summed to the listener.
    private struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
        init(low: Bool, hz: Double, fs: Double) {
            let w = 2 * Double.pi * hz / fs, cs = cos(w), al = sin(w) / (2 * 0.7071067811865476), a0 = 1 + al
            a1 = -2 * cs / a0; a2 = (1 - al) / a0
            b0 = (low ? 1 - cs : 1 + cs) / (2 * a0); b1 = (low ? 1 - cs : -(1 + cs)) / a0; b2 = b0
        }
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private func twinPath(rate fs: Double, subDelayFrames: Int, seconds: Double) -> [Float] {
        var lp = [Biquad(low: true, hz: 80, fs: fs), Biquad(low: true, hz: 80, fs: fs)]
        var hp = [Biquad(low: false, hz: 80, fs: fs), Biquad(low: false, hz: 80, fs: fs)]
        let n = Int(seconds * fs)
        var sub = [Double](repeating: 0, count: n)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let l = i == 0 ? 1.0 : 0.0
            sub[i] = lp[1].run(lp[0].run(0.5 * l))
            let delayed = i - subDelayFrames >= 0 ? sub[i - subDelayFrames] : 0
            out[i] = Float(hp[1].run(hp[0].run(l)) + delayed)
        }
        return out
    }

    /// The room adds a delay to the sub lane only; mains and sub sum at the microphone.
    private func roomSum(_ r: ThroughFeedSplitterRenderer.Rendered, subDelayFrames: Int) -> [Float] {
        let mains = r.bus(N60SpeakerOutputBusLeftHigh), sub = r.bus(N60SpeakerOutputBusSubMono)
        return (0..<r.frameCount).map { mains[$0] + ($0 >= subDelayFrames ? sub[$0 - subDelayFrames] : 0) }
    }

    func testSplitterRenderedSweepDeconvolvesWithSubBandEnergyAtEightRates() throws {
        for rate in rates {
            for subDelay in [0.0] {
                let frames = Int((subDelay * rate).rounded())
                let settings = RoomCorrectionSweepSettings(
                    sampleRate: rate, startFrequencyHz: 15, endFrequencyHz: 1_000, durationSeconds: 3,
                    leadInSeconds: 0.2, tailSeconds: 1.0)
                let program = try RoomCorrectionSweepGenerator().makeProgram(settings: settings)
                let padded = program.sweepSamples + [Float](repeating: 0, count: program.tailFrames)
                let rendered = try ThroughFeedSplitterRenderer.render(padded, feed: .left, bass: bass(), sampleRate: rate)
                var capture = [Float](repeating: 0, count: program.captureFrameCount)
                for (i, v) in roomSum(rendered, subDelayFrames: frames).enumerated() where program.leadInFrames + i < capture.count {
                    capture[program.leadInFrames + i] = v
                }
                let measured = try RoomCorrectionMeasurementAnalyzer().analyzeSingleChannel(rawCapture: capture, program: program)
                let got = CombinedPathBandAnalyzer.analyze(impulseResponse: measured.impulseResponse, sampleRate: rate)
                // The sweep analyzer re-times and normalises the response, so exact band delay and level are
                // checked on the impulse render (next tests). Here the sweep through the render must still
                // deconvolve to a finite response with energy in every sub band.
                var checked = 0
                for g in got where g.centerHz >= 31 && g.centerHz <= 125 {
                    XCTAssertTrue(g.gainDB.isFinite, "\(rate) Hz, band \(g.centerHz)")
                    XCTAssertGreaterThan(g.gainDB, -40, "\(rate) Hz, band \(g.centerHz)")
                    checked += 1
                }
                XCTAssertGreaterThanOrEqual(checked, 6)
            }
        }
    }

    /// The sub lane's room delay (0, 5, 20 ms) moves the low bands by that delay, as in the twin. Impulse path: the
    /// sweep analyzer re-times the response to its first arrival, so delays are checked on the impulse render.
    func testSplitterRenderedPathMatchesTwinBandDelaysForSubDelays() throws {
        for rate in rates {
            for subDelay in [0.0, 0.005, 0.020] {
                let frames = Int((subDelay * rate).rounded())
                var impulse = [Float](repeating: 0, count: Int(0.4 * rate)); impulse[0] = 1
                let rendered = try ThroughFeedSplitterRenderer.render(impulse, feed: .left, bass: bass(), sampleRate: rate)
                let got = CombinedPathBandAnalyzer.analyze(impulseResponse: roomSum(rendered, subDelayFrames: frames), sampleRate: rate)
                let truth = CombinedPathBandAnalyzer.analyze(
                    impulseResponse: twinPath(rate: rate, subDelayFrames: frames, seconds: 0.4), sampleRate: rate)
                for (g, t) in zip(got, truth) where g.centerHz <= 125 {
                    guard let gd = g.delaySeconds, let td = t.delaySeconds else { continue }
                    XCTAssertEqual(gd, td, accuracy: 1.0 / min(rate, 48_000), "\(rate) Hz, sub \(subDelay), band \(g.centerHz)")
                }
            }
        }
    }

    func testImpulseRenderMatchesTwinSampleForSample() throws {
        for rate in rates {
            let got = try ThroughFeedSplitterRenderer.combinedImpulseResponse(feed: .left, bass: bass(), sampleRate: rate, seconds: 0.2)
            let want = twinPath(rate: rate, subDelayFrames: 0, seconds: 0.2)
            let peak = want.map { abs($0) }.max() ?? 1
            let error = zip(got, want).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(Double(error / peak), 1e-3, "\(rate)")
        }
    }

    func testRightFeedReachesTheRightMainsAndTheSameSub() throws {
        let rate = 48_000.0
        var impulse = [Float](repeating: 0, count: 4_800); impulse[0] = 1
        let left = try ThroughFeedSplitterRenderer.render(impulse, feed: .left, bass: bass(), sampleRate: rate)
        let right = try ThroughFeedSplitterRenderer.render(impulse, feed: .right, bass: bass(), sampleRate: rate)
        XCTAssertEqual(left.bus(N60SpeakerOutputBusRightHigh).map { abs($0) }.max(), 0)
        XCTAssertEqual(right.bus(N60SpeakerOutputBusLeftHigh).map { abs($0) }.max(), 0)
        XCTAssertEqual(left.bus(N60SpeakerOutputBusSubMono), right.bus(N60SpeakerOutputBusSubMono), "one shared sub")
        XCTAssertEqual(ThroughFeedSplitterRenderer.Feed.right.recordSource, .feedRight)
    }

    func testDisabledOrUnsetSplitterThrows() {
        var off = bass(); off.enabled = false
        XCTAssertThrowsError(try ThroughFeedSplitterRenderer.render([1, 0], feed: .left, bass: off, sampleRate: 48_000))
        var unset = bass(); unset.physicalOutputMode = nil
        XCTAssertThrowsError(try ThroughFeedSplitterRenderer.render([1, 0], feed: .left, bass: unset, sampleRate: 48_000))
        XCTAssertThrowsError(try ThroughFeedSplitterRenderer.render([], feed: .left, bass: bass(), sampleRate: 48_000))
        XCTAssertThrowsError(try ThroughFeedSplitterRenderer.render([.nan, 0], feed: .left, bass: bass(), sampleRate: 48_000))
    }

    func testRenderedProgramKeepsTimingAndReplacesSamples() throws {
        let rate = 48_000.0
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: RoomCorrectionSweepSettings(
            sampleRate: rate, startFrequencyHz: 15, endFrequencyHz: 1_000, durationSeconds: 1, leadInSeconds: 0.1, tailSeconds: 0.5))
        let out = try ThroughFeedSplitterRenderer.program(program, feed: .left, bass: bass())
        XCTAssertEqual(out.sweepSamples.count, program.sweepSamples.count)
        XCTAssertEqual(out.inverseFilter, program.inverseFilter)
        XCTAssertEqual(out.leadInFrames, program.leadInFrames)
        XCTAssertNotEqual(out.sweepSamples, program.sweepSamples)
    }

    func testPositionStampFreshnessAndLegacyDecode() throws {
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: Date(), rawCapture: [], impulseResponse: [1], transferFunction: nil,
            quality: RoomCorrectionMeasurementQuality())
        let state = AncBassPathState.resolve(arrangement: nil, bassManagement: bass())
        var position = RoomCorrectionMeasurementPosition(name: "Seat", sampleRate: 48_000, left: channel, right: channel)
        XCTAssertEqual(state.freshness(of: position.ancBassFingerprint), .stale(AncBassPathState.staleMessage), "unstamped, sub in path")
        position.ancBassFingerprint = state.fingerprint
        XCTAssertEqual(state.freshness(of: position.ancBassFingerprint), .fresh)
        var changed = bass(); changed.frequencyHz = 100
        let other = AncBassPathState.resolve(arrangement: nil, bassManagement: changed)
        XCTAssertEqual(other.freshness(of: position.ancBassFingerprint), .stale(AncBassPathState.staleMessage))
        let decoded = try JSONDecoder().decode(RoomCorrectionMeasurementPosition.self, from: JSONEncoder().encode(position))
        XCTAssertEqual(decoded, position)
        // A stored position from before the stamp has no key at all.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(position)) as? [String: Any])
        json.removeValue(forKey: "ancBassFingerprint")
        let legacy = try JSONDecoder().decode(
            RoomCorrectionMeasurementPosition.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.ancBassFingerprint)
    }

    // MARK: Echo removal through the stamped record, sub active

    /// Band-limited (31.5-125 Hz) noise at the given rate.
    private func bandNoise(count: Int, rate: Double, seed: UInt64) -> [Float] {
        var hp = [Biquad(low: false, hz: 31.5, fs: rate), Biquad(low: false, hz: 31.5, fs: rate)]
        var lp = [Biquad(low: true, hz: 125, fs: rate), Biquad(low: true, hz: 125, fs: rate)]
        let white = FeedForwardEchoFlowTests.noise(count: count, seed: seed)
        var out = white.map { x -> Double in
            var v = Double(x)
            for i in 0..<2 { v = hp[i].run(v) }
            for i in 0..<2 { v = lp[i].run(v) }
            return v
        }
        let rms = (out.reduce(0) { $0 + $1 * $1 } / Double(out.count)).squareRoot()
        out = out.map { $0 * 0.1 / max(rms, 1e-12) }
        return out.map(Float.init)
    }

    func testEchoRemovalOfTwentyDBInTheSubBandThroughTheStampedRecord() throws {
        for rate in rates {
            let config = bass()
            let state = AncBassPathState.resolve(arrangement: nil, bassManagement: config)
            let delay = 0.006, gain: Float = 0.5

            // Leakage measured through the splitter (the S2b/S2c flow) and stamped with the bass path.
            let h = try ThroughFeedSplitterRenderer.combinedImpulseResponse(feed: .left, bass: config, sampleRate: rate, seconds: 0.12)
            let ir = [Float](repeating: 0, count: Int((delay * rate).rounded())) + h.map { $0 * gain }
            let padded = ir + [Float](repeating: 0, count: 2_000)
            var echo = try FeedForwardEchoModelBuilder.build(left: [padded], right: [padded], nativeSampleRate: rate, capturedAt: Date())
            echo.right = FeedForwardEchoPath(bulkDelay: 0, taps: [0], bound: [0])
            var survey = QuietZoneFeedForwardDesignSurvey(
                projectID: UUID(), microphoneStableID: "mic", errorChannel: 0, referenceChannel: 1,
                sampleRate: rate, capturedAt: Date(), segments: 100, bands: [])
            survey.echoModel = echo
            survey.echoBassFingerprint = state.fingerprint
            survey = try JSONDecoder().decode(QuietZoneFeedForwardDesignSurvey.self, from: JSONEncoder().encode(survey))
            XCTAssertEqual(state.freshness(of: survey.echoBassFingerprint), .fresh, "the stamped record is fresh")
            var changed = config; changed.frequencyHz = 120
            XCTAssertEqual(
                AncBassPathState.resolve(arrangement: nil, bassManagement: changed).freshness(of: survey.echoBassFingerprint),
                .stale(AncBassPathState.staleMessage), "a changed crossover makes the record stale")

            // The programme: band-limited drive through the same splitter; the reference hears it with the sub.
            let seconds = 14.0
            let drive = bandNoise(count: Int((seconds + 1) * rate), rate: rate, seed: 7)
            let heard = try ThroughFeedSplitterRenderer.render(drive, feed: .left, bass: config, sampleRate: rate).combined
            let fd = rate / Double(N60AncDecimationFactor(rate))
            let plan = QuietZoneFeedForwardShadowPlan(
                nativeSampleRate: rate, decimatedRate: fd, seedSource: .zeroWeights(reason: "test"),
                seedLeft: [Float](repeating: 0, count: 128), seedRight: [Float](repeating: 0, count: 128),
                leftPath: .init(bulkDelay: echo.left.bulkDelay, taps: echo.left.taps),
                rightPath: .init(bulkDelay: echo.right.bulkDelay, taps: echo.right.taps), bands: [])
            let capture = CombinedEchoPair(sampleRate: rate, heard: heard, delaySeconds: delay, gain: gain)
            let engine = try XCTUnwrap(QuietZoneFeedForwardShadowEngine(
                plan: plan, capture: capture, echo: survey.echoModelOrLegacy, driveSampleRate: rate, hostSeconds: { Double($0) * 1.0e-9 }))
            XCTAssertTrue(engine.echoActive)
            try engine.start()
            var next = 0
            var snapshot: QuietZoneFeedForwardShadowEngine.Snapshot?
            var t = 0.0
            while t < seconds {
                t += 0.1
                capture.produce(seconds: 0.1)
                let upTo = min(Int((t + 0.05) * rate), drive.count)
                var chunk = FeedForwardDriveChunk(
                    anchors: [], left: [], right: [], firstFrame: UInt64(next), droppedFrames: 0, droppedAnchors: 0)
                var k = next
                while k < upTo {
                    let n = min(512, upTo - k)
                    chunk.anchors.append(N60SpeakerDriveAnchor(
                        outputHostTime: capture.driveHostNanos(frame: k), firstFrameIndex: UInt64(k), frames: UInt32(n), reserved: 0))
                    k += n
                }
                chunk.left = Array(drive[next..<upTo])
                chunk.right = [Float](repeating: 0, count: upTo - next)
                next = upTo
                snapshot = try engine.pump(drive: chunk)
            }
            let status = try XCTUnwrap(snapshot).status
            XCTAssertEqual(status.echoState, UInt32(N60_FF_ECHO_LOCKED), "\(rate)")
            let removal = 10 * log10(Double(status.referencePowerBefore) / max(Double(status.referencePowerAfter), 1e-30))
            XCTAssertGreaterThanOrEqual(removal, 20, "\(rate): before \(status.referencePowerBefore) after \(status.referencePowerAfter)")
            engine.close()
        }
    }
}

/// The reference microphone hears `heard` (the drive after the splitter and the sub), delayed and scaled.
private final class CombinedEchoPair: QuietZoneFeedForwardPairCapturing {
    let sampleRate: Double
    private let heard: [Float]
    private let delayFrames: Int
    private let gain: Float
    private var available = 0
    private var next = 0
    private let base = 1.0e12

    init(sampleRate: Double, heard: [Float], delaySeconds: Double, gain: Float) {
        self.sampleRate = sampleRate
        self.heard = heard
        self.delayFrames = Int((delaySeconds * sampleRate).rounded())
        self.gain = gain
    }

    func start() throws {}
    func close() {}
    func produce(seconds: Double) { available += Int((seconds * sampleRate).rounded()) }
    func driveHostNanos(frame: Int) -> UInt64 { UInt64(base + Double(frame) / sampleRate * 1.0e9) }

    func readPair(maximumFrames: Int) throws -> (reference: [N60FeedForwardReferenceFrame], error: [Float]) {
        let count = min(maximumFrames, available)
        available -= count
        var frames = [N60FeedForwardReferenceFrame](repeating: N60FeedForwardReferenceFrame(), count: count)
        var error = [Float](repeating: 0, count: count)
        let callback = 512
        for i in 0..<count {
            let m = next + i
            let offset = m % callback
            let start = m - offset
            let source = m - delayFrames
            let x = source >= 0 && source < heard.count ? gain * heard[source] : 0
            frames[i].sample = x
            frames[i].firstFrameHostTime = UInt64(base + Double(start) / sampleRate * 1.0e9)
            frames[i].firstFrameSampleTime = Double(start)
            frames[i].frameOffset = UInt32(offset)
            error[i] = x
        }
        next += count
        return (frames, error)
    }
}
