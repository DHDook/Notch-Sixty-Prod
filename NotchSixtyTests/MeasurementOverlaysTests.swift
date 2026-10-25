import Foundation
import XCTest
@testable import NotchSixty

final class MeasurementOverlaysTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    func testPredictedEqualsMeasurementPlusEQResponseAtAllRates() {
        let bands = [
            EQBand(type: .lowShelf, frequencyHz: 120, gainDB: 5, q: 0.707),
            EQBand(type: .peaking, frequencyHz: 1_100, gainDB: -8, q: 2.0),
        ]
        for rate in rates {
            let program = ProductionEQResponseMath.compile(bands: bands, sampleRate: rate)
            XCTAssertFalse(program.isEmpty)
            let frequencies = stride(from: 20.0, through: 20_000.0, by: 137.0).map { $0 }
            let measured = frequencies.map { 70 - 3 * log10($0) }
            let curve = RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies, magnitudeDB: measured, phaseRadians: [0])
            let predicted = MeasurementOverlays.predicted(measurement: curve, program: program, sampleRate: rate)
            XCTAssertEqual(predicted.frequenciesHz, frequencies)
            for index in frequencies.indices {
                let eq = ProductionEQResponseMath.responseDB(
                    program: program, sampleRate: rate, frequencyHz: frequencies[index])
                XCTAssertEqual(predicted.magnitudeDB[index], measured[index] + eq, accuracy: 1e-9)
            }
            // The 1.1 kHz cut is visible in the prediction.
            let near = frequencies.indices.min { abs(frequencies[$0] - 1_100) < abs(frequencies[$1] - 1_100) }!
            XCTAssertLessThan(predicted.magnitudeDB[near] - measured[near], -6)
        }
    }

    func testEmptyProgramLeavesMeasurementUnchanged() {
        let curve = RoomCorrectionFrequencyResponse(
            frequenciesHz: [100, 1_000], magnitudeDB: [1, 2], phaseRadians: nil)
        let predicted = MeasurementOverlays.predicted(measurement: curve, program: [], sampleRate: 48_000)
        XCTAssertEqual(predicted.magnitudeDB, [1, 2])
    }

    func testRTAOverlayFollowsAFixedInputAndDropsFloorBands() {
        let floor = Double(N60_SPL_FLOOR_DB)
        let spectrum = RTASpectrum(
            centresHz: [100, 200, 400, 800], levelsDB: [60, 70, floor, 80], framesAnalysed: 1)
        let absolute = MeasurementOverlays.rtaCurve(spectrum: spectrum, relativeToMean: false)
        XCTAssertEqual(absolute?.frequenciesHz, [100, 200, 800])
        XCTAssertEqual(absolute?.magnitudeDB, [60, 70, 80])
        let relative = MeasurementOverlays.rtaCurve(spectrum: spectrum, relativeToMean: true)
        XCTAssertEqual(relative?.magnitudeDB, [-10, 0, 10])
        XCTAssertNil(MeasurementOverlays.rtaCurve(spectrum: nil, relativeToMean: true))
        XCTAssertNil(MeasurementOverlays.rtaCurve(
            spectrum: RTASpectrum(centresHz: [100], levelsDB: [60], framesAnalysed: 1), relativeToMean: true))
    }
}
