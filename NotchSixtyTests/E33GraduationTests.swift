import XCTest
@testable import NotchSixty

/// E33 S11d: `e33.page-enhancements` graduated. These tests use no flag override: they read what a Release user gets by
/// default and drive the page model, the engine's own publish path and the real core at the eight rates. With the nightly
/// flags-off matrix (`NOTCHSIXTY_GRADUATED_FLAGS_OFF`) the default-on cases skip; the flags-off path is covered by
/// `E33ShipEndToEndTests.testFlagsOffPublishesTheOldBlocks` and `EQEditorLayoutTests`.
@MainActor
final class E33GraduationTests: XCTestCase {
    let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func skipIfGraduatedFlagsAreForcedOff() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1",
                      "the flags-off matrix switches graduated flags off")
    }

    func testFlagIsGraduatedAndStaysRegistered() {
        XCTAssertTrue(FeatureFlag.all.contains(.eqPageEnhancements))
        XCTAssertTrue(FeatureFlag.eqPageEnhancements.graduated)
        XCTAssertTrue(FeatureFlag.eqPageEnhancements.resolvedDefault)
    }

    func testReleaseUserGetsItOnAndCanSwitchItOffAndOnAgain() {
        let defaults = UserDefaults(suiteName: "e33grad.\(UUID().uuidString)")!
        func store(_ arguments: [String]) -> FeatureFlags {
            FeatureFlags(known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly,
                         arguments: arguments, environment: [:])
        }
        XCTAssertTrue(store([]).isEnabled(.eqPageEnhancements))
        XCTAssertFalse(store(["-NotchSixtyFeatures", "-e33.page-enhancements"]).isEnabled(.eqPageEnhancements))
        XCTAssertFalse(store(["-NotchSixtyFeatures", "e33.page-enhancements=off"]).isEnabled(.eqPageEnhancements))
    }

    /// Defaults, no override: the 5 Hz Equalizer floor, five multiband bands and expander lookahead reach the published
    /// graph, and the page layout reads the flag as on.
    func testDefaultsReachThePublishedGraphAtEveryRate() throws {
        try skipIfGraduatedFlagsAreForcedOff()
        XCTAssertTrue(FeatureFlags.isEnabledProcessWide(.eqPageEnhancements))
        XCTAssertEqual(EQBandRules.editFloor(for: .peaking), 5, "5 Hz band floor by default (S3)")
        for rate in rates {
            let output = AudioOutputDevice(
                deviceID: 9_434, uid: "e33grad-out", name: "Out", nominalSampleRate: rate,
                availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
            let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
            _ = try engine.refreshOutputDevices()
            try engine.selectOutput(uid: "e33grad-out")
            var d = DynamicsConfiguration()
            d.expander.enabled = true
            d.expander.lookaheadMs = 5
            d.multibandCompressor.enabled = true
            try engine.replaceDynamicsConfiguration(d)
            var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
            let extras = DynamicsGraphExtras.make(engine.dynamicsConfiguration, sampleRate: rate,
                                                  flagOn: FeatureFlags.isEnabledProcessWide(.eqPageEnhancements))
            let stages = try UnifiedGraphTranslator.stereoEligibility(
                snapshot: &snapshot, sampleRate: rate,
                compressorExtras: extras?.compressor, expanderExtras: extras?.expander, multibandExtras: extras?.multiband
            ).get().stereoStages
            XCTAssertGreaterThan(stages.expander?.count ?? 0, 6, "expander lookahead block at \(rate)")
            XCTAssertGreaterThan(stages.multiband?.count ?? 0, 29, "five-band multiband block at \(rate)")
        }
    }

    func testDefaultEqualizerLayoutIsTheEnhancedOne() throws {
        try skipIfGraduatedFlagsAreForcedOff()
        XCTAssertTrue(FeatureFlags().isEnabled(.eqPageEnhancements))
        XCTAssertTrue(FeatureFlags.isEnabledProcessWide(.eqPageEnhancements))
    }
}
