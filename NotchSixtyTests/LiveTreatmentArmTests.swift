import Foundation
import XCTest
@testable import NotchSixty

/// Owner decision, 27 Oct 2026: live ANC / MIMO output is decided by a per-feature ARM switch
/// plus always-on safeguards (cap, ramps, auto-disarm, trip latch). These tests are behavioural:
/// the arm state machine, the engine's cap, and the real tone synthesiser's ramp shapes.
@MainActor
final class LiveTreatmentArmTests: XCTestCase {
    private static let standardRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func environment(
        output: String? = "out-1",
        rate: Double? = 48_000,
        running: Bool = true,
        input: Bool = true,
        level: Double? = nil
    ) -> LiveTreatmentEnvironment {
        LiveTreatmentEnvironment(
            outputDeviceUID: output, sampleRate: rate, engineRunning: running,
            inputAvailable: input, microphoneLevelDBFS: level)
    }

    private func armed(rate: Double = 48_000) throws -> LiveTreatmentArm {
        let arm = LiveTreatmentArm(feature: .quietZone)
        try arm.arm(environment: environment(rate: rate))
        return arm
    }

    // MARK: Arm state machine

    func testEveryFeatureStartsDisarmedAndCannotPlay() {
        for feature in LiveTreatmentFeature.allCases {
            let arm = LiveTreatmentArm(feature: feature)
            XCTAssertFalse(arm.isArmed, "\(feature) must start disarmed on every launch")
            XCTAssertNil(arm.lastDisarmReason)
            XCTAssertFalse(arm.latchedByEvent)
        }
        XCTAssertFalse(AdaptiveQuietZoneOutputPolicy.mayPlay(LiveTreatmentArm(feature: .quietZone)))
    }

    func testArmingIsOneExplicitActionAndNeedsARunningEngine() throws {
        let arm = LiveTreatmentArm(feature: .quietZone)
        XCTAssertThrowsError(try arm.arm(environment: environment(running: false)))
        XCTAssertThrowsError(try arm.arm(environment: environment(rate: nil)))
        XCTAssertThrowsError(try arm.arm(environment: environment(output: nil)))
        XCTAssertFalse(arm.isArmed)
        try arm.arm(environment: environment())
        XCTAssertTrue(arm.isArmed)
        XCTAssertTrue(AdaptiveQuietZoneOutputPolicy.mayPlay(arm))
    }

    func testUserDisarmFiresOnceAndDoesNotLatch() throws {
        let arm = try armed()
        var reasons: [LiveTreatmentDisarmReason] = []
        arm.onDisarm = { reasons.append($0) }
        arm.disarm(.user)
        arm.disarm(.user)
        XCTAssertEqual(reasons, [.user])
        XCTAssertFalse(arm.isArmed)
        XCTAssertFalse(arm.latchedByEvent)
        XCTAssertNil(arm.statusMessage)
    }

    func testEveryAutomaticTriggerDisarmsAtEveryStandardRate() throws {
        for rate in Self.standardRates {
            let cases: [(String, LiveTreatmentEnvironment, LiveTreatmentDisarmReason)] = [
                ("device changed", environment(output: "out-2", rate: rate), .outputDeviceChanged),
                ("device lost", environment(output: nil, rate: rate), .outputDeviceLost),
                ("rate changed", environment(rate: rate == 48_000 ? 96_000 : 48_000), .sampleRateChanged),
                ("input lost", environment(rate: rate, input: false), .inputLost),
                ("engine stopped", environment(rate: rate, running: false), .engineStopped),
                ("no transport", environment(rate: nil), .engineStopped),
                ("NaN mic", environment(rate: rate, level: .nan), .microphoneInvalid),
                ("inf mic", environment(rate: rate, level: .infinity), .microphoneInvalid),
            ]
            for (name, env, expected) in cases {
                let arm = try armed(rate: rate)
                var fired: [LiveTreatmentDisarmReason] = []
                arm.onDisarm = { fired.append($0) }
                arm.observe(env, now: t0)
                XCTAssertFalse(arm.isArmed, "\(name) @\(rate)")
                XCTAssertEqual(fired, [expected], "\(name) @\(rate)")
                XCTAssertNotNil(arm.statusMessage)
            }
            // A healthy environment never disarms.
            let healthy = try armed(rate: rate)
            healthy.observe(environment(rate: rate, level: -40), now: t0)
            XCTAssertTrue(healthy.isArmed)
        }
    }

