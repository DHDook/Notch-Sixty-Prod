import Foundation

/// PR95: offline spatial commissioning. Sequential microphone captures are only
/// comparable when they share a repeatable coherent timing/phase reference.
/// This model does not claim that moving people/noise remain coherent.
struct QuietZoneSeatCapture: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var weight: Double = 1
    var microphoneID: String
    var routeID: String
    var coherentReferenceID: String
    var sampleRate: Double
    var capturedFrequencyHz: Double
    var snrDB: Double
    var clipped: Bool = false
    var leftSecondaryPath: ActiveQuietZoneComplex
    var rightSecondaryPath: ActiveQuietZoneComplex
    var disturbance: ActiveQuietZoneComplex
}

struct QuietZoneSpatialSession: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var monitorSeatID: UUID
    var captures: [QuietZoneSeatCapture]
}

enum QuietZoneSpatialError: Error, LocalizedError {
    case insufficientSeats
    case invalidCapture
    case inconsistentReference
    case incompatibleRoute
    case inadequateHeadroom
    case noSafeImprovement
    case verificationRequired

    var errorDescription: String? {
        switch self {
        case .insufficientSeats: return "Calibrate at least two distinct listening positions."
        case .invalidCapture: return "One or more captures are clipped, noisy, non-finite or unmeasurable."
        case .inconsistentReference: return "Sequential captures require the same coherent time/phase reference and frequency."
        case .incompatibleRoute: return "Microphone identity, route or sample rate changed between seats."
        case .inadequateHeadroom: return "The current output path has insufficient safe injection headroom."
        case .noSafeImprovement: return "No candidate improves the zone without worsening another seat."
        case .verificationRequired: return "Re-measure and confirm every calibrated position before commissioning."
        }
    }
}

struct QuietZoneSeatPrediction: Equatable, Sendable, Identifiable {
    var seatID: UUID
    var name: String
    var predictedReductionDB: Double
    var baselineMagnitude: Double
    var residualMagnitude: Double
    var id: UUID { seatID }
}

struct QuietZoneSpatialSolution: Equatable, Sendable {
    var frequencyHz: Double
    var leftOutput: ActiveQuietZoneComplex
    var rightOutput: ActiveQuietZoneComplex
    var predictions: [QuietZoneSeatPrediction]
    var weightedMeanReductionDB: Double
    var worstSeatReductionDB: Double
    /// Non-live projection only; one monitor microphone cannot continuously
    /// verify any other seat.
    var commissioned: Bool = false
}

