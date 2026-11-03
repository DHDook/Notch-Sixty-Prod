import XCTest
@testable import NotchSixty

/// A recording stand-in for the engine's ABX boundary. No Core Audio session runs offline.
@MainActor
final class FakeABXPlayer: RoomCorrectionABXPlaying {
    var unavailableReason: String?
    var isSwitching = false
    var failNextPlay = false
    private(set) var played: [RoomCorrectionABXOverride] = []
    private(set) var restoreCount = 0

    func play(_ override: RoomCorrectionABXOverride) throws {
        if failNextPlay { failNextPlay = false; throw RoomCorrectionABXError.unavailable("switch failed") }
        played.append(override)
    }

    func restoreApplied() throws { restoreCount += 1 }
}

/// E24 S9: lane-plan matching, the engine override, the controller and the schema 2 log.
@MainActor
final class RoomCorrectionABXWiringTests: XCTestCase {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func grid(_ db: Double, below: Double = 1_000) throws -> RoomCorrectionGridDesign {
        let frequencies = try RoomCorrectionCore.gridFrequencies()
        return RoomCorrectionGridDesign(
            correctionDB: frequencies.map { $0 < below ? db : 0 },
            correctionPhaseRadians: [Double](repeating: 0, count: frequencies.count),
            coherence: [Double](repeating: 0, count: frequencies.count), seatContribution: [])
    }

    private func install(
        mode: RoomCorrectionLatencyMode, db: Double, name: String, subs: Int = 1, laneBDB: Double? = nil
    ) throws -> RoomCorrectionLaneInstall {
        let design = RoomCorrectionMultiLaneDesign(
            latencyMode: mode, laneCount: 2 + subs,
            lanes: [RoomCorrectionLaneDesign(lane: 0, grid: try grid(db)),
                    RoomCorrectionLaneDesign(lane: 1, grid: try grid(laneBDB ?? db))])
        return RoomCorrectionLaneInstall(
            name: name, design: design, laneDelays: [RoomCorrectionLaneDelay(lane: 1, seconds: 0.001)],
            programLaneCount: 2, subwooferCount: subs)
    }

