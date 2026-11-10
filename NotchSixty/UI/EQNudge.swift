import Foundation

/// E27 S1: the step tables shared by the number-field arrows and the graph keys, plus the
/// scroll and pinch scaling for Q. Plain Swift; clamping is done here so a nudge can never
/// leave the range the engine accepts.
enum EQNudge {
    static let minimumFrequency = 20.0
    static let qRange = 0.1...20.0
    /// Q a band returns to on a double-click reset (the `EQBand` default for every type).
    static let defaultQ = 0.707
    /// Q of a band added by double-clicking the empty graph.
    static let addedBandQ = 1.0

    /// G17: the step and direction types are the generic ones.
    typealias Step = ValueNudge.Step
    typealias Direction = ValueNudge.Direction

    // MARK: Tables

    /// Frequency ratio per step: a semitone (2^(1/12)), a third of an octave (2^(1/3)),
    /// 1/96 octave (2^(1/96)).
    static func frequencyRatio(_ step: Step) -> Double { ValueNudge.timeRatio(step) }

    /// Gain per step in dB: 0.5, 3, 0.1.
    static func gainStep(_ step: Step) -> Double { ValueNudge.decibelStep(step) }

    /// Q ratio per step: 1.1, 1.5, 1.02.
    static func qRatio(_ step: Step) -> Double { ValueNudge.ratioStep(step) }

    // MARK: Nudges

    static func frequency(
        _ hertz: Double,
        direction: Direction,
        step: Step,
        range: ClosedRange<Double>
    ) -> Double {
        ValueNudge.nudged(hertz, kind: .multiplicativeTime, direction: direction, step: step, range: range, floor: range.lowerBound)
    }

    static func gain(
        _ decibels: Double,
        direction: Direction,
        step: Step,
        range: ClosedRange<Double> = StereoEQConfiguration.bandGainRange
    ) -> Double {
        ValueNudge.nudged(decibels, kind: .decibels, direction: direction, step: step, range: range, floor: range.lowerBound)
    }

    static func q(
        _ value: Double,
        direction: Direction,
        step: Step,
        range: ClosedRange<Double> = qRange
    ) -> Double {
        ValueNudge.nudged(value, kind: .ratio, direction: direction, step: step, range: range, floor: range.lowerBound)
    }

    /// Nudges the field's value in place of the arrow keys.
    static func nudged(
        _ value: Double,
        field: EQValueParser.Field,
        direction: Direction,
        step: Step,
        band: EQBand,
        maximumFrequency: Double
    ) -> Double {
        let limits = EQValueParser.range(for: field, band: band, maximumFrequency: maximumFrequency)
        switch field {
        case .frequency, .linkwitzTargetFrequency:
            return frequency(value, direction: direction, step: step, range: limits)
        case .gain:
            return gain(value, direction: direction, step: step, range: limits)
        case .q, .linkwitzTargetQ:
            return q(value, direction: direction, step: step, range: limits)
        }
    }

    // MARK: Scroll and pinch

    /// Q scale per scroll notch.
    static let scrollQRatioPerNotch = 1.05

    /// Q after `notches` scroll notches (positive raises Q), clamped.
    static func q(_ value: Double, scrollNotches notches: Int, range: ClosedRange<Double>) -> Double {
        clamp(value * pow(scrollQRatioPerNotch, Double(notches)), to: range)
    }

    /// Q after a pinch of `magnification` (positive = spread, raises Q), clamped.
    static func q(_ value: Double, magnification: Double, range: ClosedRange<Double>) -> Double {
        guard magnification.isFinite, magnification > -1 else { return value }
        return clamp(value * (1 + magnification), to: range)
    }

    /// Turns raw scroll deltas into whole notches. A wheel reports one line per detent; a
    /// trackpad reports points, so it takes `pointsPerNotch` of travel for one notch and the
    /// remainder carries over to the next event.
    struct ScrollAccumulator: Equatable, Sendable {
        static let pointsPerNotch = 8.0
        private var remainder = 0.0

        mutating func add(delta: Double, precise: Bool) -> Int {
            guard delta.isFinite, delta != 0 else { return 0 }
            if !precise {
                let notches = Int(delta.rounded(.awayFromZero))
                return notches
            }
            remainder += delta
            let notches = Int((remainder / Self.pointsPerNotch).rounded(.towardZero))
            remainder -= Double(notches) * Self.pointsPerNotch
            return notches
        }

        mutating func reset() { remainder = 0 }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
