import XCTest
@testable import NotchSixty

/// E15 S1: the binding table, its persistence in `profiles-v1.json` and the backup snapshot.
@MainActor
final class OutputProfileBindingsTests: XCTestCase {
    private var root: URL!
    private var storage: URL { root.appendingPathComponent("profiles-v1.json") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func controller() -> ProductProfileController {
        ProductProfileController(engine: AudioIOEngine(), storageURL: storage)
    }

    func testFreshControllerHasNoBindingsAndWritesNoBindingField() throws {
        let profiles = controller()
        XCTAssertTrue(profiles.outputBindings.isEmpty)
        profiles.saveCurrentSystemProfile(named: "A")
        let json = try String(contentsOf: storage, encoding: .utf8)
        XCTAssertFalse(json.contains("outputBindings"), "an unused table leaves the file unchanged")
    }

    func testOldFileWithoutBindingsLoadsAndRoundTripsUnchanged() throws {
        let first = controller()
        first.saveCurrentSystemProfile(named: "A")
        let before = try Data(contentsOf: storage)
        let second = controller()
        XCTAssertTrue(second.outputBindings.isEmpty)
        second.saveCurrentSystemProfile(named: "B")
        second.deleteSelectedSystemProfile()
        let after = try Data(contentsOf: storage)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("outputBindings"))
        XCTAssertFalse(String(decoding: after, as: UTF8.self).contains("outputBindings"))
    }

    func testBindingsPersistAndReload() throws {
        let profiles = controller()
        let id = profiles.saveCurrentSystemProfile(named: "Desk")
        let key = OutputKey(deviceUID: "usb-dac")
        profiles.useSelectedSystem(for: key)
        XCTAssertEqual(profiles.outputBindings.profileID(for: key), id)
        XCTAssertEqual(profiles.systemProfiles.first { $0.id == id }?.state.associatedOutputUID, "usb-dac")
        let reloaded = controller()
        XCTAssertEqual(reloaded.outputBindings.profileID(for: key), id)
    }

    func testDeletingAProfileDropsItsBindings() {
        let profiles = controller()
        let id = profiles.saveCurrentSystemProfile(named: "Desk")
        profiles.useSelectedSystem(for: OutputKey(deviceUID: "usb-dac"))
        profiles.useSelectedSystem(for: OutputKey(deviceUID: "builtin", dataSourceID: 1))
        XCTAssertEqual(profiles.outputBindings.entries.count, 2)
        XCTAssertEqual(profiles.selectedSystemProfileID, id)
        profiles.deleteSelectedSystemProfile()
        XCTAssertTrue(profiles.outputBindings.isEmpty)
        XCTAssertTrue(controller().outputBindings.isEmpty)
    }

    func testBackupSnapshotRoundTripsBindingsAndPrunesDeletedProfiles() throws {
        let profiles = controller()
        let id = profiles.saveCurrentSystemProfile(named: "Desk")
        let key = OutputKey(deviceUID: "usb-dac", dataSourceID: 7)
        profiles.useSelectedSystem(for: key)
        var snapshot = profiles.makeBackupSnapshot()
        XCTAssertEqual(snapshot.outputBindings?.profileID(for: key), id)
        let decoded = try JSONDecoder().decode(
            ProductProfileBackupSnapshot.self, from: try JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)

        let other = ProductProfileController(
            engine: AudioIOEngine(), storageURL: root.appendingPathComponent("other.json"))
        _ = try other.restoreBackupSnapshot(decoded, availableOutputUIDs: ["usb-dac"])
        XCTAssertEqual(other.outputBindings.profileID(for: key), id)

        var stale = OutputProfileBindings()
        stale.bind(key, to: UUID())
        snapshot.outputBindings = stale
        _ = try other.restoreBackupSnapshot(snapshot, availableOutputUIDs: ["usb-dac"])
        XCTAssertTrue(other.outputBindings.isEmpty)
    }

    func testOldBackupSnapshotWithoutBindingsDecodes() throws {
        let profiles = controller()
        let snapshot = profiles.makeBackupSnapshot()
        XCTAssertNil(snapshot.outputBindings)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("outputBindings"))
        XCTAssertNil(try JSONDecoder().decode(ProductProfileBackupSnapshot.self, from: data).outputBindings)
    }

    func testSeedBindsUniqueUIDsAndListsAmbiguousOnes() {
        let a = UUID(), b = UUID(), c = UUID()
        var table = OutputProfileBindings()
        let associations: [(profileID: UUID, outputUID: String?)] = [
            (a, "usb-dac"), (b, "shared"), (c, "shared"), (UUID(), nil),
        ]
        table.seed(from: associations)
        XCTAssertEqual(table.profileID(for: OutputKey(deviceUID: "usb-dac")), a)
        XCTAssertNil(table.profileID(for: OutputKey(deviceUID: "shared")))
        XCTAssertEqual(OutputProfileBindings.ambiguousUIDs(associations: associations, bindings: table), ["shared"])
        XCTAssertTrue(table.seeded)
        // The user resolves the ambiguity by binding; it no longer lists.
        table.bind(OutputKey(deviceUID: "shared"), to: b)
        XCTAssertEqual(OutputProfileBindings.ambiguousUIDs(associations: associations, bindings: table), [])
    }

    func testSeedRunsOnceAndNeverOverridesABinding() {
        let a = UUID(), b = UUID()
        var table = OutputProfileBindings()
        table.bind(OutputKey(deviceUID: "usb-dac", dataSourceID: 3), to: b)
        table.seed(from: [(profileID: a, outputUID: "usb-dac")])
        XCTAssertEqual(table.entries.count, 1)
        table.unbind(OutputKey(deviceUID: "usb-dac", dataSourceID: 3))
        table.seed(from: [(profileID: a, outputUID: "usb-dac")])
        XCTAssertTrue(table.isEmpty, "second seed is a no-op")
    }

    func testControllerSeedFromAssociationsPersists() {
        let profiles = controller()
        let id = profiles.saveCurrentSystemProfile(named: "Desk")
        // Associate through the binding path, then drop the binding so only `associatedOutputUID` remains.
        profiles.useSelectedSystem(for: OutputKey(deviceUID: "usb-dac"))
        profiles.unbindOutput(OutputKey(deviceUID: "usb-dac"))
        XCTAssertTrue(profiles.seedOutputBindingsFromAssociations().isEmpty)
        XCTAssertEqual(profiles.outputBindings.profileID(for: OutputKey(deviceUID: "usb-dac")), id)
        XCTAssertEqual(controller().outputBindings.profileID(for: OutputKey(deviceUID: "usb-dac")), id)
    }

    func testBindingsAreSeparatePerDataSourceAndFallBackToDeviceBinding() {
        let a = UUID(), b = UUID()
        var table = OutputProfileBindings()
        let speakers = OutputKey(deviceUID: "builtin", dataSourceID: 1)
        let jack = OutputKey(deviceUID: "builtin", dataSourceID: 2)
        table.bind(speakers, to: a)
        table.bind(jack, to: b)
        XCTAssertEqual(table.profileID(for: speakers), a)
        XCTAssertEqual(table.profileID(for: jack), b)
        XCTAssertNil(table.profileID(for: OutputKey(deviceUID: "builtin", dataSourceID: 3)))
        table.bind(OutputKey(deviceUID: "builtin"), to: a)
        XCTAssertEqual(table.profileID(for: OutputKey(deviceUID: "builtin", dataSourceID: 3)), a)
        XCTAssertNil(table.profileID(for: OutputKey(deviceUID: "other")))
    }
}
