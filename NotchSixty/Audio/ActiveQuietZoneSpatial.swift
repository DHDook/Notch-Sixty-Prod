import Foundation

enum ActiveQuietZoneSpatialError: Error, Equatable, LocalizedError {
    case invalidSurvey
    case inadequatePhaseReference
    case insufficientPositions
    case incompatibleMeasurement
    case mismatchedAnchor
    case unusableSpatialPlant
    case spatialRegression
    case noSpatialBenefit
    case invalidHeadroom
    case calibrationProjectMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSurvey: return "Spatial Quiet Zone requires a finite, frequency-matched phase-referenced noise survey."
        case .inadequatePhaseReference: return "Sequential environmental captures lack a trustworthy common phase reference."
        case .insufficientPositions: return "Use 2–5 included microphone positions for a spatial quiet-area calibration."
        case .incompatibleMeasurement: return "Measurement sample rates, capture quality or acoustic routes are incompatible."
        case .mismatchedAnchor: return "The live error microphone must be at the calibrated anchor position."
        case .unusableSpatialPlant: return "The measured multi-position speaker paths are ill conditioned."
        case .spatialRegression: return "The predicted spatial candidate would worsen a measured seat beyond the allowed limit."
        case .noSpatialBenefit: return "The model does not predict enough distributed low-frequency reduction."
        case .invalidHeadroom: return "The audio path has insufficient safe headroom for this spatial candidate."
        case .calibrationProjectMismatch: return "Spatial calibration belongs to a different room measurement project."
        }
    }
}

struct ActiveQuietZoneSpatialSettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    var minimumCoherence: Double = 0.95
    var maximumPhaseClosureRadians: Double = 0.15
    var maximumFrequencyDriftHz: Double = 0.10
    var maximumPredictedSeatRegressionDB: Double = 0.5
    var minimumWeightedReductionDB: Double = 1.0
    var regularization: Double = 0.06

    func validated() throws -> Self {
        guard minimumCoherence.isFinite, (0.90...1).contains(minimumCoherence),
              maximumPhaseClosureRadians.isFinite,
              (0.01...0.25).contains(maximumPhaseClosureRadians),
              maximumFrequencyDriftHz.isFinite,
              (0.01...0.25).contains(maximumFrequencyDriftHz),
              maximumPredictedSeatRegressionDB.isFinite,
              (0...1).contains(maximumPredictedSeatRegressionDB),
              minimumWeightedReductionDB.isFinite,
              (0.5...3).contains(minimumWeightedReductionDB),
              regularization.isFinite,
              (0.005...0.5).contains(regularization)
        else { throw ActiveQuietZoneSpatialError.invalidSurvey }
        return self
    }
}

struct ActiveQuietZoneSpatialPosition: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var weight: Double
}

/// Complex ratios are referenced to the SAME stationary disturbance phase clock.
/// A regular Room Correction sweep supplies speaker paths, NOT these ratios.
struct ActiveQuietZoneSpatialDisturbance: Codable, Equatable, Sendable {
    var positionID: UUID
    var ratioToAnchor: ActiveQuietZoneComplex
    var coherence: Double
    var phaseClosureRadians: Double
    var frequencyDriftHz: Double
}

struct ActiveQuietZoneSpatialToneSurvey: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var frequencyHz: Double
    var capturedAt: Date
    var commonPhaseReferenceValidated: Bool
    var disturbances: [ActiveQuietZoneSpatialDisturbance]
}

