import CryptoKit
import Foundation

/// Off-device evidence envelope. Only payload bytes, not an automatically
/// re-encoded object, are covered by the Ed25519 signature.
struct QuietZoneEvidenceEnvelope: Codable, Sendable {
    let version: Int
    let signerKeyID: String
    let payload: Data
    let signature: Data
}

/// The expected signing key is provisioned OUTSIDE the evidence package.
/// Merely verifying a signature does not certify physical ADC/DAC behavior.
struct QuietZoneEvidenceTrustedSigner: Sendable {
    let keyID: String
    let instrumentID: String
    let calibrationRecordID: String
    let publicKey: Data
}

struct QuietZoneEvidenceSourceLaunch: Codable, Sendable {
    let eventID: String
    let position: QuietZoneFeedForwardPosition
    let emissionHostSeconds: Double
    let timebaseUncertaintySeconds: Double
}

struct QuietZoneEvidenceEndpoint: Codable, Sendable {
    let eventID: String
    let method: QuietZoneLatencyWitnessMethod
    let measuredAt: Date
    let startHostSeconds: Double
    let endHostSeconds: Double
    let calibratedEndpointCorrectionSeconds: Double
    let startClockUncertaintySeconds: Double
    let endClockUncertaintySeconds: Double
    let correctionUncertaintySeconds: Double
    let worstSchedulingJitterSeconds: Double
    let clockCalibrationVerified: Bool
    let endpointCorrectionVerified: Bool
}

struct QuietZoneEvidencePayload: Codable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let sessionStartedAt: Date
    let capturedAt: Date
    let rig: QuietZoneHardwareCalibrationRig
    let instrumentID: String
    let calibrationRecordID: String
    let calibrationValidUntil: Date
    let sourceLaunches: [QuietZoneEvidenceSourceLaunch]
    let endpointMeasurements: [QuietZoneEvidenceEndpoint]
}

enum QuietZoneEvidenceHandoffError: Error, Equatable, LocalizedError {
    case oversized
    case unsupportedVersion
    case malformed
    case untrustedSigner
    case invalidSignature
    case mismatchedSession
    case mismatchedRoute
    case expiredCalibration
    case invalidLaunchSequence
    case duplicateEvent
    case incompleteMeasurements
    case replayedPackage

    var errorDescription: String? {
        switch self {
        case .oversized: return "The measurement handoff exceeds the maximum size."
        case .unsupportedVersion: return "Unsupported physical evidence schema."
        case .malformed: return "The signed measurement record is malformed."
        case .untrustedSigner: return "The expected instrument signing key is not provisioned."
        case .invalidSignature: return "The payload failed signature verification."
        case .mismatchedSession: return "Evidence belongs to another calibration session."
        case .mismatchedRoute: return "Physical output, input microphone, clock or session lease changed."
        case .expiredCalibration: return "Measurement evidence or instrument calibration is expired."
        case .invalidLaunchSequence: return "Source launches must be independent and in A/B/A order."
        case .duplicateEvent: return "A physical capture event was reused."
        case .incompleteMeasurements: return "Each of four physical stages needs three independent observations."
        case .replayedPackage: return "This session already imported the same evidence."
        }
    }
}

/// In-memory replay protection within a calibration session. This cannot
/// prevent replays after process restart; the random session ID must change.
struct QuietZoneEvidenceImportLedger: Sendable {
    private var sessions = Set<UUID>()
    private var events = Set<String>()

    func permits(sessionID: UUID, eventIDs: Set<String>) -> Bool {
        !sessions.contains(sessionID) && events.isDisjoint(with: eventIDs)
    }

    mutating func record(sessionID: UUID, eventIDs: Set<String>) {
        sessions.insert(sessionID)
        events.formUnion(eventIDs)
    }
}

