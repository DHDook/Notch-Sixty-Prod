import Foundation

struct MIMORoomTreatmentConfiguration: Equatable, Sendable {
    var minimumFrequencyHz = 20.0
    var maximumFrequencyHz = 150.0
    var frequencyCount = 48
    var regularization = 0.02
    var maximumCoefficientGainDB = 0.0
    var maximumAggregateSourceGainDB = 0.0
    var targetHeadroomDB = 0.0
    var minimumPredictedImprovementDB = 1.0
    var maximumRobustnessDegradationDB = 1.0
    var robustnessMagnitudeFraction = 0.10
    var robustnessPhaseDegrees = 5.0
    var minimumColumnSafetyScale = 0.25

    static let conservative = MIMORoomTreatmentConfiguration()
}

struct MIMORoomTreatmentComplexCoefficient: Equatable, Sendable {
    let real: Double
    let imaginary: Double

    var magnitude: Double {
        hypot(real, imaginary)
    }

    var magnitudeDB: Double {
        20.0 * log10(max(magnitude, 1.0e-15))
    }

    var phaseRadians: Double {
        atan2(imaginary, real)
    }
}

struct MIMORoomTreatmentFrequencyResult: Equatable, Sendable {
    let frequencyHz: Double
    let accepted: Bool
    let targetMagnitudeMean: Double
    let untreatedResidualPower: Double
    let candidateResidualPower: Double
    let candidateImprovementDB: Double
    let worstCaseRelativeDegradationDB: Double
    let maximumCoefficientMagnitude: Double
    let maximumColumnPower: Double
    let minimumAppliedSafetyScale: Double
}

struct MIMORoomTreatmentPlan: Equatable, Sendable {
    let sampleRate: Double
    let sources: [MultichannelCalibrationSource]
    let seatIDs: [UUID]
    let frequenciesHz: [Double]
    let frequencyResults: [MIMORoomTreatmentFrequencyResult]
    /// Frequency-major, source-major, target-major.
    let coefficients: [MIMORoomTreatmentComplexCoefficient]
    let acceptedFrequencyCount: Int

    /// PR73 deliberately produces a review/simulation artifact only.
    var simulationOnly: Bool { true }

    func coefficient(
        frequencyIndex: Int,
        sourceIndex: Int,
        targetIndex: Int
    ) -> MIMORoomTreatmentComplexCoefficient? {
        let sourceCount = sources.count
        guard frequencyIndex >= 0,
              frequencyIndex < frequenciesHz.count,
              sourceIndex >= 0,
              sourceIndex < sourceCount,
              targetIndex >= 0,
              targetIndex < sourceCount else {
            return nil
        }
        let offset =
            (frequencyIndex * sourceCount + sourceIndex) * sourceCount
            + targetIndex
        return coefficients[offset]
    }
}

enum MIMORoomTreatmentDesignError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case invalidFrequencyRange
    case invalidFrequencyCount(Int)
    case invalidSettings
    case noIncludedSeats
    case tooManySeats(Int)
    case noSources
    case tooManySources(Int)
    case duplicateSource(MultichannelCalibrationSource)
    case missingMeasurement(seatID: UUID, source: MultichannelCalibrationSource)
    case sampleRateMismatch(expected: Double, actual: Double)
    case invalidTransferFunction(source: MultichannelCalibrationSource)
    case transferAllocationFailed
    case transferPopulationFailed
    case designFailed

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let value):
            return "MIMO room treatment sample rate \(value) Hz is invalid."
        case .invalidFrequencyRange:
            return "MIMO room treatment requires a finite low-frequency range below Nyquist."
        case .invalidFrequencyCount(let count):
            return "MIMO room treatment frequency count \(count) is unsupported."
        case .invalidSettings:
            return "MIMO room treatment safety/robustness settings are invalid."
        case .noIncludedSeats:
            return "MIMO room treatment requires at least one included weighted seat."
        case .tooManySeats(let count):
            return "MIMO room treatment received \(count) seats; the current bounded designer supports up to \(Int(N60_MIMO_MAX_MEASUREMENTS))."
        case .noSources:
            return "MIMO room treatment requires at least one physical speaker/subwoofer source."
        case .tooManySources(let count):
            return "MIMO room treatment received \(count) sources; the current bounded designer supports up to \(Int(N60_MIMO_MAX_SOURCES))."
        case .duplicateSource(let source):
            return "MIMO room treatment source \(source.displayName) is duplicated."
        case .missingMeasurement(_, let source):
            return "MIMO room treatment is missing a measurement for \(source.displayName)."
        case .sampleRateMismatch(let expected, let actual):
            return "MIMO room treatment expected \(expected) Hz measurement data but found \(actual) Hz."
        case .invalidTransferFunction(let source):
            return "MIMO room treatment measurement for \(source.displayName) lacks a valid complex transfer function."
        case .transferAllocationFailed:
            return "MIMO room treatment could not allocate the bounded transfer matrix."
        case .transferPopulationFailed:
            return "MIMO room treatment could not populate the transfer matrix."
        case .designFailed:
            return "MIMO room treatment could not produce a bounded robust candidate."
        }
    }
}

