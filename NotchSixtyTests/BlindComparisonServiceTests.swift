import XCTest
@testable import NotchSixty

/// E12 S26: the shared comparison service (level matching, blinding, fixed switch time, restore on every exit).
@MainActor
final class BlindComparisonServiceTests: XCTestCase {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    @MainActor
    final class FakeEngine: ComparisonEngine {
        var unavailableReason: String?
        var isSwitching = false
        private(set) var restoreCount = 0
        private(set) var activations: [String] = []
        func restoreApplied() throws { restoreCount += 1 }
        func record(_ name: String) { activations.append(name) }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private func makeService(
        engine: FakeEngine, clock: Clock = Clock(), initialAssignment: Bool = true, hold: TimeInterval = 0.3,
        failB: Bool = false
    ) throws -> BlindComparisonService {
        let level = try ComparisonLevelMatch.make(lanePowersA: [1], lanePowersB: [0.5])
        return try BlindComparisonService(
            engine: engine,
            a: ComparisonSide(name: "Alpha") { engine.record("A") },
            b: ComparisonSide(name: "Beta") {
                if failB { throw RoomCorrectionABXError.unavailable("switch failed") }
                engine.record("B")
            },
            match: level, trialCount: 12, initialAssignment: initialAssignment, nextAssignment: { true },
            switchHold: hold, clock: { clock.now })
    }

    // MARK: Level matching

    func testLouderSideIsTrimmedAndQuieterIsNeverRaised() throws {
        let match = try ComparisonLevelMatch.make(lanePowersA: [4, 4], lanePowersB: [1, 1])
        XCTAssertEqual(match.trimmedSide, .a)
        XCTAssertEqual(match.gainB, 1, accuracy: 1e-15)
        XCTAssertEqual(match.trimADB, -10 * log10(4), accuracy: 1e-9)
        let swapped = try ComparisonLevelMatch.make(lanePowersA: [1, 1], lanePowersB: [4, 4])
        XCTAssertEqual(swapped.trimmedSide, .b)
        XCTAssertEqual(swapped.gainA, 1, accuracy: 1e-15)
        XCTAssertLessThanOrEqual(swapped.gainB, 1)
        XCTAssertNil(try ComparisonLevelMatch.make(lanePowersA: [2], lanePowersB: [2]).trimmedSide)
    }

    /// Reference configurations at every standard rate: a flat gain and a two-tap low-pass, measured again after the
    /// trim by direct DFT, agree within the recorded tolerance (G55).
    func testLevelMatchWithinToleranceAtEightRates() throws {
        for rate in Self.rates {
            let a: [Float] = [1.3]
            let b: [Float] = [0.45, 0.45]
            let powerA = pow(10, RoomCorrectionABXMatch.bandLevelDB(taps: a, sampleRate: rate) / 10)
            let powerB = pow(10, RoomCorrectionABXMatch.bandLevelDB(taps: b, sampleRate: rate) / 10)
            let match = try ComparisonLevelMatch.make(lanePowersA: [powerA], lanePowersB: [powerB])
            let trimmedA = a.map { Float(Double($0) * match.gainA) }
            let trimmedB = b.map { Float(Double($0) * match.gainB) }
            let difference = abs(RoomCorrectionABXMatch.bandLevelDB(taps: trimmedA, sampleRate: rate)
                                 - RoomCorrectionABXMatch.bandLevelDB(taps: trimmedB, sampleRate: rate))
            XCTAssertLessThan(difference, ComparisonLevelMatch.toleranceDB, "rate \(rate)")
            XCTAssertNotNil(match.trimmedSide, "rate \(rate)")
            XCTAssertLessThanOrEqual(max(match.gainA, match.gainB), 1)
            XCTAssertEqual(max(match.gainA, match.gainB), 1, accuracy: 1e-12)
        }
    }