struct QuietZoneEvidenceInspection: Sendable {
    let instrumentID: String
    let signerKeyID: String
    let calibrationRecordID: String
    let sourceLaunchIDs: [String]
    let measuredStages: [QuietZonePhysicalLatencyEvidence]
    let measurementRun: QuietZonePhysicalLatencyMeasurementRun
    let signatureMatchesConfiguredKey: Bool = true
    let physicalHardwareVerified: Bool = false
    let acousticCancellationVerified: Bool = false
    let liveANCQualified: Bool = false
}

/// Read-only signature, provenance and physical measurement-shape validator.
/// Caller-configured key material must come from a separate trusted channel.
struct QuietZoneEvidenceHandoffVerifier: Sendable {
    static let envelopeByteLimit = 131_072
    static let payloadByteLimit = 65_536
    static let maximumSourceUncertaintySeconds = 0.0005
    static let minimumEvents = 3
    static let maximumEvents = 20

    func inspect(
        _ bytes: Data,
        trustedSigner: QuietZoneEvidenceTrustedSigner,
        session: QuietZoneHardwareCalibrationSession,
        currentOutput: QuietZoneHardwareHALClockAcquisition.Route?,
        ledger: inout QuietZoneEvidenceImportLedger,
        now: Date = Date()
    ) throws -> QuietZoneEvidenceInspection {
        guard !bytes.isEmpty, bytes.count <= Self.envelopeByteLimit
        else { throw QuietZoneEvidenceHandoffError.oversized }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let envelope = try? decoder.decode(
            QuietZoneEvidenceEnvelope.self, from: bytes
        ) else { throw QuietZoneEvidenceHandoffError.malformed }
        guard envelope.version == 1 else {
            throw QuietZoneEvidenceHandoffError.unsupportedVersion
        }
        guard envelope.payload.count > 0,
              envelope.payload.count <= Self.payloadByteLimit,
              envelope.signature.count == 64,
              !envelope.signerKeyID.isEmpty else {
            throw QuietZoneEvidenceHandoffError.oversized
        }
        guard envelope.signerKeyID == trustedSigner.keyID,
              trustedSigner.publicKey.count == 32,
              !trustedSigner.instrumentID.isEmpty,
              !trustedSigner.calibrationRecordID.isEmpty
        else { throw QuietZoneEvidenceHandoffError.untrustedSigner }
        guard let key = try? Curve25519.Signing.PublicKey(
            rawRepresentation: trustedSigner.publicKey
        ), key.isValidSignature(envelope.signature, for: envelope.payload)
        else { throw QuietZoneEvidenceHandoffError.invalidSignature }
        guard let payload = try? decoder.decode(
            QuietZoneEvidencePayload.self, from: envelope.payload
        ) else { throw QuietZoneEvidenceHandoffError.malformed }
        guard payload.schemaVersion == 1 else {
            throw QuietZoneEvidenceHandoffError.unsupportedVersion
        }

        let rig = session.rig
        guard payload.sessionID == session.evidenceSessionID,
              abs(payload.sessionStartedAt.timeIntervalSince(
                    session.startedAt
              )) < 0.001,
              payload.rig.projectID == rig.projectID
        else { throw QuietZoneEvidenceHandoffError.mismatchedSession }
        guard payload.rig == rig,
              let route = currentOutput,
              route.outputID == rig.outputDeviceID,
              route.routeID == rig.routeID,
              route.sampleRate.isFinite,
              abs(route.sampleRate - rig.sampleRate) < 0.5
        else { throw QuietZoneEvidenceHandoffError.mismatchedRoute }

        let elapsed = now.timeIntervalSince(session.startedAt)
        let age = now.timeIntervalSince(payload.capturedAt)
        guard elapsed.isFinite, elapsed >= 0,
              elapsed <= QuietZoneHardwareCalibrationSession.maximumSessionSeconds,
              age.isFinite, age >= 0,
              age <= QuietZoneHardwareCalibrationSession.maximumSessionSeconds,
              payload.capturedAt >= payload.sessionStartedAt,
              payload.calibrationValidUntil >= payload.capturedAt,
              payload.calibrationValidUntil >= now,
              payload.instrumentID == trustedSigner.instrumentID,
              payload.calibrationRecordID == trustedSigner.calibrationRecordID
        else { throw QuietZoneEvidenceHandoffError.expiredCalibration }

        guard payload.sourceLaunches.count == 3,
              payload.sourceLaunches.map(\.position) == [
                .listenerFirst, .upstream, .listenerReturn
              ] else { throw QuietZoneEvidenceHandoffError.invalidLaunchSequence }
        var events = Set<String>()
        var lastLaunch: Double?
        for launch in payload.sourceLaunches {
            guard !launch.eventID.isEmpty, events.insert(launch.eventID).inserted
            else { throw QuietZoneEvidenceHandoffError.duplicateEvent }
            guard launch.emissionHostSeconds.isFinite,
                  launch.emissionHostSeconds > 0,
                  launch.timebaseUncertaintySeconds.isFinite,
                  launch.timebaseUncertaintySeconds > 0,
                  launch.timebaseUncertaintySeconds
                      <= Self.maximumSourceUncertaintySeconds,
                  lastLaunch.map({ launch.emissionHostSeconds > $0 }) ?? true
            else { throw QuietZoneEvidenceHandoffError.invalidLaunchSequence }
            lastLaunch = launch.emissionHostSeconds
        }
        guard payload.endpointMeasurements.count >= 4 * Self.minimumEvents,
              payload.endpointMeasurements.count <= 4 * Self.maximumEvents
        else { throw QuietZoneEvidenceHandoffError.incompleteMeasurements }
        guard ledger.permits(sessionID: payload.sessionID, eventIDs: events)
        else { throw QuietZoneEvidenceHandoffError.replayedPackage }

        var assembled = try QuietZonePhysicalLatencyMeasurementRun(
            rig: rig, now: session.startedAt
        )
        for event in payload.endpointMeasurements {
            guard !event.eventID.isEmpty, events.insert(event.eventID).inserted
            else { throw QuietZoneEvidenceHandoffError.duplicateEvent }
            try assembled.add(
                .init(
                    rig: rig, method: event.method, eventID: event.eventID,
                    measuredAt: event.measuredAt,
                    startHostSeconds: event.startHostSeconds,
                    endHostSeconds: event.endHostSeconds,
                    calibratedEndpointCorrectionSeconds:
                        event.calibratedEndpointCorrectionSeconds,
                    startClockUncertaintySeconds:
                        event.startClockUncertaintySeconds,
                    endClockUncertaintySeconds:
                        event.endClockUncertaintySeconds,
                    correctionUncertaintySeconds:
                        event.correctionUncertaintySeconds,
                    worstSchedulingJitterSeconds:
                        event.worstSchedulingJitterSeconds,
                    clockCalibrationVerified:
                        event.clockCalibrationVerified,
                    endpointCorrectionVerified:
                        event.endpointCorrectionVerified,
                    origin: .instrumentedHardware
                ),
                now: now
            )
        }
        guard assembled.isComplete else {
            throw QuietZoneEvidenceHandoffError.incompleteMeasurements
        }
        guard ledger.permits(sessionID: payload.sessionID, eventIDs: events)
        else { throw QuietZoneEvidenceHandoffError.replayedPackage }
        let stages = try assembled.measurements(now: now)
        // Only modify in-memory replay protection after a complete success.
        ledger.record(sessionID: payload.sessionID, eventIDs: events)
        return .init(
            instrumentID: payload.instrumentID,
            signerKeyID: envelope.signerKeyID,
            calibrationRecordID: payload.calibrationRecordID,
            sourceLaunchIDs: payload.sourceLaunches.map(\.eventID),
            measuredStages: stages,
            measurementRun: assembled
        )
    }
}
