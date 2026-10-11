import Foundation

enum SpeakerOptimizerMeasurementRole: String, Codable, CaseIterable, Sendable {
    case baseline
    case candidate
    case verification
}

struct SpeakerOptimizerMicrophoneIdentity: Codable, Equatable, Hashable, Sendable {
    var deviceUID: String
    var inputChannelIndex: Int
    var calibrationFingerprint: String?

    func validate() -> Bool {
        !deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inputChannelIndex >= 0
            && calibrationFingerprint.map {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? true
    }
}

struct SpeakerOptimizerMeasurementPosition: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String

    func validate() -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Compact analyzed evidence for one repeated sweep.
///
/// Raw captured sweep samples are intentionally excluded. The existing
/// measurement analyzer owns deconvolution; Speaker Optimizer persists only
/// the response and quality metadata needed for repeatability/confidence.
struct SpeakerOptimizerMeasurementCapture: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var capturedAt: Date
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var positionID: UUID
    var source: MultichannelCalibrationSource
    var sampleRate: Double
    var response: RoomCorrectionFrequencyResponse
    var quality: RoomCorrectionMeasurementQuality

    init(
        id: UUID = UUID(),
        capturedAt: Date,
        playbackSystemID: UUID,
        routingSignature: String,
        microphone: SpeakerOptimizerMicrophoneIdentity,
        positionID: UUID,
        source: MultichannelCalibrationSource,
        sampleRate: Double,
        response: RoomCorrectionFrequencyResponse,
        quality: RoomCorrectionMeasurementQuality
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.playbackSystemID = playbackSystemID
        self.routingSignature = routingSignature
        self.microphone = microphone
        self.positionID = positionID
        self.source = source
        self.sampleRate = sampleRate
        self.response = response
        self.quality = quality
    }

    init(
        compacting measurement: MultichannelCalibrationMeasurement,
        playbackSystemID: UUID,
        routingSignature: String,
        microphone: SpeakerOptimizerMicrophoneIdentity
    ) throws {
        guard let response = measurement.channel.transferFunction else {
            throw SpeakerOptimizerMeasurementEvidenceError.missingTransferFunction(
                captureID: measurement.id
            )
        }
        self.init(
            id: measurement.id,
            capturedAt: measurement.channel.capturedAt,
            playbackSystemID: playbackSystemID,
            routingSignature: routingSignature,
            microphone: microphone,
            positionID: measurement.seatID,
            source: measurement.source,
            sampleRate: measurement.sampleRate,
            response: response,
            quality: measurement.channel.quality
        )
    }
}

struct SpeakerOptimizerMeasurementSet: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var role: SpeakerOptimizerMeasurementRole
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var sampleRate: Double
    var positions: [SpeakerOptimizerMeasurementPosition]
    var plannedSources: [MultichannelCalibrationSource]
    var captures: [SpeakerOptimizerMeasurementCapture]
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
}

enum SpeakerOptimizerMeasurementEvidenceError: Error, Equatable, LocalizedError {
    case invalidMeasurementSet
    case duplicatePositionID
    case duplicateCaptureID
    case duplicatePlannedSource
    case missingTransferFunction(captureID: UUID)

    var errorDescription: String? {
        switch self {
        case .invalidMeasurementSet:
            return "Speaker Optimizer measurement-set metadata is invalid."
        case .duplicatePositionID:
            return "Speaker Optimizer measurement positions must have unique identifiers."
        case .duplicateCaptureID:
            return "Speaker Optimizer repeated captures must have unique identifiers."
        case .duplicatePlannedSource:
            return "Speaker Optimizer planned sources must be unique."
        case .missingTransferFunction(let captureID):
            return "Speaker Optimizer capture \(captureID.uuidString) has no analyzed transfer function."
        }
    }
}

struct SpeakerOptimizerMeasurementGroupReport: Codable, Equatable, Sendable {
    var positionID: UUID
    var source: MultichannelCalibrationSource
    var repeatCount: Int
    var minimumSNRDB: Double?
    var magnitudeRepeatabilityRMSDB: Double?
    var arrivalSpreadMilliseconds: Double?
    /// Circular agreement of bulk-delay-removed phase across repeated sweeps.
    /// This is inter-repeat phase consistency in [0, 1], not conventional
    /// magnitude-squared coherence.
    var phaseConsistency: Double?
    var commonUsableLowHz: Double?
    var commonUsableHighHz: Double?
    var confidence: Double
    var optimizerReady: Bool
    var blockingReasons: [String]
    var warnings: [String]
}

