import Foundation

enum SpeakerOptimizerCharacterizationAxisReference: String, Codable, CaseIterable, Sendable {
    case acousticCenter
    case tweeter
    case manufacturerReference
}

/// Recorded setup for a source-specific near-speaker characterization.
///
/// This is NOT an anechoic or true free-field measurement. The speaker stays
/// in its normal installed location; the shorter path is intended only to make
/// source-persistent behavior easier to distinguish from seat-specific room
/// effects.
struct SpeakerOptimizerCharacterizationGeometry: Codable, Equatable, Sendable {
    static let preferredDistanceMeters = 1.0
    static let minimumDistanceMeters = 0.75
    static let maximumDistanceMeters = 2.0
    static let maximumAxisOffsetDegrees = 10.0

    var distanceMeters: Double = preferredDistanceMeters
    var axisReference: SpeakerOptimizerCharacterizationAxisReference = .acousticCenter
    var horizontalOffsetDegrees: Double = 0
    var verticalOffsetDegrees: Double = 0
    var speakerRemainedInInstalledPosition: Bool = true

    func validate() -> Bool {
        distanceMeters.isFinite
            && (Self.minimumDistanceMeters...Self.maximumDistanceMeters).contains(distanceMeters)
            && horizontalOffsetDegrees.isFinite
            && abs(horizontalOffsetDegrees) <= Self.maximumAxisOffsetDegrees
            && verticalOffsetDegrees.isFinite
            && abs(verticalOffsetDegrees) <= Self.maximumAxisOffsetDegrees
            && speakerRemainedInInstalledPosition
    }
}

struct SpeakerOptimizerCharacterizationTarget: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var source: MultichannelCalibrationSource
    var geometry: SpeakerOptimizerCharacterizationGeometry

    var displayName: String {
        "\(source.displayName) · \(geometry.distanceMeters.formatted(.number.precision(.fractionLength(2)))) m"
    }

    func validate() -> Bool {
        guard case .speaker(let role) = source,
              role != .lowFrequencyEffects else {
            return false
        }
        return geometry.validate()
    }
}

struct SpeakerOptimizerCharacterizationMeasurementSet: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var role: SpeakerOptimizerMeasurementRole = .baseline
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var sampleRate: Double
    var linkedListeningMeasurementSetID: UUID?
    var targets: [SpeakerOptimizerCharacterizationTarget]
    /// Reuses compact PR103 capture evidence. positionID is deliberately the
    /// characterization target ID, preventing seat/near-speaker mixing.
    var captures: [SpeakerOptimizerMeasurementCapture]
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
}

enum SpeakerOptimizerCharacterizationError: Error, Equatable, LocalizedError {
    case invalidSet
    case invalidTarget
    case captureIdentityMismatch
    case captureDoesNotMatchStep
    case invalidRepeatCount(Int)
    case noCaptureToRetry
    case incompatibleListeningEvidence
    case persistenceIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSet:
            return "Speaker characterization measurement metadata is invalid."
        case .invalidTarget:
            return "Speaker characterization geometry or source is invalid."
        case .captureIdentityMismatch:
            return "The characterization capture does not match the campaign playback system, route, microphone, sample rate, or target."
        case .captureDoesNotMatchStep:
            return "The characterization capture does not match the pending speaker/repeat."
        case .invalidRepeatCount(let count):
            return "Speaker characterization requires at least \(SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount) repeats; requested \(count)."
        case .noCaptureToRetry:
            return "No completed characterization capture exists for that speaker."
        case .incompatibleListeningEvidence:
            return "The characterization campaign and listening-position baseline do not share one playback system, route, microphone, sample rate, and optional linked baseline identity."
        case .persistenceIdentityMismatch:
            return "The stored characterization campaign does not match the requested identity."
        }
    }
}

extension SpeakerOptimizerCharacterizationMeasurementSet {
    func validateStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              sampleRate.isFinite, sampleRate > 0,
              !routingSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              microphone.validate(),
              !targets.isEmpty,
              targets.allSatisfy({ $0.validate() }),
              Set(targets.map(\.id)).count == targets.count,
              Set(targets.map(\.source)).count == targets.count,
              Set(captures.map(\.id)).count == captures.count else {
            throw SpeakerOptimizerCharacterizationError.invalidSet
        }
        for capture in captures {
            guard let target = targets.first(where: { $0.id == capture.positionID }),
                  capture.source == target.source,
                  capture.playbackSystemID == playbackSystemID,
                  capture.routingSignature == routingSignature,
                  capture.microphone == microphone,
                  abs(capture.sampleRate - sampleRate) < 0.5 else {
                throw SpeakerOptimizerCharacterizationError.captureIdentityMismatch
            }
        }
    }

    func validateCompatibility(
        with listening: SpeakerOptimizerMeasurementSet
    ) throws {
        try validateStructure()
        try listening.validatePersistenceStructure()
        guard listening.role == .baseline,
              role == .baseline,
              listening.playbackSystemID == playbackSystemID,
              listening.routingSignature == routingSignature,
              listening.microphone == microphone,
              abs(listening.sampleRate - sampleRate) < 0.5,
              linkedListeningMeasurementSetID.map { $0 == listening.id } ?? true else {
            throw SpeakerOptimizerCharacterizationError.incompatibleListeningEvidence
        }
    }
}

