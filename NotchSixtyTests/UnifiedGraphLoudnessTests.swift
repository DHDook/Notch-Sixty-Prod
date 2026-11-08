import XCTest
@testable import NotchSixty

/// E6 S12c: loudness match, contour and dialogue leveler settings reach the unified graph through the production
/// translator (they no longer keep the kernel path) and act on a rendered signal at the eight rates.
@MainActor
final class UnifiedGraphLoudnessTests: XCTestCase {
    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_414, uid: "loudness-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "loudness-out")
        return engine
    }

    private func render(
        _ engine: AudioIOEngine, rate: Double, input: [Float], masterGain: Float? = nil
    ) throws -> (UnifiedGraphConfiguration, [[Float]]) {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        if let masterGain { snapshot.masterGainLinear = masterGain }
        let configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
            "the loudness settings must not keep the kernel path")
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        var out: [[Float]] = [[], []]
        var position = 0
        while position < input.count {
            let count = min(512, input.count - position)
            let block = Array(input[position..<position + count])
            let result = try host.processOffline(input: [block, block], frames: count)
            out[0] += result[0]; out[1] += result[1]
            position += count
        }
        return (configuration, out)
    }

    private func tone(_ rate: Double, _ hz: Double, _ amplitude: Double = 0.1) -> [Float] {
        (0..<Int(rate * 0.6)).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    private func rms(_ x: [Float]) -> Double {
        let tail = x[(x.count / 2)...]
        return (tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)).squareRoot()
    }

    func testAllOffLeavesTheStageOut() throws {
        let engine = try engine(rate: 48_000)
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: 48_000)
        let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000))
        XCTAssertNil(configuration.stereoStages.loudness)
    }

    func testEachPartAttachesTheGraphAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            var configuration = DynamicsConfiguration()
            configuration.loudnessMatch.enabled = true
            configuration.loudnessMatch.attackSeconds = 1.25
            try engine.replaceDynamicsConfiguration(configuration)
            var (graph, _) = try render(engine, rate: rate, input: tone(rate, 1_000))
            XCTAssertEqual(try XCTUnwrap(graph.stereoStages.loudness)[0], 1, "match at \(rate)")

            configuration = DynamicsConfiguration()
            configuration.loudnessContour.enabled = true
            configuration.loudnessContour.strength = 0.7
            try engine.replaceDynamicsConfiguration(configuration)
            (graph, _) = try render(engine, rate: rate, input: tone(rate, 1_000))
            XCTAssertEqual(try XCTUnwrap(graph.stereoStages.loudness)[6], 1, "contour at \(rate)")

            configuration.loudnessContour.levelSource = .integrated
            try engine.replaceDynamicsConfiguration(configuration)
            (graph, _) = try render(engine, rate: rate, input: tone(rate, 1_000))
            XCTAssertEqual(try XCTUnwrap(graph.stereoStages.loudness)[9], 1, "per-band source at \(rate)")

            configuration = DynamicsConfiguration()
            configuration.dialogueRelativeLeveler.enabled = true
            configuration.dialogueRelativeLeveler.voiceGate.enabled = true
            try engine.replaceDynamicsConfiguration(configuration)
            (graph, _) = try render(engine, rate: rate, input: tone(rate, 1_000))
            XCTAssertEqual(try XCTUnwrap(graph.stereoStages.loudness)[14], 1, "leveler at \(rate)")
        }
    }

    func testContourBoostsABassToneAtLowVolumeAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            let input = tone(rate, 80)
            let (_, off) = try render(engine, rate: rate, input: input, masterGain: 0.05)
            var configuration = DynamicsConfiguration()
            configuration.loudnessContour.enabled = true
            try engine.replaceDynamicsConfiguration(configuration)
            let (_, on) = try render(engine, rate: rate, input: input, masterGain: 0.05)
            XCTAssertGreaterThan(rms(on[0]), 1.2 * rms(off[0]), "contour lifts the bass at \(rate)")
        }
    }
}
