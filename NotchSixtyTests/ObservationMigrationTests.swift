import Observation
import XCTest
@testable import NotchSixty

/// E20 S9: `AudioIOEngine` and `RoomTreatmentAdvisorController` are `@Observable`. A change to one
/// property wakes only the readers of that property, and `ObservationSubscription` replaces the old
/// `objectWillChange` subscriptions.
@MainActor
final class ObservationMigrationTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    /// Tracks `read` once and returns how many times its onChange fired.
    private func tracker(_ read: @escaping () -> Void) -> Counter {
        let counter = Counter()
        withObservationTracking(read) { counter.value += 1 }
        return counter
    }

    func testEngineChangeInvalidatesOnlyItsReaders() throws {
        let engine = AudioIOEngine()
        let gainReader = tracker { _ = engine.gainConfiguration }
        let eqReader = tracker { _ = engine.stereoEQConfiguration }
        let routeReader = tracker { _ = engine.routeConfiguration }

        try engine.setInputPreampDB(-3)

        XCTAssertEqual(gainReader.value, 1)
        XCTAssertEqual(eqReader.value, 0)
        XCTAssertEqual(routeReader.value, 0)
        XCTAssertEqual(engine.gainConfiguration.inputPreampDB, -3)
    }

    func testAdvisorChangeInvalidatesOnlyItsReaders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("E20-S9-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let advisor = RoomTreatmentAdvisorController(
            store: RoomCorrectionProjectStore(rootDirectory: root)
        )
        let baselineReader = tracker { _ = advisor.physicalSubBaselineID }
        let candidateReader = tracker { _ = advisor.physicalSubCandidateID }

        advisor.physicalSubBaselineID = UUID()

        XCTAssertEqual(baselineReader.value, 1)
        XCTAssertEqual(candidateReader.value, 0)
    }

    func testSubscriptionFiresOnceAfterChangeAndRearms() async throws {
        let engine = AudioIOEngine()
        var fired = 0
        let subscription = ObservationSubscription(
            track: { _ = engine.gainConfiguration },
            onChange: { fired += 1 }
        )
        withExtendedLifetime(subscription) {}

        try engine.setInputPreampDB(-1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fired, 1)

        try engine.setInputPreampDB(-2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fired, 2)
    }

    func testSubscriptionIgnoresUnreadPropertiesAndCancels() async throws {
        let engine = AudioIOEngine()
        var fired = 0
        let subscription = ObservationSubscription(
            track: { _ = engine.stereoEQConfiguration },
            onChange: { fired += 1 }
        )
        try engine.setInputPreampDB(-1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fired, 0, "a gain change must not wake an EQ reader")

        subscription.cancel()
        withExtendedLifetime(subscription) {}
    }

    func testValueSubscriptionDeliversOnlyDistinctChanges() async throws {
        let engine = AudioIOEngine()
        var delivered: [Double] = []
        let subscription = ObservationSubscription(
            value: { engine.gainConfiguration.inputPreampDB },
            onChange: { delivered.append($0) }
        )
        try engine.setInputPreampDB(0)       // same value: not delivered
        try await Task.sleep(for: .milliseconds(50))
        try engine.setInputPreampDB(-4)
        try await Task.sleep(for: .milliseconds(50))
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(delivered, [-4])
    }

    func testDebouncedSubscriptionCoalescesBursts() async throws {
        let engine = AudioIOEngine()
        var fired = 0
        let subscription = ObservationSubscription(
            debounce: .milliseconds(100),
            track: { _ = engine.gainConfiguration },
            onChange: { fired += 1 }
        )
        for value in [-1.0, -2.0, -3.0] { try engine.setInputPreampDB(value) }
        try await Task.sleep(for: .milliseconds(300))
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(fired, 1)
    }
}
