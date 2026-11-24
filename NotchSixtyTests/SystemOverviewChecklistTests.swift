import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S15 (G14, G15, G20): the Overview checklist, the verification record and the out-of-date notice.
@MainActor
final class SystemOverviewChecklistTests: XCTestCase {
    private let flags = FeatureFlags()

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    private func summary(design: UUID = UUID()) -> RoomCorrectionCalibrationSummary {
        RoomCorrectionCalibrationSummary(
            projectID: UUID(), activeDesignID: design, designDate: Date(timeIntervalSince1970: 1_000),
            positionCount: 3, correctionLowHz: 20, correctionHighHz: 300, targetName: "Flat",
            smoothingOctaves: 1.0 / 6, maximumBoostDB: 3, maximumCutDB: 12,
            recommendedHeadroomDB: 6, algorithmVersion: "t")
    }

    private func stamp(
        uid: String? = "out", bass: BassManagementConfiguration = BassManagementConfiguration(),
        routing: SpeakerRoutingConfiguration? = nil
    ) -> SystemCalibrationStamp {
        SystemCalibrationStamp(
            outputUID: uid, arrangement: nil, outputRouting: nil, speakerRouting: routing, bass: bass)
    }

    private func inputs(
        record: SystemCalibrationRecord? = nil, current: SystemCalibrationStamp? = nil,
        calibration: RoomCorrectionCalibrationSummary? = nil
    ) -> SystemChecklistInputs {
        var i = SystemChecklistInputs()
        i.arrangementSummary = "2 speakers."
        i.alignmentConfigured = true
        i.alignmentSummary = "aligned"
        i.bassEnabled = true
        i.bassSummary = "80 Hz"
        i.calibration = calibration
        i.record = record
        i.current = current
        return i
    }

    func testEmptySystemHasNothingDoneAndHighlightsTheFirstRow() {
        let rows = SystemChecklistModel.rows(SystemChecklistInputs())
        XCTAssertEqual(rows.map(\.rowID), SystemChecklistRowID.allCases)
        XCTAssertTrue(rows.allSatisfy { $0.state == .notDone })
        XCTAssertEqual(rows.filter(\.isNextStep).map(\.rowID), [.arrangement])
    }

    func testUnverifiedCorrectionPointsAtVerification() {
        let rows = SystemChecklistModel.rows(inputs(calibration: summary()))
        XCTAssertEqual(rows.map(\.state), [.done, .done, .done, .done, .notDone])
        XCTAssertEqual(rows.first(where: \.isNextStep)?.rowID, .verification)
    }

    func testVerifiedCorrectionIsAllDoneWithTheVerificationDate() {
        let design = UUID()
        let date = Date(timeIntervalSince1970: 5_000)
        let record = SystemCalibrationRecord(verifiedDesignID: design, verifiedDate: date, stamp: stamp(), stampDate: date)
        let rows = SystemChecklistModel.rows(inputs(record: record, current: stamp(), calibration: summary(design: design)))
        XCTAssertTrue(rows.allSatisfy { $0.state == .done })
        XCTAssertEqual(rows.last?.date, date)
        XCTAssertNil(rows.first(where: \.isNextStep))
    }

    func testVerificationOfAnotherDesignDoesNotCount() {
        let record = SystemCalibrationRecord(verifiedDesignID: UUID(), verifiedDate: Date(), stamp: stamp(), stampDate: Date())
        let rows = SystemChecklistModel.rows(inputs(record: record, current: stamp(), calibration: summary()))
        XCTAssertEqual(rows.last?.state, .notDone)
    }

