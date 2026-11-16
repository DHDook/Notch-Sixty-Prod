import XCTest
@testable import NotchSixty

/// E33 S5b: 2 to 5 multiband bands (graph ABI 42). Profile schema, the 73-value block layout, the translator substitution,
/// the widened limits, the frozen-kernel clamp and the graph at the eight rates.
@MainActor
final class MultibandBandsTests: XCTestCase {
    private let rates = EQRenderHarness.rates

    private func fiveBands() -> MultibandCompressorConfiguration {
        var m = MultibandCompressorConfiguration()
        m.enabled = true
        m.setBandCount(5)
        m.lowThresholdDB = -20; m.midThresholdDB = -21; m.highThresholdDB = -22
        m[extraBand: 3].thresholdDB = -23
        m[extraBand: 4].thresholdDB = -24
        m[extraBand: 3].ratio = 7; m[extraBand: 4].ratio = 9
        m[extraBand: 3].attackMs = 0.5; m[extraBand: 4].releaseMs = 4_000
        m[extraBand: 3].kneeDB = 11; m[extraBand: 4].makeupGainDB = -20
        m[extraBand: 4].sidechainHighPassHz = 150
        m.slope2 = .steep
        m.bypassedBands = [4]; m.autoReleaseBands = [3]; m.rmsDetectorBands = [0, 4]
        return m
    }