/// Product-facing PR73 wrapper around the independent PR59 complex MIMO solver.
///
/// This remains strictly offline/simulation-only. It converts the PR58/64
/// source × seat measurements into a bounded low-frequency transfer set, invokes
/// the PR73 robust spatial-equalization policy, and materializes a reviewable
/// candidate matrix. It has no API that can install filters into a live graph.
struct MIMORoomTreatmentDesigner: Sendable {
    func design(
        sources: [MultichannelCalibrationSource],
        seats: [MultichannelCalibrationSeat],
        measurements: [MultichannelCalibrationMeasurement],
        sampleRate: Double,
        configuration: MIMORoomTreatmentConfiguration = .conservative
    ) throws -> MIMORoomTreatmentPlan {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw MIMORoomTreatmentDesignError.invalidSampleRate(sampleRate)
        }
        guard configuration.frequencyCount > 0,
              configuration.frequencyCount <= Int(N60_MIMO_MAX_FREQUENCY_BINS) else {
            throw MIMORoomTreatmentDesignError.invalidFrequencyCount(
                configuration.frequencyCount
            )
        }

        let maximumFrequency = min(
            configuration.maximumFrequencyHz,
            sampleRate * 0.48
        )
        guard configuration.minimumFrequencyHz.isFinite,
              maximumFrequency.isFinite,
              configuration.minimumFrequencyHz >= N60_MIMO_ROOM_TREATMENT_DEFAULT_MIN_HZ,
              configuration.maximumFrequencyHz <= N60_MIMO_ROOM_TREATMENT_DEFAULT_MAX_HZ,
              maximumFrequency > configuration.minimumFrequencyHz else {
            throw MIMORoomTreatmentDesignError.invalidFrequencyRange
        }

        var cSettings = N60MIMORoomTreatmentSettingsMakeDefault()
        cSettings.regularization = configuration.regularization
        cSettings.maximumCoefficientGainDB = configuration.maximumCoefficientGainDB
        cSettings.maximumAggregateSourceGainDB = configuration.maximumAggregateSourceGainDB
        cSettings.targetHeadroomDB = configuration.targetHeadroomDB
        cSettings.minimumPredictedImprovementDB = configuration.minimumPredictedImprovementDB
        cSettings.maximumRobustnessDegradationDB = configuration.maximumRobustnessDegradationDB
        cSettings.robustnessMagnitudeFraction = configuration.robustnessMagnitudeFraction
        cSettings.robustnessPhaseDegrees = configuration.robustnessPhaseDegrees
        cSettings.minimumColumnSafetyScale = configuration.minimumColumnSafetyScale
        guard N60MIMORoomTreatmentSettingsIsValid(cSettings) else {
            throw MIMORoomTreatmentDesignError.invalidSettings
        }

        let includedSeats = seats.filter {
            $0.included && $0.weight.isFinite && $0.weight > 0
        }
        guard !includedSeats.isEmpty else {
            throw MIMORoomTreatmentDesignError.noIncludedSeats
        }
        guard includedSeats.count <= Int(N60_MIMO_MAX_MEASUREMENTS) else {
            throw MIMORoomTreatmentDesignError.tooManySeats(includedSeats.count)
        }

