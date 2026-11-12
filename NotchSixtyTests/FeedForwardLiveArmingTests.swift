import XCTest
@testable import NotchSixty

/// E4 S25 arming: user-initiated only, slow fade-in after the checks, any change returns to off.
@MainActor
final class FeedForwardLiveArmingTests: XCTestCase {
    private final class Engine: FeedForwardLiveArmingEngine {
        var armCode: UInt32? = UInt32(N60FeedForwardLiveArmOK)
        var armCalls = 0
        var disarmCalls = 0
        var kernel: FeedForwardLiveKernelFacts? = FeedForwardLiveKernelFacts(state: .idle, gain: 0)
        var lastGate: FeedForwardLiveArmGate.Inputs?
        func armFeedForwardLive(gate: FeedForwardLiveArmGate.Inputs) -> UInt32? {
            armCalls += 1
            lastGate = gate
            if armCode == UInt32(N60FeedForwardLiveArmOK) { kernel = .init(state: .armed, gain: 0) }
            return armCode
        }
        func disarmFeedForwardLive() {
            disarmCalls += 1
            kernel = .init(state: .idle, gain: 0)
        }
        func feedForwardLiveKernelFacts() -> FeedForwardLiveKernelFacts? { kernel }
    }

    private var now = 100.0
    private var shadow = FeedForwardLiveShadowFacts(
        stability: .passed(loopGain: 0.2), verifiedRemovalDecibels: 25,
        referenceRunning: true, pumpDelaySeconds: 0.020)

    private func budget(preview: Double = 0.030, path: Double = 0.004) -> QuietZoneFeedForwardBudget {
        var b = QuietZoneFeedForwardBudget.missing
        b.readiness = .physicallyPlausible
        b.conservativePreviewSeconds = preview
        b.antiNoisePathSeconds = path
        b.runtimeAvailable = true
        return b
    }

    private func facts(
        armed: Bool = true, baseline: Bool = true, verdict: DoNoHarmVerdict = .ok, lease: Bool = true,
        uid: String? = "dac", rate: Double? = 48_000, budget: QuietZoneFeedForwardBudget? = nil,
        subwoofer: Bool = false
    ) -> FeedForwardLiveQuietZoneFacts {
        FeedForwardLiveQuietZoneFacts(
            armed: armed, hasBaseline: baseline, verdict: verdict, leaseRequired: true, leaseHealthy: lease,
            outputDeviceUID: uid, sampleRate: rate, budget: budget ?? self.budget(),
            subwooferActive: subwoofer)
    }

    private func make() -> (FeedForwardLiveArmingController, Engine) {
        let engine = Engine()
        let c = FeedForwardLiveArmingController(
            engine: engine, shadowFacts: { [unowned self] in self.shadow }, clock: { [unowned self] in self.now })
        return (c, engine)
    }

    func testRequestRefusedUnlessQuietZoneArmed() {
        let (c, engine) = make()
        XCTAssertFalse(c.request(quietZone: facts(armed: false)))
        XCTAssertEqual(c.phase, .off)
        XCTAssertEqual(engine.armCalls, 0)
    }

    func testNothingArmsWithoutARequest() {
        let (c, engine) = make()
        for _ in 0..<5 { c.poll(quietZone: facts()) }
        XCTAssertEqual(engine.armCalls, 0)
        XCTAssertEqual(c.phase, .off)
    }

    func testWaitsForBaselineVerdictLeaseAndLead() {
        let (c, engine) = make()
        XCTAssertTrue(c.request(quietZone: facts(baseline: false)))
        XCTAssertEqual(engine.armCalls, 0)
        c.poll(quietZone: facts(baseline: true, verdict: .baselining)); XCTAssertEqual(engine.armCalls, 0)
        c.poll(quietZone: facts(lease: false)); XCTAssertEqual(engine.armCalls, 0)
        // lead 0.030 - 0.020 delay = 0.010 against 0.004 + 0.002 required: passes; shrink it.
        c.poll(quietZone: facts(budget: budget(preview: 0.024))); XCTAssertEqual(engine.armCalls, 0)
        guard case .waiting = c.phase else { return XCTFail("expected waiting") }
        c.poll(quietZone: facts())
        XCTAssertEqual(engine.armCalls, 1)
        XCTAssertEqual(c.phase, .fadingIn)
        XCTAssertEqual(engine.lastGate?.leadSeconds ?? 0, 0.010, accuracy: 1e-9)
    }

