import Foundation

// E29 S2: persistence for the room model. `RoomModel.json` (schema v1: points and path metadata) plus one 32-bit float
// mono WAV per path that has an impulse response, in one folder per model. Control plane only: never called from a
// render callback, never arms anything. Profile JSON keeps only the model ID (`PlaybackSystemProfile.roomModelID`).
// Format references: RIFF/WAVE with IEEE float (format tag 3), little-endian, 32 bits per sample.

enum RoomModelStoreError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(name: String, version: Int)
    case corruptJSON
    case corruptWAV(file: String)
    case missingImpulseResponse(file: String)
    case rateMismatch(file: String)
    case missingStamp(field: String)
    case unknownPath(UUID)

    var description: String {
        switch self {
        case .unsupportedSchema(let n, let v): return "Room model schema \(n) v\(v) is not supported."
        case .corruptJSON: return "RoomModel.json is damaged."
        case .corruptWAV(let f): return "Impulse response \(f) is damaged."
        case .missingImpulseResponse(let f): return "Impulse response \(f) is missing."
        case .rateMismatch(let f): return "Impulse response \(f) does not match its path's sample rate."
        case .missingStamp(let f): return "A new path needs \(f) before it can be stored."
        case .unknownPath(let id): return "No path \(id)."
        }
    }
}

/// The model plus its impulse responses, keyed by path ID. Only paths with `hasImpulseResponse` carry samples.
struct RoomModelDocument: Equatable, Sendable {
    var modelID: UUID
    var model: RoomModel
    var impulseResponses: [UUID: [Float]]

    init(modelID: UUID = UUID(), model: RoomModel = RoomModel(), impulseResponses: [UUID: [Float]] = [:]) {
        self.modelID = modelID
        self.model = model
        self.impulseResponses = impulseResponses
    }

    /// Adds a measured path. Stamps the output device UID and arrangement revision (G2) from `context` onto every
    /// new path and refuses when the context cannot supply them, so no new path is ever unstampable later.
    mutating func addPath(_ path: RoomPath, impulseResponse: [Float]?, context: RoomModelContext) throws {
        var p = path
        if p.stamps.outputDeviceUID == nil { p.stamps.outputDeviceUID = context.outputDeviceUID }
        if p.stamps.arrangementRevision == nil { p.stamps.arrangementRevision = context.arrangementRevision }
        if p.stamps.outputGainDB == nil { p.stamps.outputGainDB = context.outputGainDB }
        if p.stamps.calibrationName == nil { p.stamps.calibrationName = context.calibrationName }
        if p.stamps.bassFingerprint == nil { p.stamps.bassFingerprint = context.bassFingerprint }
        guard p.stamps.outputDeviceUID != nil else { throw RoomModelStoreError.missingStamp(field: "an output device") }
        guard p.stamps.arrangementRevision != nil else {
            throw RoomModelStoreError.missingStamp(field: "an arrangement revision")
        }
        p.hasImpulseResponse = impulseResponse != nil
        model = RoomModel(points: model.points, paths: model.paths.filter { $0.id != p.id } + [p])
        impulseResponses[p.id] = impulseResponse
    }

    mutating func addPoint(_ point: RoomPoint) {
        model = RoomModel(points: model.points.filter { $0.id != point.id } + [point], paths: model.paths)
    }
}

struct RoomModelSaveReport: Equatable, Sendable {
    var impulseResponseBytes: Int
    /// True above `RoomModelStore.sizeWarningBytes`: the store warns, it never drops data.
    var overSizeCap: Bool
}

enum RoomModelStore {
    static let schemaName = "n60.roommodel"
    static let currentSchemaVersion = 1
    static let jsonFileName = "RoomModel.json"
    /// Design note 9: 8 sources x 16 points at 384 kHz stays near 200 MB.
    static let sizeWarningBytes = 200 * 1024 * 1024

    private struct Header: Codable { var schema: String; var version: Int }

    private struct File: Codable {
        var schema: String
        var version: Int
        var modelID: UUID
        var points: [RoomPoint]
        var paths: [RoomPath]
    }

