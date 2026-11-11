import XCTest
@testable import NotchSixty

@MainActor
final class FeatureFlagsTests: XCTestCase {
    private let draft = FeatureFlag(id: "unifiedGraph", title: "Unified graph", epic: "E6")
    private let onByDefault = FeatureFlag(id: "polish", title: "Polish", epic: "E5", defaultEnabled: true)
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "FeatureFlagsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func flags(
        _ policy: FeatureFlags.OverridePolicy,
        arguments: [String] = []
    ) -> FeatureFlags {
        FeatureFlags(known: [draft, onByDefault], defaults: defaults, policy: policy, arguments: arguments)
    }

    func testFlagsUseTheirCompiledDefaultsWithoutOverrides() {
        for policy in [FeatureFlags.OverridePolicy.storedOverrides, .launchArgumentOnly] {
            let store = flags(policy)
            XCTAssertFalse(store.isEnabled(draft))
            XCTAssertTrue(store.isEnabled(onByDefault))
        }
    }

    /// E26 S7 (owner decision): the sub-aware Quiet Zone flag is on in a release-style configuration (stored overrides
    /// ignored, no launch argument), even with a stored "off" override, and the live ANC flags stay off.
    func testSubAwareAncResolvesOnInAReleaseConfiguration() {
        defaults.set(false, forKey: FeatureFlags.key(for: .subAwareAnc))
        let release = FeatureFlags(known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly, arguments: [])
        XCTAssertTrue(release.isEnabled(.subAwareAnc))
        XCTAssertFalse(release.isEnabled(.mimoTreatment))
    }

    func testDebugOverridesPersistAndReset() {
        flags(.storedOverrides).setEnabled(true, for: draft)
        flags(.storedOverrides).setEnabled(false, for: onByDefault)
        XCTAssertEqual(defaults.object(forKey: "feature.unifiedGraph") as? Bool, true)

        let reopened = flags(.storedOverrides)
        XCTAssertTrue(reopened.isEnabled(draft), "override survives a relaunch")
        XCTAssertFalse(reopened.isEnabled(onByDefault))

        reopened.resetOverrides()
        XCTAssertFalse(reopened.isEnabled(draft))
        XCTAssertTrue(reopened.isEnabled(onByDefault))
    }

    func testReleaseIgnoresStoredOverridesAndCannotWriteThem() {
        defaults.set(true, forKey: "feature.unifiedGraph")
        let release = flags(.launchArgumentOnly)
        XCTAssertFalse(release.canEditOverrides)
        XCTAssertFalse(release.isEnabled(draft), "a stored override must not reach a shipped build")

        defaults.removeObject(forKey: "feature.unifiedGraph")
        release.setEnabled(true, for: draft)
        XCTAssertNil(defaults.object(forKey: "feature.unifiedGraph"))
    }

    func testLaunchArgumentEnablesFlagsInEveryBuild() {
        let arguments = ["Notch Sixty", "-NotchSixtyFeatures", " unifiedGraph , other "]
        for policy in [FeatureFlags.OverridePolicy.storedOverrides, .launchArgumentOnly] {
            let store = flags(policy, arguments: arguments)
            XCTAssertTrue(store.isEnabled(draft))
            XCTAssertTrue(store.isForcedByLaunchArgument(draft))
            XCTAssertFalse(store.isForcedByLaunchArgument(onByDefault))
        }
        // A trailing flag with no value is ignored rather than crashing.
        XCTAssertFalse(flags(.launchArgumentOnly, arguments: ["-NotchSixtyFeatures"]).isEnabled(draft))
    }

    // Flag graduation (owner decision, 11 Nov 2026).
    private let graduatedFlag = FeatureFlag(id: "grad", title: "Graduated", epic: "E5", graduated: true)

    private func gradStore(_ policy: FeatureFlags.OverridePolicy, arguments: [String] = []) -> FeatureFlags {
        FeatureFlags(known: [draft, graduatedFlag], defaults: defaults, policy: policy, arguments: arguments)
    }

    func testGraduatedFlagDefaultsOnInReleaseAndDebug() {
        XCTAssertTrue(gradStore(.launchArgumentOnly).isEnabled(graduatedFlag))
        XCTAssertTrue(gradStore(.storedOverrides).isEnabled(graduatedFlag))
        XCTAssertFalse(gradStore(.launchArgumentOnly).isEnabled(draft), "a dark flag stays off")
    }

    func testReleaseUserCanTurnAGraduatedFeatureOffWithEitherSyntax() {
        for value in ["-grad", "grad=off", " -grad , unifiedGraph", "grad=OFF"] {
            let store = gradStore(.launchArgumentOnly, arguments: ["App", "-NotchSixtyFeatures", value])
            XCTAssertFalse(store.isEnabled(graduatedFlag), value)
            XCTAssertTrue(store.isForcedByLaunchArgument(graduatedFlag), value)
        }
        let on = gradStore(.launchArgumentOnly, arguments: ["App", "-NotchSixtyFeatures", "unifiedGraph=on,-grad"])
        XCTAssertTrue(on.isEnabled(draft))
        XCTAssertFalse(on.isEnabled(graduatedFlag))
    }

    func testExplicitOffBeatsOnAndStoredOverrides() {
        let both = gradStore(.launchArgumentOnly, arguments: ["-NotchSixtyFeatures", "grad,-grad"])
        XCTAssertFalse(both.isEnabled(graduatedFlag), "off wins when an id is both on and off")
        defaults.set(true, forKey: "feature.grad")
        defaults.set(false, forKey: "feature.unifiedGraph")
        let debug = gradStore(.storedOverrides, arguments: ["-NotchSixtyFeatures", "-grad,unifiedGraph"])
        XCTAssertFalse(debug.isEnabled(graduatedFlag), "launch off beats a stored on")
        XCTAssertTrue(debug.isEnabled(draft), "launch on beats a stored off")
    }

    func testReleaseIgnoresStoredOffForAGraduatedFlagButDebugHonoursIt() {
        defaults.set(false, forKey: "feature.grad")
        XCTAssertTrue(gradStore(.launchArgumentOnly).isEnabled(graduatedFlag))
        XCTAssertFalse(gradStore(.storedOverrides).isEnabled(graduatedFlag))
    }

    func testMalformedLaunchEntriesAreIgnored() {
        let parsed = FeatureFlags.launchSwitches(in: ["-NotchSixtyFeatures", "-, =off,a=maybe,,b=on,-c"])
        XCTAssertEqual(parsed.on, ["b"])
        XCTAssertEqual(parsed.off, ["c"])
        XCTAssertFalse(gradStore(.launchArgumentOnly, arguments: ["-NotchSixtyFeatures", "-nosuch"]).isEnabled(draft))
    }

    /// Graduation means available, never armed (E4 S32 graduates the four live ANC output flags; `E4GraduationTests`
    /// pins that nothing arms). Live MIMO room treatment never graduates.
    func testLiveMIMOFlagNeverGraduates() {
        for flag in [FeatureFlag.mimoTreatment] {
            XCTAssertFalse(flag.graduated, flag.id)
            XCTAssertFalse(flag.resolvedDefault, flag.id)
        }
    }

    func testUnknownFlagsAreAlwaysOff() {
        let retired = FeatureFlag(id: "retired", title: "Retired", epic: "E0", defaultEnabled: true)
        defaults.set(true, forKey: "feature.retired")
        let store = flags(.storedOverrides, arguments: ["-NotchSixtyFeatures", "retired"])
        XCTAssertFalse(store.isEnabled(retired))
        store.setEnabled(true, for: retired)
        XCTAssertFalse(store.isEnabled(retired))
    }

    func testRegisteredFlagsHaveUniqueIDsAndOwners() {
        let ids = FeatureFlag.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for flag in FeatureFlag.all {
            XCTAssertFalse(flag.id.isEmpty)
            XCTAssertFalse(flag.id.contains(","), "ids are comma-separated on the command line")
            XCTAssertTrue(flag.epic.hasPrefix("E"), "\(flag.id) names its owning epic")
        }
    }

    /// E6 S11: the graph is the default renderer; only the frozen-fallback flag selects the kernel.
    func testGraphIsDefaultAndLegacyKernelFlagSelectsFallback() {
        XCTAssertTrue(FeatureFlag.all.contains(.legacyKernel))
        XCTAssertEqual(FeatureFlag.legacyKernel.id, "e6.legacy-kernel")
        let plain = FeatureFlags(known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly, arguments: [])
        XCTAssertFalse(plain.isEnabled(.legacyKernel), "graph renders by default")
        let fallback = FeatureFlags(
            known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly,
            arguments: ["Notch Sixty", "-NotchSixtyFeatures", "e6.legacy-kernel"])
        XCTAssertTrue(fallback.isEnabled(.legacyKernel))
        XCTAssertEqual(
            UnifiedGraphConfiguration(sampleRate: 48_000, lanes: [UnifiedGraphLane(), UnifiedGraphLane()]).orderPolicy,
            .canonical)
    }

    // These strings are persisted on users' Macs; renaming one silently resets
    // that setting.
    func testPersistedPreferenceKeysNeverChange() {
        XCTAssertEqual(PreferenceKeys.Application.appearance, "application.appearance")
        XCTAssertEqual(PreferenceKeys.Application.presence, "application.presence")
        XCTAssertEqual(PreferenceKeys.Application.volumeStepResolution, "application.volumeStepResolution")
        XCTAssertEqual(PreferenceKeys.Application.showVolumeInMenuBar, "application.showVolumeInMenuBar")
        XCTAssertEqual(PreferenceKeys.Application.showVolumePopup, "application.showVolumePopup")
        XCTAssertEqual(PreferenceKeys.Application.volumePopupPosition, "application.volumePopupPosition")
        XCTAssertEqual(PreferenceKeys.Application.coverSystemVolumePopup, "application.coverSystemVolumePopup")
        XCTAssertEqual(PreferenceKeys.abComparisonEnabled, "toolbar.abComparisonEnabled")
        XCTAssertEqual(ProductionProfileToolbarPolicy.abComparisonEnabledKey, "toolbar.abComparisonEnabled")
        XCTAssertEqual(PreferenceKeys.vuMetersEnabled, "production.vuMetersEnabled")
        XCTAssertEqual(PreferenceKeys.quietZoneMeasuredLatency, "quietZone.measuredLatency")
        XCTAssertEqual(PreferenceKeys.featureFlagPrefix, "feature.")
    }
}

