import XCTest
@testable import NotchSixty

/// E12 S27: the Blind Listening page tests what the app does (candidates, level match at the eight rates, both tests,
/// statistics, restore, and the before/after model), end to end from the service to a fake engine.
@MainActor
final class BlindLiveComparisonTests: XCTestCase {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    @MainActor
    final class FakePlayer: ContentAuditionPlaying {
        var unavailableReason: String?
        var isSwitching = false
        var outputSampleRate: Double = 48_000
        var current: ContentABAuditionState
        private(set) var applied: [(state: ContentABAuditionState, attenuation: Double)] = []
        var failApply = false

        init(current: ContentABAuditionState) { self.current = current }
        func currentContentState() -> ContentABAuditionState { current }
        func apply(_ state: ContentABAuditionState, attenuationDB: Double) throws {
            if failApply { throw RoomCorrectionABXError.unavailable("refused") }
            applied.append((state, attenuationDB))
        }
        func restoreApplied() throws { try apply(current, attenuationDB: 0) }
    }

    private final class Clock { var now = Date(timeIntervalSince1970: 5_000) }

    /// `EQBand` carries its own id, so equal arguments must give the one same state.
    private var cache: [String: ContentABAuditionState] = [:]

    private func state(gain: Double = 0, preamp: Double = 0) -> ContentABAuditionState {
        let key = "\(gain)/\(preamp)"
        if let hit = cache[key] { return hit }
        let made = build(gain: gain, preamp: preamp)
        cache[key] = made
        return made
    }

    private func build(gain: Double, preamp: Double) -> ContentABAuditionState {
        let bands = gain == 0 ? [] : [EQBand(enabled: true, type: .peaking, frequencyHz: 1_000, gainDB: gain, q: 1, slope: .db12)]
        return ContentABAuditionState(
            stereoEQ: StereoEQConfiguration(channelMode: .linked, editChannel: .linked, phaseMode: .minimumPhase, bypassed: false, linkedBands: bands),
            inputPreampDB: preamp, headroomAttenuationDB: 0, dynamics: DynamicsConfiguration())
    }

    private func candidates(_ current: ContentABAuditionState, presets: [ContentPreset] = []) -> [ComparisonCandidate] {
        ComparisonCandidates.list(current: current, presets: presets)
    }

    // MARK: Candidates

    func testCandidateListHasCurrentOffAndEveryPreset() {
        let preset = ContentPreset(name: "Bright", origin: .user, state: ContentPresetState(stereoEQ: state(gain: 4).stereoEQ))
        let list = candidates(state(), presets: [preset])
        XCTAssertEqual(list.map(\.name), ["Current settings", "Processing off", "Bright"])
        XCTAssertEqual(Set(list.map(\.id)).count, 3)
        XCTAssertEqual(list[0].state, state())
    }

    func testProcessingOffKeepsTheUsersOutputProtection() {
        var current = state(gain: 6, preamp: 2)
        var protection = OutputProtectionSettings()
        protection.headroomStrict = true
        current.dynamics.outputProtection = protection
        let off = candidates(current)[1].state
        XCTAssertEqual(off.dynamics.outputProtection, protection)
        XCTAssertEqual(off.inputPreampDB, 0)
        XCTAssertTrue(off.stereoEQ.linkedBands.isEmpty)
    }

    // MARK: Level match at the eight rates

    func testLouderSideTrimmedAndMatchedWithinToleranceAtEightRates() throws {
        for rate in Self.rates {
            let loud = state(gain: 6, preamp: 3), flat = state()
            let match = try BlindLiveComparison.match(a: loud, b: flat, sampleRate: rate)
            XCTAssertEqual(match.trimmedSide, .a, "rate \(rate)")
            XCTAssertEqual(match.gainB, 1, accuracy: 1e-12)
            let a = try XCTUnwrap(BlindLiveComparison.levelDB(of: loud, sampleRate: rate)) + match.trimADB
            let b = try XCTUnwrap(BlindLiveComparison.levelDB(of: flat, sampleRate: rate)) + match.trimBDB
            XCTAssertEqual(a, b, accuracy: ComparisonLevelMatch.toleranceDB, "rate \(rate)")
            XCTAssertLessThanOrEqual(match.trimADB, 0)
        }
    }

    func testActiveDynamicsMarksTheMatchApproximate() throws {
        var dynamic = state()
        dynamic.dynamics.loudnessMatch.enabled = true
        XCTAssertTrue(dynamic.dynamics.hasActiveProcessing)
        XCTAssertTrue(try BlindLiveComparison.match(a: dynamic, b: state(preamp: 1), sampleRate: 48_000).isApproximate)
        XCTAssertFalse(try BlindLiveComparison.match(a: state(gain: 2), b: state(preamp: 1), sampleRate: 48_000).isApproximate)
    }