    static func wavName(for pathID: UUID) -> String { "\(pathID.uuidString).wav" }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @discardableResult
    static func save(_ doc: RoomModelDocument, to directory: URL) throws -> RoomModelSaveReport {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = 0
        var keep = Set<String>([jsonFileName])
        for path in doc.model.paths where path.hasImpulseResponse {
            guard let ir = doc.impulseResponses[path.id] else {
                throw RoomModelStoreError.missingImpulseResponse(file: wavName(for: path.id))
            }
            let name = wavName(for: path.id)
            let data = WAV.encode(ir, sampleRate: path.sampleRate)
            bytes += data.count
            keep.insert(name)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        let file = File(
            schema: schemaName, version: currentSchemaVersion, modelID: doc.modelID,
            points: doc.model.points, paths: doc.model.paths)
        try encoder().encode(file).write(to: directory.appendingPathComponent(jsonFileName), options: .atomic)
        // Remove WAVs no path references any more.
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasSuffix(".wav") && !keep.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        return RoomModelSaveReport(impulseResponseBytes: bytes, overSizeCap: bytes > sizeWarningBytes)
    }

    static func load(from directory: URL) throws -> RoomModelDocument {
        let data = try Data(contentsOf: directory.appendingPathComponent(jsonFileName))
        guard let header = try? decoder().decode(Header.self, from: data) else { throw RoomModelStoreError.corruptJSON }
        guard header.schema == schemaName, header.version == currentSchemaVersion else {
            throw RoomModelStoreError.unsupportedSchema(name: header.schema, version: header.version)
        }
        guard let file = try? decoder().decode(File.self, from: data) else { throw RoomModelStoreError.corruptJSON }
        var irs: [UUID: [Float]] = [:]
        for path in file.paths where path.hasImpulseResponse {
            let name = wavName(for: path.id)
            guard let wav = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                throw RoomModelStoreError.missingImpulseResponse(file: name)
            }
            guard let decoded = WAV.decode(wav) else { throw RoomModelStoreError.corruptWAV(file: name) }
            guard decoded.sampleRate == path.sampleRate.rounded() else { throw RoomModelStoreError.rateMismatch(file: name) }
            irs[path.id] = decoded.samples
        }
        return RoomModelDocument(
            modelID: file.modelID, model: RoomModel(points: file.points, paths: file.paths), impulseResponses: irs)
    }

    /// Export copies a validated model folder; import validates the source before it replaces `directory`.
    static func export(_ doc: RoomModelDocument, to destination: URL) throws -> RoomModelSaveReport {
        try save(doc, to: destination)
    }

    static func importModel(from source: URL, into directory: URL) throws -> RoomModelDocument {
        let doc = try load(from: source)
        try save(doc, to: directory)
        return doc
    }

    /// Minimal 32-bit float mono WAV (RIFF, `fmt ` tag 3, `data`), little-endian.
    enum WAV {
        static func encode(_ samples: [Float], sampleRate: Double) -> Data {
            var d = Data()
            func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
            func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
            let dataBytes = UInt32(samples.count * 4)
            let rate = UInt32(sampleRate.rounded())
            d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
            d.append(contentsOf: Array("WAVE".utf8))
            d.append(contentsOf: Array("fmt ".utf8)); u32(16)
            u16(3); u16(1); u32(rate); u32(rate * 4); u16(4); u16(32)
            d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
            for s in samples { u32(s.bitPattern) }
            return d
        }

        static func decode(_ data: Data) -> (samples: [Float], sampleRate: Double)? {
            let b = [UInt8](data)
            guard b.count >= 44 else { return nil }
            func u32(_ o: Int) -> UInt32 {
                UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
            }
            func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
            func tag(_ o: Int) -> String { String(decoding: b[o..<o + 4], as: UTF8.self) }
            guard tag(0) == "RIFF", tag(8) == "WAVE", tag(12) == "fmt ", u32(16) == 16 else { return nil }
            guard u16(20) == 3, u16(22) == 1, u16(34) == 32, u16(32) == 4 else { return nil }
            let rate = u32(24)
            guard rate > 0, u32(28) == rate * 4, tag(36) == "data" else { return nil }
            let n = Int(u32(40))
            guard n % 4 == 0, 44 + n == b.count, u32(4) == UInt32(36 + n) else { return nil }
            var out = [Float]()
            out.reserveCapacity(n / 4)
            for i in 0..<(n / 4) { out.append(Float(bitPattern: u32(44 + i * 4))) }
            return (out, Double(rate))
        }
    }
}
