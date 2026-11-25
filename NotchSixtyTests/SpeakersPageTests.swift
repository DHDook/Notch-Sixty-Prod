import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S16 (G16, G17, G18, G91): one owner of bass and routing, the arrangement editor, and the distances and levels
/// table.
@MainActor
final class SpeakersPageTests: XCTestCase {
    private let flags = FeatureFlags()

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    // MARK: Owner line (G16)

    func testMatrixOwnsWhenEnabledAndSaysSo() {
        let page = SpeakersPageModel.make(matrixEnabled: true, bass: BassManagementConfiguration(), legacyRoutingReason: nil)
        XCTAssertEqual(page.owner, .routingMatrix)
        XCTAssertTrue(page.ownerLine.contains("routing matrix"))
        XCTAssertFalse(page.showsArrangementBassCards)
        XCTAssertNil(page.legacyBassNote)
    }

    func testMatrixOwnerShowsAStillPlayingLegacyCrossoverReadOnly() {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.frequencyHz = 90
        let page = SpeakersPageModel.make(matrixEnabled: true, bass: bass, legacyRoutingReason: nil)
        XCTAssertEqual(page.owner, .routingMatrix)
        let note = try? XCTUnwrap(page.legacyBassNote)
        XCTAssertTrue(note?.contains("90 Hz") == true)
    }

    func testArrangementOwnsWhenNoMatrixAndNamesTheCrossover() {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.frequencyHz = 80
        let on = SpeakersPageModel.make(matrixEnabled: false, bass: bass, legacyRoutingReason: nil)
        XCTAssertEqual(on.owner, .arrangement)
        XCTAssertTrue(on.showsArrangementBassCards)
        XCTAssertTrue(on.ownerLine.contains("80 Hz"))
        bass.enabled = false
        let off = SpeakersPageModel.make(matrixEnabled: false, bass: bass, legacyRoutingReason: nil)
        XCTAssertTrue(off.ownerLine.contains("no crossover is on"))
    }

    func testUnmigratedLegacyRoutingKeepsPlayingAndSaysWhy() {
        let page = SpeakersPageModel.make(
            matrixEnabled: false, bass: BassManagementConfiguration(), legacyRoutingReason: "three-way split.")
        XCTAssertTrue(page.ownerLine.contains("three-way split."))
        XCTAssertTrue(page.ownerLine.contains("keeps playing"))
    }

    // MARK: Table units and rows (G18)

