import Foundation
import XCTest
@testable import NotchSixty

final class OptionalAudioResearchTests: XCTestCase {
    private let rates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400,
        192_000, 352_800, 384_000
    ]

    func testMixedPhaseIdentityIsFiniteAndNeverDeploysThrough384kHz() throws {
        var taps = [Float](repeating: 0, count: 512)
        taps[0] = 1
        for rate in rates {
            let result = try MixedPhaseResearchDesigner().design(
                left: taps, right: taps,
                sampleRate: rate, linearPhaseShare: 0.25,
                latencyBudgetMilliseconds: 5
            )
            XCTAssertEqual(result.leftTaps.count, 512)
            XCTAssertEqual(result.rightTaps.count, 512)
            XCTAssertEqual(result.maximumMagnitudeDeviationDB, 0,
                           accuracy: 0.0001)
            XCTAssertEqual(result.preRingingEnergyFraction, 0,
                           accuracy: 0.0001)
            XCTAssertTrue(result.leftTaps.allSatisfy(\.isFinite))
            XCTAssertFalse(result.canDeploy)
            XCTAssertFalse(result.isMeasuredVerification)
        }
    }

    func testMixedPhaseFiniteTapsAndBlockingHeadroomAndBadInputs() throws {
        var taps = [Float](repeating: 0, count: 256)
        taps[0] = 3.0
        taps[1] = 0.25
        let result = try MixedPhaseResearchDesigner().design(
            left: taps, right: taps,
            sampleRate: 48_000, linearPhaseShare: 0.3,
            latencyBudgetMilliseconds: 10
        )
        XCTAssertGreaterThan(result.maximumPositiveGainDB, 6)
        XCTAssertTrue(result.blockingReasons.contains {
            $0.contains("attenuation")
        })
        XCTAssertFalse(result.canDeploy)
        taps[3] = .nan
        XCTAssertThrowsError(try MixedPhaseResearchDesigner().design(
            left: taps, right: taps, sampleRate: 48_000
        ))
        XCTAssertThrowsError(try MixedPhaseResearchDesigner().design(
            left: Array(repeating: 0, count: 256),
            right: Array(repeating: 0, count: 255),
            sampleRate: 48_000
        ))
        XCTAssertThrowsError(try MixedPhaseResearchDesigner().design(
            left: Array(repeating: 0, count: 256),
            right: Array(repeating: 0, count: 256),
            sampleRate: 400_000
        ))
    }

    func testHRTFExactDirectionAndInterpolationAreBounded() throws {
        let asset = BinauralProfileAsset.validationStereo(sampleRate: 384_000)
        let designer = HRTFDirectionalResearchDesigner()
        let exact = try designer.interpolate(
            asset: asset, azimuthDegrees: 30, elevationDegrees: 0
        )
        XCTAssertEqual(exact.sourceMeasurementCount, 1)
        XCTAssertEqual(exact.rightIR[0], 1.0, accuracy: 1e-6)
        let between = try designer.interpolate(
            asset: asset, azimuthDegrees: 15, elevationDegrees: 0
        )
        XCTAssertGreaterThanOrEqual(between.sourceMeasurementCount, 2)
        XCTAssertTrue(between.leftIR.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(between.rightIR[0], between.leftIR[0])
        XCTAssertFalse(between.canDeploy)
        XCTAssertFalse(between.personalizedAccuracyVerified)
        XCTAssertThrowsError(try designer.interpolate(
            asset: asset, azimuthDegrees: 120, elevationDegrees: 0
        )) { error in
            XCTAssertEqual(error as? OptionalAcousticResearchError,
                           .insufficientCoverage)
        }
    }

    func testHRTFWrapAroundAndPrivateListenerRatingPersistence() throws {
        let taps: [Float] = [0.5] + Array(repeating: 0, count: 15)
        var asset = BinauralProfileAsset.validationStereo()
        asset.measurements = [
            BinauralMeasurement(azimuthDegrees: -179, elevationDegrees: 0,
                distanceMeters: 1, leftIR: taps, rightIR: taps),
            BinauralMeasurement(azimuthDegrees: 179, elevationDegrees: 0,
                distanceMeters: 1, leftIR: taps, rightIR: taps),
        ]
        let result = try HRTFDirectionalResearchDesigner().interpolate(
            asset: asset, azimuthDegrees: 180, elevationDegrees: 0
        )
        XCTAssertLessThanOrEqual(result.nearestAngularDistanceDegrees, 1.01)
        XCTAssertEqual(result.sourceMeasurementCount, 2)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HRTFAuditionPreferenceStore(rootURL: directory)
        let record = HRTFAuditionRecord(
            assetID: asset.id, sourceName: "Local listener HRTF",
            listenerRating: 4, notes: "Subjective spatial impression",
            createdAt: Date(timeIntervalSince1970: 12)
        )
        try store.save(record)
        XCTAssertEqual(try store.load(assetID: asset.id), record)
        XCTAssertNil(try store.load(assetID: UUID()))
    }

    private func model(
        leftShiftDB: Double = -3
    ) -> HeadphoneModelMeasurement {
        let points = (0..<32).map { i -> HeadphoneModelFrequencyPoint in
            let hz = 30 * pow(18_000.0 / 30, Double(i) / 31)
            let shape = exp(-pow(log2(hz / 1200.0) / 1.3, 2))
            return HeadphoneModelFrequencyPoint(
                frequencyHz: hz,
                leftMagnitudeDB: leftShiftDB * shape,
                rightMagnitudeDB: -2.5 * shape,
                targetMagnitudeDB: 0
            )
        }
        return HeadphoneModelMeasurement(
            schemaVersion: 1, id: UUID(), headphoneModel: "Synthetic Test Headset",
            sourceName: "Independent synthetic measurement fixture",
            sourceAttribution: "Notch Sixty owned reference generation",
            sourceLicense: "CC0-1.0 synthetic only",
            acquisitionNotes: "Not an actual headphone measurement",
            points: points
        )
    }

    func testModelPEQFitReducesModeledResidualAndStagesOnlyDraft() throws {
        for rate in [44_100.0, 96_000.0, 384_000.0] {
            let fitted = try HeadphoneModelCorrectionDesigner().fit(
                measurement: model(), sampleRate: rate,
                maximumBandsPerEar: 5
            )
            XCTAssertLessThan(fitted.leftRMSEAfterDB, fitted.leftRMSEBeforeDB)
            XCTAssertLessThan(fitted.rightRMSEAfterDB, fitted.rightRMSEBeforeDB)
            XCTAssertLessThanOrEqual(fitted.proposal.leftBands.count, 5)
            XCTAssertLessThanOrEqual(fitted.proposal.rightBands.count, 5)
            XCTAssertLessThanOrEqual(fitted.recommendedHeadroomDB, 30)
            XCTAssertFalse(fitted.canApply)
            XCTAssertFalse(fitted.isIndividualCalibration)
            var draft = HeadphoneDeviceProfileConfiguration()
            try draft.stageLocalProposal(fitted.proposal, sampleRate: rate)
            XCTAssertFalse(draft.enabled)
            try draft.validateStructure(sampleRate: rate)
        }
    }

    func testModelLibraryRetainsCreditAndRejectsMalformedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HeadphoneModelMeasurementLibrary(rootURL: root)
        var input = model()
        try store.save(input, sampleRate: 48_000)
        let loaded = try store.list(sampleRate: 48_000)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].sourceLicense, "CC0-1.0 synthetic only")
        XCTAssertEqual(loaded[0].sourceAttribution, input.sourceAttribution)
        input.sourceLicense = ""
        XCTAssertThrowsError(try store.save(input, sampleRate: 48_000))
        input = model()
        input.points[2].frequencyHz = input.points[1].frequencyHz
        XCTAssertThrowsError(try input.validate(sampleRate: 48_000))
        input = model()
        input.points[0].leftMagnitudeDB = .nan
        XCTAssertThrowsError(try input.validate(sampleRate: 48_000))
    }
}
