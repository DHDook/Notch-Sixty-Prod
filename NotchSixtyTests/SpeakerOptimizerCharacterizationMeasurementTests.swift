import XCTest
@testable import NotchSixty

final class SpeakerOptimizerCharacterizationMeasurementTests: XCTestCase {
    private let systemID = UUID(uuidString: "C1000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let mic = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "pr105-characterization-mic",
        inputChannelIndex: 0,
        calibrationFingerprint: "pr105-cal"
    )
    private let left: MultichannelCalibrationSource = .speaker(.frontLeft)
    private let right: MultichannelCalibrationSource = .speaker(.frontRight)

    func testWholeSpeakersUseSeparateGeometryBoundCharacterizationTargets() throws {
        let set = makeSet()
        XCTAssertEqual(set.targets.count, 2)
        XCTAssertNotEqual(set.targets[0].id, set.targets[1].id)
        XCTAssertEqual(set.targets[0].geometry.distanceMeters, 1.0)
        XCTAssertTrue(set.targets.allSatisfy { $0.geometry.speakerRemainedInInstalledPosition })
        XCTAssertNoThrow(try set.validateStructure())
    }

    func testSubwooferAndLFEAreNotSpeakerCharacterizationTargets() throws {
        var set = makeSet()
        set.targets.append(SpeakerOptimizerCharacterizationTarget(
            source: .subwoofer(0), geometry: .init()
        ))
        XCTAssertThrowsError(try set.validateStructure())
        set = makeSet()
        set.targets[0].source = .speaker(.lowFrequencyEffects)
        XCTAssertThrowsError(try set.validateStructure())
    }

    func testGeometryFailsClosedOutsideIntegrationRangeOrOffAxis() throws {
        var set = makeSet()
        set.targets[0].geometry.distanceMeters = 0.25
        XCTAssertThrowsError(try set.validateStructure())
        set = makeSet()
        set.targets[0].geometry.horizontalOffsetDegrees = 20
        XCTAssertThrowsError(try set.validateStructure())
        set = makeSet()
        set.targets[0].geometry.speakerRemainedInInstalledPosition = false
        XCTAssertThrowsError(try set.validateStructure())
    }

    func testCharacterizationCompletesThreeStationaryRepeatsBeforeMovingSpeakerTarget() throws {
        let set = makeSet()
        let orchestrator = try SpeakerOptimizerCharacterizationSessionOrchestrator()
        let steps = try orchestrator.steps(for: set)
        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual(Array(steps.prefix(3).map(\.target.id)),
                       Array(repeating: set.targets[0].id, count: 3))
        XCTAssertEqual(Array(steps.suffix(3).map(\.target.id)),
                       Array(repeating: set.targets[1].id, count: 3))
        XCTAssertEqual(Array(steps.prefix(3).map(\.repeatIndex)), [0, 1, 2])
        XCTAssertTrue(steps[0].instruction.contains("installed position"))
        XCTAssertTrue(steps[0].instruction.contains("1.00 m"))
    }

    func testCaptureCannotBeMixedBetweenCharacterizationTargets() throws {
        let set = makeSet()
        let orchestrator = try SpeakerOptimizerCharacterizationSessionOrchestrator()
        let step = try XCTUnwrap(orchestrator.nextPendingStep(for: set))
        let wrong = makeCapture(target: set.targets[1], repeatIndex: 0)
        XCTAssertThrowsError(
            try orchestrator.appending(wrong, to: set, for: step)
        )
    }

    func testStableCharacterizationReusesStrictPR103EvidenceQualification() throws {
        var set = makeSet()
        for target in set.targets {
            for repeatIndex in 0..<3 {
                set.captures.append(makeCapture(
                    target: target, repeatIndex: repeatIndex
                ))
            }
        }
        let report = try SpeakerOptimizerCharacterizationEvidenceEvaluator()
            .evaluate(set)
        XCTAssertTrue(report.optimizerReady, report.blockingReasons.joined(separator: "; "))
        XCTAssertEqual(report.groups.count, 2)
        XCTAssertTrue(report.groups.allSatisfy { $0.evidence.repeatCount == 3 })
        XCTAssertTrue(report.groups.allSatisfy { ($0.evidence.minimumSNRDB ?? 0) >= 50 })
    }

    func testNoisyNearSpeakerRepeatsFailClosed() throws {
        var set = makeSet(targets: [makeTarget(source: left)])
        for repeatIndex in 0..<3 {
            var capture = makeCapture(target: set.targets[0], repeatIndex: repeatIndex)
            if repeatIndex == 2 { capture.quality.estimatedSNRDB = 20 }
            set.captures.append(capture)
        }
        let report = try SpeakerOptimizerCharacterizationEvidenceEvaluator().evaluate(set)
        XCTAssertFalse(report.optimizerReady)
        XCTAssertTrue(report.blockingReasons.contains {
            $0.localizedCaseInsensitiveContains("SNR")
        })
    }

