import XCTest
@testable import NotchSixty

/// E10 S5: curtains, offsets and the target library.
final class RoomCorrectionTargetEditorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("targets-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testCurtainsReachUnityWithinOneThirdOctave() {
        let s = TargetShaping(lowCurtainHz: 40, highCurtainHz: 300)
        for f in [40.0, 100, 300] { XCTAssertEqual(s.curtainWeight(at: f), 1, accuracy: 1e-12) }
        let third = pow(2, 1.0 / 3)
        XCTAssertEqual(s.curtainWeight(at: 300 * third), 0, accuracy: 1e-12)
        XCTAssertEqual(s.curtainWeight(at: 40 / third), 0, accuracy: 1e-12)
        XCTAssertEqual(s.curtainWeight(at: 300 * pow(2, 1.0 / 6)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.shapedCorrectionDB(-6, at: 1_000), 0, accuracy: 1e-12)
        XCTAssertEqual(s.shapedCorrectionDB(-6, at: 20), 0, accuracy: 1e-12)
        var previous = 1.0
        for i in 0 ... 20 {
            let w = s.curtainWeight(at: 300 * pow(third, Double(i) / 20))
            XCTAssertLessThanOrEqual(w, previous + 1e-12)
            previous = w
        }
    }

    func testLimitedRangePresetUsesDefaultHighCurtain() {
        let s = TargetShaping.limitedRange()
        XCTAssertEqual(s.highCurtainHz, 300)
        XCTAssertEqual(s.curtainWeight(at: 100), 1, accuracy: 1e-12)
        XCTAssertEqual(s.curtainWeight(at: 2_000), 0, accuracy: 1e-12)
    }

    func testOffsetsApplyPerChannelOnly() {
        var shaping = ChannelTargetShaping()
        shaping[1] = TargetShaping(levelOffsetDB: 2, tiltDBPerOctave: -1)
        XCTAssertEqual(shaping.targetDB(shared: 0, channel: 0, at: 4_000), 0, accuracy: 1e-12)
        XCTAssertEqual(shaping.targetDB(shared: 0, channel: 1, at: 4_000), 0, accuracy: 1e-12)
        XCTAssertEqual(shaping.targetDB(shared: 1, channel: 1, at: 1_000), 3, accuracy: 1e-12)
        XCTAssertEqual(shaping.targetDB(shared: 1, channel: 0, at: 1_000), 1, accuracy: 1e-12)
        XCTAssertEqual(shaping.targetDB(shared: 0, channel: 2, at: 125), 0, accuracy: 1e-12)
        shaping[1] = .none
        XCTAssertTrue(shaping.channels.isEmpty)
    }

    private func sample() -> TargetRecord {
        var shaping = ChannelTargetShaping()
        shaping[0] = TargetShaping.limitedRange()
        shaping[3] = TargetShaping(lowCurtainHz: 30.1234567891234, levelOffsetDB: -1.1, tiltDBPerOctave: 0.37)
        return TargetRecord(name: "Mine", points: [
            .init(frequencyHz: 20, gainDB: 3.123456789012345),
            .init(frequencyHz: 1_000.5, gainDB: 0.1),
            .init(frequencyHz: 20_000, gainDB: -2.7)], shaping: shaping)
    }

    func testLibraryRoundTripIsBitExact() throws {
        let library = TargetLibrary(directory: directory)
        let record = sample()
        try library.save(record)
        XCTAssertEqual(try library.load(id: record.id), record)
        let report = library.loadAll()
        XCTAssertEqual(report.records.last, record)
        XCTAssertTrue(report.skipped.isEmpty)
        let before = try Data(contentsOf: directory.appendingPathComponent("\(record.id.uuidString).json"))
        try library.save(try library.load(id: record.id))
        XCTAssertEqual(before, try Data(contentsOf: directory.appendingPathComponent("\(record.id.uuidString).json")))
    }

    func testBuiltInsListedAndProtected() throws {
        let library = TargetLibrary(directory: directory)
        let builtIn = TargetLibrary.builtIns[0]
        XCTAssertEqual(library.loadAll().records.count, TargetLibrary.builtIns.count)
        XCTAssertThrowsError(try library.save(builtIn))
        XCTAssertThrowsError(try library.delete(id: builtIn.id))
        let copy = try library.duplicate(builtIn)
        XCTAssertNotEqual(copy.id, builtIn.id)
        try library.rename(id: copy.id, to: "Renamed")
        XCTAssertEqual(try library.load(id: copy.id).name, "Renamed")
        try library.delete(id: copy.id)
        XCTAssertEqual(library.loadAll().records.count, TargetLibrary.builtIns.count)
    }

    func testSchemaVersionRejected() throws {
        let library = TargetLibrary(directory: directory)
        var record = sample()
        try library.save(record)
        record.schema = 2
        XCTAssertThrowsError(try TargetLibrary.validate(record)) {
            XCTAssertEqual($0 as? TargetLibraryError, .unsupportedSchema(2))
        }
        let url = directory.appendingPathComponent("\(record.id.uuidString).json")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"schema\" : 1", with: "\"schema\" : 2")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try library.load(id: record.id)) {
            XCTAssertEqual($0 as? TargetLibraryError, .unsupportedSchema(2))
        }
        let report = library.loadAll()
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(report.records.count, TargetLibrary.builtIns.count)
    }

    func testCorruptFileIsSkippedAndReported() throws {
        let library = TargetLibrary(directory: directory)
        let good = sample()
        var bad = sample(); bad.id = UUID(); bad.name = "Bad"
        try library.save(bad)
        try library.save(good)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("\(bad.id.uuidString).json"))
        let report = library.loadAll()
        XCTAssertEqual(report.skipped.map(\.file), ["\(bad.id.uuidString).json"])
        XCTAssertEqual(report.records.last, good)
    }

    func testREWTextRoundTripWithin0p001dB() throws {
        let record = sample()
        let data = TargetLibrary.exportREW(record)
        let back = try TargetLibrary.importREW(data, name: "Back")
        XCTAssertEqual(back.points.count, record.points.count)
        for (a, b) in zip(record.points, back.points) {
            XCTAssertEqual(a.frequencyHz, b.frequencyHz, accuracy: a.frequencyHz * 1e-8)
            XCTAssertEqual(a.gainDB, b.gainDB, accuracy: 0.001)
        }
    }
}
