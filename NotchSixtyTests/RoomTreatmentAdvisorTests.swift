import Foundation
import XCTest
@testable import NotchSixty

final class RoomTreatmentAdvisorTests: XCTestCase {
    func testMultiPositionBassVariationPrefersPlacement() {
        let frequencies = bassFrequencies
        let first = position(
            name: "Center",
            frequencies: frequencies,
            magnitudes: Array(
                repeating: 0,
                count: frequencies.count
            )
        )
        var secondMagnitudes = Array(
            repeating: 0.0,
            count: frequencies.count
        )
        secondMagnitudes[
            frequencies.firstIndex(of: 80)!
        ] = -10
        let second = position(
            name: "Left Seat",
            frequencies: frequencies,
            magnitudes: secondMagnitudes
        )
        let project = project(
            measurements: [first, second]
        )

        let report =
            RoomTreatmentAdvisorAnalyzer()
                .analyze(project: project)
        let finding = report.findings.first {
            $0.kind == .spatialBassVariation
        }

        XCTAssertNotNil(finding)
        XCTAssertEqual(
            finding?.primaryRemedy,
            .placement
        )
        XCTAssertTrue(
            finding?.secondaryRemedies.contains(
                .activeRoomTreatment
            ) == true
        )
        XCTAssertEqual(
            finding?.frequencyHz ?? 0,
            80,
            accuracy: 0.001
        )
    }

    func testSinglePositionDeepNullRequiresMoreMeasurementBeforeBoost() {
        var magnitudes = Array(
            repeating: 0.0,
            count: bassFrequencies.count
        )
        magnitudes[
            bassFrequencies.firstIndex(of: 80)!
        ] = -14
        let project = project(
            measurements: [
                position(
                    name: "Listening Position",
                    frequencies: bassFrequencies,
                    magnitudes: magnitudes
                ),
            ]
        )

        let report =
            RoomTreatmentAdvisorAnalyzer()
                .analyze(project: project)
        let finding = report.findings.first {
            $0.kind == .deepBassCancellation
        }

        XCTAssertNotNil(finding)
        XCTAssertEqual(
            finding?.primaryRemedy,
            .measureMore
        )
        XCTAssertTrue(
            finding?.secondaryRemedies.contains(
                .placement
            ) == true
        )
    }

    func testStrongEarlyReflectionPrefersPassiveTreatment() {
        let sampleRate = 48_000.0
        let direct = 480
        let reflection = 720
        var impulse = [Float](
            repeating: 0,
            count: 2_000
        )
        impulse[direct] = 1
        impulse[reflection] = 0.5

        let measured = position(
            name: "Center",
            frequencies: bassFrequencies,
            magnitudes: Array(
                repeating: 0,
                count: bassFrequencies.count
            ),
            sampleRate: sampleRate,
            impulse: impulse,
            directArrivalSeconds:
                Double(direct) / sampleRate
        )
        let report =
            RoomTreatmentAdvisorAnalyzer()
                .analyze(
                    project: project(
                        measurements: [measured]
                    )
                )
        let finding = report.findings.first {
            $0.kind == .earlyReflection
        }

        XCTAssertNotNil(finding)
        XCTAssertEqual(
            finding?.primaryRemedy,
            .passiveTreatment
        )
        XCTAssertEqual(
            finding?.delayMilliseconds ?? 0,
            5,
            accuracy: 0.05
        )
        XCTAssertTrue(
            finding?.measuredEvidence.contains(
                "relative to the direct sound"
            ) == true
        )
    }

    func testClippedOrLowSNRMeasurementFailsTowardMeasureMore() {
        let measured = position(
            name: "Center",
            frequencies: bassFrequencies,
            magnitudes: Array(
                repeating: 0,
                count: bassFrequencies.count
            ),
            clipped: true,
            snrDB: 12
        )
        let report =
            RoomTreatmentAdvisorAnalyzer()
                .analyze(
                    project: project(
                        measurements: [measured]
                    )
                )

        XCTAssertFalse(report.qualityWarnings.isEmpty)
        XCTAssertEqual(
            report.findings.first {
                $0.kind == .measurementQuality
            }?.primaryRemedy,
            .measureMore
        )
    }