/// E28 S7a: compressor extras config and translator inputs.
final class CompressorExtrasConfigTests: XCTestCase {
    func testDefaultsGiveNoExtrasAndOldProfilesDecode() throws {
        var c = CompressorConfiguration()
        XCTAssertEqual(c.coreExtras(sampleRate: 48_000), [100, 100, 0, 50, 0, 0])
        let json = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(CompressorConfiguration.self, from: json)
        XCTAssertEqual(back, c)
        c.mixPercent = 50; c.linkPercent = 0; c.rmsDetector = true; c.lookaheadMs = 5
        XCTAssertEqual(c.coreExtras(sampleRate: 96_000), [50, 0, 1, 50, 480, 0])
    }

    func testLookaheadFramesClampAndValidation() {
        XCTAssertEqual(CompressorConfiguration.lookaheadFrames(ms: 20, sampleRate: 384_000), 7_680)
        XCTAssertEqual(CompressorConfiguration.lookaheadFrames(ms: 1_000, sampleRate: 384_000), 8_192)
        XCTAssertEqual(CompressorConfiguration.lookaheadFrames(ms: 0, sampleRate: 48_000), 0)
        var c = CompressorConfiguration()
        c.mixPercent = 101
        XCTAssertThrowsError(try c.validate())
        c.mixPercent = 50; c.lookaheadMs = 25
        XCTAssertThrowsError(try c.validate())
    }

    @MainActor func testFlagRegisteredAndOff() {
        XCTAssertTrue(FeatureFlag.all.contains(.dynamicsExtras))
        XCTAssertTrue(FeatureFlag.all.contains(.roomModel))
    }
}
