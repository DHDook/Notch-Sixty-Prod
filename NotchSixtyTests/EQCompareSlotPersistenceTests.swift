import XCTest
@testable import NotchSixty

/// E33 S18 (G38, G34): compare slot B survives a relaunch with the working state, a preset switch while B differs from A
/// asks for a slot, and a legacy import skips a FIR band with a warning.
@MainActor
final class EQCompareSlotPersistenceTests: XCTestCase {
    private func engine() throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_435, uid: "cmp-out", name: "Out", nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "cmp-out")
        return engine
    }

    private func controller(_ engine: AudioIOEngine, root: URL, flag: Bool = true) -> ProductProfileController {
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        profiles.eqEnhancementsEnabled = { flag }
        return profiles
    }

    private func root() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func eq(_ gain: Double) -> StereoEQConfiguration { EQRenderHarness.peakConfiguration(gainDB: gain) }

    func testSlotBSurvivesARelaunchAndTheSwitchPromptReturnsTheChosenSlot() throws {
        let root = root()
        let first = controller(try engine(), root: root)
        first.restoreSelectedLayers()
        try first.engine.replaceStereoEQConfiguration(eq(6))
        try first.eqComparison.select(.b, history: nil)
        try first.engine.replaceStereoEQConfiguration(eq(-5))
        first.eqComparison.liveChanged()
        first.recordWorkingContentStateIfNeeded()
        XCTAssertTrue(first.eqComparison.needsSlotChoice)

        // Relaunch: a fresh engine and controller over the same storage.
        let second = controller(try engine(), root: root)
        second.restoreSelectedLayers()
        XCTAssertTrue(second.eqComparison.isComparing)
        XCTAssertEqual(second.eqComparison.activeSlot, .b)
        XCTAssertEqual(second.engine.stereoEQConfiguration.linkedBands.map(\.gainDB), eq(-5).linkedBands.map(\.gainDB))
        XCTAssertEqual(second.eqComparison.slots.configuration(.a).linkedBands.map(\.gainDB), eq(6).linkedBands.map(\.gainDB))

        // A switch with B different from A needs a choice, and nothing changes until one is made.
        XCTAssertThrowsError(try second.resolveEQSlotsBeforePresetSwitch(keeping: nil)) {
            XCTAssertEqual($0 as? EQSlotChoiceError, .choiceRequired)
        }
        XCTAssertTrue(second.eqComparison.isComparing)
        try second.resolveEQSlotsBeforePresetSwitch(keeping: .a)
        XCTAssertFalse(second.eqComparison.isComparing)
        XCTAssertEqual(second.engine.stereoEQConfiguration.linkedBands.map(\.gainDB), eq(6).linkedBands.map(\.gainDB), "Keep A makes A the live EQ")

        // Ending the comparison drops the saved slot: a third launch is not comparing.
        let third = controller(try engine(), root: root)
        third.restoreSelectedLayers()
        XCTAssertFalse(third.eqComparison.isComparing)
    }

    func testFlagOffKeepsNothingAndNeverPrompts() throws {
        let root = root()
        let first = controller(try engine(), root: root, flag: false)
        first.restoreSelectedLayers()
        try first.engine.replaceStereoEQConfiguration(eq(6))
        try first.eqComparison.select(.b, history: nil)
        try first.engine.replaceStereoEQConfiguration(eq(-5))
        first.eqComparison.liveChanged()
        XCTAssertNoThrow(try first.resolveEQSlotsBeforePresetSwitch(keeping: nil))
        let second = controller(try engine(), root: root, flag: false)
        second.restoreSelectedLayers()
        XCTAssertFalse(second.eqComparison.isComparing)
    }

    func testLegacyImportSkipsAFIRBandWithAWarning() throws {
        let legacy: [String: Any] = [
            "version": 2,
            "name": "Has FIR",
            "bands": [
                ["filterType": 0, "frequency": 400.0, "gain": -2.0, "q": 1.2],
                ["filterType": 8, "frequency": 1_000.0, "gain": 0.0, "q": 1.0],
                ["filterType": "fir", "frequency": 2_000.0, "gain": 0.0, "q": 1.0],
            ],
        ]
        let imported = try PresetInterchange.importPreset(
            data: try JSONSerialization.data(withJSONObject: legacy), fileName: "Has FIR.eqpreset",
            baseStereo: StereoEQConfiguration())
        XCTAssertEqual(imported.stereoEQ.linkedBands.count, 1)
        XCTAssertFalse(imported.stereoEQ.linkedBands.contains { $0.type == .fir })
        XCTAssertEqual(imported.warnings.filter { $0.contains("FIR band") && $0.contains("skipped") }.count, 2)
        XCTAssertFalse(EQFilterPickerModel.sections.flatMap(\.types).contains(.fir))
    }
}
