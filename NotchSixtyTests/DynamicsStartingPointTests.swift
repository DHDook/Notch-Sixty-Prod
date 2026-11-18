import XCTest
@testable import NotchSixty

/// E33 S15: starting points, the refreshed factory presets, the stacking hint and the limiter line.
@MainActor
final class DynamicsStartingPointTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func busyConfiguration() -> DynamicsConfiguration {
        var d = DynamicsConfiguration()
        d.dcOffsetFilter.enabled = true
        d.infrasonicFilter.enabled = true
        d.spectralDenoiser.enabled = true
        d.deEsser.enabled = true
        d.deHarsh.enabled = true
        d.dynamicEQ.enabled = true
        d.loudnessContour.enabled = true
        d.expander.enabled = true
        d.softClipper.enabled = true
        d.stereoWidener.enabled = true
        d.pauseGate.enabled = true
        d.oversampling = .two
        d.multibandCompressor.enabled = true
        d.gainRider.enabled = true
        d.compressor.mixPercent = 40
        return d
    }

    /// Copies the level controllers a starting point owns from `result` into `base`; what is left must equal `result`.
    private func overlayingOwned(_ result: DynamicsConfiguration, on base: DynamicsConfiguration) -> DynamicsConfiguration {
        var d = base
        d.loudnessMatch = result.loudnessMatch
        d.dialogueRelativeLeveler = result.dialogueRelativeLeveler
        d.gainRider = result.gainRider
        d.automaticHeadroom = result.automaticHeadroom
        d.compressor = result.compressor
        d.multibandCompressor = result.multibandCompressor
        d.limiter = result.limiter
        return d
    }

    func testEachStartingPointChangesOnlyTheLevelControllers() {
        let base = busyConfiguration()
        for point in DynamicsStartingPoint.allCases {
            let result = point.applying(to: base)
            XCTAssertNotEqual(result, base, point.title)
            XCTAssertEqual(overlayingOwned(result, on: base), result, "\(point.title) touched a processor it does not own")
            XCTAssertTrue(result.limiter.enabled, point.title)
            XCTAssertFalse(result.multibandCompressor.enabled, point.title)
            XCTAssertFalse(result.gainRider.enabled, point.title)
        }
    }

    func testRecipesTurnOnWhatTheyName() {
        let base = DynamicsConfiguration()
        let late = DynamicsStartingPoint.lateNight.applying(to: base)
        XCTAssertTrue(late.compressor.enabled && late.dialogueRelativeLeveler.enabled)
        XCTAssertFalse(late.loudnessMatch.enabled)
        let clear = DynamicsStartingPoint.clearDialogue.applying(to: base)
        XCTAssertTrue(clear.dialogueRelativeLeveler.enabled)
        XCTAssertGreaterThan(clear.dialogueRelativeLeveler.targetGapDB, late.dialogueRelativeLeveler.targetGapDB)
        let even = DynamicsStartingPoint.evenVolume.applying(to: base)
        XCTAssertTrue(even.loudnessMatch.enabled)
        XCTAssertFalse(even.dialogueRelativeLeveler.enabled)
        let protect = DynamicsStartingPoint.protectSpeakers.applying(to: base)
        XCTAssertTrue(protect.automaticHeadroom.enabled)
        XCTAssertFalse(protect.compressor.enabled)
        XCTAssertEqual(protect.limiter.ceilingDB, -3.0)
        XCTAssertEqual(DynamicsStartingPoint.allCases.count, 4)
    }

    func testEveryRecipePublishesAtEveryRateAndStaysUnderTheHintThreshold() throws {
        for point in DynamicsStartingPoint.allCases {
            let d = point.applying(to: busyConfiguration())
            for rate in Self.rates {
                XCTAssertNoThrow(try d.makeSnapshot(sampleRate: rate), "\(point.title) @ \(rate)")
            }
            XCTAssertLessThan(DynamicsLevelStacking.activeNames(in: d).count, DynamicsLevelStacking.hintThreshold, point.title)
        }
    }

    func testRecipesAreIdempotent() {
        for point in DynamicsStartingPoint.allCases {
            let once = point.applying(to: busyConfiguration())
            XCTAssertEqual(point.applying(to: once), once, point.title)
        }
    }

    func testStackingHintAppearsAtThreeAndNotAtTwo() {
        var d = DynamicsConfiguration()
        d.compressor.enabled = true
        d.loudnessMatch.enabled = true
        XCTAssertNil(DynamicsLevelStacking.hint(in: d))
        d.dialogueRelativeLeveler.enabled = true
        let hint = DynamicsLevelStacking.hint(in: d)
        XCTAssertNotNil(hint)
        for name in ["LUFS Match", "Dialogue leveller", "Compressor"] { XCTAssertTrue(hint?.contains(name) == true, name) }
        d.automaticHeadroom.enabled = true
        d.gainRider.enabled = true
        d.multibandCompressor.enabled = true
        XCTAssertEqual(DynamicsLevelStacking.activeNames(in: d).count, 6)
    }

    func testLimiterLineFollowsTheLimiterAndProtection() {
        XCTAssertEqual(LimiterProtectionLine.acting(limiterDB: 0, protectionDB: 0), .none)
        XCTAssertEqual(LimiterProtectionLine.acting(limiterDB: 2, protectionDB: 0), .limiter)
        XCTAssertEqual(LimiterProtectionLine.acting(limiterDB: 0, protectionDB: 1), .protection)
        XCTAssertEqual(LimiterProtectionLine.acting(limiterDB: 2, protectionDB: 1), .both)
        XCTAssertEqual(LimiterProtectionLine.acting(limiterDB: .nan, protectionDB: .infinity), .none)
        XCTAssertTrue(LimiterProtectionLine.text(limiterOn: true, running: true, acting: .limiter).contains("Acting now: the limiter"))
        XCTAssertTrue(LimiterProtectionLine.text(limiterOn: false, running: false, acting: .both).contains("limiter is off"))
        XCTAssertFalse(LimiterProtectionLine.text(limiterOn: true, running: false, acting: .both).contains("Acting now"))
    }

    // MARK: Profiles

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private var archiveURL: URL { root.appendingPathComponent("profiles.json") }

    private func makeController() -> ProductProfileController {
        ProductProfileController(engine: AudioIOEngine(), storageURL: archiveURL)
    }

    func testApplyingAStartingPointLeavesThePresetDirtyAndSaveWritesIt() throws {
        let profiles = makeController()
        let id = try XCTUnwrap(profiles.contentPresets.first { $0.name == "Reference" }?.id)
        profiles.selectContentPreset(id)
        XCTAssertFalse(profiles.selectedContentPresetIsDirty)
        let stored = try XCTUnwrap(profiles.selectedContentPreset)
        let engine = profiles.engine
        let eqBefore = engine.stereoEQConfiguration
        let gainBefore = engine.gainConfiguration

        try engine.replaceDynamicsConfiguration(DynamicsStartingPoint.lateNight.applying(to: engine.dynamicsConfiguration))
        XCTAssertTrue(profiles.selectedContentPresetIsDirty)
        XCTAssertEqual(profiles.selectedContentPreset, stored, "nothing is saved by applying")
        XCTAssertEqual(engine.stereoEQConfiguration, eqBefore)
        XCTAssertEqual(engine.gainConfiguration, gainBefore)

        profiles.overwriteSelectedContentPreset()
        XCTAssertFalse(profiles.selectedContentPresetIsDirty)
        XCTAssertTrue(profiles.selectedContentPreset?.state.dynamics.dialogueRelativeLeveler.enabled == true)
    }

    func testCinemaAndCinemaNightPublishAtEveryRate() throws {
        let presets = makeController().contentPresets
        let cinema = try XCTUnwrap(presets.first { $0.name == "Cinema" }).state.dynamics
        let night = try XCTUnwrap(presets.first { $0.name == "Cinema Night" }).state.dynamics
        XCTAssertTrue(cinema.dialogueRelativeLeveler.enabled)
        XCTAssertTrue(cinema.loudnessMatch.enabled)
        XCTAssertTrue(night.dialogueRelativeLeveler.enabled)
        XCTAssertTrue(night.compressor.enabled)
        XCTAssertNil(night.limiter.autoRelease, "flags-off publishes the fixed release")
        XCTAssertLessThan(DynamicsLevelStacking.activeNames(in: cinema).count, DynamicsLevelStacking.hintThreshold)
        for rate in Self.rates {
            XCTAssertNoThrow(try cinema.makeSnapshot(sampleRate: rate), "Cinema @ \(rate)")
            XCTAssertNoThrow(try night.makeSnapshot(sampleRate: rate), "Cinema Night @ \(rate)")
        }
        let nightPreset = try XCTUnwrap(presets.first { $0.name == "Cinema Night" })
        let cinemaPreset = try XCTUnwrap(presets.first { $0.name == "Cinema" })
        XCTAssertEqual(nightPreset.state.stereoEQ, cinemaPreset.state.stereoEQ, "Cinema Night keeps the Cinema EQ")
    }

    /// Rewrites the stored archive as an install from before this slice: old Cinema Dynamics, no Cinema Night, an edited
    /// "Edited" copy and a user copy of the old Cinema.
    private func writeOldArchive() throws {
        _ = makeController()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any])
        var presets = try XCTUnwrap(json["contentPresets"] as? [[String: Any]])
        let legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ProductProfileController.legacyCinemaDynamics()))
        var edited = legacy as? [String: Any] ?? [:]
        presets.removeAll { ($0["name"] as? String) == "Cinema Night" }
        let cinemaIndex = try XCTUnwrap(presets.firstIndex { ($0["name"] as? String) == "Cinema" })
        var cinema = presets[cinemaIndex]
        var state = try XCTUnwrap(cinema["state"] as? [String: Any])
        state["dynamics"] = legacy
        cinema["state"] = state
        presets[cinemaIndex] = cinema
        var copy = cinema
        copy["id"] = UUID().uuidString
        copy["name"] = "My Cinema"
        copy["origin"] = "user"
        presets.append(copy)
        var comp = (edited["compressor"] as? [String: Any]) ?? [:]
        comp["enabled"] = true
        edited["compressor"] = comp
        var editedState = state
        editedState["dynamics"] = edited
        var editedCopy = cinema
        editedCopy["id"] = UUID().uuidString
        editedCopy["name"] = "Edited Cinema"
        editedCopy["state"] = editedState
        presets.append(editedCopy)
        json["contentPresets"] = presets
        json.removeValue(forKey: "factoryRefreshRevision")
        try JSONSerialization.data(withJSONObject: json).write(to: archiveURL)
    }

    func testOldArchiveRefreshesCinemaOnceAndNeverRewritesUserCopies() throws {
        try writeOldArchive()
        let profiles = makeController()
        let presets = profiles.contentPresets
        let cinema = try XCTUnwrap(presets.first { $0.id == presets.first { $0.name == "Cinema" }?.id })
        XCTAssertEqual(cinema.state.dynamics, ProductProfileController.cinemaDynamics())
        XCTAssertNotNil(presets.first { $0.name == "Cinema Night" })
        let copy = try XCTUnwrap(presets.first { $0.name == "My Cinema" })
        XCTAssertEqual(copy.origin, .user)
        XCTAssertEqual(copy.state.dynamics, ProductProfileController.legacyCinemaDynamics(), "a user copy is never rewritten")
        let edited = try XCTUnwrap(presets.first { $0.name == "Edited Cinema" })
        XCTAssertTrue(edited.state.dynamics.compressor.enabled)
        XCTAssertFalse(edited.state.dynamics.dialogueRelativeLeveler.enabled)

        // Deleting Cinema Night keeps it deleted on the next launch.
        let night = try XCTUnwrap(presets.first { $0.name == "Cinema Night" })
        profiles.selectContentPreset(night.id)
        profiles.deleteSelectedContentPreset()
        XCTAssertNil(makeController().contentPresets.first { $0.name == "Cinema Night" })
    }
}
