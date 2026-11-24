import Foundation
import XCTest
@testable import NotchSixty

/// E21 S10b: the ambient field analysis in libn60core (n60/anc_design.h v2) against the Swift reference, at the eight standard
/// rates. The Swift path stays as the flag-off reference (`useCoreMaths = false`) until S14.
final class AmbientFieldCoreParityTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let frames = 32_768

    private func analyzers() -> (swift: AmbientFieldAnalyzer, core: AmbientFieldAnalyzer) {
        var swift = AmbientFieldAnalyzer()
        swift.useCoreMaths = false
        var core = AmbientFieldAnalyzer()
        core.useCoreMaths = true
        return (swift, core)
    }

    private func noise(_ amplitude: Double, seed: UInt32) -> [Float] {
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(amplitude * (Double(state >> 8) / Double(1 << 24) * 2 - 1))
        }
    }

    private func program(rate: Double) -> [Float] {
        var out = noise(0.005, seed: 11)
        for f in [150.0, 233.0, 331.0, 457.0] {
            for i in 0..<frames {
                out[i] += Float(0.05 * sin(2 * Double.pi * f * Double(i) / rate + f))
            }
        }
        return out
    }

    private func closeBands(_ a: [AmbientSpectrumBand], _ b: [AmbientSpectrumBand], line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, line: line)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.centerFrequencyHz, y.centerFrequencyHz, accuracy: 1e-6 * x.centerFrequencyHz, line: line)
            // Below -120 dBFS both paths are float rounding residue (Swift float vDSP, core double), so only the
            // level above that floor is compared; the floor itself must stay below it on both sides.
            if max(x.levelDBFS, y.levelDBFS) > -120 {
                XCTAssertEqual(x.levelDBFS, y.levelDBFS, accuracy: 0.05, line: line)
            } else {
                XCTAssertLessThan(min(x.levelDBFS, y.levelDBFS), -120, line: line)
            }
        }
    }

    private func closeSnapshots(_ s: AmbientAnalysisSnapshot, _ c: AmbientAnalysisSnapshot, line: UInt = #line) {
        XCTAssertEqual(s.separationMode, c.separationMode, line: line)
        XCTAssertEqual(s.character, c.character, line: line)
        XCTAssertEqual(s.analyzedFrames, c.analyzedFrames, line: line)
        XCTAssertEqual(s.separationConfidence, c.separationConfidence, accuracy: 0.01, line: line)
        XCTAssertEqual(s.predictionGain ?? 0, c.predictionGain ?? 0, accuracy: 0.01, line: line)
        XCTAssertEqual(s.microphoneLevelDBFS, c.microphoneLevelDBFS, accuracy: 0.01, line: line)
        XCTAssertEqual(s.ambientLevelDBFS, c.ambientLevelDBFS, accuracy: 0.05, line: line)
        XCTAssertEqual(s.stationarityScore, c.stationarityScore, accuracy: 0.01, line: line)
        XCTAssertEqual(s.periodicityScore, c.periodicityScore, accuracy: 0.01, line: line)
        XCTAssertEqual(s.periodicFrequencyHz ?? 0, c.periodicFrequencyHz ?? 0, accuracy: 0.5, line: line)
        XCTAssertEqual(s.lowFrequencyEnergyFraction, c.lowFrequencyEnergyFraction, accuracy: 0.01, line: line)
        XCTAssertEqual(s.cancellationCandidateScore, c.cancellationCandidateScore, accuracy: 0.01, line: line)
        closeBands(s.spectrum, c.spectrum, line: line)
        XCTAssertEqual(s.tonalComponents.count, c.tonalComponents.count, line: line)
        for (x, y) in zip(s.tonalComponents, c.tonalComponents) {
            XCTAssertEqual(x.frequencyHz, y.frequencyHz, accuracy: 1e-6, line: line)
            XCTAssertEqual(x.levelDBFS, y.levelDBFS, accuracy: 0.05, line: line)
            XCTAssertEqual(x.phaseRadians ?? 0, y.phaseRadians ?? 0, accuracy: 0.01, line: line)
        }
    }

    func testMicrophoneOnlyToneMatchesSwiftAtEightRates() throws {
        let (swift, core) = analyzers()
        for rate in rates {
            var mic = noise(0.001, seed: 7)
            for i in 0..<frames { mic[i] += Float(0.1 * sin(2 * Double.pi * 100 * Double(i) / rate)) }
            let s = try swift.analyzeDetailed(microphone: mic, sampleRate: rate)
            let c = try core.analyzeDetailed(microphone: mic, sampleRate: rate)
            closeSnapshots(s.snapshot, c.snapshot)
            XCTAssertEqual(c.separatedResidualSamples, mic, "mic-only residual is the window")
            XCTAssertNil(c.playbackAlignmentLagFrames)
        }
    }

    func testModeledPlaybackSubtractionMatchesSwiftAtEightRates() throws {
        let (swift, core) = analyzers()
        for rate in rates {
            let play = program(rate: rate)
            let lag = 37
            var impulse = [Float](repeating: 0, count: 16)
            impulse[5] = 0.5
            let mic: [Float] = (0..<frames).map { i in
                let j = i - lag - 5
                let p = j >= 0 ? 0.5 * Double(play[j]) : 0
                return Float(p + 0.01 * sin(2 * Double.pi * 60 * Double(i) / rate))
            }
            let source = AmbientPlaybackSourceReference(id: "p", samples: play, acousticImpulseResponse: impulse)
            let s = try swift.analyzeDetailed(microphone: mic, playbackSources: [source], sampleRate: rate)
            let c = try core.analyzeDetailed(microphone: mic, playbackSources: [source], sampleRate: rate)
            XCTAssertEqual(s.snapshot.separationMode, .modeledPlaybackSubtraction)
            XCTAssertEqual(c.playbackAlignmentLagFrames, s.playbackAlignmentLagFrames, "lag at \(rate)")
            XCTAssertEqual(c.playbackAlignmentConfidence ?? 0, s.playbackAlignmentConfidence ?? 0, accuracy: 0.01)
            closeSnapshots(s.snapshot, c.snapshot)
            closeBands(s.modeledPlaybackSpectrum ?? [], c.modeledPlaybackSpectrum ?? [])
            XCTAssertEqual(c.separatedResidualSamples.count, s.separatedResidualSamples.count)
        }
    }

    func testRefusalsMatchSwift() throws {
        let (swift, core) = analyzers()
        let mic = noise(0.1, seed: 3)
        let play = noise(0.1, seed: 4)
        // Unmodelled audible playback is never read as ambient.
        let unmodelled = AmbientPlaybackSourceReference(id: "u", samples: play)
        let s = try swift.analyzeDetailed(microphone: mic, playbackSources: [unmodelled], sampleRate: 48_000)
        let c = try core.analyzeDetailed(microphone: mic, playbackSources: [unmodelled], sampleRate: 48_000)
        XCTAssertEqual(c.snapshot.separationMode, .playbackModelUnavailable)
        closeSnapshots(s.snapshot, c.snapshot)

        func failure(_ analyzer: AmbientFieldAnalyzer, _ mic: [Float], _ sources: [AmbientPlaybackSourceReference],
                     rate: Double) -> AmbientAnalysisError? {
            do {
                _ = try analyzer.analyzeDetailed(microphone: mic, playbackSources: sources, sampleRate: rate)
                return nil
            } catch let error as AmbientAnalysisError { return error } catch { return nil }
        }
        var nanMic = mic
        nanMic[10] = .nan
        var nanPlay = play
        nanPlay[3] = .infinity
        let zeroModel = AmbientPlaybackSourceReference(id: "z", samples: play, acousticImpulseResponse: [0, 0, 0])
        let shortPlay = AmbientPlaybackSourceReference(id: "s", samples: Array(play.prefix(100)))
        let cases: [([Float], [AmbientPlaybackSourceReference], Double)] = [
            (Array(mic.prefix(100)), [], 48_000), (mic, [], 0), (nanMic, [], 48_000),
            (mic, [AmbientPlaybackSourceReference(id: "n", samples: nanPlay)], 48_000), (mic, [zeroModel], 48_000),
            (mic, [shortPlay], 48_000),
        ]
        for (m, sources, rate) in cases {
            let a = failure(swift, m, sources, rate: rate)
            let b = failure(core, m, sources, rate: rate)
            XCTAssertNotNil(a)
            XCTAssertEqual(a, b)
        }
        var bad = AmbientAnalysisConfiguration.production
        bad.spectrumBandCount = 4
        var badCore = AmbientFieldAnalyzer(configuration: bad)
        badCore.useCoreMaths = true
        XCTAssertEqual(failure(badCore, mic, [], rate: 48_000), .invalidConfiguration)
    }

    func testCoreIsDeterministic() throws {
        let (_, core) = analyzers()
        let mic = noise(0.1, seed: 3)
        let a = try core.analyzeDetailed(microphone: mic, playbackSources: [], sampleRate: 48_000)
        let b = try core.analyzeDetailed(microphone: mic, playbackSources: [], sampleRate: 48_000)
        XCTAssertEqual(a, b)
    }
}
