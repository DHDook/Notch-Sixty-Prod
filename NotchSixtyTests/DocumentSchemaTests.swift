import Foundation
import XCTest
@testable import NotchSixty

/// E21 S13: the `schemas/` JSON Schemas pin the persisted document formats. Fixtures (one per
/// schema version) must decode through the Codable types, re-encode to keys and types the schema
/// allows, and a freshly exported backup must conform, so a Codable change that drifts the file
/// format fails here until the schema, the version and a new fixture are updated together.
@MainActor
final class DocumentSchemaTests: XCTestCase {
    private var schemasURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schemas", isDirectory: true)
    }
    private var checker: JSONSchemaChecker { JSONSchemaChecker(schemasDirectory: schemasURL) }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: schemasURL.appendingPathComponent("fixtures/\(name)"))
    }

    private func assertConforms(_ data: Data, _ schema: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        let violations = try checker.violations(of: object, schemaFile: schema)
        XCTAssertEqual(violations, [], file: file, line: line)
    }

    private func millisEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    private func millisDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    func testRoomCorrectionProjectV2FixtureDecodesAndReencodesWithinSchema() throws {
        let data = try fixture("room-correction-project.v2.json")
        try assertConforms(data, "room-correction-project.v2.schema.json")
        let project = try JSONDecoder().decode(RoomCorrectionProject.self, from: data)
        XCTAssertEqual(project.schemaVersion, RoomCorrectionProject.currentSchemaVersion)
        XCTAssertEqual(project.measurements.count, 1)
        XCTAssertEqual(project.designs.count, 1)
        try project.validateForPersistence()
        let reencoded = try JSONEncoder().encode(project)
        try assertConforms(reencoded, "room-correction-project.v2.schema.json")
        XCTAssertEqual(try JSONDecoder().decode(RoomCorrectionProject.self, from: reencoded), project)
    }

    func testProfileSnapshotV1FixtureDecodesAndReencodesWithinSchema() throws {
        let data = try fixture("profile-snapshot.v1.json")
        try assertConforms(data, "profile-snapshot.v1.schema.json")
        let snapshot = try millisDecoder().decode(ProductProfileBackupSnapshot.self, from: data)
        XCTAssertEqual(snapshot.schemaVersion, ProductProfileBackupSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.contentPresets.count, 1)
        try assertConforms(try millisEncoder().encode(snapshot), "profile-snapshot.v1.schema.json")
    }

    func testBackupBundleV1FixtureDecodesAndReencodesWithinSchema() throws {
        let data = try fixture("backup-bundle.v1.json")
        try assertConforms(data, "backup-bundle.v1.schema.json")
        let bundle = try millisDecoder().decode(NotchSixtyBackupBundle.self, from: data)
        XCTAssertEqual(bundle.schemaVersion, NotchSixtyBackupBundle.currentSchemaVersion)
        XCTAssertEqual(bundle.roomCorrectionProjects.count, 1)
        try assertConforms(try millisEncoder().encode(bundle), "backup-bundle.v1.schema.json")
        // The checked-in fixture also passes the service's own integrity check.
        let (service, root) = makeBackupService()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNoThrow(try service.inspect(data))
    }

    func testFreshExportConformsToTheBackupSchema() throws {
        let (service, root) = makeBackupService()
        defer { try? FileManager.default.removeItem(at: root) }
        let exported = try service.exportData(
            preferences: NotchSixtyBackupPreferences(
                appearance: "light", presence: "tray", volumeStepResolution: 64, showVolumePopup: true),
            appVersion: "1.0", appBuild: "1", createdAt: Date(timeIntervalSince1970: 2_000))
        try assertConforms(exported, "backup-bundle.v1.schema.json")
    }

    func testSchemaVersionsMatchTheCodableTypesAndEachSchemaHasAFixture() throws {
        func const(_ schemaFile: String, _ path: [String]) throws -> Int? {
            var node: Any = try checker.load(schemaFile)
            for key in path { node = (node as? [String: Any])?[key] as Any }
            return ((node as? [String: Any])?["const"] as? NSNumber)?.intValue
        }
        let room = "room-correction-project.v2.schema.json"
        let profiles = "profile-snapshot.v1.schema.json"
        let backup = "backup-bundle.v1.schema.json"
        XCTAssertEqual(try const(room, ["properties", "schemaVersion"]), RoomCorrectionProject.currentSchemaVersion)
        XCTAssertEqual(try const(room, ["$defs", "sweep", "properties", "schemaVersion"]),
                       RoomCorrectionSweepSettings.currentSchemaVersion)
        XCTAssertEqual(try const(room, ["$defs", "microphone", "properties", "calibration", "properties", "schemaVersion"]),
                       RoomCorrectionMicrophoneCalibration.currentSchemaVersion)
        XCTAssertEqual(try const(profiles, ["properties", "schemaVersion"]), ProductProfileBackupSnapshot.currentSchemaVersion)
        XCTAssertEqual(try const(profiles, ["$defs", "contentPreset", "properties", "schemaVersion"]),
                       ContentPreset.currentSchemaVersion)
        XCTAssertEqual(try const(profiles, ["$defs", "contentPreset", "properties", "state", "properties", "schemaVersion"]),
                       ContentPresetState.currentSchemaVersion)
        XCTAssertEqual(try const(profiles, ["$defs", "systemProfile", "properties", "schemaVersion"]),
                       PlaybackSystemProfile.currentSchemaVersion)
        XCTAssertEqual(try const(profiles, ["$defs", "systemProfile", "properties", "state", "properties", "schemaVersion"]),
                       PlaybackSystemState.currentSchemaVersion)
        XCTAssertEqual(try const(backup, ["properties", "schemaVersion"]), NotchSixtyBackupBundle.currentSchemaVersion)
        XCTAssertEqual(try const(backup, ["properties", "preferences", "properties", "schemaVersion"]),
                       NotchSixtyBackupPreferences.currentSchemaVersion)
        XCTAssertEqual(try const(backup, ["properties", "manifest", "properties", "schemaVersion"]),
                       NotchSixtyBackupManifest.currentSchemaVersion)

        let names = try FileManager.default.contentsOfDirectory(atPath: schemasURL.path)
            .filter { $0.hasSuffix(".schema.json") }
        XCTAssertEqual(names.count, 3)
        for name in names {
            let stem = name.replacingOccurrences(of: ".schema.json", with: "")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: schemasURL.appendingPathComponent("fixtures/\(stem).json").path),
                "schema \(name) has no fixture for its version")
        }
    }

    func testCheckerRejectsDriftedDocuments() throws {
        let data = try fixture("room-correction-project.v2.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unexpectedKey"] = 1
        object["name"] = 5
        object["schemaVersion"] = 3
        object.removeValue(forKey: "designs")
        var sweep = try XCTUnwrap(object["sweep"] as? [String: Any])
        sweep["repeatCount"] = 5
        object["sweep"] = sweep
        let found = try checker.violations(of: object, schemaFile: "room-correction-project.v2.schema.json")
        XCTAssertTrue(found.contains("$: unexpected key unexpectedKey"))
        XCTAssertTrue(found.contains("$.name: expected string"))
        XCTAssertTrue(found.contains("$.schemaVersion: const mismatch"))
        XCTAssertTrue(found.contains("$: missing designs"))
        XCTAssertTrue(found.contains("$.sweep.repeatCount: not in enum"))
    }

    private func makeBackupService() -> (NotchSixtyBackupService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profiles = ProductProfileController(engine: AudioIOEngine(), storageURL: root.appendingPathComponent("p.json"))
        let service = NotchSixtyBackupService(
            profiles: profiles,
            roomStore: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("room", isDirectory: true)),
            labStore: SpeakerMeasurementLabSessionStore(rootDirectory: root.appendingPathComponent("lab", isDirectory: true)),
            binauralStore: BinauralProfileAssetStore(rootURL: root.appendingPathComponent("binaural", isDirectory: true)))
        return (service, root)
    }
}