    func testEachOutOfDateReasonIsNamedOnTheRows() {
        var way = RoutedWay(endpoint: PhysicalOutputEndpoint(deviceUID: "d", channelIndex: 0))
        let base = SpeakerRoutingConfiguration(
            schemaVersion: SpeakerRoutingConfiguration.currentSchemaVersion, enabled: true,
            speakers: [RoutedSpeaker(source: RoutingSource(kind: .program, index: 0), ways: [way])], matrix: [])
        var trimmed = base
        way.trimDB = 2
        trimmed.speakers[0].ways = [way]
        var bass = BassManagementConfiguration()
        bass.frequencyHz = 100
        var subTrim = BassManagementConfiguration()
        subTrim.subGainDB = 3

        let recorded = stamp(routing: base)
        XCTAssertEqual(stamp(uid: "other", routing: base).changes(from: recorded), [.output])
        XCTAssertEqual(stamp(routing: trimmed).changes(from: recorded), [.trims])
        XCTAssertEqual(stamp(bass: subTrim, routing: base).changes(from: recorded), [.trims])
        XCTAssertEqual(stamp(bass: bass, routing: base).changes(from: recorded), [.crossover])
        XCTAssertTrue(stamp(routing: base).changes(from: recorded).isEmpty)

        let design = UUID()
        let record = SystemCalibrationRecord(verifiedDesignID: design, verifiedDate: Date(), stamp: recorded, stampDate: Date())
        let rows = SystemChecklistModel.rows(inputs(record: record, current: stamp(uid: "other", routing: base), calibration: summary(design: design)))
        XCTAssertEqual(rows.map(\.state), [.done, .outOfDate, .outOfDate, .outOfDate, .outOfDate])
        XCTAssertEqual(rows[1].reason, "Out of date: the output device changed.")
    }

    func testMovedMarkMakesItOutOfDateAndAgeAloneDoesNot() {
        let design = UUID()
        let old = Date(timeIntervalSince1970: 0)
        var record = SystemCalibrationRecord(verifiedDesignID: design, verifiedDate: old, stamp: stamp(), stampDate: old)
        XCTAssertTrue(record.outOfDateReasons(current: stamp()).isEmpty)
        record.movedDate = Date()
        XCTAssertEqual(record.outOfDateReasons(current: stamp()), [.moved])
        let rows = SystemChecklistModel.rows(inputs(record: record, current: stamp(), calibration: summary(design: design)))
        XCTAssertEqual(rows.last?.state, .outOfDate)
        XCTAssertEqual(rows.last?.reason, "Out of date: you said something moved.")
    }

    func testSampleRateIsNotPartOfTheStamp() {
        // Designs are built and cached per output rate, so the stamp has no rate field to differ.
        let mirror = Mirror(reflecting: stamp()).children.compactMap(\.label)
        XCTAssertFalse(mirror.contains { $0.lowercased().contains("rate") })
    }

    func testDashboardAttentionNamesTheReason() {
        var i = DashboardInputs()
        XCTAssertTrue(DashboardModel.attention(i).isEmpty)
        i.calibrationOutOfDate = "the output device changed"
        let item = DashboardModel.attention(i).first
        XCTAssertEqual(item?.kind, .calibrationOutOfDate)
        XCTAssertEqual(item?.destination.section, .system)
        XCTAssertTrue(item?.text.contains("the output device changed") == true)
    }

    func testProfileKeepsTheVerificationAcrossARelaunchAndMovedClearsOnReverify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s15-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profiles.json")
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: url)
        let design = UUID()
        _ = profiles.saveCurrentSystemProfile(named: "Room")
        profiles.recordSystemVerification(designID: design, date: Date(timeIntervalSince1970: 9_000))
        XCTAssertEqual(profiles.selectedSystemProfile?.state.calibrationRecord?.verifiedDesignID, design)

        let relaunched = ProductProfileController(engine: AudioIOEngine(), storageURL: url)
        let record = relaunched.selectedSystemProfile?.state.calibrationRecord
        XCTAssertEqual(record?.verifiedDesignID, design)
        XCTAssertEqual(record?.verifiedDate, Date(timeIntervalSince1970: 9_000))

        relaunched.markSystemMoved()
        XCTAssertNotNil(relaunched.selectedSystemProfile?.state.calibrationRecord?.movedDate)
        relaunched.recordSystemVerification(designID: design)
        XCTAssertNil(relaunched.selectedSystemProfile?.state.calibrationRecord?.movedDate)
    }

    func testOverviewChecklistFitsAtBothReferenceSizes() throws {
        flags.setEnabled(true, for: .systemPages)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s15fit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        let navigation = ProductionNavigation()
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let page = HostedPage(
                ProductionSystemOverviewView(engine: engine, profiles: profiles, navigation: navigation), size: size)
            let controls = page.controls.filter { [.button, .segmented, .popup, .toggle].contains($0.kind) }
            XCTAssertGreaterThanOrEqual(controls.count, 3, page.outline)
            for control in controls {
                let frame = control.view.convert(control.view.bounds, to: page.hosting)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(control.title) left of page at \(size.width)")
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(control.title) past the page at \(size.width)")
            }
        }
    }
}