    func testDistanceUnitsRoundTrip() {
        for ms in [0.0, 0.5, 2.92, 13.0, 50.0] {
            for unit in DistanceUnit.allCases {
                let d = SpeakerFeedTable.distance(delayMs: ms, unit: unit)
                XCTAssertEqual(SpeakerFeedTable.delayMs(distance: d, unit: unit), ms, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(SpeakerFeedTable.distance(delayMs: 1, unit: .metres), 0.343, accuracy: 1e-9)
        XCTAssertEqual(SpeakerFeedTable.distance(delayMs: 1, unit: .feet), 0.343 / 0.3048, accuracy: 1e-9)
    }

    func testEditsAreClampedToTheSupportedRanges() {
        let a = SpeakerFeedTable.editing(nil, side: .left) { $0.trimDB = 99; $0.delayMs = -4 }
        XCTAssertEqual(a.left.trimDB, 20)
        XCTAssertEqual(a.left.delayMs, 0)
        XCTAssertTrue(a.right.isIdentity)
        XCTAssertNil(a.issue)
    }

    func testRowsMarkManualChangeOnlyAgainstAMeasurement() {
        let uid = "u"
        func ep(_ i: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: uid, channelIndex: i) }
        var arrangement = SystemArrangement(
            outputs: SystemOutputs(deviceUID: uid, detectedChannelCount: 2, channelsInUse: 2),
            speakers: [ArrangedSpeaker(role: .frontLeft, feed: .direct(ep(0))),
                       ArrangedSpeaker(role: .frontRight, feed: .direct(ep(1)))])
        arrangement.stereoAlignment = StereoBassAlignment(
            left: SpeakerFeedCalibration(trimDB: 1.5, delayMs: 0.3, polarityInverted: false))
        let unmeasured = SpeakerFeedTable.rows(arrangement: arrangement, measured: nil)
        XCTAssertEqual(unmeasured.map(\.isManual), [false, false])
        let measured = MeasuredFeedCalibration(
            left: SpeakerFeedCalibration(trimDB: 1.5, delayMs: 0.3), right: SpeakerFeedCalibration())
        XCTAssertEqual(SpeakerFeedTable.rows(arrangement: arrangement, measured: measured).map(\.isManual), [false, false])
        arrangement.stereoAlignment?.right.trimDB = -2
        XCTAssertEqual(SpeakerFeedTable.rows(arrangement: arrangement, measured: measured).map(\.isManual), [false, true])
        XCTAssertTrue(SpeakerFeedTable.rows(arrangement: nil, measured: measured).isEmpty)
    }

    // MARK: Editor and table through the real services (G17, G18, G91)

    func testArrangementEditFromTheTabEqualsTheWizardsResult() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        rig.model.begin()
        rig.model.chooseOutput(uid: OfflineSetupRig.outputUID)
        rig.model.chooseChannelCount(2)
        rig.model.chooseBass(.dspMonoToMains)
        let wizard = try XCTUnwrap(rig.model.arrangement)

        let other = try OfflineSetupRig(rate: 48_000)
        defer { other.tearDown() }
        let editor = SpeakersArrangementEditorModel(engine: other.engine, profiles: other.profiles)
        editor.chooseBass(.dspMonoToMains)
        XCTAssertNil(editor.message)
        XCTAssertEqual(editor.arrangement, wizard)
        XCTAssertEqual(other.profiles.selectedSystemProfile?.state.systemArrangement, wizard)
        let compiled = try SystemArrangementCompiler.compile(wizard, preserving: nil).get()
        XCTAssertEqual(
            other.profiles.selectedSystemProfile?.state.bassManagement.enabled, compiled.bassManagementEnabled)
        XCTAssertEqual(other.engine.appliedStereoAlignment, compiled.stereoAlignment)
    }

    func testTableEditReachesTheEngineSurvivesRelaunchAndMarksOutOfDate() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let editor = SpeakersArrangementEditorModel(engine: rig.engine, profiles: rig.profiles)
        editor.chooseBass(.dspMonoToMains)
        // A measured alignment is on the system and stamped.
        let measured = SpeakerFeedCalibration(trimDB: 1.0, delayMs: 0.4, polarityInverted: false)
        try SpeakerFeedTableEditor.edit(side: .left, engine: rig.engine, profiles: rig.profiles) { $0 = measured }
        rig.profiles.recordMeasuredFeeds(left: measured, right: SpeakerFeedCalibration())
        let stampBefore = rig.profiles.currentCalibrationStamp()
        var record = rig.profiles.selectedSystemProfile?.state.calibrationRecord ?? SystemCalibrationRecord()
        XCTAssertNotNil(record.stamp, "G91: a configured system with no stamp takes one before the manual change")
        XCTAssertEqual(rig.profiles.selectedSystemProfile?.state.systemArrangement?.stereoAlignment?.left, measured)
        XCTAssertEqual(rig.engine.appliedStereoAlignment?.left.trimDB, 1.0)

        // The user nudges one speaker by ear.
        try SpeakerFeedTableEditor.edit(side: .right, engine: rig.engine, profiles: rig.profiles) {
            $0.trimDB = -1.5
            $0.polarityInverted = true
        }
        XCTAssertEqual(rig.engine.appliedStereoAlignment?.right.trimDB, -1.5)
        XCTAssertEqual(rig.engine.appliedStereoAlignment?.right.polarityInverted, true)
        record = try XCTUnwrap(rig.profiles.selectedSystemProfile?.state.calibrationRecord)
        XCTAssertNotEqual(rig.profiles.currentCalibrationStamp(), record.stamp)
        XCTAssertNotEqual(stampBefore, rig.profiles.currentCalibrationStamp())
        let rows = SpeakerFeedTable.rows(
            arrangement: rig.profiles.selectedSystemProfile?.state.systemArrangement, measured: record.measuredFeeds)
        XCTAssertEqual(rows.map(\.isManual), [false, true])

        // Reset to measured puts the right speaker back.
        try SpeakerFeedTableEditor.resetToMeasured(side: .right, engine: rig.engine, profiles: rig.profiles)
        XCTAssertEqual(rig.engine.appliedStereoAlignment?.right, SpeakerFeedCalibration())

        // Relaunch keeps the table.
        try SpeakerFeedTableEditor.edit(side: .left, engine: rig.engine, profiles: rig.profiles) { $0.delayMs = 2 }
        let relaunched = ProductProfileController(
            engine: rig.engine, storageURL: rig.root.appendingPathComponent("profiles.json"))
        XCTAssertEqual(relaunched.selectedSystemProfile?.state.systemArrangement?.stereoAlignment?.left.delayMs, 2)
        XCTAssertEqual(relaunched.selectedSystemProfile?.state.calibrationRecord?.measuredFeeds?.left, measured)
    }

    func testAnUnconfiguredSystemIsNotStampedByItsFirstEdit() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let editor = SpeakersArrangementEditorModel(engine: rig.engine, profiles: rig.profiles)
        editor.chooseBass(.fullRange)
        XCTAssertNil(rig.profiles.selectedSystemProfile?.state.calibrationRecord?.stamp)
    }

    func testArrangementChangeMarksACalibratedSystemOutOfDate() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let editor = SpeakersArrangementEditorModel(engine: rig.engine, profiles: rig.profiles)
        editor.chooseBass(.dspMonoToMains)
        rig.profiles.recordSystemVerification(designID: UUID())
        let stamp = try XCTUnwrap(rig.profiles.selectedSystemProfile?.state.calibrationRecord?.stamp)
        XCTAssertTrue(rig.profiles.currentCalibrationStamp().changes(from: stamp).isEmpty)
        editor.chooseBass(.fullRange)
        let changes = rig.profiles.currentCalibrationStamp().changes(from: stamp)
        XCTAssertTrue(changes.contains(.arrangement))
    }

    // MARK: Screen fit (AGENTS.md section 13)

    func testTableFitsTheDefaultAndSmallWindows() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let editor = SpeakersArrangementEditorModel(engine: rig.engine, profiles: rig.profiles)
        editor.chooseBass(.dspMonoToMains)
        for width in [1_280.0, 1_920.0] {
            let view = SpeakerDistancesLevelsTable(engine: rig.engine, profiles: rig.profiles)
                .frame(width: width, height: 600)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width, "table wider than the \(width) window")
        }
    }
}
