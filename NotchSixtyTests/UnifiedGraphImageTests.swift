import XCTest
@testable import NotchSixty

/// E6 S12b: stereo mode, widener, de-harsh and de-esser settings reach the unified graph through the production
/// translator (they no longer keep the kernel path) and act on a rendered signal at the eight rates.
@MainActor
final class UnifiedGraphImageTests: XCTestCase {
    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_413, uid: "image-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "image-out")
        return engine
    }

    private func render(
        _ engine: AudioIOEngine, rate: Double, left: [Float], right: [Float]
    ) throws -> (UnifiedGraphConfiguration, [[Float]]) {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
            "the image and de-ess settings must not keep the kernel path")
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        var out: [[Float]] = [[], []]
        var position = 0
        while position < left.count {
            let count = min(512, left.count - position)
            let result = try host.processOffline(
                input: [Array(left[position..<position + count]), Array(right[position..<position + count])], frames: count)
            out[0] += result[0]; out[1] += result[1]
            position += count
        }
        return (configuration, out)
    }

    private func tone(_ rate: Double, _ hz: Double, _ amplitude: Double = 0.5) -> [Float] {
        (0..<Int(rate * 0.6)).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    private func rms(_ x: [Float]) -> Double {
        let tail = x[(x.count / 2)...]
        return (tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)).squareRoot()
    }

    func testTrueMonoReachesTheGraphAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            var configuration = DynamicsConfiguration()
            configuration.stereoMode = .trueMono
            let engine = try engine(rate: rate)
            try engine.replaceDynamicsConfiguration(configuration)
            let left = tone(rate, 1_000), silence = [Float](repeating: 0, count: left.count)
            let (graph, out) = try render(engine, rate: rate, left: left, right: silence)
            XCTAssertNotNil(graph.stereoStages.image)
            let tailL = Array(out[0][(left.count * 3 / 4)...]), tailR = Array(out[1][(left.count * 3 / 4)...])
            for (a, b) in zip(tailL, tailR) { XCTAssertEqual(a, b, accuracy: 1e-3, "L equals R at \(rate)") }
            XCTAssertEqual(rms(out[0]), 0.5 * 0.7071 * 0.5, accuracy: 0.01, "mono sum halves the lone channel at \(rate)")
        }
    }

    func testDeEsserReducesASibilantToneAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            let input = tone(rate, 6_500)
            let (offGraph, off) = try render(engine, rate: rate, left: input, right: input)
            XCTAssertNil(offGraph.stereoStages.deess)
            var configuration = DynamicsConfiguration()
            configuration.deEsser.enabled = true
            configuration.deEsser.thresholdDB = -40
            configuration.deEsser.dynamicEQMode = false
            try engine.replaceDynamicsConfiguration(configuration)
            let (onGraph, on) = try render(engine, rate: rate, left: input, right: input)
            XCTAssertNotNil(onGraph.stereoStages.deess)
            XCTAssertLessThan(rms(on[0]), 0.7 * rms(off[0]), "de-esser reduces the tone at \(rate)")
        }
    }

    func testAllOffLeavesBothStagesOut() throws {
        let engine = try engine(rate: 48_000)
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: 48_000)
        let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000))
        XCTAssertNil(configuration.stereoStages.image)
        XCTAssertNil(configuration.stereoStages.deess)
    }
}
