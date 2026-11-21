import Foundation
import XCTest
@testable import NotchSixty

/// E33 S26 (G51): matched EQ filters through the Swift side: the per-band method and its schema, the cookbook staying
/// bit-identical, the drawn curve being the engine's coefficients, who gets which method, and the graph accepting it.
final class EQMatchedFiltersTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func matchedBand(_ type: EQFilterType = .peaking, hz: Double = 15_000, gain: Double = 6, q: Double = 1) -> EQBand {
        var band = EQBand(type: type, frequencyHz: hz, gainDB: gain, q: q)
        band.filterMethod = .matched
        return band
    }

    func testSchemaRoundTripKeepsTheMethod() throws {
        let band = matchedBand()
        let data = try JSONEncoder().encode(band)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"filterMethod\":\"matched\""))
        XCTAssertEqual(try JSONDecoder().decode(EQBand.self, from: data), band)
    }

    func testOldProfileLoadsAsCookbookAndSoundsUnchanged() throws {
        let cookbook = EQBand(type: .highShelf, frequencyHz: 8_000, gainDB: 5, q: 0.8)
        let data = try JSONEncoder().encode(cookbook)
        // A saved EQ never wrote the key, and a cookbook band still does not, so old files stay byte-for-byte as they were.
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("filterMethod"))
        let loaded = try JSONDecoder().decode(EQBand.self, from: data)
        XCTAssertNil(loaded.filterMethod)
        XCTAssertFalse(loaded.usesMatchedFilters)
        for rate in rates {
            var reference = N60BiquadCoefficients()
            XCTAssertTrue(N60BiquadDesign(N60BiquadFilterTypeHighShelf, rate, 8_000, 5, 0.8, &reference))
            let sections = try loaded.compiledSections(sampleRate: rate)
            XCTAssertEqual(sections.count, 1)
            XCTAssertEqual(sections[0].type, N60BiquadFilterTypeHighShelf)
            XCTAssertEqual(sections[0].coefficients.b0, reference.b0)
            XCTAssertEqual(sections[0].coefficients.a2, reference.a2)
        }
    }

    func testMatchedSectionsAreTheCoreDesignAndTheDrawnCurveIsTheirs() throws {
        for rate in rates where rate * 0.42 > 15_000 {
            let band = matchedBand()
            let sections = try band.compiledSections(sampleRate: rate)
            XCTAssertEqual(sections.count, 1)
            XCTAssertEqual(sections[0].type, N60BiquadFilterTypeMatchedPeaking)
            var c = [Double](repeating: 0, count: 5)
            XCTAssertEqual(n60_eq_design_section(16, rate, 15_000, 6, 1, &c), 1)
            XCTAssertEqual(sections[0].coefficients.b0, Float(c[0]))
            XCTAssertEqual(sections[0].coefficients.a1, Float(c[3]))
            // The page draws ProductionEQResponseMath over the same coefficients the engine is given.
            let program = ProductionEQResponseMath.compile(bands: [band], sampleRate: rate)
            XCTAssertEqual(program.count, 1)
            XCTAssertEqual(Float(program[0].b1), sections[0].coefficients.b1)
            let analysis = EQFilterAnalysis(bands: [band], phaseMode: .minimumPhase, sampleRate: rate)
            XCTAssertEqual(analysis.magnitudeDB(at: 15_000), 6, accuracy: 0.05)
        }
    }

    func testG51TopOfBandBellKeepsItsShape() throws {
        // +6 dB Q 1 at 15 kHz: the analogue bell is +4.4 dB at 20 kHz; the cookbook falls to about +0.5 dB at 44.1 kHz.
        for rate in [44_100.0, 48_000.0] {
            let matched = EQFilterAnalysis(bands: [matchedBand()], phaseMode: .minimumPhase, sampleRate: rate).magnitudeDB(at: 20_000)
            var cookbook = matchedBand()
            cookbook.filterMethod = nil
            let plain = EQFilterAnalysis(bands: [cookbook], phaseMode: .minimumPhase, sampleRate: rate).magnitudeDB(at: 20_000)
            XCTAssertEqual(matched, 4.4, accuracy: 0.6, "rate \(rate)")
            XCTAssertGreaterThan(matched - plain, 2.5, "rate \(rate)")
        }
    }

    func testMatchedShapesApplyOnlyWhereTheDesignExists() {
        XCTAssertTrue(matchedBand(.peaking).usesMatchedFilters)
        XCTAssertTrue(matchedBand(.tilt).usesMatchedFilters)
        XCTAssertTrue(matchedBand(.bandPass).usesMatchedFilters)
        var steep = matchedBand(.lowPass)
        steep.slope = .db24
        XCTAssertFalse(steep.usesMatchedFilters, "low pass above 12 dB/oct keeps the cookbook")
        var odd = matchedBand(.highShelf)
        odd.slope = .db6
        XCTAssertFalse(odd.usesMatchedFilters, "a first-order shelf keeps the cookbook")
        for type in [EQFilterType.notch, .allPass, .linkwitzTransform] {
            XCTAssertFalse(matchedBand(type).usesMatchedFilters, "\(type)")
        }
        var dynamic = matchedBand()
        dynamic.dynamic.enabled = true
        XCTAssertFalse(dynamic.usesMatchedFilters, "dynamic bands keep the cookbook")
    }

    func testWhoGetsWhichMethod() {
        let added = EQMatchedFiltersPolicy.newBand(EQBand(frequencyHz: 2_000, q: 1), enhanced: true)
        XCTAssertEqual(added.filterMethod, .matched)
        XCTAssertNil(EQMatchedFiltersPolicy.newBand(EQBand(frequencyHz: 2_000, q: 1), enhanced: false).filterMethod)
        let parsed = EqualizerAPOCodec.parse("Filter 1: ON PK Fc 15000 Hz Gain 6 dB Q 1")
        XCTAssertEqual(parsed.bands.count, 1)
        XCTAssertNil(parsed.bands[0].filterMethod, "APO imports stay cookbook")
        let imported = EQBandRules.sanitizedForImport(parsed.bands[0])
        XCTAssertNil(imported.filterMethod)
        XCTAssertEqual(EQMatchedFiltersPolicy.eligible([imported, added]).count, 1, "the offer lists cookbook bands only")
    }

    func testCopyKeepsTheMethodAndTheOfferSwitchesBandsOneWay() {
        let band = matchedBand()
        XCTAssertEqual(band.withID(UUID()).filterMethod, .matched)
        var cookbook = band
        cookbook.filterMethod = nil
        var notch = EQBand(type: .notch, frequencyHz: 1_000, gainDB: 0, q: 2)
        notch.filterMethod = nil
        XCTAssertEqual(EQMatchedFiltersPolicy.eligible([cookbook, notch, band]).map(\.id), [cookbook.id])
        var dynamic = cookbook
        dynamic.dynamic.enabled = true
        XCTAssertTrue(EQMatchedFiltersPolicy.hasDynamicBandNote([dynamic]))
        XCTAssertTrue(EQMatchedFiltersPolicy.eligible([dynamic]).isEmpty)
    }

    func testGraphParametersAcceptMatchedTypesOnly() throws {
        for type in [16, 17, 18, 19, 20, 23, 24] {
            let p = try UnifiedGraphConfiguration.groupPEQParameters([
                UnifiedGraphPEQSection(type: type, frequencyHz: 1_000, gainDB: 3, q: 1, coefficients: nil, linkwitzDeviation: nil)
            ])
            XCTAssertEqual(p[0], Float(type))
        }
        for type in [21, 22, 25] {
            XCTAssertThrowsError(try UnifiedGraphConfiguration.groupPEQParameters([
                UnifiedGraphPEQSection(type: type, frequencyHz: 1_000, gainDB: 3, q: 1, coefficients: nil, linkwitzDeviation: nil)
            ]))
        }
        XCTAssertEqual(UInt32(N60BiquadFilterTypeMatchedPeaking.rawValue), UInt32(N60_PEQ_SECTION_MATCHED_BASE))
        XCTAssertEqual(UInt32(N60BiquadFilterTypeMatchedPeakingConstantQ.rawValue), UInt32(N60_PEQ_SECTION_MATCHED_BASE) + 8)
    }
}
