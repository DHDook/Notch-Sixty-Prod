import XCTest
@testable import NotchSixty

final class ANCMeasurementReportTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func recorder() -> SafetyFlightRecorder {
        var r = SafetyFlightRecorder()
        r.record(.verifier, "Verified: -12 dB at 43 Hz", at: t0.addingTimeInterval(-5))
        r.recordDisarm(.user, at: t0.addingTimeInterval(-1))
        return r
    }

    private func survey() -> QuietZoneNoiseSurveyReport {
        QuietZoneNoiseSurvey.survey(
            bands: [
                QuietZoneSurveyBand(centerHz: 47, levelDB: -30, spreadDB: 0.5, floorDB: -60),
                QuietZoneSurveyBand(centerHz: 80, levelDB: -50, spreadDB: 8, floorDB: -60),
            ],
            coherence: 0.9
        )
    }

    func testReportRoundTripsThroughJSON() throws {
        let report = ANCMeasurementReport(
            version: "1.0", build: "7", verifiedReadout: "-12 dB at 43 Hz, verified",
            survey: survey(), recorder: recorder(), now: t0
        )
        XCTAssertFalse(report.predictions.isEmpty)
        XCTAssertGreaterThanOrEqual(report.safetyEvents.count, 2)
        let decoded = try ANCMeasurementReport.decode(try report.jsonData())
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(try decoded.jsonData(), try report.jsonData())
    }

    func testEmptyReportAddsNothingToDiagnostics() {
        let report = ANCMeasurementReport(
            version: "1", build: "1", verifiedReadout: nil, survey: nil,
            recorder: SafetyFlightRecorder(), now: t0
        )
        XCTAssertFalse(report.hasContent)
        XCTAssertTrue(report.diagnosticsLines.isEmpty)
    }

    func testDiagnosticsLinesNameReadoutAndPredictions() {
        let report = ANCMeasurementReport(
            version: "1", build: "1", verifiedReadout: "-12 dB at 43 Hz, verified",
            survey: survey(), recorder: recorder(), now: t0
        )
        let text = report.diagnosticsLines.joined(separator: "\n")
        XCTAssertTrue(text.contains("-12 dB at 43 Hz, verified"))
        XCTAssertTrue(text.contains("Predicted"))
    }

    /// The reviewer noise files come from a script with fixed constants: two runs match byte for byte.
    func testReviewerNoiseGeneratorIsByteIdenticalAcrossRuns() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "python3 not available")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("ci/generate_reviewer_noise.py").path
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }

        func run(_ name: String) throws -> URL {
            let dir = base.appendingPathComponent(name)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = ["-I", script, dir.path, "--seconds", "0.5"]
            try p.run()
            p.waitUntilExit()
            // The sandboxed test host cannot run the Xcode python shim; `ci/run_harnesses.sh e4_reviewer_noise`
            // covers the same check on CI.
            try XCTSkipIf(p.terminationStatus != 0, "python3 cannot run inside the test host sandbox")
            return dir
        }
        let a = try run("a"), b = try run("b")
        let names = try FileManager.default.contentsOfDirectory(atPath: a.path).sorted()
        XCTAssertEqual(names.filter { $0.hasSuffix(".wav") }.count, 6)
        XCTAssertTrue(names.contains { $0.hasSuffix("_48000.wav") } && names.contains { $0.hasSuffix("_96000.wav") })
        for name in names {
            XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent(name)),
                           try Data(contentsOf: b.appendingPathComponent(name)), name)
        }
    }
}
