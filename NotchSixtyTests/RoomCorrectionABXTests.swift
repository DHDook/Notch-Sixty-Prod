import XCTest
@testable import NotchSixty

final class RoomCorrectionABXTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func candidates() -> (RoomCorrectionABXCandidate, RoomCorrectionABXCandidate) {
        var a = [Float](repeating: 0, count: 64); a[0] = 1.0; a[5] = 0.2
        var b = [Float](repeating: 0, count: 96); b[10] = 0.6; b[20] = -0.1
        return (RoomCorrectionABXCandidate(name: "Minimum phase", taps: a, latencyFrames: 0),
                RoomCorrectionABXCandidate(name: "Mixed phase", taps: b, latencyFrames: 10))
    }

    func testLevelAndLatencyMatchingIsExactAtAllRates() throws {
        let (a, b) = candidates()
        for rate in rates {
            let m = try RoomCorrectionABXMatch.make(a: a, b: b, sampleRate: rate)
            let la = RoomCorrectionABXMatch.bandLevelDB(taps: m.matchedTaps(a, isA: true), sampleRate: rate)
            let lb = RoomCorrectionABXMatch.bandLevelDB(taps: m.matchedTaps(b, isA: false), sampleRate: rate)
            // Pure delay does not change magnitude, so the levels match to rounding.
            XCTAssertEqual(la, lb, accuracy: 0.01, "rate \(rate)")
            XCTAssertLessThan(abs(la - lb), RoomCorrectionABXMatch.toleranceDB)
            XCTAssertLessThanOrEqual(m.gainA, 1)
            XCTAssertLessThanOrEqual(m.gainB, 1)
            XCTAssertEqual(m.delayA, 10)
            XCTAssertEqual(m.delayB, 0)
            XCTAssertEqual(a.latencyFrames + m.delayA, b.latencyFrames + m.delayB)
        }
    }

    func testMatchingRejectsBadInput() {
        let (a, b) = candidates()
        var bad = b; bad.taps[3] = .nan
        XCTAssertThrowsError(try RoomCorrectionABXMatch.make(a: a, b: bad, sampleRate: 48_000))
        XCTAssertThrowsError(try RoomCorrectionABXMatch.make(a: a, b: b, sampleRate: 400_000))
        var silent = b; silent.taps = [Float](repeating: 0, count: 8)
        XCTAssertThrowsError(try RoomCorrectionABXMatch.make(a: a, b: silent, sampleRate: 48_000))
    }

    func testBinomialPValuesMatchReferenceTable() {
        // Exact one-sided P(X >= k | n, 0.5), from the standard binomial table.
        let table: [(Int, Int, Double)] = [
            (16, 16, 1.0 / 65_536.0), (15, 16, 17.0 / 65_536.0), (13, 16, 697.0 / 65_536.0),
            (12, 16, 2_517.0 / 65_536.0), (11, 16, 6_885.0 / 65_536.0),
            (8, 16, 39_203.0 / 65_536.0), (10, 12, 79.0 / 4_096.0), (0, 12, 1.0)
        ]
        for (k, n, expected) in table {
            XCTAssertEqual(BlindABXSession.exactOneSidedPValue(correct: k, total: n) ?? -1,
                           expected, accuracy: 1e-12, "\(k)/\(n)")
        }
    }

    func testTrialLogRoundTripAndGate() throws {
        let (a, b) = candidates()
        let match = try RoomCorrectionABXMatch.make(a: a, b: b, sampleRate: 48_000)
        var session = try BlindABXSession(trialCount: 12, initialAssignment: true)
        for i in 0..<12 {
            try session.recordXPlayback()
            // Answer correctly for the first 11 trials.
            let hidden = session.currentHiddenXWasB
            try session.submit(i < 11 ? hidden : !hidden, nextAssignment: i % 2 == 0)
        }
        let log = try RoomCorrectionABXLog(session: session, match: match, a: a, b: b,
                                           seatCount: 3, date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(log.correctCount, 11)
        XCTAssertTrue(log.passesGateG3)
        XCTAssertLessThan(log.levelMatchResidualDB, 0.01)
        XCTAssertEqual(log.latencyFramesMatched, 10)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try log.write(to: dir)
        XCTAssertEqual(try RoomCorrectionABXLog.read(from: url), log)
        var twoSeat = log; twoSeat.seatCount = 2
        XCTAssertFalse(twoSeat.passesGateG3)
    }

    func testIncompleteSessionCannotBeLogged() throws {
        let (a, b) = candidates()
        let match = try RoomCorrectionABXMatch.make(a: a, b: b, sampleRate: 48_000)
        let session = try BlindABXSession(trialCount: 12)
        XCTAssertThrowsError(try RoomCorrectionABXLog(session: session, match: match, a: a, b: b, seatCount: 3))
    }
}
