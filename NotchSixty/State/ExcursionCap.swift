import Foundation

/// E4 S21 (`e4.earned-cap`): what the speaker can take, from the measured lower limit and the
/// speaker's role only. The owner decided on 28 Oct 2026 that no driver data is typed in.
struct ExcursionLimits: Equatable, Sendable {
    /// Where the main speakers stop reproducing bass: the -10 dB point of the Room Correction
    /// measurement, or the bass-management crossover when there is no measurement.
    var mainLowerLimitHz: Double
    /// The bass-management crossover when a subwoofer is in the system; nil without one.
    var subCrossoverHz: Double?

    /// Used when nothing measured is available: mains with no sub are assumed to stop at 60 Hz.
    static let unmeasuredMainLowerLimitHz = 60.0

    /// The -10 dB point of a measured response: the mean level of the 200-1000 Hz reference band,
    /// then the highest frequency below it where the response falls 10 dB under that mean
    /// (linear interpolation in dB over log frequency). Nil when the data is unusable or the
    /// response never falls 10 dB.
    static func lowerLimitHz(frequenciesHz: [Double], magnitudeDB: [Double]) -> Double? {
        guard frequenciesHz.count == magnitudeDB.count, frequenciesHz.count >= 4 else { return nil }
        let points = zip(frequenciesHz, magnitudeDB)
            .filter { $0.0.isFinite && $0.0 > 0 && $0.1.isFinite }
            .sorted { $0.0 < $1.0 }
        let reference = points.filter { $0.0 >= 200 && $0.0 <= 1000 }.map(\.1)
        guard !reference.isEmpty else { return nil }
        let target = reference.reduce(0, +) / Double(reference.count) - 10
        guard let start = points.lastIndex(where: { $0.0 < 200 }) else { return nil }
        var index = start
        while index >= 0 {
            if points[index].1 < target {
                guard index + 1 < points.count else { return nil }
                let (f0, l0) = points[index]
                let (f1, l1) = points[index + 1]
                guard l1 > l0 else { return f1 }
                let t = (target - l0) / (l1 - l0)
                return exp(log(f0) + t * (log(f1) - log(f0)))
            }
            index -= 1
        }
        return nil
    }
}

/// The most anti-noise (dBFS peak per channel) a tone may carry at each frequency. Mains fall
/// 12 dB per octave below their lower limit. With a sub, a tone at or below the crossover is the
/// sub's job (the mains are high-passed there), and the sub falls 12 dB per octave above the
/// crossover plus one octave. Every value is at most the live hard maximum, so the curve only ever
/// lowers the S20 cap.
struct ExcursionCapCurve: Equatable, Sendable {
    static let slopeDBPerOctave = 12.0
    /// The lowest the curve goes (dBFS), so a cap never reaches zero.
    static let floorDBFS = -80.0
    /// The microphone-move tracking range of a tone (S18b / S19): the cap at a tone is the lowest
    /// of the curve across it.
    static let trackFraction = 0.10

    let limits: ExcursionLimits

    init(limits: ExcursionLimits) {
        self.limits = limits
    }

    static var passbandDBFS: Double { LiveTreatmentSafeguards.hardMaximumPeakCapDBFS }

    /// The sub's own curve: flat up to the crossover plus one octave, then 12 dB per octave down.
    func subCapDBFS(atHz frequency: Double) -> Double {
        guard let crossover = limits.subCrossoverHz else { return Self.floorDBFS }
        let edge = crossover * 2
        return max(Self.floorDBFS, Self.passbandDBFS - Self.slopeDBPerOctave * max(0, log2(frequency / edge)))
    }

    func mainCapDBFS(atHz frequency: Double) -> Double {
        max(Self.floorDBFS, Self.passbandDBFS - Self.slopeDBPerOctave * max(0, log2(limits.mainLowerLimitHz / frequency)))
    }

    /// With a sub, a tone at or below the crossover is the sub's job (the mains are high-passed
    /// there); above it the mains carry the tone. Without a sub the mains carry everything.
    func capDBFS(atHz frequency: Double) -> Double {
        guard frequency.isFinite, frequency > 0 else { return Self.floorDBFS }
        if let crossover = limits.subCrossoverHz, frequency <= crossover {
            return subCapDBFS(atHz: frequency)
        }
        return mainCapDBFS(atHz: frequency)
    }

    /// The cap for a tone that may drift by the tracking range: the lowest across it.
    func trackedCapDBFS(atHz frequency: Double) -> Double {
        let span = Self.trackFraction
        return min(capDBFS(atHz: frequency * (1 - span)), capDBFS(atHz: frequency), capDBFS(atHz: frequency * (1 + span)))
    }

    func trackedCapLinear(atHz frequency: Double) -> Float {
        Float(LiveTreatmentSafeguards.linearPeak(dbfs: trackedCapDBFS(atHz: frequency)))
    }
}

/// A 60 s running mean of the played anti-noise power per channel. When its RMS is above 6 dB
/// under the peak cap, the cap is held 6 dB lower without disarming, until the mean falls 1.5 dB
/// further. Pure and deterministic: the caller supplies the time and the played peak. A single
/// tone's RMS is its peak less 3 dB, which is the worst case for the sum of tones.
struct ExcursionThermalIntegrator: Equatable, Sendable {
    static let timeConstantSeconds = 60.0
    static let marginBelowCapDB = 6.0
    static let releaseHysteresisDB = 1.5
    static let holdReductionDB = 6.0

    private(set) var meanPower = 0.0
    private(set) var holding = false
    private var lastTime: TimeInterval?

    var holdReductionDB: Double { holding ? Self.holdReductionDB : 0 }

    mutating func reset() {
        self = ExcursionThermalIntegrator()
    }

    /// `nominalCapDBFS` is the cap before any hold. Returns true while the hold is in force.
    @discardableResult
    mutating func update(now: TimeInterval, playedPeakLinear: Double, nominalCapDBFS: Double) -> Bool {
        defer { lastTime = now }
        guard let last = lastTime, now > last else { return holding }
        let dt = now - last
        let peak = playedPeakLinear.isFinite ? max(0, playedPeakLinear) : 0
        let alpha = 1 - exp(-dt / Self.timeConstantSeconds)
        meanPower += alpha * (peak * peak / 2 - meanPower)
        let rmsDB = meanPower > 0 ? 10 * log10(meanPower) : -.infinity
        let limit = nominalCapDBFS - Self.marginBelowCapDB
        if holding {
            if rmsDB < limit - Self.releaseHysteresisDB { holding = false }
        } else if rmsDB > limit {
            holding = true
        }
        return holding
    }
}
