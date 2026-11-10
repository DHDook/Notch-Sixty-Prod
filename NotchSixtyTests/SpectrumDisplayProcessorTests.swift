import XCTest
@testable import NotchSixty

final class SpectrumDisplayProcessorTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func toneBands(rate: Double) -> [ProductionSpectrumBand] {
        let analyzer = ProductionSpectrumAnalyzer()
        let count = ProductionAnalysisMath.fftSize(sampleRate: rate)
        let tone = (0..<count).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
        return analyzer.analyze(
            inputLeft: tone, inputRight: tone, outputLeft: tone, outputRight: tone,
            count: count, sampleRate: rate
        )
    }

    private func peakIndex(_ bands: [ProductionSpectrumBand]) -> Int {
        bands.indices.max(by: { bands[$0].outputDB < bands[$1].outputDB })!
    }

    private func flat(_ bands: [ProductionSpectrumBand], db: Float) -> [ProductionSpectrumBand] {
        bands.map {
            ProductionSpectrumBand(
                frequencyHz: $0.frequencyHz, inputDB: db, outputDB: db,
                inputPeakHoldDB: db, outputPeakHoldDB: db
            )
        }
    }

    func testToneKeepsItsPeakBandAtEverySmoothingAndRate() {
        for rate in rates {
            let raw = toneBands(rate: rate)
            XCTAssertEqual(raw.count, 288)
            let reference = peakIndex(raw)
            XCTAssertLessThan(abs(raw[reference].frequencyHz - 1_000), 60, "rate \(rate)")
            for smoothing in SpectrumSmoothing.allCases {
                var processor = SpectrumDisplayProcessor()
                processor.ingest(raw, averaging: .off, deltaSeconds: 0.05)
                var options = SpectrumDisplayOptions()
                options.smoothing = smoothing
                let shown = processor.display(options: options)
                XCTAssertEqual(shown.count, raw.count)
                XCTAssertLessThanOrEqual(
                    abs(peakIndex(shown) - reference), 1,
                    "\(smoothing) moved the peak at \(rate) Hz"
                )
                if smoothing != .off {
                    XCTAssertLessThanOrEqual(shown[reference].outputDB, raw[reference].outputDB + 0.001)
                }
            }
        }
    }

    func testSmoothingNeverChangesAFlatSpectrum() {
        let raw = flat(toneBands(rate: 48_000), db: -30)
        var processor = SpectrumDisplayProcessor()
        processor.ingest(raw, averaging: .off, deltaSeconds: 0.05)
        for smoothing in SpectrumSmoothing.allCases {
            var options = SpectrumDisplayOptions()
            options.smoothing = smoothing
            for band in processor.display(options: options) {
                XCTAssertEqual(band.outputDB, -30, accuracy: 0.001)
            }
        }
    }

    func testWiderSmoothingFlattensMore() {
        let raw = toneBands(rate: 96_000)
        var processor = SpectrumDisplayProcessor()
        processor.ingest(raw, averaging: .off, deltaSeconds: 0.05)
        var previous = Float.infinity
        for smoothing in SpectrumSmoothing.allCases {
            var options = SpectrumDisplayOptions()
            options.smoothing = smoothing
            let level = processor.display(options: options).map(\.outputDB).max()!
            XCTAssertLessThanOrEqual(level, previous + 0.001)
            previous = level
        }
    }

    func testThreeDBTiltFlattensPinkSpectrumAtEveryRate() {
        for rate in rates {
            // The analyzer reports per-bin density, so pink noise slopes -3 dB/oct about 1 kHz.
            let layout = toneBands(rate: rate)
            let pink = layout.map { band -> ProductionSpectrumBand in
                let level = SpectrumDisplayProcessor.tiltOffsetDB(frequency: band.frequencyHz, dbPerOctave: -3) - 20
                return ProductionSpectrumBand(
                    frequencyHz: band.frequencyHz, inputDB: level, outputDB: level,
                    inputPeakHoldDB: level, outputPeakHoldDB: level
                )
            }
            var processor = SpectrumDisplayProcessor()
            processor.ingest(pink, averaging: .off, deltaSeconds: 0.05)
            var options = SpectrumDisplayOptions()
            options.tilt = .db3
            options.smoothing = .octave3
            let shown = processor.display(options: options).map(\.outputDB)
            XCTAssertLessThan((shown.max()! - shown.min()!), 0.5, "rate \(rate)")
            options.tilt = .flat
            let untilted = processor.display(options: options).map(\.outputDB)
            XCTAssertGreaterThan(untilted.max()! - untilted.min()!, 10)
        }
    }

    func testTiltIsZeroAtOneKilohertzAndSignedPerOctave() {
        XCTAssertEqual(SpectrumDisplayProcessor.tiltOffsetDB(frequency: 1_000, dbPerOctave: 4.5), 0, accuracy: 1e-6)
        XCTAssertEqual(SpectrumDisplayProcessor.tiltOffsetDB(frequency: 2_000, dbPerOctave: 4.5), 4.5, accuracy: 1e-5)
        XCTAssertEqual(SpectrumDisplayProcessor.tiltOffsetDB(frequency: 500, dbPerOctave: 3), -3, accuracy: 1e-5)
    }

    func testAveragingTimeConstantsAreWithinTwoPercentAtEveryRate() {
        // Power steps from the floor to 0 dB; after one time constant the average
        // should sit at 1 - 1/e of the step. Frames arrive at the worker's 20 Hz.
        for rate in rates {
            let layout = toneBands(rate: rate)
            let silent = flat(layout, db: -80)
            let loud = flat(layout, db: 0)
            for (mode, tau) in [(SpectrumAveraging.ms125, 0.125), (.s1, 1.0)] {
                var processor = SpectrumDisplayProcessor()
                processor.ingest(silent, averaging: mode, deltaSeconds: 0.05)
                let frames = Int((tau / 0.05).rounded())
                for _ in 0..<frames { processor.ingest(loud, averaging: mode, deltaSeconds: 0.05) }
                let power = pow(10, Double(processor.display(options: SpectrumDisplayOptions())[0].outputDB) / 10)
                let expected = 1 - exp(-Double(frames) * 0.05 / tau)
                XCTAssertEqual(power, expected, accuracy: 0.02 * expected, "\(mode) at \(rate)")
            }
        }
    }

    func testInfiniteAveragingIsTheRunningMeanOfPower() {
        let layout = toneBands(rate: 48_000)
        var processor = SpectrumDisplayProcessor()
        let levels: [Float] = [0, -10, -20, -30]
        for level in levels {
            processor.ingest(flat(layout, db: level), averaging: .infinite, deltaSeconds: 0.05)
        }
        let mean = levels.map { pow(10, Double($0) / 10) }.reduce(0, +) / Double(levels.count)
        let shown = pow(10, Double(processor.display(options: SpectrumDisplayOptions())[10].outputDB) / 10)
        XCTAssertEqual(shown, mean, accuracy: 0.02 * mean)
    }

    func testChangingBandLayoutRestartsTheAverage() {
        var processor = SpectrumDisplayProcessor()
        processor.ingest(flat(toneBands(rate: 48_000), db: 0), averaging: .infinite, deltaSeconds: 0.05)
        processor.ingest(flat(toneBands(rate: 48_000), db: 0), averaging: .infinite, deltaSeconds: 0.05)
        let other = flat(toneBands(rate: 32_000), db: -40)
        processor.ingest(other, averaging: .infinite, deltaSeconds: 0.05)
        XCTAssertEqual(processor.display(options: SpectrumDisplayOptions())[0].outputDB, -40, accuracy: 0.001)
    }

    func testAxisMapsFrequencyToPositionAndBackAtEveryRate() {
        for rate in rates {
            let axis = SpectrumAxis(maximumFrequency: toneBands(rate: rate).last!.frequencyHz)
            XCTAssertEqual(axis.fraction(frequency: 20), 0, accuracy: 1e-9)
            XCTAssertEqual(axis.fraction(frequency: axis.maximumFrequency), 1, accuracy: 1e-9)
            for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
                let frequency = axis.frequency(fraction: fraction)
                XCTAssertEqual(axis.fraction(frequency: frequency), fraction, accuracy: 1e-9)
            }
        }
    }

    func testHoverPicksTheBandUnderThePointerAndTheReference() {
        for rate in rates {
            let bands = toneBands(rate: rate)
            let axis = SpectrumAxis(maximumFrequency: bands.last!.frequencyHz)
            let reference = SpectrumReference(frequencies: bands.map(\.frequencyHz), levelsDB: bands.indices.map { Float($0) * -0.1 })
            let fraction = axis.fraction(frequency: 1_000)
            let readout = SpectrumDisplayProcessor.hoverReadout(
                fraction: fraction, bands: bands, axis: axis, reference: reference
            )
            XCTAssertNotNil(readout)
            XCTAssertLessThan(abs(readout!.frequencyHz - 1_000), 40, "rate \(rate)")
            let index = bands.firstIndex { $0.frequencyHz == readout!.frequencyHz }!
            XCTAssertEqual(readout!.outputDB, bands[index].outputDB)
            XCTAssertEqual(readout!.referenceDB!, Float(index) * -0.1, accuracy: 1e-4)
            XCTAssertNil(SpectrumDisplayProcessor.hoverReadout(fraction: 0.5, bands: [], axis: axis, reference: nil))
        }
    }

    @MainActor
    func testReferenceNeverChangesAndFreezeHoldsTheDisplay() {
        let suite = "spectrum.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SpectrumDisplayModel(defaults: defaults)
        let layout = toneBands(rate: 48_000)

        model.ingest(flat(layout, db: -20), now: 1)
        model.captureReference()
        let captured = model.reference
        XCTAssertEqual(captured?.levelsDB.first, -20)

        model.ingest(flat(layout, db: -50), now: 1.05)
        XCTAssertEqual(model.reference, captured, "new frames must not alter the reference")
        model.options.tilt = .db45
        model.options.smoothing = .octave3
        XCTAssertEqual(model.reference, captured, "options must not alter the reference")

        model.options.tilt = .flat
        model.options.smoothing = .off
        model.setFrozen(true)
        let frozen = model.bands
        model.ingest(flat(layout, db: -70), now: 1.1)
        XCTAssertEqual(model.bands, frozen)
        model.setFrozen(false)
        model.ingest(flat(layout, db: -70), now: 1.2)
        XCTAssertEqual(model.bands.first?.outputDB ?? 0, -70, accuracy: 0.001)

        model.clearReference()
        XCTAssertNil(model.reference)
    }

    @MainActor
    func testOptionsPersistAcrossModels() {
        let suite = "spectrum.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SpectrumDisplayOptions.load(from: defaults), SpectrumDisplayOptions())
        let first = SpectrumDisplayModel(defaults: defaults)
        first.options.smoothing = .octave6
        first.options.averaging = .s1
        first.options.tilt = .db3
        first.options.showInput = false
        first.options.showPeakHold = false
        let second = SpectrumDisplayModel(defaults: defaults)
        XCTAssertEqual(second.options, first.options)
        XCTAssertEqual(second.options.smoothing, .octave6)
        XCTAssertFalse(second.options.showInput)
    }

    func testReadoutTextIncludesReferenceDifference() {
        let line = SpectrumReadoutText.line(
            SpectrumHoverReadout(frequencyHz: 1_000, inputDB: -20, outputDB: -18, referenceDB: -20)
        )
        XCTAssertTrue(line.contains("1000 Hz") || line.contains("1.00 kHz"))
        XCTAssertTrue(line.contains("+2.0 dB"))
    }
}
