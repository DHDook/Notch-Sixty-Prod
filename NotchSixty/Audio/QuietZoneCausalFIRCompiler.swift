import Foundation

/// Converts offline, complex-frequency candidate controls into a causal,
/// finite, REAL-tap stereo FIR. This is a commissioning *preflight only*.
/// It cannot certify actual microphone→DAC scheduling, loudspeaker latency,
/// or physical attenuation at the listener.
struct QuietZoneCausalFIRCandidate: Equatable, Sendable {
    var sampleRate: Double
    var leftTaps: [Float]
    var rightTaps: [Float]
    var worstPredictedReductionDB: Double
    var maximumRelativeFitError: Double
    var maximumReferenceEchoFraction: Double

    /// No direct pipeline from a model into live playback is permitted.
    var liveDeploymentAuthorized: Bool { false }
}

enum QuietZoneCausalFIRError: Error, LocalizedError, Equatable {
    case invalidReferenceClock
    case invalidModel
    case rankDeficient
    case excessiveGain
    case nonCausalTarget
    case inadequateModeledReduction

    var errorDescription: String? {
        switch self {
        case .invalidReferenceClock:
            return "A measured, common reference/output sample rate and causal preview budget are required."
        case .invalidModel: return "The transfer model does not match the offline design."
        case .rankDeficient: return "The regularized FIR fit was numerically unstable."
        case .excessiveGain: return "The FIR exceeds the strictly bounded output gain budget."
        case .nonCausalTarget: return "No short causal real-tap filter can represent this complex target adequately."
        case .inadequateModeledReduction: return "The compiled FIR fails the modeled benefit, echo or no-regression tests."
        }
    }
}

struct QuietZoneCausalFIRCompiler: Sendable {
    static let maximumTaps = 64
    static let peakGainLimit = 0.06309573444801933
    static let maximumRelativeFitError = 0.18

    /// Refit the complex-frequency preview with real causal taps using
    /// Tikhonov-regularized least squares and exponentially increasing
    /// late-tap penalties. Candidate *must* pass independent acoustic
    /// re-evaluation after fitting, never merely match the idealized controls.
    func compile(
        design: QuietZoneVirtualSeatDesign,
        measurements: [QuietZoneVirtualSeatBand],
        budget: QuietZoneFeedForwardBudget,
        sampleRate: Double,
        tapCount: Int = 32
    ) throws -> QuietZoneCausalFIRCandidate {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              tapCount >= 1, tapCount <= Self.maximumTaps,
              budget.readiness == .physicallyPlausible,
              let reserve = budget.conservativeReserveSeconds,
              reserve.isFinite, reserve >= 0.002 else {
            throw QuietZoneCausalFIRError.invalidReferenceClock
        }
        let model = measurements.sorted { $0.frequencyHz < $1.frequencyHz }
        let target = design.bands.sorted { $0.frequencyHz < $1.frequencyHz }
        guard design.safePreviewOnly, !model.isEmpty,
              model.count == target.count,
              model.count <= 64 else {
            throw QuietZoneCausalFIRError.invalidModel
        }
        for i in model.indices {
            guard model[i].frequencyHz.isFinite,
                  model[i].frequencyHz == target[i].frequencyHz,
                  target[i].leftFilter.real.isFinite,
                  target[i].leftFilter.imaginary.isFinite,
                  target[i].rightFilter.real.isFinite,
                  target[i].rightFilter.imaginary.isFinite else {
                throw QuietZoneCausalFIRError.invalidModel
            }
        }
        let left = try fit(
            target.map(\.leftFilter), at: model.map(\.frequencyHz),
            sampleRate: sampleRate, taps: tapCount
        )
        let right = try fit(
            target.map(\.rightFilter), at: model.map(\.frequencyHz),
            sampleRate: sampleRate, taps: tapCount
        )

        let boundL = left.reduce(0.0) { $0 + abs($1) }
        let boundR = right.reduce(0.0) { $0 + abs($1) }
        guard boundL <= Self.peakGainLimit,
              boundR <= Self.peakGainLimit,
              left.allSatisfy(\.isFinite),
              right.allSatisfy(\.isFinite) else {
            throw QuietZoneCausalFIRError.excessiveGain
        }

        var maxError = 0.0
        var worstReduction = Double.infinity
        var maxEcho = 0.0
        for i in model.indices {
            let f = model[i].frequencyHz
            let computedL = response(left, frequency: f, sampleRate: sampleRate)
            let computedR = response(right, frequency: f, sampleRate: sampleRate)
            let desiredL = target[i].leftFilter
            let desiredR = target[i].rightFilter
            let norm = max(
                desiredL.magnitude + desiredR.magnitude,
                1.0e-9
            )
            let error = (
                (computedL - desiredL).magnitude
                + (computedR - desiredR).magnitude
            ) / norm
            guard error.isFinite else {
                throw QuietZoneCausalFIRError.nonCausalTarget
            }
            maxError = max(maxError, error)
            let disturbance = target[i].disturbanceTransfer
            let predicted = disturbance
                + model[i].leftSecondaryAtListener * computedL
                + model[i].rightSecondaryAtListener * computedR
            let benefit = 20 * log10(
                disturbance.magnitude / max(predicted.magnitude, 1.0e-15)
            )
            let echo = (
                model[i].leftLeakageAtReference * computedL
                + model[i].rightLeakageAtReference * computedR
            ).magnitude
            guard benefit.isFinite, echo.isFinite,
                  benefit >= QuietZoneVirtualSeatDesigner.minimumModeledReductionDB,
                  echo <= QuietZoneVirtualSeatDesigner.maximumLeakageFraction
            else { throw QuietZoneCausalFIRError.inadequateModeledReduction }
            maxEcho = max(maxEcho, echo)
            worstReduction = min(worstReduction, benefit)
        }

        guard maxError <= Self.maximumRelativeFitError else {
            throw QuietZoneCausalFIRError.nonCausalTarget
        }
        return QuietZoneCausalFIRCandidate(
            sampleRate: sampleRate,
            leftTaps: left.map(Float.init),
            rightTaps: right.map(Float.init),
            worstPredictedReductionDB: worstReduction,
            maximumRelativeFitError: maxError,
            maximumReferenceEchoFraction: maxEcho
        )
    }

