import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneNativeShadowTimingTransportTests: XCTestCase {
    private let rate = 48_000.0

    private func plan() -> QuietZoneFeedForwardSchedulingPlan {
        // Strictly synthetic fixture for the native bridge; not a real
        // commissionable hardware rig or speaker-output authorization.
        let rig = QuietZoneHardwareCalibrationRig(
            projectID: UUID(), microphoneID: "mic", microphoneChannel: 0,
            outputDeviceID: "dac", routeID: "lease", sampleRate: rate,
            clockID: "clock", triggerID: "source"
        )
        let stages: [(QuietZonePhysicalLatencyStage, Double)] = [
            (.referenceADC, 0.001), (.referenceProcessing, 0.001),
            (.outputDAC, 0.001), (.speakerToSeat, 0.002)
        ]
        let evidence = stages.map { kind, duration in
            QuietZonePhysicalLatencyEvidence(
                stage: kind, origin: .syntheticFixture,
                microphoneDeviceID: rig.microphoneID, microphoneChannel: 0,
                outputDeviceID: rig.outputDeviceID, routeLeaseID: rig.routeID,
                synchronizedClockID: rig.clockID, sampleRate: rate,
                capturedAt: Date(),
                independentLaunchIDs: ["a","b","c"],
                measuredLatencySeconds: duration,
                measuredUpperBoundSeconds: duration,
                oneSigmaUncertaintySeconds: 0,
                worstCaseJitterSeconds: 0
            )
        }
        // Plan's production initializer rejects synthetic evidence through
        // upstream PR97 strict analyzer. For these isolated native unit tests,
        // use the existing report structure, without claiming hardware origin.
        let budget = QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible,
            acousticPreviewSeconds: 0.025,
            conservativePreviewSeconds: 0.025,
            antiNoisePathSeconds: 0.005,
            conservativeReserveSeconds: 0.020,
            geometryOnly: false,
            runtimeAvailable: false,
            explanation: "Synthetic test fixture"
        )
        let report = QuietZonePhysicalLatencyReport(
            stageEvidence: evidence,
            nominalPathSeconds: 0.005,
            upperBoundPathSeconds: 0.0053,
            lowerBoundNoiseLeadSeconds: 0.025,
            conservativeReserveSeconds: 0.0197,
            requiredSafetyReserveSeconds: 0.002,
            readiness: .physicallyPlausible,
            budget: budget
        )
        return try! QuietZoneFeedForwardSchedulingPlan(rig: rig, report: report)
    }

    private func candidate() -> QuietZoneCausalFIRCandidate {
        .init(
            sampleRate: rate, leftTaps: [0.01, 0.01, -0.005],
            rightTaps: [0.01, 0.01, -0.005],
            worstPredictedReductionDB: 2,
            maximumRelativeFitError: 0.01,
            maximumReferenceEchoFraction: 0.01
        )
    }

    private func raw(
        frame: Int,
        offset: UInt32 = 0,
        callbackTicks: UInt64 = 1_000
    ) -> N60FeedForwardReferenceFrame {
        var x = N60FeedForwardReferenceFrame()
        x.sample = 0.2
        x.firstFrameHostTime = callbackTicks
        x.firstFrameSampleTime = 2_000 + Double(frame)
        x.frameOffset = offset
        return x
    }

    private func input(frame: Int, offset: UInt32 = 0) ->
        QuietZoneFeedForwardReferenceDeadlineEvent {
        let time = 100 + Double(frame + Int(offset)) / rate
        return .init(
            referenceSampleFrame: 2_000 + Double(frame) + Double(offset),
            referenceAcousticHostSeconds: time,
            referenceAvailableHostSeconds: time + 0.001,
            evaluatedAtHostSeconds: time + 0.0012,
            microphoneSample: 0.2
        )
    }

    private func output(frame: Int, offset: UInt32 = 0,
                        route: UInt64 = 9) -> N60FFDeadlineOutputWitness {
        let e = input(frame: frame, offset: offset)
        var x = N60FFDeadlineOutputWitness()
        x.routeLeaseToken = route
        x.synchronizedClockToken = 7
        x.sampleRate = rate
        x.firstFrame = 48_000
        x.firstFrameHostSeconds = 100
        x.witnessedAtSeconds = e.evaluatedAtHostSeconds - 0.0001
        return x
    }

    private func transport(
        capacity: UInt32 = 256
    ) throws -> QuietZoneNativeShadowTimingTransport {
        try .init(
            plan: plan(), candidate: candidate(),
            routeLeaseToken: 9, synchronizedClockToken: 7, capacity: capacity
        )
    }

    func testNativeBridgeSchedulesFIFOWithoutEverProducingPCM() throws {
        let bridge = try transport()
        for n in 0..<200 {
            try bridge.ingest(
                referenceFrame: raw(frame: n),
                witnessed: input(frame: n),
                output: output(frame: n)
            )
        }
        let rows = bridge.readDiagnostics(maximum: 200)
        XCTAssertEqual(rows.count, 200)
        XCTAssertTrue(zip(rows, rows.dropFirst()).allSatisfy { pair in
            pair.0.hypotheticalOutputFrame < pair.1.hypotheticalOutputFrame
        })
        XCTAssertEqual(rows[0].referenceFrame, 2000)
        XCTAssertGreaterThan(rows[0].estimatedProcessingSlackSeconds, 0)
        XCTAssertEqual(bridge.snapshot().acceptedRecords, 200)
        XCTAssertFalse(bridge.snapshot().halted)
        XCTAssertFalse(bridge.snapshot().outputConnected)
        XCTAssertFalse(bridge.snapshot().liveANCQualified)
        XCTAssertFalse(bridge.outputConnected)
        XCTAssertFalse(bridge.liveANCQualified)
        bridge.close()
    }

    func testOverflowStopsPermanentlyAndRevokesAllQueuedMetadata() throws {
        let bridge = try transport()
        for n in 0..<256 {
            try bridge.ingest(
                referenceFrame: raw(frame: n), witnessed: input(frame: n),
                output: output(frame: n)
            )
        }
        XCTAssertEqual(bridge.snapshot().queuedRecords, 256)
        XCTAssertThrowsError(try bridge.ingest(
            referenceFrame: raw(frame: 256), witnessed: input(frame: 256),
            output: output(frame: 256)
        ))
        XCTAssertTrue(bridge.snapshot().halted)
        XCTAssertEqual(bridge.snapshot().firstFault.rawValue, 7)
        XCTAssertEqual(bridge.snapshot().queuedRecords, 0)
        XCTAssertTrue(bridge.readDiagnostics().isEmpty)
        XCTAssertThrowsError(try bridge.ingest(
            referenceFrame: raw(frame: 257), witnessed: input(frame: 257),
            output: output(frame: 257)
        ))
    }

    func testOutputLeaseAndClockAnchorDiscontinuityFailClosed() throws {
        let swapped = try transport()
        XCTAssertThrowsError(try swapped.ingest(
            referenceFrame: raw(frame: 0), witnessed: input(frame: 0),
            output: output(frame: 0, route: 10)
        ))
        XCTAssertEqual(swapped.snapshot().firstFault.rawValue, 2)
        let discontinuous = try transport()
        try discontinuous.ingest(
            referenceFrame: raw(frame: 0), witnessed: input(frame: 0),
            output: output(frame: 0)
        )
        var jumped = output(frame: 1)
        jumped.firstFrameHostSeconds += 0.002
        XCTAssertThrowsError(try discontinuous.ingest(
            referenceFrame: raw(frame: 1), witnessed: input(frame: 1),
            output: jumped
        ))
        XCTAssertEqual(discontinuous.snapshot().firstFault.rawValue, 4)
        XCTAssertEqual(discontinuous.snapshot().queuedRecords, 0)
    }

    func testSourceFrameRewindAndWitnessMutationCannotBeIgnored() throws {
        let bridge = try transport()
        try bridge.ingest(
            referenceFrame: raw(frame: 0), witnessed: input(frame: 0),
            output: output(frame: 0)
        )
        // The Swift shim rejects raw microphone/source disagreement even
        // before submitting potentially untrusted data to the native ring.
        XCTAssertThrowsError(try bridge.ingest(
            referenceFrame: raw(frame: 1), witnessed: input(frame: 4),
            output: output(frame: 1)
        ))
        XCTAssertTrue(bridge.snapshot().halted)
        XCTAssertTrue(bridge.readDiagnostics().isEmpty)
    }

    func testMissedDeadlineAndStaleClockFailClosed() throws {
        let late = try transport()
        let tooLate = QuietZoneFeedForwardReferenceDeadlineEvent(
            referenceSampleFrame: 2_000,
            referenceAcousticHostSeconds: 100,
            referenceAvailableHostSeconds: 100.001,
            evaluatedAtHostSeconds: 100.04,
            microphoneSample: 0.2
        )
        var out = output(frame: 0)
        out.witnessedAtSeconds = 100.0399
        XCTAssertThrowsError(try late.ingest(
            referenceFrame: raw(frame: 0), witnessed: tooLate, output: out
        ))
        XCTAssertEqual(late.snapshot().firstFault.rawValue, 6)

        let stale = try transport()
        var old = output(frame: 0)
        old.witnessedAtSeconds = 99.0
        XCTAssertThrowsError(try stale.ingest(
            referenceFrame: raw(frame: 0), witnessed: input(frame: 0),
            output: old
        ))
        XCTAssertEqual(stale.snapshot().firstFault.rawValue, 5)
    }

    func testWraparoundAfterDrainsKeepsFIFOAndDoesNotRepeatAudio() throws {
        let bridge = try transport()
        for batch in 0..<4 {
            for frame in 0..<128 {
                let n = batch * 128 + frame
                try bridge.ingest(
                    referenceFrame: raw(frame: n), witnessed: input(frame: n),
                    output: output(frame: n)
                )
            }
            let records = bridge.readDiagnostics(maximum: 128)
            XCTAssertEqual(records.count, 128)
            XCTAssertEqual(records.first?.referenceFrame,
                           Double(2000 + batch * 128))
        }
        XCTAssertEqual(bridge.snapshot().acceptedRecords, 512)
        XCTAssertEqual(bridge.snapshot().queuedRecords, 0)
        XCTAssertFalse(bridge.snapshot().halted)
    }

    func testInvalidNativePlanAndFIRAreRejectedAtConstruction() throws {
        let p = plan()
        var bad = candidate()
        bad.leftTaps = [0.2]
        bad.rightTaps = [0.2]
        XCTAssertThrowsError(try QuietZoneNativeShadowTimingTransport(
            plan: p, candidate: bad,
            routeLeaseToken: 9, synchronizedClockToken: 7
        ))
        XCTAssertThrowsError(try QuietZoneNativeShadowTimingTransport(
            plan: p, candidate: candidate(),
            routeLeaseToken: 0, synchronizedClockToken: 7
        ))
        XCTAssertThrowsError(try transport(capacity: 257))
    }
}
