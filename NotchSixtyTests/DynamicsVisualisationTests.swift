import XCTest
@testable import NotchSixty

/// E28 S5: the transfer curve against the core, the gain-reduction history and monitor, the expander readback and the
/// ceiling slider's accessibility wording.
@MainActor
final class DynamicsVisualisationTests: XCTestCase {
    // MARK: Curve maths

    func testHardKneeCompressorMatchesTheStaticLaw() {
        let curve = DynamicsTransferCurve(kind: .compressor, thresholdDB: -20, ratio: 4)
        XCTAssertEqual(curve.reductionDB(atInput: -30), 0, accuracy: 1e-9)
        XCTAssertEqual(curve.reductionDB(atInput: -20), 0, accuracy: 1e-9)
        XCTAssertEqual(curve.reductionDB(atInput: 0), 15, accuracy: 1e-9, "20 dB over at 4:1 removes 15 dB")
    }

    func testSoftKneeIsContinuousAndMidKneeIsQuarterWidthRule() {
        for knee in [6.0, 24.0] {
            let curve = DynamicsTransferCurve(kind: .compressor, thresholdDB: -20, ratio: 4, kneeDB: knee)
            XCTAssertEqual(curve.reductionDB(atInput: -20 - knee / 2 - 0.001), 0, accuracy: 1e-3)
            let atEdge = curve.reductionDB(atInput: -20 + knee / 2)
            let above = curve.reductionDB(atInput: -20 + knee / 2 + 0.001)
            XCTAssertEqual(atEdge, above, accuracy: 0.01, "continuous at the upper knee edge, knee \(knee)")
            // Giannoulis/Massberg/Reiss: (1 - 1/R)(x - T + W/2)^2 / (2W) in the knee.
            let mid = (1 - 0.25) * pow(knee / 2, 2) / (2 * knee)
            XCTAssertEqual(curve.reductionDB(atInput: -20), mid, accuracy: 1e-9)
        }
    }

    func testInversionIsExactOnTheCurve() {
        for knee in [0.0, 6.0, 24.0] {
            let curve = DynamicsTransferCurve(kind: .compressor, thresholdDB: -24, ratio: 3, kneeDB: knee, makeupDB: 0)
            for input in stride(from: -40.0, through: 0.0, by: 2.5) {
                let reduction = curve.reductionDB(atInput: input)
                guard reduction > 0.01, let back = curve.inputDB(forReductionDB: reduction) else { continue }
                XCTAssertEqual(curve.reductionDB(atInput: back), reduction, accuracy: 1e-6, "knee \(knee) input \(input)")
            }
        }
    }

    func testNoDotWhenThereIsNoReduction() {
        let curve = DynamicsTransferCurve(kind: .compressor, thresholdDB: -20, ratio: 4)
        XCTAssertNil(curve.livePoint(reductionDB: 0))
        XCTAssertNotNil(curve.livePoint(reductionDB: 5))
    }