    func testFadeInThenLive() {
        let (c, engine) = make()
        XCTAssertTrue(c.request(quietZone: facts()))
        XCTAssertEqual(c.phase, .fadingIn)
        engine.kernel = .init(state: .armed, gain: 0.5)
        c.poll(quietZone: facts())
        XCTAssertEqual(c.phase, .fadingIn)
        XCTAssertEqual(c.fadeProgress, 0.5, accuracy: 1e-6)
        engine.kernel = .init(state: .armed, gain: 1)
        c.poll(quietZone: facts())
        XCTAssertEqual(c.phase, .live)
    }

    func testEveryChangeReturnsToOffAndStaysOff() {
        let cases: [(String, FeedForwardLiveQuietZoneFacts, () -> Void)] = [
            ("disarmed", facts(armed: false), {}),
            ("device", facts(uid: "other"), {}),
            ("rate", facts(rate: 96_000), {}),
            ("lease", facts(lease: false), {}),
            ("harm", facts(verdict: .harm(frequencyHz: 50, increaseDB: 5)), {}),
            ("baseline", facts(baseline: false), {}),
        ]
        for (name, bad, _) in cases {
            let (c, engine) = make()
            XCTAssertTrue(c.request(quietZone: facts()), name)
            c.poll(quietZone: bad)
            XCTAssertEqual(c.phase, .off, name)
            XCTAssertGreaterThanOrEqual(engine.disarmCalls, 1, name)
            XCTAssertNotNil(c.statusMessage, name)
            // Conditions are good again: it must not come back by itself.
            let before = engine.armCalls
            for _ in 0..<5 { c.poll(quietZone: facts()) }
            XCTAssertEqual(engine.armCalls, before, name)
            XCTAssertEqual(c.phase, .off, name)
        }
    }

    func testReferenceStabilityAndKernelTripsGoOff() {
        let (c, engine) = make()
        XCTAssertTrue(c.request(quietZone: facts()))
        shadow.referenceRunning = false
        c.poll(quietZone: facts())
        XCTAssertEqual(c.phase, .off)

        shadow.referenceRunning = true
        XCTAssertTrue(c.request(quietZone: facts()))
        shadow.stability = .refused("loop")
        c.poll(quietZone: facts())
        XCTAssertEqual(c.phase, .off)

        shadow.stability = .passed(loopGain: 0.2)
        XCTAssertTrue(c.request(quietZone: facts()))
        engine.kernel = .init(state: .tripped(UInt32(N60FeedForwardLiveTripReferenceLost)), gain: 0)
        c.poll(quietZone: facts())
        XCTAssertEqual(c.phase, .off)
        XCTAssertTrue(c.statusMessage?.contains("reference lost") == true)
    }

    func testUserCancelAndQuietZoneStopTurnOff() {
        let (c, engine) = make()
        XCTAssertTrue(c.request(quietZone: facts()))
        c.cancel()
        XCTAssertEqual(c.phase, .off)
        XCTAssertNil(c.statusMessage)
        XCTAssertEqual(engine.disarmCalls, 1)
        XCTAssertTrue(c.request(quietZone: facts()))
        c.quietZoneStopped()
        XCTAssertEqual(c.phase, .off)
        XCTAssertEqual(engine.disarmCalls, 2)
    }

    func testWaitTimesOutAndEngineRefusalKeepsWaiting() {
        let (c, engine) = make()
        engine.armCode = UInt32(N60FeedForwardLiveArmNoWeights)
        XCTAssertTrue(c.request(quietZone: facts()))
        guard case .waiting = c.phase else { return XCTFail("expected waiting") }
        now += FeedForwardLiveArmingPolicy.maximumWaitSeconds + 1
        c.poll(quietZone: facts())
        XCTAssertEqual(c.phase, .off)
        XCTAssertTrue(c.statusMessage?.contains("did not start") == true)
    }

