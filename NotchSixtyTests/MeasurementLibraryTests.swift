import XCTest
@testable import NotchSixty

/// E11 S5: measurement library, overlays and A/B.
final class MeasurementLibraryTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("n60lib-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func response() -> RoomCorrectionFrequencyResponse {
        let f = (0..<200).map { 20 * pow(1000.0, Double($0) / 199) }
        return RoomCorrectionFrequencyResponse(
            frequenciesHz: f, magnitudeDB: f.map { 3 * sin($0 / 300) + 0.1 * log($0) }, phaseRadians: nil)
    }

    private func record(rate: Double, name: String = "Left, seat 1") -> MeasurementRecord {
        MeasurementRecord(
            name: name, notes: "n\u{00e9}ar field", group: "Room", tags: ["a", "b"], createdAt: Date(timeIntervalSince1970: 1_700_000_000.123),
            sampleRate: rate, channel: "Left", seat: "S1", microphone: "mic-uid", timingTier: "reference",
            quality: RoomCorrectionMeasurementQuality(sweepComplete: true, directArrivalSeconds: 0.0123), response: response())
    }

    private func ir(_ n: Int) -> [Float] {
        var s: UInt64 = 7
        return (0..<n).map { _ in s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(bitPattern: UInt32(truncatingIfNeeded: s >> 32) & 0x7F7F_FFFF) }
    }

    func testRoundTripIsBitExactAtEveryRate() throws {
        for rate in Self.rates {
            let library = MeasurementLibrary(root: root.appendingPathComponent("\(Int(rate))"))
            let rec = record(rate: rate), samples = ir(4_097), raw = ir(333)
            let stored = try library.save(rec, impulseResponse: samples, rawCapture: raw)
            let loaded = try library.load()
            XCTAssertEqual(loaded.errors, [])
            XCTAssertEqual(loaded.records, [stored], "rate \(rate)")
            XCTAssertEqual(try library.loadImpulseResponse(id: rec.id).map(\.bitPattern), samples.map(\.bitPattern))
            XCTAssertEqual(try library.loadRawCapture(id: rec.id).map(\.bitPattern), raw.map(\.bitPattern))
            XCTAssertEqual(try MeasurementFloatWAV.decode(MeasurementFloatWAV.encode(samples, sampleRate: rate), name: "x").sampleRate, rate)
        }
    }

    func testSchemaVersionRejectedAndFolderSkipped() throws {
        let library = MeasurementLibrary(root: root)
        let good = record(rate: 48_000, name: "Good"), future = record(rate: 48_000, name: "Future")
        try library.save(good, impulseResponse: ir(64))
        try library.save(future, impulseResponse: ir(64))
        let url = root.appendingPathComponent(future.id.uuidString).appendingPathComponent("record.json")
        let json = try String(contentsOf: url).replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
        try json.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try library.loadRecord(id: future.id)) {
            XCTAssertEqual($0 as? MeasurementLibraryError, .unsupportedSchema(found: 2, folder: future.id.uuidString))
        }
        let loaded = try library.load()
        XCTAssertEqual(loaded.records.map(\.name), ["Good"])
        XCTAssertEqual(loaded.errors.count, 1)
    }

    func testCorruptFolderIsSkippedAndReported() throws {
        let library = MeasurementLibrary(root: root)
        let good = record(rate: 96_000, name: "Good"), bad = record(rate: 96_000, name: "Bad"), gone = record(rate: 96_000, name: "NoIR")
        for r in [good, bad, gone] { try library.save(r, impulseResponse: ir(64)) }
        try Data("not json".utf8).write(to: root.appendingPathComponent(bad.id.uuidString).appendingPathComponent("record.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(gone.id.uuidString).appendingPathComponent("ir.wav"))
        let loaded = try library.load()
        XCTAssertEqual(loaded.records.map(\.name), ["Good"])
        XCTAssertEqual(loaded.errors.count, 2)
        var truncated = MeasurementFloatWAV.encode(ir(16), sampleRate: 48_000)
        truncated.removeLast(10)
        XCTAssertThrowsError(try MeasurementFloatWAV.decode(truncated, name: "ir.wav"))
    }

    func testIndexSchemaFromNewerBuildIsNotOverwritten() throws {
        let library = MeasurementLibrary(root: root)
        try library.save(record(rate: 48_000), impulseResponse: ir(8))
        let index = root.appendingPathComponent("index.json")
        try String(contentsOf: index).replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 9").write(to: index, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try library.load())
    }

    func testMetadataUpdateAndDelete() throws {
        let library = MeasurementLibrary(root: root)
        let rec = record(rate: 48_000)
        try library.save(rec, impulseResponse: ir(8))
        try library.updateMetadata(id: rec.id) { $0.notes = "changed"; $0.group = "Sub" }
        XCTAssertEqual(try library.loadRecord(id: rec.id).notes, "changed")
        XCTAssertThrowsError(try library.updateMetadata(id: rec.id) { $0.name = "  " })
        try library.delete(id: rec.id)
        XCTAssertEqual(try library.load().records, [])
        XCTAssertThrowsError(try library.save(MeasurementRecord(name: " ", createdAt: Date(), sampleRate: 48_000), impulseResponse: nil))
    }

    func testDifferenceOfRecordWithItselfIsZero() {
        let r = response()
        for smoothing in MeasurementSmoothing.allCases {
            let d = MeasurementComparison.difference(r, reference: r, smoothing: smoothing)
            XCTAssertEqual(d.magnitudeDB.count, r.magnitudeDB.count)
            XCTAssertTrue(d.magnitudeDB.allSatisfy { abs($0) < 1e-9 }, "\(smoothing)")
        }
    }

    func testDifferenceRecoversOffsetAndResamplesGrid() {
        let r = response()
        var shifted = r
        shifted.magnitudeDB = r.magnitudeDB.map { $0 + 4 }
        // Reference on a coarser grid.
        let coarse = RoomCorrectionFrequencyResponse(
            frequenciesHz: stride(from: 0, to: 200, by: 4).map { r.frequenciesHz[$0] },
            magnitudeDB: stride(from: 0, to: 200, by: 4).map { r.magnitudeDB[$0] }, phaseRadians: nil)
        let d = MeasurementComparison.difference(shifted, reference: coarse, smoothing: .none)
        XCTAssertEqual(d.magnitudeDB[100], 4, accuracy: 0.2)
        let flat = MeasurementComparison.difference(shifted, reference: r, smoothing: .octave3)
        XCTAssertTrue(flat.magnitudeDB.allSatisfy { abs($0 - 4) < 1e-9 })
    }

    func testOverlayLimitAndReference() throws {
        var set = MeasurementOverlaySet()
        let ids = (0..<8).map { _ in UUID() }
        for id in ids { try set.add(id) }
        XCTAssertThrowsError(try set.add(UUID())) { XCTAssertEqual($0 as? MeasurementLibraryError, .tooManyOverlays(limit: 8)) }
        set.setReference(ids[2])
        set.remove(ids[2])
        XCTAssertNil(set.referenceID)
        XCTAssertEqual(set.overlayIDs.count, 7)
    }

    func testRoomCorrectionCopyNeedsMatchingRatesAndData() throws {
        let library = MeasurementLibrary(root: root)
        let l = record(rate: 48_000, name: "L"), r = record(rate: 48_000, name: "R"), other = record(rate: 96_000, name: "X")
        var curveOnly = record(rate: 48_000, name: "C"); curveOnly.hasImpulseResponse = false
        let samples = ir(256)
        let ls = try library.save(l, impulseResponse: samples), rs = try library.save(r, impulseResponse: ir(256))
        let os = try library.save(other, impulseResponse: ir(256))
        let cs = try library.save(curveOnly, impulseResponse: nil)
        let analysis = try library.roomCorrectionAnalysis(left: ls, right: rs)
        XCTAssertEqual(analysis.left.impulseResponse.map(\.bitPattern), samples.map(\.bitPattern))
        XCTAssertEqual(analysis.sampleRate, 48_000)
        XCTAssertThrowsError(try library.roomCorrectionAnalysis(left: ls, right: os))
        XCTAssertThrowsError(try library.roomCorrectionAnalysis(left: ls, right: cs))
    }
}
