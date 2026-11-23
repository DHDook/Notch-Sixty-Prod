import XCTest
@testable import NotchSixty

/// E12 S28: two-file mode (loudness match, trim, selected output device, position and loop, remembered level), the
/// saved list of finished tests (round trip, backup, export schema) and a live test that ends in History.
@MainActor
final class BlindFilesHistoryTests: XCTestCase {
    @MainActor
    final class FakeVoice: BlindFileVoice {
        var currentTime: TimeInterval = 0
        var volume: Float = 0
        var isPlaying = false
        var stopped = 0
        func play() -> Bool { isPlaying = true; return true }
        func stop() { isPlaying = false; stopped += 1 }
    }

    private func metrics(rms: Double, frames: Int64, rate: Double = 48_000) -> BlindABXFileMetrics {
        BlindABXFileMetrics(sampleRate: rate, channels: 2, frameCount: frames, rmsDBFS: rms, samplePeakDBFS: -3)
    }

    private func defaultsSuite() -> UserDefaults {
        let name = "blind-files-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    // MARK: Loudness match and trim

    func testLouderFileIsTurnedDownAndBothCutToTheShorter() {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let a = metrics(rms: -20, frames: Int64(rate * 10), rate: rate)
            let b = metrics(rms: -14, frames: Int64(rate * 7), rate: rate)
            let match = BlindFileLoudnessMatch.make(a: a, b: b)
            XCTAssertEqual(match.gainA, 1, accuracy: 1e-12)
            XCTAssertEqual(match.gainBDB, -6, accuracy: 1e-9, "the louder file is the one turned down")
            XCTAssertEqual(match.durationSeconds, 7, accuracy: 1e-9)
            // After the trim the two RMS levels agree to far inside the 0.1 dB the old page demanded.
            XCTAssertEqual(a.rmsDBFS + match.gainADB, b.rmsDBFS + match.gainBDB, accuracy: 1e-9)
        }
        let same = BlindFileLoudnessMatch.make(a: metrics(rms: -18, frames: 100), b: metrics(rms: -18, frames: 100))
        XCTAssertEqual(same.gainA, 1)
        XCTAssertEqual(same.gainB, 1)
        XCTAssertTrue(same.summary.contains("same loudness"))
    }

    func testFilesOfDifferentLoudnessAndLengthAreNoLongerRefused() {
        XCTAssertTrue(BlindABXPreflight.reasons(a: metrics(rms: -30, frames: 48_000), b: metrics(rms: -10, frames: 96_000)).isEmpty)
    }

    // MARK: Player

    private func player(durationA: Double = 12, defaults: UserDefaults? = nil) -> (BlindFilePlayer, FakeVoice, FakeVoice) {
        let a = FakeVoice(), b = FakeVoice()
        let match = BlindFileLoudnessMatch.make(a: metrics(rms: -20, frames: Int64(48_000 * durationA)), b: metrics(rms: -14, frames: 48_000 * 12))
        let store = BlindFileLevelStore(defaults: defaults ?? defaultsSuite())
        return (BlindFilePlayer(voiceA: a, voiceB: b, match: match, levelStore: store), a, b)
    }

    func testFilesPlayOnTheSelectedOutputDeviceNotTheDefault() throws {
        var seen: [String] = []
        let match = BlindFileLoudnessMatch.make(a: metrics(rms: -20, frames: 480_000), b: metrics(rms: -20, frames: 480_000))
        _ = try BlindFilePlayer.make(
            urlA: URL(fileURLWithPath: "/a.wav"), urlB: URL(fileURLWithPath: "/b.wav"), deviceUID: "dac-uid-1", match: match,
            voiceFactory: { _, uid in seen.append(uid); return FakeVoice() })
        XCTAssertEqual(seen, ["dac-uid-1", "dac-uid-1"])
    }

    func testSwitchingKeepsThePositionAndAppliesTheMatchedLevel() {
        let (p, a, b) = player()
        XCTAssertTrue(p.play(.a))
        a.currentTime = 4.5
        XCTAssertTrue(p.play(.b))
        XCTAssertEqual(b.currentTime, 4.5, accuracy: 1e-9)
        XCTAssertFalse(a.isPlaying)
        XCTAssertTrue(b.isPlaying)
        // B is the louder file: its volume is the slider level times its trim.
        XCTAssertEqual(Double(b.volume), p.level * pow(10, -6.0 / 20), accuracy: 1e-6)
        XCTAssertEqual(Double(a.volume), p.level, accuracy: 1e-6)
    }

