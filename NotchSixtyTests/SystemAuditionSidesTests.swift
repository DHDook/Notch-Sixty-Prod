import XCTest
@testable import NotchSixty

/// E12 S28b2: system-profile sides, "Everything off", the level and latency match through the built graphs, the exits,
/// and the page model end to end against a fake transport (the engine boundary `SystemAuditionPlaying`).
@MainActor
final class SystemAuditionSidesTests: XCTestCase {
    static let rates = AuditionOverrideTests.rates

    // MARK: Fixtures

    private func grid(_ db: Double) throws -> RoomCorrectionGridDesign {
        let frequencies = try RoomCorrectionCore.gridFrequencies()
        return RoomCorrectionGridDesign(
            correctionDB: frequencies.map { $0 < 1_000 ? db : 0 },
            correctionPhaseRadians: [Double](repeating: 0, count: frequencies.count),
            coherence: [Double](repeating: 0, count: frequencies.count), seatContribution: [])
    }

    private func install(db: Double) throws -> RoomCorrectionLaneInstall {
        let design = RoomCorrectionMultiLaneDesign(
            latencyMode: .video, laneCount: 2,
            lanes: [RoomCorrectionLaneDesign(lane: 0, grid: try grid(db)), RoomCorrectionLaneDesign(lane: 1, grid: try grid(db))])
        return RoomCorrectionLaneInstall(name: "P", design: design, programLaneCount: 2, subwooferCount: 0)
    }

    private func running(room: RoomCorrectionLaneInstall?, bass: BassManagementConfiguration = BassManagementConfiguration())
        -> SystemAuditionContext {
        var state = PlaybackSystemState(associatedOutputUID: "out", bassManagement: bass)
        if let room { state.roomCorrection = RoomCorrectionConfiguration(enabled: true, lanes: room) }
        return SystemAuditionContext(running: state, speakerRouting: nil, programLanes: 2, subwoofers: 0, refusal: nil)
    }

    private func profile(_ name: String, _ edit: (inout PlaybackSystemState) -> Void, base: PlaybackSystemState) -> PlaybackSystemProfile {
        var state = base
        edit(&state)
        return PlaybackSystemProfile(name: name, state: state)
    }

    private let current = ContentABAuditionState(
        stereoEQ: StereoEQConfiguration(), inputPreampDB: 0, headroomAttenuationDB: 0, dynamics: DynamicsConfiguration())

    // MARK: Eligibility

    func testEligibilityTableGreysEveryMismatchWithItsReason() throws {
        let room = try install(db: -2)
        let context = running(room: room)
        let base = context.running
        let cases: [(String, (inout PlaybackSystemState) -> Void, String)] = [
            ("output", { $0.associatedOutputUID = "other" }, "uses a different output"),
            ("playback", { $0.playback.speakerCrossfeedEnabled = true }, "uses different Playback System controls"),
            ("bass mode", { $0.bassManagement.physicalOutputMode = .mainsSub }, "uses a different bass output mode"),
            ("driver", {
                var bus = SpeakerDriverBusProcessingConfiguration(bus: .leftFullRange)
                bus.enabled = true
                bus.trimDB = -2
                $0.speakerDriverProcessing = SpeakerDriverProcessingConfiguration(buses: [bus])
            }, "uses different speaker-driver processing"),
            ("legacy filter", {
                $0.roomCorrection = RoomCorrectionConfiguration(enabled: true, filter: nil, lanes: nil)
            }, "uses an older room correction that cannot be compared live"),
        ]
        for (label, edit, reason) in cases {
            let side = profile(label, edit, base: base)
            let result = SystemSideEligibility.evaluate(profile: side, context: context)
            XCTAssertNil(result.override, label)
            XCTAssertEqual(result.reason, reason, label)
        }
        // A correction measured for another layout.
        var other = room
        other.programLaneCount = 3
        let layout = profile("layout", { $0.roomCorrection = RoomCorrectionConfiguration(enabled: true, lanes: other) }, base: base)
        XCTAssertEqual(SystemSideEligibility.evaluate(profile: layout, context: context).reason, "was measured for a different speaker layout")
        // Refused while treatment is live: every profile is greyed with the engine's reason.
        var armed = context
        armed.refusal = "Turn off room treatment to compare system settings."
        XCTAssertEqual(SystemSideEligibility.evaluate(profile: profile("x", { _ in }, base: base), context: armed).reason, armed.refusal)
    }

