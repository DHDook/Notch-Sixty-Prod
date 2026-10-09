import CryptoKit
import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneEvidenceHandoffTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let privateKey = Curve25519.Signing.PrivateKey()

    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(projectID: UUID(), microphoneID: "measurement-mic",
              microphoneChannel: 0, outputDeviceID: "dac-123",
              routeID: "selected-session-lease", sampleRate: 48_000,
              clockID: "host-clock-calibration-1", triggerID: "source-fixture")
    }

    private func session() throws -> QuietZoneHardwareCalibrationSession {
        try .init(rig: rig(), now: origin)
    }

    private func signer() -> QuietZoneEvidenceTrustedSigner {
        .init(keyID: "bench-key-v1", instrumentID: "instrument-alpha",
              calibrationRecordID: "calibration-2026",
              publicKey: privateKey.publicKey.rawRepresentation)
    }

    private func payload(
        _ session: QuietZoneHardwareCalibrationSession
    ) -> QuietZoneEvidencePayload {
        let launches: [QuietZoneEvidenceSourceLaunch] = [
            .init(eventID: "listener-launch", position: .listenerFirst,
                  emissionHostSeconds: 100, timebaseUncertaintySeconds: 0.00004),
            .init(eventID: "doorway-launch", position: .upstream,
                  emissionHostSeconds: 101, timebaseUncertaintySeconds: 0.00004),
            .init(eventID: "listener-return-launch", position: .listenerReturn,
                  emissionHostSeconds: 102, timebaseUncertaintySeconds: 0.00004)
        ]
        let methods: [QuietZoneLatencyWitnessMethod] = [
            .acousticReferenceToADCReady, .adcReadyToAntiNoiseCommand,
            .commandToAnalogDACOutput, .analogSpeakerOutputToListenerMic
        ]
        let events: [QuietZoneEvidenceEndpoint] = methods.enumerated().flatMap {
            stageIndex, method in
            (0..<3).map { repetition in
                let start = 200 + Double(stageIndex) * 10 + Double(repetition)
                return QuietZoneEvidenceEndpoint(
                    eventID: "endpoint-\(stageIndex)-\(repetition)",
                    method: method,
                    measuredAt: origin.addingTimeInterval(
                        3 + Double(stageIndex) + Double(repetition) * 0.1
                    ),
                    startHostSeconds: start,
                    endHostSeconds: start + 0.003,
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
            capturedAt: origin.addingTimeInterval(8),
            rig: session.rig, instrumentID: "instrument-alpha",
            calibrationRecordID: "calibration-2026",
            calibrationValidUntil: origin.addingTimeInterval(300),
            sourceLaunches: launches, endpointMeasurements: events
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    private func envelope(
        _ payload: QuietZoneEvidencePayload,
        keyID: String = "bench-key-v1"
    ) throws -> Data {
        let body = try encode(payload)
        let signature = try privateKey.signature(for: body)
        return try encode(QuietZoneEvidenceEnvelope(
            version: 1, signerKeyID: keyID,
            payload: body, signature: signature
        ))
    }

    private func route(
        _ session: QuietZoneHardwareCalibrationSession
    ) -> QuietZoneHardwareHALClockAcquisition.Route {
        (outputID: session.rig.outputDeviceID,
         routeID: session.rig.routeID,
         sampleRate: session.rig.sampleRate)
    }

    func testSignedEnvelopeProducesInspectableDiagnosticOnly() throws {
        let s = try session()
        var ledger = QuietZoneEvidenceImportLedger()
        let bytes = try envelope(payload(s))
        let inspection = try QuietZoneEvidenceHandoffVerifier().inspect(
            bytes, trustedSigner: signer(),
            session: s, currentOutput: route(s), ledger: &ledger,
            now: origin.addingTimeInterval(10)
        )
        XCTAssertTrue(inspection.signatureMatchesConfiguredKey)
        XCTAssertEqual(inspection.sourceLaunchIDs.count, 3)
        XCTAssertEqual(inspection.measuredStages.count, 4)
        XCTAssertEqual(inspection.measurementRun.completedStages, 4)
        XCTAssertEqual(
            inspection.measuredStages[0].measuredLatencySeconds,
            0.0025, accuracy: 0.000001
        )
        XCTAssertFalse(inspection.physicalHardwareVerified)
        XCTAssertFalse(inspection.acousticCancellationVerified)
        XCTAssertFalse(inspection.liveANCQualified)
        XCTAssertThrowsError(try QuietZoneEvidenceHandoffVerifier().inspect(
            bytes, trustedSigner: signer(),
            session: s, currentOutput: route(s), ledger: &ledger,
            now: origin.addingTimeInterval(11)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .replayedPackage)
        }
    }

    func testAlteredPayloadCannotPassPinnedSignature() throws {
        let s = try session()
        let good = try envelope(payload(s))
        let decoder = JSONDecoder()
        let saved = try decoder.decode(QuietZoneEvidenceEnvelope.self, from: good)
        var tampered = saved.payload
        tampered[tampered.startIndex] ^= 0x01
        let corrupted = try encode(QuietZoneEvidenceEnvelope(
            version: 1, signerKeyID: saved.signerKeyID,
            payload: tampered, signature: saved.signature
        ))
        var ledger = QuietZoneEvidenceImportLedger()
        XCTAssertThrowsError(try QuietZoneEvidenceHandoffVerifier().inspect(
            corrupted, trustedSigner: signer(), session: s,
            currentOutput: route(s), ledger: &ledger,
            now: origin.addingTimeInterval(10)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .invalidSignature)
        }
        // Failed verification cannot burn the legitimate import nonce.
        XCTAssertNoThrow(try QuietZoneEvidenceHandoffVerifier().inspect(
            good, trustedSigner: signer(), session: s,
            currentOutput: route(s), ledger: &ledger,
            now: origin.addingTimeInterval(10)
        ))
    }

    func testUnenrolledSignerAndSwappedPhysicalLeaseAreRejected() throws {
        let s = try session()
        let file = try envelope(payload(s))
        var ledger = QuietZoneEvidenceImportLedger()
        let wrong = QuietZoneEvidenceTrustedSigner(
            keyID: "untrusted", instrumentID: signer().instrumentID,
            calibrationRecordID: signer().calibrationRecordID,
            publicKey: signer().publicKey
        )
        XCTAssertThrowsError(try QuietZoneEvidenceHandoffVerifier().inspect(
            file, trustedSigner: wrong, session: s,
            currentOutput: route(s), ledger: &ledger,
            now: origin.addingTimeInterval(10)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .untrustedSigner)
        }
        XCTAssertThrowsError(try QuietZoneEvidenceHandoffVerifier().inspect(
            file, trustedSigner: signer(), session: s,
            currentOutput: (outputID: "dac-123",
                            routeID: "restarted", sampleRate: 48_000),
            ledger: &ledger, now: origin.addingTimeInterval(10)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .mismatchedRoute)
        }
    }

    func testOldSessionAndExpiredCalibrationFailClosed() throws {
        let s = try session()
        let file = try envelope(payload(s))
        let different = try session()
        var ledger = QuietZoneEvidenceImportLedger()
        XCTAssertThrowsError(try QuietZoneEvidenceHandoffVerifier().inspect(
            file, trustedSigner: signer(), session: different,
            currentOutput: route(different), ledger: &ledger,
            now: origin.addingTimeInterval(10)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .mismatchedSession)
        }
        XCTAssertThrowsError(try QuietZoneEvidenceHandoffVerifier().inspect(
            file, trustedSigner: signer(), session: s,
            currentOutput: route(s), ledger: &ledger,
            now: origin.addingTimeInterval(320)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .expiredCalibration)
        }
    }

    func testDuplicateSourceAndEndpointIDsRejectedEvenWithValidSignature() throws {
        let s = try session()
        let original = payload(s)
        var launches = original.sourceLaunches
        launches[2] = .init(
            eventID: launches[0].eventID, position: .listenerReturn,
            emissionHostSeconds: 102,
            timebaseUncertaintySeconds: 0.00004
        )
        let duplicate = QuietZoneEvidencePayload(
            schemaVersion: original.schemaVersion,
            sessionID: original.sessionID,
            sessionStartedAt: original.sessionStartedAt,
            capturedAt: original.capturedAt, rig: original.rig,
            instrumentID: original.instrumentID,
            calibrationRecordID: original.calibrationRecordID,
            calibrationValidUntil: original.calibrationValidUntil,
            sourceLaunches: launches,
            endpointMeasurements: original.endpointMeasurements
        )
        var ledger = QuietZoneEvidenceImportLedger()
        XCTAssertThrowsError(try QuietZoneEvidenceHandoffVerifier().inspect(
            envelope(duplicate), trustedSigner: signer(), session: s,
            currentOutput: route(s), ledger: &ledger,
            now: origin.addingTimeInterval(10)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .duplicateEvent)
        }
    }

    func testOversizedAndMalformedEvidenceIsRejected() throws {
        let s = try session()
        var ledger = QuietZoneEvidenceImportLedger()
        XCTAssertThrowsError(try QuietZoneEvidenceHandoffVerifier().inspect(
            Data(repeating: 0, count: QuietZoneEvidenceHandoffVerifier
                .envelopeByteLimit + 1),
            trustedSigner: signer(), session: s,
            currentOutput: route(s), ledger: &ledger,
            now: origin.addingTimeInterval(10)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .oversized)
        }
        XCTAssertThrowsError(try QuietZoneEvidenceHandoffVerifier().inspect(
            Data("not JSON".utf8), trustedSigner: signer(), session: s,
            currentOutput: route(s), ledger: &ledger,
            now: origin.addingTimeInterval(10)
        )) {
            XCTAssertEqual($0 as? QuietZoneEvidenceHandoffError, .malformed)
        }
    }
}
