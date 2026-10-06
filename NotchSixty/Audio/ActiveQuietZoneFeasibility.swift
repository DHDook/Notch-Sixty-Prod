import Foundation

struct ActiveQuietZoneReferenceObservation: Equatable, Sendable {
    let referenceID: String
    let errorMicrophoneID: String
    /// Positive frames mean the reference microphone observes the disturbance
    /// before the same disturbance reaches the error microphone.
    let referenceLeadFrames: Double
    let frequenciesHz: [Double]
    let magnitudeSquaredCoherence: [Double]
}

struct ActiveQuietZoneSecondaryPath: Equatable, Sendable {
    let actuator: MultichannelCalibrationSource
    let errorMicrophoneID: String
    /// Digital actuator command -> acoustic arrival at the error microphone.
    let commandToErrorArrivalFrames: Double
    /// Reserved level/effort margin after normal program + protection planning.
    let reservedHeadroomDB: Double
}

struct ActiveQuietZoneFeasibilityConfiguration: Equatable, Sendable {
    var minimumFrequencyHz = 20.0
    var requestedMaximumFrequencyHz = 150.0
    /// Reference sample available to digital actuator command. This must include
    /// all capture buffering, scheduling, controller/block and output staging
    /// that precedes the measured secondary acoustic path.
    var referenceToActuatorProcessingLatencyFrames = 64.0
    var causalitySafetyMarginFrames = 32.0
    var marginalExtraCausalityFrames = 32.0
    var timingJitterFrames = 4.0
    var maximumTimingPhaseUncertaintyDegrees = 20.0
    var quietZoneRadiusMeters = 0.45
    var speedOfSoundMetersPerSecond = 343.0
    var minimumMagnitudeSquaredCoherence = 0.80
    var marginalCoherenceReserve = 0.05
    var minimumActuatorHeadroomDB = 6.0
    var marginalHeadroomReserveDB = 1.5
    var coherenceGridCount = 96

    static let conservative = ActiveQuietZoneFeasibilityConfiguration()
}

enum ActiveQuietZonePairFailure: String, Equatable, Sendable {
    case none
    case insufficientReferenceLead
    case insufficientCoherence
    case insufficientActuatorHeadroom
}

struct ActiveQuietZonePairFeasibility: Equatable, Sendable {
    let errorMicrophoneID: String
    let actuator: MultichannelCalibrationSource
    let referenceID: String
    let causalityMarginFrames: Double
    let causalityMarginMilliseconds: Double
    let coherenceFloor: Double
    let coherenceLimitedMaximumHz: Double
    let reservedHeadroomDB: Double
    let recommendedMaximumHz: Double
    let failure: ActiveQuietZonePairFailure

    var feasible: Bool { failure == .none }
}

struct ActiveQuietZoneErrorMicrophoneFeasibility: Equatable, Sendable {
    let errorMicrophoneID: String
    let bestPair: ActiveQuietZonePairFeasibility?
    let recommendedMaximumHz: Double
    let covered: Bool
}

enum ActiveQuietZoneFeasibilityStatus: String, Equatable, Sendable {
    case infeasible
    case marginal
    case feasible
}

struct ActiveQuietZoneFeasibilityReport: Equatable, Sendable {
    let sampleRate: Double
    let requestedBandHz: ClosedRange<Double>
    let timingUncertaintyMaximumHz: Double
    let spatialQuarterWavelengthMaximumHz: Double
    let physicalMaximumHz: Double
    let recommendedMaximumHz: Double
    let pairResults: [ActiveQuietZonePairFeasibility]
    let errorMicrophones: [ActiveQuietZoneErrorMicrophoneFeasibility]
    let minimumCausalityMarginFrames: Double?
    let minimumCoherenceFloor: Double?
    let minimumActuatorHeadroomDB: Double?
    let status: ActiveQuietZoneFeasibilityStatus
    let reasons: [String]
}