struct SpeakerOptimizerMeasurementEvidenceReport: Codable, Equatable, Sendable {
    var measurementSetID: UUID
    var role: SpeakerOptimizerMeasurementRole
    var groupReports: [SpeakerOptimizerMeasurementGroupReport]
    var confidence: Double
    var optimizerReady: Bool
    var blockingReasons: [String]
    var warnings: [String]
}

struct SpeakerOptimizerMeasurementEvidenceEvaluator: Sendable {
    /// PR86 already treats captures below 30 dB SNR as insufficient for
    /// calibration prediction. Speaker Optimizer intentionally inherits that
    /// conservative evidence floor instead of introducing a weaker one.
    static let minimumSNRDB = 30.0

    /// Three independent captures is the minimum needed to detect one-off
    /// variation without pretending a single A/B pair is repeatability.
    static let minimumRepeatCount = 3

    /// Initial software qualification defaults. These bound repeated captures
    /// made without moving the microphone. Physical acceptance may tighten them
    /// later, but remote CI must not relax them.
    static let maximumMagnitudeRepeatabilityRMSDB = 1.5
    static let maximumArrivalSpreadMilliseconds = 0.5
    static let minimumPhaseConsistency = 0.80
    static let minimumCommonResponsePointCount = 16
    static let minimumOptimizerConfidence = 0.50

