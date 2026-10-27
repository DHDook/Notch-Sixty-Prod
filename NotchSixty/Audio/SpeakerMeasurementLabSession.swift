import Foundation

enum SpeakerMeasurementLabCoherentLeg:
    String, Codable, CaseIterable, Equatable, Sendable {
    case main
    case subwoofer
}

struct SpeakerMeasurementLabProtocol:
    Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var request: SpeakerMeasurementLabRequest
    /// Optional explicit sweep level for bounded multi-level diagnostics.
    /// Nil preserves legacy behavior using the current measurement-controller
    /// sweep level. New level-dependence analysis requires explicit values.
    var excitationLevelDBFS: Double? = nil
    /// Optional only for subwooferNearField. Older persisted Slice 2 sessions
    /// decode this as nil, preserving schema compatibility.
    var nearFieldComponent:
        SpeakerMeasurementLabNearFieldComponent? = nil
    /// Slice 9B: a coherent pair is represented by two protocols sharing this
    /// ID, one Main leg and one Sub leg. Optional preserves older archives.
    var coherentPairID: UUID? = nil
    var coherentLeg: SpeakerMeasurementLabCoherentLeg? = nil
    /// E8 B2: the parent speaker source of a `driverNearField` protocol (capture identity). Optional and additive.
    var driverCaptureSource: MultichannelCalibrationSource? = nil

    var routedWayID: UUID? {
        guard case .routedWay(let id) = request.target else { return nil }
        return id
    }

    /// E8 A2b: the way of a protected routed-way protocol.
    var protectedRoutedWayID: UUID? {
        guard case .protectedRoutedWay(let id) = request.target else { return nil }
        return id
    }

    /// The way a protocol sweeps, whichever routed target it uses.
    var sweptWayID: UUID? { protectedRoutedWayID ?? routedWayID }

    var acousticSource: MultichannelCalibrationSource? {
        guard case .acousticSource(let source) = request.target else {
            return nil
        }
        return source
    }

    var protectedDriverBus: SpeakerOutputBus? {
        guard case .protectedDriverBus(let bus) = request.target else {
            return nil
        }
        return bus
    }

    /// Protected split-driver captures retain the parent L/R speaker identity
    /// for common acoustic analysis while separate provenance keeps the exact
    /// Low/Mid/High bus identity.
    var captureSource: MultichannelCalibrationSource? {
        if let acousticSource { return acousticSource }
        if sweptWayID != nil { return driverCaptureSource }
        if request.mode == .coherentMainsSubTiming,
           case .sourcePair(let main, let subwoofer) = request.target,
           let coherentLeg {
            switch coherentLeg {
            case .main: return main
            case .subwoofer: return subwoofer
            }
        }
        guard let bus = protectedDriverBus else { return nil }
        switch bus {
        case .leftLow, .leftMid, .leftHigh:
            return .speaker(.frontLeft)
        case .rightLow, .rightMid, .rightHigh:
            return .speaker(.frontRight)
        case .leftFullRange, .rightFullRange, .subMono:
            return nil
        }
    }

    func resolvedExcitationLevelDBFS(default defaultLevel: Double) -> Double {
        excitationLevelDBFS ?? defaultLevel
    }

    func validateForAcquisition() throws {
        try request.validate()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SpeakerMeasurementLabSessionError.invalidProtocol
        }
        if let excitationLevelDBFS {
            guard excitationLevelDBFS.isFinite,
                  (-48.0 ... -12.0).contains(excitationLevelDBFS) else {
                throw SpeakerMeasurementLabSessionError.invalidProtocol
            }
        }
        switch request.mode {
        case .wholeSpeakerOnAxis,
             .wholeSpeakerOffAxis:
            guard acousticSource != nil,
                  nearFieldComponent == nil,
                  coherentPairID == nil,
                  coherentLeg == nil else {
                throw SpeakerMeasurementLabSessionError.invalidProtocol
            }
        case .subwooferNearField:
            guard acousticSource != nil,
                  nearFieldComponent?.validate() ?? true,
                  coherentPairID == nil,
                  coherentLeg == nil else {
                throw SpeakerMeasurementLabSessionError.invalidProtocol
            }
        case .protectedDriverNearField:
            guard protectedDriverBus != nil || protectedRoutedWayID != nil,
                  captureSource != nil,
                  nearFieldComponent == nil,
                  let excitationLevelDBFS,
                  excitationLevelDBFS >= -48.0,
                  excitationLevelDBFS <= -24.0,
                  coherentPairID == nil,
                  coherentLeg == nil else {
                throw SpeakerMeasurementLabSessionError.invalidProtocol
            }
        case .driverNearField:
            // Same driver-safety ceiling as the protected-driver protocol: low explicit level only.
            guard routedWayID != nil,
                  captureSource != nil,
                  nearFieldComponent == nil,
                  let excitationLevelDBFS,
                  excitationLevelDBFS >= -48.0,
                  excitationLevelDBFS <= -24.0,
                  coherentPairID == nil,
                  coherentLeg == nil else {
                throw SpeakerMeasurementLabSessionError.invalidProtocol
            }
        case .coherentMainsSubTiming:
            guard coherentPairID != nil,
                  coherentLeg != nil,
                  captureSource != nil,
                  nearFieldComponent == nil,
                  let excitationLevelDBFS,
                  excitationLevelDBFS.isFinite,
                  (-48.0 ... -12.0).contains(excitationLevelDBFS) else {
                throw SpeakerMeasurementLabSessionError.invalidProtocol
            }
        }
    }
}