    func testLoopReturnsToTheChosenPassageAndPlainPlayStopsAtTheShorterEnd() {
        let (p, a, _) = player()
        p.setPassage(start: 2, end: 5)
        p.loopEnabled = true
        XCTAssertTrue(p.play(.a))
        XCTAssertEqual(a.currentTime, 2, accuracy: 1e-9, "starts at the passage")
        a.currentTime = 5.01
        p.tick()
        XCTAssertEqual(a.currentTime, 2, accuracy: 1e-9)
        XCTAssertTrue(a.isPlaying)
        p.loopEnabled = false
        a.currentTime = 12.0
        p.tick()
        XCTAssertNil(p.playing)
        XCTAssertFalse(a.isPlaying)
    }

    func testPassageIsClampedToTheCommonLengthAndNeverEmpty() {
        let (p, _, _) = player(durationA: 12)
        p.setPassage(start: 20, end: 30)
        XCTAssertLessThanOrEqual(p.loopEnd, 12)
        XCTAssertGreaterThanOrEqual(p.loopEnd - p.loopStart, 0.25 - 1e-9)
        p.setPassage(start: 3, end: 3)
        XCTAssertGreaterThanOrEqual(p.loopEnd - p.loopStart, 0.25 - 1e-9)
    }

    func testLevelStartsLowIsRememberedAndNeverRaisesAboveFull() {
        let defaults = defaultsSuite()
        let (p, a, _) = player(defaults: defaults)
        XCTAssertEqual(p.level, BlindFileLevelStore.defaultLevel, accuracy: 1e-12)
        XCTAssertLessThan(p.level, 0.2, "no longer the old fixed 20% cap, and it starts low")
        _ = p.play(.a)
        p.level = 0.35
        XCTAssertEqual(Double(a.volume), 0.35, accuracy: 1e-6, "the slider acts while playing")
        let (again, _, _) = player(defaults: defaults)
        XCTAssertEqual(again.level, 0.35, accuracy: 1e-12, "remembered")
        BlindFileLevelStore(defaults: defaults).level = 7
        XCTAssertEqual(BlindFileLevelStore(defaults: defaults).level, 1)
    }

    // MARK: History

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blindhist-\(UUID().uuidString)/history.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    private func completeSession(correct: Bool = true) throws -> BlindABXSession {
        var session = try BlindABXSession(trialCount: 12, initialAssignment: false)
        for _ in 0..<12 {
            try session.recordXPlayback()
            try session.submit(correct ? false : true, nextAssignment: false)
        }
        return session
    }

    func testHistoryRoundTripNewestFirstAndCapped() throws {
        let url = tempURL()
        let store = BlindTestHistoryStore(url: url)
        let session = try completeSession()
        for index in 0..<(BlindTestHistoryStore.limit + 5) {
            let record = try XCTUnwrap(BlindTestRecords.abx(
                sideA: "A\(index)", sideB: "B", session: session, now: Date(timeIntervalSince1970: Double(index))))
            store.append(record)
        }
        XCTAssertEqual(store.records.count, BlindTestHistoryStore.limit)
        XCTAssertEqual(store.records.first?.sideA, "A\(BlindTestHistoryStore.limit + 4)")
        let reloaded = BlindTestHistoryStore(url: url)
        XCTAssertEqual(reloaded.records, store.records)
        let first = try XCTUnwrap(store.records.first)
        store.append(first)
        XCTAssertEqual(store.records.count, BlindTestHistoryStore.limit, "the same id is not added twice")
        store.clear()
        XCTAssertTrue(BlindTestHistoryStore(url: url).records.isEmpty)
    }

