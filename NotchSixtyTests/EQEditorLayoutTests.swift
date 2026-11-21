import XCTest
@testable import NotchSixty

/// E33 S1: band list and editor layout, picker sections, dynamic hint and moved-to-fit note.
final class EQEditorLayoutTests: XCTestCase {
    private func fullyDynamicBand() -> EQBand {
        var band = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 3, q: 1)
        band.dynamic.enabled = true
        band.dynamic.direction = .both
        band.dynamic.detectorMode = .rms
        return band
    }

    func testBreakpointSelectsColumns() {
        XCTAssertEqual(EQEditorLayout.columns(pageWidth: 950), .two, "default window detail width")
        XCTAssertEqual(EQEditorLayout.columns(pageWidth: EQEditorLayout.twoColumnMinimumWidth), .two)
        XCTAssertEqual(EQEditorLayout.columns(pageWidth: 780), .one, "narrowest window detail width")
    }

    func testListTakesAboutOneThird() {
        XCTAssertEqual(EQEditorLayout.listWidth(pageWidth: 1_200), 400)
        XCTAssertEqual(EQEditorLayout.listWidth(pageWidth: 600), 280, "never narrower than a row needs")
    }

    func testTwoColumnsPlaceEveryFullyDynamicControlWithoutScrolling() {
        let band = fullyDynamicBand()
        let placement = EQEditorLayout.placement(for: band, columns: .two)
        XCTAssertEqual(placement.leading, [.filter, .frequency, .gain, .q, .constantQ])
        XCTAssertEqual(placement.trailing, [
            .dynamicToggle, .direction, .threshold, .ratio, .maxCut, .attack, .release, .detector, .rmsWindow,
            .boostThreshold, .boostRatio, .maxBoost
        ])
        XCTAssertFalse(placement.isSingleColumn)
        XCTAssertEqual(Set(placement.leading).intersection(placement.trailing), [], "no control twice")
    }

    func testOneColumnStacksEverythingInOrder() {
        let band = fullyDynamicBand()
        let two = EQEditorLayout.placement(for: band, columns: .two)
        let one = EQEditorLayout.placement(for: band, columns: .one)
        XCTAssertTrue(one.isSingleColumn)
        XCTAssertEqual(one.leading, two.leading + two.trailing)
    }

    func testCutOnlyAndPeakDetectorDropBoostAndRmsControls() {
        var band = fullyDynamicBand()
        band.dynamic.direction = .cutOnly
        band.dynamic.detectorMode = .peak
        let dynamics = EQEditorLayout.dynamicControls(for: band)
        XCTAssertFalse(dynamics.contains(.rmsWindow))
        XCTAssertFalse(dynamics.contains(.maxBoost))
    }

    func testTypesWithoutDynamicModeHaveNoDynamicColumn() {
        for type in EQFilterType.allCases where !type.supportsDynamicEQ {
            XCTAssertEqual(EQEditorLayout.dynamicControls(for: EQBand(type: type)), [], "\(type)")
        }
    }

    func testListHeightSizesToContentAndCaps() {
        XCTAssertLessThan(EQEditorLayout.listHeight(bandCount: 2), EQEditorLayout.listHeight(bandCount: 6))
        XCTAssertEqual(EQEditorLayout.listHeight(bandCount: 9), EQEditorLayout.listHeight(bandCount: 64))
    }

    func testEveryFilterTypeIsInExactlyOnePickerSection() {
        for type in EQFilterType.allCases where type != .fir {
            let hits = EQFilterPickerModel.sections.filter { $0.types.contains(type) }
            XCTAssertEqual(hits.count, 1, "\(type)")
        }
        XCTAssertEqual(EQFilterPickerModel.sections.map(\.title), ["Basic", "Special"])
        XCTAssertNil(EQFilterPickerModel.sectionTitle(of: .fir))  // E33 S18 (G34)
        XCTAssertEqual(EQFilterPickerModel.sectionTitle(of: .peaking), "Basic")
        XCTAssertEqual(EQFilterPickerModel.sectionTitle(of: .notch), "Basic")
        for type in [EQFilterType.linkwitzTransform, .tilt, .allPass] {
            XCTAssertEqual(EQFilterPickerModel.sectionTitle(of: type), "Special", "\(type)")
        }
    }

    func testRangeHintReadsTheDynamicRanges() {
        XCTAssertEqual(EQDynamicHint.rangeText, "Dynamic bands: 20 Hz to 20 kHz, Q 0.4 to 8")
    }

    func testMovedNoteAppearsAfterSanitizeMoveAndNotOtherwise() {
        for rate in EQRenderHarness.rates {
            var band = fullyDynamicBand()
            band.frequencyHz = 30_000
            band.q = 15
            let fitted = EQBandRules.sanitized(band, sampleRate: rate)
            let note = EQDynamicHint.movedNote(from: band, to: fitted)
            XCTAssertNotNil(note, "\(rate)")
            XCTAssertTrue(note?.contains("Q 15 to 8") == true, "\(rate)")
            XCTAssertTrue(note?.hasPrefix("Moved to fit") == true)
            // The next edit that needs no move clears it.
            XCTAssertNil(EQDynamicHint.movedNote(from: fitted, to: EQBandRules.sanitized(fitted, sampleRate: rate)))
        }
    }

    func testFlagIsRegisteredAndGraduated() {
        XCTAssertTrue(FeatureFlag.all.contains(.eqPageEnhancements))
        XCTAssertTrue(FeatureFlag.eqPageEnhancements.resolvedDefault, "graduated in E33 S11d")
    }
}
