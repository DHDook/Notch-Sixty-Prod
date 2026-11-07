import Foundation
import XCTest
@testable import NotchSixty

final class EQBandPanelModelTests: XCTestCase {
    private func bands(_ count: Int) -> [EQBand] {
        (0..<count).map { EQBand(frequencyHz: 100 * Double($0 + 1)) }
    }

    func testFrequencyText() {
        XCTAssertEqual(EQBandPanelModel.frequencyText(45), "45 Hz")
        XCTAssertEqual(EQBandPanelModel.frequencyText(999.4), "999 Hz")
        XCTAssertEqual(EQBandPanelModel.frequencyText(2_000), "2 kHz")
        XCTAssertEqual(EQBandPanelModel.frequencyText(1_500), "1.5 kHz")
    }

    func testGainText() {
        XCTAssertEqual(EQBandPanelModel.gainText(0.44), "+0.4 dB")
        XCTAssertEqual(EQBandPanelModel.gainText(-3), "-3.0 dB")
        XCTAssertEqual(EQBandPanelModel.gainText(-0.04), "0.0 dB")
        XCTAssertEqual(EQBandPanelModel.gainText(0), "0.0 dB")
    }

    func testCountText() {
        XCTAssertEqual(EQBandPanelModel.countText(count: 7, maximum: 64), "7 of 64")
    }

    func testAccessibilityLabel() {
        let band = EQBand(type: .peaking, frequencyHz: 300, gainDB: -0.7)
        XCTAssertEqual(
            EQBandPanelModel.accessibilityLabel(number: 3, band: band),
            "Band 3, \(EQFilterType.peaking.displayName), 300 hertz, minus 0.7 decibels, enabled"
        )
        var off = EQBand(frequencyHz: 2_000, gainDB: 4)
        off.enabled = false
        off.dynamic.enabled = true
        let label = EQBandPanelModel.accessibilityLabel(number: 1, band: off)
        XCTAssertTrue(label.contains("2 kilohertz, plus 4.0 decibels, dynamic, disabled"), label)
    }

    func testEnsuredSelection() {
        let list = bands(3)
        XCTAssertEqual(EQBandPanelModel.ensuredSelection(current: list[1].id, bands: list), list[1].id)
        XCTAssertEqual(EQBandPanelModel.ensuredSelection(current: UUID(), bands: list), list[0].id)
        XCTAssertEqual(EQBandPanelModel.ensuredSelection(current: nil, bands: list), list[0].id)
        XCTAssertNil(EQBandPanelModel.ensuredSelection(current: UUID(), bands: []))
    }

    func testAdjacentSelectionWraps() {
        let list = bands(3)
        XCTAssertEqual(EQBandPanelModel.adjacentSelection(from: list[2].id, offset: 1, bands: list), list[0].id)
        XCTAssertEqual(EQBandPanelModel.adjacentSelection(from: list[0].id, offset: -1, bands: list), list[2].id)
        XCTAssertEqual(EQBandPanelModel.adjacentSelection(from: list[0].id, offset: 1, bands: list), list[1].id)
        XCTAssertEqual(EQBandPanelModel.adjacentSelection(from: nil, offset: 1, bands: list), list[1].id)
        XCTAssertNil(EQBandPanelModel.adjacentSelection(from: nil, offset: 1, bands: []))
    }

    func testSelectionAfterRemoving() {
        let list = bands(4)
        // Removing the selected middle band selects the band that takes its place.
        XCTAssertEqual(EQBandPanelModel.selectionAfterRemoving(removed: list[1].id, selected: list[1].id, bandsBefore: list), list[2].id)
        // Removing the selected last band selects the new last band.
        XCTAssertEqual(EQBandPanelModel.selectionAfterRemoving(removed: list[3].id, selected: list[3].id, bandsBefore: list), list[2].id)
        // Removing another band keeps the selection.
        XCTAssertEqual(EQBandPanelModel.selectionAfterRemoving(removed: list[0].id, selected: list[2].id, bandsBefore: list), list[2].id)
        // Removing the only band clears the selection.
        XCTAssertNil(EQBandPanelModel.selectionAfterRemoving(removed: list[0].id, selected: list[0].id, bandsBefore: [list[0]]))
    }

    func testSixtyFourBandsAreAllAddressable() {
        let list = bands(EQConfiguration.maximumBandCount)
        var id = list[0].id
        for _ in 0..<list.count { id = EQBandPanelModel.adjacentSelection(from: id, offset: 1, bands: list)! }
        XCTAssertEqual(id, list[0].id)
    }
}
