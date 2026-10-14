import Foundation
import XCTest
@testable import NotchSixty

/// Batch 3: shipped headphone UI logic, not physical headphone acceptance.
final class HeadphoneCompletionTests: XCTestCase {
    private func band(
        _ hz: Double, gain: Double, enabled: Bool = true,
        type: HeadphoneCorrectionFilterType = .peaking
    ) -> HeadphoneCorrectionEQBand {
        HeadphoneCorrectionEQBand(
            enabled: enabled, type: type,
            frequencyHz: hz, gainDB: gain, q: 0.707
        )
    }

    private func proposal(
        rate: Double? = nil
    ) -> HeadphoneCorrectionProposal {
        HeadphoneCorrectionProposal(
            schemaVersion: 1,
            headphoneModel: "User-owned measurement fixture",
            sourceName: "Local documented response",
            sourceAttribution: "Synthetic test authored for Notch Sixty",
            sourceLicense: "CC0-1.0 (user-supplied fixture metadata)",
            referenceSampleRate: rate,
            leftBands: [band(1000, gain: 4)],
            rightBands: [band(1000, gain: 2)]
        )
    }

    func testIndependent16BandPerEarEditingPersistsAt384kHz() throws {
        var p = HeadphoneDeviceProfileConfiguration()
        p.headroomAttenuationDB = 16
        p.left.eqBands = (0..<16).map {
            band(40 + Double($0) * 900, gain: 0.5)
        }
        p.right.eqBands = (0..<16).map {
            band(50 + Double($0) * 850, gain: 0.25)
        }
        try p.validateStructure(sampleRate: 384_000)
        let compiled = try p.makeRealtimeSnapshot(sampleRate: 384_000)
        XCTAssertEqual(compiled.sampleRate, 384_000, accuracy: 0.1)
        XCTAssertEqual(p.left.eqBands.count, 16)
        XCTAssertEqual(p.right.eqBands.count, 16)
        let decoded = try JSONDecoder().decode(
            HeadphoneDeviceProfileConfiguration.self,
            from: JSONEncoder().encode(p)
        )
        XCTAssertEqual(decoded, p)

        p.right.eqBands.append(band(17000, gain: 0.5))
        XCTAssertThrowsError(try p.validateStructure(sampleRate: 384_000))
    }

    func testPerEarElectricalResponsePreviewUsesActualProductionCoefficients() throws {
        var p = HeadphoneDeviceProfileConfiguration()
        p.headroomAttenuationDB = 0
        p.left.eqBands = [band(1000, gain: 6)]
        p.right.eqBands = [band(1000, gain: -3)]
        // Only negative gain requires no additional conservative headroom.
        XCTAssertThrowsError(try p.validateStructure(sampleRate: 48_000))
        p.headroomAttenuationDB = 6
        try p.validateStructure(sampleRate: 48_000)
        let l = try XCTUnwrap(HeadphoneEQResponsePreview.magnitudeDB(
            p.left, frequencyHz: 1000,
            sampleRate: 48_000, headroomAttenuationDB: 6
        ))
        let r = try XCTUnwrap(HeadphoneEQResponsePreview.magnitudeDB(
            p.right, frequencyHz: 1000,
            sampleRate: 48_000, headroomAttenuationDB: 6
        ))
        XCTAssertEqual(l, 0, accuracy: 0.02)
        XCTAssertEqual(r, -9, accuracy: 0.02)
        XCTAssertGreaterThan(l, r + 8)
        XCTAssertEqual(HeadphoneEQResponsePreview.curve(
            p.left, sampleRate: 48_000,
            headroomAttenuationDB: 6
        ).count, 96)
    }

    func testProposalRequiresSourceCreditAndExplicitMatchingRate() throws {
        var next = proposal(rate: 48_000)
        XCTAssertThrowsError(try next.validate(sampleRate: 384_000))
        next.referenceSampleRate = 384_000
        try next.validate(sampleRate: 384_000)
        next.sourceLicense = ""
        XCTAssertThrowsError(try next.validate(sampleRate: 384_000))
        next = proposal(rate: 384_000)
        next.leftBands.append(next.leftBands[0])
        XCTAssertThrowsError(try next.validate(sampleRate: 384_000))
    }

    func testProposedLocalCorrectionStagesOnlyInDraftWithSufficientHeadroom() throws {
        let imported = proposal(rate: 384_000)
        var p = HeadphoneDeviceProfileConfiguration()
        p.headroomAttenuationDB = 1
        try p.stageLocalProposal(imported, sampleRate: 384_000)
        XCTAssertEqual(p.left.eqBands, imported.leftBands)
        XCTAssertEqual(p.right.eqBands, imported.rightBands)
        XCTAssertEqual(p.headroomAttenuationDB, 4, accuracy: 0.0001)
        XCTAssertFalse(p.enabled)
        XCTAssertEqual(p.spatialMode, .stereo)
        try p.validateStructure(sampleRate: 384_000)
        let other = proposal(rate: 48_000)
        XCTAssertThrowsError(try p.stageLocalProposal(other, sampleRate: 384_000))
        XCTAssertEqual(p.left.eqBands, imported.leftBands)
    }

    func testSofaRateMismatchNeverTriggersSilentSRC() throws {
        var p = HeadphoneDeviceProfileConfiguration()
        p.spatialMode = .virtualSpeakers
        p.binauralProfile = BinauralProfileReference(
            assetID: UUID(), displayName: "Generated SOFA fixture",
            originalSourceName: "fixture.sofa", sampleRate: 48_000,
            tapCount: 256
        )
        XCTAssertThrowsError(try p.validateStructure(sampleRate: 384_000)) {
            guard case HeadphoneDeviceProfileError
                .binauralProfileSampleRateMismatch = $0 else {
                XCTFail("Mismatched spatial profile must fail closed")
                return
            }
        }
        try p.validateStructure(sampleRate: 48_000)
    }

    func testDisabledBandsDoNotAddHeadroomOrGain() throws {
        var p = HeadphoneDeviceProfileConfiguration()
        p.headroomAttenuationDB = 0
        p.left.eqBands = [band(100, gain: 18, enabled: false)]
        try p.validateStructure(sampleRate: 44_100)
        let result = try XCTUnwrap(HeadphoneEQResponsePreview.magnitudeDB(
            p.left, frequencyHz: 100, sampleRate: 44_100,
            headroomAttenuationDB: 0
        ))
        XCTAssertEqual(result, 0, accuracy: 1e-8)
    }
}