    private func engine(rate: Double = 48_000) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_201, uid: "abx-wiring-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 6)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "abx-wiring-out")
        engine.unifiedGraphEnabled = true
        return engine
    }

    private func shape() throws -> UnifiedGraphLayoutShape {
        try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontLeft, .frontRight]))
    }

    // MARK: Matching

    func testLanePlanMatchLevelsAndLatencyAtEveryRate() throws {
        let a = try install(mode: .video, db: -2, name: "A")
        let b = try install(mode: .defaultMusic, db: -5, name: "B")
        let cache = RoomCorrectionRateCache()
        for rate in Self.rates {
            let planA = try cache.plan(for: a.design, sampleRate: rate)
            let planB = try cache.plan(for: b.design, sampleRate: rate)
            let match = try RoomCorrectionABXMatch.make(a: planA, b: planB, programLanes: [0, 1])
            for lane in [0, 1] {
                let la = 10 * log10(try RoomCorrectionABXMatch.lanePower(plan: planA, lane: lane)) + 20 * log10(match.gainA)
                let lb = 10 * log10(try RoomCorrectionABXMatch.lanePower(plan: planB, lane: lane)) + 20 * log10(match.gainB)
                XCTAssertEqual(la, lb, accuracy: 0.1, "\(rate) lane \(lane)")
            }
            XCTAssertLessThanOrEqual(match.gainA, 1, "\(rate)")
            XCTAssertLessThanOrEqual(match.gainB, 1, "\(rate)")
            XCTAssertEqual(planA.declaredLatencyFrames + UInt32(match.delayA), planB.declaredLatencyFrames + UInt32(match.delayB), "\(rate)")
            XCTAssertFalse(match.hasLaneResidualWarning, "\(rate)")
        }
    }

    func testLaneResidualWarningWhenOneSpeakerDiffers() throws {
        let a = try install(mode: .video, db: -2, name: "A")
        let b = try install(mode: .video, db: -2, name: "B", laneBDB: -6)
        let cache = RoomCorrectionRateCache()
        let match = try RoomCorrectionABXMatch.make(
            a: try cache.plan(for: a.design, sampleRate: 48_000), b: try cache.plan(for: b.design, sampleRate: 48_000),
            programLanes: [0, 1])
        XCTAssertGreaterThan(match.maxLaneResidualDB, RoomCorrectionABXMatch.laneResidualWarningDB)
        XCTAssertTrue(match.hasLaneResidualWarning)
    }

    func testMatchRefusesNoLanesAndRateMismatch() throws {
        let a = try install(mode: .video, db: -2, name: "A")
        let cache = RoomCorrectionRateCache()
        let p48 = try cache.plan(for: a.design, sampleRate: 48_000)
        let p96 = try cache.plan(for: a.design, sampleRate: 96_000)
        XCTAssertThrowsError(try RoomCorrectionABXMatch.make(a: p48, b: p48, programLanes: []))
        XCTAssertThrowsError(try RoomCorrectionABXMatch.make(a: p48, b: p96, programLanes: [0]))
    }

    // MARK: Engine override

    func testOverrideReplacesLanesTrimsAndDelaysEverySourceLane() throws {
        for rate in [48_000.0, 384_000.0] {
            let engine = try engine(rate: rate)
            let profile = try install(mode: .video, db: -2, name: "Profile")
            let candidate = try install(mode: .defaultMusic, db: -4, name: "Candidate")
            var inputs = engine.currentLiveGraphInputs
            inputs.room = RoomCorrectionConfiguration(enabled: true, lanes: profile)
            let base = try XCTUnwrap(engine.makeUnifiedProgramDSP(
                sampleRate: rate, shape: try shape(), virtualSpeakers: false, subwooferCount: 1, inputs: inputs))
            let baseGain = base.inputGain

            engine.roomCorrectionABXOverride = RoomCorrectionABXOverride(install: candidate, gain: 0.5, extraDelayFrames: 40)
            let over = try XCTUnwrap(engine.makeUnifiedProgramDSP(
                sampleRate: rate, shape: try shape(), virtualSpeakers: false, subwooferCount: 1, inputs: inputs), "\(rate)")
            let candidateDelays = try candidate.delayFrames(sampleRate: rate)
            for lane in 0..<3 {
                XCTAssertEqual(over.laneDelayFrames[lane], candidateDelays[lane, default: 0] + 40, "\(rate) lane \(lane)")
            }
            XCTAssertEqual(over.inputGain, baseGain * 0.5, accuracy: 1e-6, "\(rate)")
            let expected = try engine.roomCorrectionRateCache.plan(for: candidate.design, sampleRate: rate)
            XCTAssertEqual(over.roomLanes, expected, "\(rate)")
            XCTAssertEqual(try engine.roomCorrectionRateCache.plan(for: profile.design, sampleRate: rate), try XCTUnwrap(base.roomLanes))

            // Sub-to-main arrival is the same with and without the override.
            let baseDelays = try profile.delayFrames(sampleRate: rate)
            XCTAssertEqual(
                Int(over.laneDelayFrames[2, default: 0]) - Int(over.laneDelayFrames[0, default: 0]),
                Int(candidateDelays[2, default: 0]) - Int(candidateDelays[0, default: 0]), "\(rate)")
            XCTAssertEqual(baseDelays[2, default: 0], candidateDelays[2, default: 0], "\(rate)")

            // Clearing restores the profile plan exactly.
            engine.roomCorrectionABXOverride = nil
            let restored = try XCTUnwrap(engine.makeUnifiedProgramDSP(
                sampleRate: rate, shape: try shape(), virtualSpeakers: false, subwooferCount: 1, inputs: inputs))
            XCTAssertEqual(restored.roomLanes, base.roomLanes, "\(rate)")
            XCTAssertEqual(restored.laneDelayFrames, base.laneDelayFrames, "\(rate)")
            XCTAssertEqual(restored.inputGain, baseGain, "\(rate)")
        }
    }

    func testOverrideThatCannotBeHonouredThrowsAndKeepsTheProfilePlan() throws {
        let engine = try engine()
        let profile = try install(mode: .video, db: -2, name: "Profile")
        var inputs = engine.currentLiveGraphInputs
        inputs.room = RoomCorrectionConfiguration(enabled: true, lanes: profile)
        let candidate = try install(mode: .video, db: -3, name: "Candidate")
        engine.roomCorrectionABXOverride = RoomCorrectionABXOverride(install: candidate, gain: 1, extraDelayFrames: 10_000_000)
        XCTAssertThrowsError(try engine.makeUnifiedProgramDSP(
            sampleRate: 48_000, shape: try shape(), virtualSpeakers: false, subwooferCount: 1, inputs: inputs))
        let wrongLayout = try install(mode: .video, db: -3, name: "Wrong", subs: 2)
        engine.roomCorrectionABXOverride = RoomCorrectionABXOverride(install: wrongLayout, gain: 1, extraDelayFrames: 0)
        XCTAssertThrowsError(try engine.makeUnifiedProgramDSP(
            sampleRate: 48_000, shape: try shape(), virtualSpeakers: false, subwooferCount: 1, inputs: inputs))
    }

    func testEngineReportsWhyABXIsUnavailableAndRefusesToPlay() throws {
        let engine = try engine()
        XCTAssertNotNil(engine.roomCorrectionABXUnavailableReason)
        let candidate = try install(mode: .video, db: -3, name: "Candidate")
        XCTAssertThrowsError(try engine.setRoomCorrectionABXOverride(
            RoomCorrectionABXOverride(install: candidate, gain: 1, extraDelayFrames: 0)))
        XCTAssertNil(engine.roomCorrectionABXOverride)
        XCTAssertNoThrow(try engine.setRoomCorrectionABXOverride(nil))
    }

    // MARK: Controller

    private struct Run {
        let controller: RoomCorrectionABXController
        let player: FakeABXPlayer
        let overrideB: RoomCorrectionABXOverride
        let directory: URL
    }

    private func makeRun(
        seatNames: [String] = ["Seat 1", "Seat 2", "Seat 3"], directory: URL? = nil, laneBDB: Double? = nil,
        player: FakeABXPlayer? = nil
    ) throws -> Run {
        let player = player ?? FakeABXPlayer()
        let a = try install(mode: .video, db: -2, name: "A")
        let b = try install(mode: .defaultMusic, db: -2, name: "B", laneBDB: laneBDB)
        let cache = RoomCorrectionRateCache()
        let match = try RoomCorrectionABXMatch.make(
            a: try cache.plan(for: a.design, sampleRate: 48_000), b: try cache.plan(for: b.design, sampleRate: 48_000),
            programLanes: [0, 1])
        let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("abx-wiring-\(UUID().uuidString)")
        let controller = try RoomCorrectionABXController(
            player: player, a: a, b: b, match: match, seatCount: seatNames.count, seatNames: seatNames, logDirectory: dir,
            trialCount: 16, initialAssignment: true, nextAssignment: { Bool.random() })
        return Run(controller: controller, player: player, overrideB: match.override(for: b, isA: false), directory: dir)
    }

    /// Plays X, reads which design the fake was handed, and answers right (or wrong).
    private func runTrials(_ run: Run, correct: Bool) {
        for _ in 0..<run.controller.totalTrials {
            run.controller.select(.x)
            let xIsB = run.player.played.last == run.overrideB
            run.controller.answer(xIsB: correct ? xIsB : !xIsB)
        }
    }

    func testChoicesAreRefusedUntilXHasPlayedAndNamesStayHidden() throws {
        let run = try makeRun()
        defer { try? FileManager.default.removeItem(at: run.directory) }
        let c = run.controller
        XCTAssertFalse(c.canAnswer)
        c.answer(xIsB: true)
        XCTAssertEqual(c.completedTrials, 0)
        XCTAssertNotNil(c.message)
        c.select(.a); c.select(.b)
        XCTAssertFalse(c.canAnswer, "A and B alone never unlock the answer")
        c.select(.x)
        XCTAssertTrue(c.canAnswer)
        XCTAssertNil(c.revealedNames)
        runTrials(run, correct: true)
        XCTAssertEqual(c.phase, .askingPreference)
        XCTAssertNil(c.revealedNames, "names stay hidden until the preference is in")
        XCTAssertNil(c.result)
        c.submitPreference(.b)
        XCTAssertEqual(c.phase, .finished)
        XCTAssertEqual(c.revealedNames?.a, RoomCorrectionABXLog.minimumPhaseName)
        XCTAssertEqual(c.revealedNames?.b, RoomCorrectionABXLog.mixedPhaseName)
    }

    func testBusyCoreRefusesASwitch() throws {
        let player = FakeABXPlayer()
        let run = try makeRun(player: player)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        player.isSwitching = true
        run.controller.select(.a)
        XCTAssertTrue(player.played.isEmpty)
        player.isSwitching = false
        run.controller.select(.a)
        XCTAssertEqual(player.played.count, 1)
    }

    func testOneLogPerRunWithPValueSeatAndPreference() throws {
        let run = try makeRun()
        defer { try? FileManager.default.removeItem(at: run.directory) }
        let c = run.controller
        c.listeningSeatIndex = 1
        runTrials(run, correct: true)
        c.submitPreference(.b)
        let logs = RoomCorrectionABXLog.readAll(in: run.directory)
        XCTAssertEqual(logs.count, 1)
        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(log.schemaVersion, 2)
        XCTAssertEqual(log.correctCount, 16)
        XCTAssertEqual(log.oneSidedExactPValue, 1.0 / 65_536.0, accuracy: 1e-12)
        XCTAssertEqual(log.listeningSeat, 2)
        XCTAssertEqual(log.preferredDesignName, RoomCorrectionABXLog.mixedPhaseName)
        XCTAssertNotNil(log.maxLaneResidualDB)
        XCTAssertEqual(c.result?.pValue ?? 1, log.oneSidedExactPValue, accuracy: 1e-12)
        c.submitPreference(.a)
        XCTAssertEqual(RoomCorrectionABXLog.readAll(in: run.directory).count, 1, "a second answer writes nothing")
    }

    func testNoPreferenceIsLoggedAsNil() throws {
        let run = try makeRun()
        defer { try? FileManager.default.removeItem(at: run.directory) }
        runTrials(run, correct: false)
        run.controller.submitPreference(.none)
        XCTAssertNil(RoomCorrectionABXLog.readAll(in: run.directory).first?.preferredDesignName)
        XCTAssertFalse(run.controller.g3Passed)
    }

    func testGateG3ThroughTheControllerNeedsThreeSeats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("abx-g3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var last: RoomCorrectionABXController?
        for seat in 0..<3 {
            let run = try makeRun(directory: directory)
            run.controller.listeningSeatIndex = seat
            runTrials(run, correct: true)
            run.controller.submitPreference(.b)
            XCTAssertEqual(run.controller.seatsWithPassingLog, seat + 1)
            XCTAssertEqual(run.controller.g3Passed, seat == 2)
            last = run.controller
        }
        XCTAssertTrue(try XCTUnwrap(last).g3Passed)
    }

    func testCloseRestoresAndReadinessEndsTheRun() throws {
        let player = FakeABXPlayer()
        let run = try makeRun(player: player)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        run.controller.select(.a)
        run.controller.close()
        XCTAssertEqual(player.restoreCount, 1)

        let stopped = FakeABXPlayer()
        let second = try makeRun(player: stopped)
        defer { try? FileManager.default.removeItem(at: second.directory) }
        second.controller.select(.b)
        stopped.unavailableReason = "Start playback with music to compare by ear."
        second.controller.refreshReadiness()
        XCTAssertEqual(second.controller.phase, .ended("Start playback with music to compare by ear."))
        XCTAssertEqual(stopped.restoreCount, 1, "the applied design is back")
        second.controller.select(.a)
        XCTAssertEqual(stopped.played.count, 1, "an ended run plays nothing more")
    }

    func testLaneResidualWarningReachesTheSheet() throws {
        let run = try makeRun(laneBDB: -8)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        XCTAssertNotNil(run.controller.levelWarning)
        let ok = try makeRun()
        defer { try? FileManager.default.removeItem(at: ok.directory) }
        XCTAssertNil(ok.controller.levelWarning)
    }

    // MARK: Log schema and Gate G3

    private func makeLog(seat: Int?, p: Double, preferred: String?) throws -> RoomCorrectionABXLog {
        let a = try install(mode: .video, db: -2, name: "A")
        let cache = RoomCorrectionRateCache()
        let plan = try cache.plan(for: a.design, sampleRate: 48_000)
        let match = try RoomCorrectionABXMatch.make(a: plan, b: plan, programLanes: [0])
        var session = try BlindABXSession(trialCount: 12, initialAssignment: true)
        for i in 0..<12 {
            try session.recordXPlayback()
            let hidden = session.currentHiddenXWasB
            try session.submit(hidden, nextAssignment: i % 2 == 0)
        }
        var log = try RoomCorrectionABXLog(
            session: session, match: match, designAName: RoomCorrectionABXLog.minimumPhaseName,
            designBName: RoomCorrectionABXLog.mixedPhaseName, seatCount: 3, listeningSeat: seat ?? 0,
            preferredDesignName: preferred)
        log.listeningSeat = seat
        log.oneSidedExactPValue = p
        return log
    }

    func testSchemaOneFileDecodesWithNilFields() throws {
        let sample = try makeLog(seat: 1, p: 0.01, preferred: RoomCorrectionABXLog.mixedPhaseName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(sample)) as? [String: Any])
        object["schemaVersion"] = 1
        for key in ["maxLaneResidualDB", "listeningSeat", "preferredDesignName"] { object.removeValue(forKey: key) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("abx-old-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let old = try RoomCorrectionABXLog.read(from: url)
        XCTAssertEqual(old.schemaVersion, 1)
        XCTAssertNil(old.listeningSeat)
        XCTAssertNil(old.preferredDesignName)
        XCTAssertNil(old.maxLaneResidualDB)
        XCTAssertFalse(RoomCorrectionABXLog.gateG3([old, old, old]))
    }

    func testGateG3Rules() throws {
        let mixed = RoomCorrectionABXLog.mixedPhaseName
        let three = [try makeLog(seat: 1, p: 0.01, preferred: mixed), try makeLog(seat: 2, p: 0.04, preferred: mixed),
                     try makeLog(seat: 3, p: 0.001, preferred: mixed)]
        XCTAssertTrue(RoomCorrectionABXLog.gateG3(three))
        XCTAssertFalse(RoomCorrectionABXLog.gateG3(Array(three.prefix(2))))
        let oneSeat = [try makeLog(seat: 1, p: 0.01, preferred: mixed), try makeLog(seat: 1, p: 0.01, preferred: mixed),
                       try makeLog(seat: 1, p: 0.01, preferred: mixed)]
        XCTAssertFalse(RoomCorrectionABXLog.gateG3(oneSeat))
        var atBoundary = three; atBoundary[2] = try makeLog(seat: 3, p: 0.05, preferred: mixed)
        XCTAssertFalse(RoomCorrectionABXLog.gateG3(atBoundary), "p must be below 0.05")
        var minPhase = three; minPhase[0] = try makeLog(seat: 1, p: 0.01, preferred: RoomCorrectionABXLog.minimumPhaseName)
        XCTAssertFalse(RoomCorrectionABXLog.gateG3(minPhase))
        var none = three; none[0] = try makeLog(seat: 1, p: 0.01, preferred: nil)
        XCTAssertFalse(RoomCorrectionABXLog.gateG3(none))
    }
}
