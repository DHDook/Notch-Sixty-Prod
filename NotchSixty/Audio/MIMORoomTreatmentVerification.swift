import Foundation

struct MIMORoomTreatmentVerificationConfiguration: Equatable, Sendable {
    var minimumFrequencyHz = 20.0
    var maximumFrequencyHz = 150.0
    var frequencyCount = 32
    var minimumSpatialRMSErrorImprovementDB = 0.50
    var maximumAbsoluteMeanLevelShiftDB = 1.50
    var maximumWorstSeatErrorIncreaseDB = 1.50
    var maximumTreatedSpatialRMSErrorDB = 4.0

    static let conservative = MIMORoomTreatmentVerificationConfiguration()
}

struct MIMORoomTreatmentSourceSafetyDeclaration: Equatable, Sendable {
    let source: MultichannelCalibrationSource
    let safeMinimumFrequencyHz: Double
    let safeMaximumFrequencyHz: Double
    let reservedHeadroomDB: Double
    let excursionModelConfirmed: Bool
    let thermalModelConfirmed: Bool
    let finalProtectionChainConfirmed: Bool

    func validate(requiredLowHz: Double, requiredHighHz: Double) -> Bool {
        safeMinimumFrequencyHz.isFinite
            && safeMinimumFrequencyHz > 0
            && safeMaximumFrequencyHz.isFinite
            && safeMaximumFrequencyHz > safeMinimumFrequencyHz
            && safeMinimumFrequencyHz <= requiredLowHz
            && safeMaximumFrequencyHz >= requiredHighHz
            && reservedHeadroomDB.isFinite
            && reservedHeadroomDB >= 3.0
            && excursionModelConfirmed
            && thermalModelConfirmed
            && finalProtectionChainConfirmed
    }
}

struct MIMORoomTreatmentSourceVerification: Equatable, Sendable {
    let source: MultichannelCalibrationSource
    let baselineSpatialRMSErrorDB: Double
    let treatedSpatialRMSErrorDB: Double
    let spatialRMSErrorImprovementDB: Double
    let maximumAbsoluteMeanLevelShiftDB: Double
    let worstSeatErrorIncreaseDB: Double
}

struct MIMORoomTreatmentVerificationReport: Equatable, Sendable {
    let sampleRate: Double
    let seatIDs: [UUID]
    let sources: [MultichannelCalibrationSource]
    let frequenciesHz: [Double]
    let sourceReports: [MIMORoomTreatmentSourceVerification]
    let baselineSpatialRMSErrorDB: Double
    let treatedSpatialRMSErrorDB: Double
    let spatialRMSErrorImprovementDB: Double
    let maximumAbsoluteMeanLevelShiftDB: Double
    let worstSeatErrorIncreaseDB: Double
    let accepted: Bool
}

enum MIMORoomTreatmentVerificationError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case invalidConfiguration
    case noIncludedSeats
    case noSources
    case missingMeasurement(
        phase: String,
        seatID: UUID,
        source: MultichannelCalibrationSource
    )
    case sampleRateMismatch(expected: Double, actual: Double)
    case invalidTransferFunction(
        phase: String,
        source: MultichannelCalibrationSource
    )

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let rate):
            return "Room-treatment verification sample rate \(rate) Hz is invalid."
        case .invalidConfiguration:
            return "Room-treatment verification thresholds are invalid."
        case .noIncludedSeats:
            return "Room-treatment verification requires at least one weighted seat."
        case .noSources:
            return "Room-treatment verification requires at least one treatment source."
        case .missingMeasurement(let phase, _, let source):
            return "Room-treatment \(phase) measurements are missing \(source.displayName)."
        case .sampleRateMismatch(let expected, let actual):
            return "Room-treatment verification expected \(expected) Hz but found \(actual) Hz."
        case .invalidTransferFunction(let phase, let source):
            return "Room-treatment \(phase) measurement for \(source.displayName) has no usable transfer magnitude."
        }
    }
}