struct SpeakerOptimizerCharacterizationGroupReport: Equatable, Sendable {
    var target: SpeakerOptimizerCharacterizationTarget
    var evidence: SpeakerOptimizerMeasurementGroupReport
}

struct SpeakerOptimizerCharacterizationEvidenceReport: Equatable, Sendable {
    var measurementSetID: UUID
    var confidence: Double
    var optimizerReady: Bool
    var groups: [SpeakerOptimizerCharacterizationGroupReport]
    var blockingReasons: [String]
    var warnings: [String]
}

struct SpeakerOptimizerCharacterizationEvidenceEvaluator: Sendable {
    func evaluate(
        _ set: SpeakerOptimizerCharacterizationMeasurementSet
    ) throws -> SpeakerOptimizerCharacterizationEvidenceReport {
        try set.validateStructure()
        var groups: [SpeakerOptimizerCharacterizationGroupReport] = []
        var blockers: [String] = []
        var warnings: [String] = []

        for target in set.targets {
            let position = SpeakerOptimizerMeasurementPosition(
                id: target.id,
                name: target.displayName
            )
            let captures = set.captures.filter {
                $0.positionID == target.id && $0.source == target.source
            }
            let synthetic = SpeakerOptimizerMeasurementSet(
                role: set.role,
                playbackSystemID: set.playbackSystemID,
                routingSignature: set.routingSignature,
                microphone: set.microphone,
                sampleRate: set.sampleRate,
                positions: [position],
                plannedSources: [target.source],
                captures: captures,
                createdAt: set.createdAt,
                modifiedAt: set.modifiedAt
            )
            let report = try SpeakerOptimizerMeasurementEvidenceEvaluator()
                .evaluate(synthetic)
            guard let group = report.groupReports.first else {
                throw SpeakerOptimizerCharacterizationError.invalidSet
            }
            groups.append(SpeakerOptimizerCharacterizationGroupReport(
                target: target,
                evidence: group
            ))
            blockers.append(contentsOf: report.blockingReasons)
            warnings.append(contentsOf: report.warnings)
        }

        let confidence = groups.map(\.evidence.confidence).min() ?? 0
        return SpeakerOptimizerCharacterizationEvidenceReport(
            measurementSetID: set.id,
            confidence: confidence,
            optimizerReady: blockers.isEmpty
                && groups.allSatisfy(\.evidence.optimizerReady),
            groups: groups,
            blockingReasons: blockers,
            warnings: warnings
        )
    }
}

struct SpeakerOptimizerCharacterizationSessionStep: Equatable, Sendable {
    var target: SpeakerOptimizerCharacterizationTarget
    var repeatIndex: Int

    var instruction: String {
        let geometry = target.geometry
        return "Keep \(target.source.displayName) in its installed position. Place the microphone \(geometry.distanceMeters.formatted(.number.precision(.fractionLength(2)))) m away on the \(geometry.axisReference.rawValue) axis and keep it fixed for repeat \(repeatIndex + 1)."
    }
}

struct SpeakerOptimizerCharacterizationProgress: Equatable, Sendable {
    var completedSweepCount: Int
    var requiredSweepCount: Int
    var completedTargetCount: Int
    var requiredTargetCount: Int
    var nextStep: SpeakerOptimizerCharacterizationSessionStep?

    var complete: Bool {
        requiredSweepCount > 0 && completedSweepCount >= requiredSweepCount
    }

    var fractionComplete: Double {
        requiredSweepCount > 0
            ? min(1, max(0, Double(completedSweepCount) / Double(requiredSweepCount)))
            : 0
    }
}

struct SpeakerOptimizerCharacterizationSessionOrchestrator: Sendable {
    let repeatsPerTarget: Int

    init(
        repeatsPerTarget: Int =
            SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount
    ) throws {
        guard repeatsPerTarget
            >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount else {
            throw SpeakerOptimizerCharacterizationError.invalidRepeatCount(
                repeatsPerTarget
            )
        }
        self.repeatsPerTarget = repeatsPerTarget
    }

