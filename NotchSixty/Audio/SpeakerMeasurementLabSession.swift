import Foundation

struct SpeakerMeasurementLabProtocol:
    Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var request: SpeakerMeasurementLabRequest
    /// Optional only for subwooferNearField. Older persisted Slice 2 sessions
    /// decode this as nil, preserving schema compatibility.
    var nearFieldComponent:
        SpeakerMeasurementLabNearFieldComponent? = nil

    var acousticSource: MultichannelCalibrationSource? {
        guard case .acousticSource(let source) = request.target else {
            return nil
        }
        return source
    }

    func validateForAcquisition() throws {
        try request.validate()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SpeakerMeasurementLabSessionError.invalidProtocol
        }
        switch request.mode {
        case .wholeSpeakerOnAxis,
             .wholeSpeakerOffAxis:
            guard acousticSource != nil,
                  nearFieldComponent == nil else {
                throw SpeakerMeasurementLabSessionError.invalidProtocol
            }
        case .subwooferNearField:
            guard acousticSource != nil,
                  nearFieldComponent?.validate() ?? true else {
                throw SpeakerMeasurementLabSessionError.invalidProtocol
            }
        case .protectedDriverNearField,
             .coherentMainsSubTiming:
            throw SpeakerMeasurementLabSessionError
                .unsupportedAcquisitionMode(request.mode)
        }
    }
}

struct SpeakerMeasurementLabCapture:
    Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var protocolID: UUID
    var repeatIndex: Int
    var capturedAt: Date
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var microphoneCalibration: RoomCorrectionMicrophoneCalibration? = nil
    var sampleRate: Double
    var source: MultichannelCalibrationSource
    var impulseResponse: [Float]
    var transferFunction: RoomCorrectionFrequencyResponse
    var quality: RoomCorrectionMeasurementQuality
}

struct SpeakerMeasurementLabSession:
    Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var sampleRate: Double
    var protocols: [SpeakerMeasurementLabProtocol]
    var captures: [SpeakerMeasurementLabCapture]
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    func validateStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              sampleRate.isFinite,
              sampleRate > 0,
              !routingSignature.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              microphone.validate(),
              !protocols.isEmpty,
              Set(protocols.map(\.id)).count == protocols.count,
              Set(captures.map(\.id)).count == captures.count else {
            throw SpeakerMeasurementLabSessionError.invalidSession
        }

        for labProtocol in protocols {
            try labProtocol.validateForAcquisition()
        }

        for capture in captures {
            guard let labProtocol = protocols.first(
                where: { $0.id == capture.protocolID }
            ),
                  let source = labProtocol.acousticSource,
                  capture.source == source,
                  capture.playbackSystemID == playbackSystemID,
                  capture.routingSignature == routingSignature,
                  capture.microphone == microphone,
                  abs(capture.sampleRate - sampleRate) < 0.5,
                  capture.repeatIndex >= 0,
                  capture.repeatIndex < labProtocol.request.repeatCount,
                  !capture.impulseResponse.isEmpty,
                  capture.impulseResponse.allSatisfy(\.isFinite),
                  valid(response: capture.transferFunction) else {
                throw SpeakerMeasurementLabSessionError
                    .captureIdentityMismatch
            }
        }

        for labProtocol in protocols {
            let group = captures
                .filter { $0.protocolID == labProtocol.id }
                .sorted { $0.repeatIndex < $1.repeatIndex }
            guard group.count <= labProtocol.request.repeatCount,
                  group.map(\.repeatIndex) == Array(0..<group.count) else {
                throw SpeakerMeasurementLabSessionError
                    .captureSequenceInvalid
            }
        }
    }

    private func valid(
        response: RoomCorrectionFrequencyResponse
    ) -> Bool {
        let f = response.frequenciesHz
        let m = response.magnitudeDB
        guard f.count == m.count,
              f.count >= 2,
              f.allSatisfy({ $0.isFinite && $0 > 0 }),
              m.allSatisfy(\.isFinite),
              zip(f, f.dropFirst()).allSatisfy({ $0.0 < $0.1 })
        else {
            return false
        }
        if let phase = response.phaseRadians {
            guard phase.count == f.count,
                  phase.allSatisfy(\.isFinite) else {
                return false
            }
        }
        return true
    }
}