enum ActiveQuietZoneFeasibilityError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case invalidConfiguration
    case noReferenceObservations
    case noSecondaryPaths
    case invalidReferenceObservation(String)
    case invalidSecondaryPath(String)
    case uncoveredErrorMicrophone(String)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let rate):
            return "Active Quiet Zone sample rate \(rate) Hz is invalid."
        case .invalidConfiguration:
            return "Active Quiet Zone feasibility settings are invalid."
        case .noReferenceObservations:
            return "Active Quiet Zone feasibility requires at least one reference-to-error observation."
        case .noSecondaryPaths:
            return "Active Quiet Zone feasibility requires at least one actuator-to-error secondary path."
        case .invalidReferenceObservation(let id):
            return "Active Quiet Zone reference observation \(id) is invalid."
        case .invalidSecondaryPath(let id):
            return "Active Quiet Zone secondary path for \(id) is invalid."
        case .uncoveredErrorMicrophone(let id):
            return "Active Quiet Zone error microphone \(id) has no reference observation or actuator path."
        }
    }
}

/// Passive/offline causality planner for future feed-forward Active Quiet Zone.
///
/// This analyzer produces no anti-noise, adaptive coefficients, or live audio.
/// It answers whether the proposed physical geometry has enough lead time and
/// signal quality to justify building a controller at all.
struct ActiveQuietZoneFeasibilityAnalyzer: Sendable {
    func analyze(
        referenceObservations: [ActiveQuietZoneReferenceObservation],
        secondaryPaths: [ActiveQuietZoneSecondaryPath],
        sampleRate: Double,
        configuration: ActiveQuietZoneFeasibilityConfiguration = .conservative
    ) throws -> ActiveQuietZoneFeasibilityReport {
        try validate(
            referenceObservations: referenceObservations,
            secondaryPaths: secondaryPaths,
            sampleRate: sampleRate,
            configuration: configuration
        )

        let timingMaximum = Self.timingUncertaintyMaximumHz(
            sampleRate: sampleRate,
            jitterFrames: configuration.timingJitterFrames,
            maximumPhaseDegrees:
                configuration.maximumTimingPhaseUncertaintyDegrees
        )
        let spatialMaximum =
            configuration.speedOfSoundMetersPerSecond
            / (4.0 * configuration.quietZoneRadiusMeters)
        let physicalMaximum = min(
            configuration.requestedMaximumFrequencyHz,
            timingMaximum,
            spatialMaximum,
            sampleRate * 0.48
        )

        let errorIDs = Array(Set(
            referenceObservations.map(\.errorMicrophoneID)
                + secondaryPaths.map(\.errorMicrophoneID)
        )).sorted()

        var allPairs: [ActiveQuietZonePairFeasibility] = []
        var errorResults: [ActiveQuietZoneErrorMicrophoneFeasibility] = []

        for errorID in errorIDs {
            let references = referenceObservations.filter {
                $0.errorMicrophoneID == errorID
            }
            let actuators = secondaryPaths.filter {
                $0.errorMicrophoneID == errorID
            }
            guard !references.isEmpty, !actuators.isEmpty else {
                throw ActiveQuietZoneFeasibilityError
                    .uncoveredErrorMicrophone(errorID)
            }

            var localPairs: [ActiveQuietZonePairFeasibility] = []
            for secondary in actuators {
                for reference in references {
                    let requiredFrames =
                        configuration.referenceToActuatorProcessingLatencyFrames
                        + secondary.commandToErrorArrivalFrames
                        + configuration.causalitySafetyMarginFrames
                    let margin = reference.referenceLeadFrames - requiredFrames
                    let coherence = Self.coherenceBandResult(
                        observation: reference,
                        minimumHz: configuration.minimumFrequencyHz,
                        maximumHz: physicalMaximum,
                        threshold:
                            configuration.minimumMagnitudeSquaredCoherence,
                        gridCount: configuration.coherenceGridCount
                    )

                    let failure: ActiveQuietZonePairFailure
                    if margin < 0 {
                        failure = .insufficientReferenceLead
                    } else if secondary.reservedHeadroomDB
                        < configuration.minimumActuatorHeadroomDB {
                        failure = .insufficientActuatorHeadroom
                    } else if coherence.maximumHz
                        < configuration.minimumFrequencyHz {
                        failure = .insufficientCoherence
                    } else {
                        failure = .none
                    }

                    let recommendedMaximum = failure == .none
                        ? min(physicalMaximum, coherence.maximumHz)
                        : 0
                    let pair = ActiveQuietZonePairFeasibility(
                        errorMicrophoneID: errorID,
                        actuator: secondary.actuator,
                        referenceID: reference.referenceID,
                        causalityMarginFrames: margin,
                        causalityMarginMilliseconds:
                            margin / sampleRate * 1_000.0,
                        coherenceFloor: coherence.floor,
                        coherenceLimitedMaximumHz: coherence.maximumHz,
                        reservedHeadroomDB: secondary.reservedHeadroomDB,
                        recommendedMaximumHz: recommendedMaximum,
                        failure: failure
                    )
                    localPairs.append(pair)
                    allPairs.append(pair)
                }
            }

            let best = localPairs
                .filter(\.feasible)
                .max { lhs, rhs in
                    if lhs.recommendedMaximumHz
                        == rhs.recommendedMaximumHz {
                        if lhs.causalityMarginFrames
                            == rhs.causalityMarginFrames {
                            return lhs.coherenceFloor < rhs.coherenceFloor
                        }
                        return lhs.causalityMarginFrames
                            < rhs.causalityMarginFrames
                    }
                    return lhs.recommendedMaximumHz
                        < rhs.recommendedMaximumHz
                }
            errorResults.append(
                ActiveQuietZoneErrorMicrophoneFeasibility(
                    errorMicrophoneID: errorID,
                    bestPair: best,
                    recommendedMaximumHz:
                        best?.recommendedMaximumHz ?? 0,
                    covered: best != nil
                )
            )
        }

        let allCovered = errorResults.allSatisfy(\.covered)
        let recommendedMaximum = allCovered
            ? errorResults.map(\.recommendedMaximumHz).min() ?? 0
            : 0
        let chosenPairs = errorResults.compactMap(\.bestPair)
        let minimumMargin = chosenPairs.map(\.causalityMarginFrames).min()
        let minimumCoherence = chosenPairs.map(\.coherenceFloor).min()
        let minimumHeadroom = chosenPairs.map(\.reservedHeadroomDB).min()

        var reasons: [String] = []
        var status: ActiveQuietZoneFeasibilityStatus = .feasible

        if !allCovered
            || recommendedMaximum < configuration.minimumFrequencyHz {
            status = .infeasible
            for error in errorResults where !error.covered {
                reasons.append(
                    "No causal/coherent/headroom-qualified reference-actuator pair covers error microphone \(error.errorMicrophoneID)."
                )
            }
        } else {
            if physicalMaximum
                < configuration.requestedMaximumFrequencyHz - 0.5 {
                status = .marginal
                if spatialMaximum <= timingMaximum
                    && spatialMaximum
                        < configuration.requestedMaximumFrequencyHz {
                    reasons.append(
                        String(
                            format:
                                "Quiet-zone radius limits the conservative quarter-wavelength ceiling to %.1f Hz.",
                            spatialMaximum
                        )
                    )
                }
                if timingMaximum < spatialMaximum
                    && timingMaximum
                        < configuration.requestedMaximumFrequencyHz {
                    reasons.append(
                        String(
                            format:
                                "Timing uncertainty limits the phase-stable ceiling to %.1f Hz.",
                            timingMaximum
                        )
                    )
                }
            }
            if recommendedMaximum
                < configuration.requestedMaximumFrequencyHz - 0.5 {
                status = .marginal
                reasons.append(
                    String(
                        format:
                            "Measured reference/error coherence limits the common cancellation band to %.1f Hz.",
                        recommendedMaximum
                    )
                )
            }
            if let minimumMargin,
               minimumMargin
                < configuration.marginalExtraCausalityFrames {
                status = .marginal
                reasons.append(
                    String(
                        format:
                            "Minimum post-safety causality margin is only %.1f frames (%.2f ms).",
                        minimumMargin,
                        minimumMargin / sampleRate * 1_000.0
                    )
                )
            }
            if let minimumCoherence,
               minimumCoherence
                < configuration.minimumMagnitudeSquaredCoherence
                    + configuration.marginalCoherenceReserve {
                status = .marginal
                reasons.append(
                    String(
                        format:
                            "Minimum selected coherence floor is %.3f, close to the %.3f threshold.",
                        minimumCoherence,
                        configuration.minimumMagnitudeSquaredCoherence
                    )
                )
            }
            if let minimumHeadroom,
               minimumHeadroom
                < configuration.minimumActuatorHeadroomDB
                    + configuration.marginalHeadroomReserveDB {
                status = .marginal
                reasons.append(
                    String(
                        format:
                            "Minimum actuator reserve is %.1f dB, close to the %.1f dB threshold.",
                        minimumHeadroom,
                        configuration.minimumActuatorHeadroomDB
                    )
                )
            }
        }

        if reasons.isEmpty {
            reasons.append(
                String(
                    format:
                        "All error microphones have at least one causal, coherent actuator/reference path through %.1f Hz.",
                    recommendedMaximum
                )
            )
        }

        return ActiveQuietZoneFeasibilityReport(
            sampleRate: sampleRate,
            requestedBandHz:
                configuration.minimumFrequencyHz
                ...configuration.requestedMaximumFrequencyHz,
            timingUncertaintyMaximumHz: timingMaximum,
            spatialQuarterWavelengthMaximumHz: spatialMaximum,
            physicalMaximumHz: physicalMaximum,
            recommendedMaximumHz: recommendedMaximum,
            pairResults: allPairs,
            errorMicrophones: errorResults,
            minimumCausalityMarginFrames: minimumMargin,
            minimumCoherenceFloor: minimumCoherence,
            minimumActuatorHeadroomDB: minimumHeadroom,
            status: status,
            reasons: reasons
        )
    }

