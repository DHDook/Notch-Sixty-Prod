import XCTest
@testable import NotchSixty

/// E13 S1: the bring-your-own importer and target library schema 2. Fixtures are written here.
final class FrequencyResponseImporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("e13-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private let autoEq = """
    frequency,raw,error,smoothed,equalization,parametric_eq,fixed_band_eq,target
    20,1.5,0,1.4,0,0,0,0.5
    1000,0.0,0,0,0,0,0,0.0
    10000,-3.0,0,-3,0,0,0,-2.0
    """

    func testAutoEqPicksRawAndOffersTarget() throws {
        let c = try FrequencyResponseImporter.parse(autoEq, sourceName: "hp")
        XCTAssertEqual(c.format, .autoEqCSV)
        XCTAssertEqual(c.frequenciesHz, [20, 1000, 10000])
        XCTAssertEqual(c.db, [1.5, 0, -3])
        XCTAssertEqual(c.offeredTarget, [0.5, 0, -2])
    }

    func testAutoEqWithoutRawUsesFirstNumericColumn() throws {
        let c = try FrequencyResponseImporter.parse("Frequency,SPL\n20,3\n100,2\n", sourceName: "x")
        XCTAssertEqual(c.db, [3, 2])
    }

    func testREWSquigAndFRDParse() throws {
        let rew = "* Measurement\n* Freq(Hz) SPL(dB)\n20 1.0\n100 2.0\n1000 0.0\n"
        let squig = "Frequency (Hz)\tdB\n20\t1.0\n100\t2.0\n1000\t0.0\n"
        let frd = "20 1.0 10\n100 2.0 20\n1000 0.0 30\n"
        for (text, phase) in [(rew, false), (squig, false), (frd, true)] {
            let c = try FrequencyResponseImporter.parse(text, sourceName: "f")
            XCTAssertEqual(c.format, .text)
            XCTAssertEqual(c.frequenciesHz, [20, 100, 1000])
            XCTAssertEqual(c.db, [1, 2, 0])
            XCTAssertEqual(c.phaseDegrees != nil, phase)
        }
    }

    func testDecimalCommaMatchesDotFile() throws {
        let dot = try FrequencyResponseImporter.parse("20;1.5\n1000.5;0.25\n", sourceName: "a")
        let comma = try FrequencyResponseImporter.parse("20;1,5\n1000,5;0,25\n", sourceName: "a")
        let tab = try FrequencyResponseImporter.parse("20\t1,5\n1000,5\t0,25\n", sourceName: "a")
        XCTAssertEqual(dot, comma)
        XCTAssertEqual(dot, tab)
        let csv = try FrequencyResponseImporter.parse("frequency;raw\n20;1,5\n1000,5;0,25\n", sourceName: "a")
        XCTAssertEqual(csv.db, [1.5, 0.25])
    }

    func testNoDataThrows() {
        XCTAssertThrowsError(try FrequencyResponseImporter.parse("hello\nworld\n", sourceName: "a"))
    }

    func testLeftRightPairing() throws {
        func curve(_ n: String) throws -> ImportedCurve { try FrequencyResponseImporter.parse("20 1\n30 2\n", sourceName: n) }
        let l = try curve("HD600 L.txt"), r = try curve("HD600 R.txt")
        let pair = try XCTUnwrap(FrequencyResponseImporter.stereo([r, l]))
        XCTAssertEqual(pair.left.sourceName, "HD600 L.txt")
        XCTAssertEqual(pair.right.sourceName, "HD600 R.txt")
        let lr = try XCTUnwrap(FrequencyResponseImporter.stereo([try curve("cans_left"), try curve("cans_right")]))
        XCTAssertEqual(lr.left.sourceName, "cans_left")
        XCTAssertNil(FrequencyResponseImporter.stereo([try curve("A L"), try curve("B R")]))
        let one = try XCTUnwrap(FrequencyResponseImporter.stereo([l]))
        XCTAssertEqual(one.left, one.right)
    }

    func testDenseCurveReducesDeterministically() throws {
        let n = 2000
        let f = (0 ..< n).map { 10 * pow(2000.0, Double($0) / Double(n - 1)) }
        let v = f.map { 3 * sin(log2($0)) }
        let a = FrequencyResponseImporter.reduced(frequenciesHz: f, db: v)
        let b = FrequencyResponseImporter.reduced(frequenciesHz: f, db: v)
        XCTAssertEqual(a.frequenciesHz, b.frequenciesHz)
        XCTAssertEqual(a.db.map(\.bitPattern), b.db.map(\.bitPattern))
        XCTAssertEqual(a.frequenciesHz.count, FrequencyResponseImporter.referenceGrid.count)
        XCTAssertLessThan(a.frequenciesHz.count, 512)
        // A short curve is untouched.
        let s = FrequencyResponseImporter.reduced(frequenciesHz: [20, 30], db: [1, 2])
        XCTAssertEqual(s.frequenciesHz, [20, 30])
    }

    func testTargetNormalisedAtOneKilohertzWithProvenance() throws {
        let c = try FrequencyResponseImporter.parse("20 5\n1000 3\n20000 1\n", sourceName: "t")
        let r = try FrequencyResponseImporter.targetRecord(from: c, category: .headphone,
                                                           attribution: "me", importDate: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r.points.map(\.gainDB), [2, 0, -2])
        XCTAssertEqual(r.category, .headphone)
        XCTAssertEqual(r.provenance?.fileName, "t")
        XCTAssertEqual(r.provenance?.attribution, "me")
        XCTAssertEqual(r.schema, 2)
        let offered = try FrequencyResponseImporter.parse(autoEq, sourceName: "e")
        let t = try FrequencyResponseImporter.targetRecord(from: offered, useOfferedTarget: true, category: .room)
        XCTAssertEqual(t.points.map(\.gainDB), [0.5, 0, -2])
    }

    func testSchemaOneLoadsAsRoomAndSchemaThreeRejected() throws {
        let id = UUID()
        let v1 = """
        {"schema":1,"id":"\(id.uuidString)","name":"Old","points":[{"frequencyHz":20,"gainDB":1},{"frequencyHz":1000,"gainDB":0}]}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        try Data(v1.utf8).write(to: url)
        try Data("{\"schema\":1,\"ids\":[\"\(id.uuidString)\"]}".utf8).write(to: directory.appendingPathComponent("index.json"))
        let library = TargetLibrary(directory: directory)
        let loaded = try library.load(id: id)
        XCTAssertEqual(loaded.category, .room)
        XCTAssertNil(loaded.provenance)
        XCTAssertTrue(library.loadAll().records.contains { $0.id == id })
        XCTAssertEqual(try Data(contentsOf: url), Data(v1.utf8), "load must not rewrite the file")
        try library.save(loaded)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"schema\" : 2"))
        let v3 = v1.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":3")
        XCTAssertThrowsError(try TargetLibrary.decode(Data(v3.utf8))) {
            XCTAssertEqual($0 as? TargetLibraryError, .unsupportedSchema(3))
        }
    }

    func testCategoryFilterAndCaution() throws {
        var a = TargetRecord(name: "a", points: [.init(frequencyHz: 20, gainDB: 0), .init(frequencyHz: 30, gainDB: 0)])
        var b = a; b.name = "b"; b.category = .headphone
        var g = a; g.name = "g"; g.category = .general
        a.category = .room
        let all = [a, b, g]
        XCTAssertEqual(TargetLibrary.visible(all, for: .room, showAll: false).map(\.name), ["a", "g"])
        XCTAssertEqual(TargetLibrary.visible(all, for: .room, showAll: true).count, 3)
        XCTAssertNotNil(TargetLibrary.crossCategoryCaution(b, picker: .room))
        XCTAssertNil(TargetLibrary.crossCategoryCaution(g, picker: .room))
    }

    func testImportedTargetChangesDesignerTarget() throws {
        let c = try FrequencyResponseImporter.parse("20 6\n1000 0\n20000 -6\n", sourceName: "t")
        let record = try FrequencyResponseImporter.targetRecord(from: c, category: .room)
        let flat = RoomCorrectionBuiltInTarget.flat.curve
        XCTAssertNotEqual(record.curve.points, flat.points)
        XCTAssertEqual(record.curve.id, record.id)
        // The library round-trips it exactly, as the card's setTarget path consumes record.curve.
        let library = TargetLibrary(directory: directory)
        try library.save(record)
        XCTAssertEqual(try library.load(id: record.id).curve.points, record.curve.points)
    }

    func testFlagDefaultsOffAndIsRegistered() {
        XCTAssertTrue(FeatureFlag.all.contains(.byoImport))
        XCTAssertFalse(FeatureFlag.byoImport.defaultEnabled)
    }
}
