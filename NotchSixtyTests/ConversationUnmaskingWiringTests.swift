import XCTest
@testable import NotchSixty

/// E4 S30c: governor limits, card model, analysis-window scaling (G4), engine validation and the trailer at every rate.
@MainActor
final class ConversationUnmaskingWiringTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let n = SpeechIntelligibilityBands.centersHz.count

    private func input(confidence: Double = 0.9) -> ConversationUnmaskingInput {
        ConversationUnmaskingInput(
            speechBandLevelsDB: [Double](repeating: 55, count: n),
            musicBandLevelsDB: [Double](repeating: 62, count: n),
            lowMusicLevelDB: 60, speechConfidence: confidence)
    }

    private func planned(_ cuts: [Double]) -> ConversationUnmaskingEvaluation {
        ConversationUnmaskingEvaluation(
            status: .planned(ConversationUnmaskingPlan(
                bandCutsDB: cuts, siiBefore: 0.4, siiAfter: 0.5, overallChangeDB: -1)),
            speechConfidence: 0.9, input: input())
    }

    private func fallback(_ reason: ConversationUnmaskingFallback) -> ConversationUnmaskingEvaluation {
        ConversationUnmaskingEvaluation(status: .fallback(reason), speechConfidence: 0.2, input: nil)
    }

    func testAttackIsLimitedToOneDBPerPollAndNeverPastSix() {
        var g = ConversationUnmaskingGovernor()
        let target = [Double](repeating: 6, count: n)
        var cuts = g.update(evaluation: planned(target), elapsedSeconds: 0.25)
        XCTAssertEqual(cuts.max() ?? 0, 1.0, accuracy: 1e-9)
        for _ in 0..<40 { cuts = g.update(evaluation: planned(target), elapsedSeconds: 0.25) }
        XCTAssertLessThanOrEqual(cuts.max() ?? 0, 6.0 + 1e-9)
    }

    func testReleaseIsSlowerThanAttack() {
        var g = ConversationUnmaskingGovernor()
        let target = [Double](repeating: 3, count: n)
        for _ in 0..<6 { _ = g.update(evaluation: planned(target), elapsedSeconds: 0.25) }
        let before = g.cutsDB[8]
        let after = g.update(evaluation: fallback(.lowSeparationConfidence), elapsedSeconds: 0.25)[8]
        XCTAssertEqual(before - after, 0.25, accuracy: 1e-9)
    }

    func testStepsScaleWithElapsedTime() {
        var g = ConversationUnmaskingGovernor()
        let cuts = g.update(evaluation: planned([Double](repeating: 6, count: n)), elapsedSeconds: 0.5)
        XCTAssertEqual(cuts.max() ?? 0, 2.0, accuracy: 1e-9)
    }

    func testStaleAnalysisHoldsThenReleases() {
        var g = ConversationUnmaskingGovernor()
        for _ in 0..<4 { _ = g.update(evaluation: planned([Double](repeating: 2, count: n)), elapsedSeconds: 0.25) }
        let held = g.cutsDB
        for _ in 0..<7 { XCTAssertEqual(g.noAnalysis(elapsedSeconds: 0.25), held) }
        let released = g.noAnalysis(elapsedSeconds: 0.25)
        XCTAssertLessThan(released.max() ?? 0, held.max() ?? 0)
    }

    func testFlagOffAndResetClearAtOnce() {
        var g = ConversationUnmaskingGovernor()
        for _ in 0..<3 { _ = g.update(evaluation: planned([Double](repeating: 2, count: n)), elapsedSeconds: 0.25) }
        XCTAssertTrue(g.isEngaged)
        XCTAssertEqual(g.update(evaluation: nil, elapsedSeconds: 0.25), [Double](repeating: 0, count: n))
        XCTAssertFalse(g.isEngaged)
    }

    func testOverallProgrammeChangeStaysInsideThreeDBWhileMoving() {
        var g = ConversationUnmaskingGovernor()
        let planner = g.planner
        let inp = input()
        let target = [Double](repeating: 6, count: n)
        for _ in 0..<40 {
            let cuts = g.update(evaluation: planned(target), elapsedSeconds: 0.25)
            XCTAssertLessThanOrEqual(-planner.overallChangeDB(inp, cuts: cuts), 3.0 + 1e-3)
        }
    }

    func testTrailerAndCardAreValidAtEveryRate() throws {
        let cuts: [Double] = [0, 0, 0.5, 1.5, 2.5, 3.5, 4.5, 4.5, 4, 3.5, 2.5, 1.5, 1, 0.5, 0, 0, 0]
        for rate in Self.rates {
            let params = try XCTUnwrap(AmbientUnmaskOverlay.stageParameters(base: nil, plannedCutsDB: cuts, sampleRate: rate))
            XCTAssertEqual(params.count, 10 + 1 + 3 * 17, "rate \(rate)")
            XCTAssertEqual(params[10], 17)
            let card = ConversationUnmaskingCardModel(evaluation: planned(cuts), appliedCutsDB: cuts, sampleRate: rate)
            XCTAssertEqual(card.cutBandCount, cuts.filter { $0 > 0.05 }.count)
            XCTAssertFalse(card.curve.isEmpty, "rate \(rate)")
            XCTAssertNil(card.fallbackReason)
            XCTAssertTrue(card.curve.allSatisfy { $0.gainDB <= 1e-6 })
        }
    }

    func testCardExplainsEveryFallback() {
        let reasons: [ConversationUnmaskingFallback] = [
            .notConversationFocus, .notPlaying, .lowSeparationConfidence, .noPlaybackModel, .noBaseline,
            .incompleteSpectrum, .invalidAppliedCuts, .shortEnvelope]
        for reason in reasons {
            let card = ConversationUnmaskingCardModel(
                evaluation: fallback(reason), appliedCutsDB: [], sampleRate: 48_000)
            XCTAssertFalse(card.fallbackReason?.isEmpty ?? true)
            XCTAssertNil(card.siiAfter)
            XCTAssertTrue(card.curve.isEmpty)
        }
    }

    func testCardHoldsNumbersOnlyNoAudio() {
        let card = ConversationUnmaskingCardModel(
            evaluation: planned([Double](repeating: 1, count: n)), appliedCutsDB: [Double](repeating: 1, count: n),
            sampleRate: 48_000)
        for child in Mirror(reflecting: card).children {
            XCTAssertFalse(child.value is [Float], "card must not hold sample data: \(child.label ?? "")")
        }
    }

    func testAnalysisWindowAndReadLimitCoverAPollAtEveryRate() {
        for rate in Self.rates {
            let poll = Int(rate * 0.25)
            XCTAssertGreaterThanOrEqual(AmbientCompensationController.analysisFrames(sampleRate: rate), poll, "rate \(rate)")
            XCTAssertGreaterThanOrEqual(AmbientCompensationController.readLimitFrames(sampleRate: rate), poll, "rate \(rate)")
            XCTAssertLessThanOrEqual(
                AmbientCompensationController.analysisFrames(sampleRate: rate),
                AmbientCompensationController.maximumHistoryFrames)
        }
        XCTAssertEqual(AmbientCompensationController.analysisFrames(sampleRate: 44_100), 32_768)
    }

    func testEngineRejectsCutsItCannotRealise() {
        let engine = AudioIOEngine()
        var target = AmbientCompensationTarget.unity
        target.mode = .conversationFocus
        target.unmaskingCutsDB = [Double](repeating: 1, count: n)
        // No running graph session: the legacy kernel cannot realise cuts.
        XCTAssertThrowsError(try engine.replaceAmbientCompensationRuntimeTarget(target))
        target.mode = .musicFocus
        XCTAssertThrowsError(try engine.replaceAmbientCompensationRuntimeTarget(target))
        target.mode = .conversationFocus
        target.unmaskingCutsDB = [Double](repeating: 7, count: n)
        XCTAssertThrowsError(try engine.replaceAmbientCompensationRuntimeTarget(target))
        target.unmaskingCutsDB = [1, 2]
        XCTAssertThrowsError(try engine.replaceAmbientCompensationRuntimeTarget(target))
    }
}
