import Foundation

/// E4 S30b: turns the ambient analyser's band spectra into the planner's inputs. Control-plane maths only
/// (no audio callback, no recording): it consumes band levels and returns numbers.
///
/// The analyser reports log-spaced bands (about 6 per octave, 20 Hz to 20 kHz). Each is spread uniformly in
/// log frequency and re-binned onto the 17 one-third-octave SII bands, so band power is conserved.
enum ThirdOctaveBandAggregator {
    struct Result: Equatable, Sendable {
        /// Power level (same dB reference as the input) in each SII band.
        var bandLevelsDB: [Double]
        /// Level of everything outside the 17 bands (below about 178 Hz and above about 9 kHz).
        var outsideLevelDB: Double
    }

    /// Nil when the spectrum does not cover every SII band, for example at a rate whose analysis stops early.
    static func aggregate(_ bands: [AmbientSpectrumBand]) -> Result? {
        guard !bands.isEmpty,
              bands.allSatisfy({ $0.levelDBFS.isFinite && $0.lowerFrequencyHz > 0
                  && $0.upperFrequencyHz > $0.lowerFrequencyHz }) else { return nil }
        let half = pow(2.0, 1.0 / 6.0)
        var inBands = [Double](repeating: 0, count: SpeechIntelligibilityBands.centersHz.count)
        var coverage = inBands
        var total = 0.0
        for band in bands {
            let power = pow(10, band.levelDBFS / 10)
            total += power
            let width = log(band.upperFrequencyHz / band.lowerFrequencyHz)
            for (j, center) in SpeechIntelligibilityBands.centersHz.enumerated() {
                let low = max(band.lowerFrequencyHz, center / half)
                let high = min(band.upperFrequencyHz, center * half)
                guard high > low else { continue }
                inBands[j] += power * log(high / low) / width
                coverage[j] += log(high / low)
            }
        }
        let bandWidth = log(half * half)
        guard coverage.allSatisfy({ $0 >= 0.98 * bandWidth }) else { return nil }
        let outside = max(total - inBands.reduce(0, +), 0)
        return Result(bandLevelsDB: inBands.map { dB($0) }, outsideLevelDB: dB(outside))
    }

    static func dB(_ power: Double) -> Double { 10 * log10(max(power, 1e-20)) }
}

enum ConversationUnmaskingInputBuilder {
    /// Speech power is the residual minus the quiet baseline, never below this far under the baseline.
    static let speechFloorBelowBaselineDB = 20.0

    enum Unavailable: Error, Equatable, Sendable {
        case noPlaybackModel
        case noBaseline
        case incompleteSpectrum
        case invalidAppliedCuts
    }

    /// - residual: band spectrum of the ambient residual after playback removal (speech plus noise).
    /// - playback: the analyser's scaled playback prediction at the microphone, which includes any cut
    ///   already applied; `appliedCutsDB` (positive dB per SII band) is added back so the planner works from
    ///   the uncut music and does not chase its own output.
    /// - baseline: the stored quiet-room spectrum, which is the noise masker.
    static func build(
        residual: [AmbientSpectrumBand],
        playback: [AmbientSpectrumBand]?,
        baseline: [AmbientSpectrumBand]?,
        appliedCutsDB: [Double],
        speechConfidence: Double
    ) -> Swift.Result<ConversationUnmaskingInput, Unavailable> {
        guard let playback else { return .failure(.noPlaybackModel) }
        guard let baseline else { return .failure(.noBaseline) }
        let n = SpeechIntelligibilityBands.centersHz.count
        guard appliedCutsDB.count == n, appliedCutsDB.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return .failure(.invalidAppliedCuts)
        }
        guard let res = ThirdOctaveBandAggregator.aggregate(residual),
              let music = ThirdOctaveBandAggregator.aggregate(playback),
              let noise = ThirdOctaveBandAggregator.aggregate(baseline) else {
            return .failure(.incompleteSpectrum)
        }
        let floor = pow(10, -speechFloorBelowBaselineDB / 10)
        var speech: [Double] = []
        for i in 0..<n {
            let baselinePower = pow(10, noise.bandLevelsDB[i] / 10)
            let residualPower = pow(10, res.bandLevelsDB[i] / 10)
            speech.append(ThirdOctaveBandAggregator.dB(max(residualPower - baselinePower, baselinePower * floor)))
        }
        return .success(ConversationUnmaskingInput(
            speechBandLevelsDB: speech,
            musicBandLevelsDB: zip(music.bandLevelsDB, appliedCutsDB).map { $0 + $1 },
            lowMusicLevelDB: music.outsideLevelDB,
            speechConfidence: speechConfidence,
            noiseBandLevelsDB: noise.bandLevelsDB
        ))
    }
}