    func evaluate(
        _ set: SpeakerOptimizerMeasurementSet
    ) throws -> SpeakerOptimizerMeasurementEvidenceReport {
        try validateSet(set)

        var reports: [SpeakerOptimizerMeasurementGroupReport] = []
        reports.reserveCapacity(set.positions.count * set.plannedSources.count)

        for position in set.positions {
            for source in set.plannedSources {
                let captures = set.captures
                    .filter { $0.positionID == position.id && $0.source == source }
                    .sorted {
                        if $0.capturedAt != $1.capturedAt {
                            return $0.capturedAt < $1.capturedAt
                        }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                reports.append(
                    evaluateGroup(
                        captures,
                        set: set,
                        position: position,
                        source: source
                    )
                )
            }
        }

        var blockingReasons: [String] = []
        var warnings: [String] = []
        for report in reports {
            let prefix = "\(positionName(report.positionID, in: set)) · \(report.source.displayName): "
            blockingReasons.append(contentsOf: report.blockingReasons.map { prefix + $0 })
            warnings.append(contentsOf: report.warnings.map { prefix + $0 })
        }

        let confidence = reports.map(\.confidence).min() ?? 0
        let ready = !reports.isEmpty
            && reports.allSatisfy(\.optimizerReady)
            && confidence >= Self.minimumOptimizerConfidence

        if !reports.isEmpty,
           reports.allSatisfy(\.optimizerReady),
           confidence < Self.minimumOptimizerConfidence {
            blockingReasons.append(
                "Overall measurement confidence \(format(confidence)) is below the optimizer minimum \(format(Self.minimumOptimizerConfidence))."
            )
        }

        return SpeakerOptimizerMeasurementEvidenceReport(
            measurementSetID: set.id,
            role: set.role,
            groupReports: reports,
            confidence: confidence,
            optimizerReady: ready,
            blockingReasons: blockingReasons,
            warnings: warnings
        )
    }

    private func validateSet(_ set: SpeakerOptimizerMeasurementSet) throws {
        guard set.schemaVersion == SpeakerOptimizerMeasurementSet.currentSchemaVersion,
              set.sampleRate.isFinite,
              set.sampleRate > 0,
              !set.routingSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              set.microphone.validate(),
              !set.positions.isEmpty,
              set.positions.allSatisfy({ $0.validate() }),
              !set.plannedSources.isEmpty else {
            throw SpeakerOptimizerMeasurementEvidenceError.invalidMeasurementSet
        }
        guard Set(set.positions.map(\.id)).count == set.positions.count else {
            throw SpeakerOptimizerMeasurementEvidenceError.duplicatePositionID
        }
        guard Set(set.captures.map(\.id)).count == set.captures.count else {
            throw SpeakerOptimizerMeasurementEvidenceError.duplicateCaptureID
        }
        guard Set(set.plannedSources).count == set.plannedSources.count else {
            throw SpeakerOptimizerMeasurementEvidenceError.duplicatePlannedSource
        }
    }

    private func evaluateGroup(
        _ captures: [SpeakerOptimizerMeasurementCapture],
        set: SpeakerOptimizerMeasurementSet,
        position: SpeakerOptimizerMeasurementPosition,
        source: MultichannelCalibrationSource
    ) -> SpeakerOptimizerMeasurementGroupReport {
        var blockers: [String] = []
        var warnings: [String] = []

        if captures.count < Self.minimumRepeatCount {
            blockers.append(
                "Needs at least \(Self.minimumRepeatCount) repeated sweeps; only \(captures.count) are available."
            )
        }

        let identityMismatch = captures.contains {
            $0.playbackSystemID != set.playbackSystemID
                || $0.routingSignature != set.routingSignature
                || $0.microphone != set.microphone
                || abs($0.sampleRate - set.sampleRate) >= 0.5
                || $0.positionID != position.id
                || $0.source != source
        }
        if identityMismatch {
            blockers.append(
                "Capture identity changed across playback routing, microphone, sample rate, position, or source."
            )
        }

        let invalidQuality = captures.contains { capture in
            capture.quality.clipped
                || !capture.quality.sweepComplete
                || !qualityIsFinite(capture.quality)
        }
        if invalidQuality {
            blockers.append("At least one repeated sweep is clipped, incomplete, or has invalid quality metadata.")
        }

        let snrs = captures.compactMap(\.quality.estimatedSNRDB)
        let minimumSNR = snrs.min()
        if snrs.count != captures.count {
            blockers.append("Every repeated sweep needs an SNR estimate.")
        } else if let minimumSNR, minimumSNR < Self.minimumSNRDB {
            blockers.append(
                "Minimum repeated-sweep SNR \(format(minimumSNR)) dB is below \(format(Self.minimumSNRDB)) dB."
            )
        }

        let arrivals = captures.compactMap(\.quality.directArrivalSeconds)
        let arrivalSpreadMs: Double?
        if arrivals.count == captures.count, let minimum = arrivals.min(), let maximum = arrivals.max() {
            arrivalSpreadMs = (maximum - minimum) * 1_000
            if let arrivalSpreadMs,
               arrivalSpreadMs > Self.maximumArrivalSpreadMilliseconds {
                blockers.append(
                    "Direct-arrival spread \(format(arrivalSpreadMs)) ms exceeds \(format(Self.maximumArrivalSpreadMilliseconds)) ms."
                )
            }
        } else {
            arrivalSpreadMs = nil
            blockers.append("Every repeated sweep needs a direct-arrival estimate.")
        }

        let commonLow = captures.compactMap(\.quality.usableLowHz).max()
        let commonHigh = captures.compactMap(\.quality.usableHighHz).min()
        let usableRangeValid = commonLow.map { $0.isFinite } == true
            && commonHigh.map { $0.isFinite } == true
            && (commonLow ?? 0) > 0
            && (commonHigh ?? 0) > (commonLow ?? .infinity)
        if !usableRangeValid {
            blockers.append("Repeated sweeps do not share a valid usable frequency range.")
        }

        let responseValidation = validateResponses(
            captures,
            commonLowHz: commonLow,
            commonHighHz: commonHigh
        )
        blockers.append(contentsOf: responseValidation.blockingReasons)
        warnings.append(contentsOf: responseValidation.warnings)

        if let repeatability = responseValidation.magnitudeRepeatabilityRMSDB,
           repeatability > Self.maximumMagnitudeRepeatabilityRMSDB {
            blockers.append(
                "Magnitude repeatability RMS \(format(repeatability)) dB exceeds \(format(Self.maximumMagnitudeRepeatabilityRMSDB)) dB."
            )
        }

        if let phaseConsistency = responseValidation.phaseConsistency {
            if phaseConsistency < Self.minimumPhaseConsistency {
                blockers.append(
                    "Inter-repeat phase consistency \(format(phaseConsistency)) is below \(format(Self.minimumPhaseConsistency))."
                )
            }
        } else if !captures.isEmpty {
            blockers.append("Every repeated sweep needs phase evidence for optimizer qualification.")
        }

        for warning in captures.flatMap({ $0.quality.warnings }) where !warnings.contains(warning) {
            warnings.append(warning)
        }

        let snrScore = minimumSNR.map(scoreSNR) ?? 0
        let magnitudeScore = responseValidation.magnitudeRepeatabilityRMSDB
            .map { descendingScore($0, threshold: Self.maximumMagnitudeRepeatabilityRMSDB) } ?? 0
        let timingScore = arrivalSpreadMs
            .map { descendingScore($0, threshold: Self.maximumArrivalSpreadMilliseconds) } ?? 0
        let phaseScore = responseValidation.phaseConsistency ?? 0
        let repeatScore = min(
            1,
            Double(captures.count) / Double(Self.minimumRepeatCount)
        )
        let confidence = min(
            repeatScore,
            snrScore,
            magnitudeScore,
            timingScore,
            phaseScore
        )
        let ready = blockers.isEmpty
            && confidence >= Self.minimumOptimizerConfidence

        return SpeakerOptimizerMeasurementGroupReport(
            positionID: position.id,
            source: source,
            repeatCount: captures.count,
            minimumSNRDB: minimumSNR,
            magnitudeRepeatabilityRMSDB: responseValidation.magnitudeRepeatabilityRMSDB,
            arrivalSpreadMilliseconds: arrivalSpreadMs,
            phaseConsistency: responseValidation.phaseConsistency,
            commonUsableLowHz: commonLow,
            commonUsableHighHz: commonHigh,
            confidence: confidence,
            optimizerReady: ready,
            blockingReasons: blockers,
            warnings: warnings
        )
    }

    private struct ResponseValidation {
        var magnitudeRepeatabilityRMSDB: Double?
        var phaseConsistency: Double?
        var blockingReasons: [String]
        var warnings: [String]
    }

    private func validateResponses(
        _ captures: [SpeakerOptimizerMeasurementCapture],
        commonLowHz: Double?,
        commonHighHz: Double?
    ) -> ResponseValidation {
        guard let first = captures.first else {
            return ResponseValidation(
                magnitudeRepeatabilityRMSDB: nil,
                phaseConsistency: nil,
                blockingReasons: ["No analyzed repeated sweeps are available."],
                warnings: []
            )
        }

        let reference = first.response
        guard responseIsStructurallyValid(reference) else {
            return ResponseValidation(
                magnitudeRepeatabilityRMSDB: nil,
                phaseConsistency: nil,
                blockingReasons: ["An analyzed response is structurally invalid."],
                warnings: []
            )
        }

        for capture in captures.dropFirst() {
            guard responseIsStructurallyValid(capture.response),
                  frequencyGridsMatch(reference.frequenciesHz, capture.response.frequenciesHz) else {
                return ResponseValidation(
                    magnitudeRepeatabilityRMSDB: nil,
                    phaseConsistency: nil,
                    blockingReasons: ["Repeated sweeps must share one finite, strictly increasing frequency grid."],
                    warnings: []
                )
            }
        }

        guard let low = commonLowHz,
              let high = commonHighHz,
              low.isFinite,
              high.isFinite,
              high > low else {
            return ResponseValidation(
                magnitudeRepeatabilityRMSDB: nil,
                phaseConsistency: nil,
                blockingReasons: [],
                warnings: []
            )
        }

        let indices = reference.frequenciesHz.indices.filter {
            reference.frequenciesHz[$0] >= low && reference.frequenciesHz[$0] <= high
        }
        guard indices.count >= Self.minimumCommonResponsePointCount else {
            return ResponseValidation(
                magnitudeRepeatabilityRMSDB: nil,
                phaseConsistency: nil,
                blockingReasons: [
                    "Common usable bandwidth contains only \(indices.count) response points; at least \(Self.minimumCommonResponsePointCount) are required."
                ],
                warnings: []
            )
        }

        var residualSquareSum = 0.0
        var residualCount = 0
        for index in indices {
            let values = captures.map { $0.response.magnitudeDB[index] }
            let mean = values.reduce(0, +) / Double(values.count)
            for value in values {
                let residual = value - mean
                residualSquareSum += residual * residual
                residualCount += 1
            }
        }
        let repeatability = residualCount > 0
            ? sqrt(residualSquareSum / Double(residualCount))
            : nil

        let allHavePhase = captures.allSatisfy {
            guard let phase = $0.response.phaseRadians else { return false }
            return phase.count == $0.response.frequenciesHz.count
                && phase.allSatisfy(\.isFinite)
        }
        let phaseConsistency: Double?
        if allHavePhase {
            var consistencySum = 0.0
            for index in indices {
                var real = 0.0
                var imaginary = 0.0
                for capture in captures {
                    let phase = capture.response.phaseRadians![index]
                    real += cos(phase)
                    imaginary += sin(phase)
                }
                consistencySum += hypot(real, imaginary) / Double(captures.count)
            }
            phaseConsistency = consistencySum / Double(indices.count)
        } else {
            phaseConsistency = nil
        }

        return ResponseValidation(
            magnitudeRepeatabilityRMSDB: repeatability,
            phaseConsistency: phaseConsistency,
            blockingReasons: [],
            warnings: []
        )
    }

    private func responseIsStructurallyValid(
        _ response: RoomCorrectionFrequencyResponse
    ) -> Bool {
        guard response.frequenciesHz.count >= Self.minimumCommonResponsePointCount,
              response.frequenciesHz.count == response.magnitudeDB.count,
              response.frequenciesHz.allSatisfy({ $0.isFinite && $0 > 0 }),
              response.magnitudeDB.allSatisfy(\.isFinite) else {
            return false
        }
        for index in response.frequenciesHz.indices.dropFirst() {
            if response.frequenciesHz[index] <= response.frequenciesHz[index - 1] {
                return false
            }
        }
        return true
    }

    private func frequencyGridsMatch(
        _ lhs: [Double],
        _ rhs: [Double]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices {
            let tolerance = max(1.0e-6, abs(lhs[index]) * 1.0e-9)
            if abs(lhs[index] - rhs[index]) > tolerance {
                return false
            }
        }
        return true
    }

    private func qualityIsFinite(
        _ quality: RoomCorrectionMeasurementQuality
    ) -> Bool {
        let values = [
            quality.playbackPeakDBFS,
            quality.capturePeakDBFS,
            quality.estimatedNoiseFloorDBFS,
            quality.estimatedSNRDB,
            quality.directArrivalSeconds,
            quality.usableLowHz,
            quality.usableHighHz,
        ]
        return values.allSatisfy { value in
            value.map { $0.isFinite } ?? true
        }
    }

    private func scoreSNR(_ snrDB: Double) -> Double {
        guard snrDB.isFinite else { return 0 }
        if snrDB >= Self.minimumSNRDB {
            return min(
                1,
                0.5 + 0.5 * ((snrDB - Self.minimumSNRDB) / 20)
            )
        }
        return max(
            0,
            0.5 * snrDB / Self.minimumSNRDB
        )
    }

    private func descendingScore(
        _ value: Double,
        threshold: Double
    ) -> Double {
        guard value.isFinite, value >= 0, threshold > 0 else { return 0 }
        return max(0, min(1, 1 - 0.5 * value / threshold))
    }

    private func positionName(
        _ id: UUID,
        in set: SpeakerOptimizerMeasurementSet
    ) -> String {
        set.positions.first(where: { $0.id == id })?.name ?? id.uuidString
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}


enum SpeakerOptimizerMeasurementExcitationTarget: Equatable, Sendable {
    /// Whole acoustic source already supported by the existing targeted
    /// multichannel calibration transport.
    case acousticSource(MultichannelCalibrationSource)

    /// Logical active-crossover/driver bus. PR103 deliberately models this
    /// target but does not send a raw full-band sweep to its physical channel.
    case protectedDriverBus(SpeakerOutputBus)
}

enum SpeakerOptimizerMeasurementTransportBlockReason: Equatable, Sendable {
    case protectedDriverPathRequired(SpeakerOutputBus)
    case activeCrossoverRoutingPresent
    case configuredLimiterWouldBeBypassed
    case physicalRouteUnavailable(String)

    var message: String {
        switch self {
        case .protectedDriverPathRequired(let bus):
            return "\(bus.displayName) requires a crossover-preserving protected driver measurement path."
        case .activeCrossoverRoutingPresent:
            return "Existing targeted calibration cannot be reused while active split-driver routing is present because it writes directly to physical output lanes."
        case .configuredLimiterWouldBeBypassed:
            return "Existing targeted calibration cannot be reused while per-driver limiter protection is configured because the direct measurement path would bypass it."
        case .physicalRouteUnavailable(let source):
            return "No unique targeted physical output is available for \(source)."
        }
    }
}

struct SpeakerOptimizerMeasurementTransportPlan: Equatable, Sendable {
    var target: SpeakerOptimizerMeasurementExcitationTarget
    var physicalOutputChannelIndex: UInt32?
    var usesExistingTargetedCalibrationTransport: Bool
    var preservesMandatoryProtection: Bool
    var blockReason: SpeakerOptimizerMeasurementTransportBlockReason?

    var canStartMeasurement: Bool {
        usesExistingTargetedCalibrationTransport
            && preservesMandatoryProtection
            && physicalOutputChannelIndex != nil
            && blockReason == nil
    }
}

/// Fail-closed adapter between Speaker Optimizer measurement intent and the
/// existing targeted multichannel calibration transport.
///
/// Important: MultichannelCalibrationTransport writes its precomputed sweep
/// directly to one physical output lane. That is safe for an ordinary whole
/// speaker/sub target only when no active split-driver routing or configured
/// per-driver limiter would be bypassed. Protected Low/Mid/High driver buses
/// are explicitly blocked until a later slice provides a crossover-preserving
/// excitation path.
struct SpeakerOptimizerMeasurementTransportPlanner: Sendable {
    func plan(
        target: SpeakerOptimizerMeasurementExcitationTarget,
        routePlan: LiveNChannelOutputRoutePlan,
        multiOutputRouting: MultiOutputRoutingConfiguration?,
        speakerDriverProcessing: SpeakerDriverProcessingConfiguration?
    ) -> SpeakerOptimizerMeasurementTransportPlan {
        switch target {
        case .protectedDriverBus(let bus):
            return blocked(
                target: target,
                reason: .protectedDriverPathRequired(bus)
            )

        case .acousticSource(let source):
            if let routing = multiOutputRouting,
               routing.enabled,
               routing.enabledRoutes.contains(where: { !$0.bus.isFullRangeBus }) {
                return blocked(
                    target: target,
                    reason: .activeCrossoverRoutingPresent
                )
            }

            if let driverProcessing = speakerDriverProcessing,
               driverProcessing.buses.contains(where: {
                   $0.enabled && $0.limiterEnabled
               }) {
                return blocked(
                    target: target,
                    reason: .configuredLimiterWouldBeBypassed
                )
            }

            guard let channel = physicalOutputChannel(
                for: source,
                routePlan: routePlan
            ) else {
                return blocked(
                    target: target,
                    reason: .physicalRouteUnavailable(source.displayName)
                )
            }

            return SpeakerOptimizerMeasurementTransportPlan(
                target: target,
                physicalOutputChannelIndex: channel,
                usesExistingTargetedCalibrationTransport: true,
                preservesMandatoryProtection: true,
                blockReason: nil
            )
        }
    }

    private func physicalOutputChannel(
        for source: MultichannelCalibrationSource,
        routePlan: LiveNChannelOutputRoutePlan
    ) -> UInt32? {
        let channel: UInt32
        switch source {
        case .speaker(let role):
            guard role != .lowFrequencyEffects,
                  let index = routePlan.programLayout.roles.firstIndex(of: role),
                  index < routePlan.programPhysicalChannels.count else {
                return nil
            }
            channel = routePlan.programPhysicalChannels[index]

        case .subwoofer(let index):
            guard Int(index) < routePlan.subwooferPhysicalChannels.count else {
                return nil
            }
            channel = routePlan.subwooferPhysicalChannels[Int(index)]
        }

        guard channel != UInt32.max,
              channel < routePlan.physicalChannelCount else {
            return nil
        }
        return channel
    }

    private func blocked(
        target: SpeakerOptimizerMeasurementExcitationTarget,
        reason: SpeakerOptimizerMeasurementTransportBlockReason
    ) -> SpeakerOptimizerMeasurementTransportPlan {
        SpeakerOptimizerMeasurementTransportPlan(
            target: target,
            physicalOutputChannelIndex: nil,
            usesExistingTargetedCalibrationTransport: false,
            preservesMandatoryProtection: false,
            blockReason: reason
        )
    }
}


enum SpeakerOptimizerMeasurementSessionError: Error, Equatable, LocalizedError {
    case invalidRepeatCount(Int)
    case noPendingStep
    case captureDoesNotMatchStep
    case captureIdentityMismatch
    case noCaptureToRetry
    case persistenceInvalid
    case persistenceIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidRepeatCount(let count):
            return "Speaker Optimizer requires at least \(SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount) repeats; requested \(count)."
        case .noPendingStep:
            return "The Speaker Optimizer measurement session has no pending sweep."
        case .captureDoesNotMatchStep:
            return "The analyzed capture does not match the pending Speaker Optimizer position/source step."
        case .captureIdentityMismatch:
            return "The analyzed capture does not match the session playback system, routing, microphone, or sample rate."
        case .noCaptureToRetry:
            return "There is no completed capture for this Speaker Optimizer position/source to retry."
        case .persistenceInvalid:
            return "The saved Speaker Optimizer measurement set is structurally invalid."
        case .persistenceIdentityMismatch:
            return "The saved Speaker Optimizer measurement set does not match the requested measurement-set identity."
        }
    }
}

