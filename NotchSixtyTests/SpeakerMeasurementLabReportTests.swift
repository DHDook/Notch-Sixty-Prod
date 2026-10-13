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

    func testFullJSONPreservesRawEvidenceAndSafetyBoundary()
        throws {
        let session = makeSession(includeCapture: true)
        let generatedAt =
            Date(timeIntervalSince1970: 1_704_100_200)
        let data = try SpeakerMeasurementLabFullFidelityExporter()
            .fullJSONData(
                session,
                generatedAt: generatedAt
            )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            SpeakerMeasurementLabFullFidelityExportEnvelope.self,
            from: data
        )
        XCTAssertEqual(envelope.session, session)
        XCTAssertEqual(envelope.generatedAt, generatedAt)
        XCTAssertTrue(envelope.measurementOnly)
        XCTAssertFalse(envelope.canDeploy)
        XCTAssertTrue(envelope.containsRawImpulseData)
        XCTAssertTrue(envelope.containsFullTransferFunctionData)

        let json = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )
        XCTAssertTrue(json.contains("impulseResponse"))
        XCTAssertTrue(json.contains("transferFunction"))
    }

    func testDetailedCSVsPreserveTransferAndImpulseSamples()
        throws {
        let session = makeSession(includeCapture: true)
        let capture = try XCTUnwrap(session.captures.first)
        let exporter =
            SpeakerMeasurementLabFullFidelityExporter()

        let transfer = try XCTUnwrap(
            String(
                data: try exporter.transferCSVData(session),
                encoding: .utf8
            )
        )
        XCTAssertTrue(transfer.contains(capture.id.uuidString))
        XCTAssertTrue(transfer.contains("100.000000000"))
        XCTAssertTrue(transfer.contains("-1.000000000"))
        XCTAssertTrue(transfer.contains("90.000000000"))

        let impulse = try XCTUnwrap(
            String(
                data: try exporter.impulseCSVData(session),
                encoding: .utf8
            )
        )
        XCTAssertTrue(impulse.contains(capture.id.uuidString))
        XCTAssertTrue(impulse.contains("0.250000000"))
        XCTAssertTrue(impulse.contains("-0.500000000"))
        XCTAssertTrue(impulse.contains("0.000020833"))
    }

    func testFRDPreservesTransferGridWithoutClaimingAbsoluteSPL()
        throws {
        let session = makeSession(includeCapture: true)
        let capture = try XCTUnwrap(session.captures.first)
        let data = try SpeakerMeasurementLabFullFidelityExporter()
            .frdData(session, captureID: capture.id)
        let frd = try XCTUnwrap(
            String(data: data, encoding: .utf8)
        )

        XCTAssertTrue(
            frd.contains(
                "magnitude_domain=transfer_function_db_not_absolute_spl"
            )
        )
        XCTAssertTrue(
            frd.contains(
                "100.000000000\t-1.000000000\t0.000000000"
            )
        )
        XCTAssertTrue(
            frd.contains(
                "1000.000000000\t-2.000000000\t90.000000000"
            )
        )
        XCTAssertTrue(frd.contains("measurement_only=true"))
        XCTAssertTrue(frd.contains("can_deploy=false"))
    }

    func testImpulseWAVIsMonoFloat32AtCaptureRate()
        throws {
        let session = makeSession(includeCapture: true)
        let capture = try XCTUnwrap(session.captures.first)
        let data = try SpeakerMeasurementLabFullFidelityExporter()
            .impulseWAVData(session, captureID: capture.id)

        XCTAssertEqual(
            String(data: data[0..<4], encoding: .ascii),
            "RIFF"
        )
        XCTAssertEqual(
            String(data: data[8..<12], encoding: .ascii),
            "WAVE"
        )
        XCTAssertEqual(uint16LE(data, at: 20), 3)
        XCTAssertEqual(uint16LE(data, at: 22), 1)
        XCTAssertEqual(uint32LE(data, at: 24), 48_000)
        XCTAssertEqual(uint16LE(data, at: 34), 32)
        XCTAssertEqual(
            String(data: data[36..<40], encoding: .ascii),
            "data"
        )
        XCTAssertEqual(uint32LE(data, at: 40), 12)
        XCTAssertEqual(
            uint32LE(data, at: 44),
            Float(0.25).bitPattern
        )
        XCTAssertEqual(
            uint32LE(data, at: 48),
            Float(-0.5).bitPattern
        )
        XCTAssertEqual(
            uint32LE(data, at: 52),
            Float(1.0).bitPattern
        )
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
            Date(timeIntervalSince1970: 1_704_000_000),
        includeCapture: Bool = false
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
        let playbackSystemID = UUID()
        let microphone = SpeakerOptimizerMicrophoneIdentity(
            deviceUID: "pr106-report-mic",
            inputChannelIndex: 0,
            calibrationFingerprint: nil
        )
        let captures: [SpeakerMeasurementLabCapture]
        if includeCapture {
            captures = [
                SpeakerMeasurementLabCapture(
                    protocolID: labProtocol.id,
                    repeatIndex: 0,
                    capturedAt:
                        Date(timeIntervalSince1970: 1_704_000_010),
                    playbackSystemID: playbackSystemID,
                    routingSignature: "pr106-report-route",
                    microphone: microphone,
                    sampleRate: 48_000,
                    source: labProtocol.captureSource!,
                    impulseResponse: [0.25, -0.5, 1.0],
                    transferFunction:
                        RoomCorrectionFrequencyResponse(
                            frequenciesHz: [100, 1_000],
                            magnitudeDB: [-1, -2],
                            phaseRadians: [0, .pi / 2]
                        ),
                    quality: RoomCorrectionMeasurementQuality(
                        clipped: false,
                        playbackPeakDBFS: -24,
                        capturePeakDBFS: -12,
                        estimatedNoiseFloorDBFS: -72,
                        estimatedSNRDB: 60,
                        sweepComplete: true,
                        directArrivalSeconds: 0.001,
                        usableLowHz: 100,
                        usableHighHz: 1_000,
                        warnings: []
                    )
                ),
            ]
        } else {
            captures = []
        }

        return SpeakerMeasurementLabSession(
            id: id,
            playbackSystemID: playbackSystemID,
            routingSignature: "pr106-report-route",
            microphone: microphone,
            microphoneCalibration: nil,
            sharedClockReferenceConfiguration: nil,
            sampleRate: 48_000,
            protocols: [labProtocol],
            captures: captures,
            createdAt:
                Date(timeIntervalSince1970: 1_703_999_900),
            modifiedAt: modifiedAt
        )
    }

    private func uint16LE(
        _ data: Data,
        at offset: Int
    ) -> UInt16 {
        UInt16(data[offset])
            | (UInt16(data[offset + 1]) << 8)
    }

    private func uint32LE(
        _ data: Data,
        at offset: Int
    ) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
