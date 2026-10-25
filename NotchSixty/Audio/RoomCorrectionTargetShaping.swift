import Foundation

/// E10 S5: target editor model (design note 8). Curtains, the limited-range preset and per-channel
/// level and tilt offsets. Pure functions; design time only, never called from an audio callback.

struct TargetShaping: Codable, Equatable, Sendable {
    /// Below this frequency the correction returns to unity over a third-octave raised-cosine.
    var lowCurtainHz: Double?
    /// Above this frequency the correction returns to unity over a third-octave raised-cosine.
    var highCurtainHz: Double?
    /// Level offset of this channel's target relative to the shared target.
    var levelOffsetDB: Double = 0
    /// Tilt offset in dB per octave, pivoting at 1 kHz.
    var tiltDBPerOctave: Double = 0

    static let none = TargetShaping()
    static let tiltPivotHz = 1_000.0
    static let limitedRangeHighCurtainHz = 300.0
    static let transitionOctaves = 1.0 / 3.0

    /// The "Limited range" preset class: bass-only correction.
    static func limitedRange(highCurtainHz: Double = limitedRangeHighCurtainHz) -> TargetShaping {
        TargetShaping(highCurtainHz: highCurtainHz)
    }

    var isValid: Bool {
        let curtains = [lowCurtainHz, highCurtainHz].compactMap { $0 }
        guard curtains.allSatisfy({ $0.isFinite && $0 > 0 }),
              levelOffsetDB.isFinite, tiltDBPerOctave.isFinite else { return false }
        if let low = lowCurtainHz, let high = highCurtainHz { return low < high }
        return true
    }

    /// Correction weight in 0...1: 1 inside the curtains, raised-cosine to 0 over one third-octave
    /// beyond each curtain (so the correction is unity within a third-octave of the curtain).
    func curtainWeight(at frequencyHz: Double) -> Double {
        guard frequencyHz > 0 else { return 0 }
        var weight = 1.0
        if let high = highCurtainHz {
            let t = log2(frequencyHz / high) / Self.transitionOctaves
            weight *= Self.raisedCosine(1 - min(max(t, 0), 1))
        }
        if let low = lowCurtainHz {
            let t = log2(low / frequencyHz) / Self.transitionOctaves
            weight *= Self.raisedCosine(1 - min(max(t, 0), 1))
        }
        return weight
    }

    private static func raisedCosine(_ x: Double) -> Double { 0.5 - 0.5 * cos(Double.pi * x) }

    /// Offset applied to the shared target for this channel.
    func offsetDB(at frequencyHz: Double) -> Double {
        levelOffsetDB + tiltDBPerOctave * log2(max(frequencyHz, 1e-9) / Self.tiltPivotHz)
    }

    /// This channel's target gain: shared target plus its offsets.
    func targetDB(shared sharedDB: Double, at frequencyHz: Double) -> Double {
        sharedDB + offsetDB(at: frequencyHz)
    }

    /// The correction after the curtains: `weight * correction`, unity (0 dB) outside.
    func shapedCorrectionDB(_ correctionDB: Double, at frequencyHz: Double) -> Double {
        curtainWeight(at: frequencyHz) * correctionDB
    }
}

/// Shaping for every channel of a layout, keyed by channel index. Channels not listed are unshaped,
/// so editing one channel never changes another.
struct ChannelTargetShaping: Codable, Equatable, Sendable {
    var channels: [Int: TargetShaping] = [:]

    private struct Entry: Codable { var channel: Int; var shaping: TargetShaping }

    init(channels: [Int: TargetShaping] = [:]) { self.channels = channels }

    // Encoded as a channel-sorted array so the bytes are deterministic.
    init(from decoder: Decoder) throws {
        let entries = try decoder.singleValueContainer().decode([Entry].self)
        channels = Dictionary(entries.map { ($0.channel, $0.shaping) }, uniquingKeysWith: { $1 })
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(channels.keys.sorted().map { Entry(channel: $0, shaping: channels[$0]!) })
    }

    subscript(channel: Int) -> TargetShaping {
        get { channels[channel] ?? .none }
        set { channels[channel] = newValue == .none ? nil : newValue }
    }

    func targetDB(shared: Double, channel: Int, at frequencyHz: Double) -> Double {
        self[channel].targetDB(shared: shared, at: frequencyHz)
    }

    func shapedCorrectionDB(_ correctionDB: Double, channel: Int, at frequencyHz: Double) -> Double {
        self[channel].shapedCorrectionDB(correctionDB, at: frequencyHz)
    }
}

// MARK: - Library

/// One saved target: the shared curve plus per-channel shaping (schema 1).
struct TargetRecord: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = 1
    var schema: Int = TargetRecord.schemaVersion
    var id: UUID
    var name: String
    var points: [RoomCorrectionTargetPoint]
    var shaping: ChannelTargetShaping = .init()

    init(id: UUID = UUID(), name: String, points: [RoomCorrectionTargetPoint], shaping: ChannelTargetShaping = .init()) {
        self.id = id; self.name = name; self.points = points; self.shaping = shaping
    }

    init(curve: RoomCorrectionTargetCurve, shaping: ChannelTargetShaping = .init()) {
        self.init(id: curve.id, name: curve.name, points: curve.points, shaping: shaping)
    }

    var curve: RoomCorrectionTargetCurve { RoomCorrectionTargetCurve(id: id, name: name, points: points) }
}

