import CoreAudio
import XCTest
@testable import NotchSixty

/// E4 S30b: the planner's inputs (band aggregation, speech and noise from the residual and baseline, add-back
/// of applied cuts), the 4 s speech-envelope history, and the tap point of the playback reference.
final class ConversationUnmaskingInputTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let n = SpeechIntelligibilityBands.centersHz.count

    /// 64 log bands 20 Hz to 20 kHz (the analyser's production layout) with a per-band level function.
    private func bands(_ level: (Double) -> Double) -> [AmbientSpectrumBand] {
        (0..<64).map { i in
            let lo = 20 * pow(1000.0, Double(i) / 64)
            let hi = 20 * pow(1000.0, Double(i + 1) / 64)
            let c = (lo * hi).squareRoot()
            return AmbientSpectrumBand(lowerFrequencyHz: lo, centerFrequencyHz: c, upperFrequencyHz: hi, levelDBFS: level(c))
        }
    }

    // MARK: aggregation

    func testAggregationConservesPowerAndMatchesWhiteNoiseDensity() throws {
        // White noise: band power proportional to linear width.
        let density = 1e-9
        let spectrum = bands { _ in 0 }.map {
            AmbientSpectrumBand(lowerFrequencyHz: $0.lowerFrequencyHz, centerFrequencyHz: $0.centerFrequencyHz,
                                upperFrequencyHz: $0.upperFrequencyHz,
                                levelDBFS: 10 * log10(density * ($0.upperFrequencyHz - $0.lowerFrequencyHz)))
        }
        let total = spectrum.reduce(0.0) { $0 + pow(10, $1.levelDBFS / 10) }
        let result = try XCTUnwrap(ThirdOctaveBandAggregator.aggregate(spectrum))
        let sum = result.bandLevelsDB.reduce(pow(10, result.outsideLevelDB / 10)) { $0 + pow(10, $1 / 10) }
        XCTAssertEqual(10 * log10(sum / total), 0, accuracy: 0.1)
        let half = pow(2.0, 1.0 / 6.0)
        for (j, c) in SpeechIntelligibilityBands.centersHz.enumerated() {
            let expected = 10 * log10(density * c * (half - 1 / half))
            XCTAssertEqual(result.bandLevelsDB[j], expected, accuracy: 0.5, "band \(c)")
        }
    }

    func testAggregationOfRealAnalysisAtEveryRate() throws {
        for rate in Self.rates {
            // 1 kHz tone plus quiet noise through the production analyser.
            let count = 32_768
            var seed: UInt64 = 12345
            let mic = (0..<count).map { i -> Float in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Double(Int64(bitPattern: seed >> 11) % 1000) / 1000 * 1e-3
                return Float(0.1 * sin(2 * .pi * 1_000 * Double(i) / rate) + noise)
            }
            let analysis = try AmbientFieldAnalyzer().analyzeDetailed(microphone: mic, playbackSources: [], sampleRate: rate)
            let result = try XCTUnwrap(ThirdOctaveBandAggregator.aggregate(analysis.snapshot.spectrum), "rate \(rate)")
            let loudest = try XCTUnwrap(result.bandLevelsDB.enumerated().max { $0.element < $1.element })
            XCTAssertEqual(SpeechIntelligibilityBands.centersHz[loudest.offset], 1_000, "rate \(rate)")
            let total = analysis.snapshot.spectrum.reduce(0.0) { $0 + pow(10, $1.levelDBFS / 10) }
            let sum = result.bandLevelsDB.reduce(pow(10, result.outsideLevelDB / 10)) { $0 + pow(10, $1 / 10) }
            XCTAssertEqual(10 * log10(sum / total), 0, accuracy: 0.1, "rate \(rate)")
        }
    }

    func testIncompleteSpectrumIsRefused() {
        let partial = bands { _ in -40 }.filter { $0.upperFrequencyHz < 5_000 }
        XCTAssertNil(ThirdOctaveBandAggregator.aggregate(partial))
        XCTAssertNil(ThirdOctaveBandAggregator.aggregate([]))
    }

    // MARK: builder

    /// A spectrum whose level in each third-octave band is `levels[j]` (smooth, so analyser bands that
    /// straddle an edge stay within the 0.5 dB tolerance).
    private func shaped(_ levels: [Double]) -> [AmbientSpectrumBand] {
        bands { c in
            let j = SpeechIntelligibilityBands.centersHz.enumerated().min {
                abs(log($0.element / c)) < abs(log($1.element / c))
            }!.offset
            // A third-octave band spans about 2.14 of the 64 analyser bands, so subtract that gain.
            return levels[j] - 10 * log10(2.141)
        }
    }

    func testAppliedCutsAreAddedBackToTheUncutLevel() throws {
        let uncut = (0..<n).map { 50 - 0.5 * Double($0) }
        let cuts = (0..<n).map { max(4 - 0.25 * Double($0), 0) }
        let reference = shaped(zip(uncut, cuts).map { $0 - $1 })
        let quiet = shaped([Double](repeating: 10, count: n))
        let input = try ConversationUnmaskingInputBuilder.build(
            residual: shaped([Double](repeating: 30, count: n)), playback: reference, baseline: quiet,
            appliedCutsDB: cuts, speechConfidence: 1
        ).get()
        let reference0 = try ConversationUnmaskingInputBuilder.build(
            residual: shaped([Double](repeating: 30, count: n)), playback: shaped(uncut), baseline: quiet,
            appliedCutsDB: [Double](repeating: 0, count: n), speechConfidence: 1
        ).get()
        for j in 0..<n {
            XCTAssertEqual(input.musicBandLevelsDB[j], reference0.musicBandLevelsDB[j], accuracy: 0.5, "band \(j)")
        }
    }

    func testSpeechIsResidualMinusBaselineWithAFloor() throws {
        let zeros = [Double](repeating: 0, count: n)
        let baseline = shaped([Double](repeating: 20, count: n))
        // Residual 10 dB over the baseline in the low half of the bands, equal to the baseline in the rest.
        let residualLevels = (0..<n).map { $0 < 8 ? 30.0 : 20.0 }
        let input = try ConversationUnmaskingInputBuilder.build(
            residual: shaped(residualLevels), playback: shaped([Double](repeating: 40, count: n)),
            baseline: baseline, appliedCutsDB: zeros, speechConfidence: 0.9
        ).get()
        XCTAssertEqual(input.speechConfidence, 0.9)
        XCTAssertEqual(input.noiseBandLevelsDB.count, n)
        // Residual 10 dB over the baseline: speech is 10 log10(10 - 1) = 9.54 dB over it.
        XCTAssertEqual(input.speechBandLevelsDB[2] - input.noiseBandLevelsDB[2], 10 * log10(9), accuracy: 0.6)
        // Nothing above the baseline: the floor is 20 dB under it.
        XCTAssertEqual(input.speechBandLevelsDB[12] - input.noiseBandLevelsDB[12], -20, accuracy: 0.6)
    }

    func testMissingInputsAreReported() {
        let s = shaped([Double](repeating: 20, count: n))
        let zeros = [Double](repeating: 0, count: n)
        func build(playback: [AmbientSpectrumBand]?, baseline: [AmbientSpectrumBand]?, cuts: [Double]? = nil)
            -> ConversationUnmaskingInputBuilder.Unavailable? {
            if case .failure(let reason) = ConversationUnmaskingInputBuilder.build(
                residual: s, playback: playback, baseline: baseline, appliedCutsDB: cuts ?? zeros, speechConfidence: 1
            ) { return reason }
            return nil
        }
        XCTAssertEqual(build(playback: nil, baseline: s), .noPlaybackModel)
        XCTAssertEqual(build(playback: s, baseline: nil), .noBaseline)
        XCTAssertEqual(build(playback: s, baseline: s, cuts: [1]), .invalidAppliedCuts)
        XCTAssertEqual(build(playback: s, baseline: s, cuts: [Double](repeating: -1, count: n)), .invalidAppliedCuts)
        XCTAssertEqual(build(playback: s.filter { $0.upperFrequencyHz < 5_000 }, baseline: s), .incompleteSpectrum)
        XCTAssertNil(build(playback: s, baseline: s))
    }

    // MARK: planner with a noise masker

    func testNoiseDominantBandIsLeftUncut() throws {
        let level = [Double](repeating: 50, count: n)
        var noise = [Double](repeating: 0, count: n)  // far below the music: music is the masker
        noise[7] = 70  // 1 kHz: the room noise masks the speech, cutting music cannot help
        let input = ConversationUnmaskingInput(
            speechBandLevelsDB: level.map { $0 - 2 }, musicBandLevelsDB: level, lowMusicLevelDB: 60,
            speechConfidence: 1, noiseBandLevelsDB: noise
        )
        let plan = try XCTUnwrap(ConversationUnmaskingPlanner().plan(input))
        XCTAssertEqual(plan.bandCutsDB[7], 0)
        XCTAssertGreaterThan(plan.bandCutsDB.reduce(0, +), 0)
        XCTAssertGreaterThan(plan.siiAfter, plan.siiBefore)
        // Without the noise masker the same band is cut.
        var quiet = input
        quiet.noiseBandLevelsDB = []
        XCTAssertGreaterThan(try XCTUnwrap(ConversationUnmaskingPlanner().plan(quiet)).bandCutsDB[7], 0)
        // A wrong-length noise array is refused.
        var bad = input
        bad.noiseBandLevelsDB = [1, 2]
        XCTAssertNil(ConversationUnmaskingPlanner().plan(bad))
    }

    func testPlannerLimitsHoldWithNoise() throws {
        let level = [Double](repeating: 50, count: n)
        let input = ConversationUnmaskingInput(
            speechBandLevelsDB: level.map { $0 - 8 }, musicBandLevelsDB: level, lowMusicLevelDB: 55,
            speechConfidence: 1, noiseBandLevelsDB: [Double](repeating: 30, count: n)
        )
        let plan = try XCTUnwrap(ConversationUnmaskingPlanner().plan(input))
        XCTAssertTrue(plan.bandCutsDB.allSatisfy { $0 >= 0 && $0 <= 6 + 1e-9 })
        XCTAssertGreaterThanOrEqual(plan.overallChangeDB, -3 - 1e-6)
    }

    // MARK: evaluator

    private func detailed(
        rate: Double, playback: Bool, confidence: Double = 1
    ) throws -> AmbientAnalysisDetailedResult {
        let count = 8_192
        let mic = (0..<count).map { Float(0.05 * sin(2 * .pi * 500 * Double($0) / rate)) }
        let source = AmbientPlaybackSourceReference(id: "p", samples: mic, acousticImpulseResponse: [1])
        return try AmbientFieldAnalyzer().analyzeDetailed(
            microphone: mic, playbackSources: playback ? [source] : [], sampleRate: rate
        )
    }

    func testEvaluatorCarriesThePlaybackPredictionAtEveryRateAndExplainsFallbacks() throws {
        for rate in Self.rates {
            let withModel = try detailed(rate: rate, playback: true)
            let without = try detailed(rate: rate, playback: false)
            XCTAssertNotNil(withModel.modeledPlaybackSpectrum, "rate \(rate)")
            XCTAssertNil(without.modeledPlaybackSpectrum, "rate \(rate)")
            func status(_ d: AmbientAnalysisDetailedResult, mode: ActiveAcousticsPlaybackAdaptationMode = .conversationFocus,
                        running: Bool = true, baseline: [AmbientSpectrumBand]? = nil, seconds: Double = 4,
                        minConfidence: Double = 0.0) -> ConversationUnmaskingStatus {
                ConversationUnmaskingEvaluator.evaluate(
                    mode: mode, running: running, detailed: d, quietBaseline: baseline, envelopeSeconds: seconds,
                    speechConfidence: 0.9, appliedCutsDB: [Double](repeating: 0, count: n),
                    minimumSeparationConfidence: minConfidence
                ).status
            }
            XCTAssertEqual(status(withModel, mode: .musicFocus), .fallback(.notConversationFocus))
            XCTAssertEqual(status(withModel, running: false), .fallback(.notPlaying))
            XCTAssertEqual(status(without), .fallback(.noPlaybackModel))
            XCTAssertEqual(status(withModel, minConfidence: 1.01), .fallback(.lowSeparationConfidence))
            XCTAssertEqual(status(withModel, seconds: 1.5), .fallback(.shortEnvelope))
            XCTAssertEqual(status(withModel), .fallback(.noBaseline))
        }
    }

    func testEvaluatorPlansWithAllInputs() throws {
        let rate = 48_000.0
        // Music loud in the speech region, speech and baseline lower, through the production analyser.
        let count = 16_384
        func tones(_ f: [Double], _ amp: Double) -> [Float] {
            (0..<count).map { i in Float(amp * f.reduce(0.0) { $0 + sin(2 * .pi * $1 * Double(i) / rate) }) }
        }
        // Music and a quieter "voice" 6 dB lower in the same third-octave bands.
        let music = tones([500, 1_000, 2_000], 0.2)
        let speechLike = tones([530, 1_060, 2_120], 0.1)
        let mic = zip(music, speechLike).map { $0 + $1 }
        let source = AmbientPlaybackSourceReference(id: "p", samples: music, acousticImpulseResponse: [1])
        let analysis = try AmbientFieldAnalyzer().analyzeDetailed(microphone: mic, playbackSources: [source], sampleRate: rate)
        XCTAssertEqual(analysis.snapshot.separationMode, .modeledPlaybackSubtraction)
        // A quiet baseline well under the speech.
        let quiet = bands { _ in -120 }
        let result = ConversationUnmaskingEvaluator.evaluate(
            mode: .conversationFocus, running: true, detailed: analysis, quietBaseline: quiet, envelopeSeconds: 4,
            speechConfidence: 0.8, appliedCutsDB: [Double](repeating: 0, count: n), minimumSeparationConfidence: 0
        )
        guard case .planned(let plan) = result.status else { return XCTFail("expected a plan, got \(result.status)") }
        XCTAssertNotNil(result.input)
        XCTAssertGreaterThan(plan.bandCutsDB.reduce(0, +), 0)
        XCTAssertGreaterThan(plan.siiAfter, plan.siiBefore)
        // Low confidence plans no cuts but still reports.
        let calm = ConversationUnmaskingEvaluator.evaluate(
            mode: .conversationFocus, running: true, detailed: analysis, quietBaseline: quiet, envelopeSeconds: 4,
            speechConfidence: 0.1, appliedCutsDB: [Double](repeating: 0, count: n), minimumSeparationConfidence: 0
        )
        guard case .planned(let calmPlan) = calm.status else { return XCTFail("expected a plan") }
        XCTAssertEqual(calmPlan.bandCutsDB.reduce(0, +), 0)
    }

    // MARK: speech envelope history

    private let epoch = UUID()

    /// A carrier (deterministic noise) with a 4 Hz amplitude modulation when `depth` > 0.
    private func stream(rate: Double, seconds: Double, depth: Double, from: Int = 0, count: Int? = nil) -> [Float] {
        let total = count ?? Int(rate * seconds)
        var seed: UInt64 = 99 &+ UInt64(from)
        return (0..<total).map { i -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let carrier = Double(Int64(bitPattern: seed) >> 40) / 8_388_608
            let t = Double(from + i) / rate
            return Float(0.1 * (1 + depth * sin(2 * .pi * 4 * t)) * carrier)
        }
    }

    /// Feeds `signal` as overlapping windows the way the controller does.
    private func feed(_ history: inout SpeechEnvelopeHistory, signal: [Float], rate: Double, epoch: UUID? = nil) {
        let window = min(Int(rate * 0.5), 65_536)
        let step = min(Int(rate * 0.25), window)
        var end = window
        while end <= signal.count {
            history.append(window: Array(signal[(end - window)..<end]), endFrame: UInt64(end), sampleRate: rate,
                           epoch: epoch ?? self.epoch, microphoneID: "mic")
            end += step
        }
    }

    func testSpeechModulationGivesConfidenceAfterTwoSecondsAndMusicDoesNot() {
        for rate in Self.rates {
            var speech = SpeechEnvelopeHistory()
            var music = SpeechEnvelopeHistory()
            let speechSignal = stream(rate: rate, seconds: 4, depth: 0.8)
            let musicSignal = stream(rate: rate, seconds: 4, depth: 0)
            feed(&speech, signal: Array(speechSignal.prefix(Int(rate * 1.5))), rate: rate)
            XCTAssertEqual(speech.confidence, 0, "rate \(rate): under 2 s")
            speech = SpeechEnvelopeHistory()
            feed(&speech, signal: Array(speechSignal.prefix(Int(rate * 2.5))), rate: rate)
            feed(&music, signal: Array(musicSignal.prefix(Int(rate * 2.5))), rate: rate)
            XCTAssertGreaterThanOrEqual(speech.confidence, 0.5, "rate \(rate)")
            XCTAssertLessThan(music.confidence, 0.2, "rate \(rate)")
        }
    }

    func testOverlappingWindowsCountEachSampleOnce() {
        for rate in [44_100.0, 96_000, 384_000] {
            let signal = stream(rate: rate, seconds: 3, depth: 0.8)
            var overlapped = SpeechEnvelopeHistory()
            feed(&overlapped, signal: signal, rate: rate)
            let fed = (overlapped.envelope.count)
            var whole = SpeechEnvelopeHistory()
            // The overlapped feed ended at the last whole step; give `whole` exactly the same frames.
            let window = min(Int(rate * 0.5), 65_536)
            let step = min(Int(rate * 0.25), window)
            var end = window
            while end + step <= signal.count { end += step }
            whole.append(window: Array(signal[0..<end]), endFrame: UInt64(end), sampleRate: rate, epoch: epoch, microphoneID: "mic")
            XCTAssertEqual(overlapped.envelope.count, fed)
            XCTAssertEqual(overlapped.envelope, whole.envelope, "rate \(rate)")
            XCTAssertEqual(whole.envelope.count, Int(Double(end) / (rate / 100)), "rate \(rate)")
        }
    }

    func testHistoryKeepsFourSecondsAndHoldsNoSamples() {
        let rate = 48_000.0
        var history = SpeechEnvelopeHistory()
        feed(&history, signal: stream(rate: rate, seconds: 7, depth: 0.8), rate: rate)
        XCTAssertEqual(history.envelope.count, 400)
        XCTAssertEqual(history.seconds, 4, accuracy: 1e-9)
        // The stored values are block RMS numbers: far fewer than the samples they came from.
        XCTAssertLessThan(history.envelope.count, Int(rate) / 100)
    }

    func testGapAndSourceChangesClearTheHistory() {
        let rate = 48_000.0
        let signal = stream(rate: rate, seconds: 3, depth: 0.8)
        func filled() -> SpeechEnvelopeHistory {
            var h = SpeechEnvelopeHistory()
            feed(&h, signal: signal, rate: rate)
            XCTAssertGreaterThan(h.envelope.count, 200)
            return h
        }
        let window = Array(signal.prefix(24_000))
        let blockFrames = 480

        var gap = filled()
        let end = gap.envelope.count * blockFrames
        gap.append(window: window, endFrame: UInt64(end + 100_000), sampleRate: rate, epoch: epoch, microphoneID: "mic")
        XCTAssertEqual(gap.envelope.count, 24_000 / blockFrames, "a gap keeps only the new window")

        var epochChange = filled()
        epochChange.append(window: window, endFrame: UInt64(signal.count + 24_000), sampleRate: rate, epoch: UUID(), microphoneID: "mic")
        XCTAssertEqual(epochChange.envelope.count, 24_000 / blockFrames)

        var micChange = filled()
        micChange.append(window: window, endFrame: UInt64(signal.count + 24_000), sampleRate: rate, epoch: epoch, microphoneID: "other")
        XCTAssertEqual(micChange.envelope.count, 24_000 / blockFrames)

        var rateChange = filled()
        rateChange.append(window: window, endFrame: UInt64(signal.count + 24_000), sampleRate: 96_000, epoch: epoch, microphoneID: "mic")
        XCTAssertEqual(rateChange.envelope.count, 24_000 / 960)

        var explicit = filled()
        explicit.reset()
        XCTAssertTrue(explicit.envelope.isEmpty)
        XCTAssertEqual(explicit.confidence, 0)

        // The same window again adds nothing.
        var repeated = SpeechEnvelopeHistory()
        repeated.append(window: window, endFrame: 24_000, sampleRate: rate, epoch: epoch, microphoneID: "mic")
        let before = repeated.envelope
        repeated.append(window: window, endFrame: 24_000, sampleRate: rate, epoch: epoch, microphoneID: "mic")
        XCTAssertEqual(repeated.envelope, before)
    }

    // MARK: tap point

    /// The playback reference the analyser predicts from is the engine's final output, so it carries the
    /// ambient gain already applied (the ambient stage is before the tap). That is why the builder adds the applied cuts back.
    func testPlaybackReferenceCarriesTheAppliedAmbientGain() throws {
        for rate in Self.rates {
            let cut = try renderReference(rate: rate, ambientLevelDB: 4)
            let plain = try renderReference(rate: rate, ambientLevelDB: 0)
            XCTAssertEqual(cut.reference.count, cut.output.count, "rate \(rate)")
            for (r, o) in zip(cut.reference, cut.output) { XCTAssertEqual(r, o, accuracy: 1e-6, "rate \(rate)") }
            let ratio = 20 * log10(Self.rms(cut.reference) / Self.rms(plain.reference))
            XCTAssertEqual(ratio, 4, accuracy: 0.5, "rate \(rate): the reference must carry the +4 dB ambient gain (the stage is after the tap-point; cuts arrive with S30a)")
        }
    }

    private static func rms(_ x: [Float]) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))).squareRoot()
    }

    private func renderReference(rate: Double, ambientLevelDB: Double) throws -> (reference: [Float], output: [Float]) {
        let block = 256
        let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(4_096))
        defer { N60RealtimeAudioBridgeDestroy(bridge) }
        var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
        XCTAssertTrue(N60DSPGraphSnapshotSetAmbientCompensation(&snapshot, ambientLevelDB, 0, 0, 0, true))
        XCTAssertTrue(N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot))
        N60RealtimeAudioBridgeConfigureOutputGate(bridge, UInt32(2 * block), 64)
        N60RealtimeAudioBridgeSetAmbientReferenceDemand(bridge, true)
        var output: [Float] = []
        var reference: [Float] = []
        for index in 0..<60 {
            let program = (0..<block).map { Float(0.4 * sin(Double(index * block + $0) * 2 * .pi * 997 / rate)) }
            capture(program, bridge: bridge)
            guard index >= 2 else { continue }
            let rendered = render(frames: block, bridge: bridge)
            var frames = [N60AmbientPlaybackReferenceFrame](repeating: N60AmbientPlaybackReferenceFrame(), count: block)
            let read = Int(frames.withUnsafeMutableBufferPointer {
                N60RealtimeAudioBridgeReadAmbientReferenceFrames(bridge, $0.baseAddress!, UInt32($0.count))
            })
            guard index >= 40 else { continue } // after the level ramp has settled
            output += rendered
            reference += frames.prefix(read).flatMap { [$0.left, $0.right] }
        }
        return (reference, output)
    }

    private func capture(_ mono: [Float], bridge: OpaquePointer) {
        var samples = mono.flatMap { [$0, $0] }
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(buffer.count * 4),
                                      mData: UnsafeMutableRawPointer(buffer.baseAddress))
            )
            var unusedOutput = AudioBufferList()
            var now = AudioTimeStamp(), inputTime = AudioTimeStamp(), outputTime = AudioTimeStamp()
            _ = N60CaptureIOProc(0, &now, &list, &inputTime, &unusedOutput, &outputTime, UnsafeMutableRawPointer(bridge))
        }
    }

    private func render(frames: Int, bridge: OpaquePointer) -> [Float] {
        var samples = [Float](repeating: -1, count: frames * 2)
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(buffer.count * 4),
                                      mData: UnsafeMutableRawPointer(buffer.baseAddress))
            )
            var unusedInput = AudioBufferList()
            var now = AudioTimeStamp(), inputTime = AudioTimeStamp(), outputTime = AudioTimeStamp()
            _ = N60OutputIOProc(0, &now, &unusedInput, &inputTime, &list, &outputTime, UnsafeMutableRawPointer(bridge))
        }
        return samples
    }
}
