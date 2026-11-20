import XCTest
@testable import NotchSixty

/// E33 S11b part 4 (G110, G6, G94/G109 offer switch): end-to-end and lab cases through production wiring at the eight rates,
/// with `e33.page-enhancements` on. Same harness as `E33ShipEndToEndTests` (engine publish path, `UnifiedGraphHost`).
extension E33ShipEndToEndTests {
    private func settledGain(_ host: UnifiedGraphHost, hz: Double, amplitude: Double, rate: Double) throws -> Double {
        let n = Int(rate * 0.5)
        let input = tone(hz, amplitude: amplitude, rate: rate, frames: n)
        let out = try run(host, input: input)
        let tail = (n - Int(rate * 0.1))..<n
        return 20 * log10(rms(out[tail]) / rms(input[tail]))
    }

    // MARK: G110 linear-phase convolver render

    /// The linear-phase FIR designed the way the engine designs it (`EQFIRDesigner`, the taps and declared latency the
    /// engine hands the convolver) is attached to the published stereo graph as the program convolver and rendered by the
    /// core. A transport session cannot be built offline (it opens Core Audio), so the attach is done as the translator does
    /// it (`stereoStages.programFIR`). The render holds the band's gain at its centre, the impulse is late by the declared
    /// latency and the graph reports it. Every length the stage budget carries, at every rate.
    func testLinearPhaseFIRRendersThroughTheGraphAtEveryRate() throws {
        for rate in rates {
            for length in [EQLinearPhaseLength.ms21, .ms85] where length.refusal(sampleRate: rate, laneCount: 2) == nil {
                var configuration = StereoEQConfiguration(linkedBands: [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1)])
                configuration.phaseMode = .linearPhase
                configuration.linearPhaseLength = length
                let design = try EQFIRDesigner.design(configuration, sampleRate: rate)
                var graph = try published(try engine(rate: rate), rate: rate)
                graph.stereoStages.programFIR = UnifiedGraphFIRProgram(
                    generation: 1, left: design.left, right: design.right, declaredLatencyFrames: design.declaredLatencyFrames)
                let spec = try graph.makeSpec()

                let host = try UnifiedGraphHost(spec: spec)
                defer { host.release() }
                let flat = try UnifiedGraphHost(spec: try published(try engine(rate: rate), rate: rate).makeSpec())
                defer { flat.release() }
                // The convolver adds its own block alignment (a multiple of 256 frames) on top of the declared latency.
                let extra = Int(host.latencyFrames) - Int(flat.latencyFrames) - Int(design.declaredLatencyFrames)
                XCTAssertTrue(extra >= 0 && extra % 256 == 0 && extra <= 512, "reported latency extra \(extra), \(length) at \(rate)")

                XCTAssertEqual(try settledGain(host, hz: 1_000, amplitude: 0.05, rate: rate), 6, accuracy: 0.5, "\(length) at \(rate)")
                XCTAssertEqual(try settledGain(host, hz: 10_000, amplitude: 0.05, rate: rate), 0, accuracy: 0.5, "far from the band, \(length) at \(rate)")
            }
        }
    }

    /// The impulse of the same graph peaks at the declared latency plus the graph's own (linear phase: delay, no ringing before it).
    func testLinearPhaseImpulseIsLateByTheDeclaredLatency() throws {
        for rate in rates {
            var configuration = StereoEQConfiguration(linkedBands: [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1)])
            configuration.phaseMode = .linearPhase
            let design = try EQFIRDesigner.design(configuration, sampleRate: rate)
            var graph = try published(try engine(rate: rate), rate: rate)
            let flat = try UnifiedGraphHost(spec: graph.makeSpec())
            defer { flat.release() }
            graph.stereoStages.programFIR = UnifiedGraphFIRProgram(
                generation: 1, left: design.left, right: design.right, declaredLatencyFrames: design.declaredLatencyFrames)
            let host = try UnifiedGraphHost(spec: graph.makeSpec())
            defer { host.release() }
            var impulse = [Float](repeating: 0, count: 8_192 + design.left.count)
            impulse[100] = 0.3
            func peak(_ h: UnifiedGraphHost) throws -> Int {
                let out = try run(h, input: impulse)
                return try XCTUnwrap(out.indices.max { abs(out[$0]) < abs(out[$1]) })
            }
            // The measured delay equals what the graph reports, and is the declared latency plus the convolver's block alignment.
            let measured = try peak(host) - peak(flat)
            XCTAssertEqual(measured, Int(host.latencyFrames) - Int(flat.latencyFrames), accuracy: 1, "reported equals measured at \(rate)")
            let extra = measured - Int(design.declaredLatencyFrames)
            XCTAssertTrue(extra >= 0 && extra % 256 <= 1 || extra % 256 >= 255, "alignment \(extra) at \(rate)")
        }
    }

    // MARK: Saved EQ offer switch (G94, G109)

    /// A saved EQ keeps its cookbook band until the user takes "Use matched filters"; the page's switch (eligible bands set to
    /// `.matched` through `updateEQBand`) changes the published graph at 44.1 and 48 kHz, where the cookbook bell has
    /// collapsed at 20 kHz, and leaves a band the design does not apply to alone.
    func testSavedEQOfferSwitchChangesThePublishedGraph() throws {
        for rate in rates where rate <= 48_000 {
            let saved = EQBand(type: .peaking, frequencyHz: 15_000, gainDB: 6, q: 1)
            XCTAssertNotEqual(saved.filterMethod, .matched, "a saved band stays cookbook")
            XCTAssertEqual(EQMatchedFiltersPolicy.eligible([saved]).count, 1)
            var edges: [Double] = []
            let e = try engine(rate: rate)
            try e.replaceStereoEQConfiguration(StereoEQConfiguration(linkedBands: [saved]))
            for step in 0..<2 {
                if step == 1 {
                    for var band in EQMatchedFiltersPolicy.eligible(e.stereoEQConfiguration.linkedBands) {
                        band.filterMethod = .matched
                        try e.updateEQBand(band)
                    }
                    XCTAssertTrue(EQMatchedFiltersPolicy.eligible(e.stereoEQConfiguration.linkedBands).isEmpty, "the offer goes once taken")
                }
                let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
                defer { host.release() }
                edges.append(try settledGain(host, hz: 20_000, amplitude: 0.05, rate: rate))
            }
            XCTAssertGreaterThan(edges[1] - edges[0], 2.5, "taking the offer restores the bell at 20 kHz, \(rate)")
        }
    }

    // MARK: G6 headroom strip and RTA

    /// G6: with an EQ boost and the compressor on, the strip the Meters page builds from the graph's own readings equals the
    /// peaks of what went in and what came out, at the eight rates (the same reading path the hub overlay uses).
    func testHeadroomStripEqualsHubPeaksWithEQAndDynamicsOn() throws {
        for rate in rates {
            let e = try engine(rate: rate)
            try e.replaceStereoEQConfiguration(StereoEQConfiguration(linkedBands: [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1)]))
            var d = DynamicsConfiguration()
            d.compressor.enabled = true
            d.compressor.thresholdDB = -18
            try e.replaceDynamicsConfiguration(d)
            let host = try UnifiedGraphHost(spec: try published(e, rate: rate).makeSpec())
            defer { host.release() }
            let n = Int(rate * 0.5)
            let input = tone(1_000, amplitude: 0.2, rate: rate, frames: n)
            let out = try run(host, input: input)
            var diagnostics = N60RenderKernelDiagnostics()
            host.overlayStereoReadbacks(&diagnostics, latencyFrames: 0, includeOutput: true)

            // The same mapping the Meters page uses (ProductionMetersView, `enhanced` branch).
            var strip = HeadroomStripModel()
            strip.update(peaks: [
                "input": max(diagnostics.inputMeter.peakLeft, diagnostics.inputMeter.peakRight),
                "postEQ": max(diagnostics.postEQMeter.peakLeft, diagnostics.postEQMeter.peakRight),
                "output": max(diagnostics.outputMeter.peakLeft, diagnostics.outputMeter.peakRight),
            ])
            func db(_ x: Float) -> Double { 20 * log10(Double(x)) }
            let inputPeak = db(input.map { abs($0) }.max() ?? 0)
            let outputPeak = db(out.map { abs($0) }.max() ?? 0)
            let points = Dictionary(uniqueKeysWithValues: strip.points.map { ($0.id, $0) })
            XCTAssertEqual(try XCTUnwrap(points["input"]).holdDBFS, inputPeak, accuracy: 0.1, "input at \(rate)")
            XCTAssertEqual(try XCTUnwrap(points["output"]).holdDBFS, outputPeak, accuracy: 0.1, "output at \(rate)")
            XCTAssertGreaterThan(try XCTUnwrap(points["postEQ"]).holdDBFS, inputPeak + 3, "the +6 dB boost shows post-EQ at \(rate)")
            strip.reset()
            XCTAssertEqual(strip.points.map(\.holdDBFS), [Double](repeating: HeadroomStripModel.floorDB, count: 3))
        }
    }

    /// G6: deterministic pink noise (Voss-McCartney, seeded) rendered through the published graph and fed to the analysis
    /// feed the Meters page owns reads on the third-octave RTA as the source does, 100 Hz to 5 kHz, at the eight rates.
    func testPinkNoiseThroughTheGraphReadsFlatOnTheRTA() throws {
        for rate in rates {
            let rta = ThirdOctaveRTA(sampleRate: rate)
            let frames = Int(Double(ThirdOctaveRTA.lowSize * rta.decimation) / rate * rate) + Int(rate * 0.5)
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func white() -> Double {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                return Double(seed >> 11) / Double(1 << 53) * 2 - 1
            }
            var rows = [Double](repeating: 0, count: 16)
            var sum = 0.0
            var input = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                let changes = (i == 0) ? 16 : min(i.trailingZeroBitCount + 1, 16)
                for r in 0..<changes { sum -= rows[r]; rows[r] = white(); sum += rows[r] }
                input[i] = Float(0.08 * (sum + white()) / 4)
            }
            let host = try UnifiedGraphHost(spec: try published(try engine(rate: rate), rate: rate).makeSpec())
            defer { host.release() }
            let out = try run(host, input: input)
            func spread(_ x: [Float]) -> (Double, Double) {
                let feed = ProductionAnalysisMeterFeed()
                feed.setActive(meters: false, rta: true, sampleRate: rate)
                let frames = x.map { N60AnalysisFrame(inputLeft: $0, inputRight: $0, outputLeft: $0, outputRight: $0) }
                frames.withUnsafeBufferPointer { feed.ingest($0) }
                let levels = feed.rtaLevels()
                let band = zip(RTABandMap.bandIndices, levels).filter { RTABandMap.centre($0.0) >= 100 && RTABandMap.centre($0.0) <= 5_000 }.map { Double($0.1) }
                return (band.max() ?? 0, band.min() ?? 0)
            }
            // The graph is transparent with EQ and dynamics flat: the RTA of its output matches the RTA of the noise itself,
            // band by band extremes within 0.3 dB, and the noise is pink to within the generator's own ripple.
            let source = spread(input), rendered = spread(out)
            XCTAssertNotEqual(source.0, source.1, "rings full at \(rate)")
            XCTAssertEqual(rendered.0, source.0, accuracy: 0.3, "top band at \(rate)")
            XCTAssertEqual(rendered.1, source.1, accuracy: 0.3, "bottom band at \(rate)")
            XCTAssertLessThan(source.0 - source.1, 8, "pink source spread at \(rate)")
        }
    }
}