    func testStrayArmedKernelIsBackedOutWhileOff() {
        let (c, engine) = make()
        engine.kernel = .init(state: .armed, gain: 0.3)
        c.poll(quietZone: facts())
        XCTAssertEqual(engine.disarmCalls, 1)
    }

    // MARK: - E4 S35 turn-on guards (fakes only; nothing here arms a real filter)

    /// Wake, device change and rate change while the filter is armed and live leave it off, back the
    /// kernel out, and nothing brings it back until the user asks again.
    func testWakeDeviceChangeAndRateChangeWhileArmedLeaveItOff() {
        // A wake shows up as the engine safety lease lapsing and the transport being rebuilt on the
        // same or a new device; the three shapes are covered here.
        let cases: [(String, FeedForwardLiveQuietZoneFacts)] = [
            ("wake: lease lapsed", facts(lease: false)),
            ("wake: Quiet Zone disarmed", facts(armed: false)),
            ("device change", facts(uid: "other-dac")),
            ("device vanished", facts(uid: nil)),
            ("rate change 48 to 96 kHz", facts(rate: 96_000)),
            ("rate change 48 to 384 kHz", facts(rate: 384_000)),
            ("rate unknown after rebuild", facts(rate: nil)),
        ]
        for (name, bad) in cases {
            let (c, engine) = make()
            XCTAssertTrue(c.request(quietZone: facts()), name)
            engine.kernel = .init(state: .armed, gain: 1)
            c.poll(quietZone: facts())
            XCTAssertEqual(c.phase, .live, name)
            let disarmsBefore = engine.disarmCalls
            c.poll(quietZone: bad)
            XCTAssertEqual(c.phase, .off, name)
            XCTAssertGreaterThan(engine.disarmCalls, disarmsBefore, name)
            XCTAssertEqual(engine.kernel?.state, .idle, name)
            XCTAssertNotNil(c.statusMessage, name)
            let armsBefore = engine.armCalls
            for _ in 0..<10 { c.poll(quietZone: facts()) }
            XCTAssertEqual(engine.armCalls, armsBefore, "\(name): must not come back by itself")
            XCTAssertEqual(c.phase, .off, name)
        }
    }

    func testSystemWakeStopsQuietZoneAndLeavesFeedForwardOff() {
        let (c, engine) = make()
        XCTAssertTrue(c.request(quietZone: facts()))
        engine.kernel = .init(state: .armed, gain: 0.4)
        c.quietZoneStopped()
        XCTAssertEqual(c.phase, .off)
        XCTAssertEqual(engine.kernel?.state, .idle)
        let armsBefore = engine.armCalls
        for _ in 0..<5 { c.poll(quietZone: facts()) }
        XCTAssertEqual(engine.armCalls, armsBefore)
        XCTAssertEqual(c.phase, .off)
    }