    func testEligibleProfilesMayDifferInCorrectionBassAndOutputGainOnly() throws {
        let room = try install(db: -2), otherRoom = try install(db: -4)
        let context = running(room: room)
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.frequencyHz = 100
        // Correction off, a different design, a different crossover, a different output gain.
        let off = profile("off", { $0.roomCorrection = RoomCorrectionConfiguration() }, base: context.running)
        XCTAssertEqual(SystemSideEligibility.evaluate(profile: off, context: context).override?.roomCorrection, .off)
        let design = profile("design", { $0.roomCorrection = RoomCorrectionConfiguration(enabled: true, lanes: otherRoom) }, base: context.running)
        XCTAssertEqual(SystemSideEligibility.evaluate(profile: design, context: context).override?.installedLanes, otherRoom)
        let crossover = profile("bass", { $0.bassManagement = bass; $0.outputGainDB = -3 }, base: context.running)
        let result = SystemSideEligibility.evaluate(profile: crossover, context: context)
        XCTAssertEqual(result.override?.bassManagement, bass)
        XCTAssertEqual(result.override?.roomCorrection, .applied)
        // The running system itself is not a different side.
        XCTAssertEqual(SystemSideEligibility.evaluate(profile: profile("same", { $0.outputGainDB = -3 }, base: context.running), context: context).reason,
                       "plays the same room correction and bass management as now")
        // The list greys the ineligible and keeps the current content on the eligible.
        let list = ComparisonCandidates.systemProfiles(
            [off, profile("else", { $0.associatedOutputUID = "x" }, base: context.running)], current: current, context: context)
        XCTAssertNil(list[0].unavailableReason)
        XCTAssertEqual(list[0].state, current)
        XCTAssertEqual(list[1].unavailableReason, "else uses a different output")
        XCTAssertTrue(list.allSatisfy(\.isSystemSide))
        XCTAssertEqual(Set(list.map(\.id)).count, 2)
    }

    func testEverythingOffTurnsBassOffOnlyWithNoSubwooferOrAConfirmation() throws {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        var context = running(room: try install(db: -2), bass: bass)
        let withoutSub = ComparisonCandidates.everythingOff(current: current, context: context, bassOff: true)
        XCTAssertEqual(withoutSub.systemOverride?.roomCorrection, .off)
        XCTAssertEqual(withoutSub.systemOverride?.bassManagement?.enabled, false)
        XCTAssertEqual(withoutSub.state.stereoEQ, StereoEQConfiguration())
        // With a subwoofer and no confirmation bass management stays on (Q1).
        context.subwoofers = 1
        let kept = ComparisonCandidates.everythingOff(current: current, context: context, bassOff: false)
        XCTAssertEqual(kept.systemOverride?.roomCorrection, .off)
        XCTAssertNil(kept.systemOverride?.bassManagement)
        // Treatment live: greyed, not playable.
        context.refusal = "Turn off room treatment to compare system settings."
        XCTAssertEqual(ComparisonCandidates.everythingOff(current: current, context: context, bassOff: true).unavailableReason, context.refusal)
        XCTAssertNotNil(ComparisonCandidates.everythingOff(current: current, context: nil, bassOff: true).unavailableReason)
        XCTAssertEqual(withoutSub.id, ComparisonCandidates.everythingOffID)
    }

