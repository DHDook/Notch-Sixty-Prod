import XCTest
@testable import NotchSixty

/// E13 S10 (`e13.headphones-page`): the list of headphones in a Playback System.
@MainActor
final class HeadphoneListTests: XCTestCase {
    private let flags = FeatureFlags()

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    private var storageURL = URL(fileURLWithPath: "/dev/null")

    private func makeProfiles() -> ProductProfileController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        storageURL = root.appendingPathComponent("profiles.json")
        return ProductProfileController(engine: AudioIOEngine(), storageURL: storageURL)
    }

    private func reload(_ profiles: ProductProfileController) -> ProductProfileController {
        ProductProfileController(engine: AudioIOEngine(), storageURL: storageURL)
    }

    private func saved(name: String, trim: Double = 0) -> HeadphoneDeviceProfileConfiguration {
        var p = HeadphoneDeviceProfileConfiguration()
        p.name = name
        p.headroomAttenuationDB = 6
        p.left.gainDB = trim
        return p
    }

    func testSchemaRoundTripAndOlderStateHasNoList() throws {
        var list = HeadphoneList()
        let a = try list.add(name: "Studio", enabled: false, outputDeviceUID: "dac")
        try list.link(a, toOutputUID: "dac")
        list.selectedID = a
        let state = PlaybackSystemState(headphoneDeviceProfile: list.selected?.profile, headphoneList: list)
        let back = try JSONDecoder().decode(PlaybackSystemState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
        // A state saved before the list existed decodes with no list and encodes without the key.
        let old = PlaybackSystemState(headphoneDeviceProfile: saved(name: "Old"))
        let json = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("headphoneList"))
        XCTAssertNil(try JSONDecoder().decode(PlaybackSystemState.self, from: json).headphoneList)
    }

    func testMigrationMakesTodaysProfileTheFirstEntry() throws {
        let profiles = makeProfiles()
        let profile = saved(name: "My Pair", trim: -2)
        // Saved before S10 (flag off): a profile and no list.
        try profiles.replaceSelectedSystemHeadphoneDeviceProfile(profile)
        XCTAssertNil(profiles.selectedSystemHeadphoneList)
        flags.setEnabled(true, for: .headphonesPage)
        profiles.ensureSelectedSystemHeadphoneList()
        let list = try XCTUnwrap(profiles.selectedSystemHeadphoneList)
        XCTAssertEqual(list.entries.count, 1)
        XCTAssertEqual(list.selected?.name, "My Pair")
        XCTAssertEqual(list.selected?.profile, profile)
        profiles.ensureSelectedSystemHeadphoneList()
        XCTAssertEqual(profiles.selectedSystemHeadphoneList, list, "idempotent")
        XCTAssertEqual(reload(profiles).selectedSystemHeadphoneList, list, "persisted")
    }

    func testFlagOffNeverMakesAList() throws {
        let profiles = makeProfiles()
        try profiles.replaceSelectedSystemHeadphoneDeviceProfile(saved(name: "Pair"))
        profiles.ensureSelectedSystemHeadphoneList()
        XCTAssertNil(profiles.selectedSystemHeadphoneList)
    }

    func testAddDuplicateRenameDelete() throws {
        var list = HeadphoneList()
        let a = try list.add(name: "Cans", enabled: true, outputDeviceUID: nil)
        try list.select(a)
        XCTAssertTrue(list.selected?.profile.enabled == true)
        let b = try list.duplicate(a)
        XCTAssertEqual(list.entries.map(\.name), ["Cans", "Cans copy"])
        XCTAssertEqual(list.entries[1].profile.name, "Cans copy")
        XCTAssertEqual(list.add_unique("Cans"), "Cans 2")
        try list.rename(b, to: "  Buds ")
        XCTAssertEqual(list.entries[1].name, "Buds")
        XCTAssertEqual(list.entries[1].profile.name, "Buds")
        XCTAssertThrowsError(try list.rename(b, to: "  ")) { XCTAssertEqual($0 as? HeadphoneListError, .emptyName) }
        try list.select(b)
        try list.delete(b)
        XCTAssertEqual(list.selectedID, a, "selection moves to a neighbour")
        try list.delete(a)
        XCTAssertTrue(list.entries.isEmpty)
        XCTAssertNil(list.selectedID)
        XCTAssertThrowsError(try list.delete(a)) { XCTAssertEqual($0 as? HeadphoneListError, .unknownEntry) }
    }

    func testSwitchingEntriesPublishesTheRightProfileToTheEngine() throws {
        flags.setEnabled(true, for: .headphonesPage)
        let profiles = makeProfiles()
        let engine = profiles.engine
        try profiles.replaceSelectedSystemHeadphoneDeviceProfile(saved(name: "A", trim: -1))
        var secondID: UUID?
        try profiles.editSelectedSystemHeadphoneList { list in
            let id = try list.add(name: "B", enabled: false, outputDeviceUID: nil)
            list.entries[list.entries.count - 1].profile.left.gainDB = -4
            secondID = id
        }
        XCTAssertEqual(profiles.selectedSystemHeadphoneList?.selected?.name, "A", "adding does not switch")
        XCTAssertEqual(engine.headphoneDeviceProfileConfiguration?.left.gainDB, -1)
        try profiles.editSelectedSystemHeadphoneList { try $0.select(try XCTUnwrap(secondID)) }
        XCTAssertEqual(engine.headphoneDeviceProfileConfiguration?.name, "B")
        XCTAssertEqual(engine.headphoneDeviceProfileConfiguration?.left.gainDB, -4)
        XCTAssertEqual(profiles.selectedSystemHeadphoneDeviceProfile, engine.headphoneDeviceProfileConfiguration)
        // Editing the active pair changes only its own entry.
        var edited = try XCTUnwrap(profiles.selectedSystemHeadphoneDeviceProfile)
        edited.left.gainDB = -5
        try profiles.replaceSelectedSystemHeadphoneDeviceProfile(edited)
        let list = try XCTUnwrap(profiles.selectedSystemHeadphoneList)
        XCTAssertEqual(list.entries[0].profile.left.gainDB, -1)
        XCTAssertEqual(list.entries[1].profile.left.gainDB, -5)
        XCTAssertEqual(reload(profiles).selectedSystemHeadphoneList, list)
    }

    func testSwitchKeepsTheListenersModeAndDeletingTheLastClearsTheEngine() throws {
        flags.setEnabled(true, for: .headphonesPage)
        let profiles = makeProfiles()
        var on = saved(name: "A")
        on.enabled = true
        try profiles.replaceSelectedSystemHeadphoneDeviceProfile(on)
        try profiles.editSelectedSystemHeadphoneList { list in
            try list.select(try list.add(name: "B", enabled: false, outputDeviceUID: nil))
        }
        XCTAssertEqual(profiles.selectedSystemHeadphoneDeviceProfile?.name, "B")
        XCTAssertTrue(profiles.selectedSystemHeadphoneDeviceProfile?.enabled == true, "correction stays on")
        try profiles.editSelectedSystemHeadphoneList { list in
            for e in list.entries { try list.delete(e.id) }
        }
        XCTAssertNil(profiles.selectedSystemHeadphoneDeviceProfile)
        XCTAssertNil(profiles.engine.headphoneDeviceProfileConfiguration)
    }

    func testLinkedDeviceSelectsItsEntryAndAFailedEditRollsBack() throws {
        var list = HeadphoneList()
        let a = try list.add(name: "A", enabled: false, outputDeviceUID: nil)
        let b = try list.add(name: "B", enabled: false, outputDeviceUID: nil)
        try list.link(a, toOutputUID: "usb")
        XCTAssertEqual(list.entry(linkedTo: "usb")?.id, a)
        try list.link(b, toOutputUID: "usb")
        XCTAssertEqual(list.entry(linkedTo: "usb")?.id, b, "a device links to one pair")
        XCTAssertNil(list.entries[0].linkedOutputUID)
        XCTAssertNil(list.entry(linkedTo: "dac"), "a wired pair on a DAC is picked by hand")

        flags.setEnabled(true, for: .headphonesPage)
        let profiles = makeProfiles()
        try profiles.replaceSelectedSystemHeadphoneDeviceProfile(saved(name: "A"))
        let before = profiles.selectedSystemHeadphoneList
        XCTAssertThrowsError(try profiles.editSelectedSystemHeadphoneList { _ = try $0.duplicate(UUID()) })
        XCTAssertEqual(profiles.selectedSystemHeadphoneList, before)
    }
}

private extension HeadphoneList {
    func add_unique(_ base: String) -> String { uniqueName(base) }
}
