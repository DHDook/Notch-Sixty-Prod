import Foundation

/// E4 S26a: one surveyed tone at an ear position, in the form the stereo design needs.
///
/// `ratio` is the S26a monitor-to-ear ratio R. `earLeft` and `earRight` are the speaker paths to the ear
/// position, evaluated at the tone from that position's Room Correction impulse responses.
/// `effectiveSecondary` is the S26a effective secondary path of the common (left plus right) drive,
/// kept for the authority check and the card.
struct QuietZoneEarTone: Equatable, Codable, Sendable, Identifiable {
    var frequencyHz: Double
    var ratio: ActiveQuietZoneComplex
    var earLeft: ActiveQuietZoneComplex
    var earRight: ActiveQuietZoneComplex
    var effectiveSecondary: ActiveQuietZoneComplex
    var id: Double { frequencyHz }

    /// True when every value is finite (a stored survey is checked before it is trusted again).
    var isFinite: Bool {
        frequencyHz.isFinite && [ratio, earLeft, earRight, effectiveSecondary].allSatisfy { $0.real.isFinite && $0.imaginary.isFinite }
    }
}

/// E4 S27 (G21): another surveyed seat that must not get louder. The noise there is `ratio` times the monitor noise,
/// and the speakers reach it by `left` and `right`. Its predicted change is limited like the monitor microphone's.
struct QuietZoneOtherSeatPoint: Equatable, Sendable {
    var ratio: ActiveQuietZoneComplex
    var left: ActiveQuietZoneComplex
    var right: ActiveQuietZoneComplex
}

struct QuietZoneVirtualDesignResult: Equatable, Sendable {
    var left: ActiveQuietZoneComplex
    var right: ActiveQuietZoneComplex
    /// Predicted reduction at the ear (virtual microphone), dB.
    var predictedReductionAtEarDB: Double
    /// Predicted level change at the real monitor microphone, dB (positive is louder).
    var monitorChangeDB: Double
    /// 1 unless the monitor-microphone limit scaled the design back.
    var monitorLimitScale: Double
}

/// Per-tone design for a quiet zone at the ear instead of at the error microphone.
///
/// The uncancelled noise at the ear is R times the uncancelled noise at the monitor (S26a); the speaker
/// paths are the ear position's. The one-zone stereo solve therefore runs unchanged on those inputs, which
/// keeps every existing cap (per-tone peak, aggregate peak, headroom, bass conditioning, target
/// reduction). The real monitor microphone is then treated as an S16 other-seat point: the output is
/// scaled back until it would raise the monitor level by no more than the other-seat limit.
/// Control plane only; no audio thread, no allocation rules apply. Independent of the device rate.
enum QuietZoneVirtualDesign {
    /// Below this scale the monitor limit leaves too little output to be worth playing.
    static let minimumScale = 0.05
    /// A design that predicts less than this reduction at the ear is not played.
    static let minimumReductionDB = 0.5

    /// Returns nil when the design cannot help (the caller then keeps the fixed-seat design).
    static func solve(
        planner: ActiveQuietZonePlanner,
        tone: QuietZoneEarTone,
        frequencyHz: Double,
        monitorDisturbance: ActiveQuietZoneComplex,
        monitorLeft: ActiveQuietZoneComplex,
        monitorRight: ActiveQuietZoneComplex,
        availableInjectionPeak: Double,
        configuration: ActiveQuietZoneConfiguration,
        bassConditioning: BassPlantConditioningMode,
        otherSeats: [QuietZoneOtherSeatPoint] = []
    ) throws -> QuietZoneVirtualDesignResult? {
        let earDisturbance = tone.ratio * monitorDisturbance
        let solution = try planner.solveStereo(
            frequencyHz: frequencyHz,
            disturbance: earDisturbance,
            leftSecondaryPath: tone.earLeft,
            rightSecondaryPath: tone.earRight,
            availableInjectionPeak: availableInjectionPeak,
            configuration: configuration,
            bassConditioning: bassConditioning)
        guard solution.predictedReductionDB >= minimumReductionDB else { return nil }

        func monitorChange(_ scale: Double) -> Double {
            let residual = monitorDisturbance
                + monitorLeft * (solution.leftOutput * scale)
                + monitorRight * (solution.rightOutput * scale)
            return 20 * log10(max(residual.magnitude, 1.0e-15) / max(monitorDisturbance.magnitude, 1.0e-15))
        }
        let limit = QuietZoneQualificationTargets.maximumOtherSeatIncreaseDB
        // G21: every other surveyed seat is predicted from its own ratio and speaker paths, like the monitor.
        func seatChange(_ seat: QuietZoneOtherSeatPoint, _ scale: Double) -> Double {
            let before = seat.ratio * monitorDisturbance
            let residual = before + seat.left * (solution.leftOutput * scale) + seat.right * (solution.rightOutput * scale)
            return 20 * log10(max(residual.magnitude, 1.0e-15) / max(before.magnitude, 1.0e-15))
        }
        func exceeds(_ scale: Double) -> Bool {
            monitorChange(scale) > limit || otherSeats.contains { seatChange($0, scale) > limit }
        }
        var scale = 1.0
        if exceeds(1) {
            var low = 0.0, high = 1.0
            for _ in 0..<32 {
                let middle = 0.5 * (low + high)
                if exceeds(middle) { high = middle } else { low = middle }
            }
            scale = low
        }
        guard scale >= minimumScale else { return nil }
        let left = solution.leftOutput * scale
        let right = solution.rightOutput * scale
        let residual = earDisturbance + tone.earLeft * left + tone.earRight * right
        let reduction = 20 * log10(max(earDisturbance.magnitude, 1.0e-15) / max(residual.magnitude, 1.0e-15))
        guard reduction >= minimumReductionDB, reduction.isFinite else { return nil }
        return QuietZoneVirtualDesignResult(
            left: left, right: right,
            predictedReductionAtEarDB: reduction,
            monitorChangeDB: monitorChange(scale),
            monitorLimitScale: scale)
    }
}
