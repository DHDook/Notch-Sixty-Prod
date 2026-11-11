import XCTest
@testable import NotchSixty

/// E4 S32: the graduated Quiet Zone flags, end to end through production wiring. A release-style flag store (stored
/// overrides ignored) turns the flags on, `QuietZoneFlagWiring` (the code `ProductController` runs) configures the
/// engine and attaches the controllers, and nothing is armed. With a flag off by launch argument, its path is absent.
@MainActor
final class E4GraduationTests: XCTestCase {
    private static let graduated: [FeatureFlag] = [
        .ancEngineLease, .adaptiveTonalLive, .earnedCap, .feedForwardLive, .noiseSurvey, .conversationUnmasking, .overnight,
    ]
    /// No production reader yet (E4 G16, owner question): these stay dark.
    private static let dark: [FeatureFlag] = [.virtualMicrophone, .headPositionCamera, .zones]

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "E4GraduationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func release(_ arguments: [String] = []) -> FeatureFlags {
        FeatureFlags(known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly, arguments: arguments)
    }

    func testGraduatedFlagsAreOnInReleaseAndStayRegistered() {
        let store = release()
        for flag in Self.graduated {
            XCTAssertTrue(FeatureFlag.all.contains(flag), flag.id)
            XCTAssertTrue(flag.graduated, flag.id)
            XCTAssertTrue(store.isEnabled(flag), flag.id)
        }
        for flag in Self.dark {
            XCTAssertFalse(flag.graduated, flag.id)
            XCTAssertFalse(store.isEnabled(flag), flag.id)
        }
        XCTAssertFalse(store.isEnabled(.mimoTreatment))
    }

    func testEachGraduatedFlagCanBeSwitchedOffAtLaunch() {
        for flag in Self.graduated {
            XCTAssertFalse(release(["-NotchSixtyFeatures", "-\(flag.id)"]).isEnabled(flag), flag.id)
        }
    }

    func testProductionWiringWithGraduatedFlagsOnAvailableButNothingArmed() throws {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let flags = release()
        XCTAssertTrue(QuietZoneFlagWiring.configureEngine(engine, flags: flags))
        XCTAssertTrue(engine.activeQuietZoneLeaseEnabled)
        XCTAssertTrue(engine.adaptiveTonalMailboxEnabled)
        XCTAssertTrue(engine.speakerDriveFeatureEnabled)

        // The real controller graph (the same wiring `ProductController` uses), with the default flag store.
        let product = ProductController(audioEngine: AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [])))
        let quietZone = product.activeQuietZone
        // `ProductController` reads the process-wide flag store. The nightly flags-off run (FC1) switches every
        // graduated flag off through the environment, so there the same controller must leave the paths absent.
        if ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1" {
            XCTAssertNil(quietZone.adaptiveLive)
            XCTAssertNil(quietZone.noiseSurvey)
            XCTAssertNil(quietZone.earnedCap)
            XCTAssertNil(quietZone.feedForwardArming)
            XCTAssertNil(product.feedForwardArming)
            XCTAssertFalse(quietZone.arm.isArmed)
            return
        }
        XCTAssertNotNil(quietZone.adaptiveLive)
        XCTAssertNotNil(quietZone.noiseSurvey)
        XCTAssertNotNil(quietZone.earnedCap)
        XCTAssertNotNil(quietZone.feedForwardArming)
        XCTAssertNotNil(product.feedForwardArming)
        // Available, never armed: no arm, no latched state, no output, and the Quiet Zone card is not holding power.
        XCTAssertFalse(quietZone.arm.isArmed)
        XCTAssertFalse(quietZone.isHoldingOvernightPower)
        XCTAssertEqual(product.feedForwardArming?.phase, .off)
        XCTAssertFalse(product.feedForwardArming?.isRequested ?? true)
    }

    func testProductionWiringWithFlagsOffByLaunchArgumentLeavesEnginePathsShut() {
        let off = release(["-NotchSixtyFeatures", "-e4.engine-lease,-e4.adaptive-tonal-live,-e4.feedforward-live"])
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        XCTAssertFalse(QuietZoneFlagWiring.configureEngine(engine, flags: off))
        XCTAssertFalse(engine.activeQuietZoneLeaseEnabled)
        XCTAssertFalse(engine.adaptiveTonalMailboxEnabled)
        XCTAssertFalse(engine.speakerDriveFeatureEnabled)
        // The tonal canceller needs the lease: lease off alone also shuts it.
        let leaseOff = release(["-NotchSixtyFeatures", "-e4.engine-lease"])
        XCTAssertFalse(QuietZoneFlagWiring.configureEngine(engine, flags: leaseOff))
        XCTAssertFalse(engine.adaptiveTonalMailboxEnabled)
    }
}
