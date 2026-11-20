import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E33 S11b part 2 (G106): view-level tests of the real Dynamics, Equalizer and Meters pages, read and driven through
/// `HostedPage` (the AppKit controls SwiftUI hosts). Each test states the gap it closes.
@MainActor
final class E33PageGapTests: XCTestCase {
    private let flags = FeatureFlags()

    override func setUp() {
        super.setUp()
        flags.setEnabled(true, for: .eqPageEnhancements)
        flags.setEnabled(true, for: .dynamicsExtras)
    }

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    private func dynamics(_ module: ProductionDynamicsModule, _ engine: AudioIOEngine) -> HostedPage {
        HostedPage(ProductionDynamicsView(engine: engine, initialModule: module))
    }

    private func equalizer(_ engine: AudioIOEngine) -> HostedPage {
        HostedPage(ProductionEqualizerView(engine: engine, autoPreamp: EQAutoPreampController(engine: engine)))
    }

    private func meters(_ engine: AudioIOEngine) -> HostedPage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("e33-gap-\(UUID().uuidString)")
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        return HostedPage(ProductionMetersView(
            engine: engine,
            assistant: HeadroomAssistantController(engine: engine, profiles: profiles, abComparison: ContentABComparisonController(profiles: profiles))))
    }

    private func edit(_ engine: AudioIOEngine, _ change: (inout DynamicsConfiguration) -> Void) throws {
        var configuration = engine.dynamicsConfiguration
        change(&configuration)
        try engine.replaceDynamicsConfiguration(configuration)
    }

    // MARK: Harness self-checks

    func testHarnessReadsNamedFieldsAndDrivesATypedEntry() throws {
        let engine = AudioIOEngine()
        let page = dynamics(.compressor, engine)
        let names = page.controls(of: .textField).map(\.label)
        for expected in ["Threshold", "Ratio", "Knee", "Attack", "Release", "Makeup Gain"] {
            XCTAssertTrue(names.contains(expected), "\(expected) in \(names)")
        }
        let threshold = try XCTUnwrap(page.field("Threshold"))
        XCTAssertEqual(threshold.title, ParameterNumberFieldText.text(for: .compressorThresholdDB, engine.dynamicsConfiguration.compressor.thresholdDB))
        XCTAssertTrue(page.setText("-20", inField: "Threshold"))
        XCTAssertEqual(engine.dynamicsConfiguration.compressor.thresholdDB, -20, accuracy: 1e-9, "a typed value reaches the engine")
        XCTAssertEqual(try XCTUnwrap(page.field("Threshold")).title, ParameterNumberFieldText.text(for: .compressorThresholdDB, -20))
        XCTAssertTrue(page.setText("not a number", inField: "Threshold"))
        XCTAssertEqual(engine.dynamicsConfiguration.compressor.thresholdDB, -20, accuracy: 1e-9, "an unreadable entry changes nothing")
        XCTAssertEqual(try XCTUnwrap(page.field("Threshold")).title, ParameterNumberFieldText.text(for: .compressorThresholdDB, -20), "and the field shows the live value again")
    }

    // MARK: Dynamics (G63, G13, G20, G68)

    /// G63: the real Dynamics page with the flag on offers Start from and keeps its numbers; with it off the page has neither.
    func testDynamicsPageWithTheFlagOnAndOff() {
        let engine = AudioIOEngine()
        XCTAssertTrue(dynamics(.compressor, engine).has("Start from", kind: .popup))
        flags.setEnabled(false, for: .eqPageEnhancements)
        let off = dynamics(.compressor, engine)
        XCTAssertFalse(off.has("Start from", kind: .popup))
        XCTAssertNotNil(off.field("Threshold"), "the flag-off page keeps its numbers")
    }

    /// G13: the expander Lookahead row is there with the flag on, follows the engine's switch, and commits a typed time.
    func testExpanderLookaheadRowFollowsTheFlagAndTheEngine() throws {
        // The Lookahead row is one of the dynamics extras (it needs the extras engine path). With the graduated flags forced off
        // (NOTCHSIXTY_GRADUATED_FLAGS_OFF, off wins over setEnabled) the whole Extras section is absent by design (G13b).
        guard flags.isEnabled(.dynamicsExtras), flags.isEnabled(.eqPageEnhancements) else {
            let flagsOff = AudioIOEngine()
            flagsOff.unifiedGraphEnabled = true
            XCTAssertNil(dynamics(.expander, flagsOff).field("Lookahead"), "with the graduated flags off the expander has no Lookahead row")
            return
        }
        let engine = AudioIOEngine()
        engine.unifiedGraphEnabled = true
        let on = dynamics(.expander, engine)
        let field = try XCTUnwrap(on.field("Lookahead"), "Lookahead row with the flag on")
        XCTAssertFalse(field.isEnabled, "the time is unavailable while lookahead is off")
        try edit(engine) { $0.expander.enabled = true; $0.expander.lookaheadOn = true }
        let live = dynamics(.expander, engine)
        XCTAssertTrue(try XCTUnwrap(live.field("Lookahead")).isEnabled, "and available once it is on")
        XCTAssertTrue(live.setText("8", inField: "Lookahead"))
        XCTAssertEqual(engine.dynamicsConfiguration.expander.lookaheadTimeMs, 8, accuracy: 1e-9)

        engine.unifiedGraphEnabled = false
        XCTAssertFalse(try XCTUnwrap(dynamics(.expander, engine).field("Lookahead")).isEnabled, "the frozen kernel has no extras")

        engine.unifiedGraphEnabled = true
        flags.setEnabled(false, for: .eqPageEnhancements)
        XCTAssertNil(dynamics(.expander, engine).field("Lookahead"), "the flag-off expander has no Lookahead row")
    }

    /// G20: the Bands picker offers 2 to 5, a choice rebuilds the page's crossover rows, and the flag-off page stays at three bands.
    func testMultibandBandsPickerAndCrossoverRows() throws {
        let engine = AudioIOEngine()
        let page = dynamics(.multiband, engine)
        let picker = try XCTUnwrap(page.controls(of: .segmented).first { $0.items == ["2", "3", "4", "5"] })
        XCTAssertEqual(picker.value, "3")
        func crossovers() -> [String] { page.controls(of: .textField).map(\.label).filter { $0 == "Low / Mid" || $0.hasPrefix("Crossover") } }
        XCTAssertEqual(crossovers().count, 2)
        XCTAssertTrue(page.selectSegment("5"))
        XCTAssertEqual(engine.dynamicsConfiguration.multibandCompressor.bandCountValue, 5)
        XCTAssertEqual(crossovers(), ["Crossover 1", "Crossover 2", "Crossover 3", "Crossover 4"])
        XCTAssertTrue(page.selectSegment("2"))
        XCTAssertEqual(engine.dynamicsConfiguration.multibandCompressor.bandCountValue, 2)
        XCTAssertEqual(crossovers().count, 1)

        flags.setEnabled(false, for: .eqPageEnhancements)
        let off = dynamics(.multiband, AudioIOEngine())
        XCTAssertNil(off.controls(of: .segmented).first { $0.items == ["2", "3", "4", "5"] }, "no Bands picker with the flag off")
        XCTAssertEqual(off.controls(of: .textField).map(\.label).filter { $0.contains(" / ") || $0.hasPrefix("Crossover") }, ["Low / Mid", "Mid / High"])
    }

    /// G68: while Auto Release is on the limiter page drops the fixed Release row; off, it is there again.
    func testLimiterReleaseRowGivesWayToAutoRelease() throws {
        let engine = AudioIOEngine()
        XCTAssertNotNil(dynamics(.limiter, engine).field("Release"))
        try edit(engine) { $0.limiter.autoRelease = true }
        XCTAssertNil(dynamics(.limiter, engine).field("Release"), "Auto Release replaces the fixed Release row")
        XCTAssertNotNil(dynamics(.limiter, engine).field("Ceiling"))
        try edit(engine) { $0.limiter.autoRelease = nil }
        XCTAssertNotNil(dynamics(.limiter, engine).field("Release"))
        try edit(engine) { $0.limiter.autoRelease = true }
        flags.setEnabled(false, for: .eqPageEnhancements)
        XCTAssertNotNil(dynamics(.limiter, engine).field("Release"), "the flag-off page ignores Auto Release")
    }

    // MARK: Equalizer (G1, G4, G17)

    /// G1, G4, G17: the real Equalizer page, flag off and on, at the default size.
    func testEqualizerPageFlagOffAndOn() throws {
        let engine = AudioIOEngine()
        let on = equalizer(engine)
        let zoomOn = try XCTUnwrap(on.controls(of: .segmented).first { $0.items.first == "Full range" })
        XCTAssertEqual(zoomOn.items, ["Full range", "Audible", "Subsonic (5 Hz)"], "the Subsonic zoom option (G17)")
        XCTAssertTrue(on.has("Import and Export", kind: .popup), "the Import and Export menu (G4)")
        XCTAssertTrue(on.selectSegment("Subsonic (5 Hz)"))
        XCTAssertEqual(try XCTUnwrap(on.controls(of: .segmented).first { $0.items.first == "Full range" }).value, "Subsonic (5 Hz)")

        flags.setEnabled(false, for: .eqPageEnhancements)
        let off = equalizer(engine)
        XCTAssertEqual(try XCTUnwrap(off.controls(of: .segmented).first { $0.items.first == "Full range" }).items, ["Full range", "Audible"])
        XCTAssertFalse(off.has("Import and Export", kind: .popup), "G1: the flag-off page has no transfer menu")
        for name in ["Preamp", "Output"] { XCTAssertNotNil(off.field(name), "\(name) stays on the flag-off page") }
        XCTAssertEqual(off.controls(of: .segmented).first { $0.items.first == "Minimum phase" }?.items, ["Minimum phase", "Mixed phase", "Linear phase"])
    }

    // MARK: Meters (G9, G10)

    /// G9, G10: the Spectrum page offers Spectrum, RTA and Spectrogram with the flag on, and each can be chosen.
    func testSpectrumPageModeSwitch() throws {
        let engine = AudioIOEngine()
        let on = meters(engine)
        XCTAssertTrue(on.selectSegment("Spectrum"))
        let mode = try XCTUnwrap(on.controls(of: .segmented).first { $0.items == ["Spectrum", "RTA", "Spectrogram"] })
        XCTAssertEqual(mode.value, "Spectrum")
        for name in ["RTA", "Spectrogram", "Spectrum"] {
            XCTAssertTrue(on.selectSegment(name, in: ["Spectrum", "RTA", "Spectrogram"]), name)
            XCTAssertEqual(try XCTUnwrap(on.controls(of: .segmented).first { $0.items == ["Spectrum", "RTA", "Spectrogram"] }).value, name)
        }
        flags.setEnabled(false, for: .eqPageEnhancements)
        let off = meters(engine)
        XCTAssertTrue(off.selectSegment("Spectrum"))
        XCTAssertNil(off.controls(of: .segmented).first { $0.items == ["Spectrum", "RTA", "Spectrogram"] }, "no mode switch with the flag off")
    }
}

/// Mirrors the row's displayed text so a test does not hard-code number formats.
@MainActor
private enum ParameterNumberFieldText {
    static func text(for spec: DynamicsParameterSpec, _ value: Double) -> String { spec.displayText(value) }
}
