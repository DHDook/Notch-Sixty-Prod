import XCTest
@testable import NotchSixty

final class SpeakerOptimizerCharacterizationControllerTests: XCTestCase {
    func testCurrentCharacterizationStoreRoundTripAndDelete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PR105-guided-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let systemID = UUID()
        let target = SpeakerOptimizerCharacterizationTarget(
            source: .speaker(.frontLeft),
            geometry: .init()
        )
        let set = SpeakerOptimizerCharacterizationMeasurementSet(
            playbackSystemID: systemID,
            routingSignature: "guided-route",
            microphone: SpeakerOptimizerMicrophoneIdentity(
                deviceUID: "guided-mic",
                inputChannelIndex: 0,
                calibrationFingerprint: nil
            ),
            sampleRate: 48_000,
            linkedListeningMeasurementSetID: UUID(),
            targets: [target],
            captures: [],
            earlyWindowEvidence: [],
            createdAt: Date(timeIntervalSince1970: 1_703_400_000.125),
            modifiedAt: Date(timeIntervalSince1970: 1_703_400_000.250)
        )
        let store = SpeakerOptimizerCharacterizationSetStore(
            rootDirectory: root
        )
        try store.saveCurrent(set)
        XCTAssertEqual(
            try XCTUnwrap(store.loadCurrent(playbackSystemID: systemID)),
            set
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.currentURL(for: systemID).path
            )
        )
        try store.deleteCurrent(playbackSystemID: systemID)
        XCTAssertNil(try store.loadCurrent(playbackSystemID: systemID))
    }

    func testCrossDomainSummaryCountsEveryClassificationWithoutGrantingApply() {
        let source: MultichannelCalibrationSource = .speaker(.frontLeft)
        let points: [SpeakerOptimizerCrossDomainPoint] = [
            .init(
                frequencyHz: 1_000,
                characterizationResidualDB: 2,
                listeningMeanResidualDB: 2,
                listeningSeatSpreadDB: 0.2,
                classification: .speakerPersistent
            ),
            .init(
                frequencyHz: 2_000,
                characterizationResidualDB: 0,
                listeningMeanResidualDB: -3,
                listeningSeatSpreadDB: 2,
                classification: .roomSeatDependent
            ),
            .init(
                frequencyHz: 4_000,
                characterizationResidualDB: 2,
                listeningMeanResidualDB: -2,
                listeningSeatSpreadDB: 0.2,
                classification: .ambiguous
            ),
            .init(
                frequencyHz: 8_000,
                characterizationResidualDB: 0,
                listeningMeanResidualDB: 0,
                listeningSeatSpreadDB: 0.1,
                classification: .noMaterialDeviation
            ),
        ]
        let report = SpeakerOptimizerCrossDomainReport(
            characterizationMeasurementSetID: UUID(),
            listeningMeasurementSetID: UUID(),
            playbackSystemID: UUID(),
            routingSignature: "summary",
            sources: [
                SpeakerOptimizerCrossDomainSourceReport(
                    source: source,
                    frequenciesHz: points.map(\.frequencyHz),
                    points: points,
                    characterizationCaptureCount: 3,
                    listeningSeatCount: 3
                )
            ],
            warnings: []
        )
        let summary = SpeakerOptimizerCrossDomainSummary(report: report)
        XCTAssertEqual(summary.speakerPersistentPointCount, 1)
        XCTAssertEqual(summary.roomSeatDependentPointCount, 1)
        XCTAssertEqual(summary.ambiguousPointCount, 1)
        XCTAssertEqual(summary.noMaterialDeviationPointCount, 1)
        XCTAssertEqual(summary.sourceCount, 1)
        XCTAssertFalse(report.canDeploy)
    }
}