struct SpeakerOptimizerMeasurementSessionStep: Equatable, Sendable {
    var position: SpeakerOptimizerMeasurementPosition
    var source: MultichannelCalibrationSource
    /// Zero-based repeat ordinal for this exact position/source pair.
    var repeatIndex: Int

    var displayName: String {
        "\(position.name) · \(source.displayName) · Repeat \(repeatIndex + 1)"
    }
}

struct SpeakerOptimizerMeasurementSessionProgress: Equatable, Sendable {
    var completedSweepCount: Int
    var requiredSweepCount: Int
    var completedPositionSourceGroups: Int
    var requiredPositionSourceGroups: Int
    var nextStep: SpeakerOptimizerMeasurementSessionStep?

    var fractionComplete: Double {
        guard requiredSweepCount > 0 else { return 0 }
        return min(max(Double(completedSweepCount) / Double(requiredSweepCount), 0), 1)
    }

    var complete: Bool {
        requiredSweepCount > 0 && completedSweepCount >= requiredSweepCount
    }
}

extension SpeakerOptimizerMeasurementSet {
    func validatePersistenceStructure() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              sampleRate.isFinite,
              sampleRate > 0,
              !routingSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              microphone.validate(),
              !positions.isEmpty,
              positions.allSatisfy({ $0.validate() }),
              !plannedSources.isEmpty,
              Set(positions.map(\.id)).count == positions.count,
              Set(captures.map(\.id)).count == captures.count,
              Set(plannedSources).count == plannedSources.count else {
            throw SpeakerOptimizerMeasurementSessionError.persistenceInvalid
        }

