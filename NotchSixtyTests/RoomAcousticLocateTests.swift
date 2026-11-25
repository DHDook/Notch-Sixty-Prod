import XCTest
@testable import NotchSixty

/// E29 S5 (`e29.room-model`): acoustic locate through the Swift import and the seat map's "Locate from measurement".
/// The maths and the image-source reference room are covered at the eight rates by
/// `core/tests/test_roommodel_locate.cpp`; these tests cover the imported surface at the eight rates, the refusal
/// without loopback timing, the sub exclusion, and the seat-map flow from library records to a stored position.
@MainActor
final class RoomAcousticLocateTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let left = RoomPosition(x: 1.5, y: 0.3, z: 0.9, source: .typed, uncertaintyMetres: nil)
    private let right = RoomPosition(x: 3.5, y: 0.3, z: 0.9, source: .typed, uncertaintyMetres: nil)
    private let seat = (x: 2.3, y: 2.6, z: 1.1)
    private var root: URL!
    private var store: RoomCorrectionProjectStore!
    private var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
    private var records: [MeasurementRecord] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("locate-\(UUID().uuidString)", isDirectory: true)
        store = RoomCorrectionProjectStore(rootDirectory: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A direct arrival from a speaker at the seat, as a windowed sinc so the delay is sub-sample exact.
    private func ir(from speaker: RoomPosition, rate: Double) -> [Float] {
        let dx = speaker.x - seat.x, dy = speaker.y - seat.y, dz = speaker.z - seat.z
        let r = (dx * dx + dy * dy + dz * dz).squareRoot()
        let pos = r / 343.0 * rate
        var h = [Float](repeating: 0, count: Int(rate * 0.05))
        let c0 = Int(pos.rounded(.down))
        for t in (c0 - 15)...(c0 + 16) where t >= 0 && t < h.count {
            let x = Double(t) - pos
            let s = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            let w = 0.5 * (1 + cos(Double.pi * x / 16))
            h[t] = Float(s * w / r)
        }
        return h
    }

    private func sources(rate: Double, trusted: Bool = true) -> [RoomLocateSource] {
        [("Left", left), ("Right", right)].map { name, pos in
            RoomLocateSource(
                speakerName: name, speakerPosition: pos, impulseResponse: ir(from: pos, rate: rate), sampleRate: rate,
                timingTrusted: trusted)
        }
    }

    func testLocatesAtTheEightRates() throws {
        for rate in Self.rates {
            guard case .located(let fix) = RoomAcousticLocator.locate(sources(rate: rate), seatHeight: seat.z) else {
                return XCTFail("no fix at \(rate)")
            }
            XCTAssertEqual(fix.position.x, seat.x, accuracy: 0.02, "rate \(rate)")
            XCTAssertEqual(fix.position.y, seat.y, accuracy: 0.02, "rate \(rate)")
            XCTAssertEqual(fix.position.source, .acousticLocate)
            XCTAssertNotNil(fix.position.uncertaintyMetres)
            XCTAssertEqual(fix.speakersUsed, 2)
        }
    }

    func testRefusedWithoutLoopbackTiming() {
        XCTAssertEqual(RoomAcousticLocator.locate(sources(rate: 48_000, trusted: false), seatHeight: 1.1), .refused(.noLoopbackTiming))
    }

    func testSubIsExcluded() throws {
        var all = sources(rate: 48_000)
        all.append(RoomLocateSource(
            speakerName: "Sub", speakerPosition: RoomPosition(x: 0.2, y: 3, z: 0.3, source: .typed, uncertaintyMetres: nil),
            impulseResponse: [Float](repeating: 0, count: 64), sampleRate: 48_000, timingTrusted: false, isSub: true))
        guard case .located(let fix) = RoomAcousticLocator.locate(all, seatHeight: seat.z) else { return XCTFail("no fix") }
        XCTAssertEqual(fix.excludedSubs, 1)
        XCTAssertEqual(fix.speakersUsed, 2)
        XCTAssertEqual(fix.position.x, seat.x, accuracy: 0.02)
    }

    func testMixedRatesAreRefused() {
        var mixed = sources(rate: 48_000)
        mixed[1] = sources(rate: 96_000)[1]
        XCTAssertEqual(RoomAcousticLocator.locate(mixed, seatHeight: 1.1), .refused(.mixedRates))
    }

    func testDelayCrossCheckNeedsADisagreement() {
        var cal = StereoBassAlignment()
        // Left is nearer by 0.686 m, so it should be delayed 2 ms more than right.
        XCTAssertNil(RoomAcousticLocator.delayCrossCheck(left: 2.0, right: 2.686, calibration: nil))
        XCTAssertNotNil(RoomAcousticLocator.delayCrossCheck(left: 2.0, right: 2.686, calibration: cal))
        cal.left.delayMs = 2
        XCTAssertNil(RoomAcousticLocator.delayCrossCheck(left: 2.0, right: 2.686, calibration: cal))
    }

    // MARK: Seat map

    private func record(seat: String, channel: String, tier: String?, rate: Double) -> MeasurementRecord {
        MeasurementRecord(
            name: "\(seat) \(channel)", createdAt: Date(timeIntervalSince1970: 1_800_000_000), sampleRate: rate,
            channel: channel, seat: seat, timingTier: tier)
    }

    private func mapWith(tier: String?, rate: Double = 96_000, placeSpeakers: Bool = true) throws
        -> (RoomSeatMapController, UUID)
    {
        let rec = [("Left", left), ("Right", right)].map { (record(seat: "Sofa", channel: $0.0, tier: tier, rate: rate), $0.1) }
        let irs = Dictionary(uniqueKeysWithValues: rec.map { ($0.0.id, ir(from: $0.1, rate: rate)) })
        let map = RoomSeatMapController(projectStore: store, impulseResponseLoader: { irs[$0] })
        var geometry = RoomGeometryModel.template(projectID: project.id)
        geometry.leftSpeaker = RoomGeometryPoint3D(x: left.x, y: left.y, z: left.z)
        geometry.rightSpeaker = RoomGeometryPoint3D(x: right.x, y: right.y, z: right.z)
        records = rec.map(\.0)
        map.load(project: project, geometry: placeSpeakers ? geometry : nil, library: records)
        let sofa = try XCTUnwrap(map.points.first { $0.name == "Sofa" })
        return (map, sofa.id)
    }

    func testSeatMapLocatesFromLibraryMeasurementsAndPersists() throws {
        let (map, sofa) = try mapWith(tier: "loopback")
        XCTAssertNil(map.locateUnavailableReason(for: sofa))
        map.locate(sofa)
        let pos = try XCTUnwrap(map.points.first { $0.id == sofa }?.position)
        XCTAssertEqual(pos.x, seat.x, accuracy: 0.02)
        XCTAssertEqual(pos.y, seat.y, accuracy: 0.02)
        XCTAssertEqual(pos.source, .acousticLocate)
        XCTAssertNotNil(pos.uncertaintyMetres)
        XCTAssertTrue(map.locateMessage?.contains("Located at") ?? false)

        // The located position is stored like any entered position.
        let reload = RoomSeatMapController(projectStore: store)
        reload.load(project: project, geometry: nil, library: records)
        let again = try XCTUnwrap(reload.points.first { $0.id == sofa }?.position)
        XCTAssertEqual(again.x, pos.x, accuracy: 1e-9)
        XCTAssertEqual(again.source, .acousticLocate)
        XCTAssertEqual(again.uncertaintyMetres ?? -1, pos.uncertaintyMetres ?? -2, accuracy: 1e-9)
    }

    func testSeatMapRefusesWithoutLoopbackTiming() throws {
        let (map, sofa) = try mapWith(tier: nil)
        XCTAssertEqual(map.locateUnavailableReason(for: sofa), RoomLocateRefusal.noLoopbackTiming.message)
        map.locate(sofa)
        XCTAssertNil(map.points.first { $0.id == sofa }?.position)
        XCTAssertEqual(map.locateMessage, RoomLocateRefusal.noLoopbackTiming.message)
    }

    func testSeatMapNeedsSpeakerPositions() throws {
        let (map, sofa) = try mapWith(tier: "reference", placeSpeakers: false)
        XCTAssertTrue(map.locateUnavailableReason(for: sofa)?.contains("Enter the position") ?? false)
    }

    func testSpeakersAreNotLocatable() throws {
        let (map, _) = try mapWith(tier: "loopback")
        let feed = try XCTUnwrap(map.points.first { $0.kind == .speakerFeed })
        XCTAssertNotNil(map.locateUnavailableReason(for: feed.id))
    }
}
