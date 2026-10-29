import XCTest
@testable import NotchSixty

/// E4 S14: control-plane half of the anti-noise dead-man lease.
@MainActor
final class ActiveQuietZoneLeaseKeeperTests: XCTestCase {
    func testStartRenewsImmediatelyThenPeriodicallyAndStopReleasesOnce() async throws {
        var renewals: [Double] = []
        var releases = 0
        let keeper = ActiveQuietZoneLeaseKeeper(
            renewIntervalSeconds: 0.01,
            leaseSeconds: 3,
            renew: { renewals.append($0) },
            release: { releases += 1 }
        )
        keeper.start()
        keeper.start()
        XCTAssertEqual(renewals, [3], "the lease must exist before any anti-noise plays")
        XCTAssertTrue(keeper.isRunning)

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertGreaterThan(renewals.count, 2)
        XCTAssertTrue(renewals.allSatisfy { $0 == 3 })

        keeper.stop()
        keeper.stop()
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(keeper.isRunning)
        let count = renewals.count
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(renewals.count, count, "no renewals after stop")
    }

    func testDefaultsFitThreeMissedRenewals() {
        XCTAssertEqual(ActiveQuietZoneLeaseKeeper.leaseSeconds / ActiveQuietZoneLeaseKeeper.renewIntervalSeconds, 3)
    }

    func testLeaseFlagIsKnownAndDefaultsOff() {
        XCTAssertTrue(FeatureFlag.all.contains(.ancEngineLease))
        XCTAssertFalse(FeatureFlag.ancEngineLease.defaultEnabled)
    }
}