        for capture in captures {
            guard capture.playbackSystemID == playbackSystemID,
                  capture.routingSignature == routingSignature,
                  capture.microphone == microphone,
                  abs(capture.sampleRate - sampleRate) < 0.5,
                  positions.contains(where: { $0.id == capture.positionID }),
                  plannedSources.contains(capture.source) else {
                throw SpeakerOptimizerMeasurementSessionError.persistenceInvalid
            }
        }
    }
}

/// Deterministic, persistence-derived session orchestration.
///
/// There is no hidden "current step" stored separately. Progress is derived from
/// compact analyzed captures, so an interrupted app/session resumes at the first
/// incomplete position/source repeat after reload.
struct SpeakerOptimizerMeasurementSessionOrchestrator: Sendable {
    let repeatsPerPositionSource: Int

    init(
        repeatsPerPositionSource: Int =
            SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount
    ) throws {
        guard repeatsPerPositionSource
            >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount else {
            throw SpeakerOptimizerMeasurementSessionError.invalidRepeatCount(
                repeatsPerPositionSource
            )
        }
        self.repeatsPerPositionSource = repeatsPerPositionSource
    }

    func steps(
        for set: SpeakerOptimizerMeasurementSet
    ) throws -> [SpeakerOptimizerMeasurementSessionStep] {
        try set.validatePersistenceStructure()
        var result: [SpeakerOptimizerMeasurementSessionStep] = []
        result.reserveCapacity(
            set.positions.count
                * set.plannedSources.count
                * repeatsPerPositionSource
        )

        // Position-major ordering intentionally minimizes microphone moves.
        for position in set.positions {
            for source in set.plannedSources {
                for repeatIndex in 0..<repeatsPerPositionSource {
                    result.append(
                        SpeakerOptimizerMeasurementSessionStep(
                            position: position,
                            source: source,
                            repeatIndex: repeatIndex
                        )
                    )
                }
            }
        }
        return result
    }