    func testOldProfilesDecodeAsThreeBands() throws {
        let data = try JSONEncoder().encode(MultibandCompressorConfiguration())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("bandCount"))
        XCTAssertFalse(text.contains("extraBands"))
        let decoded = try JSONDecoder().decode(MultibandCompressorConfiguration.self, from: data)
        XCTAssertNil(decoded.bandCount)
        XCTAssertEqual(decoded.bandCountValue, 3)
        XCTAssertEqual(decoded.translatorBlock(sampleRate: 48_000, bands: true).count, 17, "three bands keep the 17 extras")
        XCTAssertNoThrow(try decoded.validate())
    }

    func testFiveBandProfileRoundTripsAndValidates() throws {
        let m = fiveBands()
        let back = try JSONDecoder().decode(MultibandCompressorConfiguration.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.bandCountValue, 5)
        XCTAssertNoThrow(try back.validate())
    }

    func testBandCountAndCornerOrderingRules() throws {
        var m = MultibandCompressorConfiguration()
        m.bandCount = 6
        XCTAssertThrowsError(try m.validate())
        m.bandCount = 1
        XCTAssertThrowsError(try m.validate())
        m = fiveBands()
        m.corner2Hz = m.midHighFrequencyHz  // equal to the previous corner
        XCTAssertThrowsError(try m.validate())
        m = fiveBands()
        m.corner3Hz = 20_000
        XCTAssertThrowsError(try m.validate())
        // A corner the band count does not use is not checked for order.
        m = fiveBands()
        m.setBandCount(3)
        m.corner2Hz = 5
        XCTAssertNoThrow(try m.validate())
        for count in MultibandCompressorConfiguration.bandCountRange {
            m.setBandCount(count)
            XCTAssertEqual(m.corners.count, count - 1)
            XCTAssertNoThrow(try m.validate(), "preset corners for \(count) bands")
            XCTAssertEqual(m.corners, m.corners.sorted())
        }
    }

    func testWidenedLimitsMatchTheWidebandCompressor() throws {
        XCTAssertEqual(MultibandCompressorConfiguration.thresholdRange, CompressorConfiguration.thresholdRange)
        XCTAssertEqual(MultibandCompressorConfiguration.ratioRange, CompressorConfiguration.ratioRange)
        XCTAssertEqual(MultibandCompressorConfiguration.attackRange, CompressorConfiguration.attackRange)
        XCTAssertEqual(MultibandCompressorConfiguration.releaseRange, CompressorConfiguration.releaseRange)
        XCTAssertEqual(MultibandCompressorConfiguration.kneeRange, CompressorConfiguration.kneeRange)
        XCTAssertEqual(MultibandCompressorConfiguration.makeupRange, CompressorConfiguration.makeupRange)
        var m = MultibandCompressorConfiguration()
        m.lowAttackMs = 0.1; m.midRatio = 80; m.highReleaseMs = 4_000; m.lowThresholdDB = -90
        XCTAssertNoThrow(try m.validate())
        m.midRatio = 101
        XCTAssertThrowsError(try m.validate())
    }

    func testCoreBlockLayoutMatchesTheHeader() {
        let m = fiveBands()
        for rate in rates {
            let b = m.coreBlock(sampleRate: rate)
            XCTAssertEqual(b.count, UnifiedGraphConfiguration.multibandBandsParamCount)
            XCTAssertEqual(b[0], 1)
            XCTAssertEqual(b[1], Float(m.lowMidFrequencyHz)); XCTAssertEqual(b[2], Float(m.midHighFrequencyHz))
            XCTAssertEqual(b[44], 5); XCTAssertEqual(b[45], Float(m.corner2Value)); XCTAssertEqual(b[46], Float(m.corner3Value))
            XCTAssertEqual(b[47], 1, "slope 2 steep"); XCTAssertEqual(b[48], 0)
            XCTAssertEqual(b[5], -20); XCTAssertEqual(b[6], -21); XCTAssertEqual(b[7], -22)
            XCTAssertEqual(b[49], -23); XCTAssertEqual(b[50], -24)         // threshold, bands 4 and 5
            XCTAssertEqual(b[51], 7); XCTAssertEqual(b[52], 9)             // ratio
            XCTAssertEqual(b[53], 0.5)                                     // attack of band 4
            XCTAssertEqual(b[56], 4_000)                                   // release of band 5
            XCTAssertEqual(b[57], 11)                                      // knee of band 4
            XCTAssertEqual(b[60], 150)                                     // sidechain of band 5
            XCTAssertEqual(b[62], -20)                                     // make-up of band 5
            XCTAssertEqual(b[49 + 2 * 7], 1)                               // auto release of band 4 (63)
            XCTAssertEqual(b[49 + 2 * 8 + 1], 1)                           // bypass of band 5
            XCTAssertEqual(b[49 + 2 * 11 + 1], 1)                          // RMS detector of band 5
            XCTAssertEqual(b[5 + 3 * 11], 1)                               // RMS detector of band 1
            XCTAssertEqual(b[5 + 3 * 9], 0); XCTAssertEqual(b[49 + 2 * 9], 0); XCTAssertEqual(b[49 + 2 * 10], 0)  // solo, listen
            XCTAssertEqual(b[42], Float(CompressorConfiguration.lookaheadFrames(ms: 0, sampleRate: rate)))
            XCTAssertEqual(b[43], 1)
        }
    }

    func testKernelMapClampsWidenedValuesAndTheSnapshotBuilds() throws {
        var d = DynamicsConfiguration()
        d.multibandCompressor = fiveBands()
        d.multibandCompressor.lowAttackMs = 0.1
        d.multibandCompressor.midRatio = 80
        d.multibandCompressor.lowMidFrequencyHz = 90
        d.multibandCompressor.midHighFrequencyHz = 12_000
        d.multibandCompressor.corner2Hz = 13_000
        d.multibandCompressor.corner3Hz = 15_000
        d.multibandCompressor.lowThresholdDB = -90
        XCTAssertNoThrow(try d.multibandCompressor.validate())
        XCTAssertNoThrow(try d.makeSnapshot(sampleRate: 48_000), "the frozen kernel setter must accept the clamped values")
        let mapped = d.multibandCompressor.kernelMapped()
        XCTAssertEqual(mapped.lowAttackMs, 1); XCTAssertEqual(mapped.midRatio, 20); XCTAssertEqual(mapped.midHighFrequencyHz, 8_000)
        XCTAssertEqual(mapped.lowThresholdDB, -60)
    }

    // MARK: graph

    private func spec(rate: Double, block: [Float]) -> UnifiedGraphSpec {
        UnifiedGraphSpec(
            sampleRate: rate, maxBlockFrames: 1_024, inputChannels: 2, outputChannels: 2,
            stages: [UnifiedGraphStageSpec(kind: N60_STAGE_MULTIBAND.rawValue, stageId: UnifiedGraphConfiguration.multibandStageId,
                                           laneA: 0, laneB: 1, laneMask: 0, capacityFrames: 0, params: block)])
    }

    private func tone(_ rate: Double, _ hz: Double, _ amplitude: Double, seconds: Double = 0.6) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    private func run(_ host: UnifiedGraphHost, _ input: [Float]) throws -> [Float] {
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

    private func tailRMS(_ x: [Float]) -> Double {
        let tail = x[(x.count / 2)...]
        return (tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)).squareRoot()
    }

    func testEveryBandCountSumsFlatAtEveryRate() throws {
        for rate in rates {
            for count in MultibandCompressorConfiguration.bandCountRange {
                var m = MultibandCompressorConfiguration()
                m.enabled = true
                m.setBandCount(count)
                m.lowThresholdDB = 0; m.midThresholdDB = 0; m.highThresholdDB = 0
                m.lowRatio = 1; m.midRatio = 1; m.highRatio = 1
                m[extraBand: 3].ratio = 1; m[extraBand: 4].ratio = 1
                let host = try UnifiedGraphHost(spec: spec(rate: rate, block: m.coreBlock(sampleRate: rate)))
                for hz in [80.0, 300, 1_000, 5_000, 9_000] where hz < rate * 0.4 {
                    let input = tone(rate, hz, 0.4)
                    let ratio = tailRMS(try run(host, input)) / tailRMS(input)
                    XCTAssertEqual(20 * log10(ratio), 0, accuracy: 0.1, "\(count) bands at \(Int(hz)) Hz, \(rate)")
                }
                host.release()
            }
        }
    }

    func testTheTopBandCompressesOnlyItsOwnRangeAtEveryRate() throws {
        for rate in rates {
            var m = fiveBands()
            m.bypassedBands = nil; m.autoReleaseBands = nil; m.rmsDetectorBands = nil
            m.lowThresholdDB = 0; m.midThresholdDB = 0; m.highThresholdDB = 0
            m.lowRatio = 1; m.midRatio = 1; m.highRatio = 1
            m[extraBand: 3].thresholdDB = 0; m[extraBand: 3].ratio = 1
            m[extraBand: 4].thresholdDB = -40; m[extraBand: 4].ratio = 20; m[extraBand: 4].makeupGainDB = 0
            m[extraBand: 4].releaseMs = 100; m[extraBand: 4].attackMs = 1
            let host = try UnifiedGraphHost(spec: spec(rate: rate, block: m.coreBlock(sampleRate: rate)))
            let high = tone(rate, 12_000, 0.5, seconds: 0.8)
            let low = tone(rate, 200, 0.5, seconds: 0.8)
            let highGain = tailRMS(try run(host, high)) / tailRMS(high)
            host.release()
            let host2 = try UnifiedGraphHost(spec: spec(rate: rate, block: m.coreBlock(sampleRate: rate)))
            let lowGain = tailRMS(try run(host2, low)) / tailRMS(low)
            host2.release()
            if 12_000 < rate * 0.4 { XCTAssertLessThan(highGain, 0.5, "band 5 reduces a 12 kHz tone at \(rate)") }
            XCTAssertEqual(lowGain, 1, accuracy: 0.02, "band 5 leaves 200 Hz alone at \(rate)")
        }
    }

    func testTranslatorSubstitutesTheBlockAndReadsBandReadbacks() throws {
        let rate = 48_000.0
        let output = AudioOutputDevice(
            deviceID: 9_433, uid: "multiband-bands-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "multiband-bands-out")
        var d = DynamicsConfiguration()
        d.multibandCompressor = fiveBands()
        d.multibandCompressor.bypassedBands = nil
        d.multibandCompressor.lowThresholdDB = -50; d.multibandCompressor.lowRatio = 10
        try engine.replaceDynamicsConfiguration(d)
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let block = d.multibandCompressor.translatorBlock(sampleRate: rate, bands: true)
        let configuration = try UnifiedGraphTranslator.stereoEligibility(snapshot: &snapshot, sampleRate: rate, multibandExtras: block).get()
        let params = try XCTUnwrap(configuration.stereoStages.multiband)
        XCTAssertEqual(params, block)
        XCTAssertEqual(params.count, UnifiedGraphConfiguration.multibandBandsParamCount)
        // Without the block the kernel's 29 values stay (flag off).
        var other = try engine.stereoTransportStartGraph(sampleRate: rate)
        let plain = try UnifiedGraphTranslator.stereoEligibility(snapshot: &other, sampleRate: rate).get()
        XCTAssertEqual(try XCTUnwrap(plain.stereoStages.multiband).count, 29)

        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        _ = try run(host, tone(rate, 150, 0.5, seconds: 0.5))
        var diagnostics = N60RenderKernelDiagnostics()
        host.overlayStereoReadbacks(&diagnostics, latencyFrames: 0, includeOutput: true)
        XCTAssertEqual(diagnostics.multibandBandCount, 5)
        XCTAssertGreaterThan(diagnostics.multibandLowGainReductionDB, 3, "low band compresses a 150 Hz tone")
        host.release()
    }

    func testSoloAndListenReachBandsFourAndFive() throws {
        let rate = 48_000.0
        let m = fiveBands()
        let host = try UnifiedGraphHost(spec: spec(rate: rate, block: m.coreBlock(sampleRate: rate)))
        XCTAssertEqual(DynamicsListenStage.multibandBand4.paramIndex, 69)
        XCTAssertEqual(DynamicsListenStage.multibandBand5.paramIndex, 70)
        XCTAssertEqual(DynamicsListenStage.multibandBand5.band, 4)
        try host.setSoloBands([3])
        XCTAssertEqual(host.listenSession.soloBands, [3])
        XCTAssertEqual(try host.setListener(DynamicsListener(stage: .multibandBand5, mode: .sidechain)), .posted(count: 1))
        host.release()
        // A band that does not exist is never soloed in the core: with 3 bands the extra solo slots do not exist at all.
        let three = try UnifiedGraphHost(spec: spec(rate: rate, block: Array(MultibandCompressorConfiguration().coreBlock(sampleRate: rate)[..<44])))
        XCTAssertNoThrow(try three.setSoloBands([1]))
        XCTAssertThrowsError(try three.setListener(DynamicsListener(stage: .multibandBand4, mode: .sidechain)))
        three.release()
    }

    func testPageSpecsCoverBandsFourAndFive() throws {
        for band in 3...4 {
            var d = DynamicsConfiguration()
            d.multibandCompressor.setBandCount(5)
            let rows = DynamicsParameterSpec.multibandBand(band)
            XCTAssertEqual(rows.count, 7)
            for spec in rows {
                XCTAssertTrue(DynamicsParameterSpec.all.contains(where: { $0.id == spec.id }), spec.id)
                d[keyPath: spec.keyPath] = spec.config.lowerBound
                XCTAssertEqual(d[keyPath: spec.keyPath], spec.config.lowerBound, spec.id)
                XCTAssertEqual(spec.defaultValue, DynamicsConfiguration()[keyPath: spec.keyPath])
            }
            XCTAssertNotNil(d.multibandCompressor.extraBands)
        }
        XCTAssertEqual(ProductionDynamicsView.multibandBandTitle(1, of: 3), "Mid Band")
        XCTAssertEqual(ProductionDynamicsView.multibandBandTitle(2, of: 5), "Band 3")
        XCTAssertEqual(ProductionDynamicsView.multibandBandTitle(1, of: 2), "High Band")
    }
}
