import Foundation
import XCTest
@testable import NotchSixty

final class BlindABXValidationTests: XCTestCase {
    func testABXKeepsXHiddenUntilCompletionAndRefusesEarlyExport() throws {
        var trial = try BlindABXSession(trialCount: 12, initialAssignment: true)
        XCTAssertFalse(trial.maySubmitChoice)
        XCTAssertThrowsError(try trial.submit(true)) {
            XCTAssertEqual($0 as? BlindABXError, .invalidTrial)
        }
        XCTAssertThrowsError(try trial.exportEvidence()) {
            XCTAssertEqual($0 as? BlindABXError, .incompleteSession)
        }
        for index in 0..<12 {
            try trial.recordXPlayback()
            XCTAssertTrue(trial.maySubmitChoice)
            try trial.submit(index == 0, nextAssignment: false)
            XCTAssertFalse(trial.maySubmitChoice)
        }
        XCTAssertTrue(trial.isComplete)
        XCTAssertEqual(trial.completedTrials.count, 12)
        let evidence = try trial.exportEvidence()
        XCTAssertEqual(evidence.correctCount, 12)
        XCTAssertEqual(evidence.oneSidedExactPValue, 1.0 / 4096, accuracy: 1e-12)
        XCTAssertFalse(evidence.physicalAcceptanceComplete)
        XCTAssertFalse(evidence.releaseAcceptanceComplete)
        XCTAssertFalse(evidence.liveFeedForwardANCAuthorized)
        XCTAssertFalse(evidence.mayMergeIntoMain)
        XCTAssertThrowsError(try trial.recordXPlayback())
        XCTAssertThrowsError(try trial.submit(false))
    }

    func testExactBinomialTailCalculationsAndCounts() throws {
        XCTAssertEqual(
            BlindABXSession.exactOneSidedPValue(correct: 12, total: 16)!,
            2517.0 / 65536.0, accuracy: 1e-12
        )
        XCTAssertEqual(
            BlindABXSession.exactOneSidedPValue(correct: 0, total: 16)!,
            1, accuracy: 1e-12
        )
        XCTAssertEqual(
            BlindABXSession.exactOneSidedPValue(correct: 16, total: 16)!,
            1.0 / 65536.0, accuracy: 1e-12
        )
        XCTAssertNil(BlindABXSession.exactOneSidedPValue(correct: -1, total: 16))
        XCTAssertNil(BlindABXSession.exactOneSidedPValue(correct: 17, total: 16))
        XCTAssertThrowsError(try BlindABXSession(trialCount: 5))
        XCTAssertNoThrow(try BlindABXSession(trialCount: 24))
    }

    func testIndependentRandomAssignmentsNotFixedBalance() throws {
        var trial = try BlindABXSession(trialCount: 12, initialAssignment: true)
        // Inject deterministic *independent* outcomes to verify that the
        // last trial is not forced to compensate a prebalanced session.
        for _ in 0..<11 {
            try trial.recordXPlayback()
            try trial.submit(true, nextAssignment: true)
        }
        XCTAssertEqual(trial.currentTrialNumber, 12)
        XCTAssertTrue(trial.currentHiddenXWasB)
        try trial.recordXPlayback()
        try trial.submit(true)
        XCTAssertEqual(try trial.exportEvidence().correctCount, 12)
    }

    func testPreflightOnlyRefusesFilesThatCannotPlay() {
        let a = BlindABXFileMetrics(
            sampleRate: 384_000, channels: 2, frameCount: 384_000,
            rmsDBFS: -20.0, samplePeakDBFS: -4.0
        )
        // E12 S28: loudness, length, rate and peak differences are matched by the page, not refused.
        var b = a
        b.rmsDBFS = -14
        b.sampleRate = 48_000
        b.frameCount = 96_000
        b.samplePeakDBFS = -0.1
        XCTAssertTrue(BlindABXPreflight.reasons(a: a, b: b).isEmpty)
        b = a
        b.channels = 1
        XCTAssertFalse(BlindABXPreflight.reasons(a: a, b: b).isEmpty)
        b = a
        b.rmsDBFS = .nan
        XCTAssertFalse(BlindABXPreflight.reasons(a: a, b: b).isEmpty)
        b = a
        b.frameCount = 0
        XCTAssertFalse(BlindABXPreflight.reasons(a: a, b: b).isEmpty)
    }

    func testABXExportIsRoundTrippableAndExposesNoHardwareAuthority() throws {
        var session = try BlindABXSession(trialCount: 16, initialAssignment: false)
        for _ in 0..<16 {
            try session.recordXPlayback()
            try session.submit(false, nextAssignment: false)
        }
        let exported = try session.exportEvidence()
        let encoded = try JSONEncoder().encode(exported)
        let decoded = try JSONDecoder().decode(BlindABXEvidence.self, from: encoded)
        XCTAssertEqual(decoded.trialCount, 16)
        XCTAssertEqual(decoded.correctCount, 16)
        XCTAssertEqual(decoded.evidenceAuthority, "userExploratoryOfflineListening")
        XCTAssertEqual(decoded.trials.count, 16)
        XCTAssertFalse(decoded.realHardwareMeasured)
        XCTAssertFalse(decoded.mayMergeIntoMain)
    }
}
