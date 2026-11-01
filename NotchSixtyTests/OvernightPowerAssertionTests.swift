import XCTest
@testable import NotchSixty

@MainActor
final class OvernightPowerAssertionTests: XCTestCase {
    private final class Fake: PowerAssertionBackend {
        var live: Set<UInt32> = []
        var created = 0
        var refuse = false
        func create(reason: String) -> UInt32? {
            if refuse { return nil }
            created += 1
            live.insert(UInt32(created))
            return UInt32(created)
        }
        func release(_ id: UInt32) { live.remove(id) }
    }

    func testTakenOnceWhileWantedAndReleasedOnDisarm() {
        let fake = Fake()
        let a = OvernightPowerAssertion(backend: fake)
        XCTAssertFalse(a.update(wanted: false))
        XCTAssertTrue(a.update(wanted: true))
        XCTAssertTrue(a.update(wanted: true))
        XCTAssertEqual(fake.created, 1)
        XCTAssertFalse(a.update(wanted: false))
        XCTAssertTrue(fake.live.isEmpty)
    }

    func testRefusalLeavesNothingHeldAndRetriesLater() {
        let fake = Fake()
        fake.refuse = true
        let a = OvernightPowerAssertion(backend: fake)
        XCTAssertFalse(a.update(wanted: true))
        fake.refuse = false
        XCTAssertTrue(a.update(wanted: true))
    }

    func testTeardownReleases() {
        let fake = Fake()
        var a: OvernightPowerAssertion? = OvernightPowerAssertion(backend: fake)
        a?.update(wanted: true)
        XCTAssertEqual(fake.live.count, 1)
        a = nil
        XCTAssertTrue(fake.live.isEmpty)
    }

    func testRealBackendRoundTrip() {
        let a = OvernightPowerAssertion()
        XCTAssertTrue(a.update(wanted: true))
        a.release()
        XCTAssertFalse(a.isHeld)
    }
}