struct ActiveQuietZoneSpatialCalibration: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var version: Int = schemaVersion
    var projectID: UUID
    var playbackSystemID: UUID
    var anchorPositionID: UUID
    var microphoneStableID: String
    var microphoneInputChannelIndex: Int
    var sampleRate: Double
    var positions: [ActiveQuietZoneSpatialPosition]
    var surveys: [ActiveQuietZoneSpatialToneSurvey] = []
    var settings: ActiveQuietZoneSpatialSettings = .init()

    /// Persisted positions and speaker paths may be ready even when no
    /// coherent environmental survey exists. That state is NOT runtime ready.
    func validated(against project: RoomCorrectionProject) throws -> Self {
        guard version == Self.schemaVersion,
              projectID == project.id,
              playbackSystemID == project.playbackSystemID,
              let microphone = project.microphone,
              microphone.stableID == microphoneStableID,
              !microphoneStableID.isEmpty,
              microphone.inputChannelIndex == microphoneInputChannelIndex,
              sampleRate.isFinite, sampleRate > 8_000,
              positions.count >= 2, positions.count <= 5,
              Set(positions.map(\.id)).count == positions.count,
              positions.contains(where: { $0.id == anchorPositionID }),
              positions.allSatisfy({
                  $0.weight.isFinite && $0.weight >= 0.05 && $0.weight <= 1
              })
        else { throw ActiveQuietZoneSpatialError.calibrationProjectMismatch }
        _ = try settings.validated()

        for selected in positions {
            guard let measure = project.measurements.first(where: {
                $0.id == selected.id && $0.included && $0.weight > 0
            }),
                  abs(measure.sampleRate - sampleRate) < 0.5,
                  measurementTrusted(measure)
            else { throw ActiveQuietZoneSpatialError.incompatibleMeasurement }
        }
        guard Set(surveys.map(\.id)).count == surveys.count else {
            throw ActiveQuietZoneSpatialError.invalidSurvey
        }
        for survey in surveys {
            try validateSurvey(survey)
        }
        return self
    }

    func validatedSurvey(for frequencyHz: Double) throws -> ActiveQuietZoneSpatialToneSurvey {
        guard let survey = surveys.min(by: {
            abs($0.frequencyHz - frequencyHz) < abs($1.frequencyHz - frequencyHz)
        }), abs(survey.frequencyHz - frequencyHz) <= settings.maximumFrequencyDriftHz
        else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }
        try validateSurvey(survey)
        return survey
    }

    private func validateSurvey(_ survey: ActiveQuietZoneSpatialToneSurvey) throws {
        guard survey.frequencyHz.isFinite, (20...150).contains(survey.frequencyHz),
              survey.commonPhaseReferenceValidated,
              survey.disturbances.count == positions.count,
              Set(survey.disturbances.map(\.positionID)) == Set(positions.map(\.id))
        else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }
        for item in survey.disturbances {
            guard item.ratioToAnchor.real.isFinite,
                  item.ratioToAnchor.imaginary.isFinite,
                  item.ratioToAnchor.magnitude >= 0.02,
                  item.ratioToAnchor.magnitude <= 30,
                  item.coherence.isFinite,
                  item.coherence >= settings.minimumCoherence,
                  item.coherence <= 1,
                  item.phaseClosureRadians.isFinite,
                  abs(item.phaseClosureRadians) <= settings.maximumPhaseClosureRadians,
                  item.frequencyDriftHz.isFinite,
                  abs(item.frequencyDriftHz) <= settings.maximumFrequencyDriftHz
            else { throw ActiveQuietZoneSpatialError.inadequatePhaseReference }
        }
        guard let anchor = survey.disturbances.first(where: {
            $0.positionID == anchorPositionID
        }), abs(anchor.ratioToAnchor.real - 1) < 0.01,
           abs(anchor.ratioToAnchor.imaginary) < 0.01 else {
            throw ActiveQuietZoneSpatialError.mismatchedAnchor
        }
    }

    private func measurementTrusted(_ position: RoomCorrectionMeasurementPosition) -> Bool {
        guard !position.left.impulseResponse.isEmpty,
              !position.right.impulseResponse.isEmpty else { return false }
        for measurement in [position.left, position.right] {
            guard !measurement.quality.clipped,
                  measurement.quality.sweepComplete,
                  measurement.quality.warnings.isEmpty,
                  let snr = measurement.quality.estimatedSNRDB,
                  snr.isFinite, snr >= 20,
                  measurement.impulseResponse.allSatisfy({ $0.isFinite })
            else { return false }
        }
        return true
    }
}

struct ActiveQuietZoneSpatialSeatPrediction: Equatable, Sendable, Identifiable {
    var positionID: UUID
    var predictedReductionDB: Double
    var beforeMagnitude: Double
    var afterMagnitude: Double
    var id: UUID { positionID }
}

struct ActiveQuietZoneSpatialSolution: Equatable, Sendable {
    var frequencyHz: Double
    var leftOutput: ActiveQuietZoneComplex
    var rightOutput: ActiveQuietZoneComplex
    var weightedReductionDB: Double
    var worstSeatReductionDB: Double
    var predictions: [ActiveQuietZoneSpatialSeatPrediction]
    var appliedScale: Double
}

struct ActiveQuietZoneSpatialPlanner: Sendable {
    private let pr90 = ActiveQuietZonePlanner()

