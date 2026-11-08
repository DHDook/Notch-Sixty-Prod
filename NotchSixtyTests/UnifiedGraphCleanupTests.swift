import XCTest
@testable import NotchSixty

/// E6 S12a: the DC offset, infrasonic, mains notch and hum detector settings reach the unified graph through the
/// production translator (they no longer keep the kernel path) and act on a rendered signal at the eight rates.
@MainActor
final class UnifiedGraphCleanupTests: XCTestCase {
    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_412, uid: "cleanup-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "cleanup-out")
        return engine
    }

    private func rms(_ engine: AudioIOEngine, rate: Double, hz: Double, dc: Double = 0) throws -> (rms: Double, mean: Double) {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
            "the clean-up filters must not keep the kernel path")
        XCTAssertNotNil(configuration.stereoStages.cleanup)
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        let input = (0..<Int(rate * 1.2)).map { Float(dc + 0.5 * sin(2 * Double.pi * hz * Double($0) / rate)) }
        var out: [Float] = []
        var position = 0
        while position < input.count {
            let count = min(512, input.count - position)
            let chunk = Array(input[position..<position + count])
            out += try host.processOffline(input: [chunk, chunk], frames: count)[0]
            position += count
        }
        let tail = out[(out.count * 3 / 4)...]
        let mean = tail.reduce(0.0) { $0 + Double($1) } / Double(tail.count)
        let power = tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)
        return (power.squareRoot(), mean)
    }

    func testInfrasonicMainsAndDCReachTheGraphAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            var configuration = DynamicsConfiguration()
            configuration.infrasonicFilter.enabled = true
            configuration.infrasonicFilter.cutoffHz = 20
            configuration.mainsNotch.enabled = true
            configuration.dcOffsetFilter.enabled = true
            let engine = try engine(rate: rate)
            try engine.replaceDynamicsConfiguration(configuration)
            let infra = try rms(engine, rate: rate, hz: 5)
            XCTAssertLessThan(infra.rms, 0.5 * 0.7071 * 0.05, "5 Hz is attenuated at \(rate)")
            let hum = try rms(engine, rate: rate, hz: 60)
            XCTAssertLessThan(hum.rms, 0.5 * 0.7071 * 0.5, "60 Hz is notched at \(rate)")
            let passband = try rms(engine, rate: rate, hz: 1_000, dc: 0.2)
            XCTAssertEqual(passband.rms, 0.5 * 0.7071, accuracy: 0.02, "passband at \(rate)")
            XCTAssertEqual(passband.mean, 0, accuracy: 0.01, "DC removed at \(rate)")
        }
    }

    func testAllOffLeavesTheStageOut() throws {
        let engine = try engine(rate: 48_000)
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: 48_000)
        let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000))
        XCTAssertNil(configuration.stereoStages.cleanup)
    }
}
