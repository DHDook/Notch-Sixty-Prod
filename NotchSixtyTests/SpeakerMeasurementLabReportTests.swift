import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabReportTests: XCTestCase {
    func testCompactReportExcludesRawImpulseAndTransferArrays() throws {
        let session = makeSession(
            modifiedAt: Date(timeIntervalSince1970: 1_704_100_000)
        )
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(
                session: session,
                generatedAt:
                    Date(timeIntervalSince1970: 1_704_100_100)
            )
        XCTAssertEqual(report.sessionID, session.id)
        XCTAssertEqual(report.protocolSummaries.count, 1)
        XCTAssertTrue(report.measurementOnly)
        XCTAssertFalse(report.canDeploy)
        XCTAssertFalse(report.containsRawImpulseData)

        let data = try SpeakerMeasurementLabReportExporter()
            .jsonData(report)
        let json = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )
        XCTAssertFalse(json.contains("impulseResponse"))
        XCTAssertFalse(json.contains("transferFunction"))
        XCTAssertTrue(json.contains("protocolSummaries"))
        XCTAssertTrue(json.contains("measurementOnly"))
    }

    func testCSVHasCompactProtocolAndAnalysisSections() throws {
        let report = try SpeakerMeasurementLabReportBuilder()
            .build(session: makeSession())
        let data = try SpeakerMeasurementLabReportExporter()
            .csvData(report)
        let csv = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )
        XCTAssertTrue(csv.contains("section,protocol_id"))
        XCTAssertTrue(csv.contains("\"protocol\""))
        XCTAssertTrue(csv.contains("Front Left on-axis"))
        XCTAssertTrue(csv.contains("section,analysis_kind"))
        XCTAssertFalse(csv.contains("impulseResponse"))
    }

    func testRecentSessionListingIsNewestFirstAndIgnoresInvalidJSON()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr106-report-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerMeasurementLabSessionStore(
            rootDirectory: root
        )
        let old = makeSession(
            id: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let recent = makeSession(
            id: UUID(),
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        try store.save(old)
        try store.save(recent)
        try Data("not-json".utf8).write(
            to: root.appendingPathComponent("broken.json")
        )

        let listed = try store.listRecentSessions(limit: 2)
        XCTAssertEqual(listed.map(\.id), [recent.id, old.id])
    }

    private func makeSession(
        id: UUID = UUID(),
        modifiedAt: Date =
            Date(timeIntervalSince1970: 1_704_000_000)
    ) -> SpeakerMeasurementLabSession {
        let labProtocol = SpeakerMeasurementLabProtocol(
            name: "Front Left on-axis",
            request: SpeakerMeasurementLabRequest(
                mode: .wholeSpeakerOnAxis,
                target: .acousticSource(
                    .speaker(.frontLeft)
                ),
                geometry: SpeakerMeasurementLabGeometry(
                    distanceMeters: 1.0
                ),
                repeatCount: 3
            )
        )
        return SpeakerMeasurementLabSession(
            id: id,
            playbackSystemID: UUID(),
            routingSignature: "pr106-report-route",
            microphone: SpeakerOptimizerMicrophoneIdentity(
                deviceUID: "pr106-report-mic",
                inputChannelIndex: 0,
                calibrationFingerprint: nil
            ),
            microphoneCalibration: nil,
            sharedClockReferenceConfiguration: nil,
            sampleRate: 48_000,
            protocols: [labProtocol],
            captures: [],
            createdAt:
                Date(timeIntervalSince1970: 1_703_999_900),
            modifiedAt: modifiedAt
        )
    }
}
