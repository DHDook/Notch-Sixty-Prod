import Foundation

/// E4 S30: Conversation Focus upgrade. Control-plane maths only: it consumes in-memory band levels and an
/// envelope, returns numbers, and never records, transcribes or identifies a speaker. Not called from an
/// audio callback. Built dark behind `e4.conversation-unmasking`; the result is applied through the existing
/// ambient-compensation EQ by a later wiring slice.
///
/// Sources: ANSI S3.5-1997 (Speech Intelligibility Index): one-third-octave band-importance weights
/// (normalised to sum 1; no licensed copy is held, so treat them as approximate until checked) and the
/// audibility ramp A = clamp((SNR + 15) / 30, 0, 1). Speech detection uses the syllable-rate (about 4 Hz)
/// envelope modulation of speech (Houtgast and Steeneken, 1985).
enum SpeechIntelligibilityBands {
    /// One-third-octave centres 200 Hz to 8 kHz and their band importance.
    static let centersHz: [Double] = [
        200, 250, 315, 400, 500, 630, 800, 1_000, 1_250, 1_600, 2_000, 2_500, 3_150, 4_000, 5_000, 6_300, 8_000
    ]
    private static let rawImportance: [Double] = [
        0.0095, 0.0150, 0.0289, 0.0440, 0.0578, 0.0653, 0.0711, 0.0818, 0.0844,
        0.0882, 0.0898, 0.0868, 0.0844, 0.0771, 0.0527, 0.0364, 0.0185
    ]
    static let importance: [Double] = {
        let sum = rawImportance.reduce(0, +)
        return rawImportance.map { $0 / sum }
    }()

    static func audibility(snrDB: Double) -> Double {
        min(max((snrDB + 15) / 30, 0), 1)
    }
}

/// Syllable-rate speech detector on an amplitude envelope (not on audio, so nothing speech-like is kept).
enum SpeechModulationDetector {
    /// Block-RMS envelope of `samples` at `envelopeRateHz` (rectify then average).
    static func envelope(samples: [Float], sampleRate: Double, envelopeRateHz: Double = 100) -> [Double] {
        guard sampleRate > 0, envelopeRateHz > 0 else { return [] }
        let block = max(Int(sampleRate / envelopeRateHz), 1)
        var out: [Double] = []
        var i = 0
        while i + block <= samples.count {
            var acc = 0.0
            for j in i..<(i + block) { acc += Double(samples[j]) * Double(samples[j]) }
            out.append((acc / Double(block)).squareRoot())
            i += block
        }
        return out
    }

    /// Speech likelihood 0...1: modulation power at 2...8 Hz relative to 0.5...32 Hz (excluding DC), times a
    /// modulation-depth term. Needs at least 2 s of envelope.
    static func confidence(envelope: [Double], envelopeRateHz: Double = 100) -> Double {
        guard envelopeRateHz >= 64, envelope.count >= Int(2 * envelopeRateHz),
              envelope.allSatisfy(\.isFinite) else { return 0 }
        let mean = envelope.reduce(0, +) / Double(envelope.count)
        guard mean > 1e-9 else { return 0 }
        let x = envelope.map { $0 / mean - 1 }
        var speechPower = 0.0
        var totalPower = 0.0
        var f = 0.5
        while f <= 32 {
            let p = modulationPower(x, frequencyHz: f, rateHz: envelopeRateHz)
            totalPower += p
            if f >= 2 && f <= 8 { speechPower += p }
            f += 0.5
        }
        guard totalPower > 1e-12 else { return 0 }
        let ratio = speechPower / totalPower
        let depth = (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot()
        let ratioTerm = min(max((ratio - 0.35) / 0.4, 0), 1)
        let depthTerm = min(max((depth - 0.15) / 0.35, 0), 1)
        return ratioTerm * depthTerm
    }

    private static func modulationPower(_ x: [Double], frequencyHz: Double, rateHz: Double) -> Double {
        let w = 2 * Double.pi * frequencyHz / rateHz
        var re = 0.0
        var im = 0.0
        for (n, v) in x.enumerated() {
            re += v * cos(w * Double(n))
            im -= v * sin(w * Double(n))
        }
        let n = Double(x.count)
        return (re * re + im * im) / (n * n)
    }
}

struct ConversationUnmaskingConfiguration: Sendable, Equatable {
    /// Largest music cut in any one band.
    var maximumBandCutDB = 6.0
    /// Largest change in overall programme level (power sum, including the untouched bass).
    var maximumOverallCutDB = 3.0
    /// Below this the music is never touched.
    var untouchedBelowHz = 150.0
    var stepDB = 0.5
    /// Speech confidence needed before any cut is planned.
    var minimumSpeechConfidence = 0.5
    /// Per-update movement limits, so a raised voice (Lombard) cannot drive cuts quickly.
    var maximumAttackStepDB = 1.0
    var maximumReleaseStepDB = 0.25
}

struct ConversationUnmaskingInput: Sendable, Equatable {
    /// Speech level at the seat per band (from the ambient residual after playback removal), dB.
    var speechBandLevelsDB: [Double]
    /// Music level at the seat per band (programme through the room position model), dB.
    var musicBandLevelsDB: [Double]
    /// Music level of everything below the first band (untouched), dB; counts toward overall level.
    var lowMusicLevelDB: Double
    var speechConfidence: Double
}

struct ConversationUnmaskingPlan: Sendable, Equatable {
    /// Positive dB of music cut per band, aligned to `SpeechIntelligibilityBands.centersHz`.
    var bandCutsDB: [Double]
    var siiBefore: Double
    var siiAfter: Double
    var overallChangeDB: Double
}

struct ConversationUnmaskingPlanner: Sendable {
    var configuration = ConversationUnmaskingConfiguration()