        guard !sources.isEmpty else {
            throw MIMORoomTreatmentDesignError.noSources
        }
        guard sources.count <= Int(N60_MIMO_MAX_SOURCES) else {
            throw MIMORoomTreatmentDesignError.tooManySources(sources.count)
        }
        var uniqueSources = Set<MultichannelCalibrationSource>()
        for source in sources {
            guard uniqueSources.insert(source).inserted else {
                throw MIMORoomTreatmentDesignError.duplicateSource(source)
            }
        }

        let frequencies = Self.logFrequencyGrid(
            minimumHz: configuration.minimumFrequencyHz,
            maximumHz: maximumFrequency,
            count: configuration.frequencyCount
        )
        let frequencyFloats = frequencies.map(Float.init)
        let weights = includedSeats.map { Float($0.weight) }

        let transfer = frequencyFloats.withUnsafeBufferPointer { frequencyBuffer in
            weights.withUnsafeBufferPointer { weightBuffer in
                N60MIMORoomTreatmentTransferSetCreate(
                    sampleRate,
                    UInt32(sources.count),
                    UInt32(includedSeats.count),
                    frequencyBuffer.baseAddress!,
                    UInt32(frequencyBuffer.count),
                    weightBuffer.baseAddress!
                )
            }
        }
        guard let transfer else {
            throw MIMORoomTreatmentDesignError.transferAllocationFailed
        }
        defer { N60MIMORoomTreatmentTransferSetDestroy(transfer) }

        for (seatIndex, seat) in includedSeats.enumerated() {
            for (sourceIndex, source) in sources.enumerated() {
                let measurement = try Self.measurement(
                    seatID: seat.id,
                    source: source,
                    measurements: measurements,
                    expectedSampleRate: sampleRate
                )
                guard let response = measurement.channel.transferFunction,
                      let phases = response.phaseRadians,
                      Self.responseIsValid(response, phases: phases) else {
                    throw MIMORoomTreatmentDesignError.invalidTransferFunction(
                        source: source
                    )
                }

                for (frequencyIndex, frequency) in frequencies.enumerated() {
                    let magnitudeDB = try Self.interpolate(
                        response.magnitudeDB,
                        frequenciesHz: response.frequenciesHz,
                        at: frequency
                    )
                    let phase = try Self.interpolate(
                        phases,
                        frequenciesHz: response.frequenciesHz,
                        at: frequency
                    )
                    let magnitude = pow(10.0, magnitudeDB / 20.0)
                    guard N60MIMORoomTreatmentTransferSetMeasuredPolar(
                        transfer,
                        UInt32(frequencyIndex),
                        UInt32(seatIndex),
                        UInt32(sourceIndex),
                        magnitude,
                        phase
                    ) else {
                        throw MIMORoomTreatmentDesignError.transferPopulationFailed
                    }
                }
            }
        }

        guard N60MIMOTransferSetIsValid(transfer),
              let cDesign = N60MIMORoomTreatmentDesignCreate(
                transfer,
                cSettings
              ) else {
            throw MIMORoomTreatmentDesignError.designFailed
        }
        defer { N60MIMORoomTreatmentDesignDestroy(cDesign) }

        var results: [MIMORoomTreatmentFrequencyResult] = []
        results.reserveCapacity(frequencies.count)
        for (frequencyIndex, frequency) in frequencies.enumerated() {
            let report = N60MIMORoomTreatmentDesignReport(
                cDesign,
                UInt32(frequencyIndex)
            )
            results.append(MIMORoomTreatmentFrequencyResult(
                frequencyHz: frequency,
                accepted: report.accepted,
                targetMagnitudeMean: report.targetMagnitudeMean,
                untreatedResidualPower: report.untreatedResidualPower,
                candidateResidualPower: report.candidateResidualPower,
                candidateImprovementDB: report.candidateImprovementDB,
                worstCaseRelativeDegradationDB: report.worstCaseRelativeDegradationDB,
                maximumCoefficientMagnitude: report.maximumCoefficientMagnitude,
                maximumColumnPower: report.maximumColumnPower,
                minimumAppliedSafetyScale: report.minimumAppliedSafetyScale
            ))
        }

