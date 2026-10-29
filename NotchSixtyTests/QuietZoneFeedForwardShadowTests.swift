import Foundation
import XCTest
@testable import NotchSixty

/// E4 S9c: the feed-forward shadow on a simulated two-channel capture
/// (eight cases). The
/// seat hears the reference 12 ms later at 0.02; both speakers reach the seat
/// 4 ms after output at 0.8. The ideal filter is -0.0125 per speaker, 8 ms late.
@MainActor
final class QuietZoneFeedForwardShadowTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let disturbanceSeconds = 0.012
    private let disturbanceGain: Float = 0.02

    func testPlanSeedsFromTheOfflineDesignOrFromZeroAtEveryStandardRate() throws {
        let planner = QuietZoneFeedForwardShadowPlanner()
        for rate in rates {
            let designed = try inputs(rate: rate, design: true)
            let plan = try planner.plan(
                bands: designed.bands, design: designed.design, budget: designed.budget,
                position: designed.position, nativeSampleRate: rate
            )
            let fd = rate / Double(N60AncDecimationFactor(rate))
            XCTAssertEqual(plan.seedSource, .offlineDesign, "\(rate) Hz")
            XCTAssertEqual(plan.decimatedRate, fd)
            XCTAssertEqual(plan.seedLeft.count, QuietZoneCausalFIRCompiler.maximumTaps)
            XCTAssertTrue(plan.seedLeft.contains { $0 != 0 })
            // Onset 4 ms less the 1 ms margin.
            let onset = (0.004 * rate).rounded() / rate
            XCTAssertEqual(plan.leftPath.bulkDelay, Int(((onset - 0.001) * fd).rounded(.down)), "\(rate) Hz")
            XCTAssertFalse(plan.liveDeploymentAuthorized)

            // The seed itself predicts exactly the offline reduction.
            let seeded = QuietZoneFeedForwardShadowComparison.compare(
                plan: plan, shadowLeft: plan.seedLeft, shadowRight: plan.seedRight
            )
            XCTAssertEqual(seeded.bands.map(\.centreHz), QuietZoneFeedForwardShadowComparison.centresHz)
            for band in seeded.bands {
                let offline = try XCTUnwrap(band.offlineReductionDB)
                XCTAssertEqual(band.shadowReductionDB, offline, accuracy: 1e-9)
                XCTAssertGreaterThan(offline, QuietZoneVirtualSeatDesigner.minimumModeledReductionDB, "\(rate) Hz \(band.centreHz) Hz")
            }

            let undesigned = try inputs(rate: rate, design: false)
            let zero = try planner.plan(
                bands: undesigned.bands, design: nil, budget: undesigned.budget,
                position: undesigned.position, nativeSampleRate: rate
            )
            guard case .zeroWeights = zero.seedSource else { return XCTFail("\(rate) Hz: expected zero weights") }
            XCTAssertTrue(zero.seedLeft.allSatisfy { $0 == 0 })
            XCTAssertEqual(zero.leftPath, plan.leftPath, "\(rate) Hz: the same fitted path either way")
            let none = QuietZoneFeedForwardShadowComparison.compare(
                plan: zero, shadowLeft: zero.seedLeft, shadowRight: zero.seedRight
            )
            XCTAssertTrue(none.bands.allSatisfy { abs($0.shadowReductionDB) < 1e-9 && $0.offlineReductionDB == nil })
        }
    }

    /// From zero weights (no design before E22's bench timing), the shadow
    /// learns the band reduction target at every rate.
    func testShadowLearnsTheTargetReductionFromZeroAtEveryStandardRate() async throws {
        for rate in rates {
            let capture = SimulatedFeedForwardPair(
                sampleRate: rate, delayFrames: Int((disturbanceSeconds * rate).rounded()), gain: disturbanceGain
            )
            let shadow = QuietZoneFeedForwardShadow(captureFactory: { _ in capture }, deviceRate: { _ in nil }, pollsAutomatically: false)
            shadow.update(inputs: try inputs(rate: rate, design: false), reason: "")
            shadow.setActive(true)
            for _ in 0..<8 {
                capture.produce(seconds: 1)
                await shadow.tick()
            }
            let status = shadow.status
            XCTAssertEqual(status.state, .adapting, "\(rate) Hz")
            XCTAssertTrue(capture.started)
            guard case .zeroWeights = status.seedSource else { return XCTFail("\(rate) Hz: expected zero weights") }
            XCTAssertEqual(status.comparison.bands.count, QuietZoneFeedForwardShadowComparison.centresHz.count)
            for band in status.comparison.bands {
                XCTAssertGreaterThanOrEqual(
                    band.shadowReductionDB, QuietZoneFeedForwardShadowComparison.targetReductionDB,
                    "\(rate) Hz at \(band.centreHz) Hz"
                )
            }
            let measured = try XCTUnwrap(status.measuredDBFS)
            let predicted = try XCTUnwrap(status.predictedDBFS)
            XCTAssertLessThan(predicted, measured - QuietZoneFeedForwardShadowComparison.targetReductionDB, "\(rate) Hz")
            XCTAssertEqual(status.guardState, .clear, "\(rate) Hz")
            XCTAssertEqual(status.gaps, 0)
            XCTAssertEqual(status.modelResets, 0)
            shadow.setActive(false)
            shadow.flushForTesting()
            XCTAssertTrue(capture.closed)
            XCTAssertEqual(shadow.status, .inactive)
        }
    }

    func testARateChangeRecreatesTheShadowCleanly() async throws {
        var captures = [
            SimulatedFeedForwardPair(sampleRate: 48_000, delayFrames: 576, gain: disturbanceGain),
            SimulatedFeedForwardPair(sampleRate: 96_000, delayFrames: 1_152, gain: disturbanceGain),
        ]
        let first = captures[0], second = captures[1]
        let shadow = QuietZoneFeedForwardShadow(
            captureFactory: { _ in captures.removeFirst() }, deviceRate: { _ in nil }, pollsAutomatically: false
        )
        shadow.update(inputs: try inputs(rate: 48_000, design: false), reason: "")
        shadow.setActive(true)
        first.produce(seconds: 1)
        await shadow.tick()
        XCTAssertEqual(shadow.status.sampleRate, 48_000)

        // The device changes rate: the capture faults, the shadow drops it
        // and the next poll creates a fresh one at the new rate.
        first.fault = true
        await shadow.tick()
        shadow.flushForTesting()
        XCTAssertFalse(shadow.hasEngine)
        XCTAssertTrue(first.closed)
        guard case .fault = shadow.status.state else { return XCTFail("expected a fault, got \(shadow.status.state)") }
        // A fault waits before reopening, so a persistent cause cannot
        // restart the device several times a second.
        for _ in 0..<QuietZoneFeedForwardShadow.retryPolls { await shadow.tick() }
        XCTAssertEqual(shadow.enginesCreated, 1)
        second.produce(seconds: 1)
        await shadow.tick()
        XCTAssertEqual(shadow.enginesCreated, 2)
        XCTAssertEqual(shadow.status.sampleRate, 96_000)
        XCTAssertEqual(shadow.status.gaps, 0)
        XCTAssertEqual(shadow.status.adaptedSeconds, 1, accuracy: 0.01)

        // New inputs (here the device's nominal rate) drop the running shadow.
        shadow.update(inputs: try inputs(rate: 192_000, design: false), reason: "")
        shadow.flushForTesting()
        XCTAssertFalse(shadow.hasEngine)
        XCTAssertTrue(second.closed)
    }

    /// A nominal-rate change that does not fault the capture still drops it.
    func testASilentRateChangeDropsTheShadow() async throws {
        let capture = SimulatedFeedForwardPair(sampleRate: 48_000, delayFrames: 576, gain: disturbanceGain)
        let rate = RateBox(48_000)
        let shadow = QuietZoneFeedForwardShadow(
            captureFactory: { _ in capture }, deviceRate: { _ in rate.value }, pollsAutomatically: false
        )
        shadow.update(inputs: try inputs(rate: 48_000, design: false), reason: "")
        shadow.setActive(true)
        capture.produce(seconds: 1)
        await shadow.tick()
        XCTAssertEqual(shadow.status.state, .adapting)
        rate.value = 96_000
        capture.produce(seconds: 1)
        await shadow.tick()
        shadow.flushForTesting()
        XCTAssertFalse(shadow.hasEngine)
        XCTAssertTrue(capture.closed)
        guard case .fault = shadow.status.state else { return XCTFail("expected a fault, got \(shadow.status.state)") }
    }

    func testAGapReArmsTheWatch() async throws {
        let capture = SimulatedFeedForwardPair(sampleRate: 48_000, delayFrames: 576, gain: disturbanceGain)
        let shadow = QuietZoneFeedForwardShadow(captureFactory: { _ in capture }, deviceRate: { _ in nil }, pollsAutomatically: false)
        shadow.update(inputs: try inputs(rate: 48_000, design: false), reason: "")
        shadow.setActive(true)
        for _ in 0..<4 {
            capture.produce(seconds: 1)
            await shadow.tick()
        }
        XCTAssertEqual(shadow.status.guardState, .clear)

        capture.skip(frames: 4_800)  // a lost callback
        capture.produce(seconds: 1)
        await shadow.tick()
        XCTAssertEqual(shadow.status.gaps, 1)
        XCTAssertEqual(shadow.status.guardState, .arming)
        for _ in 0..<3 {
            capture.produce(seconds: 1)
            await shadow.tick()
        }
        XCTAssertEqual(shadow.status.guardState, .clear)
    }

    func testWatchTripsOnResetsCeilingAndGrowthAndAGapClearsIt() {
        var status = N60FeedForwardShadowStatus()
        status.decimatedRate = 4_000
        status.samplesSinceRestart = 16_000
        status.outputPower = (1e-4, 1e-4)
        var watch = QuietZoneFeedForwardShadowWatch()
        XCTAssertEqual(watch.observe(status), .clear)
        status.modelResets = 1
        XCTAssertEqual(watch.observe(status), .wouldHaveTripped("non-finite weights"))
        status.modelResets = 1
        XCTAssertEqual(watch.observe(status), .wouldHaveTripped("non-finite weights"), "a trip holds")

        status.gaps = 1
        status.samplesSinceRestart = 100
        XCTAssertEqual(watch.observe(status), .arming, "a gap re-arms")
        status.samplesSinceRestart = 16_000
        XCTAssertEqual(watch.observe(status), .clear)
        status.outputPower = (0.2, 0)
        XCTAssertEqual(watch.observe(status), .wouldHaveTripped("over ceiling"))

        var growing = QuietZoneFeedForwardShadowWatch()
        status.outputPower = (1e-4, 0)
        XCTAssertEqual(growing.observe(status), .clear)
        for _ in 0..<2 {
            status.outputPower.0 *= 2.2
            XCTAssertEqual(growing.observe(status), .clear)
        }
        status.outputPower.0 *= 2.2
        XCTAssertEqual(growing.observe(status), .wouldHaveTripped("growth"))
    }

    func testInactiveOrPausedCreatesNothingAndAFailedCaptureWaits() async throws {
        var calls = 0
        let capture = SimulatedFeedForwardPair(sampleRate: 48_000, delayFrames: 576, gain: disturbanceGain)
        var refuse = false
        let shadow = QuietZoneFeedForwardShadow(captureFactory: { _ in
            calls += 1
            if refuse { throw FeedForwardReferenceTransportError.invalidInput }
            return capture
        }, deviceRate: { _ in nil }, pollsAutomatically: false)
        shadow.update(inputs: try inputs(rate: 48_000, design: false), reason: "")
        await shadow.tick()
        XCTAssertEqual(calls, 0, "flag off: nothing is created")
        XCTAssertEqual(shadow.status, .inactive)

        shadow.setActive(true)
        await shadow.tick()
        XCTAssertTrue(shadow.hasEngine)
        shadow.update(inputs: nil, reason: "Paused while a feed-forward measurement runs.")
        shadow.flushForTesting()
        XCTAssertFalse(shadow.hasEngine)
        XCTAssertTrue(capture.closed)
        await shadow.tick()
        XCTAssertEqual(shadow.status.state, .waiting("Paused while a feed-forward measurement runs."))
        XCTAssertEqual(calls, 1)

        refuse = true
        shadow.update(inputs: try inputs(rate: 48_000, design: true), reason: "")
        await shadow.tick()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(shadow.status.state, .waiting(
            QuietZoneFeedForwardSurveyError.referenceChannelUnavailable(1).localizedDescription
        ))
        for _ in 0..<QuietZoneFeedForwardShadow.retryPolls { await shadow.tick() }
        XCTAssertEqual(calls, 2, "a failed capture waits before trying again")
        await shadow.tick()
        XCTAssertEqual(calls, 3)
    }

    func testShadowNeverReachesTheRenderPathAndCannotPlayUnauthorised() async throws {
        let engine = AudioIOEngine()
        let before = engine.activeQuietZoneRuntimeTarget
        let capture = SimulatedFeedForwardPair(sampleRate: 48_000, delayFrames: 576, gain: disturbanceGain)
        let shadow = QuietZoneFeedForwardShadow(captureFactory: { _ in capture }, deviceRate: { _ in nil }, pollsAutomatically: false)
        shadow.update(inputs: try inputs(rate: 48_000, design: true), reason: "")
        shadow.setActive(true)
        for _ in 0..<2 {
            capture.produce(seconds: 1)
            await shadow.tick()
        }
        XCTAssertEqual(shadow.status.state, .adapting)
        XCTAssertEqual(shadow.status.seedSource, .offlineDesign)
        XCTAssertEqual(engine.activeQuietZoneRuntimeTarget, before)

        XCTAssertFalse(AdaptiveTonalOutputGate.evaluate(.sample(armed: LiveTreatmentArm(feature: .quietZone).isArmed)).isOpen)
    }

    // MARK: Fixtures

    private func inputs(rate: Double, design: Bool) throws -> QuietZoneFeedForwardShadowInputs {
        let delay = Int((0.004 * rate).rounded())
        var survey = QuietZoneFeedForwardDesignSurvey(
            projectID: UUID(), microphoneStableID: "test-mic", errorChannel: 0, referenceChannel: 1,
            sampleRate: rate, capturedAt: Date(timeIntervalSince1970: 1_800_000_000), segments: 119,
            bands: QuietZoneFeedForwardSurveyGrid.frequenciesHz.map { f in
                let angle = -2 * Double.pi * f * (disturbanceSeconds * rate).rounded() / rate
                return QuietZoneFeedForwardSurveyBand(
                    frequencyHz: f,
                    referenceToSeat: ActiveQuietZoneComplex(
                        real: Double(disturbanceGain) * cos(angle), imaginary: Double(disturbanceGain) * sin(angle)
                    ),
                    coherence: 0.97
                )
            }
        )
        survey.leakage = QuietZoneFeedForwardLeakage(
            sampleRate: rate,
            leftImpulseResponse: impulse(delay: Int((0.003 * rate).rounded()), gain: 0.02),
            rightImpulseResponse: impulse(delay: Int((0.003 * rate).rounded()), gain: 0.02),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        func channel() -> RoomCorrectionChannelMeasurement {
            RoomCorrectionChannelMeasurement(
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000), rawCapture: [],
                impulseResponse: impulse(delay: delay, gain: 0.8),
                transferFunction: nil, quality: RoomCorrectionMeasurementQuality()
            )
        }
        let position = RoomCorrectionMeasurementPosition(name: "Seat", sampleRate: rate, left: channel(), right: channel())
        let budget = design ? plausibleBudget() : QuietZoneFeedForwardBudget.missing
        let outcome = QuietZoneFeedForwardSurveyRules.design(survey: survey, position: position, budget: budget)
        let bands: [QuietZoneVirtualSeatBand]
        var offline: QuietZoneVirtualSeatDesign?
        switch outcome {
        case .design(let d, let result):
            bands = result.bands
            offline = d
        case .bandsOnly(let result, _):
            bands = result.bands
        case .unavailable(let reason):
            throw XCTSkip("fixture did not assemble: \(reason)")
        }
        XCTAssertEqual(offline != nil, design, "\(rate) Hz")
        return QuietZoneFeedForwardShadowInputs(
            device: AudioInputDevice(
                deviceID: 1, uid: "test-mic", name: "Test interface",
                nominalSampleRate: rate, availableSampleRateRanges: []
            ),
            referenceChannel: 1, errorChannel: 0, bands: bands, design: offline,
            budget: budget, position: position
        )
    }

    private func impulse(delay: Int, gain: Float) -> [Float] {
        var ir = [Float](repeating: 0, count: delay + 16)
        ir[delay] = gain
        return ir
    }

    private func plausibleBudget() -> QuietZoneFeedForwardBudget {
        QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible, acousticPreviewSeconds: 0.018,
            conservativePreviewSeconds: 0.016, antiNoisePathSeconds: 0.008,
            conservativeReserveSeconds: 0.007,
            geometryOnly: false, runtimeAvailable: false,
            explanation: "simulated fixture"
        )
    }
}