/// Why Conversation Focus is not using per-band unmasking and keeps today's broad cut (question 22).
enum ConversationUnmaskingFallback: Equatable, Sendable {
    case notConversationFocus
    case notPlaying
    case lowSeparationConfidence
    case noPlaybackModel
    case noBaseline
    case incompleteSpectrum
    case invalidAppliedCuts
    /// Fewer than 2 s of envelope: speech cannot be judged yet.
    case shortEnvelope
}

enum ConversationUnmaskingStatus: Equatable, Sendable {
    case planned(ConversationUnmaskingPlan)
    case fallback(ConversationUnmaskingFallback)
}

struct ConversationUnmaskingEvaluation: Equatable, Sendable {
    var status: ConversationUnmaskingStatus
    var speechConfidence: Double
    /// The planner's input for this poll when it was complete (nil on fallback).
    var input: ConversationUnmaskingInput?
}

enum ConversationUnmaskingEvaluator {
    /// Minimum envelope history before speech is judged (the detector's own requirement).
    static let minimumEnvelopeSeconds = 2.0

    /// One poll's plan. Nothing is applied: S30c rate-limits and sends the cuts.
    static func evaluate(
        mode: ActiveAcousticsPlaybackAdaptationMode,
        running: Bool,
        detailed: AmbientAnalysisDetailedResult,
        quietBaseline: [AmbientSpectrumBand]?,
        envelopeSeconds: Double,
        speechConfidence: Double,
        appliedCutsDB: [Double],
        minimumSeparationConfidence: Double,
        planner: ConversationUnmaskingPlanner = ConversationUnmaskingPlanner()
    ) -> ConversationUnmaskingEvaluation {
        func fallback(_ reason: ConversationUnmaskingFallback) -> ConversationUnmaskingEvaluation {
            ConversationUnmaskingEvaluation(status: .fallback(reason), speechConfidence: speechConfidence, input: nil)
        }
        guard mode == .conversationFocus else { return fallback(.notConversationFocus) }
        guard running else { return fallback(.notPlaying) }
        let snapshot = detailed.snapshot
        guard snapshot.separationMode == .modeledPlaybackSubtraction,
              detailed.modeledPlaybackSpectrum != nil else { return fallback(.noPlaybackModel) }
        guard snapshot.separationConfidence >= minimumSeparationConfidence else {
            return fallback(.lowSeparationConfidence)
        }
        guard envelopeSeconds >= minimumEnvelopeSeconds else { return fallback(.shortEnvelope) }
        switch ConversationUnmaskingInputBuilder.build(
            residual: snapshot.spectrum,
            playback: detailed.modeledPlaybackSpectrum,
            baseline: quietBaseline,
            appliedCutsDB: appliedCutsDB,
            speechConfidence: speechConfidence
        ) {
        case .failure(let reason):
            switch reason {
            case .noPlaybackModel: return fallback(.noPlaybackModel)
            case .noBaseline: return fallback(.noBaseline)
            case .incompleteSpectrum: return fallback(.incompleteSpectrum)
            case .invalidAppliedCuts: return fallback(.invalidAppliedCuts)
            }
        case .success(let input):
            guard let plan = planner.plan(input) else { return fallback(.incompleteSpectrum) }
            return ConversationUnmaskingEvaluation(
                status: .planned(plan), speechConfidence: speechConfidence, input: input
            )
        }
    }
}
