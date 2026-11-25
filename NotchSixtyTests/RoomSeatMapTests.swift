import SwiftUI
import XCTest
@testable import NotchSixty

/// E29 S4: the seat map's view model (build from live records, edits persist, geometry link, unpositioned points
/// listed, stale state, usage text), its layout maths, and that the section is hosted without overflow and is only
/// shown behind `e29.room-model`.
@MainActor
final class RoomSeatMapTests: XCTestCase {
    private var root: URL!
    private var store: RoomCorrectionProjectStore!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("seatmap-\(UUID().uuidString)", isDirectory: true)
        store = RoomCorrectionProjectStore(rootDirectory: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func channel() -> RoomCorrectionChannelMeasurement {
        var q = RoomCorrectionMeasurementQuality()
        q.sweepComplete = true
        return RoomCorrectionChannelMeasurement(
            capturedAt: date, rawCapture: [], impulseResponse: [1, 0.5], transferFunction: nil, quality: q)
    }

    private func project(seats: [String], gain: Double? = nil) -> RoomCorrectionProject {
        var p = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
        p.measurements = seats.map {
            RoomCorrectionMeasurementPosition(
                name: $0, sampleRate: 48_000, left: channel(), right: channel(), outputGainDBAtMeasurement: gain)
        }
        return p
    }

    private func geometry(_ p: RoomCorrectionProject) -> RoomGeometryModel { .template(projectID: p.id) }

    func testBuildsPointsAndPathsFromProjectRecords() {
        let p = project(seats: ["Main", "Left sofa"])
        let map = RoomSeatMapController(projectStore: store)
        map.load(project: p, geometry: nil)
        XCTAssertEqual(map.points.filter { $0.kind == .seat }.count, 2)
        XCTAssertEqual(map.pathRows.count, 4)
        XCTAssertTrue(map.pathRows.allSatisfy { $0.state == "Measured" })
        XCTAssertTrue(map.pathRows.allSatisfy { $0.usedBy.contains("magnitude only") }, "legacy positions have timing tier none")
    }

    func testUnpositionedPointsStayListed() {
        let p = project(seats: ["Main"])
        let map = RoomSeatMapController(projectStore: store)
        map.load(project: p, geometry: nil)
        XCTAssertEqual(map.unpositionedPoints.count, map.points.count)
        XCTAssertTrue(map.positionedPoints.isEmpty)
    }

    func testEnteredPositionPersistsAcrossReload() throws {
        let p = project(seats: ["Main", "Sofa"])
        let a = RoomSeatMapController(projectStore: store)
        a.load(project: p, geometry: nil)
        let sofa = try XCTUnwrap(a.points.first { $0.name == "Sofa" })
        a.setPosition(sofa.id, x: 1.5, y: 3.25, z: nil)
        XCTAssertEqual(a.points.first { $0.id == sofa.id }?.position?.z ?? 0, 1.1, accuracy: 1e-9, "seat default height")

        let b = RoomSeatMapController(projectStore: store)
        b.load(project: p, geometry: nil)
        let pos = try XCTUnwrap(b.points.first { $0.id == sofa.id }?.position)
        XCTAssertEqual(pos.x, 1.5, accuracy: 1e-9)
        XCTAssertEqual(pos.y, 3.25, accuracy: 1e-9)
        XCTAssertEqual(b.unpositionedPoints.count, b.points.count - 1)

        b.clearPosition(sofa.id)
        let c = RoomSeatMapController(projectStore: store)
        c.load(project: p, geometry: nil)
        XCTAssertNil(c.points.first { $0.id == sofa.id }?.position)
    }

    func testGeometryLinksSpeakersAndMainSeatWithoutSecondStore() throws {
        let p = project(seats: ["Main", "Sofa"])
        let g = geometry(p)
        let map = RoomSeatMapController(projectStore: store)
        map.load(project: p, geometry: g)
        let left = try XCTUnwrap(map.points.first { $0.id == RoomModelAdapter.leftFeedID }?.position)
        XCTAssertEqual(left.x, g.leftSpeaker.x, accuracy: 1e-9)
        let main = try XCTUnwrap(map.points.first { $0.name == "Main" }?.position)
        XCTAssertEqual(main.y, g.listener.y, accuracy: 1e-9)
        XCTAssertNil(map.points.first { $0.name == "Sofa" }?.position)

        // Moving a linked point returns the geometry for the advisor and writes nothing of its own.
        let updated = try XCTUnwrap(map.setPosition(RoomModelAdapter.rightFeedID, x: 3.1, y: 0.8, z: nil))
        XCTAssertEqual(updated.rightSpeaker.x, 3.1, accuracy: 1e-9)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.projectDirectory(for: p.id).appendingPathComponent("room-model/RoomModel.json").path))
        map.clearPosition(RoomModelAdapter.rightFeedID)
        XCTAssertNotNil(map.message)
    }

    func testGeometryWithoutMeasurementsStillShowsSpeakersAndListener() {
        let p = project(seats: [])
        let map = RoomSeatMapController(projectStore: store)
        map.load(project: p, geometry: geometry(p))
        XCTAssertEqual(map.points.count, 3)
        XCTAssertTrue(map.unpositionedPoints.isEmpty)
    }

    func testStaleStateUsesTheSharedMessage() {
        let p = project(seats: ["Main"], gain: -10)
        let map = RoomSeatMapController(projectStore: store)
        var ctx = RoomModelContext()
        ctx.outputGainDB = -3
        map.load(project: p, geometry: nil, context: ctx)
        XCTAssertTrue(map.pathRows.allSatisfy { $0.state.contains(RoomModelRule.staleMessage) })
        XCTAssertTrue(map.summaryText.contains("2 stale"))
    }

    func testNonFinitePositionIsRefused() throws {
        let p = project(seats: ["Main"])
        let map = RoomSeatMapController(projectStore: store)
        map.load(project: p, geometry: nil)
        let id = try XCTUnwrap(map.points.first?.id)
        map.setPosition(id, x: .nan, y: 1, z: nil)
        XCTAssertNil(map.points.first { $0.id == id }?.position)
    }

    func testLayoutRoundTripsAndClamps() {
        let l = RoomSeatMapLayout(widthMetres: 4, lengthMetres: 5, viewWidth: 400, viewHeight: 500)
        let v = l.viewPoint(x: 1, y: 2.5)
        XCTAssertEqual(v.x, 100, accuracy: 1e-9)
        XCTAssertEqual(v.y, 250, accuracy: 1e-9)
        let m = l.metres(viewX: v.x, viewY: v.y)
        XCTAssertEqual(m.x, 1, accuracy: 1e-9)
        XCTAssertEqual(l.metres(viewX: -50, viewY: 9_999).y, 5, accuracy: 1e-9)
    }

    func testUnitsFollowLocale() {
        XCTAssertEqual(RoomSeatMapUnit.forLocale(Locale(identifier: "en_GB")), .metres)
        XCTAssertEqual(RoomSeatMapUnit.forLocale(Locale(identifier: "en_US")), .feet)
        XCTAssertEqual(RoomSeatMapUnit.feet.perMetre * 0.3048, 1, accuracy: 1e-6)
    }

    func testSectionFitsAtBothScreenSizesAndLabelsPoints() throws {
        let advisor = RoomTreatmentAdvisorController(store: store)
        var p = project(seats: ["Main", "Sofa"])
        try store.save(p)
        p = try store.load(p.id)
        advisor.reloadProjects()
        for width in [1_280.0, 1_900.0] {
            let host = NSHostingView(rootView: ProductionSeatMapSection(advisor: advisor).frame(width: width))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5)
        }
        XCTAssertEqual(ProductionSeatMapSection.kindName(.seat), "seat")
        for k in RoomPointKind.allCases { XCTAssertFalse(ProductionSeatMapSection.symbol(k).isEmpty) }
    }

    func testFlagIsRegisteredAndNotGraduated() {
        XCTAssertTrue(FeatureFlag.all.contains(where: { $0.id == "e29.room-model" }))
        XCTAssertFalse(FeatureFlag.roomModel.graduated)
    }
}
