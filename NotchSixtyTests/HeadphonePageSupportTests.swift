import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E13 S9 (`e13.headphones-page`): target shaping, one import, Auto headroom, the drawn fit and old-profile loading.
@MainActor
final class HeadphonePageSupportTests: XCTestCase {
    private let flags = FeatureFlags()

    override func tearDown() {
        flags.resetOverrides()
        super.tearDown()
    }

    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func grid() -> [Double] {
        (0 ... 240).map { 20.0 * pow(2, Double($0) / 24) }.filter { $0 <= 16_000 }
    }

    private func modelJSON(name: String = "Model A", bassBoost: Double = 0) throws -> Data {
        let f = (0 ..< 64).map { 20.0 * pow(800, Double($0) / 63) }
        let points = f.map { HeadphoneModelFrequencyPoint(
            frequencyHz: $0, leftMagnitudeDB: 3 * sin($0 / 500), rightMagnitudeDB: 2 * sin($0 / 400),
            targetMagnitudeDB: $0 < 100 ? bassBoost : 0) }
        let model = HeadphoneModelMeasurement(
            schemaVersion: 1, id: UUID(), headphoneModel: name, sourceName: "file", sourceAttribution: "me",
            sourceLicense: "local", acquisitionNotes: "", points: points)
        return try JSONEncoder().encode(model)
    }

    private func csv() -> Data {
        var text = "frequency,raw\n"
        for f in grid() { text += "\(f),\(4 * sin(f / 700))\n" }
        return Data(text.utf8)
    }

    private func fit(_ record: HeadphoneResponseRecord, target: RoomCorrectionTargetCurve?, rate: Double) throws -> HeadphoneAutoFitResult {
        try HeadphoneAutoFitter.fit(measurement: try record.measurement(target: target, sampleRate: rate), sampleRate: rate)
    }

    func testEveryFormatReachesTheSameFitPath() throws {
        for rate in Self.rates {
            let text = try HeadphoneImportRouter.importData(csv(), name: "csv", sampleRate: rate)
            let json = try HeadphoneImportRouter.importData(modelJSON(), name: "json", sampleRate: rate)
            guard case .response(let a, _) = text, case .response(let b, _) = json else { return XCTFail("not responses") }
            XCTAssertFalse(try fit(a, target: nil, rate: rate).proposal.leftBands.isEmpty)
            XCTAssertNoThrow(try fit(b, target: nil, rate: rate))
        }
    }

    func testProposalJSONIsStagedNotFitted() throws {
        let band = HeadphoneCorrectionEQBand(enabled: true, type: .peaking, frequencyHz: 1_000, gainDB: 2, q: 1)
        let proposal = HeadphoneCorrectionProposal(
            schemaVersion: 1, headphoneModel: "P", sourceName: "s", sourceAttribution: "a", sourceLicense: "l",
            referenceSampleRate: 48_000, leftBands: [band], rightBands: [band])
        let outcome = try HeadphoneImportRouter.importData(JSONEncoder().encode(proposal), name: "p", sampleRate: 48_000)
        guard case .proposal(let loaded) = outcome else { return XCTFail("expected a proposal") }
        XCTAssertEqual(loaded.leftBands, [band])
    }