    func testGridCoversTheBandAndMeanPowerOfFlatResponse() {
        let grid = ComparisonLevelMatch.gridFrequencies()
        XCTAssertEqual(grid.first ?? 0, 500, accuracy: 1e-9)
        XCTAssertEqual(grid.last ?? 0, 2_000, accuracy: 1e-6)
        XCTAssertEqual(ComparisonLevelMatch.meanPower(magnitudeDB: [Double](repeating: 6, count: grid.count)),
                       pow(10, 0.6), accuracy: 1e-9)
    }

    func testActiveDynamicsMarksTheMatchApproximate() throws {
        let plain = try ComparisonLevelMatch.make(lanePowersA: [1], lanePowersB: [2])
        XCTAssertFalse(plain.isApproximate)
        XCTAssertFalse(plain.summary.contains("Approximate"))
        let dynamic = try ComparisonLevelMatch.make(lanePowersA: [1], lanePowersB: [2], hasActiveDynamicsB: true)
        XCTAssertTrue(dynamic.isApproximate)
        XCTAssertTrue(dynamic.summary.contains("Approximate"))
    }

    func testInvalidResponsesAreRejected() {
        XCTAssertThrowsError(try ComparisonLevelMatch.make(lanePowersA: [], lanePowersB: []))
        XCTAssertThrowsError(try ComparisonLevelMatch.make(lanePowersA: [1], lanePowersB: [1, 1]))
        XCTAssertThrowsError(try ComparisonLevelMatch.make(lanePowersA: [0], lanePowersB: [1]))
        XCTAssertThrowsError(try ComparisonLevelMatch.make(lanePowersA: [.nan], lanePowersB: [1]))
    }

    func testRemainingDifferenceIsTheWorstLaneAfterTheGlobalTrim() throws {
        // Lane 0 differs by 3 dB and lane 1 by 1 dB in the other direction.
        let a = [pow(10, 0.3), 1.0]
        let b = [1.0, pow(10, 0.1)]
        let match = try ComparisonLevelMatch.make(lanePowersA: a, lanePowersB: b)
        XCTAssertGreaterThan(match.remainingDifferenceDB, 0.5)
        XCTAssertLessThan(match.remainingDifferenceDB, 3.0)
    }

    // MARK: Blinding

    /// X's identity never appears in published state: two runs that differ only in the hidden assignment publish the
    /// same values at every step.
    func testPublishedStateDoesNotRevealX() throws {
        func snapshot(_ s: BlindComparisonService) -> String {
            "\(String(describing: s.selection)) \(s.phase) \(s.completedTrials) \(s.heardX) \(String(describing: s.message)) \(s.isSwitching) \(s.canAnswer) \(s.currentTrialNumber) \(String(describing: s.revealedNames?.a))"
        }
        var snapshots: [[String]] = []
        for assignment in [true, false] {
            let engine = FakeEngine()
            let s = try makeService(engine: engine, initialAssignment: assignment, hold: 0)
            var seen = [snapshot(s)]
            s.select(.x); seen.append(snapshot(s))
            s.answer(xIsB: true); seen.append(snapshot(s))
            s.select(.a); seen.append(snapshot(s))
            snapshots.append(seen)
        }
        XCTAssertEqual(snapshots[0], snapshots[1])
    }

    func testXPlaysTheHiddenSideAndAnswerNeedsX() throws {
        let engine = FakeEngine()
        let s = try makeService(engine: engine, initialAssignment: true, hold: 0)
        s.answer(xIsB: true)
        XCTAssertEqual(s.completedTrials, 0)
        XCTAssertEqual(s.message, "Listen to X before answering.")
        s.select(.x)
        XCTAssertEqual(engine.activations, ["B"])
        XCTAssertTrue(s.heardX)
        s.answer(xIsB: true)
        XCTAssertEqual(s.completedTrials, 1)
    }

