import CoreGraphics
import Foundation
import XCTest
@testable import NotchSixty

final class EQGraphRangeTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    func testXMaximumIsPointFourNineFsAtEveryRate() {
        for rate in rates {
            XCTAssertEqual(EQGraphXZoom.full.maximumFrequency(sampleRate: rate), rate * 0.49, accuracy: 1e-9)
            XCTAssertEqual(EQGraphGeometry(sampleRate: rate).maximumFrequency, rate * 0.49, accuracy: 1e-9)
            XCTAssertEqual(EQGraphXZoom.audible.maximumFrequency(sampleRate: rate), min(20_000, rate * 0.49), accuracy: 1e-9)
        }
        XCTAssertEqual(EQGraphXZoom.full.maximumFrequency(sampleRate: 384_000), 188_160, accuracy: 1e-9)
        XCTAssertEqual(EQGraphXZoom.full.maximumFrequency(sampleRate: 0), 48_000 * 0.49, accuracy: 1e-9)
    }

    func testAudibleZoomAndGeometryMapsAtEveryRate() {
        let size = CGSize(width: 800, height: 300)
        for rate in rates {
            let geometry = EQGraphGeometry(sampleRate: rate, zoom: .audible)
            XCTAssertEqual(geometry.x(frequency: 20, width: size.width), 0, accuracy: 1e-9)
            XCTAssertEqual(geometry.x(frequency: geometry.maximumFrequency, width: size.width), size.width, accuracy: 1e-9)
            XCTAssertEqual(geometry.frequency(x: size.width, width: size.width), min(20_000, rate * 0.49), accuracy: 1e-6)
        }
    }

    func testVisibleGainRangeScalesTheYAxis() {
        let geometry = EQGraphGeometry(sampleRate: 48_000, visibleDB: -6...6)
        XCTAssertEqual(geometry.y(db: 6, height: 300), 0, accuracy: 1e-9)
        XCTAssertEqual(geometry.y(db: -6, height: 300), 300, accuracy: 1e-9)
        XCTAssertEqual(geometry.y(db: 0, height: 300), 150, accuracy: 1e-9)
        XCTAssertEqual(geometry.gain(y: 75, height: 300), 3, accuracy: 1e-9)
        XCTAssertEqual(geometry.y(db: 20, height: 300), 0, accuracy: 1e-9)
        // A drag maps to the visible range, not to +/-24 dB.
        XCTAssertEqual(geometry.position(at: CGPoint(x: 0, y: 0), size: CGSize(width: 800, height: 300)).gainDB, 6, accuracy: 1e-9)
        let wide = EQGraphGeometry(sampleRate: 48_000, visibleDB: -36...36)
        XCTAssertEqual(wide.gain(y: 0, height: 300), 36, accuracy: 1e-9)
    }

    func testYPresetsAndAuto() {
        XCTAssertEqual(EQGraphYRange.allCases.compactMap(\.fixedHalfRange), [3, 6, 12, 24, 36])
        XCTAssertEqual(EQGraphYRange.autoHalfRange(peakMagnitudeDB: 0), 3)
        XCTAssertEqual(EQGraphYRange.autoHalfRange(peakMagnitudeDB: 2.9), 6)
        XCTAssertEqual(EQGraphYRange.autoHalfRange(peakMagnitudeDB: -9), 12)
        XCTAssertEqual(EQGraphYRange.autoHalfRange(peakMagnitudeDB: 21), 24)
        XCTAssertEqual(EQGraphYRange.autoHalfRange(peakMagnitudeDB: 24), 36)
        XCTAssertEqual(EQGraphYRange.autoHalfRange(peakMagnitudeDB: 80), 48)
        XCTAssertEqual(EQGraphYRange.autoHalfRange(peakMagnitudeDB: .nan), 3)
        XCTAssertEqual(EQGraphYRange.plusMinus12.halfRange(peakMagnitudeDB: 40, previous: nil, growOnly: false), 12)
        // Auto only grows while a drag is in progress, and may shrink afterwards.
        XCTAssertEqual(EQGraphYRange.auto.halfRange(peakMagnitudeDB: 1, previous: 12, growOnly: true), 12)
        XCTAssertEqual(EQGraphYRange.auto.halfRange(peakMagnitudeDB: 10, previous: 6, growOnly: true), 24 > 13 ? 24 : 12)
        XCTAssertEqual(EQGraphYRange.auto.halfRange(peakMagnitudeDB: 1, previous: 12, growOnly: false), 6)
        let memory = EQAutoRangeMemory()
        XCTAssertEqual(memory.resolve(.auto, peakMagnitudeDB: 10, growOnly: true), 24)
        XCTAssertEqual(memory.resolve(.auto, peakMagnitudeDB: 0, growOnly: true), 24)
        XCTAssertEqual(memory.resolve(.auto, peakMagnitudeDB: 0, growOnly: false), 3)
        XCTAssertEqual(EQGraphYRange.gridStep(halfRange: 3), 1)
        XCTAssertEqual(EQGraphYRange.gridStep(halfRange: 24), 6)
        XCTAssertEqual(EQGraphYRange.gridStep(halfRange: 36), 12)
    }

    func testPreferenceRawValuesRoundTrip() {
        for range in EQGraphYRange.allCases { XCTAssertEqual(EQGraphYRange(rawValue: range.rawValue), range) }
        for zoom in EQGraphXZoom.allCases { XCTAssertEqual(EQGraphXZoom(rawValue: zoom.rawValue), zoom) }
        for mode in EQBandCurvesMode.allCases { XCTAssertEqual(EQBandCurvesMode(rawValue: mode.rawValue), mode) }
    }

    func testBandCurveSelection() {
        let a = EQBand(type: .peaking, frequencyHz: 100, gainDB: 3, q: 1)
        var b = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: -3, q: 1)
        let off = EQBand(enabled: false, type: .peaking, frequencyHz: 5_000, gainDB: 3, q: 1)
        let fir = EQBand(type: .fir, frequencyHz: 1_000, gainDB: 0, q: 1)
        b.enabled = true
        let bands = [a, b, off, fir]
        XCTAssertEqual(EQBandCurves.drawn(mode: .off, bands: bands, selectedID: a.id), [])
        XCTAssertEqual(EQBandCurves.drawn(mode: .selected, bands: bands, selectedID: b.id).map(\.id), [b.id])
        XCTAssertEqual(EQBandCurves.drawn(mode: .selected, bands: bands, selectedID: nil), [])
        XCTAssertEqual(EQBandCurves.drawn(mode: .selected, bands: bands, selectedID: off.id), [], "a disabled band has no curve")
        XCTAssertEqual(EQBandCurves.drawn(mode: .all, bands: bands, selectedID: nil).map(\.id), [a.id, b.id])
        // The default is Selected.
        XCTAssertEqual(EQBandCurvesMode.selected.rawValue, "selected")
    }

    func testBandCurveEqualsAOneBandCascade() {
        let band = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 2)
        XCTAssertEqual(EQBandCurves.responseDB(of: band, sampleRate: 48_000, frequencyHz: 1_000), 6, accuracy: 0.05)
        XCTAssertEqual(EQBandCurves.responseDB(of: band, sampleRate: 48_000, frequencyHz: 20), 0, accuracy: 0.05)
    }

    func testDynamicEnvelope() {
        var band = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 0, q: 1)
        XCTAssertNil(EQBandCurves.dynamicEnvelope(of: band), "a static band has none")
        band.dynamic.enabled = true
        band.dynamic.direction = .cutOnly
        band.dynamic.rangeDB = -9
        let cut = EQBandCurves.dynamicEnvelope(of: band)
        XCTAssertEqual(cut?.lower.gainDB, -9)
        XCTAssertEqual(cut?.upper.gainDB, 0)
        band.dynamic.direction = .both
        band.dynamic.maxBoostDB = 4
        let both = EQBandCurves.dynamicEnvelope(of: band)
        XCTAssertEqual(both?.lower.gainDB, -9)
        XCTAssertEqual(both?.upper.gainDB, 4)
        band.dynamic.direction = .boostOnly
        let boost = EQBandCurves.dynamicEnvelope(of: band)
        XCTAssertEqual(boost?.lower.gainDB, 0)
        XCTAssertEqual(boost?.upper.gainDB, 4)
        band.gainDB = 20
        band.dynamic.maxBoostDB = 12
        XCTAssertEqual(EQBandCurves.dynamicEnvelope(of: band)?.upper.gainDB, 24, "clamped to the band limit")
        band.enabled = false
        XCTAssertNil(EQBandCurves.dynamicEnvelope(of: band))
    }

    func testOtherLaneGhost() {
        let left = [EQBand(type: .peaking, frequencyHz: 200, gainDB: 3, q: 1)]
        let right = [EQBand(type: .peaking, frequencyHz: 400, gainDB: -3, q: 1)]
        var configuration = StereoEQConfiguration(
            channelMode: .independent, editChannel: .left, leftBands: left, rightBands: right
        )
        XCTAssertEqual(EQBandCurves.otherLane(in: configuration)?.label, "Right")
        XCTAssertEqual(EQBandCurves.otherLane(in: configuration)?.bands, right)
        configuration.editChannel = .right
        XCTAssertEqual(EQBandCurves.otherLane(in: configuration)?.label, "Left")
        configuration.channelMode = .midSide
        configuration.editChannel = .mid
        XCTAssertEqual(EQBandCurves.otherLane(in: configuration)?.label, "Side")
        configuration.editChannel = .side
        XCTAssertEqual(EQBandCurves.otherLane(in: configuration)?.label, "Mid")
        configuration.channelMode = .linked
        XCTAssertNil(EQBandCurves.otherLane(in: configuration))
    }
}
