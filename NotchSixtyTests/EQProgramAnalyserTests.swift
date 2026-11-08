import XCTest
@testable import NotchSixty

/// E27 S2b: the program spectrum overlay reuses the render capture and `ProductionAnalysisWorker`
/// (design note 15), so the engine is unchanged. These tests cover the Swift side: the display
/// model, a tone's peak in the input and output spectra with the real EQ in between at the eight
/// rates, and that the controller is inert with the flag off.
@MainActor
final class EQProgramAnalyserTests: XCTestCase {
    private final class FakeSource: EQProgramAnalysisSource {
        var isAnalysisRunning = true
        var snapshot = ProductionAnalysisSnapshot.empty
        private(set) var demands: [UInt32] = []
        func setAnalysisDemand(_ demandMask: UInt32) { demands.append(demandMask) }
        func productionAnalysisSnapshot() -> ProductionAnalysisSnapshot { snapshot }
        private(set) var tapsInstalled: [Bool] = []
        private(set) var tapDemands: [UInt8] = []
        var analyserTapsAvailable = false
        var tapWindow: EQAnalyserTapWindow?
        private(set) var tapReads: [Bool] = []
        func setAnalyserTapsInstalled(_ installed: Bool) { tapsInstalled.append(installed) }
        func setAnalyserTapDemand(_ mask: UInt8) { tapDemands.append(mask) }
        func analyserTapWindow(afterDynamics: Bool, frames: Int) -> EQAnalyserTapWindow? {
            tapReads.append(afterDynamics)
            return tapWindow
        }
    }

    private func defaults() -> UserDefaults {
        let suite = "EQProgramAnalyserTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func snapshot(rate: Double = 48_000) -> ProductionAnalysisSnapshot {
        var snapshot = ProductionAnalysisSnapshot()
        snapshot.sampleRate = rate
        snapshot.spectrum = [
            ProductionSpectrumBand(frequencyHz: 100, inputDB: -40, outputDB: -30, inputPeakHoldDB: -40, outputPeakHoldDB: -30),
            ProductionSpectrumBand(frequencyHz: 1_000, inputDB: -20, outputDB: -8, inputPeakHoldDB: -20, outputPeakHoldDB: -8),
        ]
        return snapshot
    }

    func testSpectrumFromSnapshotAndDisplayMapping() {
        let spectrum = EQProgramSpectrum(snapshot: snapshot())
        XCTAssertEqual(spectrum.frequenciesHz, [100, 1_000])
        XCTAssertEqual(spectrum.inputDB, [-40, -20])
        XCTAssertEqual(spectrum.outputDB, [-30, -8])
        XCTAssertTrue(EQProgramSpectrum(snapshot: .empty).isEmpty)
        XCTAssertEqual(EQProgramSpectrum.fraction(forDB: -80), 0)
        XCTAssertEqual(EQProgramSpectrum.fraction(forDB: 0), 1)
        XCTAssertEqual(EQProgramSpectrum.fraction(forDB: -40), 0.5, accuracy: 1e-12)
        XCTAssertEqual(EQProgramSpectrum.fraction(forDB: -200), 0)
        XCTAssertEqual(EQProgramSpectrum.fraction(forDB: 12), 1)
        XCTAssertEqual(EQProgramSpectrum.fraction(forDB: .nan), 0)
    }

