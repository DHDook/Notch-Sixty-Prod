import XCTest
@testable import NotchSixty

/// E19 S12c (D15 mechanism B): the cued sweep stimulus for the treated probe: the post-only host path, the v48 generator words
/// through the real graph, and the production capturer against synthetic rooms at the standard rates.
@MainActor
final class MIMOProbeStimulusFeedTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Host

    private func sweepSettings(rate: Double) -> SignalGeneratorSettings {
        var s = SignalGeneratorSettings()
        s.kind = .sweep
        s.lowHz = 20
        s.highHz = 2_000
        s.periodFrames = Int(0.6 * rate)
        return s
    }

    private func spec(rate: Double, params: [Float]?) throws -> UnifiedGraphSpec {
        var config = UnifiedGraphConfiguration(
            sampleRate: rate, lanes: [UnifiedGraphLane(outputGain: 1, eq: []), UnifiedGraphLane(outputGain: 1, eq: [])])
        config.generatorParams = params
        return try config.makeSpec()
    }

    func testAPostedCueNeverRebuildsAndATopologyChangeThrowsWithTheGraphUntouched() throws {
        let rate = 48_000.0
        let s = sweepSettings(rate: rate)
        let installed = try spec(rate: rate, params: s.cuedStageParams(active: true, sampleRate: rate, solo: 0, cue: 0))
        let host = try UnifiedGraphHost(spec: installed)
        defer { host.release() }
        let cued = try spec(rate: rate, params: s.cuedStageParams(active: true, sampleRate: rate, solo: 2, cue: 1))
        guard case .posted = try host.applyPostOnly(cued) else { return XCTFail("a cue is a post") }
        XCTAssertEqual(try host.applyPostOnly(cued), .unchanged)
        // Silence on lane 0 (not the solo lane), sweep on lane 1.
        let silence = [[Float]](repeating: [Float](repeating: 0, count: 4_096), count: 2)
        var lanes: [[Float]] = [[], []]
        for _ in 0..<4 { let out = try host.processOffline(input: silence, frames: 4_096); lanes[0] += out[0]; lanes[1] += out[1] }
        XCTAssertEqual(lanes[0].map(abs).max() ?? 1, 0, "the other lane plays exact silence")
        XCTAssertGreaterThan(lanes[1].map(abs).max() ?? 0, 0.001, "the solo lane plays the sweep")
        // Removing the generator changes the topology: refused, nothing changes.
        let without = try spec(rate: rate, params: nil)
        XCTAssertThrowsError(try host.applyPostOnly(without)) { XCTAssertEqual($0 as? UnifiedGraphError, .requiresRebuild) }
        XCTAssertEqual(try host.applyPostOnly(cued), .unchanged, "the recorded spec is the cued one still")
    }

    func testTheCuedBlockIsAcceptedAtEveryRateAndAnElevenValueBlockIsNot() throws {
        for rate in rates {
            let s = sweepSettings(rate: rate)
            XCTAssertEqual(s.cuedStageParams(active: true, sampleRate: rate, solo: 1, cue: 5)?.count, 13, "\(rate)")
            XCTAssertEqual(s.stageParams(active: true, sampleRate: rate)?.count, 11)
            var pink = s
            pink.kind = .pink
            XCTAssertNil(pink.cuedStageParams(active: true, sampleRate: rate, solo: 0, cue: 0))
            XCTAssertNil(s.cuedStageParams(active: true, sampleRate: rate, solo: 0, cue: 16_777_217))
        }
    }

    // MARK: Capturer

    @MainActor
    private final class FakeFeed: MIMOProbeStimulusFeeding {
        var probeOutputSampleRate: Double? = 48_000
        var probeStageArmed = false
        var list: [MIMOProbeSource]
        var settings: SignalGeneratorSettings?
        var events: [String] = []
        var cues: [Int] = []
        var armedAtRemoval: Bool?
        var mutedAtRemoval: Bool?
        weak var treatment: MIMOGraphTreatment?
        init(list: [MIMOProbeSource]) { self.list = list }
        func probeSources() -> [MIMOProbeSource] { list }
        func installProbeStimulus(_ settings: SignalGeneratorSettings, programLanes lanes: [Int]) throws {
            self.settings = settings
            events.append("install")
        }
        func cueProbeStimulus(solo: Int) throws { cues.append(solo); events.append("cue\(solo)") }
        func removeProbeStimulus() throws {
            armedAtRemoval = probeStageArmed
            mutedAtRemoval = treatment?.probeProgrammeMuted
            events.append("remove")
        }
    }

    /// Plays the cued sweep through a synthetic room whose direct arrival, recorder offset and clock drift differ per source.
    @MainActor
    private final class FakeRecorder: ProbeMicrophoneRecording {
        let sampleRate: Double
        var render: ((Int) -> [Float])?
        var cuesSeen = 0
        init(rate: Double) { sampleRate = rate }
        func begin() throws {}
        func finish() -> [Float] { render?(cuesSeen) ?? [] }
    }

    private func room(rate: Double, flight: Double) -> n60_measure_room_params {
        var room = n60_measure_room_params()
        n60_measure_room_defaults(rate, &room)
        room.direct_delay_seconds = (flight * rate).rounded() / rate
        room.latency_seconds = 0.037
        room.drift_ppm = 100
        room.noise_dbfs = -90
        room.noise_seed = 3
        room.ir_seconds = 0.4
        room.mode_frequencies_hz = (55, 80, 110, 140)
        room.rt60_seconds = (0.5, 0.5, 0.5, 0.4, 0.4, 0.3, 0.3)
        return room
    }

    private func magnitudes(_ ir: [Float], rate: Double) -> [Double] {
        let centres = [25.0, 31.5, 40, 50, 63, 80, 100, 125, 160]
        return centres.map { fc in
            var acc = 0.0
            let steps = 7
            for k in 0..<steps {
                let f = fc * pow(2.0, (Double(k) / Double(steps - 1) - 0.5) / 3)
                var re = 0.0, im = 0.0
                let w = 2 * Double.pi * f / rate
                for (n, x) in ir.enumerated() { re += Double(x) * cos(w * Double(n)); im -= Double(x) * sin(w * Double(n)) }
                acc += re * re + im * im
            }
            return 10 * log10(acc / Double(steps))
        }
    }

    func testTheCapturerRecoversEachSourcesResponseWithUnknownOffsetAndDriftAtEveryRate() async throws {
        let rig = MIMOGraphTreatment(flags: FeatureFlags())
        for rate in rates {
            let feed = FakeFeed(list: [
                MIMOProbeSource(source: .subwoofer(0), programLane: 0), MIMOProbeSource(source: .subwoofer(1), programLane: 1),
            ])
            feed.probeOutputSampleRate = rate
            feed.treatment = rig
            let recorder = FakeRecorder(rate: rate)
            var cueCount = 0
            let flights = [0.0123, 0.0211]
            let capturer = MIMOTreatmentProbeCapturer(
                treatment: rig, feed: feed, makeRecorder: { recorder },
                seatSweep: { RoomCorrectionSweepSettings(sampleRate: $0) },
                sleep: { _ in
                    // The sleep after a cue is where the recording happens: render the room's response to what was played.
                    if feed.cues.count > cueCount { cueCount = feed.cues.count; recorder.cuesSeen = cueCount }
                })
            try capturer.setProgrammeStopped(true)
            XCTAssertTrue(rig.probeProgrammeMuted)
            let s = try XCTUnwrap(feed.settings)
            let sweep = try MeasurementCore.makeSweep(
                sampleRate: rate, startFrequencyHz: s.lowHz, endFrequencyHz: s.highHz,
                durationSeconds: Double(s.periodFrames) / rate, levelDBFS: 0, fadeSeconds: 0.05, synchronised: true).samples
            let gain = Float(pow(10.0, s.effectiveLevelDB / 20.0) * 2.0.squareRoot())
            recorder.render = { count in
                var params = self.room(rate: rate, flight: flights[(count - 1) % 2])
                let played = sweep.map { $0 * gain }
                var frames: UInt64 = 0
                _ = n60_measure_room_capture_length(&params, UInt64(played.count), &frames)
                var out = [Float](repeating: 0, count: Int(frames))
                var produced: UInt64 = 0
                _ = n60_measure_room_capture(&params, played, UInt64(played.count), &out, frames, &produced)
                return out
            }
            let seat = UUID()
            let result = try await capturer.capture(seatID: seat, treated: false)
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(feed.cues, [1, 2], "one solo sweep per source, in order")
            for (index, measurement) in result.enumerated() {
                var params = room(rate: rate, flight: flights[index])
                var length: UInt64 = 0
                XCTAssertEqual(n60_measure_room_ir_length(&params, &length), N60_MEASURE_OK)
                var reference = [Float](repeating: 0, count: Int(length))
                XCTAssertEqual(n60_measure_room_ir(&params, &reference, length, &length), N60_MEASURE_OK)
                let got = magnitudes(measurement.channel.impulseResponse, rate: rate)
                let want = magnitudes(reference, rate: rate)
                for (band, pair) in zip(got, want).enumerated() {
                    XCTAssertEqual(pair.0, pair.1, accuracy: band == 0 ? 0.2 : 0.1, "\(rate) Hz source \(index) band \(band)")
                }
                XCTAssertEqual(measurement.channel.quality.directArrivalSeconds ?? 0, MIMOTreatmentProbeCapturer.irLeadSeconds,
                               accuracy: 2 / rate)
            }
            try capturer.setProgrammeStopped(false)
            XCTAssertEqual(feed.events.last, "remove")
            XCTAssertEqual(feed.mutedAtRemoval, false, "muted is cleared before the stimulus goes")
        }
    }

    func testTheBudgetRefusesBeforeAnythingIsInstalledAndASourceTheGeneratorCannotReachIsNamed() throws {
        let rig = MIMOGraphTreatment(flags: FeatureFlags())
        let many = (0..<40).map { MIMOProbeSource(source: .subwoofer(UInt32($0)), programLane: $0) }
        let feed = FakeFeed(list: many)
        let capturer = MIMOTreatmentProbeCapturer(
            treatment: rig, feed: feed, makeRecorder: { throw MIMOTreatmentProbeCapturerError.noMicrophone },
            seatSweep: { RoomCorrectionSweepSettings(sampleRate: $0) })
        XCTAssertThrowsError(try capturer.setProgrammeStopped(true)) {
            guard case .budgetExceeded = $0 as? MIMOTreatmentProbeCapturerError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(feed.events.isEmpty)
        XCTAssertFalse(rig.probeProgrammeMuted)
        XCTAssertEqual(MIMOTreatmentProbeCapturer.sweepSeconds(sourceCount: 2), 5)
        XCTAssertEqual(MIMOTreatmentProbeCapturer.sweepSeconds(sourceCount: 20), 4)
        XCTAssertNil(MIMOTreatmentProbeCapturer.sweepSeconds(sourceCount: 34))
        feed.list = [MIMOProbeSource(source: nil, programLane: nil)]
        XCTAssertThrowsError(try capturer.setProgrammeStopped(true)) {
            guard case .sourceNotAddressable = $0 as? MIMOTreatmentProbeCapturerError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(rig.probeProgrammeMuted)
    }

    func testTheCaptureRefusesAMicrophoneAtAnotherRateAndAStageThatDoesNotMatchTheStep() async throws {
        let rig = MIMOGraphTreatment(flags: FeatureFlags())
        let feed = FakeFeed(list: [MIMOProbeSource(source: .subwoofer(0), programLane: 0)])
        let capturer = MIMOTreatmentProbeCapturer(
            treatment: rig, feed: feed, makeRecorder: { FakeRecorder(rate: 44_100) },
            seatSweep: { RoomCorrectionSweepSettings(sampleRate: $0) }, sleep: { _ in })
        await assertThrows(try await capturer.capture(seatID: UUID(), treated: false)) {
            XCTAssertEqual($0 as? MIMOTreatmentProbeCapturerError, .notInstalled)
        }
        try capturer.setProgrammeStopped(true)
        await assertThrows(try await capturer.capture(seatID: UUID(), treated: false)) {
            XCTAssertEqual($0 as? MIMOTreatmentProbeCapturerError, .microphoneRateMismatch(microphone: 44_100, output: 48_000))
        }
        feed.probeStageArmed = true
        await assertThrows(try await capturer.capture(seatID: UUID(), treated: false)) {
            XCTAssertEqual($0 as? MIMOTreatmentProbeCapturerError, .stageArmedMismatch(treated: false))
        }
        XCTAssertTrue(feed.cues.isEmpty, "nothing is played before the checks pass")
    }
}

@MainActor
private func assertThrows<T>(
    _ expression: @autoclosure () async throws -> T, _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch { handler(error) }
}