    /// Weighted two-source, N-error-point regularized complex least squares,
    /// with PR90 hard output limits and a modelled per-seat regression gate.
    /// Disturbance phases must share a proven reference. This is a prediction,
    /// not physical multi-seat verification.
    func solve(
        calibration: ActiveQuietZoneSpatialCalibration,
        project: RoomCorrectionProject,
        frequencyHz: Double,
        liveAnchorDisturbance: ActiveQuietZoneComplex,
        availableInjectionPeak: Double,
        quietZoneConfiguration: ActiveQuietZoneConfiguration
    ) throws -> ActiveQuietZoneSpatialSolution {
        let source = try calibration.validated(against: project)
        let survey = try source.validatedSurvey(for: frequencyHz)
        let aqz = try quietZoneConfiguration.validated()
        guard (aqz.minimumFrequencyHz...aqz.maximumFrequencyHz).contains(frequencyHz)
        else { throw ActiveQuietZoneError.invalidFrequency(frequencyHz) }
        guard liveAnchorDisturbance.real.isFinite,
              liveAnchorDisturbance.imaginary.isFinite,
              liveAnchorDisturbance.magnitude > 1.0e-10
        else { throw ActiveQuietZoneSpatialError.invalidSurvey }
        guard availableInjectionPeak.isFinite, availableInjectionPeak > 0
        else { throw ActiveQuietZoneSpatialError.invalidHeadroom }

        struct Seat {
            var id: UUID
            var weight: Double
            var d: ActiveQuietZoneComplex
            var left: ActiveQuietZoneComplex
            var right: ActiveQuietZoneComplex
        }
        let seats: [Seat] = try source.positions.map { position in
            guard let measurement = project.measurements.first(where: {
                $0.id == position.id
            }), let phasor = survey.disturbances.first(where: {
                $0.positionID == position.id
            })
            else { throw ActiveQuietZoneSpatialError.invalidSurvey }
            let left = try pr90.secondaryPath(
                impulseResponse: measurement.left.impulseResponse,
                frequencyHz: frequencyHz,
                sampleRate: measurement.sampleRate)
            let right = try pr90.secondaryPath(
                impulseResponse: measurement.right.impulseResponse,
                frequencyHz: frequencyHz,
                sampleRate: measurement.sampleRate)
            return Seat(id: position.id, weight: position.weight,
                        d: liveAnchorDisturbance * phasor.ratioToAnchor,
                        left: left, right: right)
        }

        let totalWeight = seats.reduce(0.0) { $0 + $1.weight }
        let pathPower = seats.reduce(0.0) {
            $0 + $1.weight * (pow($1.left.magnitude, 2) + pow($1.right.magnitude, 2))
        } / totalWeight
        guard pathPower.isFinite, pathPower > 1.0e-12 else {
            throw ActiveQuietZoneSpatialError.unusableSpatialPlant
        }
        let lambda = max(pathPower * source.settings.regularization, 1.0e-12)
        var a = ActiveQuietZoneComplex(real: lambda, imaginary: 0)
        var b = ActiveQuietZoneComplex.zero
        var d = ActiveQuietZoneComplex(real: lambda, imaginary: 0)
        var y0 = ActiveQuietZoneComplex.zero
        var y1 = ActiveQuietZoneComplex.zero
        for seat in seats {
            let w = seat.weight / totalWeight
            a = a + seat.left.conjugate * seat.left * w
            b = b + seat.left.conjugate * seat.right * w
            d = d + seat.right.conjugate * seat.right * w
            y0 = y0 - seat.left.conjugate * seat.d * w
            y1 = y1 - seat.right.conjugate * seat.d * w
        }
        let det = a * d - b * b.conjugate
        guard det.magnitude.isFinite, det.magnitude > 1.0e-18,
              a.magnitude.isFinite, d.magnitude.isFinite
        else { throw ActiveQuietZoneSpatialError.unusableSpatialPlant }
        var leftOutput = (d * y0 - b * y1) / det
        var rightOutput = (a * y1 - b.conjugate * y0) / det
        guard leftOutput.real.isFinite, leftOutput.imaginary.isFinite,
              rightOutput.real.isFinite, rightOutput.imaginary.isFinite
        else { throw ActiveQuietZoneSpatialError.unusableSpatialPlant }

        let perSource = pow(10, aqz.maximumPerSourceTonePeakDBFS / 20)
        let aggregate = pow(10, aqz.maximumAggregateSourcePeakDBFS / 20)
        let maximum = min(perSource, aggregate, availableInjectionPeak)
        guard maximum > 0 else { throw ActiveQuietZoneSpatialError.invalidHeadroom }
        let fullMagnitude = max(leftOutput.magnitude, rightOutput.magnitude)
        let hardScale = fullMagnitude > maximum ? maximum / fullMagnitude : 1.0
        leftOutput = leftOutput * hardScale
        rightOutput = rightOutput * hardScale

        func metrics(scale: Double) -> (Double, Double, [ActiveQuietZoneSpatialSeatPrediction]) {
            var weightedBefore = 0.0
            var weightedAfter = 0.0
            var worst = Double.infinity
            var predictions: [ActiveQuietZoneSpatialSeatPrediction] = []
            for seat in seats {
                let after = seat.d
                    + seat.left * leftOutput * scale
                    + seat.right * rightOutput * scale
                let beforePower = pow(seat.d.magnitude, 2)
                let afterPower = pow(after.magnitude, 2)
                weightedBefore += seat.weight * beforePower
                weightedAfter += seat.weight * afterPower
                let reduction = 10 * log10(max(beforePower, 1.0e-24)
                    / max(afterPower, 1.0e-24))
                worst = min(worst, reduction)
                predictions.append(ActiveQuietZoneSpatialSeatPrediction(
                    positionID: seat.id, predictedReductionDB: reduction,
                    beforeMagnitude: seat.d.magnitude, afterMagnitude: after.magnitude))
            }
            return (10 * log10(max(weightedBefore, 1.0e-24) / max(weightedAfter, 1.0e-24)),
                    worst, predictions)
        }

        // The trust gate MUST include every position; no averaging away a
        // potentially harmful seat. Search for a bounded non-regressing scale.
        var accepted: (Double, Double, Double, [ActiveQuietZoneSpatialSeatPrediction])?
        for index in stride(from: 100, through: 1, by: -1) {
            let factor = Double(index) / 100
            let (weighted, worst, predictions) = metrics(scale: factor)
            if worst >= -source.settings.maximumPredictedSeatRegressionDB,
               weighted >= source.settings.minimumWeightedReductionDB {
                accepted = (factor, weighted, worst, predictions)
                break
            }
        }
        guard let accepted else {
            throw ActiveQuietZoneSpatialError.noSpatialBenefit
        }

        // Reduce injection if a lower coefficient reaches the configured
        // target while satisfying spatial non-regression and minimum benefit.
        var chosen = accepted
        for index in stride(from: Int((accepted.0 * 100).rounded()) - 1,
                            through: 1, by: -1) {
            let factor = Double(index) / 100
            let (weighted, worst, predictions) = metrics(scale: factor)
            if weighted >= min(aqz.targetReductionDB, accepted.1),
               worst >= -source.settings.maximumPredictedSeatRegressionDB,
               weighted >= source.settings.minimumWeightedReductionDB {
                chosen = (factor, weighted, worst, predictions)
            }
        }
        return ActiveQuietZoneSpatialSolution(
            frequencyHz: frequencyHz,
            leftOutput: leftOutput * chosen.0,
            rightOutput: rightOutput * chosen.0,
            weightedReductionDB: chosen.1,
            worstSeatReductionDB: chosen.2,
            predictions: chosen.3,
            appliedScale: hardScale * chosen.0
        )
    }

