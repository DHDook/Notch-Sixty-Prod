import XCTest
@testable import NotchSixty

/// E6 S12e: global bypass and the reference audition run on the unified graph as the D5 path (decision 16, parity
/// exception P1), and the wide EQ (more than 16 sections per lane, constant-Q and Linkwitz bands) matches the kernel.
/// Delta audition (processed minus the aligned input) runs on the graph as a CAPTURE and SUBTRACT pair (G27).
@MainActor
final class UnifiedGraphBypassAuditionTests: XCTestCase {
    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_416, uid: "bypass-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "bypass-out")
        return engine
    }

    private func noise(_ count: Int, amplitude: Float = 0.9) -> [Float] {
        var state: UInt32 = 7
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float((state >> 8) & 0xFFFF) / 65_536 - 0.5) * 2
        }
    }

    private func render(_ host: UnifiedGraphHost, _ input: [Float]) throws -> [Float] {
        var out: [Float] = []
        var position = 0
        while position < input.count {
            let count = min(512, input.count - position)
            let block = Array(input[position..<position + count])
            out += try host.processOffline(input: [block, block], frames: count)[0]
            position += count
        }
        return out
    }

    private func protect(_ snapshot: inout N60DSPGraphSnapshot) {
        snapshot.protection.limiterEnabled = true
        snapshot.protection.limiterCeilingLinear = 0.5
        snapshot.masterGainLinear = 0.8
    }

    /// An engine snapshot with program DSP on (EQ, compressor) plus a limiter and a master gain.
    private func processedSnapshot(_ engine: AudioIOEngine, rate: Double) throws -> N60DSPGraphSnapshot {
        try engine.addEQBand(EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1))
        var dynamics = DynamicsConfiguration()
        dynamics.compressor.enabled = true
        try engine.replaceDynamicsConfiguration(dynamics)
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        protect(&snapshot)
        snapshot.latencyFrames = 300
        return snapshot
    }

    private func padded(_ configuration: UnifiedGraphConfiguration, _ snapshot: N60DSPGraphSnapshot) -> UnifiedGraphConfiguration {
        var result = configuration
        let pad = Double(Int(snapshot.latencyFrames) - Int(snapshot.protection.latencyFrames))
        for index in result.lanes.indices { result.lanes[index].calibrationDelayFrames += pad }
        return result
    }

    func testBypassAndReferenceEqualAProgramFreeGraphAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            let processed = try processedSnapshot(engine, rate: rate)
            var unity = N60DSPGraphSnapshotMakeUnity(rate)
            protect(&unity)
            unity.latencyFrames = processed.latencyFrames
            let referenceConfig = padded(
                try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &unity, sampleRate: rate)), processed)
            let expected = try render(try UnifiedGraphHost(spec: try referenceConfig.makeSpec()), noise(8_192))
            for mode in 0..<2 {
                var snapshot = processed
                if mode == 0 { snapshot.bypassed = true } else { snapshot.auditionMode = N60AuditionModeReference }
                let configuration = try XCTUnwrap(
                    UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
                    "bypass/reference stays on the graph at \(rate)")
                XCTAssertTrue(configuration.lanes.allSatisfy { $0.eq.isEmpty }, "program EQ removed")
                XCTAssertNil(configuration.stereoStages.compressor, "program dynamics removed")
                XCTAssertNotNil(configuration.protection, "protection kept")
                let actual = try render(try UnifiedGraphHost(spec: try configuration.makeSpec()), noise(8_192))
                XCTAssertEqual(actual.count, expected.count)
                let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
                XCTAssertLessThan(worst, 1e-6, "mode \(mode) at \(rate)")
                let peak = actual.map { abs($0) }.max() ?? 0
                XCTAssertLessThanOrEqual(peak, 0.5 + 1e-3, "the protection ceiling holds at \(rate)")
            }
        }
    }

    func testTogglesStepSmoothlyAndKeepLatency() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            var processed = try processedSnapshot(engine, rate: rate)
            // The processed path adds no latency beyond the protection lookahead, so the D5 pad is zero.
            processed.latencyFrames = processed.protection.latencyFrames
            var a = processed
            var b = processed
            b.bypassed = true
            var c = processed
            c.auditionMode = N60AuditionModeReference
            let specA = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &a, sampleRate: rate)).makeSpec()
            let specB = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &b, sampleRate: rate)).makeSpec()
            let specC = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &c, sampleRate: rate)).makeSpec()
            let host = try UnifiedGraphHost(spec: specA)
            let latency = host.latencyFrames
            let hz = 200.0
            let tone = (0..<Int(rate * 0.25)).map { Float(0.1 * sin(2 * Double.pi * hz * Double($0) / rate)) }
            var out = try render(host, tone)
            for spec in [specB, specC, specA] {
                try host.apply(spec, linearFade: true)
                XCTAssertEqual(host.latencyFrames, latency, "toggle keeps latency at \(rate)")
                out += try render(host, tone)
            }
            // A 200 Hz tone at 0.1 (about 0.4 after the EQ gain) steps by at most 2 pi f / rate * peak per sample.
            let maxSlope = 2 * Double.pi * hz / rate * 0.4
            let step = zip(out.dropFirst(), out).map { Double(abs($0 - $1)) }.max() ?? 0
            XCTAssertLessThan(step, maxSlope + 1e-4, "no click on toggle at \(rate)")
        }
    }

    /// E6 S12e follow-up (G27): the delta audition runs on the graph as processed minus the lane-aligned input, the
    /// kernel's definition, at every rate. The reference is the same snapshot rendered without the audition.
    func testDeltaAuditionIsProcessedMinusTheAlignedInputAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            try engine.addEQBand(EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1))
            var dynamics = DynamicsConfiguration()
            dynamics.compressor.enabled = true
            try engine.replaceDynamicsConfiguration(dynamics)
            var processed = try engine.stereoTransportStartGraph(sampleRate: rate)
            processed.latencyFrames = 0
            var delta = processed
            delta.auditionMode = N60AuditionModeDelta
            var plainSnapshot = processed
            let plain = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &plainSnapshot, sampleRate: rate))
            let audition = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &delta, sampleRate: rate),
                "delta audition is eligible on the graph at \(rate)")
            XCTAssertTrue(audition.deltaAudition)
            XCTAssertFalse(plain.deltaAudition)
            let input = noise(8_192, amplitude: 0.5)
            let plainHost = try UnifiedGraphHost(spec: try plain.makeSpec())
            let deltaHost = try UnifiedGraphHost(spec: try audition.makeSpec())
            XCTAssertEqual(deltaHost.latencyFrames, plainHost.latencyFrames, "the pair adds no latency at \(rate)")
            let latency = Int(plainHost.latencyFrames)
            let expectedProcessed = try render(plainHost, input)
            let actual = try render(deltaHost, input)
            var worst: Float = 0
            for n in 0..<actual.count {
                let aligned: Float = n >= latency ? input[n - latency] : 0
                worst = max(worst, abs(actual[n] - (expectedProcessed[n] - aligned)))
            }
            XCTAssertLessThan(worst, 1e-5, "delta equals processed minus aligned input at \(rate)")
            XCTAssertGreaterThan(actual.map { abs($0) }.max() ?? 0, 0.01, "the delta is audible at \(rate)")
        }
    }

    /// E6 S12e follow-up (G28): bypass and the reference audition with a room correction and a limiter on. The room
    /// correction leaves the path (D5), its latency is kept as a pad, and the limiter ceiling still holds, at every rate.
    func testBypassWithRoomCorrectionAndLimiterEqualsAProgramFreeGraphAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            var processed = try processedSnapshot(engine, rate: rate)
            processed.roomCorrection.enabled = true
            processed.latencyFrames = 700 + processed.protection.latencyFrames
            var unity = N60DSPGraphSnapshotMakeUnity(rate)
            protect(&unity)
            unity.latencyFrames = processed.latencyFrames
            let referenceConfig = padded(
                try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &unity, sampleRate: rate)), processed)
            let reference = try UnifiedGraphHost(spec: try referenceConfig.makeSpec())
            let expected = try render(reference, noise(8_192))
            for mode in 0..<2 {
                var snapshot = processed
                if mode == 0 { snapshot.bypassed = true } else { snapshot.auditionMode = N60AuditionModeReference }
                let configuration = try XCTUnwrap(
                    UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
                    "bypass with room correction stays on the graph at \(rate)")
                XCTAssertNil(configuration.stereoStages.roomFIR, "room correction removed from the path")
                let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
                XCTAssertEqual(host.latencyFrames, reference.latencyFrames, "latency kept at \(rate)")
                let actual = try render(host, noise(8_192))
                let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
                XCTAssertLessThan(worst, 1e-6, "mode \(mode) at \(rate)")
                XCTAssertLessThanOrEqual(actual.map { abs($0) }.max() ?? 0, 0.5 + 1e-3, "limiter ceiling at \(rate)")
            }
        }
    }

    func testWideEQMatchesTheKernelAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            for k in 0..<40 {
                try engine.addEQBand(EQBand(
                    type: .peaking, frequencyHz: 120 + 90 * Double(k), gainDB: Double(k % 5) - 2, q: 1.2,
                    constantQ: k % 3 == 0))
            }
            try engine.addEQBand(EQBand(
                type: .linkwitzTransform, frequencyHz: 60, q: 0.9, linkwitzTargetHz: 35, linkwitzTargetQ: 0.7))
            var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
            let configuration = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
                "a wide EQ stays on the graph at \(rate)")
            XCTAssertGreaterThan(configuration.lanes[0].eq.map(\.slotCount).reduce(0, +), 16)
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            let input = noise(8_192, amplitude: 0.1)
            let graph = try render(host, input)

            let kernel = try XCTUnwrap(N60RenderKernelCreate())
            defer { N60RenderKernelDestroy(kernel) }
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, snapshot))
            var worst = 0.0
            for (index, sample) in input.enumerated() {
                var left: Float = 0, right: Float = 0
                N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
                if index > 2_048 { worst = max(worst, Double(abs(left - graph[index]))) }
            }
            XCTAssertLessThan(worst, 2e-3, "wide EQ parity at \(rate)")
        }
    }
}