    /// A -20 dBFS 1 kHz tone (the display clamps at 0 dBFS, so the output stays below it) through +12 dB of EQ in the production graph: the analyser's input
    /// peak sits at the tone level and the output peak at the same band, 12 dB higher.
    func testTonePeakShiftsByTheEQGainAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let eq = EQRenderHarness.peakConfiguration(gainDB: 12)
            let result = try EQRenderHarness.render(rate: rate, amplitude: 0.1, specs: [try EQRenderHarness.spec(eq, rate: rate)],
                                                    settleSeconds: 0.2)
            let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
            XCTAssertGreaterThanOrEqual(result.output.count, size, "render too short at \(rate)")
            let start = result.output.count - size
            let output = Array(result.output[start...])
            let input = (0..<size).map { Float(0.1 * sin(2.0 * Double.pi * 1_000 * Double(start + $0) / rate)) }
            let rmsGain = 20 * log10(EQRenderHarness.rms(output[...]) / EQRenderHarness.rms(input[...]))
            XCTAssertEqual(rmsGain, 12, accuracy: 0.2, "time-domain EQ gain at \(rate)")
            let bands = ProductionSpectrumAnalyzer().analyze(
                inputLeft: input, inputRight: input, outputLeft: output, outputRight: output,
                count: size, sampleRate: rate)
            let inputPeak = try XCTUnwrap(bands.max { $0.inputDB < $1.inputDB })
            let outputPeak = try XCTUnwrap(bands.max { $0.outputDB < $1.outputDB })
            XCTAssertEqual(inputPeak.frequencyHz, outputPeak.frequencyHz, "same peak band at \(rate)")
            XCTAssertEqual(Double(inputPeak.inputDB), -20, accuracy: 1.0, "input level at \(rate)")
            XCTAssertEqual(Double(outputPeak.outputDB - inputPeak.inputDB), 12, accuracy: 0.3, "EQ shift at \(rate)")
        }
    }

    func testSwitchPersistsAndLoopHoldsThenReleasesDemand() async throws {
        let source = FakeSource()
        source.snapshot = snapshot()
        let store = defaults()
        let controller = EQProgramAnalyserController(source: source, defaults: store)
        XCTAssertFalse(controller.isOn)
        await controller.run()
        XCTAssertTrue(source.demands.isEmpty, "off: no capture demand")

        controller.setOn(true)
        XCTAssertTrue(store.bool(forKey: PreferenceKeys.Equalizer.programAnalyser))
        let task = Task { await controller.run() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(source.demands, [UInt32(N60_ANALYSIS_DEMAND_SPECTRUM)])
        XCTAssertEqual(controller.spectrum.frequenciesHz, [100, 1_000])

        source.isAnalysisRunning = false
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(source.demands.last, UInt32(N60_ANALYSIS_DEMAND_NONE), "transport stop releases the demand")
        XCTAssertTrue(controller.spectrum.isEmpty)

        source.isAnalysisRunning = true
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(source.demands.last, UInt32(N60_ANALYSIS_DEMAND_SPECTRUM))
        task.cancel()
        await task.value
        XCTAssertEqual(source.demands.last, UInt32(N60_ANALYSIS_DEMAND_NONE), "leaving the page releases the demand")

        controller.setOn(false)
        XCTAssertFalse(store.bool(forKey: PreferenceKeys.Equalizer.programAnalyser))
    }

    // MARK: E27 S2c: analyser taps (design note 16)

    func testModeDefaultsToEQOnlyPersistsAndDrivesTapDemand() async throws {
        let source = FakeSource()
        source.snapshot = snapshot()
        let store = defaults()
        let controller = EQProgramAnalyserController(source: source, defaults: store)
        XCTAssertEqual(source.tapsInstalled, [true], "the idle taps are installed once")
        XCTAssertEqual(controller.mode, .eqOnly)
        controller.setOn(true)
        let task = Task { await controller.run() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(source.tapDemands, [1], "EQ only records the EQ tap")
        controller.setMode(.eqAndDynamics)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(source.tapDemands, [1, 2], "EQ + Dynamics records the after-dynamics tap only")
        controller.setMode(.fullChain)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(source.tapDemands, [1, 2, 0], "the full chain needs no tap")
        XCTAssertEqual(store.string(forKey: PreferenceKeys.Equalizer.programAnalyserMode), "fullChain")
        controller.setMode(.eqOnly)
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        await task.value
        XCTAssertEqual(source.tapDemands, [1, 2, 0, 1, 0], "leaving the page releases the tap demand")
        let reopened = EQProgramAnalyserController(source: source, defaults: store)
        XCTAssertEqual(reopened.mode, .eqOnly)
    }

    func testOutputCurveFallsBackToFullChainWithoutATap() {
        let source = FakeSource()
        source.snapshot = snapshot()
        let controller = EQProgramAnalyserController(source: source, defaults: defaults())
        controller.poll()
        XCTAssertEqual(controller.spectrum.outputLabel, "Output (full chain)", "no tap (kernel path): the S2b curve")
        XCTAssertEqual(controller.spectrum.outputDB, [-30, -8])
        XCTAssertTrue(source.tapReads.isEmpty)
    }

    /// The real graph: both taps installed, demand toggled live, +12 dB EQ then a 0.5 output gain after the taps. The
    /// EQ tap and the controller's tap spectrum show +12 dB at the tone at every rate, whatever follows.
    func testTapSpectrumShowsTheEQStageAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let off = UnifiedGraphAnalyserTaps()
            let on = UnifiedGraphAnalyserTaps(eqDemand: true, dynDemand: true)
            let eq = EQRenderHarness.peakConfiguration(gainDB: 12)
            let host = try UnifiedGraphHost(spec: EQRenderHarness.spec(eq, rate: rate, taps: off))
            let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
            var position = 0
            func run(frames: Int) throws {
                let end = position + frames
                while position < end {
                    let chunk = (0..<512).map { Float(0.1 * sin(2.0 * Double.pi * 1_000 * Double(position + $0) / rate)) }
                    _ = try host.processOffline(input: [chunk, chunk], frames: 512)
                    position += 512
                }
            }
            try run(frames: 4_096)
            XCTAssertNil(host.readAnalyserTap(stageId: UnifiedGraphConfiguration.analyserTapEQStageId, frames: 1_024),
                         "no demand: nothing recorded at \(rate)")
            let before = host.analyserTapWritten(stageId: UnifiedGraphConfiguration.analyserTapEQStageId)
            XCTAssertEqual(before, 0)
            let result = try host.apply(EQRenderHarness.spec(eq, rate: rate, taps: on))
            XCTAssertEqual(result, .posted(count: 2), "demand is a live parameter, not a rebuild at \(rate)")
            try run(frames: size + 4_096)
            let window = try XCTUnwrap(
                host.readAnalyserTap(stageId: UnifiedGraphConfiguration.analyserTapEQStageId, frames: size), "EQ tap at \(rate)")
            let dyn = try XCTUnwrap(
                host.readAnalyserTap(stageId: UnifiedGraphConfiguration.analyserTapDynStageId, frames: size), "dyn tap at \(rate)")
            XCTAssertEqual(window.left.count, size)
            let bands = ProductionSpectrumAnalyzer().analyze(
                inputLeft: window.left, inputRight: window.right, outputLeft: window.left, outputRight: window.right,
                count: size, sampleRate: rate)
            let peak = try XCTUnwrap(bands.max { $0.outputDB < $1.outputDB })
            XCTAssertEqual(Double(peak.outputDB), -20 + 12, accuracy: 1.0, "EQ tap level at \(rate)")
            let dynBands = ProductionSpectrumAnalyzer().analyze(
                inputLeft: dyn.left, inputRight: dyn.right, outputLeft: dyn.left, outputRight: dyn.right,
                count: size, sampleRate: rate)
            XCTAssertEqual(Double(try XCTUnwrap(dynBands.max { $0.outputDB < $1.outputDB }).outputDB), -8, accuracy: 1.0,
                           "no dynamics: the second tap matches the first at \(rate)")
            let written = host.analyserTapWritten(stageId: UnifiedGraphConfiguration.analyserTapEQStageId)
            XCTAssertNil(host.readAnalyserTap(stageId: UnifiedGraphConfiguration.analyserTapEQStageId, frames: size, since: written),
                         "samples before the baseline are not used at \(rate)")
        }
    }
}