    func testExportHasNoInternalFieldsAndRecordsWhatWasDone() throws {
        let record = try XCTUnwrap(BlindTestRecords.abx(sideA: "Mine", sideB: "Theirs", session: try completeSession(), kind: .twoFiles))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: BlindTestRecords.exportData(record)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, BlindTestRecord.currentSchemaVersion)
        XCTAssertEqual(object["kind"] as? String, "twoFiles")
        XCTAssertEqual(object["correctCount"] as? Int, 12)
        XCTAssertEqual((object["trialsCorrect"] as? [Bool])?.count, 12)
        for banned in ["mayMergeIntoMain", "liveFeedForwardANCAuthorized", "evidenceAuthority", "realHardwareMeasured",
                       "physicalAcceptanceComplete", "releaseAcceptanceComplete"] {
            XCTAssertNil(object[banned], "\(banned) is internal")
        }
        XCTAssertTrue(record.outcome.contains("12 of 12"))
        XCTAssertNil(BlindTestRecords.abx(sideA: "a", sideB: "b", session: try BlindABXSession(trialCount: 12)), "unfinished tests are not recorded")
    }

    func testPlainWordingHasNoStatisticalJargon() throws {
        let hit = BlindTestRecords.abxOutcome(correct: 14, trials: 16, pValue: 0.002)
        let miss = BlindTestRecords.abxOutcome(correct: 9, trials: 16, pValue: 0.4)
        for text in [hit, miss, BlindTestRecords.preferenceOutcome(preferredA: 3, preferredB: 9, pValue: 0.14)] {
            XCTAssertFalse(text.lowercased().contains("exploratory"))
            XCTAssertFalse(text.lowercased().contains("hypothesis"))
        }
    }

    func testHistoryTravelsInTheBackupAndOlderBackupsStillRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func service(history: BlindTestHistoryStore?, _ name: String) -> NotchSixtyBackupService {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            return NotchSixtyBackupService(
                profiles: ProductProfileController(engine: AudioIOEngine(), storageURL: dir.appendingPathComponent("p.json")),
                roomStore: RoomCorrectionProjectStore(rootDirectory: dir.appendingPathComponent("room", isDirectory: true)),
                labStore: SpeakerMeasurementLabSessionStore(rootDirectory: dir.appendingPathComponent("lab", isDirectory: true)),
                binauralStore: BinauralProfileAssetStore(rootURL: dir.appendingPathComponent("binaural", isDirectory: true)),
                blindHistory: history)
        }
        let prefs = NotchSixtyBackupPreferences(appearance: "light", presence: "tray", volumeStepResolution: 64)
        let source = BlindTestHistoryStore(url: root.appendingPathComponent("src.json"))
        let record = try XCTUnwrap(BlindTestRecords.abx(sideA: "A", sideB: "B", session: try completeSession()))
        source.append(record)
        let data = try service(history: source, "one").exportData(preferences: prefs, appVersion: "1", appBuild: "1")
        let target = BlindTestHistoryStore(url: root.appendingPathComponent("dst.json"))
        let restorer = service(history: target, "two")
        XCTAssertEqual(try restorer.inspect(data).blindListeningHistory?.count, 1)
        _ = try restorer.restore(data)
        XCTAssertEqual(target.records.map(\.id), [record.id])

        // A backup made with no history (older app) has no such key and still restores.
        let empty = BlindTestHistoryStore(url: root.appendingPathComponent("none.json"))
        let older = try service(history: empty, "three").exportData(preferences: prefs, appVersion: "1", appBuild: "1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: older) as? [String: Any])
        XCTAssertNil(object["blindListeningHistory"])
        _ = try restorer.restore(older)
        XCTAssertEqual(target.records.count, 1, "restoring an older backup keeps the list")
    }

    // MARK: End to end

    func testLiveTestThroughTheModelEndsInHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blindE2E-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        let bands = [EQBand(enabled: true, type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1, slope: .db12)]
        let fake = BlindLiveComparisonTests.FakePlayer(current: ContentABAuditionState(
            stereoEQ: StereoEQConfiguration(channelMode: .linked, editChannel: .linked, phaseMode: .minimumPhase, bypassed: false, linkedBands: bands),
            inputPreampDB: 0, headroomAttenuationDB: 0, dynamics: DynamicsConfiguration()))
        let history = BlindTestHistoryStore(url: tempURL())
        let model = BlindLiveModel(profiles: profiles, history: history, player: fake)
        model.switchHold = 0
        model.trialCount = 12
        model.start()
        let service = try XCTUnwrap(model.service, model.error ?? "no service")
        for _ in 0..<12 {
            service.select(.x)
            service.answer(xIsB: false)
        }
        model.recordIfFinished()
        model.recordIfFinished()
        XCTAssertEqual(history.records.count, 1, "kept once")
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.sideA, "Current settings")
        XCTAssertEqual(record.sideB, "Processing off (equaliser, preamp, dynamics)")
        XCTAssertEqual(record.trialCount, 12)
        XCTAssertEqual(record.kind, .canIHearIt)
        XCTAssertEqual(model.finishedRecord, record)
        model.stop()
        XCTAssertEqual(fake.applied.last?.state, fake.current, "settings are back")
    }
}