    func testListeningCampaignCompatibilityRequiresSameMeasurementIdentity() throws {
        let characterization = makeSet()
        let baseline = makeListeningBaseline()
        XCTAssertNoThrow(try characterization.validateCompatibility(with: baseline))
        var incompatible = baseline
        incompatible.routingSignature = "other-route"
        XCTAssertThrowsError(
            try characterization.validateCompatibility(with: incompatible)
        ) {
            XCTAssertEqual(
                $0 as? SpeakerOptimizerCharacterizationError,
                .incompatibleListeningEvidence
            )
        }
    }

    func testLinkedListeningMeasurementIDCannotSilentlyChange() throws {
        let baseline = makeListeningBaseline()
        var characterization = makeSet()
        characterization.linkedListeningMeasurementSetID = baseline.id
        XCTAssertNoThrow(try characterization.validateCompatibility(with: baseline))
        var different = baseline
        different.id = UUID()
        XCTAssertThrowsError(
            try characterization.validateCompatibility(with: different)
        )
    }

    func testCharacterizationPersistenceIsCompactAndDomainSeparated() throws {
        var set = makeSet(targets: [makeTarget(source: left)])
        set.captures = (0..<3).map {
            makeCapture(target: set.targets[0], repeatIndex: $0)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PR105-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpeakerOptimizerCharacterizationSetStore(rootDirectory: root)
        try store.save(set)
        let loaded = try XCTUnwrap(store.load(set.id))
        XCTAssertEqual(loaded, set)
        let json = try XCTUnwrap(String(
            data: Data(contentsOf: store.url(for: set.id)),
            encoding: .utf8
        ))
        XCTAssertTrue(json.contains("distanceMeters"))
        XCTAssertFalse(json.contains("rawCapture"))
        XCTAssertFalse(json.contains("impulseResponse"))
    }

    private func makeSet(
        targets: [SpeakerOptimizerCharacterizationTarget]? = nil
    ) -> SpeakerOptimizerCharacterizationMeasurementSet {
        SpeakerOptimizerCharacterizationMeasurementSet(
            playbackSystemID: systemID,
            routingSignature: "pr105-stable-route",
            microphone: mic,
            sampleRate: 48_000,
            linkedListeningMeasurementSetID: nil,
            targets: targets ?? [
                makeTarget(source: left),
                makeTarget(source: right)
            ],
            captures: []
        )
    }

    private func makeTarget(
        source: MultichannelCalibrationSource
    ) -> SpeakerOptimizerCharacterizationTarget {
        SpeakerOptimizerCharacterizationTarget(
            source: source,
            geometry: SpeakerOptimizerCharacterizationGeometry(
                distanceMeters: 1.0,
                axisReference: .acousticCenter,
                horizontalOffsetDegrees: 0,
                verticalOffsetDegrees: 0,
                speakerRemainedInInstalledPosition: true
            )
        )
    }

    private func makeCapture(
        target: SpeakerOptimizerCharacterizationTarget,
        repeatIndex: Int
    ) -> SpeakerOptimizerMeasurementCapture {
        let frequencies = (0..<64).map { i in
            40 * pow(400.0, Double(i) / 63)
        }
        let phaseOffset = Double(repeatIndex - 1) * 0.01
        return SpeakerOptimizerMeasurementCapture(
            capturedAt: Date(timeIntervalSince1970:
                1_703_000_000 + Double(repeatIndex)),
            playbackSystemID: systemID,
            routingSignature: "pr105-stable-route",
            microphone: mic,
            positionID: target.id,
            source: target.source,
            sampleRate: 48_000,
            response: RoomCorrectionFrequencyResponse(
                frequenciesHz: frequencies,
                magnitudeDB: frequencies.map { f in
                    2.5 * exp(-0.5 * pow(log2(f / 1_500) / 0.7, 2))
                        + Double(repeatIndex - 1) * 0.05
                },
                phaseRadians: frequencies.map { f in
                    0.06 * log2(f / 1_000) + phaseOffset
                }
            ),
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -24,
                capturePeakDBFS: -14,
                estimatedNoiseFloorDBFS: -72,
                estimatedSNRDB: 55,
                sweepComplete: true,
                directArrivalSeconds: 0.003
                    + Double(repeatIndex) * 0.00002,
                usableLowHz: 40,
                usableHighHz: 16_000,
                warnings: []
            )
        )
    }

    private func makeListeningBaseline() -> SpeakerOptimizerMeasurementSet {
        let position = SpeakerOptimizerMeasurementPosition(
            id: UUID(uuidString: "C2000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
            name: "Main seat"
        )
        return SpeakerOptimizerMeasurementSet(
            role: .baseline,
            playbackSystemID: systemID,
            routingSignature: "pr105-stable-route",
            microphone: mic,
            sampleRate: 48_000,
            positions: [position],
            plannedSources: [left, right],
            captures: []
        )
    }
}
