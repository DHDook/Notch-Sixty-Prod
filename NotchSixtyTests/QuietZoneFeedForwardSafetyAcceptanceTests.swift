import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneFeedForwardSafetyAcceptanceTests: XCTestCase {
    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(projectID: UUID(), microphoneID: "mic", microphoneChannel: 0,
              outputDeviceID: "dac", routeID: "route", sampleRate: 48_000,
              clockID: "clock", triggerID: "source")
    }

    private func candidate(
        left: [Float] = [0.015, 0.005],
        right: [Float] = [0.015, -0.005]
    ) -> QuietZoneCausalFIRCandidate {
        .init(sampleRate: 48_000, leftTaps: left, rightTaps: right,
              worstPredictedReductionDB: 1.0,
              maximumRelativeFitError: 0.03,
              maximumReferenceEchoFraction: 0.003)
    }

    private func clock() -> QuietZoneFeedForwardClockStatus {
        .init(inputRateHz: 48_000, outputRateHz: 48_000,
              relativeDriftPPM: 0.5,
              latestInputAtSeconds: 12, latestOutputAtSeconds: 12,
              observationCount: 16, firstFault: nil)
    }

    private func snapshot(
        faulted: Bool = false,
        stereoPeakMicro: UInt32 = 20_000,
        bypass: Bool = false
    ) -> N60FFDeadlineSnapshot {
        var s = N60FFDeadlineSnapshot()
        s.acceptedRecords = 128
        s.maximumObservedStereoSumMicro = stereoPeakMicro
        s.halted = faulted
        s.simulatedBypassReached = bypass
        s.faultFadeFramesRemaining = bypass ? 0 : (faulted ? 128 : 0)
        s.simulatedFaultFadeGain = bypass ? 0 : 1
        return s
    }

    private func leakage(_ r: QuietZoneHardwareCalibrationRig)
        -> QuietZoneReferenceLeakageStabilityReport {
        .init(leftPathUpperL1Gain: 0.04, rightPathUpperL1Gain: 0.04,
              candidateLeftL1Gain: 0.02, candidateRightL1Gain: 0.02,
              conservativeFeedbackLoopL1: 0.0016,
              conservativeSmallGainMargin: 0.9984,
              minimumCoherence: 0.98, uniquePhysicalLaunchCount: 6,
              worstRepeatDeviation: 0.02, capturesFromRig: r)
    }

    func testGoodSoftwareEvidenceStillCannotQualifyLiveOutput() {
        let r = rig()
        let c = candidate()
        let leak = leakage(r)
        let echo = QuietZoneReferenceEchoModel(
            rig: r, candidate: c, stability: leak,
            leftSpeakerToReference: [0.04], rightSpeakerToReference: [0.04],
            leftTapDeviationBounds: [0.0005],
            rightTapDeviationBounds: [0.0005],
            capturedAt: Date(),
            independentSourceLaunchIDs: Set((0..<6).map { "launch-\($0)" })
        )
        let report = QuietZoneFeedForwardSafetyAcceptanceEvaluator().review(
            rig: r, candidate: c, clock: clock(), shadow: snapshot(),
            leakage: leak, echo: echo)
        XCTAssertEqual(report.status(.perSpeakerGain), .diagnosticPassed)
        XCTAssertEqual(report.status(.combinedStereoHeadroom), .diagnosticPassed)
        XCTAssertEqual(report.status(.referenceFeedbackBound), .diagnosticPassed)
        XCTAssertEqual(report.status(.echoContaminationModel), .diagnosticPassed)
        XCTAssertEqual(report.status(.independentHardwareReview),
                       .independentPhysicalReviewRequired)
        XCTAssertEqual(report.status(.measuredSeatAttenuation),
                       .independentPhysicalReviewRequired)
        XCTAssertEqual(report.status(.liveOutputAuthorization),
                       .independentPhysicalReviewRequired)
        XCTAssertFalse(report.speakerOutputConnected)
        XCTAssertFalse(report.independentlyCommissioned)
        XCTAssertFalse(report.acousticAttenuationVerified)
        XCTAssertFalse(report.liveANCQualified)
    }

    func testCombinedStereoCoefficientBudgetRejectsIndividuallyValidFIR() {
        let r = rig()
        let report = QuietZoneFeedForwardSafetyAcceptanceEvaluator().review(
            rig: r, candidate: candidate(left: [0.06], right: [0.06]),
            clock: clock(), shadow: snapshot(), leakage: nil, echo: nil)
        XCTAssertEqual(report.status(.perSpeakerGain), .diagnosticPassed)
        XCTAssertEqual(report.status(.combinedStereoHeadroom), .blocked)
        XCTAssertFalse(report.liveANCQualified)
    }

    func testFaultedShadowNeverClaimsDeadlineOrPhysicalReadiness() {
        let r = rig()
        let report = QuietZoneFeedForwardSafetyAcceptanceEvaluator().review(
            rig: r, candidate: candidate(), clock: clock(),
            shadow: snapshot(faulted: true, bypass: true),
            leakage: nil, echo: nil)
        XCTAssertEqual(report.status(.realTimeDeadline), .blocked)
        XCTAssertEqual(report.status(.faultToBypassSimulation), .diagnosticPassed)
        XCTAssertFalse(report.speakerOutputConnected)
        XCTAssertFalse(report.liveANCQualified)
    }

    func testMissingEvidenceIsNeverImplicitlyGreen() {
        let report = QuietZoneFeedForwardSafetyAcceptanceEvaluator().review(
            rig: rig(), candidate: nil, clock: nil, shadow: nil,
            leakage: nil, echo: nil)
        XCTAssertEqual(report.items.count,
                       QuietZoneFeedForwardAcceptanceGate.allCases.count)
        XCTAssertEqual(report.diagnosticPassCount, 0)
        XCTAssertEqual(report.status(.synchronizedClock), .missing)
        XCTAssertEqual(report.status(.realTimeDeadline), .missing)
        XCTAssertEqual(report.status(.faultToBypassSimulation), .missing)
        XCTAssertFalse(report.liveANCQualified)
    }

    func testFaultedClockAndExcessiveReportedOutputPeakBlockDiagnostic() {
        let r = rig()
        let badClock = QuietZoneFeedForwardClockStatus(
            inputRateHz: 48_000, outputRateHz: 48_000,
            relativeDriftPPM: 120, latestInputAtSeconds: 20,
            latestOutputAtSeconds: 20,
            observationCount: 16, firstFault: .excessiveDrift)
        let report = QuietZoneFeedForwardSafetyAcceptanceEvaluator().review(
            rig: r, candidate: candidate(), clock: badClock,
            shadow: snapshot(stereoPeakMicro: 101_000),
            leakage: nil, echo: nil)
        XCTAssertEqual(report.status(.synchronizedClock), .blocked)
        XCTAssertEqual(report.status(.combinedStereoHeadroom), .blocked)
        XCTAssertFalse(report.liveANCQualified)
    }

    func testMismatchedModelAndRigCannotCountAsEchoAcceptance() {
        let r = rig()
        let other = rig()
        let c = candidate()
        let leak = leakage(r)
        let echo = QuietZoneReferenceEchoModel(
            rig: other, candidate: c, stability: leak,
            leftSpeakerToReference: [0.04], rightSpeakerToReference: [0.04],
            leftTapDeviationBounds: [0.0005],
            rightTapDeviationBounds: [0.0005],
            capturedAt: Date(),
            independentSourceLaunchIDs: Set((0..<6).map { "launch-\($0)" })
        )
        let report = QuietZoneFeedForwardSafetyAcceptanceEvaluator().review(
            rig: r, candidate: c, clock: clock(),
            shadow: snapshot(), leakage: leak, echo: echo)
        XCTAssertEqual(report.status(.echoContaminationModel), .blocked)
        XCTAssertFalse(report.liveANCQualified)
    }
}