    func progress(
        for set: SpeakerOptimizerMeasurementSet
    ) throws -> SpeakerOptimizerMeasurementSessionProgress {
        let allSteps = try steps(for: set)
        var completedSweeps = 0
        var completedGroups = 0
        var next: SpeakerOptimizerMeasurementSessionStep?

        for position in set.positions {
            for source in set.plannedSources {
                let count = set.captures.filter {
                    $0.positionID == position.id && $0.source == source
                }.count
                let bounded = min(count, repeatsPerPositionSource)
                completedSweeps += bounded
                if bounded >= repeatsPerPositionSource {
                    completedGroups += 1
                } else if next == nil {
                    next = SpeakerOptimizerMeasurementSessionStep(
                        position: position,
                        source: source,
                        repeatIndex: bounded
                    )
                }
            }
        }

        return SpeakerOptimizerMeasurementSessionProgress(
            completedSweepCount: completedSweeps,
            requiredSweepCount: allSteps.count,
            completedPositionSourceGroups: completedGroups,
            requiredPositionSourceGroups:
                set.positions.count * set.plannedSources.count,
            nextStep: next
        )
    }

    func nextPendingStep(
        for set: SpeakerOptimizerMeasurementSet
    ) throws -> SpeakerOptimizerMeasurementSessionStep? {
        try progress(for: set).nextStep
    }

