import Foundation

/// E11 S5: the measurement library (design note 10). One folder per record under
/// `Application Support/NotchSixty/Measurements/` holding `record.json`, `ir.wav` and optionally
/// `raw.wav` (float32 mono), plus an `index.json` (schema 1). Off the audio thread only.

struct MeasurementRecord: Codable, Identifiable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var name: String
    var notes: String = ""
    var group: String = ""
    var tags: [String] = []
    var createdAt: Date
    var sampleRate: Double
    var channel: String = ""
    var seat: String?
    var microphone: String?
    var sweep: RoomCorrectionSweepSettings?
    /// "loopback", "reference" or "none" (design note 4).
    var timingTier: String?
    var calibrationName: String?
    var quality: RoomCorrectionMeasurementQuality = RoomCorrectionMeasurementQuality()
    /// Stored with the record so overlays and A/B work without recomputing and for curve-only records.
    var response: RoomCorrectionFrequencyResponse?
    var hasImpulseResponse: Bool = true
    var hasRawCapture: Bool = false
}

enum MeasurementLibraryError: Error, Equatable, LocalizedError {
    case unsupportedSchema(found: Int, folder: String)
    case missingFile(String)
    case corruptWAV(String)
    case invalidName
    case notFound(UUID)
    case tooManyOverlays(limit: Int)
    case incompatible(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let found, let folder): "Measurement \(folder) uses schema \(found), which this version cannot read."
        case .missingFile(let name): "Missing file \(name)."
        case .corruptWAV(let name): "\(name) is not a valid float32 WAV file."
        case .invalidName: "A measurement needs a name."
        case .notFound(let id): "No measurement \(id.uuidString) in the library."
        case .tooManyOverlays(let limit): "At most \(limit) overlays can be shown at once."
        case .incompatible(let why): why
        }
    }
}

/// Float32 mono WAV with bit-exact sample round trip.
enum MeasurementFloatWAV {
    static func encode(_ samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(max(1, sampleRate.rounded()))
        let bytes = UInt32(samples.count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(3); u16(1); u32(rate); u32(rate * 4); u16(4); u16(32)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for sample in samples { u32(sample.bitPattern) }
        return data
    }

    static func decode(_ data: Data, name: String) throws -> (samples: [Float], sampleRate: Double) {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { throw MeasurementLibraryError.corruptWAV(name) }
        var cursor = 12
        var rate: Double?
        while cursor + 8 <= bytes.count {
            let tag = String(decoding: bytes[cursor..<cursor + 4], as: UTF8.self)
            let size = Int(u32(cursor + 4))
            let body = cursor + 8
            guard body + size <= bytes.count else { throw MeasurementLibraryError.corruptWAV(name) }
            if tag == "fmt " {
                guard size >= 16, u16(body) == 3, u16(body + 2) == 1, u16(body + 14) == 32 else {
                    throw MeasurementLibraryError.corruptWAV(name)
                }
                rate = Double(u32(body + 4))
            } else if tag == "data" {
                guard let rate, size % 4 == 0 else { throw MeasurementLibraryError.corruptWAV(name) }
                let samples = (0..<size / 4).map { Float(bitPattern: u32(body + $0 * 4)) }
                return (samples, rate)
            }
            cursor = body + size + (size & 1)
        }
        throw MeasurementLibraryError.corruptWAV(name)
    }
}

struct MeasurementLibraryContents: Equatable {
    var records: [MeasurementRecord]
    /// One line per folder that was skipped.
    var errors: [String]
}

struct MeasurementLibrary: Sendable {
    static let indexSchemaVersion = 1

    private struct Index: Codable {
        var schemaVersion: Int
        var order: [UUID]
    }

    let root: URL

    init(root: URL) { self.root = root }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("NotchSixty/Measurements", isDirectory: true)
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// Writes (or replaces) a record. The folder is staged and swapped in so a failure leaves the old one.
    @discardableResult
    func save(_ record: MeasurementRecord, impulseResponse: [Float]?, rawCapture: [Float]? = nil) throws -> MeasurementRecord {
        let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MeasurementLibraryError.invalidName }
        var stored = record
        stored.name = name
        stored.schemaVersion = MeasurementRecord.currentSchemaVersion
        stored.hasImpulseResponse = impulseResponse != nil
        stored.hasRawCapture = rawCapture != nil

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(stored.id.uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try encoder.encode(stored).write(to: staging.appendingPathComponent("record.json"))
            if let impulseResponse {
                try MeasurementFloatWAV.encode(impulseResponse, sampleRate: stored.sampleRate)
                    .write(to: staging.appendingPathComponent("ir.wav"))
            }
            if let rawCapture {
                try MeasurementFloatWAV.encode(rawCapture, sampleRate: stored.sampleRate)
                    .write(to: staging.appendingPathComponent("raw.wav"))
            }
            let target = folder(stored.id)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        var order = (try? readIndex().order) ?? []
        if !order.contains(stored.id) { order.append(stored.id) }
        try writeIndex(order)
        return stored
    }

