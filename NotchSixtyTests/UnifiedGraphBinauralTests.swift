import XCTest
@testable import NotchSixty

/// E6 S8b2d: the binaural headphone session's unified-graph spec. Behavioural: real graphs,
/// real audio blocks, every standard rate.
final class UnifiedGraphBinauralTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    private func spec(
        rate: Double,
        layout: OutputProgramLayout = .fiveOne,
        headTracking: Bool = false,
        profile: HeadphoneDeviceProfileConfiguration = HeadphoneDeviceProfileConfiguration(),
        outputChannels: UInt32 = 2,
        asset: BinauralProfileAsset? = nil
    ) -> Result<UnifiedGraphSpec, UnifiedGraphFallbackReason> {
        var profile = profile
        profile.programLayout = layout
        return UnifiedGraphTranslator.binauralSpec(
            asset: asset ?? BinauralProfileAsset.validationStereo(sampleRate: rate),
            layout: layout, profile: profile, outputChannels: outputChannels,
            sampleRate: rate, headTracking: headTracking
        )
    }

    /// Renders a 1 kHz tone on lane 0 only and returns (left ear RMS, right ear RMS) once settled.
    private func earLevels(host: UnifiedGraphHost, rate: Double, lanes: Int) throws -> (Double, Double) {
        let block = 512
        let total = Int(rate * 0.3) / block * block
        var left: [Float] = [], right: [Float] = []
        var position = 0
        while position < total {
            let tone = (0..<block).map {
                Float(0.25 * sin(2.0 * .pi * 1_000.0 * Double(position + $0) / rate))
            }
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: lanes)
            input[0] = tone
            let out = try host.processOffline(input: input, frames: block)
            left += out[0]; right += out[1]
            position += block
        }
        let start = left.count * 3 / 4
        return (rms(left[start...]), rms(right[start...]))
    }

    func testFallbackReasons() throws {
        let rate = 48_000.0
        guard case .failure(let missing) = UnifiedGraphTranslator.binauralSpec(
            asset: nil, layout: .fiveOne, profile: HeadphoneDeviceProfileConfiguration(),
            outputChannels: 2, sampleRate: rate, headTracking: false
        ) else { return XCTFail("nil asset must fall back") }
        XCTAssertEqual(missing, .binauralProfileMissing)

        guard case .failure(let notStereo) = spec(rate: rate, outputChannels: 6) else {
            return XCTFail("six-channel output must fall back")
        }
        XCTAssertEqual(notStereo, .binauralOutputNotStereo)

        guard case .failure(let stereoProgram) = spec(rate: rate, layout: .stereo) else {
            return XCTFail("a stereo program has nothing to virtualise")
        }
        XCTAssertEqual(stereoProgram, .noProgramLanes)

        var big = BinauralProfileAsset.validationStereo(sampleRate: rate)
        big.tapCount = BinauralProfileAsset.maxTapCount(sampleRate: rate) + 1
        guard case .failure(let budget) = spec(rate: rate, asset: big) else {
            return XCTFail("an over-budget set must fall back")
        }
        XCTAssertEqual(budget, .binauralBudget)

        // E6 S9c2: the headphone profile's whole 0...30 dB headroom range is in the graph; the only DSP refusals left
        // are values the profile itself rejects (headroom above 30 dB, more than the legacy 16 EQ sections per side).
        var deep = HeadphoneDeviceProfileConfiguration()
        deep.headroomAttenuationDB = 27
        XCTAssertNoThrow(try spec(rate: rate, profile: deep).get())
        deep.headroomAttenuationDB = 30
        XCTAssertNoThrow(try spec(rate: rate, profile: deep).get())
        deep.headroomAttenuationDB = 31
        guard case .failure(let dsp) = spec(rate: rate, profile: deep) else {
            return XCTFail("a headroom above 30 dB must fall back")
        }
        XCTAssertEqual(dsp, .headphoneDSP)

        guard case .failure(let mismatch) = spec(
            rate: rate, asset: BinauralProfileAsset.validationStereo(sampleRate: 44_100)
        ) else { return XCTFail("an unconverted rate must fall back") }
        XCTAssertEqual(mismatch, .sampleRateMismatch)
    }

    /// The legacy headphone path allows 16 EQ sections per side (`N60_HEADPHONE_MAX_EQ_SECTIONS`); the graph takes
    /// all 16 at every rate and still refuses a 17th rather than silently dropping it.
    func testSixteenHeadphoneEQBandsPerSideBuildAndRenderAtEveryRate() throws {
        func bands(_ count: Int, _ rate: Double) -> [HeadphoneCorrectionEQBand] {
            (0..<count).map { index in
                var band = HeadphoneCorrectionEQBand()
                band.frequencyHz = min(100.0 * pow(1.28, Double(index)), rate * 0.4)
                band.gainDB = index.isMultiple(of: 2) ? 3 : -3
                band.q = 1.5
                return band
            }
        }
        for rate in Self.rates {
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.headroomAttenuationDB = 12
            profile.left.eqBands = bands(16, rate)
            profile.right.eqBands = bands(16, rate)
            let built = try spec(rate: rate, profile: profile).get()
            let host = try UnifiedGraphHost(spec: built)
            let (left, right) = try earLevels(host: host, rate: rate, lanes: 6)
            XCTAssertGreaterThan(left, 0.0005, "rate \(rate)")
            XCTAssertGreaterThan(right, 0.0001, "rate \(rate)")
            host.release()

            profile.left.eqBands = bands(17, rate)
            guard case .failure(let reason) = spec(rate: rate, profile: profile) else {
                return XCTFail("a 17th band must fall back at rate \(rate)")
            }
            XCTAssertEqual(reason, .headphoneDSP, "rate \(rate)")
        }
    }

    func testBinauralGraphRendersEarLevelsAtEveryRate() throws {
        for rate in Self.rates {
            let built = try spec(rate: rate).get()
            XCTAssertEqual(built.inputChannels, 6, "rate \(rate)")
            // The core keeps the program lane count; the ears are lanes 0 and 1.
            XCTAssertEqual(built.outputChannels, 6, "rate \(rate)")
            let host = try UnifiedGraphHost(spec: built)
            XCTAssertGreaterThanOrEqual(host.latencyFrames, 128, "rate \(rate)")
            let (left, right) = try earLevels(host: host, rate: rate, lanes: 6)
            // Front-left sits at -30 degrees: the near (left) ear is five times the far ear.
            XCTAssertGreaterThan(left, 0.01, "rate \(rate)")
            XCTAssertEqual(left / max(right, 1e-9), 5.0, accuracy: 0.5, "rate \(rate)")
            host.release()
        }
    }

    func testHeadYawPostMovesTheImageAtEveryRate() throws {
        for rate in Self.rates {
            let built = try spec(rate: rate, headTracking: true).get()
            let host = try UnifiedGraphHost(spec: built)
            let (leftFront, rightFront) = try earLevels(host: host, rate: rate, lanes: 6)
            XCTAssertGreaterThan(leftFront, rightFront, "rate \(rate)")
            // Turning the head to face the source's side swings the image to the other ear.
            try host.setBinauralPose(yaw: -60, pitch: 0, roll: 0)
            let (leftTurned, rightTurned) = try earLevels(host: host, rate: rate, lanes: 6)
            XCTAssertNotEqual(leftTurned / max(rightTurned, 1e-9), leftFront / max(rightFront, 1e-9),
                              accuracy: 0.2, "rate \(rate)")
            host.release()
        }
    }

    func testPoseWithoutBinauralStageThrows() throws {
        let stereo = try UnifiedGraphTranslator.layoutSpec(
            layoutIdentifier: UInt32(N60_LAYOUT_STEREO.rawValue), sampleRate: 48_000
        )
        let host = try UnifiedGraphHost(spec: stereo)
        XCTAssertThrowsError(try host.setBinauralPose(yaw: 10, pitch: 0, roll: 0))
        host.release()
    }

    func testPoseIsRefusedWhenBuiltWithoutHeadTracking() throws {
        let host = try UnifiedGraphHost(spec: try spec(rate: 48_000, headTracking: false).get())
        XCTAssertThrowsError(try host.setBinauralPose(yaw: 30, pitch: 0, roll: 0))
        host.release()
    }

    func testYawWrapsAndRepeatedPoseIsUnchanged() throws {
        let host = try UnifiedGraphHost(spec: try spec(rate: 48_000, headTracking: true).get())
        XCTAssertEqual(try host.setBinauralPose(yaw: 190, pitch: 0, roll: 0), .posted(count: 3))
        XCTAssertEqual(try host.setBinauralPose(yaw: -170, pitch: 0, roll: 0), .unchanged)
        host.release()
    }
    /// E6 S12g4 (G42): the largest legacy-supported set, 16 channels x 8192 taps x 24 head orientations, fits the graph
    /// budget; one tap more is refused with the named reason.
    func testLargestLegacyHRTFSetFitsTheBudgetAndOneTapMoreIsRefused() throws {
        let rate = 48_000.0
        var asset = BinauralProfileAsset.validationStereo(sampleRate: rate)
        let taps = Int(N60_GRAPH_BINAURAL_MAX_TAPS)
        asset.measurements = asset.measurements.map {
            var m = $0
            m.leftIR += [Float](repeating: 0, count: taps - m.leftIR.count)
            m.rightIR += [Float](repeating: 0, count: taps - m.rightIR.count)
            return m
        }
        asset.tapCount = taps
        let layout = OutputProgramLayout.nineOneSix
        XCTAssertEqual(layout.roles.count, 16)
        XCTAssertNoThrow(try spec(rate: rate, layout: layout, headTracking: true, asset: asset).get())
        // E13 S4: the limit is time-based (1 s), no longer 8192 taps; one tap over it is refused.
        asset.tapCount = BinauralProfileAsset.maxTapCount(sampleRate: rate) + 1
        guard case .failure(let reason) = spec(rate: rate, layout: layout, headTracking: true, asset: asset) else {
            return XCTFail("one tap over the time limit must be refused")
        }
        XCTAssertEqual(reason, .binauralBudget)
        // A mismatched asset rate is refused by name (the engine resamples through its asset cache first).
        guard case .failure(let mismatch) = spec(rate: rate, asset: BinauralProfileAsset.validationStereo(sampleRate: 44_100)) else {
            return XCTFail("a rate mismatch must be refused")
        }
        XCTAssertEqual(mismatch, .sampleRateMismatch)
    }

    // MARK: E13 S4 long BRIR (early/tail split, onset trim, time-based limits)

    /// A validation asset whose responses are `seconds` long: a direct impulse at `direct` (the original gains) and,
    /// when `echoAt` is given, an echo at that tap with `echoGain` times the direct amplitude on both ears.
    private func longAsset(rate: Double, seconds: Double, direct: Int = 0, echoAt: Int? = nil, echoGain: Float = 0.5)
        -> BinauralProfileAsset {
        var asset = BinauralProfileAsset.validationStereo(sampleRate: rate)
        let taps = Int((seconds * rate).rounded())
        asset.measurements = asset.measurements.map { source in
            var m = source
            func stretch(_ ir: [Float]) -> [Float] {
                var out = [Float](repeating: 0, count: taps)
                out[direct] = ir[0]
                if let echoAt {
                    // A smooth 0.4 ms pulse: the tail path is band-limited (a lone sample would lose level above its
                    // internal Nyquist), so the echo stays well inside the band.
                    let width = max(5, Int(rate * 0.0004) | 1)
                    for k in 0..<width {
                        let window = 0.5 * (1 - cos(2 * Double.pi * Double(k) / Double(width - 1)))
                        out[echoAt - width / 2 + k] += ir[0] * echoGain * Float(window)
                    }
                }
                return out
            }
            m.leftIR = stretch(source.leftIR)
            m.rightIR = stretch(source.rightIR)
            return m
        }
        asset.tapCount = taps
        return asset
    }

    /// Renders one impulse on lane 0 and returns the left ear for `frames` frames.
    private func impulseResponse(spec built: UnifiedGraphSpec, frames: Int, lanes: Int = 6) throws -> [Float] {
        let host = try UnifiedGraphHost(spec: built)
        defer { host.release() }
        let block = 512
        var left: [Float] = []
        var position = 0
        while position < frames {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: lanes)
            if position == 0 { input[0][0] = 1 }
            left += try host.processOffline(input: input, frames: block)[0]
            position += block
        }
        return left
    }

    private func peak(_ x: [Float], around center: Int, radius: Int) -> (index: Int, value: Float) {
        var best = (index: center, value: Float(0))
        for i in max(0, center - radius)...min(x.count - 1, center + radius) where abs(x[i]) > abs(best.value) {
            best = (i, x[i])
        }
        return best
    }

    /// A 1.0 s response with an echo at 0.6 s renders its direct sound and its echo (which lives in the shared tail)
    /// at every rate, with the declared latency unchanged.
    func testOneSecondBRIRRendersEarlyAndTailAtEveryRate() throws {
        for rate in Self.rates {
            let echo = Int(0.6 * rate)
            let built = try spec(rate: rate, asset: longAsset(rate: rate, seconds: 1.0, echoAt: echo)).get()
            let stage = try XCTUnwrap(built.stages.first { $0.stageId == N60_LSTAGE_BINAURAL })
            XCTAssertGreaterThan(stage.params[10], 0, "rate \(rate): a 1 s response has a tail")
            XCTAssertEqual(Int(stage.params[3]), Int((0.02 * rate).rounded()), "rate \(rate): early is 20 ms")
            // The whole graph's latency (stage plus the safety limiter's look-ahead) is the same as for a response with
            // no tail; the direct sound and the echo arrive that many frames after the input.
            let shortBuilt = try spec(rate: rate, asset: longAsset(rate: rate, seconds: 0.02)).get()
            let shortHost = try UnifiedGraphHost(spec: shortBuilt)
            let base = Int(shortHost.latencyFrames)
            shortHost.release()
            let host = try UnifiedGraphHost(spec: built)
            XCTAssertEqual(Double(host.latencyFrames), Double(base), accuracy: 1, "rate \(rate): latency unchanged")
            host.release()
            let out = try impulseResponse(spec: built, frames: Int(1.1 * rate))
            let direct = peak(out, around: base, radius: 3)
            XCTAssertEqual(Double(direct.index), Double(base), accuracy: 1, "rate \(rate)")
            XCTAssertGreaterThan(abs(direct.value), 0.1, "rate \(rate)")
            let late = peak(out, around: base + echo, radius: 4)
            XCTAssertEqual(Double(late.index), Double(base + echo), accuracy: 1, "rate \(rate): echo position")
            // The limiter's fractional look-ahead can split the lone direct sample over two frames, so the direct level
            // is the energy of its neighbourhood, not one sample.
            var energy: Float = 0
            for i in (direct.index - 4)...(direct.index + 4) { energy += out[i] * out[i] }
            XCTAssertEqual(abs(late.value) / energy.squareRoot(), 0.5, accuracy: 0.1, "rate \(rate): echo level")
        }
    }

    /// The common onset is trimmed to a 1 ms margin and the declared latency falls with it: a response whose direct
    /// sound sits 2000 taps in arrives (128 + margin) frames after the input.
    func testOnsetIsTrimmedToTheMarginAndShortensTheDeclaredLatency() throws {
        for rate in Self.rates {
            var asset = longAsset(rate: rate, seconds: 0.3, direct: 2_000)
            asset.declaredLatencyFrames = 2_000
            let built = try spec(rate: rate, asset: asset).get()
            let margin = Int((0.001 * rate).rounded(.up))
            let baseBuilt = try spec(rate: rate, asset: longAsset(rate: rate, seconds: 0.3)).get()
            let baseHost = try UnifiedGraphHost(spec: baseBuilt)
            let base = Int(baseHost.latencyFrames)
            baseHost.release()
            let host = try UnifiedGraphHost(spec: built)
            let expected: Int = base + margin
            XCTAssertEqual(Double(host.latencyFrames), Double(expected), accuracy: 1, "rate \(rate): declared latency falls with the trim")
            host.release()
            let out = try impulseResponse(spec: built, frames: 4_096)
            let direct = peak(out, around: expected, radius: 3)
            XCTAssertEqual(Double(direct.index), Double(expected), accuracy: 1, "rate \(rate)")
        }
    }

    /// 7.1.4 with 24 head orientations of a 20 ms early part fits the early budget at 384 kHz, and the 1 s tail fits
    /// its own budget.
    func testSevenOneFourTrackedLongBRIRFitsTheBudgetAt384k() throws {
        let rate = 384_000.0
        let layout = OutputProgramLayout.sevenOneFour
        XCTAssertEqual(layout.roles.count, 12)
        let asset = longAsset(rate: rate, seconds: 1.0, echoAt: Int(0.5 * rate))
        let built = try spec(rate: rate, layout: layout, headTracking: true, asset: asset).get()
        let stage = try XCTUnwrap(built.stages.first { $0.stageId == N60_LSTAGE_BINAURAL })
        let early = Int(stage.params[3])
        XCTAssertEqual(early, 7_680)
        XCTAssertLessThanOrEqual(12 * 2 * early * 24, UnifiedGraphTranslator.binauralMaxResponseFloats)
        XCTAssertEqual(Int(stage.params[10]), Int(rate) - early)
    }

    /// A 0.5 s asset recorded at 48 kHz converts to 352.8 and 384 kHz (time-based limit) and builds with a tail.
    func testHalfSecondAssetAt48kActivatesAtTheHighestRates() throws {
        let stored = longAsset(rate: 48_000, seconds: 0.5, echoAt: 20_000)
        for rate in [352_800.0, 384_000.0] {
            let converted = try stored.resampled(to: rate)
            XCTAssertLessThanOrEqual(converted.tapCount, BinauralProfileAsset.maxTapCount(sampleRate: rate))
            let built = try spec(rate: rate, asset: converted).get()
            let stage = try XCTUnwrap(built.stages.first { $0.stageId == N60_LSTAGE_BINAURAL })
            XCTAssertGreaterThan(stage.params[10], 0, "rate \(rate)")
        }
    }

    /// The asset limit is one second at every rate (so a 1 s response validates and a longer one does not), and the
    /// legacy renderer's copy of a long response is cut to its 8192 taps.
    func testAssetLimitIsTimeBasedAndLegacyTruncationKeepsTheFirstTaps() throws {
        for rate in Self.rates {
            XCTAssertNoThrow(try longAsset(rate: rate, seconds: 1.0).validate(), "rate \(rate)")
            var over = longAsset(rate: rate, seconds: 0.1)
            over.tapCount = BinauralProfileAsset.maxTapCount(sampleRate: rate) + 1
            XCTAssertThrowsError(try over.validate(), "rate \(rate)")
        }
        let asset = longAsset(rate: 48_000, seconds: 1.0, direct: 5, echoAt: 30_000)
        let prepared = try asset.prepare(for: .fiveOne)
        let cut = prepared.truncated(toTaps: Int(N60_BINAURAL_MAX_TAPS))
        XCTAssertEqual(Int(cut.descriptor.tapCount), Int(N60_BINAURAL_MAX_TAPS))
        XCTAssertEqual(cut.leftIRs.count, 6 * Int(N60_BINAURAL_MAX_TAPS))
        XCTAssertEqual(cut.leftIRs[5], prepared.leftIRs[5])
        XCTAssertEqual(cut.leftIRs[Int(N60_BINAURAL_MAX_TAPS) + 5], prepared.leftIRs[48_000 + 5])
    }
}