/// Offline repeat-measurement verifier.
///
/// Baseline spatial targets are the weighted mean level for each source at each
/// frequency. The treated measurement is scored both for seat-to-seat uniformity
/// and against the original baseline mean so that a candidate cannot appear to
/// improve simply by shifting overall level.
///
/// This type does not install or arm a treatment program.
struct MIMORoomTreatmentVerifier: Sendable {
    func verify(
        sources: [MultichannelCalibrationSource],
        seats: [MultichannelCalibrationSeat],
        baselineMeasurements: [MultichannelCalibrationMeasurement],
        treatedMeasurements: [MultichannelCalibrationMeasurement],
        sampleRate: Double,
        configuration: MIMORoomTreatmentVerificationConfiguration = .conservative
    ) throws -> MIMORoomTreatmentVerificationReport {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw MIMORoomTreatmentVerificationError.invalidSampleRate(sampleRate)
        }
        guard configuration.minimumFrequencyHz.isFinite,
              configuration.maximumFrequencyHz.isFinite,
              configuration.minimumFrequencyHz >= 20,
              configuration.maximumFrequencyHz <= 150,
              configuration.maximumFrequencyHz > configuration.minimumFrequencyHz,
              configuration.frequencyCount >= 8,
              configuration.frequencyCount <= 128,
              configuration.minimumSpatialRMSErrorImprovementDB.isFinite,
              configuration.minimumSpatialRMSErrorImprovementDB >= 0,
              configuration.maximumAbsoluteMeanLevelShiftDB.isFinite,
              configuration.maximumAbsoluteMeanLevelShiftDB >= 0,
              configuration.maximumWorstSeatErrorIncreaseDB.isFinite,
              configuration.maximumWorstSeatErrorIncreaseDB >= 0,
              configuration.maximumTreatedSpatialRMSErrorDB.isFinite,
              configuration.maximumTreatedSpatialRMSErrorDB >= 0 else {
            throw MIMORoomTreatmentVerificationError.invalidConfiguration
        }

        let includedSeats = seats.filter {
            $0.included && $0.weight.isFinite && $0.weight > 0
        }
        guard !includedSeats.isEmpty else {
            throw MIMORoomTreatmentVerificationError.noIncludedSeats
        }
        guard !sources.isEmpty else {
            throw MIMORoomTreatmentVerificationError.noSources
        }

        let frequencies = Self.logFrequencyGrid(
            minimumHz: configuration.minimumFrequencyHz,
            maximumHz: configuration.maximumFrequencyHz,
            count: configuration.frequencyCount
        )
        let totalSeatWeight = includedSeats.reduce(0.0) { $0 + $1.weight }

        var sourceReports: [MIMORoomTreatmentSourceVerification] = []
        sourceReports.reserveCapacity(sources.count)

        var aggregateBaselineSquared = 0.0
        var aggregateTreatedSquared = 0.0
        var aggregatePointCount = 0
        var globalMaxMeanShift = 0.0
        var globalWorstSeatIncrease = 0.0

        for source in sources {
            var sourceBaselineSquared = 0.0
            var sourceTreatedSquared = 0.0
            var sourcePointCount = 0
            var sourceMaxMeanShift = 0.0
            var sourceWorstSeatIncrease = 0.0

            let baselineResponses = try includedSeats.map { seat in
                try Self.response(
                    phase: "baseline",
                    seat: seat,
                    source: source,
                    measurements: baselineMeasurements,
                    sampleRate: sampleRate
                )
            }
            let treatedResponses = try includedSeats.map { seat in
                try Self.response(
                    phase: "treated",
                    seat: seat,
                    source: source,
                    measurements: treatedMeasurements,
                    sampleRate: sampleRate
                )
            }

            for frequency in frequencies {
                var baselineLevels: [Double] = []
                var treatedLevels: [Double] = []
                baselineLevels.reserveCapacity(includedSeats.count)
                treatedLevels.reserveCapacity(includedSeats.count)

                for seatIndex in includedSeats.indices {
                    baselineLevels.append(
                        try Self.interpolateMagnitudeDB(
                            baselineResponses[seatIndex],
                            at: frequency
                        )
                    )
                    treatedLevels.append(
                        try Self.interpolateMagnitudeDB(
                            treatedResponses[seatIndex],
                            at: frequency
                        )
                    )
                }

                let baselineMean = zip(includedSeats, baselineLevels).reduce(0.0) {
                    $0 + $1.0.weight * $1.1
                } / totalSeatWeight
                let treatedMean = zip(includedSeats, treatedLevels).reduce(0.0) {
                    $0 + $1.0.weight * $1.1
                } / totalSeatWeight
                let meanShift = abs(treatedMean - baselineMean)
                sourceMaxMeanShift = max(sourceMaxMeanShift, meanShift)
                globalMaxMeanShift = max(globalMaxMeanShift, meanShift)

                for seatIndex in includedSeats.indices {
                    let weight = includedSeats[seatIndex].weight / totalSeatWeight
                    let baselineError = baselineLevels[seatIndex] - baselineMean
                    let treatedUniformityError = treatedLevels[seatIndex] - treatedMean
                    let treatedTargetError = treatedLevels[seatIndex] - baselineMean
                    let seatErrorIncrease =
                        abs(treatedTargetError) - abs(baselineError)

                    sourceBaselineSquared += weight * baselineError * baselineError
                    sourceTreatedSquared +=
                        weight * treatedUniformityError * treatedUniformityError
                    aggregateBaselineSquared +=
                        weight * baselineError * baselineError
                    aggregateTreatedSquared +=
                        weight * treatedUniformityError * treatedUniformityError

                    sourceWorstSeatIncrease = max(
                        sourceWorstSeatIncrease,
                        seatErrorIncrease
                    )
                    globalWorstSeatIncrease = max(
                        globalWorstSeatIncrease,
                        seatErrorIncrease
                    )
                }

                sourcePointCount += 1
                aggregatePointCount += 1
            }

            let baselineRMS = sqrt(
                sourceBaselineSquared / Double(max(sourcePointCount, 1))
            )
            let treatedRMS = sqrt(
                sourceTreatedSquared / Double(max(sourcePointCount, 1))
            )
            sourceReports.append(MIMORoomTreatmentSourceVerification(
                source: source,
                baselineSpatialRMSErrorDB: baselineRMS,
                treatedSpatialRMSErrorDB: treatedRMS,
                spatialRMSErrorImprovementDB: baselineRMS - treatedRMS,
                maximumAbsoluteMeanLevelShiftDB: sourceMaxMeanShift,
                worstSeatErrorIncreaseDB: sourceWorstSeatIncrease
            ))
        }

