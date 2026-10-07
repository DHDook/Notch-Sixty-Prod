import Foundation
import XCTest
@testable import NotchSixty

final class AmbientFieldAnalyzerTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let frameCount = 16_384

    func testMicrophoneOnlyStableToneIsDetectedAsPeriodicAmbientNoise() throws {
        let ambient = sine(frequency: 60, amplitude: 0.08, frames: frameCount)
        let snapshot = try AmbientFieldAnalyzer().analyze(
            microphone: ambient,
            sampleRate: sampleRate
        )

        XCTAssertEqual(snapshot.separationMode, .microphoneOnly)
        XCTAssertEqual(snapshot.separationConfidence, 1, accuracy: 0.000_001)
        XCTAssertGreaterThan(snapshot.stationarityScore, 0.95)
        XCTAssertGreaterThan(snapshot.periodicityScore, 0.85)
        XCTAssertEqual(snapshot.periodicFrequencyHz ?? 0, 60, accuracy: 1.0)
        XCTAssertGreaterThan(snapshot.lowFrequencyEnergyFraction, 0.95)
        XCTAssertGreaterThan(snapshot.cancellationCandidateScore, 0.80)
        XCTAssertTrue(
            snapshot.character == .tonalPeriodic || snapshot.character == .tonal
        )

        guard let strongest = snapshot.tonalComponents.first else {
            XCTFail("Expected a detected tonal component")
            return
        }
        XCTAssertEqual(strongest.frequencyHz, 60, accuracy: 3.5)
        XCTAssertGreaterThan(strongest.prominenceDB, 20)
    }

    func testKnownPlaybackPredictionRecoversIndependentAmbientTone() throws {
        let playback = shapedPlayback(frames: frameCount)
        let impulse = delayedImpulse(
            delay: 41,
            taps: [
                (0, 0.62),
                (19, -0.11),
                (73, 0.07),
            ]
        )
        let predicted = convolve(playback, impulse: impulse)
        let ambientTone = sine(frequency: 83, amplitude: 0.045, frames: frameCount)
        let ambientNoise = deterministicNoise(amplitude: 0.0035, frames: frameCount)
        let ambient = zip(ambientTone, ambientNoise).map { pair in
            pair.0 + pair.1
        }
        let microphone = zip(predicted, ambient).map { pair in
            pair.0 + pair.1
        }

        let snapshot = try AmbientFieldAnalyzer().analyze(
            microphone: microphone,
            playbackReference: playback,
            acousticImpulseResponse: impulse,
            sampleRate: sampleRate
        )

        XCTAssertEqual(snapshot.separationMode, .modeledPlaybackSubtraction)
        XCTAssertGreaterThan(snapshot.separationConfidence, 0.70)
        XCTAssertEqual(snapshot.predictionGain ?? 0, 1.0, accuracy: 0.04)

        let expectedAmbientDBFS = dbfs(rms(ambient))
        XCTAssertEqual(snapshot.ambientLevelDBFS, expectedAmbientDBFS, accuracy: 1.0)
        XCTAssertLessThan(
            snapshot.ambientLevelDBFS,
            snapshot.microphoneLevelDBFS - 3,
            "Playback subtraction should materially reduce the microphone mixture"
        )

        guard let strongest = snapshot.tonalComponents.first else {
            XCTFail("Expected residual ambient tone")
            return
        }
        XCTAssertEqual(strongest.frequencyHz, 83, accuracy: 3.5)
        XCTAssertGreaterThan(snapshot.periodicityScore, 0.70)
        XCTAssertEqual(snapshot.periodicFrequencyHz ?? 0, 83, accuracy: 2.0)
    }

    func testPlaybackSubtractionRecoversFromIndependentClockWindowOffset() throws {
        let playback = shapedPlayback(frames: frameCount)
        let impulse = delayedImpulse(
            delay: 37,
            taps: [
                (0, 0.58),
                (21, -0.09),
                (67, 0.05),
            ]
        )
        let predicted = convolve(playback, impulse: impulse)
        let ambient = sine(
            frequency: 91,
            amplitude: 0.035,
            frames: frameCount
        )
        let offset = 1_200
        var microphone = ambient
        for index in microphone.indices where index >= offset {
            microphone[index] += predicted[index - offset]
        }

        let snapshot = try AmbientFieldAnalyzer().analyze(
            microphone: microphone,
            playbackReference: playback,
            acousticImpulseResponse: impulse,
            sampleRate: sampleRate
        )

        XCTAssertEqual(
            snapshot.separationMode,
            .modeledPlaybackSubtraction
        )
        XCTAssertGreaterThan(snapshot.separationConfidence, 0.70)
        XCTAssertEqual(
            snapshot.predictionGain ?? 0,
            1.0,
            accuracy: 0.08
        )
        XCTAssertEqual(
            snapshot.ambientLevelDBFS,
            dbfs(rms(ambient)),
            accuracy: 1.5
        )
        XCTAssertLessThan(
            snapshot.ambientLevelDBFS,
            snapshot.microphoneLevelDBFS - 3
        )
    }

    func testSemanticPlaybackSourcesSumInTheAcousticDomain() throws {
        let left = shapedPlayback(frames: frameCount)
        let right = (0..<frameCount).map { frame in
            Float(
                0.11 * sin(
                    2.0 * Double.pi * 1_463.0 * Double(frame) / sampleRate
                )
            )
        }
        let leftImpulse = delayedImpulse(
            delay: 23,
            taps: [(0, 0.52), (37, 0.08)]
        )
        let rightImpulse = delayedImpulse(
            delay: 31,
            taps: [(0, 0.41), (29, -0.06)]
        )
        let leftAtMic = convolve(left, impulse: leftImpulse)
        let rightAtMic = convolve(right, impulse: rightImpulse)
        let ambient = sine(frequency: 71, amplitude: 0.035, frames: frameCount)
        let microphone = (0..<frameCount).map { index in
            leftAtMic[index] + rightAtMic[index] + ambient[index]
        }

        let snapshot = try AmbientFieldAnalyzer().analyze(
            microphone: microphone,
            playbackSources: [
                AmbientPlaybackSourceReference(
                    id: "front-left",
                    samples: left,
                    acousticImpulseResponse: leftImpulse
                ),
                AmbientPlaybackSourceReference(
                    id: "front-right",
                    samples: right,
                    acousticImpulseResponse: rightImpulse
                ),
            ],
            sampleRate: sampleRate
        )

        XCTAssertEqual(snapshot.separationMode, .modeledPlaybackSubtraction)
        XCTAssertGreaterThan(snapshot.separationConfidence, 0.70)
        XCTAssertEqual(snapshot.predictionGain ?? 0, 1.0, accuracy: 0.04)
        XCTAssertEqual(
            snapshot.ambientLevelDBFS,
            dbfs(rms(ambient)),
            accuracy: 1.0
        )
        XCTAssertEqual(
            snapshot.tonalComponents.first?.frequencyHz ?? 0,
            71,
            accuracy: 3.5
        )
    }

    func testOneAudibleUnmodeledSemanticSourceFailsSeparationClosed() throws {
        let left = shapedPlayback(frames: frameCount)
        let right = sine(frequency: 1_700, amplitude: 0.05, frames: frameCount)
        let microphone = (0..<frameCount).map { left[$0] + right[$0] }

        let snapshot = try AmbientFieldAnalyzer().analyze(
            microphone: microphone,
            playbackSources: [
                AmbientPlaybackSourceReference(
                    id: "front-left",
                    samples: left,
                    acousticImpulseResponse: [1]
                ),
                AmbientPlaybackSourceReference(
                    id: "front-right",
                    samples: right,
                    acousticImpulseResponse: nil
                ),
            ],
            sampleRate: sampleRate
        )

        XCTAssertEqual(snapshot.separationMode, .playbackModelUnavailable)
        XCTAssertLessThan(snapshot.separationConfidence, 0.25)
        XCTAssertNil(snapshot.predictionGain)
    }

    func testAudiblePlaybackWithoutAcousticModelFailsConfidenceClosed() throws {
        let playback = shapedPlayback(frames: frameCount)
        let microphone = playback

        let snapshot = try AmbientFieldAnalyzer().analyze(
            microphone: microphone,
            playbackReference: playback,
            acousticImpulseResponse: nil,
            sampleRate: sampleRate
        )

        XCTAssertEqual(snapshot.separationMode, .playbackModelUnavailable)
        XCTAssertLessThan(snapshot.separationConfidence, 0.25)
        XCTAssertNil(snapshot.predictionGain)
        XCTAssertNil(snapshot.predictedPlaybackLevelDBFS)
    }

    func testNegligiblePlaybackDoesNotRequireAcousticModel() throws {
        let microphone = sine(frequency: 120, amplitude: 0.03, frames: frameCount)
        let playback = [Float](repeating: 0, count: frameCount)

        let snapshot = try AmbientFieldAnalyzer().analyze(
            microphone: microphone,
            playbackReference: playback,
            acousticImpulseResponse: nil,
            sampleRate: sampleRate
        )

        XCTAssertEqual(snapshot.separationMode, .microphoneOnly)
        XCTAssertEqual(snapshot.separationConfidence, 1, accuracy: 0.000_001)
    }

    func testDetailedAnalysisExposesSeparatedResidualAndAlignmentEvidence() throws {
        // Use a deterministic band-limited chirp so the requested transport
        // lag is uniquely observable by both the coarse and fine alignment
        // searches. A sparse tonal reference can have multiple phase-equivalent
        // correlation peaks and is inappropriate for asserting an exact lag.
        let chirpStartHz = 180.0
        let chirpEndHz = 1_000.0
        let chirpDuration = Double(frameCount) / sampleRate
        let chirpRate = (chirpEndHz - chirpStartHz) / chirpDuration
        let playback = (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let phase = 2.0 * Double.pi * (
                chirpStartHz * time
                    + 0.5 * chirpRate * time * time
            )
            return Float(0.12 * sin(phase))
        }
        let impulse = delayedImpulse(
            delay: 37,
            taps: [(0, 0.55), (23, -0.08)]
        )
        let predicted = convolve(playback, impulse: impulse)
        let ambient = sine(
            frequency: 91,
            amplitude: 0.035,
            frames: frameCount
        )
        let transportOffset = 900
        var microphone = ambient
        for index in microphone.indices
        where index >= transportOffset {
            microphone[index] +=
                predicted[index - transportOffset]
        }

        let result = try AmbientFieldAnalyzer().analyzeDetailed(
            microphone: microphone,
            playbackReference: playback,
            acousticImpulseResponse: impulse,
            sampleRate: sampleRate
        )

        XCTAssertEqual(
            result.snapshot.separationMode,
            .modeledPlaybackSubtraction
        )
        XCTAssertEqual(
            result.playbackAlignmentLagFrames ?? 0,
            transportOffset,
            accuracy: 3
        )
        XCTAssertGreaterThan(
            result.playbackAlignmentConfidence ?? 0,
            0.70
        )
        XCTAssertEqual(
            result.separatedResidualSamples.count,
            result.snapshot.analyzedFrames
        )
        XCTAssertEqual(
            dbfs(rms(result.separatedResidualSamples)),
            dbfs(rms(ambient)),
            accuracy: 1.5
        )
    }

    func testDetectedTonalComponentPublishesFiniteResidualPhase() throws {
        let transformAlignedBin = 40.0
        let frequency =
            transformAlignedBin * sampleRate
            / Double(frameCount)
        let phase = 0.43
        let samples = (0..<frameCount).map { frame in
            Float(
                0.06 * cos(
                    2 * Double.pi * frequency
                        * Double(frame) / sampleRate
                        + phase
                )
            )
        }

        let result = try AmbientFieldAnalyzer().analyzeDetailed(
            microphone: samples,
            sampleRate: sampleRate
        )
        let component = try XCTUnwrap(
            result.snapshot.tonalComponents.first
        )

        XCTAssertEqual(
            component.frequencyHz,
            frequency,
            accuracy: sampleRate / Double(frameCount)
        )
        XCTAssertNotNil(component.phaseRadians)
        XCTAssertTrue(component.phaseRadians?.isFinite == true)
        XCTAssertEqual(
            atan2(
                sin((component.phaseRadians ?? 0) - phase),
                cos((component.phaseRadians ?? 0) - phase)
            ),
            0,
            accuracy: 0.08
        )
    }

    func testDetailedAndLegacySnapshotAPIsRemainEquivalent() throws {
        let microphone = sine(
            frequency: 75,
            amplitude: 0.04,
            frames: frameCount
        )
        let analyzer = AmbientFieldAnalyzer()
        let legacy = try analyzer.analyze(
            microphone: microphone,
            sampleRate: sampleRate
        )
        let detailed = try analyzer.analyzeDetailed(
            microphone: microphone,
            sampleRate: sampleRate
        )

        XCTAssertEqual(legacy, detailed.snapshot)
        XCTAssertEqual(
            detailed.separatedResidualSamples,
            microphone
        )
        XCTAssertNil(detailed.playbackAlignmentLagFrames)
        XCTAssertNil(detailed.playbackAlignmentConfidence)
    }

    func testStationarityDistinguishesSteadyFromBurstingNoise() throws {
        let steady = deterministicNoise(amplitude: 0.04, frames: frameCount)
        var bursting = [Float](repeating: 0, count: frameCount)
        let noise = deterministicNoise(amplitude: 0.11, frames: frameCount / 4)
        let start = frameCount / 2
        for index in noise.indices {
            bursting[start + index] = noise[index]
        }

        let analyzer = AmbientFieldAnalyzer()
        let steadySnapshot = try analyzer.analyze(
            microphone: steady,
            sampleRate: sampleRate
        )
        let burstSnapshot = try analyzer.analyze(
            microphone: bursting,
            sampleRate: sampleRate
        )

        XCTAssertGreaterThan(steadySnapshot.stationarityScore, 0.90)
        XCTAssertLessThan(burstSnapshot.stationarityScore, 0.55)
        XCTAssertGreaterThan(
            steadySnapshot.stationarityScore,
            burstSnapshot.stationarityScore + 0.30
        )
        XCTAssertEqual(burstSnapshot.character, .nonstationary)
    }

    func testCancellationCandidateScorePrefersStableLowFrequencyEnergy() throws {
        let low = sine(frequency: 75, amplitude: 0.05, frames: frameCount)
        let high = sine(frequency: 3_000, amplitude: 0.05, frames: frameCount)

        let analyzer = AmbientFieldAnalyzer()
        let lowSnapshot = try analyzer.analyze(
            microphone: low,
            sampleRate: sampleRate
        )
        let highSnapshot = try analyzer.analyze(
            microphone: high,
            sampleRate: sampleRate
        )

        XCTAssertGreaterThan(lowSnapshot.lowFrequencyEnergyFraction, 0.90)
        XCTAssertLessThan(highSnapshot.lowFrequencyEnergyFraction, 0.05)
        XCTAssertGreaterThan(
            lowSnapshot.cancellationCandidateScore,
            highSnapshot.cancellationCandidateScore + 0.60
        )
    }

    func testOptionalAbsoluteCalibrationMapsDBFSToDBSPL() throws {
        var configuration = AmbientAnalysisConfiguration.production
        configuration.optionalDBSPLAt0DBFS = 118.0
        let signal = sine(frequency: 100, amplitude: 0.1, frames: frameCount)

        let snapshot = try AmbientFieldAnalyzer(configuration: configuration).analyze(
            microphone: signal,
            sampleRate: sampleRate
        )

        XCTAssertNotNil(snapshot.ambientLevelDBSPL)
        XCTAssertEqual(
            snapshot.ambientLevelDBSPL ?? 0,
            snapshot.ambientLevelDBFS + 118,
            accuracy: 0.000_001
        )
    }

    func testAnalyzerRejectsNonFiniteAndMismatchedInputs() throws {
        let microphone = [Float](repeating: 0, count: frameCount)
        let shorterPlayback = [Float](repeating: 0, count: frameCount - 1)

        XCTAssertThrowsError(
            try AmbientFieldAnalyzer().analyze(
                microphone: microphone,
                playbackReference: shorterPlayback,
                sampleRate: sampleRate
            )
        ) { error in
            XCTAssertEqual(
                error as? AmbientAnalysisError,
                .playbackLengthMismatch(
                    microphone: self.frameCount,
                    playback: self.frameCount - 1
                )
            )
        }

        var invalid = microphone
        invalid[100] = .nan
        XCTAssertThrowsError(
            try AmbientFieldAnalyzer().analyze(
                microphone: invalid,
                sampleRate: sampleRate
            )
        ) { error in
            XCTAssertEqual(error as? AmbientAnalysisError, .nonFiniteMicrophone)
        }
    }

    private func sine(
        frequency: Double,
        amplitude: Float,
        frames: Int
    ) -> [Float] {
        (0..<frames).map { frame in
            amplitude * Float(
                sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate)
            )
        }
    }

    private func shapedPlayback(frames: Int) -> [Float] {
        (0..<frames).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = 0.55 + 0.35 * sin(2.0 * Double.pi * 1.7 * time)
            let value =
                0.16 * sin(2.0 * Double.pi * 997.0 * time)
                + 0.09 * sin(2.0 * Double.pi * 431.0 * time)
                + 0.05 * sin(2.0 * Double.pi * 2_113.0 * time)
            return Float(envelope * value)
        }
    }

    private func delayedImpulse(
        delay: Int,
        taps: [(offset: Int, value: Float)]
    ) -> [Float] {
        let length = delay + (taps.map { $0.offset }.max() ?? 0) + 1
        var impulse = [Float](repeating: 0, count: length)
        for tap in taps {
            impulse[delay + tap.offset] = tap.value
        }
        return impulse
    }

    private func convolve(_ source: [Float], impulse: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: source.count)
        for frame in source.indices {
            var sum = 0.0
            let maximumTap = min(frame, impulse.count - 1)
            if maximumTap >= 0 {
                for tap in 0...maximumTap {
                    sum += Double(source[frame - tap]) * Double(impulse[tap])
                }
            }
            output[frame] = Float(sum)
        }
        return output
    }

    private func deterministicNoise(amplitude: Float, frames: Int) -> [Float] {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        return (0..<frames).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double((state >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
            return amplitude * Float(unit * 2.0 - 1.0)
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        sqrt(
            samples.reduce(0.0) {
                $0 + Double($1) * Double($1)
            } / Double(samples.count)
        )
    }

    private func dbfs(_ amplitude: Double) -> Double {
        20.0 * log10(max(amplitude, 1.0e-15))
    }
}
