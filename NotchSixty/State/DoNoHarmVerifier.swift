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

    /// E4 S22: a tone or band is left out of the check while the music at its frequency is more
    /// than this far above what the band measured with the anti-noise out.
    static let programmeExclusionDB = 6.0
    /// Bands are wider than a tone: a programme tone counts for a band within this ratio.
    static let programmeBandRatio = 1.1225  // 2^(1/6): a third-octave band

    /// The music's level at the microphone at one of the canceller's tone frequencies (peak dBFS),
    /// as the adaptive core measures it after the speaker-to-microphone path.
    struct ProgrammeLevel: Equatable, Sendable {
        var frequencyHz: Double
        var levelDBFS: Double
    }

    /// Latest verified tone reductions, strongest first.
    private(set) var reductions: [SeatVerifiedReduction] = []
    /// Tones and bands (Hz) left out of the last evaluation because music dominated them.
    private(set) var programmeExcludedHz: [Double] = []

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
    mutating func evaluate(
        _ snapshot: AmbientAnalysisSnapshot,
        now: Date,
        programme: [ProgrammeLevel] = []
    ) -> DoNoHarmVerdict {
        guard hasBaseline else { return .baselining }
        var excluded: [Double] = []
        defer { programmeExcludedHz = excluded.sorted() }

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
            if Self.programmeDominates(entry.frequencyHz, base: base, programme: programme, ratio: 1 + Self.toneMatchFraction) {
                excluded.append(entry.frequencyHz)
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
            if Self.programmeDominates(entry.center, base: base, programme: programme, ratio: Self.programmeBandRatio) {
                excluded.append(entry.center)
                continue
            }
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

    /// The seat against the baseline in force, without the harm timer: used by the supervised
    /// microphone-move re-solve (E4 S18b), which applies its own tighter limits.
    struct Measurement: Equatable, Sendable {
        /// Worst tone or band above its baseline, dB (negative when everything is quieter).
        var worstIncreaseDB: Double
        /// Smallest tone reduction against the baseline, dB (positive is quieter); nil when no tone
        /// of the baseline is detected any more.
        var minimumToneReductionDB: Double?
    }

    func measure(_ snapshot: AmbientAnalysisSnapshot, programme: [ProgrammeLevel] = []) -> Measurement? {
        guard hasBaseline else { return nil }
        var worst = -Double.infinity
        var minimumReduction: Double?
        for entry in toneAccumulators {
            guard let base = entry.acc.meanDBFS else { continue }
            guard let live = snapshot.tonalComponents.first(where: { Self.sameTone($0.frequencyHz, entry.frequencyHz) }),
                  live.levelDBFS.isFinite else {
                // Not detected any more: cancelled below the detector, so at least a large reduction.
                continue
            }
            if Self.programmeDominates(entry.frequencyHz, base: base, programme: programme, ratio: 1 + Self.toneMatchFraction) { continue }
            let delta = live.levelDBFS - base
            worst = max(worst, delta)
            minimumReduction = min(minimumReduction ?? .infinity, -delta)
        }
        for entry in bandAccumulators {
            guard let base = entry.acc.meanDBFS,
                  let live = snapshot.spectrum.first(where: { Self.sameBand($0.centerFrequencyHz, entry.center) }),
                  live.levelDBFS.isFinite else { continue }
            if Self.programmeDominates(entry.center, base: base, programme: programme, ratio: Self.programmeBandRatio) { continue }
            worst = max(worst, live.levelDBFS - base)
        }
        return Measurement(worstIncreaseDB: worst, minimumToneReductionDB: minimumReduction)
    }

    /// Drops the baseline so the next windows (taken with the anti-noise out) capture a new one.
    /// Until it is complete `evaluate` reports `.baselining`.
    mutating func beginRebaseline() {
        toneAccumulators.removeAll()
        bandAccumulators.removeAll()
        baselineWindows = 0
        violatingSince = nil
        okWindows = 0
        reductions = []
        programmeExcludedHz = []
    }

    /// "-12 dB at 43 Hz, verified", or nil when no tone is verified yet. While music dominates a
    /// tone the readout says so ("music at 43 Hz, not checked") instead of reporting it.
    var readout: String? {
        let note = programmeNote
        guard let best = reductions.first else { return note }
        let db = Int(best.reductionDB.rounded())
        let hz = Int(best.frequencyHz.rounded())
        let text = "\u{2212}\(db) dB at \(hz) Hz, verified"
        return note.map { "\(text); \($0)" } ?? text
    }

    private var programmeNote: String? {
        guard !programmeExcludedHz.isEmpty else { return nil }
        var shown: [Int] = []
        for hz in programmeExcludedHz.map({ Int($0.rounded()) }) where !shown.contains(hz) { shown.append(hz) }
        return "music at " + shown.prefix(3).map { "\($0) Hz" }.joined(separator: ", ") + ", not checked"
    }

    /// True when the music at the entry's frequency is more than `programmeExclusionDB` above
    /// the entry's baseline: what the microphone reads there is mostly music, not noise.
    private static func programmeDominates(_ hz: Double, base: Double, programme: [ProgrammeLevel], ratio: Double) -> Bool {
        programme.contains { p in
            p.levelDBFS.isFinite && max(hz, p.frequencyHz) <= min(hz, p.frequencyHz) * ratio
                && p.levelDBFS > base + programmeExclusionDB
        }
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