    // MARK: Against the core at every rate

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_428, uid: "dynvis-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "dynvis-out")
        return engine
    }

    private func readback(_ engine: AudioIOEngine, rate: Double, amplitude: Double, seconds: Double = 1.5) throws -> N60RenderKernelDiagnostics {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        let frames = Int(rate * seconds)
        let tone = (0..<frames).map { Float(amplitude * sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
        var position = 0
        var diagnostics = N60RenderKernelDiagnostics()
        while position < frames {
            let count = min(512, frames - position)
            let block = Array(tone[position..<position + count])
            _ = try host.processOffline(input: [block, block], frames: count)
            position += count
            // Drain the read-and-reset maximum each block except the last half second, so the final read is the settled value.
            if position < frames - Int(rate * 0.5) { host.overlayStereoReadbacks(&diagnostics, latencyFrames: 0, includeOutput: true) }
        }
        host.overlayStereoReadbacks(&diagnostics, latencyFrames: 0, includeOutput: true)
        return diagnostics
    }

    func testCompressorCurveAgreesWithTheCoreAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            var configuration = DynamicsConfiguration()
            configuration.compressor.enabled = true
            configuration.compressor.thresholdDB = -30
            configuration.compressor.ratio = 4
            configuration.compressor.kneeWidthDB = 0
            configuration.compressor.attackMs = 1
            configuration.compressor.releaseMs = 100
            try engine.replaceDynamicsConfiguration(configuration)
            let diagnostics = try readback(engine, rate: rate, amplitude: 0.1)
            let curve = DynamicsTransferCurve(configuration.compressor)
            // A 0.1 sine peaks at -20 dBFS; the detector sees its peak/RMS, so the figure is bracketed, not exact.
            let lower = curve.reductionDB(atInput: -23.1)
            let upper = curve.reductionDB(atInput: -19.9)
            let measured = Double(diagnostics.compressorGainReductionDB)
            XCTAssertGreaterThan(measured, lower - 0.5, "rate \(rate)")
            XCTAssertLessThan(measured, upper + 0.5, "rate \(rate)")
        }
    }

    func testExpanderAttenuationIsReadFromTheGraph() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            var configuration = DynamicsConfiguration()
            configuration.expander.enabled = true
            configuration.expander.thresholdDB = -20
            configuration.expander.ratio = 3
            configuration.expander.rangeDB = -30
            configuration.expander.attackMs = 1
            try engine.replaceDynamicsConfiguration(configuration)
            let diagnostics = try readback(engine, rate: rate, amplitude: 0.01)
            XCTAssertGreaterThan(diagnostics.expanderAttenuationDB, 3, "a -40 dBFS tone under a -20 dB threshold is attenuated at \(rate)")
        }
    }

    // MARK: History and monitor

    func testHistoryKeepsTenSecondsAndHoldsForOneSecond() {
        var history = GainReductionHistory()
        for i in 0..<1_000 { history.ingest(Float(i % 7), at: Double(i) / 60) }
        XCTAssertEqual(history.points.count, GainReductionHistory.capacity)
        var held = GainReductionHistory()
        held.ingest(10, at: 0)
        held.ingest(2, at: 0.5)
        XCTAssertEqual(held.held(at: 0.6), 10, "holds for a second")
        held.ingest(2, at: 1.2)
        XCTAssertEqual(held.held(at: 1.3), 2, "falls once the hold expires")
        held.ingest(-4, at: 1.4)
        held.ingest(.nan, at: 1.5)
        XCTAssertEqual(held.latest, 0, "negative and non-finite readings count as no reduction")
    }

    func testMonitorFoldsHubMaximaAndThrottlesTheSpokenValue() {
        let monitor = GainReductionMonitor(hub: { nil }, clock: { 0 })
        func reading(_ db: Float) -> [String: MeterChannelReading] {
            [GainReductionSource.compressor.channelID: MeterChannelReading(peakLinear: db, rmsLinear: 0, overRangeSamples: nil, truePeakLinear: nil)]
        }
        monitor.ingest(reading(6), now: 0)
        XCTAssertEqual(monitor.latest(.compressor), 6)
        XCTAssertEqual(monitor.latest(.limiter), 0)
        let first = monitor.spokenValue(.compressor)
        monitor.ingest(reading(12), now: 0.5)
        XCTAssertEqual(monitor.spokenValue(.compressor), first, "accessibility value refreshes at most every 2 s")
        monitor.ingest(reading(12), now: 2.5)
        XCTAssertNotEqual(monitor.spokenValue(.compressor), first)
    }

    func testHubFrameCarriesEverySource() {
        var raw = N60RenderKernelDiagnostics()
        raw.compressorGainReductionDB = 4
        let channels = GainReductionSource.channels(from: RenderKernelDiagnostics(raw))
        XCTAssertEqual(Set(channels.keys), Set(GainReductionSource.allCases.map(\.channelID)))
        XCTAssertEqual(channels[GainReductionSource.compressor.channelID]?.peakLinear, 4)
    }

    // MARK: Ceiling slider accessibility (G20)

    func testCeilingAccessibilityStepsAndClamps() {
        let range = OutputProtectionSettings.ceilingRangeDB
        XCTAssertEqual(OutputCeilingAccessibility.value(-1.0), "-1.0 decibels")
        XCTAssertEqual(OutputCeilingAccessibility.adjusted(-1.0, up: false), -1.1, accuracy: 1e-9)
        XCTAssertEqual(OutputCeilingAccessibility.adjusted(range.upperBound, up: true), range.upperBound, accuracy: 1e-9)
        XCTAssertEqual(OutputCeilingAccessibility.adjusted(range.lowerBound, up: false), range.lowerBound, accuracy: 1e-9)
        XCTAssertFalse(OutputCeilingAccessibility.label.isEmpty)
    }
}
