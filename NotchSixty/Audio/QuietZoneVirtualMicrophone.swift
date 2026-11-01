import Foundation

/// E4 S26a: tonal virtual microphone ("remote microphone" technique) for the quiet zone at the ears.
///
/// Pure phasor maths, offline and not wired to any output: nothing here arms or drives anti-noise.
/// Derivation (single tone, single anti-noise output y, complex phasors at the tone frequency):
///   - monitor error  e_mon = d_mon + S_mon y     (the real microphone, always present)
///   - ear error      e_ear = d_ear + S_ear y     (not measured live)
///   - for a steady tone d_ear = R d_mon, with R the monitor-to-ear ratio surveyed at setup.
///   - virtual error  e_virt = R (e_mon - Ŝ_mon y) + Ŝ_ear y = R e_mon + (Ŝ_ear - R Ŝ_mon) y
/// So the S18 worker adapts on e_mon with the effective secondary path Ŝ_eff = Ŝ_ear - R Ŝ_mon.
/// Each ear position is a Room Correction measurement position, so Ŝ_ear comes from its impulse
/// responses. Ratio method (Elliott and Garcia-Bonito, "Active control of sound at a remote
/// microphone", 1995, remote-microphone technique): both visits measure the noise phasor against
/// the canceller oscillator, which the S19 PLL keeps locked, so they are comparable in time.
/// Realtime: not used on an audio thread; pure value maths. Sample rate: only the lock-in
/// helper sees it, and it is exact at any device rate up to 384 kHz.
enum QuietZoneTonePhasor {
    /// Lock-in demodulation of `samples` at `frequencyHz`: the phasor A e^{jφ} of A cos(2π f t + φ),
    /// with t = 0 at the first sample, using a Hann window so a partial cycle count does not bias it.
    static func measure(samples: [Float], frequencyHz: Double, sampleRate: Double) -> ActiveQuietZoneComplex? {
        let n = samples.count
        guard n >= 16, frequencyHz > 0, sampleRate > 0, frequencyHz < sampleRate / 2 else { return nil }
        var re = 0.0, im = 0.0, wsum = 0.0
        let w = 2 * Double.pi * frequencyHz / sampleRate
        for i in 0..<n {
            let win = 0.5 - 0.5 * cos(2 * Double.pi * (Double(i) + 0.5) / Double(n))
            let x = Double(samples[i]) * win
            re += x * cos(w * Double(i))
            im -= x * sin(w * Double(i))
            wsum += win
        }
        guard wsum > 0 else { return nil }
        let scale = 2 / wsum
        return ActiveQuietZoneComplex(real: re * scale, imaginary: im * scale)
    }
}

/// Repeated noise phasors at one position for one tone, each against the canceller oscillator.
struct QuietZoneVirtualMicVisit: Equatable, Sendable {
    var frequencyHz: Double
    var phasors: [ActiveQuietZoneComplex]
}

struct QuietZoneVirtualMicTone: Equatable, Sendable, Identifiable {
    var frequencyHz: Double
    /// d_ear / d_mon for a steady tone.
    var ratio: ActiveQuietZoneComplex
    /// Ŝ_eff = Ŝ_ear - R Ŝ_mon, the path the adaptive core sees through the virtual error.
    var effectiveSecondary: ActiveQuietZoneComplex
    /// Ŝ_ear, the path y takes to the ear (what the virtual error sees against the uncancelled noise).
    var earSecondary: ActiveQuietZoneComplex
    var id: Double { frequencyHz }
}

enum QuietZoneVirtualMicError: Error, Equatable {
    case tooFewRepeats
    case unsteadyNoise(frequencyHz: Double)
    case monitorTooQuiet(frequencyHz: Double)
    case implausibleRatio(frequencyHz: Double)
    case noAuthorityAtEar(frequencyHz: Double)
    case mismatchedTones
}

struct QuietZoneVirtualMicrophone: Sendable {
    static let minimumRepeats = 3
    /// Largest relative scatter (RMS deviation over mean magnitude) tolerated within one visit.
    static let maximumRelativeScatter = 0.25
    static let minimumMonitorMagnitude = 1.0e-6
    /// A remote ear louder than 4 times the monitor means the pair is too far apart to trust.
    static let maximumRatioMagnitude = 4.0
    /// The effective path must keep at least this fraction of the ear path's own magnitude,
    /// otherwise the monitor and the ear see the speaker alike and the virtual error cannot be driven.
    static let minimumEffectiveFraction = 0.1