struct QuietZoneSpatialPlanner: Sendable {
    /// Conservative offline search. Derive the complex weighted normal-equation
    /// solution and search its amplitude from silence to bounded full injection,
    /// retaining only candidates that meet the hard all-seat regression gate.
    func solve(
        session: QuietZoneSpatialSession,
        configuration rawConfiguration: ActiveQuietZoneConfiguration,
        availableInjectionPeak: Double
    ) throws -> QuietZoneSpatialSolution {
        let configuration = try rawConfiguration.validated()
        let seats = session.captures
        guard seats.count >= 2,
              Set(seats.map(\.id)).count == seats.count,
              Set(seats.map(\.name)).count == seats.count,
              seats.contains(where: { $0.id == session.monitorSeatID })
        else { throw QuietZoneSpatialError.insufficientSeats }

        guard let first = seats.first else {
            throw QuietZoneSpatialError.insufficientSeats
        }
        guard !first.coherentReferenceID.isEmpty,
              first.capturedFrequencyHz >= configuration.minimumFrequencyHz,
              first.capturedFrequencyHz <= configuration.maximumFrequencyHz
        else { throw QuietZoneSpatialError.inconsistentReference }

        for seat in seats {
            guard seat.microphoneID == first.microphoneID,
                  seat.routeID == first.routeID,
                  abs(seat.sampleRate - first.sampleRate) < 1,
                  seat.sampleRate >= 8_000 else {
                throw QuietZoneSpatialError.incompatibleRoute
            }
            guard seat.coherentReferenceID == first.coherentReferenceID,
                  abs(seat.capturedFrequencyHz - first.capturedFrequencyHz) < 0.01
            else { throw QuietZoneSpatialError.inconsistentReference }
            let values = [
                seat.weight, seat.snrDB,
                seat.leftSecondaryPath.real, seat.leftSecondaryPath.imaginary,
                seat.rightSecondaryPath.real, seat.rightSecondaryPath.imaginary,
                seat.disturbance.real, seat.disturbance.imaginary
            ]
            guard values.allSatisfy(\.isFinite), seat.weight > 0,
                  seat.snrDB >= 25, !seat.clipped,
                  seat.disturbance.magnitude > 1.0e-8,
                  seat.leftSecondaryPath.magnitude + seat.rightSecondaryPath.magnitude > 1.0e-8
            else { throw QuietZoneSpatialError.invalidCapture }
        }

        guard availableInjectionPeak.isFinite, availableInjectionPeak > 0 else {
            throw QuietZoneSpatialError.inadequateHeadroom
        }
        // Weighted complex least squares, two sources, with Tikhonov damping.
        var aa = 0.0
        var dd = 0.0
        var cross = ActiveQuietZoneComplex.zero
        var rhsL = ActiveQuietZoneComplex.zero
        var rhsR = ActiveQuietZoneComplex.zero
        for seat in seats {
            let w = seat.weight
            let a = seat.leftSecondaryPath
            let b = seat.rightSecondaryPath
            aa += w * a.magnitude * a.magnitude
            dd += w * b.magnitude * b.magnitude
            cross = cross + a.conjugate * b * w
            rhsL = rhsL - a.conjugate * seat.disturbance * w
            rhsR = rhsR - b.conjugate * seat.disturbance * w
        }
        let lambda = max((aa + dd) * configuration.regularization, 1.0e-10)
        aa += lambda
        dd += lambda
        let determinant = aa * dd - cross.magnitude * cross.magnitude
        guard determinant.isFinite, determinant > 1.0e-14 else {
            throw QuietZoneSpatialError.invalidCapture
        }
        var left = (rhsL * dd - cross * rhsR) / determinant
        var right = (rhsR * aa - cross.conjugate * rhsL) / determinant
        let perSource = pow(10, configuration.maximumPerSourceTonePeakDBFS / 20)
        let aggregate = pow(10, configuration.maximumAggregateSourcePeakDBFS / 20)
        let maxMagnitude = max(left.magnitude, right.magnitude)
        guard maxMagnitude.isFinite, maxMagnitude > 1.0e-12 else {
            throw QuietZoneSpatialError.noSafeImprovement
        }
        let scale = min(1, perSource / maxMagnitude,
                        aggregate / maxMagnitude, availableInjectionPeak / maxMagnitude)
        left = left * scale
        right = right * scale

        var best: QuietZoneSpatialSolution?
        var bestScore = -Double.infinity
        for step in 1...80 {
            let multiplier = Double(step) / 80
            let l = left * multiplier
            let r = right * multiplier
            var predictions: [QuietZoneSeatPrediction] = []
            var weighted = 0.0
            var totalWeight = 0.0
            var worst = Double.infinity
            var valid = true
            for seat in seats {
                let residual = seat.disturbance
                    + seat.leftSecondaryPath * l
                    + seat.rightSecondaryPath * r
                let reduction = 20 * log10(
                    seat.disturbance.magnitude / max(residual.magnitude, 1.0e-15))
                if !reduction.isFinite ||
                    reduction < -configuration.maximumAllowedRegressionDB {
                    valid = false
                    break
                }
                worst = min(worst, reduction)
                weighted += seat.weight * reduction
                totalWeight += seat.weight
                predictions.append(QuietZoneSeatPrediction(
                    seatID: seat.id, name: seat.name,
                    predictedReductionDB: reduction,
                    baselineMagnitude: seat.disturbance.magnitude,
                    residualMagnitude: residual.magnitude))
            }
            guard valid, totalWeight > 0 else { continue }
            let mean = weighted / totalWeight
            let score = mean + 0.75 * worst - 0.03 * multiplier
            if score > bestScore {
                bestScore = score
                best = QuietZoneSpatialSolution(
                    frequencyHz: first.capturedFrequencyHz,
                    leftOutput: l, rightOutput: r,
                    predictions: predictions,
                    weightedMeanReductionDB: mean,
                    worstSeatReductionDB: worst)
            }
        }
        guard let solution = best,
              solution.weightedMeanReductionDB >= configuration.minimumProbeImprovementDB,
              solution.worstSeatReductionDB >= -configuration.maximumAllowedRegressionDB
        else { throw QuietZoneSpatialError.noSafeImprovement }
        return solution
    }

    /// Commissioning requires *new* physical tests at all original positions.
    /// Results are still historical: only the monitor seat is observed live.
    func verifyCommissioning(
        solution: QuietZoneSpatialSolution,
        measuredReductionBySeat: [UUID: Double],
        configuration: ActiveQuietZoneConfiguration
    ) throws -> QuietZoneSpatialSolution {
        let configuration = try configuration.validated()
        guard Set(measuredReductionBySeat.keys) ==
                Set(solution.predictions.map(\.seatID)),
              measuredReductionBySeat.values.allSatisfy(\.isFinite),
              measuredReductionBySeat.values.allSatisfy({
                  $0 >= -configuration.maximumAllowedRegressionDB
              }),
              measuredReductionBySeat.values.reduce(0.0, +)
                / Double(measuredReductionBySeat.count)
                >= configuration.minimumProbeImprovementDB
        else { throw QuietZoneSpatialError.verificationRequired }
        var verified = solution
        verified.commissioned = true
        return verified
    }
}