    private func validate(
        referenceObservations: [ActiveQuietZoneReferenceObservation],
        secondaryPaths: [ActiveQuietZoneSecondaryPath],
        sampleRate: Double,
        configuration: ActiveQuietZoneFeasibilityConfiguration
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ActiveQuietZoneFeasibilityError.invalidSampleRate(
                sampleRate
            )
        }
        guard configuration.minimumFrequencyHz.isFinite,
              configuration.minimumFrequencyHz >= 10,
              configuration.requestedMaximumFrequencyHz.isFinite,
              configuration.requestedMaximumFrequencyHz
                > configuration.minimumFrequencyHz,
              configuration.requestedMaximumFrequencyHz
                <= min(250, sampleRate * 0.48),
              configuration.referenceToActuatorProcessingLatencyFrames
                .isFinite,
              configuration.referenceToActuatorProcessingLatencyFrames >= 0,
              configuration.causalitySafetyMarginFrames.isFinite,
              configuration.causalitySafetyMarginFrames >= 0,
              configuration.marginalExtraCausalityFrames.isFinite,
              configuration.marginalExtraCausalityFrames >= 0,
              configuration.timingJitterFrames.isFinite,
              configuration.timingJitterFrames >= 0,
              configuration.maximumTimingPhaseUncertaintyDegrees.isFinite,
              configuration.maximumTimingPhaseUncertaintyDegrees > 0,
              configuration.maximumTimingPhaseUncertaintyDegrees <= 90,
              configuration.quietZoneRadiusMeters.isFinite,
              configuration.quietZoneRadiusMeters > 0,
              configuration.speedOfSoundMetersPerSecond.isFinite,
              configuration.speedOfSoundMetersPerSecond > 250,
              configuration.speedOfSoundMetersPerSecond < 400,
              configuration.minimumMagnitudeSquaredCoherence.isFinite,
              (0...1).contains(
                configuration.minimumMagnitudeSquaredCoherence
              ),
              configuration.marginalCoherenceReserve.isFinite,
              configuration.marginalCoherenceReserve >= 0,
              configuration.minimumMagnitudeSquaredCoherence
                + configuration.marginalCoherenceReserve <= 1,
              configuration.minimumActuatorHeadroomDB.isFinite,
              configuration.minimumActuatorHeadroomDB >= 0,
              configuration.marginalHeadroomReserveDB.isFinite,
              configuration.marginalHeadroomReserveDB >= 0,
              configuration.coherenceGridCount >= 16,
              configuration.coherenceGridCount <= 512 else {
            throw ActiveQuietZoneFeasibilityError.invalidConfiguration
        }