    func testIdenticalSidesAndHugeLevelGapsAreRefused() throws {
        let player = FakePlayer(current: state())
        let list = candidates(state())
        XCTAssertThrowsError(try BlindLiveComparison.makeService(player: player, a: list[0], b: list[0], kind: .abx, trialCount: 12)) {
            XCTAssertEqual($0 as? BlindLiveComparisonError, .identicalSides)
        }
        let huge = ComparisonCandidate(kind: .processingOff, name: "Huge", state: state(preamp: 24))
        let quiet = ComparisonCandidate(kind: .current, name: "Quiet", state: state(preamp: -40))
        XCTAssertThrowsError(try BlindLiveComparison.makeService(player: player, a: huge, b: quiet, kind: .abx, trialCount: 12)) {
            XCTAssertEqual($0 as? BlindLiveComparisonError, .levelsTooFarApart)
        }
    }

    // MARK: Service end to end with a fake player

    private func make(
        kind: BlindComparisonService.Kind, player: FakePlayer, clock: Clock = Clock(), assignments: [Bool] = [], initial: Bool = true
    ) throws -> BlindComparisonService {
        var queue = assignments
        let current = state(gain: 6)
        let list = candidates(current)
        player.current = current
        return try BlindLiveComparison.makeService(
            player: player, a: list[0], b: list[1], kind: kind, trialCount: 12, initialAssignment: initial,
            nextAssignment: { queue.isEmpty ? true : queue.removeFirst() }, clock: { clock.now })
    }

    func testAbxPlaysTheLoudSideTrimmedAndRestoresOnClose() throws {
        let player = FakePlayer(current: state(gain: 6))
        let clock = Clock()
        let service = try make(kind: .abx, player: player, clock: clock)
        service.select(.a)
        XCTAssertEqual(player.applied.last?.state, state(gain: 6))
        XCTAssertLessThan(try XCTUnwrap(player.applied.last?.attenuation), 0)
        clock.now.addTimeInterval(1)
        service.refreshReadiness()
        service.select(.b)
        XCTAssertEqual(player.applied.last?.attenuation, 0)
        service.close()
        XCTAssertEqual(player.applied.last?.state, state(gain: 6))
        XCTAssertEqual(player.applied.last?.attenuation, 0)
    }

    func testAbxRefusesAnswerUntilXHeardOnceThenAcceptsReplays() throws {
        let player = FakePlayer(current: state(gain: 6))
        let clock = Clock()
        let service = try make(kind: .abx, player: player, clock: clock)
        service.select(.a)
        clock.now.addTimeInterval(1)
        service.refreshReadiness()
        service.select(.b)
        clock.now.addTimeInterval(1)
        service.refreshReadiness()
        XCTAssertFalse(service.canAnswer)
        service.answer(xIsB: true)
        XCTAssertEqual(service.completedTrials, 0)
        service.select(.x)
        clock.now.addTimeInterval(1)
        service.refreshReadiness()
        service.select(.a)
        clock.now.addTimeInterval(1)
        service.refreshReadiness()
        XCTAssertTrue(service.canAnswer)
        service.answer(xIsB: true)
        XCTAssertEqual(service.completedTrials, 1)
        XCTAssertFalse(service.heardX)
    }

    func testPreferenceHidesTheShuffleAndTalliesByCandidate() throws {
        let player = FakePlayer(current: state(gain: 6))
        let clock = Clock()
        // Trial labels: label A = candidate B for the first trial (swap true), then no swap, alternating.
        let service = try make(kind: .preference, player: player, clock: clock, assignments: [false, true, false, true, false, true, false, true, false, true, false], initial: true)
        var preferredCandidateB = 0
        for trial in 0..<12 {
            let swap = trial % 2 == 0
            service.select(.a)
            clock.now.addTimeInterval(1)
        service.refreshReadiness()
            XCTAssertFalse(service.canAnswer, "both labels must be heard")
            service.select(.b)
            clock.now.addTimeInterval(1)
        service.refreshReadiness()
            XCTAssertTrue(service.canAnswer)
            // Always choose the side that is candidate B (processing off): label B when not swapped, label A when swapped.
            let labelB = !swap
            service.answer(xIsB: labelB)
            preferredCandidateB += 1
        }
        XCTAssertEqual(service.phase, .finished)
        let result = try XCTUnwrap(service.preferenceResult)
        XCTAssertEqual(result.preferredB, preferredCandidateB)
        XCTAssertEqual(result.preferredA, 0)
        XCTAssertLessThan(result.pValue, 0.05)
    }

    func testPreferenceFirstLabelMapsToTheShuffledCandidate() throws {
        let player = FakePlayer(current: state(gain: 6))
        let swapped = try make(kind: .preference, player: player, initial: true)
        swapped.select(.a)
        XCTAssertEqual(player.applied.last?.state, candidates(state(gain: 6))[1].state, "swap: label A plays candidate B")
        let player2 = FakePlayer(current: state(gain: 6))
        let straight = try make(kind: .preference, player: player2, initial: false)
        straight.select(.a)
        XCTAssertEqual(player2.applied.last?.state, state(gain: 6))
    }