    func appending(
        _ capture: SpeakerOptimizerMeasurementCapture,
        to set: SpeakerOptimizerMeasurementSet,
        for step: SpeakerOptimizerMeasurementSessionStep,
        modifiedAt: Date = Date()
    ) throws -> SpeakerOptimizerMeasurementSet {
        try set.validatePersistenceStructure()
        guard step.position.id == capture.positionID,
              step.source == capture.source else {
            throw SpeakerOptimizerMeasurementSessionError.captureDoesNotMatchStep
        }
        guard capture.playbackSystemID == set.playbackSystemID,
              capture.routingSignature == set.routingSignature,
              capture.microphone == set.microphone,
              abs(capture.sampleRate - set.sampleRate) < 0.5 else {
            throw SpeakerOptimizerMeasurementSessionError.captureIdentityMismatch
        }
        guard set.positions.contains(where: { $0.id == step.position.id }),
              set.plannedSources.contains(step.source) else {
            throw SpeakerOptimizerMeasurementSessionError.captureDoesNotMatchStep
        }

        let currentCount = set.captures.filter {
            $0.positionID == step.position.id && $0.source == step.source
        }.count
        guard currentCount == step.repeatIndex,
              currentCount < repeatsPerPositionSource else {
            throw SpeakerOptimizerMeasurementSessionError.captureDoesNotMatchStep
        }
        guard !set.captures.contains(where: { $0.id == capture.id }) else {
            throw SpeakerOptimizerMeasurementSessionError.captureDoesNotMatchStep
        }

        var updated = set
        updated.captures.append(capture)
        updated.modifiedAt = modifiedAt
        try updated.validatePersistenceStructure()
        return updated
    }

