import Foundation

// E12 S16b (G119): the per-driver rows of the distances and levels table, for arrangements that run the routing matrix.
// One row per way: level trim, delay (shown as distance, like the feed table) and polarity, edited in the routing
// configuration the engine renders. A way has no "measured" value to compare to (the alignment step records feeds only),
// so a row is never marked as changed by hand.

struct SpeakerDriverRow: Identifiable, Equatable, Sendable {
    var id: UUID
    var speaker: String
    var name: String
    var role: DriverRole?
    var trimDB: Double
    var delayMs: Double
    var polarityInverted: Bool
    /// The row's label: the speaker and, when it has several drivers, the way.
    var title: String { speaker.isEmpty || speaker == name ? name : "\(speaker) \(name)" }
}

enum SpeakerDriverTable {
    static let trimRangeDB = -60.0...24.0
    static let delayRangeMs = 0.0...50.0

    /// The rows of an enabled routing, in speaker then way order; empty otherwise.
    static func rows(routing: SpeakerRoutingConfiguration?) -> [SpeakerDriverRow] {
        guard let routing, routing.enabled else { return [] }
        return routing.speakers.flatMap { speaker in
            speaker.ways.map { way in
                SpeakerDriverRow(
                    id: way.id, speaker: speaker.name, name: way.name.isEmpty ? (way.role?.displayName ?? "Driver") : way.name,
                    role: way.role, trimDB: way.trimDB, delayMs: way.delayMilliseconds,
                    polarityInverted: way.polarityInverted)
            }
        }
    }

    /// `routing` with one way's trim, delay or polarity changed. Values are clamped to the supported ranges.
    static func editing(
        _ routing: SpeakerRoutingConfiguration, way id: UUID, _ edit: (inout SpeakerDriverRow) -> Void
    ) -> SpeakerRoutingConfiguration {
        var result = routing
        for s in result.speakers.indices {
            guard let w = result.speakers[s].ways.firstIndex(where: { $0.id == id }) else { continue }
            let way = result.speakers[s].ways[w]
            var row = SpeakerDriverRow(
                id: way.id, speaker: result.speakers[s].name, name: way.name, role: way.role, trimDB: way.trimDB,
                delayMs: way.delayMilliseconds, polarityInverted: way.polarityInverted)
            edit(&row)
            let trim = row.trimDB.isFinite ? row.trimDB : 0
            let delay = row.delayMs.isFinite ? row.delayMs : 0
            result.speakers[s].ways[w].trimDB = min(max(trim, trimRangeDB.lowerBound), trimRangeDB.upperBound)
            result.speakers[s].ways[w].delayMilliseconds = min(max(delay, delayRangeMs.lowerBound), delayRangeMs.upperBound)
            result.speakers[s].ways[w].polarityInverted = row.polarityInverted
        }
        return result
    }
}

@MainActor
enum SpeakerDriverTableEditor {
    /// Writes one way's change to the engine's routing (live when the outputs are unchanged). A calibrated system is
    /// stamped first (G91), so the change reads as made after the calibration.
    static func edit(
        way id: UUID, engine: AudioIOEngine, profiles: ProductProfileController, _ change: (inout SpeakerDriverRow) -> Void
    ) throws {
        guard let routing = engine.speakerRoutingConfiguration, routing.enabled else { return }
        profiles.stampBeforeManualChange(hadConfiguration: true)
        try engine.replaceSpeakerRoutingConfiguration(SpeakerDriverTable.editing(routing, way: id, change))
    }
}