    /// Bass management (a subwoofer in the arrangement): Turn On is refused with the subwoofer
    /// reason before any engine call, at every standard rate.
    func testBassManagementRefusesTurnOnWithTheSubwooferReason() {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let (c, engine) = make()
            XCTAssertFalse(c.request(quietZone: facts(rate: rate, subwoofer: true)), "\(rate)")
            XCTAssertEqual(c.phase, .off, "\(rate)")
            XCTAssertEqual(c.statusMessage, "Feed-forward is not available with a subwoofer yet.", "\(rate)")
            XCTAssertEqual(engine.armCalls, 0, "\(rate)")
            c.poll(quietZone: facts(rate: rate, subwoofer: true))
            XCTAssertEqual(engine.armCalls, 0, "\(rate)")
            XCTAssertEqual(c.phase, .off, "\(rate)")
        }
    }

    // MARK: - E4 S22b3 live echo stage

    func testRefusedWithASubwooferAndTurnsOffIfOneAppears() {
        let (c, engine) = make()
        XCTAssertFalse(c.request(quietZone: facts(subwoofer: true)))
        XCTAssertEqual(c.phase, .off)
        XCTAssertTrue(c.statusMessage?.contains("subwoofer") == true)
        XCTAssertTrue(c.request(quietZone: facts()))
        c.poll(quietZone: facts(subwoofer: true))
        XCTAssertEqual(c.phase, .off)
        XCTAssertGreaterThan(engine.disarmCalls, 0)
    }

    func testWaitsForTheLiveStageToLockBeforeArming() {
        let (c, engine) = make()
        shadow.verifiedRemovalDecibels = nil
        XCTAssertTrue(c.request(quietZone: facts()))
        c.poll(quietZone: facts())
        XCTAssertEqual(engine.armCalls, 0)
        XCTAssertEqual(c.phase, .waiting("play music for a few seconds so echo removal can lock"))
        shadow.verifiedRemovalDecibels = 12
        c.poll(quietZone: facts())
        XCTAssertEqual(engine.armCalls, 0, "under 20 dB is not enough")
        shadow.verifiedRemovalDecibels = 25
        c.poll(quietZone: facts())
        XCTAssertEqual(engine.armCalls, 1)
    }

    func testStaleRemovalForTenSecondsOfProgrammeTurnsOff() {
        let (c, engine) = make()
        XCTAssertTrue(c.request(quietZone: facts()))
        engine.kernel = .init(state: .armed, gain: 1)
        shadow.verifiedRemovalDecibels = 6
        shadow.removalProgrammeSeconds = 10
        c.poll(quietZone: facts())
        XCTAssertNotEqual(c.phase, .off, "the first reading only sets the baseline")
        shadow.removalProgrammeSeconds = 15
        c.poll(quietZone: facts())
        XCTAssertNotEqual(c.phase, .off)
        shadow.verifiedRemovalDecibels = 14  // recovered: the count restarts
        shadow.removalProgrammeSeconds = 18
        c.poll(quietZone: facts())
        shadow.verifiedRemovalDecibels = 6
        shadow.removalProgrammeSeconds = 27
        c.poll(quietZone: facts())
        XCTAssertNotEqual(c.phase, .off)
        shadow.removalProgrammeSeconds = 29
        c.poll(quietZone: facts())
        XCTAssertEqual(c.phase, .off)
        XCTAssertTrue(c.statusMessage?.contains("measure leakage again") == true)
    }

    func testEchoTripsHaveWords() {
        XCTAssertEqual(FeedForwardLiveOffReason.tripText(UInt32(N60FeedForwardLiveTripEchoAlignmentLost)), "echo removal lost alignment")
        XCTAssertEqual(FeedForwardLiveOffReason.tripText(UInt32(N60FeedForwardLiveTripEchoDiverged)), "echo removal diverged")
    }

    func testShadowFactsTrustOnlyALockedStageWithFiveSecondsOfProgramme() {
        func facts(state: UInt32, seconds: Double, before: Double = 100, after: Double = 1) -> FeedForwardLiveShadowFacts {
            var live = N60FeedForwardLiveEchoStatus()
            live.state = state
            live.programmeSeconds = seconds
            live.bandBeforePower = before
            live.bandAfterPower = after
            return FeedForwardLiveShadowFacts(
                stability: .passed(loopGain: 0.2), live: live, referenceRunning: true, pumpDelaySeconds: 0.02)
        }
        XCTAssertEqual(facts(state: UInt32(N60FeedForwardLiveEchoLocked), seconds: 6).verifiedRemovalDecibels ?? 0, 20, accuracy: 1e-9)
        XCTAssertNil(facts(state: UInt32(N60FeedForwardLiveEchoLocked), seconds: 4).verifiedRemovalDecibels)
        XCTAssertNil(facts(state: UInt32(N60FeedForwardLiveEchoOff), seconds: 60).verifiedRemovalDecibels)
        XCTAssertNil(facts(state: UInt32(N60FeedForwardLiveEchoLocked), seconds: 6, after: 0).verifiedRemovalDecibels)
        let none = FeedForwardLiveShadowFacts(
            stability: .passed(loopGain: 0.2), live: nil, referenceRunning: true, pumpDelaySeconds: 0.02)
        XCTAssertNil(none.verifiedRemovalDecibels)
    }
}