    func testModelJSONKeepsItsTarget() throws {
        let outcome = try HeadphoneImportRouter.importData(modelJSON(bassBoost: 3), name: "m", sampleRate: 48_000)
        guard case .response(let record, let target) = outcome else { return XCTFail() }
        XCTAssertEqual(record.name, "Model A")
        XCTAssertEqual(target?.points.first?.gainDB, 3)
        let flat = try HeadphoneImportRouter.importData(modelJSON(), name: "m", sampleRate: 48_000)
        guard case .response(_, let none) = flat else { return XCTFail() }
        XCTAssertNil(none)
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try HeadphoneImportRouter.importData(Data("{\"x\":1}".utf8), name: "x", sampleRate: 48_000))
    }

    func testShapingClosedFormAndNeutralPassThrough() {
        let flat = RoomCorrectionBuiltInTarget.flat.curve
        XCTAssertEqual(HeadphoneTargetShaping.shaped(base: flat, shaping: .init()), flat)
        var shaping = HeadphoneTargetShaping()
        shaping.bassShelfDB = 4
        shaping.trebleTiltDB = -3
        let curve = HeadphoneTargetShaping.shaped(base: nil, shaping: shaping)!
        for p in curve.points {
            XCTAssertEqual(p.gainDB, shaping.offsetDB(atHz: p.frequencyHz), accuracy: 1e-9)
        }
        XCTAssertEqual(curve.points.first!.gainDB, 4 / (1 + pow(20 / 105.0, 2)), accuracy: 1e-6)
        XCTAssertEqual(curve.points.last!.gainDB, -3, accuracy: 1e-3)
        XCTAssertEqual(shaping.offsetDB(atHz: 1_000), 4 / (1 + pow(1_000 / 105.0, 2)), accuracy: 1e-9)
    }

    func testShapedTargetFeedsTheFitAtEightRates() throws {
        let record = HeadphoneResponseRecord(
            name: "Flat", left: HeadphoneResponseCurve(frequenciesHz: grid(), db: grid().map { _ in 0 }),
            right: HeadphoneResponseCurve(frequenciesHz: grid(), db: grid().map { _ in 0 }))
        var shaping = HeadphoneTargetShaping()
        shaping.bassShelfDB = 5
        let shaped = HeadphoneTargetShaping.shaped(base: nil, shaping: shaping)
        for rate in Self.rates {
            let measurement = try record.measurement(target: shaped, sampleRate: rate)
            XCTAssertEqual(measurement.points[0].targetMagnitudeDB, shaping.offsetDB(atHz: measurement.points[0].frequencyHz), accuracy: 0.05)
            let plain = try fit(record, target: nil, rate: rate)
            let withShape = try fit(record, target: shaped, rate: rate)
            XCTAssertTrue(plain.proposal.leftBands.allSatisfy { $0.gainDB == 0 } || plain.proposal.leftBands.isEmpty)
            XCTAssertTrue(withShape.proposal.leftBands.contains { $0.gainDB > 1 && $0.frequencyHz < 300 })
            XCTAssertLessThan(withShape.leftRMSEAfterDB, withShape.leftRMSEBeforeDB)
        }
    }

    func testAutoHeadroomEqualsConservativeAllowanceAndFollowsBands() throws {
        var draft = HeadphoneDeviceProfileConfiguration()
        draft.left.eqBands = [HeadphoneCorrectionEQBand(enabled: true, type: .peaking, frequencyHz: 100, gainDB: 5.2, q: 1)]
        draft.right.eqBands = [HeadphoneCorrectionEQBand(enabled: true, type: .peaking, frequencyHz: 3_000, gainDB: 3, q: 1)]
        for rate in Self.rates {
            draft.headroomAttenuationDB = HeadphoneAutoHeadroom.headroomDB(for: draft)
            XCTAssertGreaterThanOrEqual(draft.headroomAttenuationDB + 1e-6, draft.conservativeRequiredHeadroomDB)
            XCTAssertLessThan(draft.headroomAttenuationDB - draft.conservativeRequiredHeadroomDB, 0.5 + 1e-9)
            XCTAssertNoThrow(try draft.validateStructure(sampleRate: rate))
        }
        let before = HeadphoneAutoHeadroom.headroomDB(for: draft)
        draft.left.eqBands[0].gainDB = 9
        XCTAssertGreaterThan(HeadphoneAutoHeadroom.headroomDB(for: draft), before)
        draft.left.eqBands = []
        draft.right.eqBands = []
        XCTAssertEqual(HeadphoneAutoHeadroom.headroomDB(for: draft), 0)
    }

    func testOldProfilesWithEachTargetLabelLoadUnchanged() throws {
        for label in HeadphoneTargetCurve.allCases {
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.targetCurve = label
            let decoded = try JSONDecoder().decode(
                HeadphoneDeviceProfileConfiguration.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(decoded, profile)
            XCTAssertEqual(decoded.targetCurve, label)
            XCTAssertEqual(decoded.conservativeRequiredHeadroomDB, profile.conservativeRequiredHeadroomDB)
        }
    }

    func testFitPreviewPredictsResponsePlusEQ() throws {
        let record = HeadphoneResponseRecord(
            name: "R", left: HeadphoneResponseCurve(frequenciesHz: grid(), db: grid().map { 2 * sin($0 / 300) }),
            right: HeadphoneResponseCurve(frequenciesHz: grid(), db: grid().map { _ in 1 }))
        let fitted = try fit(record, target: nil, rate: 96_000)
        var draft = HeadphoneDeviceProfileConfiguration()
        draft.left.eqBands = fitted.proposal.leftBands
        draft.right.eqBands = fitted.proposal.rightBands
        let preview = try HeadphoneFitPreview.make(record: record, target: nil, draft: draft, sampleRate: 96_000)
        XCTAssertEqual(preview.frequenciesHz.count, preview.predictedLeftDB.count)
        let i = preview.frequenciesHz.count / 2
        let eq = draft.left.eqBands.filter(\.enabled).reduce(0.0) {
            $0 + (HeadphoneAutoFitter.bandMagnitudeDB($1, frequencyHz: preview.frequenciesHz[i], sampleRate: 96_000) ?? 0)
        }
        XCTAssertEqual(preview.predictedLeftDB[i], preview.responseLeftDB[i] + eq, accuracy: 1e-9)
    }

    func testEveryCrossfeedPresetHasOneLine() {
        for preset in HeadphoneCrossfeedPreset.allCases {
            XCTAssertFalse(preset.summary.isEmpty)
            XCTAssertFalse(preset.summary.contains("\n"))
        }
    }

    func testFlagIsRegisteredAndOff() {
        XCTAssertTrue(FeatureFlag.all.contains(.headphonesPage))
        XCTAssertFalse(FeatureFlag.headphonesPage.graduated)
    }

    /// AGENTS.md section 13: the page with the flag on fits at 1,280 x 800 and 1,920 x 1,000.
    func testPageFitsWithTheFlagOn() {
        flags.setEnabled(true, for: .headphonesPage)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let product = ProductController(audioEngine: engine)
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let page = HostedPage(
                ProductionHeadphoneWorkspace(engine: engine, profiles: product.profiles, calibration: product.multichannelCalibration),
                size: size)
            for control in page.controls {
                let frame = control.view.convert(control.view.bounds, to: page.hosting)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(control.label) at \(size.width)")
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(control.label) at \(size.width)")
            }
        }
    }
}
