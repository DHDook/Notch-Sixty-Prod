import Foundation

/// E4 S27: which zone the quiet zone covers. Pure value maths; nothing here arms or drives output.
/// The mode joins the S20 earned-cap binding key, so a change of mode starts again at -40 dBFS.
enum QuietZoneZoneMode: String, Codable, Sendable, CaseIterable {
    /// One seat, as today.
    case fixedSeat
    /// One zone that follows the listener (S26b selects the surveyed ratios).
    case follow
    /// Two zones, for example both sides of a bed. Needs two speakers.
    case twoZones

    var zoneCount: Int { self == .twoZones ? 2 : 1 }
}

/// One zone at one tone: the uncancelled noise at the zone's virtual microphone and the two speaker
/// paths to it. `uncancelled` is R d_mon (S26a ratio times the monitor noise); `paths` are the Room
/// Correction impulse responses of the ear position, evaluated at the tone.
struct QuietZoneZoneTone: Equatable, Sendable {
    var uncancelled: ActiveQuietZoneComplex
    var leftPath: ActiveQuietZoneComplex
    var rightPath: ActiveQuietZoneComplex

    init(uncancelled: ActiveQuietZoneComplex, leftPath: ActiveQuietZoneComplex, rightPath: ActiveQuietZoneComplex) {
        self.uncancelled = uncancelled
        self.leftPath = leftPath
        self.rightPath = rightPath
    }

    /// From an S26a virtual microphone tone and the uncancelled monitor noise.
    init(
        virtualTone: QuietZoneVirtualMicTone,
        uncancelledMonitorNoise: ActiveQuietZoneComplex,
        leftPath: ActiveQuietZoneComplex,
        rightPath: ActiveQuietZoneComplex
    ) {
        self.init(uncancelled: virtualTone.ratio * uncancelledMonitorNoise, leftPath: leftPath, rightPath: rightPath)
    }

    func residual(left: ActiveQuietZoneComplex, right: ActiveQuietZoneComplex) -> ActiveQuietZoneComplex {
        uncancelled + leftPath * left + rightPath * right
    }
}

struct QuietZoneZonePrediction: Equatable, Sendable {
    var reductionDB: Double
}

struct QuietZoneZoneSolution: Equatable, Sendable {
    /// The complex L/R gain written to the one S18 record for this tone.
    var left: ActiveQuietZoneComplex
    var right: ActiveQuietZoneComplex
    var zones: [QuietZoneZonePrediction]
    /// Predicted level change at each surveyed point outside the zones (positive is louder).
    var otherPointIncreaseDB: [Double]
    /// 1 when the unconstrained solution was used; less when the output cap or the other-seat limit scaled it.
    var appliedScale: Double
    /// True when even a zero output cannot be improved on, or an other-seat point would exceed its limit
    /// at the smallest tolerated scale: the caller must not arm this tone.
    var rejected: Bool
}

enum QuietZoneZoneError: Error, Equatable {
    case zoneCountMismatch
    case invalidPath
    case illConditioned
}

/// 2 x 2 per-tone core: two virtual errors, two outputs, damped least squares.
///   minimise  sum_z |d_z + S_zL yL + S_zR yR|^2 + lambda |y|^2
/// The 2 x 2 path matrix is exactly determined when the paths are well conditioned. The result is
/// one complex L/R gain per tone, so the S18 mailbox record is unchanged.
/// Derivation: normal equations (S^H S + lambda I) y = -S^H d, solved in closed form for 2 unknowns.
/// Realtime: control plane only. Sample rate: tone-domain, independent of the device rate.
struct QuietZoneTwoZoneSolver: Sendable {
    /// Damping relative to the mean diagonal of S^H S; matches the 3.5 percent of the one-zone solve.
    static let relativeDamping = 0.035
    /// Largest accepted condition proxy |det| / (product of diagonals) below which the pair is rejected.
    static let minimumDeterminantFraction = 1.0e-4
    /// Other-seat limit, from `QuietZoneQualificationTargets`.
    static let otherPointLimitDB = QuietZoneQualificationTargets.maximumOtherSeatIncreaseDB

    var maximumOutputMagnitude: Double = .infinity

