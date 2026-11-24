import XCTest
@testable import NotchSixty

/// E29 S2: the room model store. Round trip is byte-stable, unknown schemas are refused by name, corrupt WAVs are
/// refused, IRs round-trip bit-exact at all eight standard rates, and new paths are stamped.
final class RoomModelStoreTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rms-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let ctx = RoomModelContext(
        arrangementRevision: "arr-7", outputDeviceUID: "dev-A", outputGainDB: -6, calibrationName: "UMIK-1")

    private func document(rate: Double, ir: [Float]) throws -> RoomModelDocument {
        var doc = RoomModelDocument(modelID: RoomModelID.stable("test", "model"))
        let spk = RoomPoint(id: RoomModelID.stable("p", "spk"), kind: .speakerFeed, name: "Left", position: nil)
        let seat = RoomPoint(
            id: RoomModelID.stable("p", "seat"), kind: .seat, name: "Sofa",
            position: RoomPosition(x: 1, y: 2.5, z: 1.1, source: .typed, uncertaintyMetres: 0.05))
        doc.addPoint(spk)
        doc.addPoint(seat)
        let path = RoomPath(
            id: RoomModelID.stable("path", "1"), source: spk.id, receiver: seat.id,
            origin: .measurementRecord(id: RoomModelID.stable("rec", "1")), sampleRate: rate, timingTier: .loopback,
            sessionID: "s1", bandLowHz: 20, bandHighHz: 20_000, windowSeconds: 1,
            stamps: RoomPathStamps(), date: Date(timeIntervalSince1970: 1_800_000_000),
            hasImpulseResponse: true, qualityOK: true)
        try doc.addPath(path, impulseResponse: ir, context: ctx)
        return doc
    }

    func testRoundTripBitExactAtAllRatesAndByteStable() throws {
        let ir: [Float] = [1, -0.5, .leastNonzeroMagnitude, 1e-30, -0.0, 0.123456789]
        for rate in rates {
            let d = dir.appendingPathComponent("r\(Int(rate))")
            let doc = try document(rate: rate, ir: ir)
            try RoomModelStore.save(doc, to: d)
            let first = try Data(contentsOf: d.appendingPathComponent(RoomModelStore.jsonFileName))
            let loaded = try RoomModelStore.load(from: d)
            XCTAssertEqual(loaded, doc)
            let id = doc.model.paths[0].id
            XCTAssertEqual(loaded.impulseResponses[id]?.map(\.bitPattern), ir.map(\.bitPattern), "rate \(rate)")
            try RoomModelStore.save(loaded, to: d)
            XCTAssertEqual(try Data(contentsOf: d.appendingPathComponent(RoomModelStore.jsonFileName)), first)
        }
    }

    func testNewPathsAreStamped() throws {
        let doc = try document(rate: 48_000, ir: [1])
        let s = doc.model.paths[0].stamps
        XCTAssertEqual(s.outputDeviceUID, "dev-A")
        XCTAssertEqual(s.arrangementRevision, "arr-7")
        var changed = ctx
        changed.outputDeviceUID = "dev-B"
        XCTAssertEqual(RoomModelRule.staleReasons(of: doc.model.paths[0], in: changed), [.outputDevice])
    }

    func testPathWithoutStampableContextIsRefused() throws {
        var doc = try document(rate: 48_000, ir: [1])
        var p = doc.model.paths[0]
        p.id = UUID()
        p.stamps = RoomPathStamps()
        XCTAssertThrowsError(try doc.addPath(p, impulseResponse: nil, context: RoomModelContext())) {
            guard case RoomModelStoreError.missingStamp = $0 else { return XCTFail("\($0)") }
        }
    }

    func testUnknownSchemaRefusedByName() throws {
        try RoomModelStore.save(try document(rate: 48_000, ir: [1]), to: dir)
        let url = dir.appendingPathComponent(RoomModelStore.jsonFileName)
        let text = try String(contentsOf: url).replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 9")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RoomModelStore.load(from: dir)) {
            XCTAssertEqual($0 as? RoomModelStoreError, .unsupportedSchema(name: "n60.roommodel", version: 9))
        }
        let other = text.replacingOccurrences(of: "n60.roommodel", with: "other.thing")
        try other.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RoomModelStore.load(from: dir)) {
            guard case RoomModelStoreError.unsupportedSchema(let n, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(n, "other.thing")
        }
    }

    func testCorruptAndMissingWAVRefused() throws {
        let doc = try document(rate: 96_000, ir: [1, 2, 3])
        try RoomModelStore.save(doc, to: dir)
        let wav = dir.appendingPathComponent(RoomModelStore.wavName(for: doc.model.paths[0].id))
        let good = try Data(contentsOf: wav)
        try good.dropLast(3).write(to: wav)
        XCTAssertThrowsError(try RoomModelStore.load(from: dir)) {
            guard case RoomModelStoreError.corruptWAV = $0 else { return XCTFail("\($0)") }
        }
        var wrongRate = RoomModelStore.WAV.encode([1, 2, 3], sampleRate: 48_000)
        try wrongRate.write(to: wav)
        XCTAssertThrowsError(try RoomModelStore.load(from: dir)) {
            guard case RoomModelStoreError.rateMismatch = $0 else { return XCTFail("\($0)") }
        }
        wrongRate[0] = 0x58
        try wrongRate.write(to: wav)
        XCTAssertThrowsError(try RoomModelStore.load(from: dir))
        try FileManager.default.removeItem(at: wav)
        XCTAssertThrowsError(try RoomModelStore.load(from: dir)) {
            guard case RoomModelStoreError.missingImpulseResponse = $0 else { return XCTFail("\($0)") }
        }
    }

    func testExportImportAndOrphanCleanup() throws {
        let doc = try document(rate: 384_000, ir: [0.5, 0.25])
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        _ = try RoomModelStore.export(doc, to: a)
        let imported = try RoomModelStore.importModel(from: a, into: b)
        XCTAssertEqual(imported, doc)
        var emptied = doc
        emptied.model = RoomModel(points: doc.model.points, paths: [])
        emptied.impulseResponses = [:]
        try RoomModelStore.save(emptied, to: b)
        let files = try FileManager.default.contentsOfDirectory(atPath: b.path)
        XCTAssertEqual(files, [RoomModelStore.jsonFileName])
    }

    func testSizeCapReport() throws {
        let report = try RoomModelStore.save(try document(rate: 48_000, ir: [Float](repeating: 0, count: 1000)), to: dir)
        XCTAssertEqual(report.impulseResponseBytes, 44 + 4000)
        XCTAssertFalse(report.overSizeCap)
    }

    func testProfileKeepsOnlyModelID() throws {
        var p = PlaybackSystemProfile(name: "x", state: PlaybackSystemState())
        XCTAssertNil(p.roomModelID)
        p.roomModelID = RoomModelID.stable("m", "1")
        let back = try JSONDecoder().decode(PlaybackSystemProfile.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(back.roomModelID, p.roomModelID)
    }
}