    func spatialInjectionEnvelope(
        project: RoomCorrectionProject,
        positionIDs: [UUID],
        anchorID: UUID,
        frequencyHz: Double,
        candidateLeft: ActiveQuietZoneComplex,
        candidateRight: ActiveQuietZoneComplex
    ) throws -> [UUID: Double] {
        guard positionIDs.contains(anchorID), positionIDs.count >= 2 else {
            throw ActiveQuietZoneSpatialError.insufficientPositions
        }
        var results: [UUID: Double] = [:]
        for id in positionIDs {
            guard let measurement = project.measurements.first(where: { $0.id == id }),
                  measurement.included else {
                throw ActiveQuietZoneSpatialError.incompatibleMeasurement
            }
            let left = try pr90.secondaryPath(
                impulseResponse: measurement.left.impulseResponse,
                frequencyHz: frequencyHz, sampleRate: measurement.sampleRate)
            let right = try pr90.secondaryPath(
                impulseResponse: measurement.right.impulseResponse,
                frequencyHz: frequencyHz, sampleRate: measurement.sampleRate)
            results[id] = (left * candidateLeft + right * candidateRight).magnitude
        }
        return results
    }
}

struct ActiveQuietZoneSpatialStore: Sendable {
    var roomStore: RoomCorrectionProjectStore

    func url(for projectID: UUID) -> URL {
        roomStore.projectDirectory(for: projectID)
            .appendingPathComponent("active-quiet-zone-spatial-v1.json")
    }

    func load(for project: RoomCorrectionProject) throws -> ActiveQuietZoneSpatialCalibration? {
        let path = url(for: project.id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let decoded = try JSONDecoder().decode(
            ActiveQuietZoneSpatialCalibration.self, from: Data(contentsOf: path))
        return try decoded.validated(against: project)
    }

    func save(_ calibration: ActiveQuietZoneSpatialCalibration,
              for project: RoomCorrectionProject) throws {
        let valid = try calibration.validated(against: project)
        let dir = roomStore.projectDirectory(for: project.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(valid).write(to: url(for: project.id), options: .atomic)
    }
}