    func testSilentMicrophoneDisarmsOnlyAfterTheTimerAndResetsOnSignal() throws {
        let arm = try armed()
        let silent = environment(level: -.infinity)
        arm.observe(silent, now: t0)
        arm.observe(silent, now: t0.addingTimeInterval(LiveTreatmentSafeguards.silentMicrophoneSeconds - 0.5))
        XCTAssertTrue(arm.isArmed, "short silence is tolerated")
        arm.observe(environment(level: -50), now: t0.addingTimeInterval(4.9))
        arm.observe(silent, now: t0.addingTimeInterval(5.0))
        arm.observe(silent, now: t0.addingTimeInterval(9.0))
        XCTAssertTrue(arm.isArmed, "signal restarted the timer")
        arm.observe(silent, now: t0.addingTimeInterval(10.1))
        XCTAssertFalse(arm.isArmed)
        XCTAssertEqual(arm.lastDisarmReason, .microphoneInvalid)
    }

    func testTripLatchesDisarmedUntilTheUserRearms() throws {
        let arm = try armed()
        arm.reportInstabilityTrip()
        XCTAssertFalse(arm.isArmed)
        XCTAssertTrue(arm.latchedByEvent)
        XCTAssertEqual(arm.lastDisarmReason, .instabilityTrip)
        for _ in 0..<20 { arm.observe(environment(level: -30), now: t0) }
        XCTAssertFalse(arm.isArmed, "a healthy environment never re-arms by itself")
        arm.transportTornDown(.plannedProfileChange)
        XCTAssertFalse(arm.isArmed)
        try arm.arm(environment: environment())
        XCTAssertTrue(arm.isArmed)
        XCTAssertNil(arm.lastDisarmReason, "re-arming clears the latch")
    }

    func testEngineTeardownCausesMapToDisarmReasons() throws {
        let expected: [(TransportTeardownCause, LiveTreatmentDisarmReason?)] = [
            (.stop, .engineStopped), (.quit, .quit), (.sleep, .sleep), (.outputLost, .outputDeviceLost),
            (.reconfiguration, .transportReconfigured), (.other, .engineStopped),
            (.plannedProfileChange, nil),
        ]
        for (cause, reason) in expected {
            let arm = try armed()
            arm.transportTornDown(cause)
            if let reason {
                XCTAssertEqual(arm.lastDisarmReason, reason)
                XCTAssertFalse(arm.isArmed)
            } else {
                XCTAssertTrue(arm.isArmed, "the app's own profile switch must not disarm")
            }
        }
    }

    // MARK: Cap

    func testPeakCapIsConservativeAndBoundedByTheHardMaximum() {
        XCTAssertEqual(LiveTreatmentSafeguards.defaultPeakCapDBFS, -40)
        XCTAssertLessThan(
            LiveTreatmentSafeguards.defaultPeakCapDBFS,
            ActiveQuietZoneConfiguration().maximumAggregateSourcePeakDBFS - 20)
        XCTAssertEqual(LiveTreatmentSafeguards.clampedPeakCapDBFS(0), LiveTreatmentSafeguards.hardMaximumPeakCapDBFS)
        XCTAssertEqual(LiveTreatmentSafeguards.clampedPeakCapDBFS(-3), LiveTreatmentSafeguards.hardMaximumPeakCapDBFS)
        XCTAssertEqual(LiveTreatmentSafeguards.clampedPeakCapDBFS(-200), -120)
        XCTAssertEqual(LiveTreatmentSafeguards.clampedPeakCapDBFS(.nan), LiveTreatmentSafeguards.defaultPeakCapDBFS)
        let cap = LiveTreatmentSafeguards.linearPeak(dbfs: -40)
        XCTAssertEqual(LiveTreatmentSafeguards.limitedInjectionPeak(0.5), cap, accuracy: 1e-12)
        XCTAssertEqual(LiveTreatmentSafeguards.limitedInjectionPeak(0.001), 0.001, accuracy: 1e-12)
        XCTAssertEqual(LiveTreatmentSafeguards.limitedInjectionPeak(.nan), 0)
        XCTAssertEqual(LiveTreatmentSafeguards.limitedInjectionPeak(-1), 0)
        // Even an absurd requested cap cannot exceed the hard maximum.
        XCTAssertLessThanOrEqual(
            LiveTreatmentSafeguards.limitedInjectionPeak(1, capDBFS: 20),
            LiveTreatmentSafeguards.linearPeak(dbfs: LiveTreatmentSafeguards.hardMaximumPeakCapDBFS) + 1e-12)
    }