    func testNamesStayHiddenUntilFinished() throws {
        let engine = FakeEngine()
        let s = try makeService(engine: engine, hold: 0)
        for _ in 0..<12 { s.select(.x); s.answer(xIsB: true) }
        XCTAssertEqual(s.phase, .askingPreference)
        XCTAssertNil(s.revealedNames)
        s.finish()
        XCTAssertEqual(s.revealedNames?.a, "Alpha")
        XCTAssertEqual(s.revealedNames?.b, "Beta")
    }

    // MARK: Switching

    /// A switch takes the same fixed time whichever way it goes, and the core's own busy state still blocks.
    func testSwitchTimeIsFixedInEitherDirection() throws {
        for first in [BlindComparisonService.Selection.a, .b] {
            let engine = FakeEngine()
            let clock = Clock()
            let s = try makeService(engine: engine, clock: clock)
            let second: BlindComparisonService.Selection = first == .a ? .b : .a
            s.select(first)
            XCTAssertTrue(s.isSwitching)
            s.select(second)
            XCTAssertEqual(engine.activations.count, 1, "refused during the hold")
            clock.now.addTimeInterval(ComparisonSwitchTiming.fixedSeconds - 0.01)
            s.select(second)
            XCTAssertEqual(engine.activations.count, 1, "still held just before the fixed time")
            clock.now.addTimeInterval(0.02)
            s.select(second)
            XCTAssertEqual(engine.activations.count, 2, "allowed at the fixed time")
        }
    }

    func testCoreBusyBlocksEvenAfterTheHold() throws {
        let engine = FakeEngine()
        let clock = Clock()
        let s = try makeService(engine: engine, clock: clock)
        engine.isSwitching = true
        s.select(.a)
        XCTAssertTrue(engine.activations.isEmpty)
        engine.isSwitching = false
        s.select(.a)
        XCTAssertEqual(engine.activations, ["A"])
    }

    func testFailedSwitchDoesNotCountXAsHeard() throws {
        let engine = FakeEngine()
        let s = try makeService(engine: engine, initialAssignment: true, hold: 0, failB: true)
        s.select(.x)
        XCTAssertFalse(s.heardX)
        XCTAssertNil(s.selection)
        XCTAssertEqual(s.message, "switch failed")
    }

    // MARK: Restore on every exit path

    func testCloseRestoresTheAppliedConfiguration() throws {
        let engine = FakeEngine()
        let s = try makeService(engine: engine, hold: 0)
        s.select(.a)
        s.close()
        XCTAssertEqual(engine.restoreCount, 1)
    }

    func testStopReconfigurationAndDeviceLossEndTheRunAndRestore() throws {
        for reason in ["Start playback with music to compare by ear.", "The output changed.", "The output device is gone."] {
            let engine = FakeEngine()
            let s = try makeService(engine: engine, hold: 0)
            s.select(.a)
            engine.unavailableReason = reason
            s.refreshReadiness()
            XCTAssertEqual(s.phase, .ended(reason))
            XCTAssertNil(s.selection)
            XCTAssertEqual(engine.restoreCount, 1)
            s.select(.b)
            XCTAssertEqual(engine.activations, ["A"], "an ended run never plays again")
            s.close()
            XCTAssertEqual(engine.restoreCount, 1, "no second restore once ended")
        }
    }

    func testAnUnavailableEngineIsNeverStartedByTheComparison() throws {
        let engine = FakeEngine()
        engine.unavailableReason = "Start playback with music to compare by ear."
        let s = try makeService(engine: engine, hold: 0)
        s.refreshReadiness()
        XCTAssertTrue(engine.activations.isEmpty)
        XCTAssertEqual(engine.restoreCount, 1)
    }

    func testFinishedRunIsNotEndedByALaterStop() throws {
        let engine = FakeEngine()
        let s = try makeService(engine: engine, hold: 0)
        for _ in 0..<12 { s.select(.x); s.answer(xIsB: true) }
        s.finish()
        engine.unavailableReason = "stopped"
        s.refreshReadiness()
        XCTAssertEqual(s.phase, .finished)
    }
}
