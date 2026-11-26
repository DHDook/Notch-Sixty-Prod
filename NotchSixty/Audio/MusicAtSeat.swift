import Foundation

// E29 S6 (behind `e29.room-model`): music SPL per third-octave band at the listening seat, for E4's Conversation
// Focus planner (S30). Programme band levels plus the seat's measured (or derived, with confidence) magnitude plus the
// output-gain change since the path was measured. Control plane only: it reads levels and returns numbers; no
// recording is made or kept. Low confidence, a missing or stale response, or an unavailable band falls back to
// today's analysis-microphone prediction (`modeledPlaybackSpectrum`).
//
// Scale (E29 S7, gap G15): the seat response is in the core's reference, which is not the analysis microphone's dBFS
// scale. The programme levels are the analyser's modelled playback at the microphone (dBFS, and they already carry any
// applied Conversation Focus cut). The microphone sits at the main seat, so the prediction is those levels plus the
// seat's response relative to the main seat's measured response: the core's reference cancels and no absolute
// calibration is needed. Without a measured, fresh main-seat reference the predictor falls back.

struct MusicAtSeatInput: Sendable {
    /// Programme level per band at the analysis microphone, aligned to `SpeechIntelligibilityBands.centersHz` (dBFS).
    var programmeBandLevelsDB: [Double]
    /// The measured response at the analysis microphone's own seat (the main seat); nil when none exists.
    var reference: RoomBandResponse?
    /// True when `RoomModelRule` marks the reference path stale.
    var referencePathStale: Bool = false
    /// The seat's response from the speakers (power-summed left and right), nil when none exists.
    var seat: RoomBandResponse?
    /// True when `RoomModelRule` marks any contributing path stale.
    var seatPathStale: Bool = false
    /// Output gain (volume plus headroom, dB) when the seat's path and the reference path were measured; a missing
    /// stamp counts as no change. A gain difference between the two measurements is removed from the comparison.
    var measuredOutputGainDB: Double?
    var referenceMeasuredOutputGainDB: Double?
}

enum MusicAtSeatFallback: Error, Equatable, Sendable {
    case invalidProgramme
    case noSeatResponse
    case noReference
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
        guard let reference = input.reference, !reference.isDerived else { return .failure(.noReference) }
        guard !input.seatPathStale, !input.referencePathStale else { return .failure(.stalePath) }
        // A louder measurement of the seat than of the reference would overstate the seat; take the difference out.
        var gain = 0.0
        if let seatGain = input.measuredOutputGainDB, let referenceGain = input.referenceMeasuredOutputGainDB,
           seatGain.isFinite, referenceGain.isFinite {
            gain = referenceGain - seatGain
        }
        var levels: [Double] = []
        var weighted = 0.0
        var weights = 0.0
        var minimum = 1.0
        for (i, centre) in centres.enumerated() {
            guard let k = seat.bandIndex(nearest: centre), seat.available[k], seat.levelsDB[k].isFinite,
                  let r = reference.bandIndex(nearest: centre), reference.available[r], reference.levelsDB[r].isFinite
            else { return .failure(.bandUnavailable) }
            levels.append(input.programmeBandLevelsDB[i] + (seat.levelsDB[k] - reference.levelsDB[r]) + gain)
            let w = SpeechIntelligibilityBands.importance[i]
            let c = min(seat.confidence[k], reference.confidence[r])
            weighted += w * c
            weights += w
            minimum = min(minimum, c)
        }
        let mean = weights > 0 ? weighted / weights : 0
        guard mean >= minimumConfidence else { return .failure(.lowConfidence) }
        return .success(MusicAtSeatPrediction(
            bandLevelsDB: levels, meanConfidence: mean, minimumConfidence: minimum, derived: seat.isDerived))
    }
}