    func testEnginePeakIsCappedBelowTheFormerAggregateLimit() throws {
        let engine = AudioIOEngine()
        let available = engine.activeQuietZoneAvailableInjectionPeak
        XCTAssertLessThanOrEqual(available, LiveTreatmentSafeguards.linearPeak(dbfs: -40) + 1e-12)
        let former = try ActiveQuietZonePlanner().availableInjectionPeak(
            headroomAttenuationDB: 0, ambientLevelRecoveryDB: 0, configuration: ActiveQuietZoneConfiguration())
        XCTAssertLessThanOrEqual(available, former)
    }

    // MARK: Ramps, through the real tone synthesiser

    private func synthesise(
        rate: Double,
        peak: Float,
        rampMilliseconds: Double
    ) -> [Float] {
        var snapshot = N60ActiveQuietZoneSnapshotMakeBypassed()
        var tone = N60ActiveQuietZoneToneSnapshot()
        tone.frequencyHz = 60
        tone.leftReal = peak
        let frames = UInt32((rate * rampMilliseconds / 1_000).rounded())
        XCTAssertTrue(N60ActiveQuietZoneSnapshotSet(&snapshot, &tone, 1, frames, rate, true))
        var runtime = N60ActiveQuietZoneRuntime()
        N60ActiveQuietZoneRuntimeReset(&runtime, rate)
        XCTAssertTrue(N60ActiveQuietZoneRuntimeSchedule(&runtime, &snapshot, rate))
        var out = [Float](repeating: 0, count: Int(frames) + Int(rate / 10))
        for i in out.indices {
            var left: Float = 0
            var right: Float = 0
            N60ActiveQuietZoneRuntimeProcessFrame(&runtime, &left, &right)
            out[i] = left
        }
        return out
    }

    private func blockPeaks(_ signal: [Float], rate: Double) -> [Float] {
        let block = max(1, Int(rate / 60))  // one period of the 60 Hz tone
        return stride(from: 0, to: signal.count - block + 1, by: block).map { start in
            signal[start..<start + block].map { abs($0) }.max() ?? 0
        }
    }

    func testStartRampIsSecondsLongMonotoneAndNeverExceedsTheCapAtEveryRate() {
        let cap = Float(LiveTreatmentSafeguards.linearPeak(dbfs: LiveTreatmentSafeguards.defaultPeakCapDBFS))
        XCTAssertGreaterThanOrEqual(LiveTreatmentSafeguards.startRampMilliseconds, 3_000)
        for rate in Self.standardRates {
            let signal = synthesise(rate: rate, peak: cap, rampMilliseconds: LiveTreatmentSafeguards.startRampMilliseconds)
            XCTAssertLessThanOrEqual(signal.map { abs($0) }.max() ?? 0, cap * 1.001, "cap @\(rate)")
            let peaks = blockPeaks(signal, rate: rate)
            for (a, b) in zip(peaks, peaks.dropFirst()) {
                XCTAssertLessThanOrEqual(a, b + cap * 0.02, "ramp rises monotonically @\(rate)")
            }
            XCTAssertLessThan(peaks[0], cap * 0.05, "starts from silence @\(rate)")
            XCTAssertGreaterThan(peaks[peaks.count - 2], cap * 0.95, "reaches the cap @\(rate)")
            // No step: the largest sample-to-sample change is the tone's own slope.
            var maxStep: Float = 0
            for i in 1..<signal.count { maxStep = max(maxStep, abs(signal[i] - signal[i - 1])) }
            let toneSlope = Float(2 * Double.pi * 60 / rate) * cap
            XCTAssertLessThanOrEqual(maxStep, toneSlope * 1.05, "no step @\(rate)")
            // The first half second is still below a quarter of the cap: it really is a slow fade-in.
            let halfSecond = Int(rate / 2)
            XCTAssertLessThan(signal[0..<halfSecond].map { abs($0) }.max() ?? 0, cap * 0.25, "slow start @\(rate)")
        }
    }

