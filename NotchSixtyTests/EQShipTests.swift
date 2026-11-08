import AppKit
import XCTest
@testable import NotchSixty

/// E27 S4: end-to-end tests through production wiring, with the flag gone. Each test drives the page model
/// (`ProductProfileController` and its EQ controllers) against an engine on an offline output, takes the graph
/// the engine would publish (`stereoTransportStartGraph`, the same builder as the live transport start and every
/// EQ republish), translates it with the production translator and renders it through `UnifiedGraphHost` at the
/// eight rates. This is the offline render hook of G6 and G8: the live EQ, gain and analyser-tap stages, no
/// Core Audio transport.
@MainActor
final class EQShipTests: XCTestCase {
    private let rates = EQRenderHarness.rates

    // MARK: Helpers

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_401, uid: "eq-ship-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "eq-ship-out")
        return engine
    }

    private func profiles(_ engine: AudioIOEngine) -> ProductProfileController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
    }

    private func peaking(_ frequency: Double, _ gain: Double, q: Double = 1) -> EQBand {
        EQBand(type: .peaking, frequencyHz: frequency, gainDB: gain, q: q)
    }

    /// The engine's own graph for its current state, rendered offline. `taps` mirrors what the session sets.
    private func host(_ engine: AudioIOEngine, rate: Double, taps: UnifiedGraphAnalyserTaps? = nil) throws -> UnifiedGraphHost {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        var configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        configuration.analyserTaps = taps
        return try UnifiedGraphHost(spec: try configuration.makeSpec())
    }

    private func render(_ host: UnifiedGraphHost, rate: Double, input: [Float]) throws -> [Float] {
        var output: [Float] = []
        var position = 0
        while position < input.count {
            let count = min(512, input.count - position)
            let chunk = Array(input[position..<position + count])
            output += try host.processOffline(input: [chunk, chunk], frames: count)[0]
            position += count
        }
        return output
    }

    private func tone(_ frequency: Double, amplitude: Double, rate: Double, seconds: Double = 0.4) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    /// Steady-state peak of the second half of a tone rendered through `engine`'s graph.
    private func tonePeakDB(_ engine: AudioIOEngine, rate: Double, frequency: Double, amplitudeDB: Double = -1) throws -> Double {
        let amplitude = pow(10, amplitudeDB / 20)
        let out = try render(try host(engine, rate: rate), rate: rate, input: tone(frequency, amplitude: amplitude, rate: rate))
        let peak = out[(out.count / 2)...].reduce(Float(0)) { max($0, abs($1)) }
        return 20 * log10(Double(max(peak, 1e-9)))
    }

    // MARK: Auto preamp

    func testAutoPreampKeepsALiveGraphUnderFullScaleAtEveryRate() throws {
        for rate in rates {
            let engine = try engine(rate: rate)
            let product = profiles(engine)
            try engine.addEQBand(peaking(1_000, 12))
            let off = try tonePeakDB(engine, rate: rate, frequency: 1_000)
            XCTAssertGreaterThan(off, 0, "without auto preamp the live EQ clips a -1 dBFS tone at \(rate)")

            try product.autoPreamp.setOn(true)
            let preamp = engine.gainConfiguration.inputPreampDB
            XCTAssertLessThan(preamp, -11.5, "the page model published the compensation at \(rate)")
            let on = try tonePeakDB(engine, rate: rate, frequency: 1_000)
            XCTAssertLessThan(on, 0, "auto preamp keeps the peak under full scale at \(rate)")
            XCTAssertEqual(on, -1 + 12 + preamp, accuracy: 0.3, "the graph applies the published preamp at \(rate)")

            // Away from the band the same compensation simply lowers the level; nothing clips.
            for frequency in [100.0, 4_000, 10_000] where frequency < rate * 0.45 {
                XCTAssertLessThan(try tonePeakDB(engine, rate: rate, frequency: frequency), 0, "\(frequency) Hz at \(rate)")
            }

            try product.autoPreamp.setOn(false)
            XCTAssertEqual(engine.gainConfiguration.inputPreampDB, 0, accuracy: 1e-9, "off returns the preamp to the trim")
            XCTAssertGreaterThan(try tonePeakDB(engine, rate: rate, frequency: 1_000), 0, "back to the unprotected level at \(rate)")
        }
    }

    /// The S3a lab case (G8): deterministic broadband noise at -1 dBFS peak through +12 dB of EQ and the live gain
    /// stage; with auto preamp the graph's final meter counts no over-range sample.
    func testBroadbandNoiseThroughTheLiveEQHasNoOverRangeWithAutoPreampAtEveryRate() throws {
        for rate in rates {
            let engine = try engine(rate: rate)
            let product = profiles(engine)
            try engine.addEQBand(peaking(1_000, 12))
            try product.autoPreamp.setOn(true)
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            var previous = 0.0
            var noise = (0..<Int(rate * 0.5)).map { _ -> Float in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let white = Double(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
                previous = 0.97 * previous + 0.03 * white
                return Float(previous)
            }
            let peak = noise.reduce(Float(0)) { max($0, abs($1)) }
            let scale = Float(pow(10, -1.0 / 20)) / peak
            noise = noise.map { $0 * scale }
            let host = try host(engine, rate: rate)
            let out = try render(host, rate: rate, input: noise)
            let outPeak = out.reduce(Float(0)) { max($0, abs($1)) }
            XCTAssertLessThan(outPeak, 1, "noise peak after auto preamp at \(rate)")
            XCTAssertEqual(host.overRangeSamples(stageId: N60_LSTAGE_FINAL_METER, lane: 0), 0, "over-range at \(rate)")
        }
    }

    // MARK: Live EQ impulse response (G6)

    /// An impulse through the engine's live EQ, its DFT against `EQFilterAnalysis` (the drawn curve) at the eight rates.
    func testImpulseThroughTheLiveEQMatchesTheDrawnCurveAtEveryRate() throws {
        for rate in rates {
            let engine = try engine(rate: rate)
            let bands = [peaking(250, -6, q: 2), peaking(1_000, 9, q: 1.5), peaking(6_000, -4, q: 0.8)]
            try engine.replaceStereoEQConfiguration(StereoEQConfiguration(linkedBands: bands))
            let host = try host(engine, rate: rate)
            let warmup = Int(rate * 0.05)
            var input = [Float](repeating: 0, count: warmup + Int(rate * 0.4))
            input[warmup] = 1
            let out = try render(host, rate: rate, input: input)
            let h = Array(out[warmup...])
            let analysis = EQFilterAnalysis(bands: bands, phaseMode: .minimumPhase, sampleRate: rate)
            for frequency in [100.0, 250, 700, 1_000, 3_000, 6_000, 12_000] where frequency < rate * 0.45 {
                var re = 0.0, im = 0.0
                let w = 2 * Double.pi * frequency / rate
                for (n, value) in h.enumerated() {
                    re += Double(value) * cos(w * Double(n))
                    im -= Double(value) * sin(w * Double(n))
                }
                let measured = 20 * log10(hypot(re, im))
                XCTAssertEqual(measured, analysis.magnitudeDB(at: frequency), accuracy: 0.05,
                               "\(frequency) Hz at \(rate)")
            }
        }
    }

    // MARK: A/B

    func testABToggleSwitchesThePublishedGraphBetweenSlotsAtEveryRate() throws {
        for rate in rates {
            let engine = try engine(rate: rate)
            let product = profiles(engine)
            try engine.addEQBand(peaking(1_000, 12))
            try product.eqComparison.select(.b, history: nil)
            try engine.replaceStereoEQConfiguration(StereoEQConfiguration(linkedBands: [peaking(1_000, 3)]))
            let b = try tonePeakDB(engine, rate: rate, frequency: 1_000, amplitudeDB: -20)
            XCTAssertEqual(b, -20 + 3, accuracy: 0.2, "slot B in the graph at \(rate)")
            try product.eqComparison.toggle(history: nil)
            XCTAssertEqual(product.eqComparison.activeSlot, .a)
            let a = try tonePeakDB(engine, rate: rate, frequency: 1_000, amplitudeDB: -20)
            XCTAssertEqual(a, -20 + 12, accuracy: 0.2, "slot A back in the graph at \(rate)")
            try product.eqComparison.keep(.b, history: nil)
            XCTAssertEqual(try tonePeakDB(engine, rate: rate, frequency: 1_000, amplitudeDB: -20), -20 + 3, accuracy: 0.2,
                           "Keep makes slot B the live EQ at \(rate)")
            XCTAssertFalse(product.eqComparison.isComparing)
        }
    }

    // MARK: Audition

    func testListenRendersABandPassThenReturnsTheStoredEQAtEveryRate() throws {
        for rate in rates {
            let engine = try engine(rate: rate)
            let product = profiles(engine)
            let band = peaking(4_000, 9, q: 2)
            try engine.addEQBand(band)
            let stored = engine.stereoEQConfiguration
            let normal = try tonePeakDB(engine, rate: rate, frequency: 200, amplitudeDB: -20)
            XCTAssertEqual(normal, -20, accuracy: 0.5, "the stored EQ barely touches 200 Hz at \(rate)")

            product.eqAudition.start(band: engine.stereoEQConfiguration.linkedBands[0])
            let inBand = try tonePeakDB(engine, rate: rate, frequency: 4_000, amplitudeDB: -20)
            let outOfBand = try tonePeakDB(engine, rate: rate, frequency: 200, amplitudeDB: -20)
            XCTAssertEqual(inBand, -20, accuracy: 1.0, "Listen passes the band's own frequency at unity, \(rate)")
            XCTAssertLessThan(outOfBand, -20 - 20, "Listen removes everything away from the band at \(rate)")
            XCTAssertEqual(engine.stereoEQConfiguration, stored, "the stored EQ is untouched while listening")

            product.eqAudition.stop()
            XCTAssertEqual(try tonePeakDB(engine, rate: rate, frequency: 200, amplitudeDB: -20), normal, accuracy: 0.05,
                           "stopping restores the stored EQ in the graph at \(rate)")
        }
    }

    // MARK: Analyser

    func testPageModelDrivesTheAnalyserTapsInTheLiveGraphAtEveryRate() throws {
        for rate in rates {
            let engine = try engine(rate: rate)
            let product = profiles(engine)
            XCTAssertTrue(engine.analyserTapsInstalled, "the page model installs the idle taps once")
            try engine.addEQBand(peaking(1_000, 12))
            let analyser = product.eqProgramAnalyser
            XCTAssertEqual(analyser.mode, .eqOnly)
            let mask = analyser.mode.tapDemand
            let host = try host(
                engine, rate: rate, taps: UnifiedGraphAnalyserTaps(eqDemand: mask & 1 != 0, dynDemand: mask & 2 != 0))
            let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
            let input = tone(1_000, amplitude: 0.1, rate: rate, seconds: Double(size + 8_192) / rate)
            _ = try render(host, rate: rate, input: input)
            let window = try XCTUnwrap(
                host.readAnalyserTap(stageId: UnifiedGraphConfiguration.analyserTapEQStageId, frames: size), "EQ tap at \(rate)")
            let bands = ProductionSpectrumAnalyzer().analyze(
                inputLeft: window.left, inputRight: window.right, outputLeft: window.left, outputRight: window.right,
                count: size, sampleRate: rate)
            let peak = try XCTUnwrap(bands.max { $0.outputDB < $1.outputDB })
            XCTAssertEqual(Double(peak.outputDB), -20 + 12, accuracy: 1.0, "tap shows the EQ's +12 dB at \(rate)")
        }
    }

    // MARK: G17: tap edges

    func testRebuildDropsTheMarkedBaselineSoTheNewRingIsUsable() throws {
        let rate = 48_000.0
        let engine = try engine(rate: rate)
        _ = profiles(engine)
        try engine.addEQBand(peaking(1_000, 12))
        let host = try host(engine, rate: rate, taps: UnifiedGraphAnalyserTaps(eqDemand: true, dynDemand: false))
        let stage = UnifiedGraphConfiguration.analyserTapEQStageId
        _ = try render(host, rate: rate, input: tone(1_000, amplitude: 0.1, rate: rate, seconds: 1.0))
        host.markAnalyserTapBaseline(stageId: stage)
        let marked = host.analyserTapBaseline(stageId: stage)
        XCTAssertGreaterThan(marked, 40_000)
        XCTAssertNil(host.readAnalyserTapSinceBaseline(stageId: stage, frames: 4_096), "nothing recorded since the mark yet")

        // A topology change (a second EQ band) rebuilds the graph and empties the rings.
        try engine.addEQBand(peaking(3_000, -3))
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        var configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        configuration.analyserTaps = UnifiedGraphAnalyserTaps(eqDemand: true, dynDemand: false)
        XCTAssertEqual(try host.apply(try configuration.makeSpec(), linearFade: true), .published)
        XCTAssertEqual(host.analyserTapBaseline(stageId: stage), 0, "the rebuild dropped the stale baseline")
        XCTAssertNil(host.readAnalyserTapSinceBaseline(stageId: stage, frames: 4_096), "the new ring is empty: the curve falls back")
        _ = try render(host, rate: rate, input: tone(1_000, amplitude: 0.1, rate: rate, seconds: 0.5))
        XCTAssertNotNil(host.readAnalyserTapSinceBaseline(stageId: stage, frames: 4_096),
                        "once a window refills the tap is readable, even below the old baseline")
    }

    func testKernelParityOrderOmitsTheAfterDynamicsTap() throws {
        let rate = 48_000.0
        let engine = try engine(rate: rate)
        try engine.addEQBand(peaking(1_000, 6))
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        var configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        configuration.analyserTaps = UnifiedGraphAnalyserTaps(eqDemand: true, dynDemand: true)
        configuration.stereoStages.compressor = [-30, 4, 6, 5, 50, 0, 0, 0, 0, 1]
        configuration.stereoStages.roomFIR = UnifiedGraphFIRProgram(
            generation: 1, left: [1] + [Float](repeating: 0, count: 63), right: nil, declaredLatencyFrames: 0)

        configuration.orderPolicy = .canonical
        let canonical = try configuration.makeSpec().stages.map(\.stageId)
        XCTAssertTrue(canonical.contains(UnifiedGraphConfiguration.analyserTapEQStageId))
        XCTAssertTrue(canonical.contains(UnifiedGraphConfiguration.analyserTapDynStageId), "canonical order has both taps")

        configuration.orderPolicy = .kernelParity
        let parity = try configuration.makeSpec().stages.map(\.stageId)
        XCTAssertTrue(parity.contains(UnifiedGraphConfiguration.analyserTapEQStageId))
        XCTAssertFalse(parity.contains(UnifiedGraphConfiguration.analyserTapDynStageId),
                       "kernel parity runs the compressor after the room convolver, so no after-dynamics tap exists")
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        XCTAssertNil(host.readAnalyserTap(stageId: UnifiedGraphConfiguration.analyserTapDynStageId, frames: 1_024),
                     "readers see the missing tap as unavailable")
    }

    // MARK: G14: page leave

    func testLeavingThePageEndsListenAndTheUndoHistory() throws {
        let engine = try engine(rate: 48_000)
        let product = profiles(engine)
        try engine.addEQBand(peaking(1_000, 6))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let history = EQEditHistory(
            undoManager: undoManager, live: { engine.stereoEQConfiguration },
            apply: { try engine.replaceStereoEQConfiguration($0) })
        let before = engine.stereoEQConfiguration
        var after = before
        after.replaceEditableBands([peaking(1_000, 3)])
        try engine.replaceStereoEQConfiguration(after)
        history.record(before: before, after: after)
        XCTAssertEqual(history.undoStepCount, 1)
        product.eqAudition.start(band: engine.stereoEQConfiguration.linkedBands[0])
        XCTAssertNotNil(engine.eqAudition)

        EQPageLifecycle.leave(history: history, audition: product.eqAudition)
        XCTAssertNil(engine.eqAudition, "Listen ends when the page goes")
        XCTAssertNil(product.eqAudition.active)
        XCTAssertEqual(history.undoStepCount, 0, "no undo step outlives the page")
        XCTAssertEqual(engine.stereoEQConfiguration, after, "the stored EQ is untouched")
    }
}