struct SpeakerMeasurementLabSharedClockReferenceConfiguration:
    Codable, Equatable, Sendable {
    var inputDeviceUID: String
    var inputChannelIndex: Int
    var outputReferenceDeviceUID: String
    var minimumSNRDB: Double = 35

    func validate(
        microphone: SpeakerOptimizerMicrophoneIdentity,
        sampleRate: Double
    ) -> Bool {
        !inputDeviceUID.isEmpty
            && inputDeviceUID == microphone.deviceUID
            && inputChannelIndex >= 0
            && inputChannelIndex != microphone.inputChannelIndex
            && !outputReferenceDeviceUID.isEmpty
            && minimumSNRDB.isFinite
            && (20...80).contains(minimumSNRDB)
            && sampleRate.isFinite && sampleRate > 0
    }
}

struct SpeakerMeasurementLabSharedClockReferenceEvidence:
    Codable, Equatable, Sendable {
    var inputDeviceUID: String
    var inputChannelIndex: Int
    var outputReferenceDeviceUID: String
    var sampleRate: Double
    var directArrivalSeconds: Double
    var transferFunction: RoomCorrectionFrequencyResponse
    var quality: RoomCorrectionMeasurementQuality

    var sharedTimeOriginQualified: Bool {
        !quality.clipped
            && quality.sweepComplete
            && quality.estimatedSNRDB.map { $0 >= 35 } == true
            && directArrivalSeconds.isFinite
            && directArrivalSeconds >= 0
    }
}

