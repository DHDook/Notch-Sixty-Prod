import Foundation

/// E32 S1: one compiled biquad program per distinct (bands, sample rate). The response graph, its
/// band curves, the ghost lane and the Auto range read from it, so a redraw compiles each distinct
/// set once instead of on every body evaluation. Main actor only; not observed (a lookup never
/// invalidates a view). Holds a few dozen entries and starts over when full.
@MainActor
final class EQResponseCache {
    private struct Entry {
        let bands: [EQBand]
        let sampleRate: Double
        let program: [EQResponseSection]
    }

    /// Most recent last. `EQBand` is Equatable, not Hashable, so lookups scan (a few dozen entries).
    private var entries: [Entry] = []
    private let capacity: Int
    /// How many compilations ran (for tests).
    private(set) var compileCount = 0

    /// The one cache the Equalizer page and the auto-preamp's headroom predictor share (E32 S2, G3).
    static let shared = EQResponseCache()

    init(capacity: Int = 96) {
        self.capacity = max(1, capacity)
    }

    func program(bands: [EQBand], sampleRate: Double) -> [EQResponseSection] {
        if let hit = entries.last(where: { $0.sampleRate == sampleRate && $0.bands == bands }) {
            return hit.program
        }
        let program = ProductionEQResponseMath.compile(bands: bands, sampleRate: sampleRate)
        compileCount += 1
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries.append(Entry(bands: bands, sampleRate: sampleRate, program: program))
        return program
    }
}
