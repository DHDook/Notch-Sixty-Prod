import XCTest
@testable import NotchSixty

/// E6 S12d: the multiband compressor reaches the unified graph through the production translator (it no longer keeps
/// the kernel path), reduces a loud tone, and its settings translate to the core parameter layout at the eight rates.
@MainActor
final class UnifiedGraphMultibandTests: XCTestCase {
    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_415, uid: "multiband-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "multiband-out")
        return engine
    }

    private func render(_ engine: AudioIOEngine, rate: Double, input: [Float]) throws -> (UnifiedGraphConfiguration, [[Float]]) {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
            "the multiband compressor must not keep the kernel path")
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

    private func tone(_ rate: Double, _ hz: Double, _ amplitude: Double) -> [Float] {
        (0..<Int(rate * 0.6)).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    private func rms(_ x: [Float]) -> Double {
        let tail = x[(x.count / 2)...]
        return (tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)).squareRoot()
    }

    func testDisabledLeavesTheStageOut() throws {
        let engine = try engine(rate: 48_000)
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: 48_000)
        let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000))
        XCTAssertNil(configuration.stereoStages.multiband)
    }

    func testEnabledAttachesTheGraphAndReducesALoudToneAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            var configuration = DynamicsConfiguration()
            configuration.multibandCompressor.enabled = true
            configuration.multibandCompressor.lowThresholdDB = -30
            configuration.multibandCompressor.midThresholdDB = -30
            configuration.multibandCompressor.highThresholdDB = -30
            configuration.multibandCompressor.midRatio = 8
            try engine.replaceDynamicsConfiguration(configuration)
            let input = tone(rate, 1_000, 0.5)
            let (graph, out) = try render(engine, rate: rate, input: input)
            let params = try XCTUnwrap(graph.stereoStages.multiband, "multiband at \(rate)")
            XCTAssertEqual(params.count, 29)
            XCTAssertEqual(params[0], 1)
            XCTAssertEqual(params[3], 0, "gentle slope")
            XCTAssertEqual(params[26], 0, "no auto release from the kernel settings")
            XCTAssertLessThan(rms(out[0]) / rms(input), 0.7, "1 kHz tone reduced at \(rate)")
        }
    }

    func testSteepSlopeAndSidechainHighPassTranslate() throws {
        let engine = try engine(rate: 96_000)
        var configuration = DynamicsConfiguration()
        configuration.multibandCompressor.enabled = true
        configuration.multibandCompressor.lowMidSlope = .steep
        configuration.multibandCompressor.midHighSlope = .steep
        configuration.multibandCompressor.lowSidechainHighPassHz = 80
        configuration.multibandCompressor.highMakeupGainDB = 3
        try engine.replaceDynamicsConfiguration(configuration)
        let (graph, _) = try render(engine, rate: 96_000, input: tone(96_000, 1_000, 0.1))
        let params = try XCTUnwrap(graph.stereoStages.multiband)
        XCTAssertEqual(params[3], 1)
        XCTAssertEqual(params[4], 1)
        XCTAssertEqual(params[20], 80, accuracy: 0.01)
        XCTAssertEqual(params[25], 3, accuracy: 0.001)
    }
}
