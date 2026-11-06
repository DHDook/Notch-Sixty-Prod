import Foundation

// E26 S4: the safety rules for a subwoofer in the anti-noise path (design 6): excursion limits through a receiver, the
// measured summing law for the sub's thermal integrator, the path-gain watch and the combined-leakage stability
// bound. Pure control-plane values: no engine access, nothing realtime, nothing here arms anything. Every rule is
// stricter than the one before it, never looser.

extension ExcursionLimits {
    /// The limits for the declared bass path. Open preout: the app's own crossover is the only one. Calibrated LFE
    /// out: the declared receiver crossover, and the mains' lower limit is that crossover, because a measurement
    /// through the receiver includes the sub and cannot show where the mains stop. Undeclared: the larger of the
    /// app crossover and the 80 Hz default (live is refused anyway). Other paths keep `base`. Never lower than `base`.
    func refined(for path: AncBassPath, appCrossoverHz: Double?) -> ExcursionLimits {
        guard case .downstream(let receiver) = path else { return self }
        let app = appCrossoverHz.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let crossover: Double
        switch receiver {
        case .openPreout: crossover = app ?? ReceiverBass.defaultCrossoverHz
        case .calibratedLFE(let hz): crossover = receiver.isValid ? hz : max(app ?? 0, ReceiverBass.defaultCrossoverHz)
        case .undeclared: crossover = max(app ?? 0, ReceiverBass.defaultCrossoverHz)
        }
        return ExcursionLimits(
            mainLowerLimitHz: max(crossover, mainLowerLimitHz),
            subCrossoverHz: max(crossover, subCrossoverHz ?? 0))
    }
}

/// How many channels' worth of anti-noise peak the sub carries, from the measured plant, for the thermal integrator.
enum SubSummingLaw {
    /// Both feeds in phase into one sub: the sub sees the peaks add.
    static let maximumFactor = 2.0

    /// (|HL| + |HR|) / max(|HL|, |HR|) at one band, from the seat paths: 1 when one feed dominates, 2 when both
    /// reach the room equally. Nil for unusable data.
    static func factor(left: ActiveQuietZoneComplex, right: ActiveQuietZoneComplex) -> Double? {
        let l = left.magnitude, r = right.magnitude
        guard l.isFinite, r.isFinite, max(l, r) > 1.0e-12 else { return nil }
        return min(max((l + r) / max(l, r), 1), maximumFactor)
    }

    /// The largest factor over the shared-sub bands at or below `upperHz`. A sub in the path with no usable measured
    /// band counts the worst case (2), not 1. Without a sub the factor is 1.
    static func factor(plant: BassPlantMap, subInPath: Bool, upperHz: Double) -> Double {
        guard subInPath else { return 1 }
        var worst: Double?
        for band in plant.bands where band.frequencyHz <= upperHz {
            guard BassPlantConditioning.assess(band: band).sharesSubwoofer,
                  let f = factor(left: band.leftSecondaryAtListener, right: band.rightSecondaryAtListener)
            else { continue }
            worst = max(worst ?? 1, f)
        }
        return worst ?? maximumFactor
    }
}

/// Compares the live secondary path in the sub band with its first value in this arm. A change of more than 6 dB or
/// 90 degrees (a trim step on the receiver, a polarity flip, a moved sub) is a different plant, so the caller disarms.
/// A 1 dB volume change stays inside the window (the arm switch's own output-gain check handles volume).
struct BassPathWatch: Equatable, Sendable {
    static let gainToleranceDB = 6.0
    static let phaseToleranceDegrees = 90.0
    /// Tones match a baseline within a sixth of an octave.
    static let matchOctaves = 1.0 / 6.0

    struct Sample: Equatable, Sendable {
        var frequencyHz: Double
        var levelDB: Double
        var phaseDegrees: Double
    }

    enum Verdict: Equatable, Sendable {
        case ok
        case changed(gainDB: Double, phaseDegrees: Double)
    }

    /// Only tones at or below this are compared (the sub band), hertz.
    var upperHz: Double
    private(set) var baselines: [Sample] = []

    init(upperHz: Double) { self.upperHz = upperHz }

    mutating func reset() { baselines.removeAll() }

    mutating func observe(_ samples: [Sample]) -> Verdict {
        for s in samples where s.frequencyHz.isFinite && s.frequencyHz > 0 && s.frequencyHz <= upperHz {
            guard s.levelDB.isFinite, s.phaseDegrees.isFinite else { continue }
            guard let base = baselines.first(where: { abs(log2($0.frequencyHz / s.frequencyHz)) <= Self.matchOctaves })
            else { baselines.append(s); continue }
            let gain = s.levelDB - base.levelDB
            var phase = (s.phaseDegrees - base.phaseDegrees).truncatingRemainder(dividingBy: 360)
            if phase > 180 { phase -= 360 }
            if phase < -180 { phase += 360 }
            if abs(gain) > Self.gainToleranceDB || abs(phase) > Self.phaseToleranceDegrees {
                return .changed(gainDB: gain, phaseDegrees: phase)
            }
        }
        return .ok
    }
}

/// The feed-forward leakage bound with the sub in the loop. The sub-to-reference path is part of the measured combined
/// leakage, and it can move by the same 6 dB the path watch tolerates, so in bands the sub shares the leakage limit is
/// divided by that window. Elsewhere the existing limit stands.
enum CombinedLeakageStabilityBound {
    /// The path-change window as a linear factor (6 dB).
    static let pathChangeInflation = pow(10, BassPathWatch.gainToleranceDB / 20)

    static func fractionLimit(for band: QuietZoneVirtualSeatBand, bassConditioning: Bool) -> Double {
        let base = QuietZoneVirtualSeatDesigner.maximumLeakageFraction
        guard bassConditioning, BassPlantConditioning.assess(band: band).mode != .free else { return base }
        return base / pathChangeInflation
    }
}
