import Foundation

/// One verified result for the user: how much quieter a tone is at the seat than before arming.
struct SeatVerifiedReduction: Equatable, Sendable {
    var frequencyHz: Double
    /// Positive means quieter than the ANC-off baseline.
    var reductionDB: Double
}

/// What the seat microphone says about the live anti-noise (E4 S16).
enum DoNoHarmVerdict: Equatable, Sendable {
    /// Still capturing the ANC-off baseline (no anti-noise has played yet).
    case baselining
    /// Nothing worse than baseline beyond the limit.
    case ok
    /// A tone or band is worse than baseline, but not yet for long enough to act.
    case warning
    /// Worse than baseline by more than the limit for the whole window: back off and disarm.
    case harm(frequencyHz: Double, increaseDB: Double)
}

/// Runtime form of the "other seats" and "waterbed" targets in `docs/ANC_QUALIFICATION.md`:
/// the level at the seat microphone must not rise above what it was with ANC off.
///
/// - The baseline is the power average of the first `baselineWindowCount` analysis windows taken
///   at arming, before any anti-noise plays, per detected tone and per spectrum band in
///   20-500 Hz.
/// - While armed, any tone or band louder than its baseline by more than
///   `QuietZoneQualificationTargets.maximumOtherSeatIncreaseDB` in every analysis window for
///   `harmSeconds` is reported as `.harm`; the owner then ramps the anti-noise out and disarms.
/// - Pure value logic on the control plane (main actor). Never on the audio thread; it consumes
///   analysis snapshots, which are independent of the device sample rate.
struct DoNoHarmVerifier: Sendable {
    static let harmSeconds = 2.0
    static let baselineWindowCount = 3
    static let minimumBandHz = 20.0
    static let maximumBandHz = 500.0
    /// Tones are the same tone when within this fraction of each other.
    static let toneMatchFraction = 0.03
    /// A tone must be at least this much quieter to be shown as a verified reduction.
    static let readoutMinimumReductionDB = 1.0
    /// Quiet windows needed before a reduction is shown as verified.
    static let readoutVerifiedWindows = 3

    private struct Accumulator {
        var power: Double = 0
        var count = 0
        mutating func add(_ dbfs: Double) { power += pow(10, dbfs / 10); count += 1 }
        var meanDBFS: Double? { count > 0 ? 10 * log10(power / Double(count)) : nil }
    }

    private var toneAccumulators: [(frequencyHz: Double, acc: Accumulator)] = []
    private var bandAccumulators: [(center: Double, acc: Accumulator)] = []
    private var baselineWindows = 0
    private var violatingSince: Date?
    private var okWindows = 0

    /// Latest verified tone reductions, strongest first.
    private(set) var reductions: [SeatVerifiedReduction] = []

    var hasBaseline: Bool { baselineWindows >= Self.baselineWindowCount }

    mutating func reset() { self = DoNoHarmVerifier() }

    /// Feeds one analysis window taken while no anti-noise plays.
    mutating func captureBaseline(_ snapshot: AmbientAnalysisSnapshot) {
        guard !hasBaseline else { return }
        baselineWindows += 1
        for tone in snapshot.tonalComponents where Self.inRange(tone.frequencyHz) && tone.levelDBFS.isFinite {
            if let i = toneAccumulators.firstIndex(where: { Self.sameTone($0.frequencyHz, tone.frequencyHz) }) {
                toneAccumulators[i].acc.add(tone.levelDBFS)
            } else {
                var acc = Accumulator()
                acc.add(tone.levelDBFS)
                toneAccumulators.append((tone.frequencyHz, acc))
            }
        }
        for band in snapshot.spectrum where Self.inRange(band.centerFrequencyHz) && band.levelDBFS.isFinite {
            if let i = bandAccumulators.firstIndex(where: { Self.sameBand($0.center, band.centerFrequencyHz) }) {
                bandAccumulators[i].acc.add(band.levelDBFS)
            } else {
                var acc = Accumulator()
                acc.add(band.levelDBFS)
                bandAccumulators.append((band.centerFrequencyHz, acc))
            }
        }
    }

    /// Compares one analysis window taken while the anti-noise may be playing with the baseline.
    mutating func evaluate(_ snapshot: AmbientAnalysisSnapshot, now: Date) -> DoNoHarmVerdict {
        guard hasBaseline else { return .baselining }

        var worst: (frequencyHz: Double, increaseDB: Double)?
        func consider(_ frequencyHz: Double, _ increase: Double) {
            guard increase > QuietZoneQualificationTargets.maximumOtherSeatIncreaseDB else { return }
            if worst == nil || increase > worst!.increaseDB { worst = (frequencyHz, increase) }
        }

        var newReductions: [SeatVerifiedReduction] = []
        for entry in toneAccumulators {
            guard let base = entry.acc.meanDBFS,
                  let live = snapshot.tonalComponents.first(where: {
                      Self.sameTone($0.frequencyHz, entry.frequencyHz)
                  }) else {
                // A tone that is no longer detected was cancelled below the detector or is gone;
                // either way it is not louder.
                continue
            }
            let delta = live.levelDBFS - base
            if live.levelDBFS.isFinite { consider(entry.frequencyHz, delta) }
            if -delta >= Self.readoutMinimumReductionDB {
                newReductions.append(.init(frequencyHz: entry.frequencyHz, reductionDB: -delta))
            }
        }
        for entry in bandAccumulators {
            guard let base = entry.acc.meanDBFS,
                  let live = snapshot.spectrum.first(where: { Self.sameBand($0.centerFrequencyHz, entry.center) }),
                  live.levelDBFS.isFinite else { continue }
            consider(entry.center, live.levelDBFS - base)
        }

        if let worst {
            okWindows = 0
            reductions = []
            let since = violatingSince ?? now
            violatingSince = since
            if now.timeIntervalSince(since) >= Self.harmSeconds {
                return .harm(frequencyHz: worst.frequencyHz, increaseDB: worst.increaseDB)
            }
            return .warning
        }
        violatingSince = nil
        okWindows += 1
        reductions = okWindows >= Self.readoutVerifiedWindows
            ? newReductions.sorted { $0.reductionDB > $1.reductionDB } : []
        return .ok
    }

    /// "-12 dB at 43 Hz, verified", or nil when no tone is verified yet.
    var readout: String? {
        guard let best = reductions.first else { return nil }
        let db = Int(best.reductionDB.rounded())
        let hz = Int(best.frequencyHz.rounded())
        return "\u{2212}\(db) dB at \(hz) Hz, verified"
    }

    private static func inRange(_ hz: Double) -> Bool {
        hz >= minimumBandHz && hz <= maximumBandHz
    }

    private static func sameTone(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(a, b) * toneMatchFraction
    }

    private static func sameBand(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(a, b) * 0.01
    }
}