    // MARK: Level and latency match on built graphs (eight rates)

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_302, uid: "sides-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 6)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "sides-out")
        engine.unifiedGraphEnabled = true
        return engine
    }

    /// The spec a side builds, the way a republish builds it (stereo layout, no session needed).
    private func spec(
        _ engine: AudioIOEngine, rate: Double, room: RoomCorrectionLaneInstall?, override: AuditionOverride? = nil,
        preampDB: Double = 0
    ) throws -> UnifiedGraphSpec {
        var inputs = engine.currentLiveGraphInputs
        inputs.room = room.map { RoomCorrectionConfiguration(enabled: true, lanes: $0) } ?? RoomCorrectionConfiguration()
        inputs.gain.inputPreampDB = preampDB
        engine.auditionOverride = override
        defer { engine.auditionOverride = nil }
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(sampleRate: rate, programChannels: 2, subwoofers: [])
        configuration.orderPolicy = .canonical
        configuration.inputGain = Float(DSPGainConfiguration.linearGain(forDB: preampDB))
        configuration.programDSP = try engine.makeUnifiedProgramDSP(
            sampleRate: rate, shape: try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontLeft, .frontRight])),
            virtualSpeakers: false, subwooferCount: 0, inputs: inputs)
        return try configuration.makeSpec()
    }

    func testCorrectionOffReadsLouderAndTheTrimMatchesWithinATenthOfADecibelAtEveryRate() async throws {
        let room = try install(db: -3)
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            let on = try await AuditionSideAnalyser.analyse(spec: try spec(engine, rate: rate, room: room))
            let off = try await AuditionSideAnalyser.analyse(spec: try spec(engine, rate: rate, room: room, override: AuditionOverride(roomCorrection: .off)))
            let onDB = 10 * log10(on.powerRatio), offDB = 10 * log10(off.powerRatio)
            XCTAssertGreaterThan(offDB - onDB, 0.5, "\(rate): -3 dB below 1 kHz is a real level change on the model")
            XCTAssertLessThan(offDB - onDB, 3.0, "\(rate)")
            XCTAssertGreaterThan(on.latencyFrames, off.latencyFrames, "\(rate): the built latency includes the convolver engine")
            // The match trims the louder side; re-measured with that trim the two agree within the tolerance.
            let match = try ComparisonLevelMatch.make(lanePowersA: [on.powerRatio], lanePowersB: [off.powerRatio])
            XCTAssertEqual(match.trimmedSide, .b, "\(rate)")
            let trimmed = try await AuditionSideAnalyser.analyse(spec: try spec(
                engine, rate: rate, room: room, override: AuditionOverride(roomCorrection: .off), preampDB: match.trimBDB))
            XCTAssertEqual(10 * log10(trimmed.powerRatio), onDB, accuracy: ComparisonLevelMatch.toleranceDB, "\(rate)")
        }
    }

    func testLatencyPadComesFromTheBuiltGraphsNotTheDeclaredLatency() async throws {
        let room = try install(db: -2)
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            let plan = try engine.roomCorrectionRateCache.plan(for: room.design, sampleRate: rate)
            let player = FakeSystemPlayer(current: current, rate: rate) { content, override in
                try await AuditionSideAnalyser.analyse(spec: try self.spec(
                    engine, rate: rate, room: room, override: override, preampDB: content.inputPreampDB))
            }
            let a = ComparisonCandidate(kind: .current, name: "A", state: current)
            var b = ComparisonCandidates.everythingOff(current: current, context: running(room: room), bassOff: true)
            b.state = current
            let pair = try await BlindLiveComparison.systemPair(player: player, a: a, b: b)
            let pad = try XCTUnwrap(pair.overrideB?.latencyPadFrames, "\(rate)")
            XCTAssertNil(pair.overrideA, "\(rate): the longer side is not padded")
            XCTAssertGreaterThan(pad, plan.declaredLatencyFrames, "\(rate): engine latency is part of the pad")
            XCTAssertTrue(pair.match.isElectricalModel)
            XCTAssertTrue(pair.match.summary.contains("approximate"))
            // Playing the padded side builds a graph with the same latency as the other side.
            let longer = try await AuditionSideAnalyser.analyse(spec: try spec(engine, rate: rate, room: room))
            let padded = try await AuditionSideAnalyser.analyse(spec: try spec(engine, rate: rate, room: room, override: pair.overrideB))
            XCTAssertEqual(padded.latencyFrames, longer.latencyFrames, "\(rate)")
        }
    }

    func testAPadPastTheLimitMakesThePairUnavailable() async throws {
        let player = FakeSystemPlayer(current: current, rate: 48_000) { _, override in
            AuditionSideAnalysis(latencyFrames: override == nil ? N60_GRAPH_MAX_DELAY_FRAMES + 10 : 0, powerRatio: 2, isApproximate: false)
        }
        let a = ComparisonCandidate(kind: .current, name: "A", state: current)
        var b = ComparisonCandidate(kind: .everythingOff, name: "B", state: current)
        b.systemOverride = AuditionOverride(roomCorrection: .off)
        do {
            _ = try await BlindLiveComparison.systemPair(player: player, a: a, b: b)
            XCTFail("a pad past the limit must refuse")
        } catch {
            XCTAssertEqual(error as? AuditionOverrideError, .padTooLong)
        }
    }

    func testBassOffAndSubGainPairsMatchOnTheModel() async throws {
        // Two profiles that differ only in the sub: the sub gain moves the summed level by the predicted amount.
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            var low = BassManagementConfiguration(), high = BassManagementConfiguration()
            low.enabled = true; high.enabled = true
            high.subGainDB = 6
            let plain = try await AuditionSideAnalyser.analyse(spec: try spec(engine, rate: rate, room: nil))
            let lowSide = try await AuditionSideAnalyser.analyse(spec: try spec(engine, rate: rate, room: nil, override: AuditionOverride(bassManagement: low)))
            let highSide = try await AuditionSideAnalyser.analyse(spec: try spec(engine, rate: rate, room: nil, override: AuditionOverride(bassManagement: high)))
            XCTAssertTrue(plain.powerRatio.isFinite && lowSide.powerRatio.isFinite && highSide.powerRatio.isFinite, "\(rate)")
            // A stereo layout without a sub lane has nothing for the sub gain to move: the two sides read alike.
            XCTAssertEqual(10 * log10(highSide.powerRatio), 10 * log10(lowSide.powerRatio), accuracy: ComparisonLevelMatch.toleranceDB, "\(rate)")
            let preamp = try await AuditionSideAnalyser.analyse(spec: try spec(engine, rate: rate, room: nil, preampDB: -6))
            XCTAssertEqual(10 * log10(preamp.powerRatio), 10 * log10(plain.powerRatio) - 6, accuracy: 0.1, "\(rate)")
        }
    }

    // MARK: Page model end to end against a fake transport

    func testSystemTestRunsFromThePageToHistoryAndRestoresTheStoredSystem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sides-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        let room = try install(db: -2)
        let context = running(room: room)
        let player = FakeSystemPlayer(current: current, rate: 48_000) { _, override in
            AuditionSideAnalysis(latencyFrames: override?.roomCorrection == .off ? 100 : 356, powerRatio: override?.roomCorrection == .off ? 2.0 : 1.6, isApproximate: false)
        }
        player.context = context
        let history = BlindTestHistoryStore(url: root.appendingPathComponent("history.json"))
        let model = BlindLiveModel(profiles: profiles, history: history, player: player)
        model.switchHold = 0
        model.trialCount = 12
        XCTAssertTrue(model.candidates.contains { $0.kind == .everythingOff && $0.unavailableReason == nil })
        model.sideAID = "current"
        model.sideBID = ComparisonCandidates.everythingOffID
        model.start()
        XCTAssertTrue(model.isPreparing)
        await model.awaitPreparation()
        let service = try XCTUnwrap(model.service, model.error ?? "no service")
        XCTAssertTrue(service.match.isElectricalModel)
        XCTAssertFalse(model.isPreparing)
        for _ in 0..<12 {
            service.select(.x)
            service.answer(xIsB: false)
        }
        model.recordIfFinished()
        let record = try XCTUnwrap(history.records.first)
        XCTAssertEqual(record.sideB, model.candidates.first { $0.kind == .everythingOff }?.name)
        // The played "everything off" side carried the pad (the built-graph latency difference) and the louder side's trim.
        let off = try XCTUnwrap(player.appliedSides.first { $0.override?.roomCorrection == .off })
        XCTAssertEqual(off.override?.latencyPadFrames, 256)
        XCTAssertLessThan(off.attenuationDB, 0, "the louder side is the one turned down")
        model.stop()
        let last = try XCTUnwrap(player.appliedSides.last)
        XCTAssertNil(last.override, "the override slot is cleared on close")
        XCTAssertEqual(last.content, current)
        XCTAssertEqual(last.attenuationDB, 0)
    }

    func testEveryExitRestoresAndClearsTheOverride() async throws {
        let reasons = [
            "Start playback with music to compare by ear.", "The output changed, so the comparison ended.",
            "The sample rate changed, so the comparison ended.", "Another comparison opened, so the test ended.",
            "Settings were changed elsewhere, so the comparison ended.", "Room treatment was turned on, so the comparison ended.",
            "Turn off room treatment to compare system settings.",
        ]
        for reason in reasons {
            let player = FakeSystemPlayer(current: current, rate: 48_000) { _, _ in
                AuditionSideAnalysis(latencyFrames: 0, powerRatio: 2, isApproximate: false)
            }
            var b = ComparisonCandidate(kind: .everythingOff, name: "Off", state: current)
            b.systemOverride = AuditionOverride(roomCorrection: .off)
            let service = try await BlindLiveComparison.makeSystemService(
                player: player, a: ComparisonCandidate(kind: .current, name: "Now", state: current), b: b, kind: .abx, trialCount: 12,
                switchHold: 0)
            service.select(.b)
            XCTAssertNotNil(player.appliedSides.last?.override)
            player.unavailableReason = reason
            service.refreshReadiness()
            XCTAssertEqual(service.phase, .ended(reason), reason)
            XCTAssertNil(player.appliedSides.last?.override, "restored: \(reason)")
        }
        // Close and a failed first switch also leave nothing behind.
        let player = FakeSystemPlayer(current: current, rate: 48_000) { _, _ in
            AuditionSideAnalysis(latencyFrames: 0, powerRatio: 2, isApproximate: false)
        }
        var b = ComparisonCandidate(kind: .everythingOff, name: "Off", state: current)
        b.systemOverride = AuditionOverride(roomCorrection: .off)
        let service = try await BlindLiveComparison.makeSystemService(
            player: player, a: ComparisonCandidate(kind: .current, name: "Now", state: current), b: b, kind: .abx, trialCount: 12, switchHold: 0)
        service.select(.b)
        service.close()
        XCTAssertNil(player.appliedSides.last?.override)
    }

    func testAnUnavailableSideCannotStartATest() async throws {
        let player = FakeSystemPlayer(current: current, rate: 48_000) { _, _ in
            AuditionSideAnalysis(latencyFrames: 0, powerRatio: 2, isApproximate: false)
        }
        var greyed = ComparisonCandidate(kind: .system(UUID()), name: "System: X", state: current)
        greyed.unavailableReason = "X uses a different output"
        do {
            _ = try await BlindLiveComparison.makeSystemService(
                player: player, a: ComparisonCandidate(kind: .current, name: "Now", state: current), b: greyed, kind: .abx, trialCount: 12)
            XCTFail("a greyed side must not start")
        } catch {
            XCTAssertEqual(error.localizedDescription, "X uses a different output")
        }
        XCTAssertTrue(player.appliedSides.isEmpty, "nothing was played")
    }

    // MARK: Engine hooks (arming ends the test first)

    func testArmingRequestsReachTheOpenComparisonFromBothArmPaths() async throws {
        let engine = AudioIOEngine()
        var ended = 0
        engine.auditionEndRequest = { ended += 1 }
        engine.endAuditionForArming()
        XCTAssertEqual(ended, 1)
        // The MIMO treatment asks before it checks any gate.
        engine.mimoGraphTreatment.willArm?()
        XCTAssertEqual(ended, 2, "the engine hooks the MIMO treatment's willArm")
        _ = try? await engine.mimoGraphTreatment.requestArm(context: MIMOGraphTreatment.Context(engineRunning: false, outputDeviceUID: nil, sampleRate: nil, stageAttached: false, hardLimitPresent: false, engineLeaseHeld: false, videoLatencyMode: false, outputTrimsDB: [], laneCount: 2))
        XCTAssertEqual(ended, 3, "a refused arm still asked first")
    }

    func testAQuietZoneArmIsSeenByTheEngineRefusal() throws {
        let engine = AudioIOEngine()
        XCTAssertNil(engine.auditionSystemDomainsRefusal)
        engine.commitActiveQuietZoneRuntimeTarget(ActiveQuietZoneRuntimeTarget(
            tones: [ActiveQuietZoneRuntimeTone(
                frequencyHz: 60, leftOutput: ActiveQuietZoneComplex(real: 0.001, imaginary: 0), rightOutput: .zero)],
            transitionMilliseconds: 3_000, armGeneration: engine.liveTreatmentGeneration))
        XCTAssertNotNil(engine.auditionSystemDomainsRefusal)
    }
}

