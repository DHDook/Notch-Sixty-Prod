import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneReferenceLeakageStabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let analyzer = QuietZoneReferenceLeakageStabilityAnalyzer()

    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(
            projectID: UUID(), microphoneID: "hallway-mic",
            microphoneChannel: 0, outputDeviceID: "main-dac",
            routeID: "selected-output-lease", sampleRate: 48_000,
            clockID: "measured-clock", triggerID: "isolated-speaker-probe"
        )
    }

    private func candidate(
        left: [Float] = [0.01, -0.01],
        right: [Float] = [0.01, -0.01]
    ) -> QuietZoneCausalFIRCandidate {
        .init(
            sampleRate: 48_000, leftTaps: left, rightTaps: right,
            worstPredictedReductionDB: 1.0,
            maximumRelativeFitError: 0.05,
            maximumReferenceEchoFraction: 0.01
        )
    }

    private func captures(
        _ r: QuietZoneHardwareCalibrationRig,
        impulse: [Double] = [0.04, -0.01, 0.005],
        sigma: Double = 0.0001,
        coherence: Double = 0.98
    ) -> [QuietZoneReferenceLeakageCapture] {
        [QuietZoneLeakageSpeaker.left, .right].flatMap { speaker in
            (0..<3).map { n in
                .init(
                    rig: r, speaker: speaker,
                    sourceFixtureID: r.triggerID,
                    launchID: "\(speaker.rawValue)-independent-\(n)",
                    capturedAt: now.addingTimeInterval(-Double(n * 2)),
                    measuredCoherence: coherence,
                    impulseResponse: impulse.map {
                        $0 * (1.0 + Double(n - 1) * 0.01)
                    },
                    oneSigmaError: Array(repeating: sigma, count: impulse.count)
                )
            }
        }
    }

    func testRepeatedLowLeakageProvidesConservativeDiagnosticOnly() throws {
        let r = rig()
        let result = try analyzer.assess(
            candidate: candidate(), rig: r, captures: captures(r), now: now
        )
        XCTAssertEqual(result.uniquePhysicalLaunchCount, 6)
        XCTAssertEqual(result.minimumCoherence, 0.98)
        XCTAssertGreaterThan(result.conservativeSmallGainMargin, 0.90)
        XCTAssertGreaterThan(result.conservativeFeedbackLoopL1, 0)
        XCTAssertTrue(result.reviewText.contains("Independent physical acoustic verification: NOT COMPLETE"))
        XCTAssertFalse(result.echoCancellerEnabled)
        XCTAssertFalse(result.acousticFeedbackVerified)
        XCTAssertFalse(result.outputConnected)
        XCTAssertFalse(result.liveANCQualified)
    }

    func testStrongSpeakerLeakageIsRejectedEvenIfCandidatePredictedLittleEcho() {
        let r = rig()
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(left: [0.03], right: [0.03]),
            rig: r, captures: captures(r, impulse: [5.0]), now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .excessiveFeedbackBound)
        }
    }

    func testUncertaintyCanExceedFeedbackBoundEvenWithSmallNominalLeakage() {
        let r = rig()
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(left: [0.03], right: [0.03]),
            rig: r, captures: captures(r, impulse: [0.04], sigma: 1.0),
            now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .excessiveFeedbackBound)
        }
    }

    func testMissingDuplicateAndWrongSpeakerRepetitionsFailClosed() {
        let r = rig()
        let c = captures(r)
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(), rig: r, captures: Array(c.dropLast()),
            now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .incompleteRepetitions)
        }
        var duplicates = c
        duplicates[3] = duplicates[0]
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(), rig: r, captures: duplicates, now: now
        ))
        var wrongCount = c
        wrongCount[3] = QuietZoneReferenceLeakageCapture(
            rig: r, speaker: .left,
            sourceFixtureID: r.triggerID, launchID: "unique-new-launch",
            capturedAt: now, measuredCoherence: 0.98,
            impulseResponse: [0.04, -0.01, 0.005],
            oneSigmaError: [0.0001, 0.0001, 0.0001]
        )
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(), rig: r, captures: wrongCount, now: now
        ))
    }

    func testStaleOrMismatchedRigNeverPasses() {
        let r = rig()
        var c = captures(r)
        c[0] = .init(
            rig: r, speaker: .left, sourceFixtureID: r.triggerID,
            launchID: "outdated", capturedAt: now.addingTimeInterval(-310),
            measuredCoherence: 0.98, impulseResponse: [0.04],
            oneSigmaError: [0.0001]
        )
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(), rig: r, captures: c, now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .staleEvidence)
        }
        let different = rig()
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(), rig: different,
            captures: captures(r), now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .untrustedRoute)
        }
    }

    func testLowCoherenceAndNonfiniteValuesAreRejected() {
        let r = rig()
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(), rig: r,
            captures: captures(r, coherence: 0.60), now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .insufficientCoherence)
        }
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(), rig: r,
            captures: captures(r, impulse: [.nan]), now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .invalidMeasurements)
        }
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(), rig: r,
            captures: captures(r, sigma: -.infinity), now: now
        ))
    }

    func testRepeatabilityDriftCannotBeHiddenByAveraging() {
        let r = rig()
        var c = captures(r)
        let original = c[2]
        c[2] = .init(
            rig: r, speaker: .left, sourceFixtureID: r.triggerID,
            launchID: original.launchID, capturedAt: original.capturedAt,
            measuredCoherence: original.measuredCoherence,
            impulseResponse: [0.10, -0.01, 0.005],
            oneSigmaError: original.oneSigmaError
        )
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(), rig: r, captures: c, now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .inconsistentCaptures)
        }
    }

    func testFIRFilterHeadroomAndSelfReportedEchoAreNotTrusted() {
        let r = rig()
        XCTAssertThrowsError(try analyzer.assess(
            candidate: candidate(left: [0.20], right: [0.01]),
            rig: r, captures: captures(r), now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .invalidCandidate)
        }
        var claim = candidate()
        claim.maximumReferenceEchoFraction = 0.7
        XCTAssertThrowsError(try analyzer.assess(
            candidate: claim, rig: r, captures: captures(r), now: now
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .invalidCandidate)
        }
    }
}