    func steps(
        for set: SpeakerOptimizerCharacterizationMeasurementSet
    ) throws -> [SpeakerOptimizerCharacterizationSessionStep] {
        try set.validateStructure()
        return set.targets.flatMap { target in
            (0..<repeatsPerTarget).map {
                SpeakerOptimizerCharacterizationSessionStep(
                    target: target,
                    repeatIndex: $0
                )
            }
        }
    }

    func progress(
        for set: SpeakerOptimizerCharacterizationMeasurementSet
    ) throws -> SpeakerOptimizerCharacterizationProgress {
        let all = try steps(for: set)
        var completeTargets = 0
        var completed = 0
        var next: SpeakerOptimizerCharacterizationSessionStep?
        for target in set.targets {
            let count = set.captures.filter {
                $0.positionID == target.id && $0.source == target.source
            }.count
            let bounded = min(count, repeatsPerTarget)
            completed += bounded
            if bounded >= repeatsPerTarget {
                completeTargets += 1
            } else if next == nil {
                next = SpeakerOptimizerCharacterizationSessionStep(
                    target: target,
                    repeatIndex: bounded
                )
            }
        }
        return SpeakerOptimizerCharacterizationProgress(
            completedSweepCount: completed,
            requiredSweepCount: all.count,
            completedTargetCount: completeTargets,
            requiredTargetCount: set.targets.count,
            nextStep: next
        )
    }

    func nextPendingStep(
        for set: SpeakerOptimizerCharacterizationMeasurementSet
    ) throws -> SpeakerOptimizerCharacterizationSessionStep? {
        try progress(for: set).nextStep
    }

    func appending(
        _ capture: SpeakerOptimizerMeasurementCapture,
        to set: SpeakerOptimizerCharacterizationMeasurementSet,
        for step: SpeakerOptimizerCharacterizationSessionStep,
        modifiedAt: Date = Date()
    ) throws -> SpeakerOptimizerCharacterizationMeasurementSet {
        try set.validateStructure()
        guard capture.positionID == step.target.id,
              capture.source == step.target.source else {
            throw SpeakerOptimizerCharacterizationError.captureDoesNotMatchStep
        }
        guard capture.playbackSystemID == set.playbackSystemID,
              capture.routingSignature == set.routingSignature,
              capture.microphone == set.microphone,
              abs(capture.sampleRate - set.sampleRate) < 0.5,
              set.targets.contains(where: { $0.id == step.target.id }),
              !set.captures.contains(where: { $0.id == capture.id }) else {
            throw SpeakerOptimizerCharacterizationError.captureIdentityMismatch
        }
        let current = set.captures.filter {
            $0.positionID == step.target.id && $0.source == step.target.source
        }.count
        guard current == step.repeatIndex, current < repeatsPerTarget else {
            throw SpeakerOptimizerCharacterizationError.captureDoesNotMatchStep
        }
        var updated = set
        updated.captures.append(capture)
        updated.modifiedAt = modifiedAt
        try updated.validateStructure()
        return updated
    }

    func retryLatestCapture(
        in set: SpeakerOptimizerCharacterizationMeasurementSet,
        targetID: UUID,
        modifiedAt: Date = Date()
    ) throws -> SpeakerOptimizerCharacterizationMeasurementSet {
        try set.validateStructure()
        guard let target = set.targets.first(where: { $0.id == targetID }) else {
            throw SpeakerOptimizerCharacterizationError.invalidTarget
        }
        let candidates = set.captures.enumerated().filter {
            $0.element.positionID == target.id
                && $0.element.source == target.source
        }
        guard let latest = candidates.max(by: {
            if $0.element.capturedAt != $1.element.capturedAt {
                return $0.element.capturedAt < $1.element.capturedAt
            }
            return $0.element.id.uuidString < $1.element.id.uuidString
        }) else {
            throw SpeakerOptimizerCharacterizationError.noCaptureToRetry
        }
        var updated = set
        updated.captures.remove(at: latest.offset)
        updated.modifiedAt = modifiedAt
        return updated
    }
}

struct SpeakerOptimizerCharacterizationSetStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    func url(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(id.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    func save(_ set: SpeakerOptimizerCharacterizationMeasurementSet) throws {
        try set.validateStructure()
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(set).write(to: url(for: set.id), options: .atomic)
    }

    func load(_ id: UUID) throws -> SpeakerOptimizerCharacterizationMeasurementSet? {
        let path = url(for: id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let set = try decoder.decode(
            SpeakerOptimizerCharacterizationMeasurementSet.self,
            from: Data(contentsOf: path)
        )
        guard set.id == id else {
            throw SpeakerOptimizerCharacterizationError.persistenceIdentityMismatch
        }
        try set.validateStructure()
        return set
    }

    private static func defaultRootDirectory() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return root
            .appendingPathComponent("Notch Sixty", isDirectory: true)
            .appendingPathComponent(
                "Speaker Optimizer Characterization",
                isDirectory: true
            )
    }
}
