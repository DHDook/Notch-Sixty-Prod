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
