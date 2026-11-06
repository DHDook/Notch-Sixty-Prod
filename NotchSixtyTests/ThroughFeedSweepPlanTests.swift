import XCTest
@testable import NotchSixty

/// E26 S2b: sweep settings through the whole feed, and the fingerprint stamp on the leakage survey.
final class ThroughFeedSweepPlanTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func base(_ rate: Double) -> RoomCorrectionSweepSettings {
        RoomCorrectionSweepSettings(sampleRate: rate, startFrequencyHz: 20, endFrequencyHz: 20_000,
                                    durationSeconds: 5, leadInSeconds: 0.3, tailSeconds: 1)
    }

    func testSubPathsSweepFrom15HzLongerWithLongerTailAtEveryRate() throws {
        let paths: [AncBassPath] = [.downstream(.openPreout), .downstream(.calibratedLFE(crossoverHz: 80)),
                                    .appSplitter(BassManagementConfiguration(enabled: true)), .subOutput]
        for rate in rates {
            for path in paths {
                let s = ThroughFeedSweepPlanner.settings(base: base(rate), path: path, sampleRate: rate)
                XCTAssertEqual(s.startFrequencyHz, 15)
                XCTAssertGreaterThanOrEqual(s.durationSeconds, 12)
                XCTAssertGreaterThanOrEqual(s.tailSeconds, 2)
                XCTAssertGreaterThanOrEqual(s.leadInSeconds, 0.5)
                let program = try RoomCorrectionSweepGenerator().makeProgram(settings: s)
                XCTAssertEqual(program.sweepSamples.count > 0, true)
                // The generated sweep really has the sub octaves: its length covers the declared duration.
                XCTAssertGreaterThanOrEqual(Double(program.singleSweep.count), 12 * rate * 0.99, "\(rate)")
            }
        }
    }

    func testPathsWithoutASubKeepTheBaseSettings() {
        for path in [AncBassPath.none, .monoBassOnPair] {
            let s = ThroughFeedSweepPlanner.settings(base: base(48_000), path: path, sampleRate: 48_000)
            XCTAssertEqual(s, base(48_000))
        }
    }

    func testLongerBaseValuesAreKept() {
        var b = base(96_000)
        b.durationSeconds = 20; b.tailSeconds = 3; b.startFrequencyHz = 10
        let s = ThroughFeedSweepPlanner.settings(base: b, path: .subOutput, sampleRate: 96_000)
        XCTAssertEqual(s.durationSeconds, 20)
        XCTAssertEqual(s.tailSeconds, 3)
        XCTAssertEqual(s.startFrequencyHz, 10)
    }

    func testSurveyStampSurvivesCodingAndOldFilesDecodeUnstamped() throws {
        var survey = QuietZoneFeedForwardDesignSurvey(
            projectID: UUID(), microphoneStableID: "m", errorChannel: 1, referenceChannel: 0,
            sampleRate: 48_000, capturedAt: Date(), segments: 1, bands: [])
        XCTAssertNil(survey.echoBassFingerprint)
        let state = AncBassPathState.resolve(arrangement: nil, bassManagement: BassManagementConfiguration(enabled: true))
        survey.echoBassFingerprint = state.fingerprint
        let data = try JSONEncoder().encode(survey)
        let back = try JSONDecoder().decode(QuietZoneFeedForwardDesignSurvey.self, from: data)
        XCTAssertEqual(back.echoBassFingerprint, state.fingerprint)
        survey.echoBassFingerprint = nil
        let old = try JSONDecoder().decode(QuietZoneFeedForwardDesignSurvey.self, from: JSONEncoder().encode(survey))
        XCTAssertNil(old.echoBassFingerprint)
        // A stale stamp is detected against the current path.
        XCTAssertEqual(state.freshness(of: old.echoBassFingerprint), .stale(AncBassPathState.staleMessage))
    }

    func testNoiseSurveyKeepsTheLeakageStamp() throws {
        var previous = QuietZoneFeedForwardDesignSurvey(
            projectID: UUID(), microphoneStableID: "m", errorChannel: 1, referenceChannel: 0,
            sampleRate: 48_000, capturedAt: Date(), segments: 1, bands: [])
        previous.echoBassFingerprint = AncBassPathFingerprint(value: "x")
        let next = try QuietZoneFeedForwardSurveyRules.survey(
            projectID: previous.projectID, microphoneStableID: "m", errorChannel: 1, referenceChannel: 0,
            sampleRate: 48_000, bands: [],
            segments: QuietZoneFeedForwardSurveyGrid.minimumSegments, previous: previous, now: Date())
        XCTAssertEqual(next.echoBassFingerprint, previous.echoBassFingerprint)
    }
}