enum SpeakerMeasurementLabSessionError:
    Error, Equatable, LocalizedError {
    case invalidSession
    case invalidProtocol
    case unsupportedAcquisitionMode(SpeakerMeasurementLabMode)
    case captureIdentityMismatch
    case captureSequenceInvalid
    case captureDoesNotMatchStep
    case noCaptureToRetry
    case persistenceIdentityMismatch
    case analyzedResponseUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "Advanced Speaker Measurement Lab session metadata is invalid."
        case .invalidProtocol:
            return "Advanced Speaker Measurement Lab protocol is invalid."
        case .unsupportedAcquisitionMode(let mode):
            return "\(mode.rawValue) is not available for live acquisition in the current lab safety stage."
        case .captureIdentityMismatch:
            return "Lab capture does not match the session playback system, route, microphone, sample rate, protocol, or source."
        case .captureSequenceInvalid:
            return "Lab repeat captures are not a contiguous protocol repeat sequence."
        case .captureDoesNotMatchStep:
            return "Lab capture does not match the pending protocol repeat."
        case .noCaptureToRetry:
            return "No completed lab capture exists for that protocol."
        case .persistenceIdentityMismatch:
            return "Stored Advanced Speaker Measurement Lab session identity does not match the requested session."
        case .analyzedResponseUnavailable:
            return "Lab analysis did not produce a usable transfer function or impulse response."
        }
    }
}

struct SpeakerMeasurementLabSessionStep: Equatable, Sendable {
    var labProtocol: SpeakerMeasurementLabProtocol
    var repeatIndex: Int