    func testStopRampFadesToSilenceWithoutAStepAtEveryRate() {
        let cap = Float(LiveTreatmentSafeguards.linearPeak(dbfs: LiveTreatmentSafeguards.defaultPeakCapDBFS))
        for rate in Self.standardRates {
            var snapshot = N60ActiveQuietZoneSnapshotMakeBypassed()
            var tone = N60ActiveQuietZoneToneSnapshot()
            tone.frequencyHz = 60
            tone.leftReal = cap
            XCTAssertTrue(N60ActiveQuietZoneSnapshotSet(&snapshot, &tone, 1, 4, rate, true))
            var runtime = N60ActiveQuietZoneRuntime()
            N60ActiveQuietZoneRuntimeReset(&runtime, rate)
            XCTAssertTrue(N60ActiveQuietZoneRuntimeSchedule(&runtime, &snapshot, rate))
            func run(_ frames: Int) -> [Float] {
                (0..<frames).map { _ in
                    var l: Float = 0
                    var r: Float = 0
                    N60ActiveQuietZoneRuntimeProcessFrame(&runtime, &l, &r)
                    return l
                }
            }
            _ = run(Int(rate / 20))
            var stop = N60ActiveQuietZoneSnapshotMakeBypassed()
            let stopFrames = UInt32((rate * LiveTreatmentSafeguards.stopRampMilliseconds / 1_000).rounded())
            XCTAssertTrue(N60ActiveQuietZoneSnapshotSet(&stop, nil, 0, stopFrames, rate, false))
            XCTAssertTrue(N60ActiveQuietZoneRuntimeSchedule(&runtime, &stop, rate))
            let faded = run(Int(stopFrames) + Int(rate / 20))
            let peaks = blockPeaks(faded, rate: rate)
            for (a, b) in zip(peaks, peaks.dropFirst()) {
                XCTAssertGreaterThanOrEqual(a + cap * 0.02, b, "fade is monotone @\(rate)")
            }
            XCTAssertEqual(faded.suffix(Int(rate / 100)).map { abs($0) }.max() ?? 1, 0, accuracy: cap * 0.01, "silent @\(rate)")
            var maxStep: Float = 0
            for i in 1..<faded.count { maxStep = max(maxStep, abs(faded[i] - faded[i - 1])) }
            XCTAssertLessThanOrEqual(maxStep, Float(2 * Double.pi * 60 / rate) * cap * 1.05, "no step @\(rate)")
        }
    }

    func testTripRampIsTheShortestTheEngineAccepts() throws {
        XCTAssertEqual(LiveTreatmentSafeguards.rampMilliseconds(for: .instabilityTrip), 20)
        XCTAssertEqual(LiveTreatmentSafeguards.rampMilliseconds(for: .user), LiveTreatmentSafeguards.stopRampMilliseconds)
        XCTAssertEqual(LiveTreatmentSafeguards.rampMilliseconds(for: .sleep), LiveTreatmentSafeguards.stopRampMilliseconds)
        // The engine's validator accepts the start, stop and trip ramps.
        for ms in [
            LiveTreatmentSafeguards.startRampMilliseconds, LiveTreatmentSafeguards.stopRampMilliseconds,
            LiveTreatmentSafeguards.tripRampMilliseconds,
        ] {
            XCTAssertNoThrow(try ActiveQuietZoneRuntimeTarget(tones: [], transitionMilliseconds: ms).validated())
        }
    }
}