    func testLongLowFrequencyDecayPrefersPassiveTreatment() {
        let sampleRate = 48_000.0
        let impulse = syntheticDecayImpulse(
            sampleRate: sampleRate,
            lowFrequencyHz: 80,
            lowRT60Seconds: 0.95,
            midRT60Seconds: 0.28
        )
        var magnitudes = Array(
            repeating: 0.0,
            count: bassFrequencies.count
        )
        magnitudes[
            bassFrequencies.firstIndex(of: 80)!
        ] = 6

        let report =
            RoomTreatmentAdvisorAnalyzer()
                .analyze(
                    project: project(
                        measurements: [
                            position(
                                name: "Center",
                                frequencies:
                                    bassFrequencies,
                                magnitudes: magnitudes,
                                sampleRate: sampleRate,
                                impulse: impulse,
                                directArrivalSeconds: 0
                            ),
                        ]
                    )
                )

        let finding = report.findings.first {
            $0.kind == .lowFrequencyRinging
        }
        XCTAssertNotNil(finding)
        XCTAssertEqual(
            finding?.primaryRemedy,
            .passiveTreatment
        )
        XCTAssertEqual(
            finding?.frequencyHz ?? 0,
            80,
            accuracy: 20
        )
        XCTAssertGreaterThan(
            finding?.decaySeconds ?? 0,
            0.5
        )
        XCTAssertTrue(
            finding?.interpretation.contains(
                "resonant"
            ) == true
        )
    }

    func testDeepNullWithNormalDecayBecomesBoundaryInterferenceCandidate() {
        let sampleRate = 48_000.0
        let impulse = syntheticDecayImpulse(
            sampleRate: sampleRate,
            lowFrequencyHz: 100,
            lowRT60Seconds: 0.58,
            midRT60Seconds: 0.58
        )
        var magnitudes = Array(
            repeating: 0.0,
            count: bassFrequencies.count
        )
        magnitudes[
            bassFrequencies.firstIndex(of: 100)!
        ] = -12

        let report =
            RoomTreatmentAdvisorAnalyzer()
                .analyze(
                    project: project(
                        measurements: [
                            position(
                                name: "Center",
                                frequencies:
                                    bassFrequencies,
                                magnitudes: magnitudes,
                                sampleRate: sampleRate,
                                impulse: impulse,
                                directArrivalSeconds: 0
                            ),
                        ]
                    )
                )

        let finding = report.findings.first {
            $0.kind
                == .boundaryInterferenceCandidate
        }
        XCTAssertNotNil(finding)
        XCTAssertEqual(
            finding?.primaryRemedy,
            .placement
        )
        XCTAssertTrue(
            finding?.interpretation.contains(
                "candidate"
            ) == true
        )
        XCTAssertTrue(
            finding?.recommendation.contains(
                "Avoid large EQ boost"
            ) == true
        )
    }

    func testMeasurementQualityTakesFirstActionPriority() {
        let measured = position(
            name: "Center",
            frequencies: bassFrequencies,
            magnitudes: Array(
                repeating: 0,
                count: bassFrequencies.count
            ),
            clipped: true,
            snrDB: 10
        )
        let report =
            RoomTreatmentAdvisorAnalyzer()
                .analyze(
                    project: project(
                        measurements: [measured]
                    )
                )

        XCTAssertEqual(
            report.actionPriorities.first?.remedy,
            .measureMore
        )
    }

