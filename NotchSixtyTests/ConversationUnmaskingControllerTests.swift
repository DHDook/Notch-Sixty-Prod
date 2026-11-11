import XCTest
@testable import NotchSixty

/// E4 S30d (G13, G14): the production controller's cut path with a fake analyser (the evaluation a poll would produce),
/// through the governor, the target it sends and the offline unified graph, at every standard rate.
@MainActor
final class ConversationUnmaskingControllerTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let n = SpeechIntelligibilityBands.centersHz.count
    private let block = 512

    private func makeController(flag: Bool = true, available: Bool = true) throws -> AmbientCompensationController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        let calibration = RoomCorrectionCalibrationController(engine: engine)
        let projects = RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("rc", isDirectory: true)))
        let controller = AmbientCompensationController(
            engine: engine, profiles: profiles, microphone: calibration, projects: projects)
        var configuration = AmbientCompensationConfiguration()
        configuration.playbackAdaptationMode = .conversationFocus
        controller.installConfigurationForTesting(configuration)
        controller.unmaskingInputsEnabled = flag
        controller.unmaskingRuntimeAvailableProvider = { available }
        return controller
    }

    /// What the analyser would report for speech 10 dB under the music in the speech bands.
    private func input(speechBoostDB: Double = 0) -> ConversationUnmaskingInput {
        ConversationUnmaskingInput(
            speechBandLevelsDB: [Double](repeating: 52 + speechBoostDB, count: n),
            musicBandLevelsDB: [Double](repeating: 62, count: n),
            lowMusicLevelDB: 60, speechConfidence: 0.9)
    }

    private func evaluation(_ input: ConversationUnmaskingInput) throws -> ConversationUnmaskingEvaluation {
        let plan = try XCTUnwrap(ConversationUnmaskingPlanner().plan(input))
        return ConversationUnmaskingEvaluation(status: .planned(plan), speechConfidence: 0.9, input: input)
    }

    private func fallbackEvaluation() -> ConversationUnmaskingEvaluation {
        ConversationUnmaskingEvaluation(status: .fallback(.lowSeparationConfidence), speechConfidence: 0.1, input: nil)
    }

    /// One poll's tail: the cuts the controller puts on the target, and its record that the engine took them.
    private func poll(_ controller: AmbientCompensationController, _ evaluation: ConversationUnmaskingEvaluation?)
        -> AmbientCompensationTarget
    {
        var target = AmbientCompensationTarget.unity
        target.mode = .conversationFocus
        controller.setUnmaskingEvaluationForTesting(evaluation)
        controller.attachUnmaskingCuts(to: &target, mode: .conversationFocus, freshAnalysis: true)
        controller.unmaskingCutsWereSent(target)
        return target
    }

    // MARK: Graph

    private func spec(_ params: [Float], rate: Double) throws -> UnifiedGraphSpec {
        var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
        var configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        configuration.stereoStages.ambient = params
        return try configuration.makeSpec()
    }

    /// Level change in dB of a tone at `hz` through the stage with these cuts.
    private func toneGainDB(cuts: [Double], hz: Double, rate: Double) throws -> Double {
        let params = try XCTUnwrap(AmbientUnmaskOverlay.stageParameters(base: nil, plannedCutsDB: cuts, sampleRate: rate))
        let host = try UnifiedGraphHost(spec: spec(params, rate: rate))
        defer { host.release() }
        let frames = Int(rate * 0.4) / block * block
        let tone = (0..<frames).map { Float(0.25 * sin(2 * .pi * hz * Double($0) / rate)) }
        var out: [Float] = []
        var position = 0
        while position + block <= frames {
            let chunk = [Array(tone[position..<position + block]), Array(tone[position..<position + block])]
            out += try host.processOffline(input: chunk, frames: block)[0]
            position += block
        }
        func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)) }
        let start = frames * 3 / 4
        return 20 * log10(rms(out[start...]) / rms(tone[start...]))
    }

    func testSIIRisesAndOutputIsLoweredOnlyInTheCutBandsAtEveryRate() throws {
        let e = try evaluation(input())
        guard case .planned(let plan) = e.status else { return XCTFail("no plan") }
        XCTAssertGreaterThan(plan.siiAfter, plan.siiBefore)
        for rate in Self.rates {
            let controller = try makeController()
            var cuts: [Double] = []
            for i in 0..<14 {
                let target = poll(controller, e)
                cuts = try XCTUnwrap(target.unmaskingCutsDB, "poll \(i) at \(rate)")
                XCTAssertEqual(target.mode, .conversationFocus)
                XCTAssertEqual(target.levelDB, 0)
                if i == 0 { XCTAssertEqual(cuts.max() ?? 0, 1.0, accuracy: 1e-9, "attack is 1 dB per poll") }
            }
            XCTAssertEqual(controller.unmaskingAppliedCutsDB, cuts)
            XCTAssertGreaterThan(cuts.max() ?? 0, 2.5, "\(rate)")
            XCTAssertLessThanOrEqual(cuts.max() ?? 0, 6 + 1e-9)
            XCTAssertTrue(zip(cuts, SpeechIntelligibilityBands.centersHz).allSatisfy { $1 >= 150 || $0 == 0 }, "nothing below 150 Hz")
            let cutBand = try XCTUnwrap(cuts.indices.max { cuts[$0] < cuts[$1] })
            let centre = SpeechIntelligibilityBands.centersHz[cutBand]
            XCTAssertLessThan(try toneGainDB(cuts: cuts, hz: centre, rate: rate), -1.0, "cut band \(centre) Hz at \(rate)")
            XCTAssertGreaterThan(try toneGainDB(cuts: cuts, hz: 60, rate: rate), -0.3, "bass untouched at \(rate)")
        }
    }

    func testSpeechStoppingReleasesAtNoMoreThanOneDBPerSecondAtEveryRate() throws {
        let e = try evaluation(input())
        for rate in Self.rates {
            let controller = try makeController()
            for _ in 0..<12 { _ = poll(controller, e) }
            var previous = controller.unmaskingAppliedCutsDB
            XCTAssertGreaterThan(previous.max() ?? 0, 0, "\(rate)")
            var polls = 0
            while (previous.max() ?? 0) > 0 && polls < 80 {
                let target = poll(controller, fallbackEvaluation())
                let now = target.unmaskingCutsDB ?? [Double](repeating: 0, count: n)
                for i in 0..<n {
                    XCTAssertLessThanOrEqual(previous[i] - now[i], 0.25 + 1e-9, "1 dB/s at the 250 ms poll, \(rate)")
                    XCTAssertGreaterThanOrEqual(previous[i] - now[i], -1e-9, "release never re-raises")
                }
                previous = now
                polls += 1
            }
            XCTAssertEqual(previous.max() ?? 0, 0, accuracy: 1e-9, "released at \(rate)")
        }
    }

    func testLombardSpeechRisingWithEachCutStaysWithinSixPerBandAndThreeOverall() throws {
        let planner = ConversationUnmaskingPlanner()
        let controller = try makeController()
        for step in 0..<80 {
            // The talker raises their voice by half of the mean applied cut (add-back keeps the music at its true level).
            let applied = controller.unmaskingAppliedCutsDB
            let boost = 0.5 * applied.reduce(0, +) / Double(n)
            let inp = input(speechBoostDB: boost)
            let target = poll(controller, try evaluation(inp))
            let cuts = target.unmaskingCutsDB ?? [Double](repeating: 0, count: n)
            XCTAssertLessThanOrEqual(cuts.max() ?? 0, 6 + 1e-9, "step \(step)")
            XCTAssertLessThanOrEqual(-planner.overallChangeDB(inp, cuts: cuts), 3.0 + 1e-3, "step \(step)")
        }
    }

    func testFlagOffSendsNoCutsAndClearsTheGovernorAtOnce() throws {
        let e = try evaluation(input())
        let controller = try makeController()
        for _ in 0..<6 { _ = poll(controller, e) }
        XCTAssertGreaterThan(controller.unmaskingAppliedCutsDB.max() ?? 0, 0)
        controller.unmaskingInputsEnabled = false
        let target = poll(controller, e)
        XCTAssertNil(target.unmaskingCutsDB)
        XCTAssertEqual(target.mode, .conversationFocus)
        XCTAssertEqual(controller.unmaskingAppliedCutsDB, [Double](repeating: 0, count: n))
        controller.unmaskingInputsEnabled = true
        XCTAssertEqual(poll(controller, e).unmaskingCutsDB?.max() ?? 0, 1.0, accuracy: 1e-9, "restarts from zero")
    }

    func testLegacyKernelGetsTodaysTargetWithNoCuts() throws {
        let e = try evaluation(input())
        let controller = try makeController(available: false)
        let before = AmbientCompensationTarget.unity
        var target = before
        target.mode = .conversationFocus
        let reference = target
        controller.setUnmaskingEvaluationForTesting(e)
        controller.attachUnmaskingCuts(to: &target, mode: .conversationFocus, freshAnalysis: true)
        XCTAssertEqual(target, reference, "the target is untouched when the graph cannot realise cuts")
        XCTAssertNil(target.unmaskingCutsDB)
    }

    func testATransportTeardownClearsTheCutsAndTheControllerRestarts() throws {
        let e = try evaluation(input())
        for cause in [TransportTeardownCause.reconfiguration, .stop, .outputLost, .sleep, .quit] {
            let controller = try makeController()
            for _ in 0..<8 { _ = poll(controller, e) }
            XCTAssertGreaterThan(controller.unmaskingAppliedCutsDB.max() ?? 0, 3)
            controller.engine.notifyTransportTeardown(cause)
            XCTAssertEqual(controller.unmaskingAppliedCutsDB, [Double](repeating: 0, count: n), "\(cause)")
            XCTAssertNil(controller.latestUnmasking)
            XCTAssertEqual(poll(controller, e).unmaskingCutsDB?.max() ?? 0, 1.0, accuracy: 1e-9, "\(cause): attack restarts")
        }
    }

    func testEngineReadsTheGraphFallbackUnderItsLock() {
        // No session: the locked accessor is not reachable and the engine reports no runtime for cuts.
        XCTAssertFalse(AudioIOEngine().ambientUnmaskingRuntimeAvailable)
    }
}