/// Qualifies an electrical/reference channel captured in the SAME IOProc as
/// the microphone. This establishes one per-sweep sample timeline and reference
/// arrival, not absolute DAC/ADC latency and not yet cross-source coherence.
struct SpeakerMeasurementLabSharedClockReferenceEvaluator: Sendable {
    func build(
        analyzed: RoomCorrectionChannelMeasurement,
        configuration:
            SpeakerMeasurementLabSharedClockReferenceConfiguration,
        microphone: SpeakerOptimizerMicrophoneIdentity,
        sampleRate: Double
    ) throws -> SpeakerMeasurementLabSharedClockReferenceEvidence {
        guard configuration.validate(
                  microphone: microphone,
                  sampleRate: sampleRate
              ),
              let response = analyzed.transferFunction,
              let arrival = analyzed.quality.directArrivalSeconds,
              arrival.isFinite, arrival >= 0,
              !analyzed.quality.clipped,
              analyzed.quality.sweepComplete,
              analyzed.quality.estimatedSNRDB.map({
                  $0 >= configuration.minimumSNRDB
              }) == true else {
            throw SpeakerMeasurementLabSessionError
                .sharedClockReferenceUnqualified
        }
        return SpeakerMeasurementLabSharedClockReferenceEvidence(
            inputDeviceUID: configuration.inputDeviceUID,
            inputChannelIndex: configuration.inputChannelIndex,
            outputReferenceDeviceUID:
                configuration.outputReferenceDeviceUID,
            sampleRate: sampleRate,
            directArrivalSeconds: arrival,
            transferFunction: response,
            quality: analyzed.quality
        )
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
    /// Exact sweep-program level used for this capture when known.
    /// Optional preserves decoding of older Lab archives.
    var excitationLevelDBFS: Double? = nil
    var sampleRate: Double
    var source: MultichannelCalibrationSource
    /// Nil for ordinary whole-speaker/sub captures. Protected Low/Mid/High
    /// captures require receipt-like provenance binding the exact route and
    /// production crossover/limiter state used for this repeat.
    var protectedDriverProvenance:
        SpeakerMeasurementLabProtectedDriverCaptureProvenance? = nil
    /// E8 A2b: receipt of a live routed-way capture. Required for the protected routed-way protocol; optional for
    /// stored `driverNearField` captures, and validated when present.
    var routedWayProvenance:
        SpeakerMeasurementLabRoutedWayCaptureProvenance? = nil
    /// Optional simultaneous electrical/shared-time reference evidence.
    /// Nil preserves existing Lab archives and ordinary single-input captures.
    var sharedClockReference:
        SpeakerMeasurementLabSharedClockReferenceEvidence? = nil
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
    /// Optional for backward compatibility with pre-Slice-6 lab archives.
    var microphoneCalibration: RoomCorrectionMicrophoneCalibration? = nil
    /// Optional simultaneous reference-input configuration. Slice 9A permits
    /// collecting qualified reference evidence on ordinary Lab protocols; the
    /// coherent mains/sub protocol remains blocked until paired-source 9B.
    var sharedClockReferenceConfiguration:
        SpeakerMeasurementLabSharedClockReferenceConfiguration? = nil
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
              sharedClockReferenceConfiguration?.validate(
                  microphone: microphone,
                  sampleRate: sampleRate
              ) ?? true,
              !protocols.isEmpty,
              Set(protocols.map(\.id)).count == protocols.count,
              Set(captures.map(\.id)).count == captures.count else {
            throw SpeakerMeasurementLabSessionError.invalidSession
        }

        for labProtocol in protocols {
            try labProtocol.validateForAcquisition()
        }

        let coherentProtocols = protocols.filter {
            $0.request.mode == .coherentMainsSubTiming
        }
        if !coherentProtocols.isEmpty {
            guard sharedClockReferenceConfiguration != nil else {
                throw SpeakerMeasurementLabSessionError
                    .coherentPairInvalid
            }
            let grouped = Dictionary(grouping: coherentProtocols) {
                $0.coherentPairID!
            }
            for (_, pair) in grouped {
                guard pair.count == 2,
                      Set(pair.compactMap(\.coherentLeg))
                        == Set(SpeakerMeasurementLabCoherentLeg.allCases),
                      pair[0].request.target == pair[1].request.target,
                      pair[0].request.geometry == pair[1].request.geometry,
                      pair[0].request.repeatCount
                        == pair[1].request.repeatCount,
                      pair[0].excitationLevelDBFS
                        == pair[1].excitationLevelDBFS else {
                    throw SpeakerMeasurementLabSessionError
                        .coherentPairInvalid
                }
            }
        }

        for capture in captures {
            let captureLevelValid: Bool
            if let level = capture.excitationLevelDBFS {
                captureLevelValid =
                    level.isFinite && level >= -48.0 && level <= -12.0
            } else {
                captureLevelValid = true
            }

            let captureLevelMatchesProtocol: Bool
            if let expected = protocols.first(
                where: { $0.id == capture.protocolID }
            )?.excitationLevelDBFS {
                if let actual = capture.excitationLevelDBFS {
                    captureLevelMatchesProtocol =
                        abs(actual - expected) < 1.0e-6
                } else {
                    captureLevelMatchesProtocol = false
                }
            } else {
                captureLevelMatchesProtocol = true
            }

            guard let labProtocol = protocols.first(
                where: { $0.id == capture.protocolID }
            ),
                  let source = labProtocol.captureSource,
                  capture.source == source,
                  capture.playbackSystemID == playbackSystemID,
                  capture.routingSignature == routingSignature,
                  capture.microphone == microphone,
                  abs(capture.sampleRate - sampleRate) < 0.5,
                  captureLevelValid,
                  captureLevelMatchesProtocol,
                  capture.repeatIndex >= 0,
                  capture.repeatIndex < labProtocol.request.repeatCount,
                  !capture.impulseResponse.isEmpty,
                  capture.impulseResponse.allSatisfy(\.isFinite),
                  valid(response: capture.transferFunction) else {
                throw SpeakerMeasurementLabSessionError
                    .captureIdentityMismatch
            }

            if let bus = labProtocol.protectedDriverBus {
                guard let provenance =
                        capture.protectedDriverProvenance,
                      provenance.validatesProtectedPath(for: bus) else {
                    throw SpeakerMeasurementLabSessionError
                        .captureIdentityMismatch
                }
            } else if capture.protectedDriverProvenance != nil {
                throw SpeakerMeasurementLabSessionError
                    .captureIdentityMismatch
            }

            if let wayID = labProtocol.sweptWayID {
                if let provenance = capture.routedWayProvenance {
                    guard provenance.validates(wayID: wayID) else {
                        throw SpeakerMeasurementLabSessionError
                            .captureIdentityMismatch
                    }
                } else if labProtocol.protectedRoutedWayID != nil {
                    throw SpeakerMeasurementLabSessionError
                        .captureIdentityMismatch
                }
            } else if capture.routedWayProvenance != nil {
                throw SpeakerMeasurementLabSessionError
                    .captureIdentityMismatch
            }

            if let reference = capture.sharedClockReference {
                guard let configuration =
                        sharedClockReferenceConfiguration,
                      reference.inputDeviceUID
                        == configuration.inputDeviceUID,
                      reference.inputChannelIndex
                        == configuration.inputChannelIndex,
                      reference.outputReferenceDeviceUID
                        == configuration.outputReferenceDeviceUID,
                      abs(reference.sampleRate - sampleRate) < 0.5,
                      reference.quality.estimatedSNRDB.map({
                          $0 >= configuration.minimumSNRDB
                      }) == true,
                      reference.sharedTimeOriginQualified else {
                    throw SpeakerMeasurementLabSessionError
                        .captureIdentityMismatch
                }
            } else if sharedClockReferenceConfiguration != nil {
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
            if labProtocol.sweptWayID != nil,
               let first = group.first?.routedWayProvenance {
                guard group.allSatisfy({
                    $0.routedWayProvenance == first
                }) else {
                    throw SpeakerMeasurementLabSessionError
                        .captureSequenceInvalid
                }
            }
            if labProtocol.protectedDriverBus != nil,
               let first = group.first?.protectedDriverProvenance {
                guard group.allSatisfy({
                    $0.protectedDriverProvenance == first
                }) else {
                    throw SpeakerMeasurementLabSessionError
                        .captureSequenceInvalid
                }
            }
        }

        for pairID in Set(
            protocols.compactMap {
                $0.request.mode == .coherentMainsSubTiming
                    ? $0.coherentPairID : nil
            }
        ) {
            let pairProtocols = protocols.filter {
                $0.coherentPairID == pairID
                    && $0.request.mode == .coherentMainsSubTiming
            }
            let pairCaptures = captures.filter { capture in
                pairProtocols.contains {
                    $0.id == capture.protocolID
                }
            }
            if !pairCaptures.isEmpty {
                guard pairCaptures.allSatisfy({
                    $0.sharedClockReference != nil
                }) else {
                    throw SpeakerMeasurementLabSessionError
                        .captureIdentityMismatch
                }
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
    case sharedClockReferenceUnqualified
    case coherentPairInvalid

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
        case .sharedClockReferenceUnqualified:
            return "The simultaneous electrical/reference input did not produce a qualified shared-time reference sweep."
        case .coherentPairInvalid:
            return "Coherent mains/sub acquisition requires exactly one linked Main/Sub protocol pair with identical geometry, repeat count, explicit sweep level, and a configured shared-time reference."
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
        case .protectedDriverNearField:
            let bus = labProtocol.protectedDriverBus?.displayName
                ?? (labProtocol.protectedRoutedWayID != nil
                    ? labProtocol.name : "protected driver")
            return "Place the microphone \(format(geometry.distanceMeters)) m from \(bus). The sweep is pre-rendered through the active crossover and target limiter; keep geometry fixed for \(repeatText)."
        case .driverNearField:
            return "Place the microphone \(format(geometry.distanceMeters)) m from the cone of \(labProtocol.name), close to the dust cap. Only this driver plays, with a sweep limited to its passband; keep geometry fixed for \(repeatText)."
        case .coherentMainsSubTiming:
            let leg = labProtocol.coherentLeg == .main
                ? "main speaker" : "subwoofer"
            return "Keep the microphone fixed at \(format(geometry.distanceMeters)) m and measure the linked \(leg) with the simultaneous electrical reference active; \(repeatText)."
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
              step.labProtocol.captureSource == capture.source,
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
        step: SpeakerMeasurementLabSessionStep,
        excitationLevelDBFS: Double? = nil,
        protectedDriverProvenance:
            SpeakerMeasurementLabProtectedDriverCaptureProvenance? = nil,
        routedWayProvenance:
            SpeakerMeasurementLabRoutedWayCaptureProvenance? = nil,
        sharedClockReference:
            SpeakerMeasurementLabSharedClockReferenceEvidence? = nil
    ) throws -> SpeakerMeasurementLabCapture {
        guard let source = step.labProtocol.captureSource,
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
            excitationLevelDBFS: excitationLevelDBFS,
            sampleRate: session.sampleRate,
            source: source,
            protectedDriverProvenance:
                protectedDriverProvenance,
            routedWayProvenance: routedWayProvenance,
            sharedClockReference: sharedClockReference,
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


    func existingSessionIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
        .sorted { $0.uuidString < $1.uuidString }
    }

    func delete(_ sessionID: UUID) throws {
        let path = url(for: sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
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
