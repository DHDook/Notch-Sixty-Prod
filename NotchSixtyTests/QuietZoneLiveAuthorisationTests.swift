import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneLiveAuthorisationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let binding = LiveANCBinding(
        outputDeviceUID: "dac", inputDeviceUID: "ref-mic", sampleRate: 48_000
    )

    /// Stand-in for a passing acoustic record. The real PR99 review can never
    /// pass on its own because it does not authenticate the instrument.
    private struct PassingAcoustic: LiveANCEvidence {
        let binding: LiveANCBinding
        let recordedAt: Date
        var requirement: LiveANCRequirement { .acousticTargets }
        var shortfall: String? { nil }
    }

    private func timing(at date: Date, qualified: Bool = true) -> LiveANCTimingEvidence {
        LiveANCTimingEvidence(
            trace: QuietZoneHALClockTrace(
                inputDeviceID: binding.inputDeviceUID,
                outputDeviceID: binding.outputDeviceUID,
                nominalSampleRate: binding.sampleRate,
                inputObservations: [], outputObservations: []
            ),
            health: QuietZoneHALClockHealth(
                measuredInputRateHz: 48_000, measuredOutputRateHz: 48_000,
                relativeDriftPPM: 0.1, worstInputResidualSeconds: 1e-6,
                worstOutputResidualSeconds: 1e-6, observationDurationSeconds: 2,
                qualifiedForLoopbackBench: qualified
            ),
            recordedAt: date
        )
    }

    private func latency(
        at date: Date,
        reserve: Double = 0.004,
        required: Double = 0.002,
        sampleRate: Double = 48_000
    ) -> LiveANCLatencyEvidence {
        let stages = QuietZonePhysicalLatencyStage.allCases.map { stage in
            QuietZonePhysicalLatencyEvidence(
                stage: stage, origin: .instrumentedHardware,
                microphoneDeviceID: binding.inputDeviceUID, microphoneChannel: 0,
                outputDeviceID: binding.outputDeviceUID, routeLeaseID: "route",
                synchronizedClockID: "clock", sampleRate: sampleRate,
                capturedAt: date, independentLaunchIDs: ["a", "b", "c"],
                measuredLatencySeconds: 0.001, measuredUpperBoundSeconds: 0.0012,
                oneSigmaUncertaintySeconds: 0.00001, worstCaseJitterSeconds: 0.00002
            )
        }
        return LiveANCLatencyEvidence(report: QuietZonePhysicalLatencyReport(
            stageEvidence: stages, nominalPathSeconds: 0.004,
            upperBoundPathSeconds: 0.005, lowerBoundNoiseLeadSeconds: 0.009,
            conservativeReserveSeconds: reserve,
            requiredSafetyReserveSeconds: required,
            readiness: .physicallyPlausible, budget: .missing
        ))
    }

    private func bench(
        _ requirement: LiveANCRequirement, at date: Date, passed: Bool = true
    ) -> LiveANCBenchAttestation {
        LiveANCBenchAttestation(
            requirement: requirement, binding: binding, recordedAt: date,
            operatorName: "Bench", passed: passed, note: "fixture"
        )
    }

    private func completeRecord() -> [any LiveANCEvidence] {
        [
            timing(at: t0),
            latency(at: t0.addingTimeInterval(300)),
            PassingAcoustic(binding: binding, recordedAt: t0.addingTimeInterval(1200)),
            bench(.howlDetector, at: t0.addingTimeInterval(1500)),
            bench(.analogMute, at: t0.addingTimeInterval(1600)),
            LiveANCOwnerSignOff(
                binding: binding, recordedAt: t0.addingTimeInterval(86_400),
                signedBy: "Owner"
            ),
        ]
    }

    private func replacing(
        _ requirement: LiveANCRequirement, with item: any LiveANCEvidence
    ) -> [any LiveANCEvidence] {
        completeRecord().filter { $0.requirement != requirement } + [item]
    }

    func testNoEvidenceListsEveryRequirementAsMissing() {
        let decision = LiveANCAuthorisation.evaluate([], for: binding)
        XCTAssertFalse(decision.authorised)
        XCTAssertEqual(
            decision.reasons,
            LiveANCRequirement.allCases.map { .missing($0) }
        )
    }

    func testCompleteRecordAuthorisesOnlyItsOwnHardware() {
        XCTAssertTrue(
            LiveANCAuthorisation.evaluate(completeRecord(), for: binding).authorised
        )
        for other in [
            LiveANCBinding(outputDeviceUID: "other", inputDeviceUID: "ref-mic", sampleRate: 48_000),
            LiveANCBinding(outputDeviceUID: "dac", inputDeviceUID: "other", sampleRate: 48_000),
            LiveANCBinding(outputDeviceUID: "dac", inputDeviceUID: "ref-mic", sampleRate: 96_000),
        ] {
            let decision = LiveANCAuthorisation.evaluate(completeRecord(), for: other)
            XCTAssertFalse(decision.authorised)
            XCTAssertEqual(
                decision.reasons,
                LiveANCRequirement.allCases.map { .wrongHardware($0) }
            )
        }
    }

    func testTodaysReportsAloneNeverAuthorise() {
        let decision = LiveANCAuthorisation.evaluate(
            [timing(at: t0), latency(at: t0.addingTimeInterval(60))],
            for: binding
        )
        XCTAssertFalse(decision.authorised)
        XCTAssertEqual(decision.reasons, [
            .missing(.acousticTargets), .missing(.howlDetector),
            .missing(.analogMute), .missing(.ownerSignOff),
        ])
    }

    func testRealVerificationReviewFallsShortUntilIndependentlyVerified() {
        let review = QuietZonePhysicalVerificationReview(
            rig: QuietZoneHardwareCalibrationRig(
                projectID: UUID(), microphoneID: "meas", microphoneChannel: 0,
                outputDeviceID: "dac", routeID: "route", sampleRate: 48_000,
                clockID: "clock", triggerID: "trigger"
            ),
            sessionIDs: [UUID(), UUID(), UUID()],
            firstPrimaryReductionDB: 20, neighboringSeatReductionDB: 2,
            returningPrimaryReductionDB: 19.5, worstMeasuredBandReductionDB: 8,
            largestPrimaryBaselineDifferenceDB: 0.4,
            primaryReductionRepeatDifferenceDB: 0.5,
            worstReportedShutdownSeconds: 0.02, uniqueExternalLaunchCount: 6
        )
        let acoustic = LiveANCAcousticEvidence(
            review: review, inputDeviceUID: "ref-mic",
            recordedAt: t0.addingTimeInterval(1200)
        )
        XCTAssertNotNil(acoustic.shortfall)
        let decision = LiveANCAuthorisation.evaluate(
            replacing(.acousticTargets, with: acoustic), for: binding
        )
        XCTAssertEqual(decision.reasons, [
            .shortfall(.acousticTargets, "the reduction is not independently verified."),
        ])
    }

    func testFailedEvidenceIsReportedWithItsReason() {
        let cases: [(LiveANCRequirement, any LiveANCEvidence)] = [
            (.timing, timing(at: t0, qualified: false)),
            (.latencyBudget, latency(at: t0.addingTimeInterval(300), reserve: 0.001)),
            (.howlDetector, bench(.howlDetector, at: t0.addingTimeInterval(1500), passed: false)),
            (.ownerSignOff, LiveANCOwnerSignOff(
                binding: binding, recordedAt: t0.addingTimeInterval(86_400), signedBy: " "
            )),
        ]
        for (requirement, item) in cases {
            let decision = LiveANCAuthorisation.evaluate(
                replacing(requirement, with: item), for: binding
            )
            XCTAssertFalse(decision.authorised, "\(requirement)")
            XCTAssertEqual(decision.reasons.count, 1, "\(requirement)")
            guard case .shortfall(let r, _) = decision.reasons.first else {
                return XCTFail("\(requirement): \(decision.reasons)")
            }
            XCTAssertEqual(r, requirement)
        }
    }

    func testLatencyStagesFromAnotherRateFallShort() {
        var mixed = latency(at: t0.addingTimeInterval(300)).report.stageEvidence
        mixed[3] = latency(at: t0.addingTimeInterval(300), sampleRate: 96_000)
            .report.stageEvidence[3]
        let report = QuietZonePhysicalLatencyReport(
            stageEvidence: mixed, nominalPathSeconds: 0.004,
            upperBoundPathSeconds: 0.005, lowerBoundNoiseLeadSeconds: 0.009,
            conservativeReserveSeconds: 0.004, requiredSafetyReserveSeconds: 0.002,
            readiness: .physicallyPlausible, budget: .missing
        )
        XCTAssertNotNil(LiveANCLatencyEvidence(report: report).shortfall)
    }

    func testBenchAttestationCannotStandInForOtherRequirements() {
        let forged = bench(.ownerSignOff, at: t0.addingTimeInterval(86_400))
        let decision = LiveANCAuthorisation.evaluate(
            replacing(.ownerSignOff, with: forged), for: binding
        )
        XCTAssertFalse(decision.authorised)
        guard case .shortfall(.ownerSignOff, _) = decision.reasons.first else {
            return XCTFail("\(decision.reasons)")
        }
    }

    func testDuplicateEvidenceIsRejected() {
        let decision = LiveANCAuthorisation.evaluate(
            completeRecord() + [bench(.analogMute, at: t0.addingTimeInterval(1700))],
            for: binding
        )
        XCTAssertEqual(decision.reasons, [.duplicate(.analogMute)])
    }

    func testCampaignMustFitInThirtyMinutes() {
        let decision = LiveANCAuthorisation.evaluate(
            replacing(.acousticTargets, with: PassingAcoustic(
                binding: binding, recordedAt: t0.addingTimeInterval(1801)
            )),
            for: binding
        )
        XCTAssertEqual(decision.reasons, [.campaignTooLong])
    }

    func testSignOffMustFollowTheEvidence() {
        let decision = LiveANCAuthorisation.evaluate(
            replacing(.ownerSignOff, with: LiveANCOwnerSignOff(
                binding: binding, recordedAt: t0.addingTimeInterval(1000),
                signedBy: "Owner"
            )),
            for: binding
        )
        XCTAssertEqual(decision.reasons, [.signOffBeforeEvidence])
    }
}