    private func fit(
        _ desired: [ActiveQuietZoneComplex],
        at frequencies: [Double],
        sampleRate: Double,
        taps: Int
    ) throws -> [Double] {
        let count = frequencies.count
        var matrix = Array(
            repeating: Array(repeating: 0.0, count: taps),
            count: taps
        )
        var rhs = Array(repeating: 0.0, count: taps)
        var basis = Array(
            repeating: Array(repeating: 0.0, count: taps),
            count: 2 * count
        )
        for (j, f) in frequencies.enumerated() {
            let omega = 2 * Double.pi * f / sampleRate
            for n in 0..<taps {
                basis[2 * j][n] = cos(omega * Double(n))
                basis[2 * j + 1][n] = -sin(omega * Double(n))
            }
        }
        for i in 0..<taps {
            for j in 0..<taps {
                var value = 0.0
                for k in 0..<(2 * count) {
                    value += basis[k][i] * basis[k][j]
                }
                matrix[i][j] = value
            }
            // Strong late-tap regularization discourages delay-heavy
            // solutions that depend on unrealistically long prediction.
            let late = Double(i) / Double(max(taps - 1, 1))
            matrix[i][i] += 0.02 + 0.25 * late * late
            for k in 0..<count {
                rhs[i] += basis[2 * k][i] * desired[k].real
                    + basis[2 * k + 1][i] * desired[k].imaginary
            }
        }
        // Pivoted elimination; offline only, no callback allocations.
        for k in 0..<taps {
            var pivot = k
            for row in (k + 1)..<taps {
                if abs(matrix[row][k]) > abs(matrix[pivot][k]) {
                    pivot = row
                }
            }
            guard matrix[pivot][k].isFinite,
                  abs(matrix[pivot][k]) > 1.0e-12 else {
                throw QuietZoneCausalFIRError.rankDeficient
            }
            if pivot != k {
                matrix.swapAt(k, pivot)
                rhs.swapAt(k, pivot)
            }
            let d = matrix[k][k]
            for j in k..<taps { matrix[k][j] /= d }
            rhs[k] /= d
            for row in (k + 1)..<taps {
                let scale = matrix[row][k]
                if scale == 0 { continue }
                for j in k..<taps {
                    matrix[row][j] -= scale * matrix[k][j]
                }
                rhs[row] -= scale * rhs[k]
            }
        }
        var solution = Array(repeating: 0.0, count: taps)
        for i in stride(from: taps - 1, through: 0, by: -1) {
            var x = rhs[i]
            if i + 1 < taps {
                for j in (i + 1)..<taps {
                    x -= matrix[i][j] * solution[j]
                }
            }
            solution[i] = x
        }
        guard solution.allSatisfy(\.isFinite) else {
            throw QuietZoneCausalFIRError.rankDeficient
        }
        return solution
    }

    private func response(
        _ taps: [Double],
        frequency: Double,
        sampleRate: Double
    ) -> ActiveQuietZoneComplex {
        var re = 0.0
        var im = 0.0
        let omega = 2 * Double.pi * frequency / sampleRate
        for (index, value) in taps.enumerated() {
            let angle = omega * Double(index)
            re += value * cos(angle)
            im -= value * sin(angle)
        }
        return ActiveQuietZoneComplex(real: re, imaginary: im)
    }
}
