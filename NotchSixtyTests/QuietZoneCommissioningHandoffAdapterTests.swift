import CryptoKit
import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneCommissioningHandoffAdapterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = Curve25519.Signing.PrivateKey()

    private func rig(_ project: RoomCorrectionProject) -> QuietZoneHardwareCalibrationRig {
        .init(projectID: project.id, microphoneID: "mic",
              microphoneChannel: 0, outputDeviceID: "dac",
              routeID: "exact-output-lease", sampleRate: 48_000,
              clockID: "shared-clock", triggerID: "physical-fixture")
    }

    private func project() -> RoomCorrectionProject {
        let microphone = RoomCorrectionMicrophone(
            stableID: "mic", displayName: "Reference mic",
            manufacturer: nil, inputChannelIndex: 0, calibration: nil
        )
        let quality = RoomCorrectionMeasurementQuality(
            clipped: false, estimatedSNRDB: 45, sweepComplete: true
        )
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: start, rawCapture: [],
            impulseResponse: [1, 0], transferFunction: nil, quality: quality
        )
        let seat = RoomCorrectionMeasurementPosition(
            name: "Listener", sampleRate: 48_000,
            left: channel, right: channel
        )
        var p = RoomCorrectionProject(
            playbackSystemID: UUID(), name: "Hallway ANC commissioning"
        )
        p.microphone = microphone
        p.measurements = [seat]
        return p
    }

    private func plan(_ p: RoomCorrectionProject) -> QuietZoneFeedForwardCalibration {
        .init(
            projectID: p.id, playbackSystemID: p.playbackSystemID,
            listenerPositionID: p.measurements[0].id,
            upstreamLabel: "Doorway", microphoneStableID: "mic"
        )
    }

    private func probe() -> [Float] {
        var n: UInt32 = 0x414ABEEF
        return (0..<128).map { _ in
            n = n &* 1_664_525 &+ 1_013_904_223
            return n & 0x80000000 == 0 ? 0.4 : -0.4
        }
    }

    private func clock() -> QuietZoneHALClockTrace {
        let events = (0..<12).map {
            QuietZoneHALClockObservation(
                hostTimeSeconds: 100 + Double($0) * 0.25,
                sampleFrame: 20_000 + Double($0) * 12_000
            )
        }
        return .init(
            inputDeviceID: "mic", outputDeviceID: "dac",
            nominalSampleRate: 48_000,
            inputObservations: events, outputObservations: events
        )
    }

    private func loopbacks() -> [QuietZoneBenchLoopbackCapture] {
        [100.2, 101.1, 102.0].map { time in
            let signal = probe()
            var input = [Float](repeating: 0.0001, count: 2048)
            for i in signal.indices { input[480 + i] += signal[i] * 0.5 }
            return .init(
                routeFingerprint: "exact-output-lease",
                inputDeviceID: "mic", outputDeviceID: "dac",
                nominalSampleRate: 48_000,
                stimulus: signal, recorded: input,
                stimulusStartHostSeconds: time,
                firstRecordedFrameHostSeconds: time + 0.002,
                clockUncertaintySeconds: 0.00001, captureClipped: false
            )
        }
    }

    private func acoustic(_ position: QuietZoneFeedForwardPosition, offset: Int)
        -> QuietZoneFeedForwardProbeCapture {
        let signal = probe()
        var input = [Float](repeating: 0.0001, count: 2048)
        for i in signal.indices { input[offset + i] += signal[i] * 0.5 }
        return .init(
            position: position, emittedProbe: signal, recordedSamples: input,
            sampleRate: 48_000, firstInputFrameAfterTriggerSeconds: 0.004,
            triggerClockUncertaintySeconds: 0.00005,
            sourceTriggerID: "physical-fixture",
            synchronizedClockID: "shared-clock",
            microphoneDeviceID: "mic", microphoneChannel: 0,
            routeFingerprint: "exact-output-lease"
        )
    }

    private func session(
        _ r: QuietZoneHardwareCalibrationRig,
        instrumented: Bool = true
    ) throws -> QuietZoneHardwareCalibrationSession {
        var s = try QuietZoneHardwareCalibrationSession(rig: r, now: start)
        try s.qualifyClock(clock(), now: start.addingTimeInterval(1))
        _ = try s.qualifyLoopback(
            loopbacks(), now: start.addingTimeInterval(2)
        )
        let captures: [(QuietZoneFeedForwardPosition, Int)] = [
            (.listenerFirst, 1500), (.upstream, 500), (.listenerReturn, 1500)
        ]
        for (idx, entry) in captures.enumerated() {
            let capture = acoustic(entry.0, offset: entry.1)
            let timestamp = start.addingTimeInterval(Double(idx + 3))
            if instrumented {
                let launch = QuietZoneInstrumentedSourceLaunch(
                    launchID: "physical-launch-\(idx)",
                    sourceFixtureID: r.triggerID,
                    synchronizedClockID: r.clockID,
                    physicalSourceID: "hallway-source",
                    routeLeaseID: r.routeID,
                    sampleRate: r.sampleRate,
                    emissionHostSeconds: 100 + Double(idx),
                    oneSigmaTimingUncertaintySeconds: 0.00005,
                    physicalClockCalibrationVerified: true,
                    emittedProbe: probe()
                )
                _ = try s.addInstrumentedSourceCapture(
                    capture, launch: launch, projectID: r.projectID,
                    now: timestamp
                )
            } else {
                _ = try s.addAcousticCapture(
                    capture, projectID: r.projectID, now: timestamp
                )
            }
        }
        return s
    }

    private func signer() -> QuietZoneEvidenceTrustedSigner {
        .init(keyID: "fixture-key", instrumentID: "physical-bench",
              calibrationRecordID: "certificate-1",
              publicKey: key.publicKey.rawRepresentation)
    }

    private func payload(
        _ session: QuietZoneHardwareCalibrationSession,
        slowPath: Bool = false,
        swappedSource: Bool = false
    ) -> QuietZoneEvidencePayload {
        let sourcePositions: [QuietZoneFeedForwardPosition] = [
            .listenerFirst, .upstream, .listenerReturn
        ]
        let launches = sourcePositions.enumerated().map { idx, position in
            QuietZoneEvidenceSourceLaunch(
                eventID: swappedSource && idx == 1
                    ? "other-source" : "physical-launch-\(idx)",
                position: position,
                emissionHostSeconds: 100 + Double(idx),
                timebaseUncertaintySeconds: 0.00005
            )
        }
        let methods: [QuietZoneLatencyWitnessMethod] = [
            .acousticReferenceToADCReady, .adcReadyToAntiNoiseCommand,
            .commandToAnalogDACOutput, .analogSpeakerOutputToListenerMic
        ]
        let observations = methods.enumerated().flatMap { stage, method in
            (0..<3).map { repeatID in
                let stamp = 200 + Double(stage * 10 + repeatID)
                return QuietZoneEvidenceEndpoint(
                    eventID: "segment-\(stage)-\(repeatID)",
                    method: method,
                    measuredAt: start.addingTimeInterval(
                        6 + Double(stage) * 0.4 + Double(repeatID) * 0.1
                    ),
                    startHostSeconds: stamp,
                    endHostSeconds: stamp + (slowPath ? 0.015 : 0.0025),
                    calibratedEndpointCorrectionSeconds: 0.0005,
                    startClockUncertaintySeconds: 0.00002,
                    endClockUncertaintySeconds: 0.00002,
                    correctionUncertaintySeconds: 0.00002,
                    worstSchedulingJitterSeconds: 0.0001,
                    clockCalibrationVerified: true,
                    endpointCorrectionVerified: true
                )
            }
        }
        return .init(
            schemaVersion: 1, sessionID: session.evidenceSessionID,
            sessionStartedAt: session.startedAt,
            capturedAt: start.addingTimeInterval(9),
            rig: session.rig,
            instrumentID: "physical-bench",
            calibrationRecordID: "certificate-1",
            calibrationValidUntil: start.addingTimeInterval(200),
            sourceLaunches: launches,
            endpointMeasurements: observations
        )
    }

    private func signed(_ payload: QuietZoneEvidencePayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let body = try encoder.encode(payload)
        let signature = try key.signature(for: body)
        return try encoder.encode(QuietZoneEvidenceEnvelope(
            version: 1, signerKeyID: "fixture-key",
            payload: body, signature: signature
        ))
    }

    private func route(_ r: QuietZoneHardwareCalibrationRig)
        -> QuietZoneHardwareHALClockAcquisition.Route {
        (outputID: r.outputDeviceID, routeID: r.routeID,
         sampleRate: r.sampleRate)
    }

    func testEndToEndSignedEvidenceProducesReviewButNeverLiveAuthorization() throws {
        let p = project()
        let r = rig(p)
        let s = try session(r)
        var ledger = QuietZoneEvidenceImportLedger()
        let data = try signed(payload(s))
        let result = try QuietZoneCommissioningHandoffAdapter().inspect(
            data, trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: plan(p), project: p,
            ledger: &ledger, now: start.addingTimeInterval(12)
        )
        XCTAssertEqual(s.instrumentedSourceLaunchIDs.count, 3)
        XCTAssertEqual(result.latencyStages.count, 4)
        XCTAssertEqual(result.verdict, .plausibleUnverified)
        XCTAssertEqual(result.checklist.item(.causalBudget)?.status,
                       .capturedUnverified)
        XCTAssertEqual(result.checklist.item(.independentHardwareReview)?.status,
                       .physicalVerificationRequired)
        XCTAssertTrue(result.reviewText.contains("Conservative reserve:"))
        XCTAssertTrue(result.reviewText.contains("Physical hardware verified: NO"))
        XCTAssertFalse(result.physicallyCommissioned)
        XCTAssertFalse(result.acousticCancellationVerified)
        XCTAssertFalse(result.liveANCQualified)
        XCTAssertThrowsError(try QuietZoneCommissioningHandoffAdapter().inspect(
            data, trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: plan(p), project: p,
            ledger: &ledger, now: start.addingTimeInterval(13)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .replayedPackage)
        }
    }

    func testSignedSourceIDsMustMatchAcceptedMicrophoneLaunches() throws {
        let p = project(), r = rig(p)
        let s = try session(r)
        var ledger = QuietZoneEvidenceImportLedger()
        let bad = try signed(payload(s, swappedSource: true))
        XCTAssertThrowsError(try QuietZoneCommissioningHandoffAdapter().inspect(
            bad, trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: plan(p), project: p,
            ledger: &ledger, now: start.addingTimeInterval(12)
        )) {
            XCTAssertEqual($0 as? QuietZoneCommissioningHandoffError,
                           .sourceLaunchMismatch)
        }
        // A later valid package is still admissible: no poisoned replay state.
        XCTAssertNoThrow(try QuietZoneCommissioningHandoffAdapter().inspect(
            signed(payload(s)), trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: plan(p), project: p,
            ledger: &ledger, now: start.addingTimeInterval(12)
        ))
    }

    func testMissingSurveyAndUninstrumentedSurveyAreNeverAccepted() throws {
        let p = project(), r = rig(p)
        let s = try session(r, instrumented: false)
        var ledger = QuietZoneEvidenceImportLedger()
        XCTAssertEqual(s.instrumentedSourceLaunchIDs.count, 0)
        XCTAssertThrowsError(try QuietZoneCommissioningHandoffAdapter().inspect(
            signed(payload(s)), trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: plan(p), project: p,
            ledger: &ledger, now: start.addingTimeInterval(12)
        )) {
            XCTAssertEqual($0 as? QuietZoneCommissioningHandoffError,
                           .incompletePhysicalSurvey)
        }
    }

    func testFailedDownstreamReviewDoesNotConsumeValidSignedPacket() throws {
        let p = project(), r = rig(p)
        let s = try session(r)
        var ledger = QuietZoneEvidenceImportLedger()
        let bytes = try signed(payload(s))
        var badPlan = plan(p)
        badPlan.playbackSystemID = UUID()
        XCTAssertThrowsError(try QuietZoneCommissioningHandoffAdapter().inspect(
            bytes, trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: badPlan, project: p,
            ledger: &ledger, now: start.addingTimeInterval(12)
        ))
        XCTAssertNoThrow(try QuietZoneCommissioningHandoffAdapter().inspect(
            bytes, trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: plan(p), project: p,
            ledger: &ledger, now: start.addingTimeInterval(12)
        ))
    }

    func testNonCausalTimingIsReportedButNeverMisrepresentedAsReady() throws {
        let p = project(), r = rig(p)
        let s = try session(r)
        var ledger = QuietZoneEvidenceImportLedger()
        let result = try QuietZoneCommissioningHandoffAdapter().inspect(
            signed(payload(s, slowPath: true)),
            trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: plan(p), project: p,
            ledger: &ledger, now: start.addingTimeInterval(12)
        )
        XCTAssertEqual(result.verdict, .nonCausal)
        XCTAssertLessThan(result.timing.conservativeReserveSeconds, 0)
        XCTAssertEqual(result.checklist.item(.causalBudget)?.status, .invalid)
        XCTAssertFalse(result.liveANCQualified)
    }

    func testSelectedFileIsBoundedAndReadOnly() throws {
        let p = project(), r = rig(p)
        let s = try session(r)
        var ledger = QuietZoneEvidenceImportLedger()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR97-Adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("evidence.json")
        try signed(payload(s)).write(to: url, options: .atomic)
        let report = try QuietZoneCommissioningHandoffAdapter().inspectSelectedFile(
            at: url, trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: plan(p), project: p,
            ledger: &ledger, now: start.addingTimeInterval(12)
        )
        XCTAssertEqual(report.latencyStages.count, 4)
        let huge = dir.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: QuietZoneEvidenceHandoffVerifier
            .envelopeByteLimit + 1).write(to: huge, options: .atomic)
        XCTAssertThrowsError(try QuietZoneCommissioningHandoffAdapter().inspectSelectedFile(
            at: huge, trustedSigner: signer(), session: s,
            currentOutput: route(r), plan: plan(p), project: p,
            ledger: &ledger, now: start.addingTimeInterval(12)
        )) {
            XCTAssertEqual($0 as? QuietZoneCommissioningHandoffError,
                           .oversizedFile)
        }
    }
}