    /// Explicit retry semantics for a completed repeat: remove the most recent
    /// analyzed capture from one position/source group. The derived next step
    /// then becomes that repeat again.
    func retryLatestCapture(
        in set: SpeakerOptimizerMeasurementSet,
        positionID: UUID,
        source: MultichannelCalibrationSource,
        modifiedAt: Date = Date()
    ) throws -> SpeakerOptimizerMeasurementSet {
        try set.validatePersistenceStructure()
        let candidates = set.captures.enumerated()
            .filter {
                $0.element.positionID == positionID
                    && $0.element.source == source
            }
        guard let latest = candidates.max(by: {
            if $0.element.capturedAt != $1.element.capturedAt {
                return $0.element.capturedAt < $1.element.capturedAt
            }
            return $0.element.id.uuidString < $1.element.id.uuidString
        }) else {
            throw SpeakerOptimizerMeasurementSessionError.noCaptureToRetry
        }

        var updated = set
        updated.captures.remove(at: latest.offset)
        updated.modifiedAt = modifiedAt
        return updated
    }
}

struct SpeakerOptimizerMeasurementSetStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    func url(for measurementSetID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(measurementSetID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    func save(_ set: SpeakerOptimizerMeasurementSet) throws {
        try set.validatePersistenceStructure()
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(set).write(
            to: url(for: set.id),
            options: .atomic
        )
    }

    func load(_ measurementSetID: UUID) throws -> SpeakerOptimizerMeasurementSet? {
        let path = url(for: measurementSetID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let set = try decoder.decode(
            SpeakerOptimizerMeasurementSet.self,
            from: data
        )
        guard set.id == measurementSetID else {
            throw SpeakerOptimizerMeasurementSessionError
                .persistenceIdentityMismatch
        }
        try set.validatePersistenceStructure()
        return set
    }

    func delete(_ measurementSetID: UUID) throws {
        let path = url(for: measurementSetID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return
        }
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
                "Speaker Optimizer Measurements",
                isDirectory: true
            )
    }
}
