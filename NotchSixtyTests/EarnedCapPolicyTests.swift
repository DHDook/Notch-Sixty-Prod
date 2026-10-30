import XCTest
@testable import NotchSixty

/// E4 S20: the earned anti-noise cap. Pure control plane: no audio, no engine.
@MainActor
final class EarnedCapPolicyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EarnedCapTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let binding = EarnedCapBinding(outputDeviceUID: "out", inputDeviceUID: "in", sampleRate: 48_000)

    private func policy(armed: Bool = true, gain: Double = 0) -> EarnedCapPolicy {
        let p = EarnedCapPolicy(store: EarnedCapStore(defaults: defaults))
        if armed { p.beginArm(binding: binding, outputGainDB: gain) }
        return p
    }

    private func facts(
        _ now: TimeInterval, p: EarnedCapPolicy, adapting: Bool = true, verdict: DoNoHarmVerdict = .ok,
        reduction: Double? = 6, increase: Double = 0, guardOrHold: Bool = false,
        capLimited: Bool = true, recovering: Bool = false
    ) -> EarnedCapPollFacts {
        EarnedCapPollFacts(
            now: now, adapting: adapting, verdict: verdict,
            measurement: DoNoHarmVerifier.Measurement(worstIncreaseDB: increase, minimumToneReductionDB: reduction),
            guardOrHold: guardOrHold,
            playedPeakLinear: capLimited ? p.capLinear : p.capLinear * 0.5,
            moveRecovering: recovering
        )
    }

    /// Qualifying polls once a second from `start`; returns the time after `seconds`.
    @discardableResult
    private func run(_ p: EarnedCapPolicy, from start: TimeInterval, seconds: Int) -> TimeInterval {
        var t = start
        for _ in 0 ... seconds { p.poll(facts(t, p: p)); t += 1 }
        return t
    }

    func testStartsAtFloorAndNoStepBeforeSixtySeconds() {
        let p = policy()
        XCTAssertEqual(p.capDBFS, -40)
        run(p, from: 0, seconds: 59)
        XCTAssertEqual(p.capDBFS, -40)
        p.poll(facts(60, p: p))
        XCTAssertEqual(p.capDBFS, -37)
    }

    func testAWarningAtFiftyNineSecondsRestartsTheTimer() {
        let p = policy()
        run(p, from: 0, seconds: 58)
        p.poll(facts(59, p: p, verdict: .warning))
        p.poll(facts(60, p: p))
        p.poll(facts(119, p: p))
        XCTAssertEqual(p.capDBFS, -40)
        p.poll(facts(120, p: p))
        XCTAssertEqual(p.capDBFS, -37)
    }

    func testEachDisqualifierBlocksTheStep() {
        let cases: [(String, (EarnedCapPolicy, TimeInterval) -> EarnedCapPollFacts)] = [
            ("not adapting", { self.facts($1, p: $0, adapting: false) }),
            ("baselining", { self.facts($1, p: $0, verdict: .baselining) }),
            ("small reduction", { self.facts($1, p: $0, reduction: 2.9) }),
            ("no tone", { self.facts($1, p: $0, reduction: nil) }),
            ("increase", { self.facts($1, p: $0, increase: 0.6) }),
            ("guard or hold", { self.facts($1, p: $0, guardOrHold: true) }),
            ("not cap limited", { self.facts($1, p: $0, capLimited: false) }),
            ("recovering", { self.facts($1, p: $0, recovering: true) }),
        ]
        for (name, make) in cases {
            let p = policy()
            for t in stride(from: 0.0, through: 200.0, by: 1.0) { p.poll(make(p, t)) }
            XCTAssertEqual(p.capDBFS, -40, name)
        }
    }

    func testTheClimbEndsExactlyAtMinus18AndNeverPasses() {
        let p = policy()
        var levels: [Double] = [p.capDBFS]
        var t = 0.0
        for _ in 0 ..< 1_000 {
            p.poll(facts(t, p: p)); t += 1
            if p.capDBFS != levels.last { levels.append(p.capDBFS) }
        }
        XCTAssertEqual(levels, [-40, -37, -34, -31, -28, -25, -22, -19, -18])
    }

    func testResetRulesCaseByCase() {
        for (reason, expected) in [
            (LiveTreatmentDisarmReason.seatRegression, -40.0), (.instabilityTrip, -40), (.adaptiveFault, -28),
            (.microphoneMoved, -28), (.user, -25), (.quit, -25), (.sleep, -25),
        ] {
            let p = policy()
            var t = 0.0
            while p.capDBFS < -25 { p.poll(facts(t, p: p)); t += 1 }
            p.noteDisarm(reason)
            let next = policy(armed: false)
            next.beginArm(binding: binding, outputGainDB: 0)
            XCTAssertEqual(next.capDBFS, expected, "\(reason)")
        }
    }

    func testGainToleranceRestoresOrStartsAtFloor() {
        let p = policy(gain: 0)
        var t = 0.0
        while p.capDBFS < -31 { p.poll(facts(t, p: p)); t += 1 }
        p.noteDisarm(.user)
        let near = policy(armed: false)
        near.beginArm(binding: binding, outputGainDB: 0.9)
        XCTAssertEqual(near.capDBFS, -31)
        let far = policy(armed: false)
        far.beginArm(binding: binding, outputGainDB: 1.1)
        XCTAssertEqual(far.capDBFS, -40)
        let other = policy(armed: false)
        other.beginArm(binding: EarnedCapBinding(outputDeviceUID: "out", inputDeviceUID: "in", sampleRate: 96_000), outputGainDB: 0)
        XCTAssertEqual(other.capDBFS, -40)
    }

    func testBindingChangeDropsToFloorWithinOnePollAndKeepsTheRecord() {
        let p = policy()
        var t = 0.0
        while p.capDBFS < -31 { p.poll(facts(t, p: p)); t += 1 }
        p.observe(binding: EarnedCapBinding(outputDeviceUID: "usb", inputDeviceUID: "in", sampleRate: 48_000), outputGainDB: 0)
        XCTAssertEqual(p.capDBFS, -40)
        let back = policy(armed: false)
        back.beginArm(binding: binding, outputGainDB: 0)
        XCTAssertEqual(back.capDBFS, -31)
    }

    func testMicMoveFreezesTheTimerAndRestartsItFromZeroAfterwards() {
        let p = policy()
        run(p, from: 0, seconds: 50)
        for t in 51 ... 200 { p.poll(facts(Double(t), p: p, recovering: true)) }
        XCTAssertEqual(p.capDBFS, -40)
        p.poll(facts(201, p: p))
        p.poll(facts(260, p: p))
        XCTAssertEqual(p.capDBFS, -40)
        p.poll(facts(261, p: p))
        XCTAssertEqual(p.capDBFS, -37)
    }

    func testStatusTextAndFlightEvents() {
        let p = policy()
        var events: [SafetyEventKind] = []
        p.onEvent = { kind, _ in events.append(kind) }
        XCTAssertEqual(p.statusText, "Anti-noise limit -40 dBFS")
        run(p, from: 0, seconds: 60)
        XCTAssertEqual(p.statusText, "Anti-noise limit -37 dBFS (earned)")
        XCTAssertEqual(events, [.cap])
    }
}

final class EarnedCapStoreTests: XCTestCase {
    func testRoundTripLRUBoundAndCorruptBlob() {
        let name = "EarnedCapStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = EarnedCapStore(defaults: defaults)
        for index in 0 ..< 40 {
            let binding = EarnedCapBinding(outputDeviceUID: "out\(index)", inputDeviceUID: "in", sampleRate: 48_000)
            store.save(EarnedCapRecord(binding: binding, earnedDBFS: -31, outputGainDB: 0, earnedAt: Date()))
        }
        XCTAssertEqual(store.records.count, EarnedCapStore.maximumRecords)
        let first = EarnedCapBinding(outputDeviceUID: "out0", inputDeviceUID: "in", sampleRate: 48_000)
        let last = EarnedCapBinding(outputDeviceUID: "out39", inputDeviceUID: "in", sampleRate: 48_000)
        XCTAssertNil(store.record(for: first))
        let reloaded = EarnedCapStore(defaults: defaults)
        XCTAssertEqual(reloaded.record(for: last)?.earnedDBFS, -31)
        defaults.set(Data("not json".utf8), forKey: PreferenceKeys.quietZoneEarnedCaps)
        XCTAssertTrue(EarnedCapStore(defaults: defaults).records.isEmpty)
    }
}
