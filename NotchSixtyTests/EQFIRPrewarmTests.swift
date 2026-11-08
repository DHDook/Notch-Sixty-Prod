import AppKit
import XCTest
@testable import NotchSixty

/// E27 S3c: the FIR design cache that makes a linear-phase A/B toggle redesign nothing (G10), and
/// the engine-level behaviour of A/B and Listen that S3b could only cover as pure logic (G11).
/// The engine runs against an offline output catalog: no transport, so nothing reaches Core Audio.
@MainActor
final class EQFIRPrewarmTests: XCTestCase {
    private func linear(_ gain: Double, f: Double = 1_000) -> StereoEQConfiguration {
        var configuration = EQRenderHarness.peakConfiguration(gainDB: gain, frequency: f)
        configuration.phaseMode = .linearPhase
        return configuration
    }

    private func design(_ marker: Float = 0) -> EQFIRDesign {
        EQFIRDesign(left: [marker], right: nil, declaredLatencyFrames: 0, designInfo: nil)
    }

    private func engine(rate: Double = 48_000) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_301, uid: "eq-prewarm-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "eq-prewarm-out")
        return engine
    }

    private func profiles(_ engine: AudioIOEngine) -> ProductProfileController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ProductProfileController(
            engine: engine, storageURL: root.appendingPathComponent("profiles.json"), autoPreampAvailable: true)
    }

    // MARK: The cache

    func testHitDesignsNothingAndKeyIgnoresBypassAndEditLane() {
        var cache = EQFIRProgramCache()
        let base = linear(3)
        let a = EQFIRProgramKey(base, sampleRate: 48_000)
        var runs = 0
        for _ in 0..<5 { _ = cache.design(for: a) { runs += 1; return design() } }
        XCTAssertEqual(runs, 1)
        var bypassed = base
        bypassed.bypassed = true
        _ = cache.design(for: EQFIRProgramKey(bypassed, sampleRate: 48_000)) { runs += 1; return design() }
        XCTAssertEqual(runs, 1, "bypass does not change the taps")
        _ = cache.design(for: EQFIRProgramKey(base, sampleRate: 96_000)) { runs += 1; return design() }
        XCTAssertEqual(runs, 2, "a different rate designs again")
        XCTAssertEqual(cache.designCount, 2)
    }

    func testProtectedPartnerSurvivesEditsToTheActiveSlot() {
        var cache = EQFIRProgramCache()
        let partner = EQFIRProgramKey(linear(-4, f: 250), sampleRate: 48_000)
        _ = cache.design(for: partner) { design(1) }
        cache.protect(partner)
        for step in 0..<20 {
            _ = cache.design(for: EQFIRProgramKey(linear(Double(step) / 4), sampleRate: 48_000)) { design(2) }
        }
        XCTAssertTrue(cache.hasDesign(partner))
        XCTAssertLessThanOrEqual(cache.count, EQFIRProgramCache.designCapacity)
        cache.protect(nil)
        for step in 0..<5 {
            _ = cache.design(for: EQFIRProgramKey(linear(30 + Double(step)), sampleRate: 48_000)) { design(3) }
        }
        XCTAssertFalse(cache.hasDesign(partner), "unprotected, the oldest design is replaced")
    }

    func testFailedDesignStoresNothing() {
        struct Failure: Error {}
        var cache = EQFIRProgramCache()
        let key = EQFIRProgramKey(linear(3), sampleRate: 48_000)
        XCTAssertThrowsError(try cache.design(for: key) { throw Failure() })
        XCTAssertFalse(cache.hasDesign(key))
        XCTAssertEqual(cache.designCount, 0)
    }

    // MARK: Engine: toggling between linear-phase slots redesigns nothing

    func testLinearPhaseToggleDesignsNothingAfterTheFirstPassAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            let controller = profiles(engine).eqComparison
            try engine.replaceStereoEQConfiguration(linear(6))
            try controller.select(.b, history: nil)
            var b = linear(6)
            b.replaceEditableBands([EQBand(type: .peaking, frequencyHz: 250, gainDB: -4, q: 1)])
            try engine.replaceStereoEQConfiguration(b)
            try controller.select(.a, history: nil)
            let afterFirstPass = engine.eqFIRDesignCount
            XCTAssertGreaterThan(afterFirstPass, 0, "rate \(rate): the partner was designed ahead")
            for _ in 0..<6 { try controller.toggle(history: nil) }
            XCTAssertEqual(engine.eqFIRDesignCount, afterFirstPass, "rate \(rate): toggles redesign nothing")
            XCTAssertEqual(controller.activeSlot, .a)
        }
    }

    func testEditingTheActiveSlotKeepsThePartnerDesigned() throws {
        let engine = try engine()
        let controller = profiles(engine).eqComparison
        try engine.replaceStereoEQConfiguration(linear(6))
        try controller.select(.b, history: nil)
        try engine.replaceStereoEQConfiguration(linear(-3, f: 300))
        try controller.select(.a, history: nil)
        let designed = engine.eqFIRDesignCount
        // A drag of B's partner A is not possible; edit the active slot A repeatedly.
        for step in 0..<10 {
            engine.prewarmEQFIRPartner(controller.slots.configuration(.b))
            try engine.replaceStereoEQConfiguration(linear(6 + Double(step) / 10))
        }
        let before = engine.eqFIRDesignCount
        engine.prewarmEQFIRPartner(controller.slots.configuration(.b))
        XCTAssertEqual(engine.eqFIRDesignCount, before, "the partner is still cached")
        XCTAssertGreaterThanOrEqual(before, designed)
    }

    func testMinimumPhaseSlotsDesignNoFIR() throws {
        let engine = try engine()
        let controller = profiles(engine).eqComparison
        try engine.replaceStereoEQConfiguration(EQRenderHarness.peakConfiguration(gainDB: 6))
        try controller.select(.b, history: nil)
        try controller.toggle(history: nil)
        XCTAssertEqual(engine.eqFIRDesignCount, 0)
    }

    // MARK: G11: audition end events

    func testAuditionNeverTouchesTheStoredEQAndEndsOnStop() throws {
        let engine = try engine()
        let controller = profiles(engine).eqAudition
        let eq = EQRenderHarness.peakConfiguration(gainDB: 6)
        try engine.replaceStereoEQConfiguration(eq)
        controller.start(band: eq.linkedBands[0])
        XCTAssertNotNil(engine.eqAudition)
        XCTAssertEqual(engine.stereoEQConfiguration, eq, "the stored EQ is not replaced")
        controller.stop()
        XCTAssertNil(engine.eqAudition)
        XCTAssertNil(controller.active)
        XCTAssertEqual(engine.stereoEQConfiguration, eq)
    }

    func testAuditionEndsAfterTheTimeLimit() async throws {
        let engine = try engine()
        let product = profiles(engine)
        let controller = product.eqAudition
        defer { withExtendedLifetime(product) {} }
        controller.maxDuration = 0.05
        let eq = EQRenderHarness.peakConfiguration(gainDB: 6)
        try engine.replaceStereoEQConfiguration(eq)
        controller.start(band: eq.linkedBands[0])
        XCTAssertNotNil(engine.eqAudition)
        XCTAssertEqual(EQAuditionOverride.maxDuration, 30, "the shipped limit is 30 s")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(engine.eqAudition)
        XCTAssertNil(controller.active)
    }

    func testAuditionEndsOnWindowClose() async throws {
        let engine = try engine()
        let product = profiles(engine)
        let controller = product.eqAudition
        defer { withExtendedLifetime(product) {} }
        let eq = EQRenderHarness.peakConfiguration(gainDB: 6)
        try engine.replaceStereoEQConfiguration(eq)
        controller.start(band: eq.linkedBands[0])
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(engine.eqAudition)
        XCTAssertNil(controller.active)
    }

    func testAuditionEndsWhenTheTransportIsTornDown() throws {
        let engine = try engine()
        let controller = profiles(engine).eqAudition
        let eq = EQRenderHarness.peakConfiguration(gainDB: 6)
        try engine.replaceStereoEQConfiguration(eq)
        controller.start(band: eq.linkedBands[0])
        XCTAssertNotNil(engine.eqAudition)
        // No device is attached, so the start fails and takes the engine's own teardown path.
        _ = try? engine.start()
        engine.stop()
        XCTAssertNil(engine.eqAudition)
        XCTAssertEqual(engine.stereoEQConfiguration, eq)
    }

    func testAuditionEndsWhenAnA_BSwitchStartsAndOnProfileLoad() throws {
        let engine = try engine()
        let product = profiles(engine)
        let eq = EQRenderHarness.peakConfiguration(gainDB: 6)
        try engine.replaceStereoEQConfiguration(eq)
        product.eqAudition.start(band: eq.linkedBands[0])
        try product.eqComparison.select(.b, history: nil)
        XCTAssertNil(engine.eqAudition, "switching slots ends Listen first")
        product.eqAudition.start(band: eq.linkedBands[0])
        try product.applyContentStateWithoutAudioUnitRack(product.captureContentState())
        XCTAssertNil(engine.eqAudition, "loading a content state ends Listen")
    }

    // MARK: G11: content A/B exclusion, both ways

    func testContentABRefusesWhileEQComparisonIsOpen() async throws {
        let engine = try engine()
        let product = profiles(engine)
        let content = ContentABComparisonController(profiles: product)
        content.capture(.a)
        content.capture(.b)
        try product.eqComparison.select(.b, history: nil)
        XCTAssertTrue(product.eqComparison.isComparing)
        await content.audition(.a)
        XCTAssertNil(content.activeSlot)
        XCTAssertEqual(content.lastErrorDescription, ContentABComparisonError.eqComparisonActive.localizedDescription)
    }

    func testEQComparisonRefusesWhileContentABIsOpen() async throws {
        let engine = try engine()
        let product = profiles(engine)
        let content = ContentABComparisonController(profiles: product)
        content.capture(.a)
        content.capture(.b)
        await content.audition(.a)
        XCTAssertNotNil(content.activeSlot, content.lastErrorDescription ?? "audition did not start")
        XCTAssertThrowsError(try product.eqComparison.select(.b, history: nil)) { error in
            XCTAssertEqual(error as? EQComparisonController.Refusal, .contentABActive)
        }
        XCTAssertFalse(product.eqComparison.isComparing)
        await content.endAudition()
        XCTAssertNoThrow(try product.eqComparison.select(.b, history: nil))
    }

    // MARK: G11: per-slot undo across a toggle

    func testEachSlotKeepsItsOwnUndoHistoryAcrossToggles() throws {
        let engine = try engine()
        let controller = profiles(engine).eqComparison
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let history = EQEditHistory(
            undoManager: undoManager,
            live: { engine.stereoEQConfiguration },
            apply: { try engine.replaceStereoEQConfiguration($0) })

        func edit(_ gain: Double) throws {
            let before = engine.stereoEQConfiguration
            var after = before
            after.replaceEditableBands([EQBand(type: .peaking, frequencyHz: 1_000, gainDB: gain, q: 1)])
            try engine.replaceStereoEQConfiguration(after)
            history.record(before: before, after: after)
        }

        try engine.replaceStereoEQConfiguration(EQRenderHarness.peakConfiguration(gainDB: 0))
        history.configure(
            undoManager: undoManager, live: { engine.stereoEQConfiguration },
            apply: { try engine.replaceStereoEQConfiguration($0) })
        try edit(2)
        try edit(5)
        XCTAssertEqual(history.undoStepCount, 2)

        try controller.select(.b, history: history)
        XCTAssertEqual(history.undoStepCount, 0, "slot B starts with its own empty history")
        try edit(-3)
        XCTAssertEqual(history.undoStepCount, 1)

        try controller.toggle(history: history)  // back to A
        XCTAssertEqual(history.undoStepCount, 2, "A's two steps came back")
        XCTAssertEqual(engine.stereoEQConfiguration.linkedBands[0].gainDB, 5, accuracy: 1e-9)
        undoManager.undo()
        XCTAssertEqual(engine.stereoEQConfiguration.linkedBands[0].gainDB, 2, accuracy: 1e-9)

        try controller.toggle(history: history)  // to B
        XCTAssertEqual(engine.stereoEQConfiguration.linkedBands[0].gainDB, -3, accuracy: 1e-9)
        XCTAssertEqual(history.undoStepCount, 1)
        undoManager.undo()
        XCTAssertEqual(engine.stereoEQConfiguration.linkedBands[0].gainDB, 5, accuracy: 1e-9, "B's undo goes back to where B began (a copy of A)")

        try controller.toggle(history: history)  // A again: its undone step is still undone
        XCTAssertEqual(engine.stereoEQConfiguration.linkedBands[0].gainDB, 2, accuracy: 1e-9)
    }
}
