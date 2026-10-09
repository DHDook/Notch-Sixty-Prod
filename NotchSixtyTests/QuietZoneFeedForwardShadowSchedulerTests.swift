import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneFeedForwardShadowSchedulerTests: XCTestCase {
    private let initial = Date(timeIntervalSince1970: 1_800_000_000)

    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(
            projectID: UUID(), microphoneID: "upstream-reference",
            microphoneChannel: 0, outputDeviceID: "speaker-dac",
            routeID: "output-lease", sampleRate: 48_000,
            clockID: "common-clock", triggerID: "source"
        )
    }

    private func stage(
        _ stage: QuietZonePhysicalLatencyStage, rig: QuietZoneHardwareCalibrationRig,
        seconds: Double
    ) -> QuietZonePhysicalLatencyEvidence {
        .init(
            stage: stage, origin: .instrumentedHardware,
            microphoneDeviceID: rig.microphoneID,
            microphoneChannel: rig.microphoneChannel,
            outputDeviceID: rig.outputDeviceID,
            routeLeaseID: rig.routeID,
            synchronizedClockID: rig.clockID,
            sampleRate: rig.sampleRate,
            capturedAt: initial,
            independentLaunchIDs: ["\(stage.rawValue)-1",
                                   "\(stage.rawValue)-2",
                                   "\(stage.rawValue)-3"],
            measuredLatencySeconds: seconds,
            measuredUpperBoundSeconds: seconds,
            oneSigmaUncertaintySeconds: 0.00002,
            worstCaseJitterSeconds: 0.00005
        )
    }

    private func report(
        _ rig: QuietZoneHardwareCalibrationRig,
        lead: Double = 0.025,
        readiness: QuietZoneFeedForwardReadiness = .physicallyPlausible
    ) -> QuietZonePhysicalLatencyReport {
        let stages = [
            stage(.referenceADC, rig: rig, seconds: 0.001),
            stage(.referenceProcessing, rig: rig, seconds: 0.001),
            stage(.outputDAC, rig: rig, seconds: 0.001),
            stage(.speakerToSeat, rig: rig, seconds: 0.002)
        ]
        let budget = QuietZoneFeedForwardBudget(
            readiness: readiness, acousticPreviewSeconds: lead,
            conservativePreviewSeconds: lead,
            antiNoisePathSeconds: 0.005,
            conservativeReserveSeconds: lead - 0.006037,
            geometryOnly: false,
            runtimeAvailable: false,
            explanation: "Synthetic dry-run fixture, not physical ANC validation."
        )
        return .init(
            stageEvidence: stages,
            nominalPathSeconds: 0.005,
            upperBoundPathSeconds: 0.006037,
            lowerBoundNoiseLeadSeconds: lead,
            conservativeReserveSeconds: lead - 0.006037,
            requiredSafetyReserveSeconds: 0.002,
            readiness: readiness,
            budget: budget
        )
    }

    private func candidate() -> QuietZoneCausalFIRCandidate {
        .init(
            sampleRate: 48_000,
            leftTaps: [0.01, 0.01, -0.005],
            rightTaps: [0.01, 0.01, -0.005],
            worstPredictedReductionDB: 2,
            maximumRelativeFitError: 0.01,
            maximumReferenceEchoFraction: 0.01
        )
    }

    private func clock(
        _ rig: QuietZoneHardwareCalibrationRig,
        at time: Double,
        route: String = "output-lease"
    ) -> QuietZoneFeedForwardOutputClockAnchor {
        .init(
            outputDeviceID: rig.outputDeviceID,
            routeLeaseID: route,
            synchronizedClockID: rig.clockID,
            sampleRate: rig.sampleRate,
            firstOutputSampleFrame: 48_000,
            firstOutputSampleHostSeconds: 100,
            observedAtHostSeconds: time - 0.0001
        )
    }

    private func event(
        frame: Int, current: Double? = nil,
        value: Float = 0.2
    ) -> QuietZoneFeedForwardReferenceDeadlineEvent {
        let time = 100 + Double(frame) / 48_000
        return .init(
            referenceSampleFrame: 2_000 + Double(frame),
            referenceAcousticHostSeconds: time,
            referenceAvailableHostSeconds: time + 0.001,
            evaluatedAtHostSeconds: current ?? time + 0.0012,
            microphoneSample: value
        )
    }

    private func scheduler(
        _ rig: QuietZoneHardwareCalibrationRig
    ) throws -> QuietZoneFeedForwardShadowScheduler {
        try .init(
            plan: QuietZoneFeedForwardSchedulingPlan(
                rig: rig, report: report(rig)
            ),
            candidate: candidate()
        )
    }

    func testContinuousSampleTimelineProducesStrictDeadlinesAndNoOutput() throws {
        let r = rig()
        let engine = try scheduler(r)
        var previous: Int64?
        for i in 0..<128 {
            let value = event(frame: i)
            let answer = try engine.schedule(
                value, output: clock(r, at: value.evaluatedAtHostSeconds)
            )
            XCTAssertTrue(answer.processingSlackSeconds > 0)
            XCTAssertFalse(answer.outputConnected)
            XCTAssertFalse(answer.liveANCQualified)
            if let previous { XCTAssertTrue(answer.plannedOutputFrame > previous) }
            previous = answer.plannedOutputFrame
        }
        XCTAssertEqual(engine.snapshot().scheduledReferenceFrames, 128)
        XCTAssertEqual(engine.snapshot().faults, 0)
        XCTAssertFalse(engine.snapshot().stopped)
        XCTAssertFalse(engine.snapshot().outputConnected)
        XCTAssertFalse(engine.snapshot().liveANCQualified)
        engine.stop()
        XCTAssertTrue(engine.snapshot().stopped)
    }

    func testRouteLeaseChangeStopsAndPermanentlyDisablesRehearsal() throws {
        let r = rig()
        let engine = try scheduler(r)
        let sample = event(frame: 0)
        XCTAssertThrowsError(try engine.schedule(
            sample, output: clock(r, at: sample.evaluatedAtHostSeconds,
                                  route: "after-device-restart")
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .wrongRoute)
        }
        XCTAssertTrue(engine.snapshot().stopped)
        XCTAssertEqual(engine.snapshot().faults, 1)
        XCTAssertThrowsError(try engine.schedule(
            sample, output: clock(r, at: sample.evaluatedAtHostSeconds)
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .disabled)
        }
    }

    func testLateProcessingAndStaleOutputWitnessFailClosed() throws {
        let r = rig()
        let late = try scheduler(r)
        let afterDeadline = event(frame: 0, current: 100.03)
        XCTAssertThrowsError(try late.schedule(
            afterDeadline, output: clock(r, at: afterDeadline.evaluatedAtHostSeconds)
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .missedDeadline)
        }
        let stale = try scheduler(r)
        let fresh = event(frame: 0)
        let expired = QuietZoneFeedForwardOutputClockAnchor(
            outputDeviceID: r.outputDeviceID,
            routeLeaseID: r.routeID,
            synchronizedClockID: r.clockID, sampleRate: r.sampleRate,
            firstOutputSampleFrame: 48_000,
            firstOutputSampleHostSeconds: 100,
            observedAtHostSeconds: 99
        )
        XCTAssertThrowsError(try stale.schedule(fresh, output: expired)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError,
                           .staleOutputClock)
        }
    }

    func testReferenceGapAndClockRewindStopProcessing() throws {
        let r = rig()
        let gap = try scheduler(r)
        let first = event(frame: 0)
        _ = try gap.schedule(first, output: clock(r, at: first.evaluatedAtHostSeconds))
        let jumped = event(frame: 2)
        XCTAssertThrowsError(try gap.schedule(
            jumped, output: clock(r, at: jumped.evaluatedAtHostSeconds)
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .discontinuity)
        }
        XCTAssertEqual(gap.snapshot().scheduledReferenceFrames, 1)
        let rewind = try scheduler(r)
        _ = try rewind.schedule(first, output: clock(r, at: first.evaluatedAtHostSeconds))
        XCTAssertThrowsError(try rewind.schedule(
            first, output: clock(r, at: first.evaluatedAtHostSeconds)
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .discontinuity)
        }
    }

    func testNonfiniteMicAndUnrealisticAcquisitionRejectImmediately() throws {
        let r = rig()
        let invalid = try scheduler(r)
        let sample = event(frame: 0, value: .nan)
        XCTAssertThrowsError(try invalid.schedule(
            sample, output: clock(r, at: sample.evaluatedAtHostSeconds)
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .invalidReference)
        }
        let tooOld = try scheduler(r)
        let old = QuietZoneFeedForwardReferenceDeadlineEvent(
            referenceSampleFrame: 2_000,
            referenceAcousticHostSeconds: 100,
            referenceAvailableHostSeconds: 100.1,
            evaluatedAtHostSeconds: 100.101,
            microphoneSample: 0.5
        )
        XCTAssertThrowsError(try tooOld.schedule(
            old, output: clock(r, at: old.evaluatedAtHostSeconds)
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .invalidReference)
        }
    }

    func testNegativePhysicalReserveCannotCreateSchedulingPlan() {
        let r = rig()
        XCTAssertThrowsError(try QuietZoneFeedForwardSchedulingPlan(
            rig: r, report: report(r, lead: 0.003, readiness: .nonCausal)
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .nonCausal)
        }
    }

    func testInvalidFIRAndMismatchedMeasurementRouteAreRejected() throws {
        let r = rig()
        let plan = try QuietZoneFeedForwardSchedulingPlan(
            rig: r, report: report(r)
        )
        var bad = candidate()
        bad.leftTaps = [0.2]
        bad.rightTaps = [0.2]
        XCTAssertThrowsError(try QuietZoneFeedForwardShadowScheduler(
            plan: plan, candidate: bad
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .invalidPlan)
        }
        let another = QuietZoneHardwareCalibrationRig(
            projectID: r.projectID,
            microphoneID: r.microphoneID, microphoneChannel: 0,
            outputDeviceID: r.outputDeviceID,
            routeID: "different-route", sampleRate: r.sampleRate,
            clockID: r.clockID, triggerID: r.triggerID
        )
        XCTAssertThrowsError(try QuietZoneFeedForwardSchedulingPlan(
            rig: another, report: report(r)
        )) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSchedulingError, .invalidPlan)
        }
    }
}
