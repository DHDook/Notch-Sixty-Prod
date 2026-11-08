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

    func testFlagOffIsInertAndNeverSetsDemand() async {
        let source = FakeSource()
        source.snapshot = snapshot()
        let store = defaults()
        store.set(true, forKey: PreferenceKeys.Equalizer.programAnalyser)
        let controller = EQProgramAnalyserController(source: source, isAvailable: false, defaults: store)
        XCTAssertFalse(controller.isOn, "a stored 'on' is ignored with the flag off")
        controller.setOn(true)
        XCTAssertFalse(controller.isOn)
        await controller.run()
        controller.poll()
        XCTAssertTrue(source.demands.isEmpty)
        XCTAssertFalse(controller.isCapturing)
    }

    func testSwitchPersistsAndLoopHoldsThenReleasesDemand() async throws {
        let source = FakeSource()
        source.snapshot = snapshot()
        let store = defaults()
        let controller = EQProgramAnalyserController(source: source, isAvailable: true, defaults: store)
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

    func testProfileControllerBuildsAnalyserInertWithFlagOff() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let off = ProductProfileController(
            engine: AudioIOEngine(), storageURL: root.appendingPathComponent("profiles.json"), autoPreampAvailable: false)
        XCTAssertFalse(off.eqProgramAnalyser.isAvailable)
        let on = ProductProfileController(
            engine: AudioIOEngine(), storageURL: root.appendingPathComponent("profiles2.json"), autoPreampAvailable: true)
        XCTAssertTrue(on.eqProgramAnalyser.isAvailable)
    }
}