    /// `others` are surveyed points outside every zone; each is an S16 other-seat point.
    func solve(zones: [QuietZoneZoneTone], others: [QuietZoneZoneTone] = []) throws -> QuietZoneZoneSolution {
        guard !zones.isEmpty else { throw QuietZoneZoneError.zoneCountMismatch }
        for t in zones + others {
            for c in [t.uncancelled, t.leftPath, t.rightPath] where !(c.real.isFinite && c.imaginary.isFinite) {
                throw QuietZoneZoneError.invalidPath
            }
        }
        // A^H A for the 2 unknowns.
        var a11 = 0.0, a22 = 0.0
        var a12 = ActiveQuietZoneComplex.zero
        var b1 = ActiveQuietZoneComplex.zero, b2 = ActiveQuietZoneComplex.zero
        for z in zones {
            a11 += z.leftPath.magnitude * z.leftPath.magnitude
            a22 += z.rightPath.magnitude * z.rightPath.magnitude
            a12 = a12 + z.leftPath.conjugate * z.rightPath
            b1 = b1 - z.leftPath.conjugate * z.uncancelled
            b2 = b2 - z.rightPath.conjugate * z.uncancelled
        }
        guard a11 > 1.0e-18, a22 > 1.0e-18 else { throw QuietZoneZoneError.invalidPath }
        let lambda = Self.relativeDamping * 0.5 * (a11 + a22)
        let d11 = a11 + lambda, d22 = a22 + lambda
        // det = d11 d22 - |a12|^2 (a21 is the conjugate of a12).
        let det = d11 * d22 - a12.magnitude * a12.magnitude
        if zones.count >= 2 {
            // Two zones with two speakers: the undamped matrix must be invertible.
            let raw = a11 * a22 - a12.magnitude * a12.magnitude
            guard raw > Self.minimumDeterminantFraction * a11 * a22 else { throw QuietZoneZoneError.illConditioned }
        }
        guard det > 1.0e-24 else { throw QuietZoneZoneError.illConditioned }
        var left = (b1 * d22 - a12 * b2) / det
        var right = (b2 * d11 - a12.conjugate * b1) / det

        var scale = 1.0
        let peak = max(left.magnitude, right.magnitude)
        if peak > maximumOutputMagnitude, peak > 0 { scale = maximumOutputMagnitude / peak }

        func increase(_ t: QuietZoneZoneTone, _ s: Double) -> Double {
            let after = t.residual(left: left * s, right: right * s).magnitude
            return 20 * log10(max(after, 1.0e-15) / max(t.uncancelled.magnitude, 1.0e-15))
        }
        // Other-seat limit: shrink the output until every outside point is within its limit.
        var rejected = false
        if others.contains(where: { increase($0, scale) > Self.otherPointLimitDB }) {
            var lo = 0.0, hi = scale
            for _ in 0..<24 {
                let mid = 0.5 * (lo + hi)
                if others.contains(where: { increase($0, mid) > Self.otherPointLimitDB }) { hi = mid } else { lo = mid }
            }
            scale = lo
        }
        left = left * scale
        right = right * scale
        func finalIncrease(_ t: QuietZoneZoneTone) -> Double {
            20 * log10(max(t.residual(left: left, right: right).magnitude, 1.0e-15) / max(t.uncancelled.magnitude, 1.0e-15))
        }
        let predictions = zones.map { z -> QuietZoneZonePrediction in
            let after = z.residual(left: left, right: right).magnitude
            return QuietZoneZonePrediction(
                reductionDB: -20 * log10(max(after, 1.0e-15) / max(z.uncancelled.magnitude, 1.0e-15)))
        }
        let worst = predictions.map(\.reductionDB).min() ?? 0
        if worst < 0.5 { rejected = true }
        return QuietZoneZoneSolution(
            left: left, right: right, zones: predictions,
            otherPointIncreaseDB: others.map(finalIncrease),
            appliedScale: scale, rejected: rejected)
    }
}

/// S16 other-seat bookkeeping: every surveyed point that is not inside a zone is an other-seat point,
/// and each zone keeps its own baseline, measured at the real microphone through that zone's ratio.
struct QuietZoneZonePlan: Equatable, Sendable {
    var mode: QuietZoneZoneMode
    var zonePointIDs: [UUID]
    var otherSeatPointIDs: [UUID]

    init(mode: QuietZoneZoneMode, surveyedPointIDs: [UUID], zonePointIDs: [UUID]) throws {
        guard zonePointIDs.count == mode.zoneCount, Set(zonePointIDs).count == zonePointIDs.count,
              zonePointIDs.allSatisfy(surveyedPointIDs.contains)
        else { throw QuietZoneZoneError.zoneCountMismatch }
        self.mode = mode
        self.zonePointIDs = zonePointIDs
        self.otherSeatPointIDs = surveyedPointIDs.filter { !zonePointIDs.contains($0) }
    }

    /// Switching mode while armed disarms and re-arms at -40 dBFS (the S20 binding changes).
    func requiresRearm(comparedTo other: QuietZoneZonePlan) -> Bool {
        mode != other.mode || Set(zonePointIDs) != Set(other.zonePointIDs)
    }
}
