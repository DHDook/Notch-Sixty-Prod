import Foundation

// E12 S28 (behind `e12.blind-listening`): what a finished blind test leaves behind. Control plane only, main thread.
// Allocation: allocates (offline). Synchronisation: none; the store is used from the main actor. No audio thread
// reads any of this. Reset: the user clears the list from the page; the backup carries it.

/// One finished blind test, kept locally. This is also the export: it holds no internal fields, only what the user did.
struct BlindTestRecord: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    enum Kind: String, Codable, Sendable { case canIHearIt, preference, twoFiles }

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID
    var date: Date
    var kind: Kind
    var sideA: String
    var sideB: String
    var trialCount: Int
    /// Can-I-hear-it tests only: answers that were right.
    var correctCount: Int?
    /// Preference tests only: how often each side was chosen.
    var preferredA: Int?
    var preferredB: Int?
    var pValue: Double
    var outcome: String
    /// Can-I-hear-it tests only: one entry per trial, true when the answer was right.
    var trialsCorrect: [Bool]?

    /// What the list shows: "16 Nov 2026: Current settings against Processing off, 13 of 16 correct".
    var title: String { "\(sideA) against \(sideB)" }
}

enum BlindTestRecords {
    /// Plain sentence for the result of a can-I-hear-it test.
    static func abxOutcome(correct: Int, trials: Int, pValue: Double) -> String {
        let head = "\(correct) of \(trials) correct."
        return head + (pValue < BlindComparisonStatistics.alpha
            ? " More than guessing would give."
            : " Within what guessing gives; this does not prove there is no difference.")
    }

    static func preferenceOutcome(preferredA: Int, preferredB: Int, pValue: Double) -> String {
        let head = "Preferred the first side \(preferredA) times, the second \(preferredB) times."
        return head + (pValue < BlindComparisonStatistics.alpha ? " Unlikely to be chance." : " Could be chance.")
    }

    static func abx(
        sideA: String, sideB: String, session: BlindABXSession, kind: Kind = .canIHearIt, now: Date = Date(),
        id: UUID = UUID()
    ) -> BlindTestRecord? {
        guard session.isComplete else { return nil }
        let p = BlindABXSession.exactOneSidedPValue(correct: session.correctCount, total: session.totalTrials) ?? 1
        return BlindTestRecord(
            id: id, date: now, kind: kind, sideA: sideA, sideB: sideB, trialCount: session.totalTrials,
            correctCount: session.correctCount, preferredA: nil, preferredB: nil, pValue: p,
            outcome: abxOutcome(correct: session.correctCount, trials: session.totalTrials, pValue: p),
            trialsCorrect: session.completedTrials.map(\.correct))
    }

    typealias Kind = BlindTestRecord.Kind

    static func preference(
        sideA: String, sideB: String, result: BlindComparisonService.PreferenceResult, now: Date = Date(), id: UUID = UUID()
    ) -> BlindTestRecord {
        BlindTestRecord(
            id: id, date: now, kind: .preference, sideA: sideA, sideB: sideB, trialCount: result.trials,
            correctCount: nil, preferredA: result.preferredA, preferredB: result.preferredB, pValue: result.pValue,
            outcome: preferenceOutcome(preferredA: result.preferredA, preferredB: result.preferredB, pValue: result.pValue),
            trialsCorrect: nil)
    }

    static func exportData(_ record: BlindTestRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }
}

/// The saved list, newest first, at most `limit` entries, one JSON file in the app's own folder.
@MainActor
final class BlindTestHistoryStore: ObservableObject {
    static let limit = 200
    /// The one list the page and the backup share.
    static let shared = BlindTestHistoryStore()

    private let url: URL
    @Published private(set) var records: [BlindTestRecord]

    init(url: URL = BlindTestHistoryStore.defaultURL()) {
        self.url = url
        records = Self.read(url)
    }

    nonisolated static func defaultURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("NotchSixty", isDirectory: true)
            .appendingPathComponent("blind-listening-history.json")
    }

    func append(_ record: BlindTestRecord) {
        guard !records.contains(where: { $0.id == record.id }) else { return }
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        persist()
    }

    /// Backup restore: records with a known id are replaced, the rest are kept.
    func merge(_ incoming: [BlindTestRecord]) {
        var byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for record in incoming { byID[record.id] = record }
        records = Array(byID.values.sorted { $0.date > $1.date }.prefix(Self.limit))
        persist()
    }

    func clear() {
        records = []
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder().encode(records).write(to: url, options: .atomic)
        } catch {
            // The list is a convenience; failing to save it never interrupts a test.
        }
    }

    private static func read(_ url: URL) -> [BlindTestRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder().decode([BlindTestRecord].self, from: data)) ?? []
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