        var coefficients: [MIMORoomTreatmentComplexCoefficient] = []
        coefficients.reserveCapacity(
            frequencies.count * sources.count * sources.count
        )
        for frequencyIndex in frequencies.indices {
            for sourceIndex in sources.indices {
                for targetIndex in sources.indices {
                    let coefficient = N60MIMORoomTreatmentDesignCoefficient(
                        cDesign,
                        UInt32(frequencyIndex),
                        UInt32(sourceIndex),
                        UInt32(targetIndex)
                    )
                    coefficients.append(MIMORoomTreatmentComplexCoefficient(
                        real: coefficient.real,
                        imaginary: coefficient.imaginary
                    ))
                }
            }
        }

        return MIMORoomTreatmentPlan(
            sampleRate: sampleRate,
            sources: sources,
            seatIDs: includedSeats.map(\.id),
            frequenciesHz: frequencies,
            frequencyResults: results,
            coefficients: coefficients,
            acceptedFrequencyCount: results.filter { $0.accepted }.count
        )
    }

    private static func measurement(
        seatID: UUID,
        source: MultichannelCalibrationSource,
        measurements: [MultichannelCalibrationMeasurement],
        expectedSampleRate: Double
    ) throws -> MultichannelCalibrationMeasurement {
        guard let result = measurements.last(where: {
            $0.seatID == seatID && $0.source == source
        }) else {
            throw MIMORoomTreatmentDesignError.missingMeasurement(
                seatID: seatID,
                source: source
            )
        }
        guard result.sampleRate.isFinite,
              abs(result.sampleRate - expectedSampleRate) < 0.5 else {
            throw MIMORoomTreatmentDesignError.sampleRateMismatch(
                expected: expectedSampleRate,
                actual: result.sampleRate
            )
        }
        return result
    }

    private static func responseIsValid(
        _ response: RoomCorrectionFrequencyResponse,
        phases: [Double]
    ) -> Bool {
        let count = response.frequenciesHz.count
        guard count >= 2,
              response.magnitudeDB.count == count,
              phases.count == count else {
            return false
        }

        var previous = 0.0
        for index in 0..<count {
            let frequency = response.frequenciesHz[index]
            guard frequency.isFinite,
                  frequency > previous,
                  response.magnitudeDB[index].isFinite,
                  phases[index].isFinite else {
                return false
            }
            previous = frequency
        }
        return true
    }

    private static func interpolate(
        _ values: [Double],
        frequenciesHz: [Double],
        at frequency: Double
    ) throws -> Double {
        guard values.count == frequenciesHz.count,
              values.count >= 2,
              frequency.isFinite,
              frequency > 0 else {
            throw MIMORoomTreatmentDesignError.invalidFrequencyRange
        }
        if frequency <= frequenciesHz[0] { return values[0] }
        if frequency >= frequenciesHz[frequenciesHz.count - 1] {
            return values[values.count - 1]
        }

        var lower = 0
        var upper = frequenciesHz.count - 1
        while upper - lower > 1 {
            let midpoint = (lower + upper) / 2
            if frequenciesHz[midpoint] <= frequency {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }

        let lowHz = frequenciesHz[lower]
        let highHz = frequenciesHz[upper]
        let denominator = log(highHz / lowHz)
        guard denominator.isFinite, denominator > 0 else {
            throw MIMORoomTreatmentDesignError.invalidFrequencyRange
        }
        let fraction = log(frequency / lowHz) / denominator
        return values[lower] + (values[upper] - values[lower]) * fraction
    }

    private static func logFrequencyGrid(
        minimumHz: Double,
        maximumHz: Double,
        count: Int
    ) -> [Double] {
        guard count > 1 else { return [minimumHz] }
        let ratio = maximumHz / minimumHz
        return (0..<count).map { index in
            minimumHz * pow(
                ratio,
                Double(index) / Double(count - 1)
            )
        }
    }
}
