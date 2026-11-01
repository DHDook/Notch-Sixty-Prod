import XCTest
@testable import NotchSixty

/// E4 S28: weightings, loudness estimate and survey classification. Pure maths on a third-octave spectrum, so
/// it is independent of device rate (the eight standard rates only change how the spectrum is measured, S16/S24).
final class QuietZoneNoiseSurveyTests: XCTestCase {
    func testWeightingsMatchPublishedValues() {
        // IEC 61672 table values.
        let a: [(Double, Double)] = [(31.5, -39.4), (63, -26.2), (100, -19.1), (125, -16.1), (1000, 0), (4000, 1.0), (8000, -1.1)]
        for (f, v) in a { XCTAssertEqual(QuietZoneNoiseWeighting.aWeightingDB(f), v, accuracy: 0.15, "A \(f)") }
        let c: [(Double, Double)] = [(31.5, -3.0), (63, -0.8), (100, -0.3), (1000, 0), (8000, -3.0)]
        for (f, v) in c { XCTAssertEqual(QuietZoneNoiseWeighting.cWeightingDB(f), v, accuracy: 0.15, "C \(f)") }
    }

    func testBarkScaleAndThresholdLandmarks() {
        XCTAssertEqual(QuietZoneNoiseWeighting.bark(1000), 8.5, accuracy: 0.2)
        XCTAssertEqual(QuietZoneNoiseWeighting.thresholdInQuietDB(1000), 3.0, accuracy: 1.5)
        XCTAssertGreaterThan(QuietZoneNoiseWeighting.thresholdInQuietDB(50), 30)
    }

    func testLoudnessIsMonotonicAndNearTheLiteratureAnchors() {
        var last = 0.0
        for level in stride(from: 20.0, through: 90.0, by: 5.0) {
            let n = QuietZoneNoiseSurvey.loudness(bands: [(1000, level)])
            XCTAssertGreaterThan(n, last)
            last = n
        }
        let forty = QuietZoneNoiseSurvey.loudness(bands: [(1000, 40)])
        XCTAssertEqual(forty, 1.0, accuracy: 0.15)  // 40 phon is 1 sone
        let fifty = QuietZoneNoiseSurvey.loudness(bands: [(1000, 50)])
        XCTAssertGreaterThan(fifty / forty, 1.8)  // about double per 10 dB
        XCTAssertLessThan(fifty / forty, 2.6)
        let broad = QuietZoneNoiseSurvey.loudness(bands: [(1000, 60), (1250, 60), (800, 60)])
        XCTAssertGreaterThan(broad, QuietZoneNoiseSurvey.loudness(bands: [(1000, 60)]))
    }

    private func band(_ f: Double, _ level: Double, spread: Double = 0.5, floor: Double = 30) -> QuietZoneSurveyBand {
        QuietZoneSurveyBand(centerHz: f, levelDB: level, spreadDB: spread, floorDB: floor)
    }

    func testClassificationOfFixtureSpectra() {
        XCTAssertEqual(QuietZoneNoiseSurvey.classify(band(50, 60)), .cancellableTonal)
        XCTAssertEqual(QuietZoneNoiseSurvey.classify(band(50, 60, spread: 5)), .needsReference)
        XCTAssertEqual(QuietZoneNoiseSurvey.classify(band(50, 34)), .negligible)  // under 6 dB above floor
        XCTAssertEqual(QuietZoneNoiseSurvey.classify(band(10, 70)), .negligible)
        XCTAssertEqual(QuietZoneNoiseSurvey.classify(band(500, 60)), .aboveEnvelope)
    }

    func testSurveyPredictsReductionAndLowersAnnoyance() {
        let fan = [band(50, 65), band(100, 55, spread: 6), band(500, 50), band(1000, 40)]
        let none = QuietZoneNoiseSurvey.survey(bands: fan, coherence: nil)
        XCTAssertEqual(none.findings[0].predictedReductionDB, 25)  // capped
        XCTAssertEqual(none.findings[1].predictedReductionDB, 0)   // no reference surveyed
        XCTAssertEqual(none.maskingSuggestionHz, [500, 1000])
        XCTAssertLessThan(none.predictedAfter.loudnessSone, none.before.loudnessSone)
        XCTAssertLessThan(none.predictedAfter.dBC, none.before.dBC)
        XCTAssertTrue(none.before.isEstimate)

        let withReference = QuietZoneNoiseSurvey.survey(bands: fan, coherence: 0.9)
        XCTAssertGreaterThan(withReference.findings[1].predictedReductionDB, 0)
        XCTAssertLessThanOrEqual(withReference.findings[1].predictedReductionDB, 25)  // bounded by excess
        XCTAssertLessThan(withReference.predictedAfter.loudnessSone, none.predictedAfter.loudnessSone)
    }

    func testLowFrequencyIndicatorAndHonestStatements() {
        let rumble = QuietZoneNoiseSurvey.annoyance(bands: [(40, 70), (50, 70), (63, 70)])
        XCTAssertTrue(rumble.isLowFrequencyDominated)
        let hiss = QuietZoneNoiseSurvey.annoyance(bands: [(1000, 50), (2000, 50), (4000, 50)])
        XCTAssertFalse(hiss.isLowFrequencyDominated)

        let quiet = QuietZoneNoiseSurvey.survey(bands: [band(1000, 45)], coherence: nil)
        XCTAssertTrue(quiet.statements.contains { $0.contains("little for Quiet Zone to cancel") })
        XCTAssertTrue(quiet.statements.first!.contains("150 Hz"))
        XCTAssertTrue(quiet.statements.last!.contains("estimates"))
        XCTAssertEqual(QuietZoneNoiseSurvey.shortfallDB(predicted: 20, achieved: 14), 6)
        XCTAssertEqual(QuietZoneNoiseSurvey.nearFieldGuidance.count, 3)
    }
}
