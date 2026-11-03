import Combine
import Foundation

/// Collects the ambient spectrum over time into the per-band level, spread and floor that
/// `QuietZoneNoiseSurvey` needs (E4 S28). Pure value logic; no timers, no audio-thread use.
struct QuietZoneNoiseSurveyAccumulator: Equatable {
    /// Snapshots kept per band (the ambient monitor publishes about once a second).
    static let windowCount = 60
    /// Fewest snapshots before a survey is offered, so spread and floor mean something.
    static let minimumCount = 8

    private var history: [Double: [Double]] = [:]
    private(set) var count = 0

    mutating func ingest(_ spectrum: [AmbientSpectrumBand]) {
        guard !spectrum.isEmpty else { return }
        for band in spectrum where band.levelDBFS.isFinite {
            var values = history[band.centerFrequencyHz, default: []]
            values.append(band.levelDBFS)
            if values.count > Self.windowCount { values.removeFirst(values.count - Self.windowCount) }
            history[band.centerFrequencyHz] = values
        }
        count = min(count + 1, Self.windowCount)
    }

    mutating func reset() {
        history.removeAll()
        count = 0
    }

    var isReady: Bool { count >= Self.minimumCount }

    /// Bands in dB. `offsetDB` converts dBFS to dB SPL (0 when the microphone is not calibrated).
    /// The floor is the median level of the other bands within an octave: a steady tone stands out
    /// from its surroundings, while a broad rumble has no excess over its own neighbours.
    func bands(offsetDB: Double) -> [QuietZoneSurveyBand] {
        var stats: [(f: Double, mean: Double, spread: Double)] = []
        for (centerHz, values) in history where values.count >= Self.minimumCount {
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            stats.append((centerHz, mean, variance.squareRoot()))
        }
        stats.sort { $0.f < $1.f }
        return stats.map { entry in
            let neighbours = stats
                .filter { $0.f != entry.f && $0.f >= entry.f / 2 && $0.f <= entry.f * 2 }
                .map(\.mean)
                .sorted()
            let floor = neighbours.isEmpty ? entry.mean : neighbours[neighbours.count / 2]
            return QuietZoneSurveyBand(
                centerHz: entry.f, levelDB: entry.mean + offsetDB,
                spreadDB: entry.spread, floorDB: min(floor, entry.mean) + offsetDB)
        }
    }
}

/// Holds the latest noise survey for the Quiet Zone card and the measurement report.
/// Measurement only: it never plays anything and is never read by the arm path.
@MainActor
final class QuietZoneNoiseSurveyController: ObservableObject {
    @Published private(set) var report: QuietZoneNoiseSurveyReport?
    /// False when the microphone has no dBFS-to-SPL calibration: figures are then relative.
    @Published private(set) var isCalibratedToSPL = false
    @Published private(set) var snapshotCount = 0

    private var accumulator = QuietZoneNoiseSurveyAccumulator()
    private var cancellable: AnyCancellable?
    private var splOffsetDB: Double?

    func attach(to ambient: AmbientCompensationController) {
        cancellable = ambient.$latestAnalysis
            .compactMap { $0 }
            .sink { [weak self] snapshot in self?.ingest(snapshot) }
    }

    func ingest(_ snapshot: AmbientAnalysisSnapshot) {
        // The snapshot carries SPL for the whole ambient level; the offset is SPL minus dBFS.
        if let spl = snapshot.ambientLevelDBSPL, snapshot.ambientLevelDBFS.isFinite {
            splOffsetDB = spl - snapshot.ambientLevelDBFS
        } else {
            splOffsetDB = nil
        }
        accumulator.ingest(snapshot.spectrum)
        snapshotCount = accumulator.count
        isCalibratedToSPL = splOffsetDB != nil
        report = accumulator.isReady
            ? QuietZoneNoiseSurvey.survey(bands: accumulator.bands(offsetDB: splOffsetDB ?? 0), coherence: nil)
            : nil
    }

    func reset() {
        accumulator.reset()
        report = nil
        snapshotCount = 0
    }
}