    func sii(speech: [Double], music: [Double], cuts: [Double]) -> Double {
        var total = 0.0
        for i in 0..<SpeechIntelligibilityBands.centersHz.count {
            total += SpeechIntelligibilityBands.importance[i]
                * SpeechIntelligibilityBands.audibility(snrDB: speech[i] - (music[i] - cuts[i]))
        }
        return total
    }

    /// Greedy: repeatedly cut the band with the most SII gained per dB, until the limits or no gain remain.
    func plan(_ input: ConversationUnmaskingInput) -> ConversationUnmaskingPlan? {
        let n = SpeechIntelligibilityBands.centersHz.count
        guard input.speechBandLevelsDB.count == n, input.musicBandLevelsDB.count == n,
              (input.speechBandLevelsDB + input.musicBandLevelsDB + [input.lowMusicLevelDB, input.speechConfidence])
                .allSatisfy(\.isFinite) else { return nil }
        var cuts = [Double](repeating: 0, count: n)
        let before = sii(speech: input.speechBandLevelsDB, music: input.musicBandLevelsDB, cuts: cuts)
        guard input.speechConfidence >= configuration.minimumSpeechConfidence else {
            return ConversationUnmaskingPlan(bandCutsDB: cuts, siiBefore: before, siiAfter: before, overallChangeDB: 0)
        }
        let basePower = power(input, cuts: cuts)
        let step = configuration.stepDB
        while true {
            var best = -1
            var bestGain = 1e-9
            for i in 0..<n where SpeechIntelligibilityBands.centersHz[i] >= configuration.untouchedBelowHz
                && cuts[i] + step <= configuration.maximumBandCutDB + 1e-9 {
                var trial = cuts
                trial[i] += step
                if overall(input, cuts: trial, base: basePower) < -configuration.maximumOverallCutDB { continue }
                let gain = sii(speech: input.speechBandLevelsDB, music: input.musicBandLevelsDB, cuts: trial)
                    - sii(speech: input.speechBandLevelsDB, music: input.musicBandLevelsDB, cuts: cuts)
                if gain > bestGain { bestGain = gain; best = i }
            }
            if best < 0 { break }
            cuts[best] += step
        }
        let after = sii(speech: input.speechBandLevelsDB, music: input.musicBandLevelsDB, cuts: cuts)
        return ConversationUnmaskingPlan(
            bandCutsDB: cuts, siiBefore: before, siiAfter: after,
            overallChangeDB: overall(input, cuts: cuts, base: basePower)
        )
    }

    /// Moves the applied cuts toward the target with attack and release limits.
    func rateLimited(previous: [Double], target: [Double]) -> [Double] {
        zip(previous, target).map { p, t in
            t > p ? min(t, p + configuration.maximumAttackStepDB) : max(t, p - configuration.maximumReleaseStepDB)
        }
    }

    private func power(_ input: ConversationUnmaskingInput, cuts: [Double]) -> Double {
        var p = pow(10, input.lowMusicLevelDB / 10)
        for i in 0..<cuts.count { p += pow(10, (input.musicBandLevelsDB[i] - cuts[i]) / 10) }
        return p
    }

    private func overall(_ input: ConversationUnmaskingInput, cuts: [Double], base: Double) -> Double {
        10 * log10(power(input, cuts: cuts) / base)
    }
}
