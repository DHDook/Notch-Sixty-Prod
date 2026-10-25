import Foundation

/// E11 S10: live overlays. Pure functions, no audio-thread involvement.
enum MeasurementOverlays {
    /// Measurement plus the response of the current EQ program: `measured(f) + EQ(f)` in dB.
    /// This is a prediction from the filter coefficients, not a post-DSP transfer measurement.
    static func predicted(
        measurement: RoomCorrectionFrequencyResponse,
        program: [N60BiquadCoefficients],
        sampleRate: Double
    ) -> RoomCorrectionFrequencyResponse {
        let magnitude = zip(measurement.frequenciesHz, measurement.magnitudeDB).map { frequency, db in
            db + ProductionEQResponseMath.responseDB(program: program, sampleRate: sampleRate, frequencyHz: frequency)
        }
        return RoomCorrectionFrequencyResponse(
            frequenciesHz: measurement.frequenciesHz, magnitudeDB: magnitude, phaseRadians: nil)
    }

    /// RTA bands as a curve for plotting. Bands at or below the analyser floor are dropped. With
    /// `relativeToMean` the level is shown relative to the mean of the remaining bands (the EQ view
    /// is a gain plot, so absolute SPL has no meaning there).
    static func rtaCurve(spectrum: RTASpectrum?, relativeToMean: Bool) -> RoomCorrectionFrequencyResponse? {
        guard let spectrum, spectrum.centresHz.count == spectrum.levelsDB.count else { return nil }
        let floor = Double(N60_SPL_FLOOR_DB) + 1
        let pairs = zip(spectrum.centresHz, spectrum.levelsDB).filter { $0.1 > floor && $0.1.isFinite }
        guard pairs.count >= 2 else { return nil }
        let shift = relativeToMean ? pairs.map(\.1).reduce(0, +) / Double(pairs.count) : 0
        return RoomCorrectionFrequencyResponse(
            frequenciesHz: pairs.map(\.0), magnitudeDB: pairs.map { $0.1 - shift }, phaseRadians: nil)
    }
}

/// Carries the latest RTA curve from the RTA card to the Equalizer view.
@MainActor
final class MeasurementLiveOverlayStore: ObservableObject {
    static let shared = MeasurementLiveOverlayStore()
    @Published var rtaCurve: RoomCorrectionFrequencyResponse?
    @Published var showsRTA = true
}