        guard !referenceObservations.isEmpty else {
            throw ActiveQuietZoneFeasibilityError.noReferenceObservations
        }
        guard !secondaryPaths.isEmpty else {
            throw ActiveQuietZoneFeasibilityError.noSecondaryPaths
        }

        for observation in referenceObservations {
            let count = observation.frequenciesHz.count
            guard !observation.referenceID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                  !observation.errorMicrophoneID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                  observation.referenceLeadFrames.isFinite,
                  count >= 2,
                  observation.magnitudeSquaredCoherence.count == count else {
                throw ActiveQuietZoneFeasibilityError
                    .invalidReferenceObservation(observation.referenceID)
            }
            var previous = 0.0
            for index in 0..<count {
                let frequency = observation.frequenciesHz[index]
                let coherence =
                    observation.magnitudeSquaredCoherence[index]
                guard frequency.isFinite,
                      frequency > previous,
                      coherence.isFinite,
                      (0...1).contains(coherence) else {
                    throw ActiveQuietZoneFeasibilityError
                        .invalidReferenceObservation(
                            observation.referenceID
                        )
                }
                previous = frequency
            }
        }

        for path in secondaryPaths {
            guard !path.errorMicrophoneID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                  path.commandToErrorArrivalFrames.isFinite,
                  path.commandToErrorArrivalFrames >= 0,
                  path.reservedHeadroomDB.isFinite,
                  path.reservedHeadroomDB >= 0 else {
                throw ActiveQuietZoneFeasibilityError
                    .invalidSecondaryPath(
                        path.errorMicrophoneID
                    )
            }
        }
    }

    private static func timingUncertaintyMaximumHz(
        sampleRate: Double,
        jitterFrames: Double,
        maximumPhaseDegrees: Double
    ) -> Double {
        guard jitterFrames > 0 else { return .infinity }
        let jitterSeconds = jitterFrames / sampleRate
        return maximumPhaseDegrees / 360.0 / jitterSeconds
    }

    private static func coherenceBandResult(
        observation: ActiveQuietZoneReferenceObservation,
        minimumHz: Double,
        maximumHz: Double,
        threshold: Double,
        gridCount: Int
    ) -> (maximumHz: Double, floor: Double) {
        guard maximumHz >= minimumHz else { return (0, 0) }

        var floor = 1.0
        var lastPassing = 0.0
        let ratio = maximumHz / minimumHz
        for index in 0..<gridCount {
            let fraction = gridCount == 1
                ? 0.0
                : Double(index) / Double(gridCount - 1)
            let frequency = minimumHz * pow(ratio, fraction)
            let coherence = interpolate(
                observation.magnitudeSquaredCoherence,
                frequencies: observation.frequenciesHz,
                at: frequency
            )
            floor = min(floor, coherence)
            if coherence < threshold {
                break
            }
            lastPassing = frequency
        }
        return (lastPassing, floor)
    }

    private static func interpolate(
        _ values: [Double],
        frequencies: [Double],
        at frequency: Double
    ) -> Double {
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
        let fraction =
            log(frequency / lowHz) / log(highHz / lowHz)
        return values[lower] + (values[upper] - values[lower]) * fraction
    }
}