    @MainActor
    func testControllerLoadsProjectsWithoutPlaybackProfileSelection() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "RoomAdvisorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default
                .removeItem(at: root)
        }
        let store = RoomCorrectionProjectStore(
            rootDirectory: root
        )

        var older = project(
            name: "Older Room",
            measurements: []
        )
        older.modifiedAt = Date(
            timeIntervalSince1970: 100
        )
        var newer = project(
            name: "Newer Room",
            measurements: []
        )
        newer.modifiedAt = Date(
            timeIntervalSince1970: 200
        )
        try store.save(older)
        try store.save(newer)

        let controller =
            RoomTreatmentAdvisorController(
                store: store
            )
        controller.prepareForUse()

        XCTAssertEqual(
            controller.availableProjects.map(\.name),
            ["Newer Room", "Older Room"]
        )
        XCTAssertEqual(
            controller.selectedProjectID,
            newer.id
        )
        XCTAssertEqual(
            controller.report?.projectName,
            "Newer Room"
        )
    }

    private func syntheticDecayImpulse(
        sampleRate: Double,
        lowFrequencyHz: Double,
        lowRT60Seconds: Double,
        midRT60Seconds: Double
    ) -> [Float] {
        let duration = max(
            1.4,
            max(
                lowRT60Seconds,
                midRT60Seconds
            ) * 1.35
        )
        let count = Int(
            (duration * sampleRate).rounded()
        )
        var result = [Float](
            repeating: 0,
            count: count
        )
        result[0] = 1

        let components: [
            (frequency: Double, rt60: Double, gain: Double)
        ] = [
            (lowFrequencyHz, lowRT60Seconds, 0.22),
            (500, midRT60Seconds, 0.08),
            (1_000, midRT60Seconds, 0.08),
            (2_000, midRT60Seconds, 0.08),
        ]
        for index in 1..<count {
            let t = Double(index) / sampleRate
            var value = 0.0
            for component in components {
                let tau =
                    component.rt60 / log(1_000)
                value += component.gain
                    * exp(-t / tau)
                    * sin(
                        2 * Double.pi
                        * component.frequency * t
                    )
            }
            result[index] = Float(value)
        }
        return result
    }

    private var bassFrequencies: [Double] {
        [
            40, 45, 50, 56, 63, 71, 80,
            90, 100, 112, 125, 140, 160,
            180, 200,
        ]
    }

    private func project(
        name: String = "Advisor Room",
        measurements: [RoomCorrectionMeasurementPosition]
    ) -> RoomCorrectionProject {
        var project = RoomCorrectionProject(
            playbackSystemID: UUID(),
            name: name,
            createdAt: Date(
                timeIntervalSince1970: 10
            ),
            modifiedAt: Date(
                timeIntervalSince1970: 20
            )
        )
        project.measurements = measurements
        return project
    }

    private func position(
        name: String,
        frequencies: [Double],
        magnitudes: [Double],
        sampleRate: Double = 48_000,
        impulse: [Float] = [1, 0, 0, 0],
        directArrivalSeconds: Double = 0,
        clipped: Bool = false,
        snrDB: Double = 45
    ) -> RoomCorrectionMeasurementPosition {
        let quality = RoomCorrectionMeasurementQuality(
            clipped: clipped,
            playbackPeakDBFS: -18,
            capturePeakDBFS: -12,
            estimatedNoiseFloorDBFS: -70,
            estimatedSNRDB: snrDB,
            sweepComplete: true,
            directArrivalSeconds:
                directArrivalSeconds,
            usableLowHz: frequencies.first,
            usableHighHz: frequencies.last,
            warnings: []
        )
        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: magnitudes,
            phaseRadians: frequencies.map { _ in 0 }
        )
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: Date(
                timeIntervalSince1970: 10
            ),
            rawCapture: [0, 0],
            impulseResponse: impulse,
            transferFunction: response,
            quality: quality
        )
        return RoomCorrectionMeasurementPosition(
            name: name,
            included: true,
            weight: 1,
            sampleRate: sampleRate,
            left: channel,
            right: channel
        )
    }
}