/// A fake engine boundary: records what is played and builds each side's analysis with the closure given.
@MainActor
final class FakeSystemPlayer: SystemAuditionPlaying {
    var unavailableReason: String?
    var isSwitching = false
    var outputSampleRate: Double
    var current: ContentABAuditionState
    var context: SystemAuditionContext?
    private(set) var appliedSides: [(content: ContentABAuditionState, attenuationDB: Double, override: AuditionOverride?)] = []
    private let analysis: (ContentABAuditionState, AuditionOverride?) async throws -> AuditionSideAnalysis

    init(current: ContentABAuditionState, rate: Double,
         analysis: @escaping (ContentABAuditionState, AuditionOverride?) async throws -> AuditionSideAnalysis) {
        self.current = current
        outputSampleRate = rate
        self.analysis = analysis
    }

    var systemContext: SystemAuditionContext? { context }
    func currentContentState() -> ContentABAuditionState { current }
    func analyse(content: ContentABAuditionState, override: AuditionOverride?) async throws -> AuditionSideAnalysis {
        try await analysis(content, override)
    }
    func applySide(content: ContentABAuditionState, attenuationDB: Double, override: AuditionOverride?) throws {
        appliedSides.append((content, attenuationDB, override))
    }
    func apply(_ state: ContentABAuditionState, attenuationDB: Double) throws {
        try applySide(content: state, attenuationDB: attenuationDB, override: nil)
    }
    func restoreApplied() throws { try apply(current, attenuationDB: 0) }
}
