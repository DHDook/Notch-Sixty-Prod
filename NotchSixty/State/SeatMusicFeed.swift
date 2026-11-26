import Foundation

/// E29 S7 (behind `e29.room-model`): carries the seat the listener chose for Conversation Focus from the seat map to
/// the ambient controller. The map publishes the seat's response, the main seat's measured response (the analysis
/// microphone's position), the staleness of both paths and their output-gain stamps; the ambient controller asks for
/// a music prediction once per analysis poll. Main actor only; nothing here runs on the audio thread, and no audio is
/// kept (control-plane numbers only).
@MainActor
final class SeatMusicFeed {
    struct Source: Equatable, Sendable {
        var seatName: String
        var seat: RoomBandResponse?
        var reference: RoomBandResponse?
        var seatPathStale = false
        var referencePathStale = false
        var seatMeasuredGainDB: Double?
        var referenceMeasuredGainDB: Double?
    }

    private(set) var source: Source?
    /// Why the last poll used today's analysis-microphone prediction instead of the seat, or nil when it used the seat.
    private(set) var lastFallback: MusicAtSeatFallback?

    func publish(_ source: Source?) {
        self.source = source
        lastFallback = nil
    }

    /// The seat's music per speech band, or nil (today's prediction) with no chosen seat or on any fallback.
    func prediction(modeledPlayback: [AmbientSpectrumBand]?) -> MusicAtSeatPrediction? {
        guard let source, let modeledPlayback,
              let bands = ThirdOctaveBandAggregator.aggregate(modeledPlayback) else { return nil }
        let input = MusicAtSeatInput(
            programmeBandLevelsDB: bands.bandLevelsDB, reference: source.reference,
            referencePathStale: source.referencePathStale, seat: source.seat, seatPathStale: source.seatPathStale,
            measuredOutputGainDB: source.seatMeasuredGainDB, referenceMeasuredOutputGainDB: source.referenceMeasuredGainDB)
        switch MusicAtSeatPredictor.predict(input) {
        case .success(let prediction):
            lastFallback = nil
            return prediction
        case .failure(let why):
            lastFallback = why
            return nil
        }
    }
}
