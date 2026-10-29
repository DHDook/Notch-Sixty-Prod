import XCTest
@testable import NotchSixty

/// E4 S16: the seat-microphone verifier. Analysis snapshots carry the device rate; the verifier
/// must behave the same at every standard rate.
@MainActor
final class DoNoHarmVerifierTests: XCTestCase {
    private static let standardRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
    ]
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let bandCenters: [Double] = [31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 800]

    private func snapshot(
        rate: Double,
        toneHz: Double = 43,
        toneDB: Double,
        bandDB: Double = -60,
        bandOverride: (Double, Double)? = nil
    ) -> AmbientAnalysisSnapshot {
        let bands = bandCenters.map { c -> AmbientSpectrumBand in
            let level = (bandOverride?.0 == c) ? bandOverride!.1 : bandDB
            return AmbientSpectrumBand(
                lowerFrequencyHz: c / 1.12, centerFrequencyHz: c, upperFrequencyHz: c * 1.12, levelDBFS: level)
        }
        return AmbientAnalysisSnapshot(
            sampleRate: rate, analyzedFrames: 16_384, separationMode: .microphoneOnly,
            separationConfidence: 1, predictionGain: nil, microphoneLevelDBFS: -40,
            predictedPlaybackLevelDBFS: nil, ambientLevelDBFS: -40, ambientLevelDBSPL: nil,
            stationarityScore: 1, periodicityScore: 1, periodicFrequencyHz: toneHz,
            lowFrequencyEnergyFraction: 1, cancellationCandidateScore: 1, character: .tonal,
            spectrum: bands,
            tonalComponents: [AmbientTonalComponent(frequencyHz: toneHz, levelDBFS: toneDB, prominenceDB: 20)])
    }

    private func baselined(rate: Double) -> DoNoHarmVerifier {
        var v = DoNoHarmVerifier()
        for _ in 0..<DoNoHarmVerifier.baselineWindowCount {
            v.captureBaseline(snapshot(rate: rate, toneDB: -30))
        }
        return v
    }

    func testNoVerdictBeforeTheBaselineIsCaptured() {
        var v = DoNoHarmVerifier()
        v.captureBaseline(snapshot(rate: 48_000, toneDB: -30))
        XCTAssertFalse(v.hasBaseline)
        XCTAssertEqual(v.evaluate(snapshot(rate: 48_000, toneDB: -10), now: t0), .baselining)
    }

    func testAToneWorseByMoreThanOneDBForTwoSecondsIsHarmAtEveryRate() {
        for rate in Self.standardRates {
            var v = baselined(rate: rate)
            XCTAssertEqual(v.evaluate(snapshot(rate: rate, toneDB: -28.5), now: t0), .warning, "\(rate)")
            XCTAssertEqual(v.evaluate(snapshot(rate: rate, toneDB: -28.5), now: t0.addingTimeInterval(1.9)), .warning)
            guard case .harm(let hz, let inc) =
                    v.evaluate(snapshot(rate: rate, toneDB: -28.5), now: t0.addingTimeInterval(2.0)) else {
                return XCTFail("expected harm at \(rate)")
            }
            XCTAssertEqual(hz, 43, accuracy: 0.01)
            XCTAssertEqual(inc, 1.5, accuracy: 0.01)
        }
    }

    func testABandWorseThanBaselineIsHarmEvenWhenTonesAreFine() {
        for rate in Self.standardRates {
            var v = baselined(rate: rate)
            let worse = snapshot(rate: rate, toneDB: -35, bandOverride: (125, -57))
            XCTAssertEqual(v.evaluate(worse, now: t0), .warning)
            guard case .harm(let hz, let inc) = v.evaluate(worse, now: t0.addingTimeInterval(2.5)) else {
                return XCTFail("expected harm at \(rate)")
            }
            XCTAssertEqual(hz, 125, accuracy: 0.01)
            XCTAssertEqual(inc, 3, accuracy: 0.01)
        }
    }

    func testWithinTheOneDBLimitNeverTrips() {
        var v = baselined(rate: 48_000)
        for i in 0..<20 {
            XCTAssertEqual(
                v.evaluate(snapshot(rate: 48_000, toneDB: -29.2), now: t0.addingTimeInterval(Double(i))), .ok)
        }
    }

    func testARecoveredWindowResetsTheTwoSecondTimer() {
        var v = baselined(rate: 48_000)
        _ = v.evaluate(snapshot(rate: 48_000, toneDB: -28), now: t0)
        _ = v.evaluate(snapshot(rate: 48_000, toneDB: -28), now: t0.addingTimeInterval(1.5))
        XCTAssertEqual(v.evaluate(snapshot(rate: 48_000, toneDB: -35), now: t0.addingTimeInterval(1.8)), .ok)
        XCTAssertEqual(v.evaluate(snapshot(rate: 48_000, toneDB: -28), now: t0.addingTimeInterval(2.5)), .warning)
        XCTAssertEqual(v.evaluate(snapshot(rate: 48_000, toneDB: -28), now: t0.addingTimeInterval(4.0)), .warning)
    }

    func testCancelledToneProducesAVerifiedReadoutAfterSettling() {
        var v = baselined(rate: 96_000)
        for i in 0..<(DoNoHarmVerifier.readoutVerifiedWindows - 1) {
            _ = v.evaluate(snapshot(rate: 96_000, toneDB: -42), now: t0.addingTimeInterval(Double(i)))
            XCTAssertNil(v.readout, "not verified until it settles")
        }
        _ = v.evaluate(snapshot(rate: 96_000, toneDB: -42), now: t0.addingTimeInterval(5))
        XCTAssertEqual(v.readout, "\u{2212}12 dB at 43 Hz, verified")
    }

    func testToneBelowTheDetectorIsNotHarm() {
        var v = baselined(rate: 48_000)
        var gone = snapshot(rate: 48_000, toneDB: -80)
        gone = AmbientAnalysisSnapshot(
            sampleRate: gone.sampleRate, analyzedFrames: gone.analyzedFrames, separationMode: gone.separationMode,
            separationConfidence: 1, predictionGain: nil, microphoneLevelDBFS: -40, predictedPlaybackLevelDBFS: nil,
            ambientLevelDBFS: -40, ambientLevelDBSPL: nil, stationarityScore: 1, periodicityScore: 1,
            periodicFrequencyHz: nil, lowFrequencyEnergyFraction: 1, cancellationCandidateScore: 1,
            character: .quiet, spectrum: gone.spectrum, tonalComponents: [])
        XCTAssertEqual(v.evaluate(gone, now: t0), .ok)
        XCTAssertEqual(v.evaluate(gone, now: t0.addingTimeInterval(10)), .ok)
    }

    func testResetForgetsTheBaseline() {
        var v = baselined(rate: 48_000)
        v.reset()
        XCTAssertFalse(v.hasBaseline)
        XCTAssertNil(v.readout)
    }

    func testSeatRegressionDisarmsAndLatches() {
        let arm = LiveTreatmentArm(feature: .quietZone)
        var reasons: [LiveTreatmentDisarmReason] = []
        arm.onDisarm = { reasons.append($0) }
        try? arm.arm(environment: LiveTreatmentEnvironment(
            outputDeviceUID: "out", sampleRate: 48_000, engineRunning: true, inputAvailable: true,
            microphoneLevelDBFS: nil))
        arm.reportSeatRegression()
        XCTAssertFalse(arm.isArmed)
        XCTAssertEqual(reasons, [.seatRegression])
        XCTAssertTrue(arm.latchedByEvent)
        XCTAssertNotNil(arm.statusMessage)
    }
}