private final class RateBox: @unchecked Sendable {
    var value: Double
    init(_ value: Double) { self.value = value }
}

/// Two sample-aligned channels made on demand: the reference is seeded
/// noise, the error the reference delayed and scaled. `skip` drops frames as
/// a lost callback would.
private final class SimulatedFeedForwardPair: QuietZoneFeedForwardPairCapturing {
    let sampleRate: Double
    let gain: Float
    var started = false
    var closed = false
    var fault = false
    private var available = 0
    private var history: [Float]
    private var position = 0
    private var time = 0.0
    private var state: UInt64 = 0x9E37_79B9

    init(sampleRate: Double, delayFrames: Int, gain: Float) {
        self.sampleRate = sampleRate
        self.gain = gain
        history = [Float](repeating: 0, count: delayFrames + 1)
    }

    func start() throws { started = true }
    func produce(seconds: Double) { available += Int((seconds * sampleRate).rounded()) }
    func skip(frames: Int) { time += Double(frames) }
    func close() { closed = true }

    func readPair(maximumFrames: Int) throws -> (reference: [N60FeedForwardReferenceFrame], error: [Float]) {
        if fault { throw FeedForwardReferenceTransportError.callbackFault }
        let count = min(maximumFrames, available)
        available -= count
        var frames = [N60FeedForwardReferenceFrame](repeating: N60FeedForwardReferenceFrame(), count: count)
        var error = [Float](repeating: 0, count: count)
        for i in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let x = Float(Int64(bitPattern: state >> 11) % 2_000_000 - 1_000_000) / 10_000_000
            history[position] = x
            position = (position + 1) % history.count
            frames[i].sample = x
            frames[i].firstFrameSampleTime = time
            frames[i].frameOffset = UInt32(i)
            frames[i].firstFrameHostTime = 1
            error[i] = gain * history[position]  // the oldest: delayFrames ago
        }
        time += Double(count)
        return (frames, error)
    }
}