    func testStopAndOutputChangeEndTheTestAndRestore() throws {
        let player = FakePlayer(current: state(gain: 6))
        let service = try make(kind: .abx, player: player)
        service.select(.b)
        player.unavailableReason = "Playback stopped."
        service.refreshReadiness()
        XCTAssertEqual(service.phase, .ended("Playback stopped."))
        XCTAssertEqual(player.applied.last?.state, state(gain: 6))
        XCTAssertEqual(player.applied.last?.attenuation, 0)
    }

    func testEngineRefusalIsShownAndDoesNotChangeSelection() throws {
        let player = FakePlayer(current: state(gain: 6))
        let service = try make(kind: .abx, player: player)
        player.failApply = true
        service.select(.a)
        XCTAssertNil(service.selection)
        XCTAssertEqual(service.message, "refused")
    }

    // MARK: Statistics (known values)

    func testNeededCorrectTableMatchesKnownBinomialValues() {
        XCTAssertEqual(BlindComparisonStatistics.neededCorrect(trials: 12), 10)
        XCTAssertEqual(BlindComparisonStatistics.neededCorrect(trials: 16), 12)
        XCTAssertEqual(BlindComparisonStatistics.neededCorrect(trials: 24), 17)
        XCTAssertEqual(BlindComparisonStatistics.neededPreferences(trials: 12), 10)
        XCTAssertEqual(BlindComparisonStatistics.neededPreferences(trials: 16), 13)
        XCTAssertEqual(BlindComparisonStatistics.neededPreferences(trials: 24), 18)
    }

    func testSignTestKnownValues() {
        // 12 of 12: 2 * 0.5^12.
        XCTAssertEqual(BlindComparisonStatistics.signTestPValue(preferred: 12, trials: 12), 2 / 4096.0, accuracy: 1e-12)
        XCTAssertEqual(BlindComparisonStatistics.signTestPValue(preferred: 6, trials: 12), 1, accuracy: 1e-12)
        // Symmetric: 3 of 12 equals 9 of 12.
        XCTAssertEqual(
            BlindComparisonStatistics.signTestPValue(preferred: 3, trials: 12),
            BlindComparisonStatistics.signTestPValue(preferred: 9, trials: 12), accuracy: 1e-15)
        XCTAssertEqual(BlindComparisonStatistics.signTestPValue(preferred: 9, trials: 12), 2 * 299 / 4096.0, accuracy: 1e-12)
    }

    func testGuidanceNamesTheNeededCountAndRepeatRule() {
        let text = BlindComparisonStatistics.guidance(kind: .abx, trials: 16)
        XCTAssertTrue(text.contains("at least 12"))
        XCTAssertTrue(text.contains("Repeating a test until it passes does not count"))
    }

    // MARK: Before and after (G9)

    func testBeforeAfterTrimsTheLouderSideSwitchesAndRestores() throws {
        let player = FakePlayer(current: state(gain: 6))
        let clock = Clock()
        let model = BeforeAfterModel(player: player, clock: { clock.now })
        model.show(.before)
        XCTAssertEqual(model.side, .before)
        XCTAssertNotNil(model.levelSummary)
        XCTAssertEqual(player.applied.last?.state, candidates(state(gain: 6))[1].state)
        XCTAssertTrue(model.isSwitching)
        model.show(.after)
        XCTAssertEqual(model.side, .before, "a switch inside the fixed hold is ignored")
        clock.now.addTimeInterval(1)
        model.show(.after)
        XCTAssertEqual(model.side, .after)
        XCTAssertEqual(player.applied.last?.state, state(gain: 6))
        XCTAssertLessThan(try XCTUnwrap(player.applied.last?.attenuation), 0)
        model.done()
        XCTAssertNil(model.side)
        XCTAssertEqual(player.applied.last?.attenuation, 0)
        XCTAssertEqual(player.applied.last?.state, state(gain: 6))
    }

    func testBeforeAfterEndsWhenPlaybackStopsAndRefusesWhenNothingProcesses() throws {
        let player = FakePlayer(current: state(gain: 6))
        let model = BeforeAfterModel(player: player)
        model.show(.before)
        player.unavailableReason = "Start playback with music to compare by ear."
        model.refresh()
        XCTAssertNil(model.side)
        XCTAssertEqual(model.message, "Start playback with music to compare by ear.")
        let idle = FakePlayer(current: candidates(state())[1].state)
        let flat = BeforeAfterModel(player: idle)
        flat.show(.before)
        XCTAssertNil(flat.side)
        XCTAssertEqual(flat.message, BlindLiveComparisonError.identicalSides.errorDescription)
    }

    func testRemoteSlotAndRequestFlow() {
        XCTAssertTrue(RemoteSlot.beforeAfter.isFilled)
        let request = BlindListeningRequest()
        request.request()
        XCTAssertTrue(request.pending)
        request.take()
        XCTAssertFalse(request.pending)
    }
}