    /// Updates metadata only (name, notes, group, tags), keeping the stored waveforms.
    func updateMetadata(id: UUID, _ change: (inout MeasurementRecord) -> Void) throws {
        var record = try loadRecord(id: id)
        change(&record)
        let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MeasurementLibraryError.invalidName }
        record.name = name
        try encoder.encode(record).write(to: folder(id).appendingPathComponent("record.json"), options: .atomic)
    }

    func delete(id: UUID) throws {
        let target = folder(id)
        guard FileManager.default.fileExists(atPath: target.path) else { throw MeasurementLibraryError.notFound(id) }
        try FileManager.default.removeItem(at: target)
        try writeIndex(((try? readIndex().order) ?? []).filter { $0 != id })
    }

    func loadRecord(id: UUID) throws -> MeasurementRecord {
        let url = folder(id).appendingPathComponent("record.json")
        guard let data = try? Data(contentsOf: url) else { throw MeasurementLibraryError.missingFile("record.json") }
        struct Probe: Decodable { var schemaVersion: Int }
        let found = try decoder.decode(Probe.self, from: data).schemaVersion
        guard found == MeasurementRecord.currentSchemaVersion else {
            throw MeasurementLibraryError.unsupportedSchema(found: found, folder: id.uuidString)
        }
        return try decoder.decode(MeasurementRecord.self, from: data)
    }

    func loadImpulseResponse(id: UUID) throws -> [Float] {
        try readWAV(id: id, file: "ir.wav").samples
    }

    func loadRawCapture(id: UUID) throws -> [Float] {
        try readWAV(id: id, file: "raw.wav").samples
    }

    private func readWAV(id: UUID, file: String) throws -> (samples: [Float], sampleRate: Double) {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent(file)) else {
            throw MeasurementLibraryError.missingFile(file)
        }
        return try MeasurementFloatWAV.decode(data, name: file)
    }

    /// Records in index order. A folder that cannot be read is skipped and reported, never fatal.
    func load() throws -> MeasurementLibraryContents {
        guard FileManager.default.fileExists(atPath: root.path) else { return MeasurementLibraryContents(records: [], errors: []) }
        var order = (try? readIndex().order) ?? []
        if FileManager.default.fileExists(atPath: indexURL.path) {
            // A schema we cannot read is the one fatal case: do not overwrite what a newer build wrote.
            _ = try readIndex()
        }
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in onDisk.sorted() {
            if let id = UUID(uuidString: name), !order.contains(id) { order.append(id) }
        }
        var records: [MeasurementRecord] = []
        var errors: [String] = []
        for id in order {
            guard FileManager.default.fileExists(atPath: folder(id).path) else { continue }
            do {
                let record = try loadRecord(id: id)
                if record.hasImpulseResponse {
                    guard FileManager.default.fileExists(atPath: folder(id).appendingPathComponent("ir.wav").path) else {
                        throw MeasurementLibraryError.missingFile("ir.wav")
                    }
                }
                records.append(record)
            } catch {
                errors.append("\(id.uuidString): \(error.localizedDescription)")
            }
        }
        return MeasurementLibraryContents(records: records, errors: errors)
    }

    private func readIndex() throws -> Index {
        guard let data = try? Data(contentsOf: indexURL) else { throw MeasurementLibraryError.missingFile("index.json") }
        let index = try decoder.decode(Index.self, from: data)
        guard index.schemaVersion == Self.indexSchemaVersion else {
            throw MeasurementLibraryError.unsupportedSchema(found: index.schemaVersion, folder: "index.json")
        }
        return index
    }

    private func writeIndex(_ order: [UUID]) throws {
        try encoder.encode(Index(schemaVersion: Self.indexSchemaVersion, order: order)).write(to: indexURL, options: .atomic)
    }
}

// MARK: - Overlays and A/B

/// Up to eight overlays and one reference for A/B.
struct MeasurementOverlaySet: Equatable, Sendable {
    static let limit = 8

    private(set) var overlayIDs: [UUID] = []
    private(set) var referenceID: UUID?

    mutating func add(_ id: UUID) throws {
        guard !overlayIDs.contains(id) else { return }
        guard overlayIDs.count < Self.limit else { throw MeasurementLibraryError.tooManyOverlays(limit: Self.limit) }
        overlayIDs.append(id)
    }

