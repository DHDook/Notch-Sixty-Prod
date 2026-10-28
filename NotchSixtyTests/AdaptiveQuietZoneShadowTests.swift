import Foundation
import XCTest
@testable import NotchSixty

/// E4 S6: the adaptive tonal canceller in shadow mode. The core's shadow maths
/// is covered at every rate in ci/harness_e4_fxlms.c; these cover the app-shell
/// wiring: seeding, activation, lifecycle and isolation from the render path.
@MainActor
final class AdaptiveQuietZoneShadowTests: XCTestCase {
    private let rates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]

    private func complex(_ magnitude: Double, _ degrees: Double) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(
            real: magnitude * cos(degrees * .pi / 180),
            imaginary: magnitude * sin(degrees * .pi / 180)
        )
    }

    private func seed(_ hz: Double = 60) -> AdaptiveQuietZoneSeed {
        AdaptiveQuietZoneSeed(
            frequencyHz: hz,
            leftPath: complex(0.5, -40),
            rightPath: complex(0.3, 70),
            leftOutput: complex(0.03, 120),
            rightOutput: complex(0.01, -10)
        )
    }

    /// A disturbance tone at the microphone; nothing the shadow computes is
    /// played, so the microphone hears only this.
    private func tone(_ rate: Double, start: Int, count: Int, hz: Double = 60) -> [Float] {
        (0..<count).map { i in
            Float(0.02 * cos(2 * .pi * hz * Double(start + i) / rate + 0.4))
        }
    }

    /// Delivers blocks as the ambient monitor does (every 250 ms), waiting
    /// for each result as the main actor would between polls.
    private func feed(
        _ shadow: AdaptiveQuietZoneShadow, rate: Double, seconds: Double, epoch: UUID,
        skippedFirst: Bool = false
    ) async {
        let block = Int(rate / 4)
        var start = 0
        while Double(start) < seconds * rate {
            shadow.receiveMicrophoneFrames(
                tone(rate, start: start, count: block), sampleRate: rate, epoch: epoch,
                skipped: skippedFirst && start == 0
            )
            await shadow.flushForTesting()
            start += block
        }
    }

    func testSeedsKeepTheOfflineSplitAndCombineThePaths() {
        let s = seed()
        let tones = AdaptiveQuietZoneShadowTone.tones(from: [s, seed(10), seed(80), seed(90), seed(100), seed(110)])
        XCTAssertEqual(tones.map(\.frequencyHz), [60, 80, 90, 100], "out-of-band dropped, at most four")
        let t = tones[0]
        let norm = hypot(0.03, 0.01)
        XCTAssertEqual(t.offlineMagnitude, norm, accuracy: 1e-12)
        XCTAssertEqual(hypot(t.leftShare.magnitude, t.rightShare.magnitude), 1, accuracy: 1e-12)
        // leftShare W and rightShare W reproduce the offline outputs at W = norm.
        XCTAssertEqual((t.leftShare * norm - s.leftOutput).magnitude, 0, accuracy: 1e-12)
        XCTAssertEqual((t.rightShare * norm - s.rightOutput).magnitude, 0, accuracy: 1e-12)
        let path = t.leftShare * s.leftPath + t.rightShare * s.rightPath
        XCTAssertEqual((t.path - path).magnitude, 0, accuracy: 1e-12)
    }

    func testInactiveShadowCreatesNothing() async {
        let shadow = AdaptiveQuietZoneShadow()
        shadow.updateSeeds([seed()])
        await feed(shadow, rate: 48_000, seconds: 0.5, epoch: UUID())
        XCTAssertFalse(shadow.hasEngine)
        XCTAssertEqual(shadow.status, .inactive)
    }

    func testShadowPredictsCancellationAtEveryRate() async {
        for rate in rates {
            let shadow = AdaptiveQuietZoneShadow()
            shadow.setActive(true)
            XCTAssertEqual(shadow.status.state, .waitingForTones)
            shadow.updateSeeds([seed()])
            await feed(shadow, rate: rate, seconds: 2.5, epoch: UUID())
            let status = shadow.status
            XCTAssertEqual(status.state, .adapting, "\(rate) Hz")
            XCTAssertEqual(status.sampleRate, rate)
            let t = try! XCTUnwrap(status.tones.first)
            XCTAssertTrue(t.adapting, "\(rate) Hz")
            XCTAssertEqual(t.measuredDBFS, 20 * log10(0.02), accuracy: 0.5, "\(rate) Hz: mic hears the full tone")
            XCTAssertGreaterThan(t.predictedReductionDB, 25, "\(rate) Hz")
            // |W| converges to |D| / |S| (the virtual path is the seed).
            let pathGain = AdaptiveQuietZoneShadowTone.tones(from: [seed()])[0].path.magnitude
            XCTAssertEqual(t.weightDBFS, 20 * log10(0.02 / pathGain), accuracy: 0.5, "\(rate) Hz")
            XCTAssertNotEqual(status.guardState, .arming, "\(rate) Hz: guard armed after 3 tau")
        }
    }

    func testRateOrToneChangeRecreatesTheCore() async {
        let shadow = AdaptiveQuietZoneShadow()
        shadow.setActive(true)
        shadow.updateSeeds([seed()])
        await feed(shadow, rate: 48_000, seconds: 1, epoch: UUID())
        XCTAssertEqual(shadow.status.sampleRate, 48_000)
        await feed(shadow, rate: 96_000, seconds: 0.5, epoch: UUID())
        XCTAssertEqual(shadow.status.sampleRate, 96_000)
        XCTAssertEqual(shadow.status.gaps, 0, "a new core, not a gap in the old one")

        shadow.updateSeeds([seed(80)])
        XCTAssertFalse(shadow.hasEngine, "tone set changed")
        shadow.updateSeeds([])
        XCTAssertEqual(shadow.status.state, .waitingForTones)
        shadow.setActive(false)
        XCTAssertEqual(shadow.status, .inactive)
        XCTAssertFalse(shadow.hasEngine)
    }

    func testMonitorRestartIsAGap() async {
        let shadow = AdaptiveQuietZoneShadow()
        shadow.setActive(true)
        shadow.updateSeeds([seed()])
        await feed(shadow, rate: 48_000, seconds: 0.5, epoch: UUID())
        await feed(shadow, rate: 48_000, seconds: 0.5, epoch: UUID())
        XCTAssertEqual(shadow.status.gaps, 1)
    }

    func testMeasurementNoiseInTheSeedsKeepsTheCore() async {
        let shadow = AdaptiveQuietZoneShadow()
        shadow.setActive(true)
        shadow.updateSeeds([seed()])
        await feed(shadow, rate: 48_000, seconds: 1, epoch: UUID())
        var noisy = seed()
        noisy.leftPath = noisy.leftPath * complex(1.02, 1.5)  // 0.17 dB, 1.5 deg
        shadow.updateSeeds([noisy])
        XCTAssertTrue(shadow.hasEngine, "small refresh kept the core")
        noisy.leftPath = noisy.leftPath * complex(1.5, 0)     // 3.5 dB
        shadow.updateSeeds([noisy])
        XCTAssertFalse(shadow.hasEngine, "a real design change rebuilds it")
    }

    func testSkippedPollIsAGapAndBacklogIsBounded() async {
        let shadow = AdaptiveQuietZoneShadow()
        shadow.setActive(true)
        shadow.updateSeeds([seed()])
        let epoch = UUID()
        await feed(shadow, rate: 48_000, seconds: 0.5, epoch: epoch)
        await feed(shadow, rate: 48_000, seconds: 0.5, epoch: epoch, skippedFirst: true)
        XCTAssertEqual(shadow.status.gaps, 1)

        // Without the main actor draining results, blocks beyond the bound
        // are dropped and the next accepted one is marked as a gap.
        let block = tone(48_000, start: 0, count: 12_000)
        for _ in 0..<(AdaptiveQuietZoneShadow.maximumPendingBlocks + 3) {
            shadow.receiveMicrophoneFrames(block, sampleRate: 48_000, epoch: epoch)
        }
        await shadow.flushForTesting()
        shadow.receiveMicrophoneFrames(block, sampleRate: 48_000, epoch: epoch)
        await shadow.flushForTesting()
        XCTAssertEqual(shadow.status.droppedBlocks, 3)
        XCTAssertGreaterThanOrEqual(shadow.status.gaps, 2)
    }

    func testShadowNeverReachesTheRenderPathAndCannotPlayUnauthorised() async throws {
        let engine = AudioIOEngine()
        let before = engine.activeQuietZoneRuntimeTarget
        let shadow = AdaptiveQuietZoneShadow()
        shadow.setActive(true)
        shadow.updateSeeds([seed()])
        await feed(shadow, rate: 48_000, seconds: 2, epoch: UUID())
        XCTAssertEqual(shadow.status.state, .adapting)
        XCTAssertEqual(engine.activeQuietZoneRuntimeTarget, before)

        XCTAssertFalse(AdaptiveQuietZoneOutputPolicy.mayPlay(LiveTreatmentArm(feature: .quietZone)))
    }
}