    var instruction: String {
        let geometry = labProtocol.request.geometry
        let repeatText =
            "repeat \(repeatIndex + 1) of \(labProtocol.request.repeatCount)"
        switch labProtocol.request.mode {
        case .wholeSpeakerOnAxis:
            return "Place the microphone \(format(geometry.distanceMeters)) m from \(labProtocol.name) on axis; keep speaker and microphone fixed for \(repeatText)."
        case .wholeSpeakerOffAxis:
            return "Place the microphone \(format(geometry.distanceMeters)) m from \(labProtocol.name) at H \(format(geometry.horizontalAngleDegrees))° / V \(format(geometry.verticalAngleDegrees))°; keep geometry fixed for \(repeatText)."
        case .subwooferNearField:
            return "Place the microphone \(format(geometry.distanceMeters)) m from \(labProtocol.name) in the selected near-field location; keep geometry fixed for \(repeatText)."
        case .protectedDriverNearField,
             .coherentMainsSubTiming:
            return "This protocol is blocked by the current measurement safety contract."
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct SpeakerMeasurementLabSessionProgress:
    Equatable, Sendable {
    var completedCaptureCount: Int
    var requiredCaptureCount: Int
    var completedProtocolCount: Int
    var requiredProtocolCount: Int
    var nextStep: SpeakerMeasurementLabSessionStep?

    var complete: Bool {
        requiredCaptureCount > 0
            && completedCaptureCount >= requiredCaptureCount
    }

    var fractionComplete: Double {
        guard requiredCaptureCount > 0 else { return 0 }
        return min(
            1,
            max(
                0,
                Double(completedCaptureCount)
                    / Double(requiredCaptureCount)
            )
        )
    }
}

struct SpeakerMeasurementLabSessionOrchestrator: Sendable {
    func steps(
        for session: SpeakerMeasurementLabSession
    ) throws -> [SpeakerMeasurementLabSessionStep] {
        try session.validateStructure()
        return session.protocols.flatMap { labProtocol in
            (0..<labProtocol.request.repeatCount).map {
                SpeakerMeasurementLabSessionStep(
                    labProtocol: labProtocol,
                    repeatIndex: $0
                )
            }
        }
    }

    func progress(
        for session: SpeakerMeasurementLabSession
    ) throws -> SpeakerMeasurementLabSessionProgress {
        try session.validateStructure()
        var completed = 0
        var completedProtocols = 0
        var next: SpeakerMeasurementLabSessionStep?

        for labProtocol in session.protocols {
            let count = session.captures.filter {
                $0.protocolID == labProtocol.id
            }.count
            let bounded = min(count, labProtocol.request.repeatCount)
            completed += bounded
            if bounded >= labProtocol.request.repeatCount {
                completedProtocols += 1
            } else if next == nil {
                next = SpeakerMeasurementLabSessionStep(
                    labProtocol: labProtocol,
                    repeatIndex: bounded
                )
            }
        }

        return SpeakerMeasurementLabSessionProgress(
            completedCaptureCount: completed,
            requiredCaptureCount: session.protocols.reduce(0) {
                $0 + $1.request.repeatCount
            },
            completedProtocolCount: completedProtocols,
            requiredProtocolCount: session.protocols.count,
            nextStep: next
        )
    }

    func nextPendingStep(
        for session: SpeakerMeasurementLabSession
    ) throws -> SpeakerMeasurementLabSessionStep? {
        try progress(for: session).nextStep
    }

    func appending(
        _ capture: SpeakerMeasurementLabCapture,
        to session: SpeakerMeasurementLabSession,
        for step: SpeakerMeasurementLabSessionStep,
        modifiedAt: Date = Date()
    ) throws -> SpeakerMeasurementLabSession {
        try session.validateStructure()
        guard step.labProtocol.id == capture.protocolID,
              step.repeatIndex == capture.repeatIndex,
              step.labProtocol.acousticSource == capture.source,
              session.protocols.contains(
                  where: { $0.id == step.labProtocol.id }
              ) else {
            throw SpeakerMeasurementLabSessionError
                .captureDoesNotMatchStep
        }

        let currentCount = session.captures.filter {
            $0.protocolID == step.labProtocol.id
        }.count
        guard currentCount == step.repeatIndex,
              currentCount < step.labProtocol.request.repeatCount,
              !session.captures.contains(where: { $0.id == capture.id })
        else {
            throw SpeakerMeasurementLabSessionError
                .captureDoesNotMatchStep
        }

        var updated = session
        updated.captures.append(capture)
        updated.modifiedAt = modifiedAt
        try updated.validateStructure()
        return updated
    }

    func retryLatestCapture(
        in session: SpeakerMeasurementLabSession,
        protocolID: UUID,
        modifiedAt: Date = Date()
    ) throws -> SpeakerMeasurementLabSession {
        try session.validateStructure()
        let candidates = session.captures.enumerated()
            .filter { $0.element.protocolID == protocolID }
        guard let latest = candidates.max(by: {
            if $0.element.repeatIndex != $1.element.repeatIndex {
                return $0.element.repeatIndex < $1.element.repeatIndex
            }
            return $0.element.capturedAt < $1.element.capturedAt
        }) else {
            throw SpeakerMeasurementLabSessionError.noCaptureToRetry
        }

        var updated = session
        updated.captures.remove(at: latest.offset)
        updated.modifiedAt = modifiedAt
        try updated.validateStructure()
        return updated
    }
}

struct SpeakerMeasurementLabCaptureBuilder: Sendable {
    func build(
        analyzed: RoomCorrectionChannelMeasurement,
        session: SpeakerMeasurementLabSession,
        step: SpeakerMeasurementLabSessionStep
    ) throws -> SpeakerMeasurementLabCapture {
        guard let source = step.labProtocol.acousticSource,
              let response = analyzed.transferFunction,
              !analyzed.impulseResponse.isEmpty,
              analyzed.impulseResponse.allSatisfy(\.isFinite) else {
            throw SpeakerMeasurementLabSessionError
                .analyzedResponseUnavailable
        }

        let capture = SpeakerMeasurementLabCapture(
            protocolID: step.labProtocol.id,
            repeatIndex: step.repeatIndex,
            capturedAt: analyzed.capturedAt,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            microphone: session.microphone,
            sampleRate: session.sampleRate,
            source: source,
            impulseResponse: analyzed.impulseResponse,
            transferFunction: response,
            quality: analyzed.quality
        )

        var probe = session
        probe.captures.append(capture)
        try probe.validateStructure()
        return capture
    }
}

struct SpeakerMeasurementLabSessionStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    func url(for sessionID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(sessionID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    func save(_ session: SpeakerMeasurementLabSession) throws {
        try session.validateStructure()
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(session).write(
            to: url(for: session.id),
            options: .atomic
        )
    }

    func load(_ sessionID: UUID) throws
        -> SpeakerMeasurementLabSession? {
        let path = url(for: sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let session = try decoder.decode(
            SpeakerMeasurementLabSession.self,
            from: Data(contentsOf: path)
        )
        guard session.id == sessionID else {
            throw SpeakerMeasurementLabSessionError
                .persistenceIdentityMismatch
        }
        try session.validateStructure()
        return session
    }

    private static func defaultRootDirectory() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return root
            .appendingPathComponent("Notch Sixty", isDirectory: true)
            .appendingPathComponent(
                "Advanced Speaker Measurement Lab",
                isDirectory: true
            )
    }
}