    mutating func remove(_ id: UUID) {
        overlayIDs.removeAll { $0 == id }
        if referenceID == id { referenceID = nil }
    }

    mutating func setReference(_ id: UUID?) { referenceID = id }
}

enum MeasurementSmoothing: String, CaseIterable, Identifiable, Sendable {
    case none = "None", octave12 = "1/12 octave", octave6 = "1/6 octave", octave3 = "1/3 octave", octave1 = "1 octave"
    var id: String { rawValue }
    /// Total window width in octaves.
    var widthOctaves: Double? {
        switch self {
        case .none: nil
        case .octave12: 1.0 / 12
        case .octave6: 1.0 / 6
        case .octave3: 1.0 / 3
        case .octave1: 1
        }
    }
}

enum MeasurementComparison {
    /// Fractional-octave smoothing of a magnitude curve, averaging power over a window centred in log frequency.
    static func smooth(_ response: RoomCorrectionFrequencyResponse, _ smoothing: MeasurementSmoothing) -> [Double] {
        guard let width = smoothing.widthOctaves, response.frequenciesHz.count > 1 else { return response.magnitudeDB }
        let f = response.frequenciesHz
        var prefix = [Double](repeating: 0, count: f.count + 1)
        for index in f.indices { prefix[index + 1] = prefix[index] + pow(10, response.magnitudeDB[index] / 10) }
        let half = pow(2, width / 2)
        var out = [Double](repeating: 0, count: f.count)
        var lo = 0, hi = 0
        for index in f.indices {
            let low = f[index] / half, high = f[index] * half
            while lo < f.count, f[lo] < low { lo += 1 }
            while hi < f.count, f[hi] <= high { hi += 1 }
            let count = max(1, hi - lo)
            out[index] = 10 * log10(max(1e-300, (prefix[max(hi, lo + 1)] - prefix[lo]) / Double(count)))
        }
        return out
    }

    /// Magnitude of `response` at each of `frequencies`, linear in dB over log frequency, clamped at the ends.
    static func resample(_ magnitudeDB: [Double], from source: [Double], to frequencies: [Double]) -> [Double] {
        guard source.count == magnitudeDB.count, let first = source.first, let last = source.last else { return [] }
        var upper = 1
        return frequencies.map { f in
            if f <= first { return magnitudeDB[0] }
            if f >= last { return magnitudeDB[magnitudeDB.count - 1] }
            while upper < source.count - 1, source[upper] < f { upper += 1 }
            let f0 = source[upper - 1], f1 = source[upper]
            guard f1 > f0, f0 > 0 else { return magnitudeDB[upper] }
            let u = log(f / f0) / log(f1 / f0)
            return magnitudeDB[upper - 1] + u * (magnitudeDB[upper] - magnitudeDB[upper - 1])
        }
    }

    /// `record - reference` in dB on the record's grid, after smoothing both.
    static func difference(
        _ record: RoomCorrectionFrequencyResponse, reference: RoomCorrectionFrequencyResponse, smoothing: MeasurementSmoothing
    ) -> RoomCorrectionFrequencyResponse {
        let a = smooth(record, smoothing)
        let b = resample(smooth(reference, smoothing), from: reference.frequenciesHz, to: record.frequenciesHz)
        let diff = zip(a, b).map { $0 - $1 }
        return RoomCorrectionFrequencyResponse(frequenciesHz: record.frequenciesHz, magnitudeDB: diff, phaseRadians: nil)
    }
}

// MARK: - Room Correction hand-off

extension MeasurementLibrary {
    /// "Use in Room Correction": a left and a right record become one measurement position (a copy).
    /// Both need their impulse response and response and must share the sample rate.
    func roomCorrectionAnalysis(left: MeasurementRecord, right: MeasurementRecord) throws -> RoomCorrectionMeasurementAnalysis {
        guard abs(left.sampleRate - right.sampleRate) < 0.5 else {
            throw MeasurementLibraryError.incompatible("The two measurements were taken at different sample rates.")
        }
        func channel(_ record: MeasurementRecord) throws -> RoomCorrectionChannelMeasurement {
            guard record.hasImpulseResponse, let response = record.response else {
                throw MeasurementLibraryError.incompatible("\(record.name) has no impulse response to copy.")
            }
            let raw = record.hasRawCapture ? try loadRawCapture(id: record.id) : []
            return RoomCorrectionChannelMeasurement(
                capturedAt: record.createdAt, rawCapture: raw, impulseResponse: try loadImpulseResponse(id: record.id),
                transferFunction: response, quality: record.quality)
        }
        return RoomCorrectionMeasurementAnalysis(sampleRate: left.sampleRate, left: try channel(left), right: try channel(right))
    }
}
