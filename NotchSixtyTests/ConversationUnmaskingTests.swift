import XCTest
@testable import NotchSixty

/// E4 S30: speech detection, SII planning and Lombard bounds. Control-plane maths on envelopes and band levels,
/// so the eight standard device rates only change the envelope extraction, which is tested at each of them.
final class ConversationUnmaskingTests: XCTestCase {
    private let n = SpeechIntelligibilityBands.centersHz.count

    func testImportanceSumsToOne() {
        XCTAssertEqual(SpeechIntelligibilityBands.importance.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(SpeechIntelligibilityBands.importance.count, n)
    }

    private func envelope(modHz: Double, depth: Double, seconds: Double = 4) -> [Double] {
        (0..<Int(seconds * 100)).map { 1 + depth * sin(2 * .pi * modHz * Double($0) / 100) }
    }

    func testSyllableRateModulationIsSpeechLike() {
        XCTAssertGreaterThan(SpeechModulationDetector.confidence(envelope: envelope(modHz: 4, depth: 0.7)), 0.8)
    }

    func testSteadyAndSlowOrFastModulationAreNotSpeech() {
        XCTAssertEqual(SpeechModulationDetector.confidence(envelope: [Double](repeating: 1, count: 400)), 0, accuracy: 1e-9)
        XCTAssertLessThan(SpeechModulationDetector.confidence(envelope: envelope(modHz: 0.7, depth: 0.7)), 0.2)
        XCTAssertLessThan(SpeechModulationDetector.confidence(envelope: envelope(modHz: 20, depth: 0.7)), 0.2)
        XCTAssertEqual(SpeechModulationDetector.confidence(envelope: envelope(modHz: 4, depth: 0.7, seconds: 1)), 0)
    }

    func testEnvelopeAtEveryStandardRate() {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let count = Int(rate * 3)
            let samples = (0..<count).map { i -> Float in
                let t = Double(i) / rate
                return Float((1 + 0.7 * sin(2 * .pi * 4 * t)) * sin(2 * .pi * 1_000 * t))
            }
            let env = SpeechModulationDetector.envelope(samples: samples, sampleRate: rate)
            XCTAssertEqual(env.count, 300, "rate \(rate)")
            XCTAssertGreaterThan(SpeechModulationDetector.confidence(envelope: env), 0.6, "rate \(rate)")
        }
    }

    private func input(snr: Double, confidence: Double = 1) -> ConversationUnmaskingInput {
        ConversationUnmaskingInput(
            speechBandLevelsDB: [Double](repeating: 50, count: n),
            musicBandLevelsDB: [Double](repeating: 50 - snr, count: n),
            lowMusicLevelDB: 70,
            speechConfidence: confidence
        )
    }

    func testSIIRisesAndLimitsHold() throws {
        let planner = ConversationUnmaskingPlanner()
        let plan = try XCTUnwrap(planner.plan(input(snr: -6)))
        XCTAssertGreaterThan(plan.siiAfter, plan.siiBefore + 0.02)
        XCTAssertTrue(plan.bandCutsDB.allSatisfy { $0 >= 0 && $0 <= 6 + 1e-9 })
        XCTAssertGreaterThanOrEqual(plan.overallChangeDB, -3 - 1e-6)
        XCTAssertLessThan(plan.overallChangeDB, 0)
    }

    func testCutsFavourImportantBandsAndNoCutBelowFloor() throws {
        var planner = ConversationUnmaskingPlanner()
        planner.configuration.maximumOverallCutDB = 0.4
        let plan = try XCTUnwrap(planner.plan(input(snr: -6)))
        let cut = plan.bandCutsDB
        let iBest = SpeechIntelligibilityBands.importance.enumerated().max { $0.element < $1.element }!.offset
        XCTAssertGreaterThan(cut[iBest], cut[0])
        planner.configuration.untouchedBelowHz = 1_000_000
        XCTAssertEqual(try XCTUnwrap(planner.plan(input(snr: -6))).bandCutsDB.reduce(0, +), 0)
    }

    func testNoSpeechNoCutAndAlreadyAudibleNoCut() throws {
        let planner = ConversationUnmaskingPlanner()
        XCTAssertEqual(try XCTUnwrap(planner.plan(input(snr: -6, confidence: 0.2))).bandCutsDB.reduce(0, +), 0)
        XCTAssertEqual(try XCTUnwrap(planner.plan(input(snr: 20))).bandCutsDB.reduce(0, +), 0)
        var bad = input(snr: 0)
        bad.musicBandLevelsDB[3] = .nan
        XCTAssertNil(planner.plan(bad))
    }

    func testLombardLoopStaysBounded() throws {
        // Talkers raise their voice as music rises and relax as it is cut; the plan never exceeds its caps and
        // moves no faster than the rate limits.
        let planner = ConversationUnmaskingPlanner()
        var applied = [Double](repeating: 0, count: n)
        var speech = 50.0
        for _ in 0..<200 {
            var inp = input(snr: -3)
            let totalCut = applied.reduce(0, +) / Double(n)
            speech = 50 + max(0, 6 - totalCut)
            inp.speechBandLevelsDB = [Double](repeating: speech, count: n)
            let target = try XCTUnwrap(planner.plan(inp)).bandCutsDB
            let next = planner.rateLimited(previous: applied, target: target)
            for i in 0..<n {
                XCTAssertLessThanOrEqual(next[i] - applied[i], 1.0 + 1e-9)
                XCTAssertGreaterThanOrEqual(next[i] - applied[i], -0.25 - 1e-9)
                XCTAssertLessThanOrEqual(next[i], 6 + 1e-9)
            }
            applied = next
        }
    }

    func testFlagRegistered() {
        XCTAssertTrue(FeatureFlag.all.contains(.conversationUnmasking))
        XCTAssertFalse(FeatureFlag.conversationUnmasking.defaultEnabled)
    }
}