        let baselineRMS = sqrt(
            aggregateBaselineSquared / Double(max(aggregatePointCount, 1))
        )
        let treatedRMS = sqrt(
            aggregateTreatedSquared / Double(max(aggregatePointCount, 1))
        )
        let improvement = baselineRMS - treatedRMS
        let accepted =
            improvement >= configuration.minimumSpatialRMSErrorImprovementDB
            && treatedRMS <= configuration.maximumTreatedSpatialRMSErrorDB
            && globalMaxMeanShift <= configuration.maximumAbsoluteMeanLevelShiftDB
            && globalWorstSeatIncrease <= configuration.maximumWorstSeatErrorIncreaseDB

        return MIMORoomTreatmentVerificationReport(
            sampleRate: sampleRate,
            seatIDs: includedSeats.map(\.id),
            sources: sources,
            frequenciesHz: frequencies,
            sourceReports: sourceReports,
            baselineSpatialRMSErrorDB: baselineRMS,
            treatedSpatialRMSErrorDB: treatedRMS,
            spatialRMSErrorImprovementDB: improvement,
            maximumAbsoluteMeanLevelShiftDB: globalMaxMeanShift,
            worstSeatErrorIncreaseDB: globalWorstSeatIncrease,
            accepted: accepted
        )
    }

    private static func response(
        phase: String,
        seat: MultichannelCalibrationSeat,
        source: MultichannelCalibrationSource,
        measurements: [MultichannelCalibrationMeasurement],
        sampleRate: Double
    ) throws -> RoomCorrectionFrequencyResponse {
        guard let measurement = measurements.last(where: {
            $0.seatID == seat.id && $0.source == source
        }) else {
            throw MIMORoomTreatmentVerificationError.missingMeasurement(
                phase: phase,
                seatID: seat.id,
                source: source
            )
        }
        guard measurement.sampleRate.isFinite,
              abs(measurement.sampleRate - sampleRate) < 0.5 else {
            throw MIMORoomTreatmentVerificationError.sampleRateMismatch(
                expected: sampleRate,
                actual: measurement.sampleRate
            )
        }
        guard let response = measurement.channel.transferFunction,
              response.frequenciesHz.count >= 2,
              response.magnitudeDB.count == response.frequenciesHz.count,
              response.frequenciesHz.allSatisfy(\.isFinite),
              response.magnitudeDB.allSatisfy(\.isFinite) else {
            throw MIMORoomTreatmentVerificationError.invalidTransferFunction(
                phase: phase,
                source: source
            )
        }
        return response
    }

    private static func interpolateMagnitudeDB(
        _ response: RoomCorrectionFrequencyResponse,
        at frequency: Double
    ) throws -> Double {
        let frequencies = response.frequenciesHz
        let values = response.magnitudeDB
        guard frequencies.count == values.count,
              frequencies.count >= 2,
              frequency.isFinite,
              frequency > 0 else {
            throw MIMORoomTreatmentVerificationError.invalidConfiguration
        }
        if frequency <= frequencies[0] { return values[0] }
        if frequency >= frequencies[frequencies.count - 1] {
            return values[values.count - 1]
        }

        var lower = 0
        var upper = frequencies.count - 1
        while upper - lower > 1 {
            let midpoint = (lower + upper) / 2
            if frequencies[midpoint] <= frequency {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        let lowHz = frequencies[lower]
        let highHz = frequencies[upper]
        guard lowHz > 0, highHz > lowHz else {
            throw MIMORoomTreatmentVerificationError.invalidConfiguration
        }
        let fraction =
            log(frequency / lowHz) / log(highHz / lowHz)
        return values[lower] + (values[upper] - values[lower]) * fraction
    }

    private static func logFrequencyGrid(
        minimumHz: Double,
        maximumHz: Double,
        count: Int
    ) -> [Double] {
        let ratio = maximumHz / minimumHz
        return (0..<count).map { index in
            minimumHz * pow(
                ratio,
                Double(index) / Double(count - 1)
            )
        }
    }
}

struct MIMORoomTreatmentHardwareAcceptance: Equatable, Sendable {
    let confirmedAt: Date
    let sourceCount: Int
    let sampleRate: Double
    let longRunThermalPassed: Bool
    let protectionChainPassed: Bool
    let stopStartPassed: Bool
    let unplugReplugPassed: Bool
    let sleepWakePassed: Bool
    let audibleArtifactCheckPassed: Bool

    var isComplete: Bool {
        sourceCount > 0
            && sampleRate.isFinite
            && sampleRate > 0
            && longRunThermalPassed
            && protectionChainPassed
            && stopStartPassed
            && unplugReplugPassed
            && sleepWakePassed
            && audibleArtifactCheckPassed
    }
}

enum MIMORoomTreatmentDeploymentGateStatus: String, Equatable, Sendable {
    case blockedBySourceSafety
    case repeatMeasurementRequired
    case repeatMeasurementFailed
    case hardwareAcceptanceRequired
    case eligibleForFutureLiveIntegration
}

struct MIMORoomTreatmentDeploymentGateResult: Equatable, Sendable {
    let status: MIMORoomTreatmentDeploymentGateStatus
    let blockingReasons: [String]
}

/// PR75 readiness gate. This can declare a candidate eligible for a future live
/// integration PR, but it cannot activate audio and exposes no render-graph API.
struct MIMORoomTreatmentDeploymentGate: Sendable {
    func evaluate(
        firProgram: MIMORoomTreatmentFIRProgram,
        sourceSafety: [MIMORoomTreatmentSourceSafetyDeclaration],
        verification: MIMORoomTreatmentVerificationReport?,
        hardwareAcceptance: MIMORoomTreatmentHardwareAcceptance?
    ) -> MIMORoomTreatmentDeploymentGateResult {
        let low = 20.0
        let high = 150.0
        var reasons: [String] = []

        if sourceSafety.count != firProgram.sources.count {
            reasons.append("Every treatment source needs one safety declaration.")
        }
        for source in firProgram.sources {
            guard let declaration = sourceSafety.first(where: {
                $0.source == source
            }) else {
                reasons.append("Missing safety declaration for \(source.displayName).")
                continue
            }
            if !declaration.validate(requiredLowHz: low, requiredHighHz: high) {
                reasons.append("Safety declaration for \(source.displayName) is incomplete or outside the treatment band.")
            }
        }
        if Set(sourceSafety.map(\.source)).count != sourceSafety.count {
            reasons.append("Treatment source safety declarations contain duplicates.")
        }
        if !reasons.isEmpty {
            return MIMORoomTreatmentDeploymentGateResult(
                status: .blockedBySourceSafety,
                blockingReasons: reasons
            )
        }

        guard let verification else {
            return MIMORoomTreatmentDeploymentGateResult(
                status: .repeatMeasurementRequired,
                blockingReasons: ["A treated repeat-measurement verification is required."]
            )
        }
        guard verification.accepted,
              verification.sources == firProgram.sources,
              abs(verification.sampleRate - firProgram.sampleRate) < 0.5 else {
            return MIMORoomTreatmentDeploymentGateResult(
                status: .repeatMeasurementFailed,
                blockingReasons: ["Repeat measurement did not satisfy the PR75 verification gate."]
            )
        }

        guard let hardwareAcceptance,
              hardwareAcceptance.isComplete,
              hardwareAcceptance.sourceCount == firProgram.sources.count,
              abs(hardwareAcceptance.sampleRate - firProgram.sampleRate) < 0.5 else {
            return MIMORoomTreatmentDeploymentGateResult(
                status: .hardwareAcceptanceRequired,
                blockingReasons: ["Real-Mac hardware/acoustic acceptance is still required."]
            )
        }

        return MIMORoomTreatmentDeploymentGateResult(
            status: .eligibleForFutureLiveIntegration,
            blockingReasons: []
        )
    }
}