    var tones: [QuietZoneVirtualMicTone]

    /// Builds the per-tone ratios from one monitor visit and one ear visit per tone, with the secondary
    /// paths measured at each position (keyed by the same frequency order).
    static func survey(
        monitor: [QuietZoneVirtualMicVisit],
        ear: [QuietZoneVirtualMicVisit],
        monitorSecondary: [ActiveQuietZoneComplex],
        earSecondary: [ActiveQuietZoneComplex]
    ) throws -> QuietZoneVirtualMicrophone {
        guard !monitor.isEmpty, monitor.count == ear.count,
              monitor.count == monitorSecondary.count, monitor.count == earSecondary.count else {
            throw QuietZoneVirtualMicError.mismatchedTones
        }
        var out: [QuietZoneVirtualMicTone] = []
        for i in monitor.indices {
            let f = monitor[i].frequencyHz
            guard abs(ear[i].frequencyHz - f) < 0.01 else { throw QuietZoneVirtualMicError.mismatchedTones }
            guard monitor[i].phasors.count >= minimumRepeats, ear[i].phasors.count >= minimumRepeats else {
                throw QuietZoneVirtualMicError.tooFewRepeats
            }
            let m = try mean(monitor[i].phasors, frequencyHz: f)
            let e = try mean(ear[i].phasors, frequencyHz: f)
            guard m.magnitude > minimumMonitorMagnitude else {
                throw QuietZoneVirtualMicError.monitorTooQuiet(frequencyHz: f)
            }
            let r = e / m
            guard r.real.isFinite, r.imaginary.isFinite, r.magnitude <= maximumRatioMagnitude else {
                throw QuietZoneVirtualMicError.implausibleRatio(frequencyHz: f)
            }
            let eff = earSecondary[i] - r * monitorSecondary[i]
            guard eff.magnitude >= minimumEffectiveFraction * max(earSecondary[i].magnitude, 1.0e-12),
                  eff.magnitude > 1.0e-9 else {
                throw QuietZoneVirtualMicError.noAuthorityAtEar(frequencyHz: f)
            }
            out.append(QuietZoneVirtualMicTone(frequencyHz: f, ratio: r, effectiveSecondary: eff, earSecondary: earSecondary[i]))
        }
        return QuietZoneVirtualMicrophone(tones: out)
    }

    private static func mean(_ values: [ActiveQuietZoneComplex], frequencyHz: Double) throws -> ActiveQuietZoneComplex {
        var sum = ActiveQuietZoneComplex.zero
        for v in values { sum = sum + v }
        let mean = sum / Double(values.count)
        guard mean.magnitude > 1.0e-12 else { throw QuietZoneVirtualMicError.monitorTooQuiet(frequencyHz: frequencyHz) }
        var dev = 0.0
        for v in values { let d = v - mean; dev += d.real * d.real + d.imaginary * d.imaginary }
        let scatter = (dev / Double(values.count)).squareRoot() / mean.magnitude
        guard scatter <= maximumRelativeScatter else {
            throw QuietZoneVirtualMicError.unsteadyNoise(frequencyHz: frequencyHz)
        }
        return mean
    }

    /// e_virt = R (e_mon - Ŝ_mon y) + Ŝ_ear y, for the tone at `index`.
    func virtualError(
        toneIndex index: Int,
        monitorError: ActiveQuietZoneComplex,
        output: ActiveQuietZoneComplex,
        monitorSecondary: ActiveQuietZoneComplex,
        earSecondary: ActiveQuietZoneComplex
    ) -> ActiveQuietZoneComplex {
        let t = tones[index]
        return t.ratio * (monitorError - monitorSecondary * output) + earSecondary * output
    }

    /// Damped one-tone solution for the output that minimises the virtual error given the uncancelled
    /// monitor noise d_mon (e_mon with the output's own contribution removed): e_virt = R d_mon + Ŝ_ear y,
    /// so y = -conj(Ŝ_ear) R d_mon / (|Ŝ_ear|² (1 + 3.5 percent)). The adaptive core, which sees only
    /// e_mon, converges to the same point through Ŝ_eff.
    func solve(toneIndex index: Int, uncancelledMonitorNoise: ActiveQuietZoneComplex) -> ActiveQuietZoneComplex {
        let t = tones[index]
        let power = t.earSecondary.magnitude * t.earSecondary.magnitude
        let d = t.ratio * uncancelledMonitorNoise
        return -(t.earSecondary.conjugate * d) / (power * 1.035)
    }
}