enum TargetLibraryError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case invalid(String)
    case builtIn
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): "Target file schema \(v) is not supported (expected \(TargetRecord.schemaVersion))."
        case .invalid(let why): "Invalid target: \(why)"
        case .builtIn: "Built-in targets cannot be changed; duplicate it first."
        case .notFound: "Target not found."
        }
    }
}

struct TargetLibraryLoadReport: Equatable, Sendable {
    var records: [TargetRecord]
    /// File name and reason for every file that was skipped.
    var skipped: [(file: String, reason: String)]

    static func == (l: Self, r: Self) -> Bool {
        l.records == r.records && l.skipped.map(\.file) == r.skipped.map(\.file)
    }
}

/// `Application Support/NotchSixty/Targets/`: `index.json` plus one `<uuid>.json` per target.
/// Built-ins are not stored. Off the audio thread only.
final class TargetLibrary {
    private struct Index: Codable { var schema: Int; var ids: [UUID] }

    let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("NotchSixty/Targets", isDirectory: true)
        }
    }

    static var builtIns: [TargetRecord] {
        RoomCorrectionBuiltInTarget.allCases.map { TargetRecord(curve: $0.curve) }
    }

    static func isBuiltIn(_ id: UUID) -> Bool { builtIns.contains { $0.id == id } }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    static func validate(_ record: TargetRecord) throws {
        guard record.schema == TargetRecord.schemaVersion else { throw TargetLibraryError.unsupportedSchema(record.schema) }
        guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TargetLibraryError.invalid("name is empty")
        }
        guard record.points.count >= 2 else { throw TargetLibraryError.invalid("needs at least two points") }
        var previous = 0.0
        for p in record.points {
            guard p.frequencyHz.isFinite, p.frequencyHz > previous, p.gainDB.isFinite else {
                throw TargetLibraryError.invalid("points must be finite and increasing in frequency")
            }
            previous = p.frequencyHz
        }
        for (channel, shaping) in record.shaping.channels where !shaping.isValid || channel < 0 {
            throw TargetLibraryError.invalid("shaping for channel \(channel) is not valid")
        }
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    func save(_ record: TargetRecord) throws {
        try Self.validate(record)
        if Self.isBuiltIn(record.id) { throw TargetLibraryError.builtIn }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder().encode(record).write(to: fileURL(record.id), options: .atomic)
        var ids = readIndexIDs()
        if !ids.contains(record.id) { ids.append(record.id) }
        try writeIndex(ids)
    }

    func delete(id: UUID) throws {
        if Self.isBuiltIn(id) { throw TargetLibraryError.builtIn }
        try? fileManager.removeItem(at: fileURL(id))
        try writeIndex(readIndexIDs().filter { $0 != id })
    }

    func rename(id: UUID, to name: String) throws {
        var record = try load(id: id)
        record.name = name
        try save(record)
    }

    @discardableResult
    func duplicate(_ record: TargetRecord, name: String? = nil) throws -> TargetRecord {
        var copy = record
        copy.id = UUID()
        copy.name = name ?? record.name + " Copy"
        try save(copy)
        return copy
    }

    func load(id: UUID) throws -> TargetRecord {
        if let b = Self.builtIns.first(where: { $0.id == id }) { return b }
        guard let data = try? Data(contentsOf: fileURL(id)) else { throw TargetLibraryError.notFound(id) }
        let record = try Self.decode(data)
        return record
    }

    static func decode(_ data: Data) throws -> TargetRecord {
        // Reject a newer schema before decoding the rest, so a future file reports its version.
        struct Probe: Decodable { var schema: Int }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        guard probe.schema == TargetRecord.schemaVersion else { throw TargetLibraryError.unsupportedSchema(probe.schema) }
        let record = try JSONDecoder().decode(TargetRecord.self, from: data)
        try validate(record)
        return record
    }

    /// Built-ins first, then saved targets in index order. Corrupt or unsupported files are skipped
    /// and reported; files not in the index are ignored.
    func loadAll() -> TargetLibraryLoadReport {
        var records = Self.builtIns
        var skipped: [(file: String, reason: String)] = []
        for id in readIndexIDs() {
            let url = fileURL(id)
            do {
                guard let data = try? Data(contentsOf: url) else {
                    skipped.append((url.lastPathComponent, "missing file")); continue
                }
                records.append(try Self.decode(data))
            } catch {
                skipped.append((url.lastPathComponent, (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }
        return TargetLibraryLoadReport(records: records, skipped: skipped)
    }

    private func readIndexIDs() -> [UUID] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              index.schema == TargetRecord.schemaVersion else { return [] }
        return index.ids
    }

    private func writeIndex(_ ids: [UUID]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder().encode(Index(schema: TargetRecord.schemaVersion, ids: ids)).write(to: indexURL, options: .atomic)
    }

    // MARK: REW text

    /// Imports an E11 REW text target (second column is the target level in dB).
    static func importREW(_ data: Data, name: String) throws -> TargetRecord {
        let curve = try MeasurementFormats.parse(data, format: .rew)
        let record = TargetRecord(name: name, points: zip(curve.frequenciesHz, curve.values).map {
            RoomCorrectionTargetPoint(frequencyHz: $0, gainDB: $1)
        })
        try validate(record)
        return record
    }

    static func exportREW(_ record: TargetRecord) -> Data {
        let curve = MeasurementCurve(
            frequenciesHz: record.points.map(\.frequencyHz), values: record.points.map(\.gainDB), phaseDegrees: nil)
        return Data(MeasurementFormats.write(curve, format: .rew, title: record.name).utf8)
    }
}
