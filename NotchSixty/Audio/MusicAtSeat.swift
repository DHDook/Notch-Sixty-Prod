import Foundation

// E29 S6 (behind `e29.room-model`): music SPL per third-octave band at the listening seat, for E4's Conversation
// Focus planner (S30). Programme band levels plus the seat's measured (or derived, with confidence) magnitude plus the
// output-gain change since the path was measured. Control plane only: it reads levels and returns numbers; no
// recording is made or kept. Low confidence, a missing or stale response, or an unavailable band falls back to
// today's analysis-microphone prediction (`modeledPlaybackSpectrum`).
//
// Unit assumption (gap G12): the seat response is in the core's reference (dB re 1 per unit of impulse-response sum),
// so the prediction is the programme's scale plus the path's level. Matching it to the analysis microphone's dBFS
// scale needs the E22 pink-noise bench check.

struct MusicAtSeatInput: Sendable {
    /// Programme level per band, aligned to `SpeechIntelligibilityBands.centersHz` (dB, same scale as the feed).
    var programmeBandLevelsDB: [Double]
    /// The seat's response from the speakers (power-summed left and right), nil when none exists.
    var seat: RoomBandResponse?
    /// True when `RoomModelRule` marks any contributing path stale.
    var seatPathStale: Bool = false
    /// Output gain now and when the path was measured (volume plus headroom, dB); a missing stamp counts as no change.
    var currentOutputGainDB: Double?
    var measuredOutputGainDB: Double?
}

enum MusicAtSeatFallback: Error, Equatable, Sendable {
    case invalidProgramme
    case noSeatResponse
    case stalePath
    case bandUnavailable
    case lowConfidence
}

struct MusicAtSeatPrediction: Equatable, Sendable {
    /// Aligned to `SpeechIntelligibilityBands.centersHz`.
    var bandLevelsDB: [Double]
    var meanConfidence: Double
    var minimumConfidence: Double
    var derived: Bool
}

enum MusicAtSeatPredictor {
    /// Importance-weighted confidence below this takes the fallback.
    static let minimumConfidence = 0.5

    static func predict(_ input: MusicAtSeatInput, minimumConfidence: Double = minimumConfidence)
        -> Swift.Result<MusicAtSeatPrediction, MusicAtSeatFallback> {
        let centres = SpeechIntelligibilityBands.centersHz
        guard input.programmeBandLevelsDB.count == centres.count,
              input.programmeBandLevelsDB.allSatisfy(\.isFinite) else { return .failure(.invalidProgramme) }
        guard let seat = input.seat else { return .failure(.noSeatResponse) }
        guard !input.seatPathStale else { return .failure(.stalePath) }
        var gain = 0.0
        if let now = input.currentOutputGainDB, let then = input.measuredOutputGainDB, now.isFinite, then.isFinite {
            gain = now - then
        }
        var levels: [Double] = []
        var weighted = 0.0
        var weights = 0.0
        var minimum = 1.0
        for (i, centre) in centres.enumerated() {
            guard let k = seat.bandIndex(nearest: centre), seat.available[k], seat.levelsDB[k].isFinite else {
                return .failure(.bandUnavailable)
            }
            levels.append(input.programmeBandLevelsDB[i] + seat.levelsDB[k] + gain)
            let w = SpeechIntelligibilityBands.importance[i]
            weighted += w * seat.confidence[k]
            weights += w
            minimum = min(minimum, seat.confidence[k])
        }
        let mean = weights > 0 ? weighted / weights : 0
        guard mean >= minimumConfidence else { return .failure(.lowConfidence) }
        return .success(MusicAtSeatPrediction(
            bandLevelsDB: levels, meanConfidence: mean, minimumConfidence: minimum, derived: seat.isDerived))
    }
}
