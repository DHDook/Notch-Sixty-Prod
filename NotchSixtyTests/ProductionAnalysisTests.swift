import Foundation
import XCTest
@testable import NotchSixty

final class ProductionAnalysisTests: XCTestCase {
    func testAdaptiveFFTSizeThrough384k() {
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 44_100), 4_096)
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 48_000), 4_096)
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 96_000), 8_192)
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 192_000), 16_384)
        XCTAssertEqual(ProductionAnalysisMath.fftSize(sampleRate: 384_000), 32_768)
    }

    func testAnalysisBridgeDemandIsLocalSanitizedAndParkedByDefault() {
        guard let first = N60RealtimeAudioBridgeCreate(256),
              let second = N60RealtimeAudioBridgeCreate(256) else {
            XCTFail("Could not create analysis bridge fixtures")
            return
        }
        defer {
            N60RealtimeAudioBridgeDestroy(first)
            N60RealtimeAudioBridgeDestroy(second)
        }

        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(first),
            UInt32(N60_ANALYSIS_DEMAND_NONE)
        )
        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(second),
            UInt32(N60_ANALYSIS_DEMAND_NONE)
        )

        let unsupportedBit = UInt32(1 << 30)
        N60RealtimeAudioBridgeSetAnalysisDemand(
            first,
            UInt32(N60_ANALYSIS_DEMAND_ALL) | unsupportedBit
        )

        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(first),
            UInt32(N60_ANALYSIS_DEMAND_ALL)
        )
        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(second),
            UInt32(N60_ANALYSIS_DEMAND_NONE),
            "Analysis demand must remain bridge-local"
        )

        let activeSnapshot = N60RealtimeAudioBridgeGetAnalysisCaptureSnapshot(first)
        XCTAssertEqual(activeSnapshot.demandMask, UInt32(N60_ANALYSIS_DEMAND_ALL))
        XCTAssertEqual(activeSnapshot.availableFrames, 0)
        XCTAssertEqual(activeSnapshot.capturedFrames, 0)
        XCTAssertEqual(activeSnapshot.droppedFrames, 0)

        var frames = [N60AnalysisFrame](
            repeating: N60AnalysisFrame(inputLeft: 0, inputRight: 0, outputLeft: 0, outputRight: 0),
            count: 8
        )
        let readCount = frames.withUnsafeMutableBufferPointer { buffer in
            N60RealtimeAudioBridgeReadAnalysisFrames(
                first,
                buffer.baseAddress!,
                UInt32(buffer.count)
            )
        }
        XCTAssertEqual(readCount, 0, "An empty capture ring must not synthesize frames")

        N60RealtimeAudioBridgeSetAnalysisDemand(first, UInt32(N60_ANALYSIS_DEMAND_NONE))
        XCTAssertEqual(
            N60RealtimeAudioBridgeAnalysisDemand(first),
            UInt32(N60_ANALYSIS_DEMAND_NONE)
        )
    }

    func testPhaseCorrelationCanonicalCases() {
        let sampleCount = 4_096
        let phaseStep = 2.0 * Double.pi * 64.0 / Double(sampleCount)
        let sine = (0..<sampleCount).map { Float(sin(Double($0) * phaseStep)) }
        let inverted = sine.map { -$0 }
        let cosine = (0..<sampleCount).map { Float(cos(Double($0) * phaseStep)) }

        XCTAssertEqual(
            ProductionAnalysisMath.phaseCorrelation(left: sine, right: sine, count: sampleCount) ?? 0,
            1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ProductionAnalysisMath.phaseCorrelation(left: sine, right: inverted, count: sampleCount) ?? 0,
            -1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ProductionAnalysisMath.phaseCorrelation(left: sine, right: cosine, count: sampleCount) ?? 1,
            0,
            accuracy: 0.001
        )
    }

    func testPhaseCorrelationTreatsSilenceAsUndefined() {
        let silence = [Float](repeating: 0, count: 2_048)
        XCTAssertNil(ProductionAnalysisMath.phaseCorrelation(
            left: silence,
            right: silence,
            count: silence.count
        ))
    }

    func testGoniometerUsesStandardFortyFiveDegreeRotation() {
        let mono = ProductionAnalysisMath.goniometerPoint(left: 1, right: 1)
        XCTAssertEqual(mono.x, 0, accuracy: 0.000_01)
        XCTAssertEqual(mono.y, Float(2).squareRoot(), accuracy: 0.000_01)

        let side = ProductionAnalysisMath.goniometerPoint(left: 1, right: -1)
        XCTAssertEqual(side.x, Float(2).squareRoot(), accuracy: 0.000_01)
        XCTAssertEqual(side.y, 0, accuracy: 0.000_01)
    }

    func testSpectrumSilenceStaysAtFloorThrough384k() {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            let analyzer = ProductionSpectrumAnalyzer()
            let count = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
            let silence = [Float](repeating: 0, count: count)
            let bands = analyzer.analyze(
                inputLeft: silence,
                inputRight: silence,
                outputLeft: silence,
                outputRight: silence,
                count: count,
                sampleRate: sampleRate
            )

            XCTAssertEqual(bands.count, 96, "Unexpected band count at \(sampleRate) Hz")
            for band in bands {
                XCTAssertTrue(band.inputDB.isFinite)
                XCTAssertTrue(band.outputDB.isFinite)
                XCTAssertEqual(band.inputDB, ProductionAnalysisMath.spectrumFloorDB, accuracy: 0.000_1)
                XCTAssertEqual(band.outputDB, ProductionAnalysisMath.spectrumFloorDB, accuracy: 0.000_1)
            }
        }
    }

    func testFullScaleOneKilohertzSineLandsNearZeroDBFS() {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            let analyzer = ProductionSpectrumAnalyzer()
            let count = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
            let samples = (0..<count).map { index in
                Float(sin(2.0 * Double.pi * 1_000.0 * Double(index) / sampleRate))
            }
            let bands = analyzer.analyze(
                inputLeft: samples,
                inputRight: samples,
                outputLeft: samples,
                outputRight: samples,
                count: count,
                sampleRate: sampleRate
            )

            guard let strongest = bands.max(by: { $0.inputDB < $1.inputDB }) else {
                XCTFail("No RTA bands at \(sampleRate) Hz")
                continue
            }
            XCTAssertGreaterThan(strongest.inputDB, -4.0, "1 kHz too low at \(sampleRate) Hz")
            XCTAssertLessThanOrEqual(strongest.inputDB, 0.000_1)
            XCTAssertEqual(strongest.inputDB, strongest.outputDB, accuracy: 0.000_1)
            XCTAssertLessThan(abs(strongest.frequencyHz - 1_000.0), 175.0)
        }
    }

    func testSpectrumStereoEnergyDoesNotCancelAntiPhaseChannels() {
        let sampleRate = 96_000.0
        let analyzer = ProductionSpectrumAnalyzer()
        let count = ProductionAnalysisMath.fftSize(sampleRate: sampleRate)
        let left = (0..<count).map { index in
            Float(sin(2.0 * Double.pi * 1_000.0 * Double(index) / sampleRate))
        }
        let right = left.map { -$0 }

        let bands = analyzer.analyze(
            inputLeft: left,
            inputRight: right,
            outputLeft: left,
            outputRight: right,
            count: count,
            sampleRate: sampleRate
        )

        guard let strongest = bands.max(by: { $0.inputDB < $1.inputDB }) else {
            XCTFail("No anti-phase RTA bands")
            return
        }
        XCTAssertGreaterThan(
            strongest.inputDB,
            -4.0,
            "Stereo RTA must combine channel energy after the transform rather than cancel anti-phase content"
        )
        XCTAssertEqual(strongest.inputDB, strongest.outputDB, accuracy: 0.000_1)
    }

    func testPlaybackSystemStateKeepsPR39ProfileDataBackwardCompatible() throws {
        let state = PlaybackSystemState()
        let data = try JSONEncoder().encode(state)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("roomCorrectionCalibration"), "Nil additive metadata should remain absent from legacy-compatible JSON")

        let decoded = try JSONDecoder().decode(PlaybackSystemState.self, from: data)
        XCTAssertNil(decoded.roomCorrectionCalibration)
        XCTAssertEqual(decoded, state)
    }

    func testMicrophoneCalibrationParserNormalizesSortsAndDeduplicates() throws {
        let text = """
        # frequency gain
        1000, -1.0
        20 1.5
        1000 -3.0 ; duplicate points are averaged
        20000 -0.5
        """

        let calibration = try RoomCorrectionMicrophoneCalibrationParser()
            .parse(text, sourceName: "fixture.cal")

        XCTAssertEqual(calibration.sourceName, "fixture.cal")
        XCTAssertEqual(calibration.points.map(\.frequencyHz), [20, 1_000, 20_000])
        XCTAssertEqual(calibration.points.map(\.gainDB), [1.5, -2.0, -0.5])
    }

    func testMicrophoneCalibrationInterpolatesInLogFrequencySpaceAndClampsEnds() throws {
        let calibration = RoomCorrectionMicrophoneCalibration(
            sourceName: "fixture.cal",
            points: [
                RoomCorrectionCalibrationPoint(frequencyHz: 100, gainDB: 0),
                RoomCorrectionCalibrationPoint(frequencyHz: 10_000, gainDB: 4),
            ]
        )

        XCTAssertEqual(try calibration.gainDB(at: 10), 0, accuracy: 0.000_001)
        XCTAssertEqual(try calibration.gainDB(at: 1_000), 2, accuracy: 0.000_001)
        XCTAssertEqual(try calibration.gainDB(at: 20_000), 4, accuracy: 0.000_001)
    }

    func testMicrophoneCalibrationParserRejectsAmbiguousOrInvalidData() throws {
        XCTAssertThrowsError(
            try RoomCorrectionMicrophoneCalibrationParser().parse("20 0.5 12\n20000 0")
        ) { error in
            XCTAssertEqual(error as? RoomCorrectionMicrophoneCalibrationError, .malformedLine(1))
        }

        XCTAssertThrowsError(
            try RoomCorrectionMicrophoneCalibrationParser().parse("0 0.5\n20000 0")
        ) { error in
            XCTAssertEqual(error as? RoomCorrectionMicrophoneCalibrationError, .invalidFrequency(line: 1))
        }

        XCTAssertThrowsError(
            try RoomCorrectionMicrophoneCalibrationParser().parse("1000 0\n1000 1")
        ) { error in
            XCTAssertEqual(error as? RoomCorrectionMicrophoneCalibrationError, .insufficientUniquePoints)
        }
    }

    func testRoomCorrectionProjectRoundTripsRawAndDesignAssets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR40-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoomCorrectionProjectStore(rootDirectory: root)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let systemID = UUID()
        var project = RoomCorrectionProject(
            playbackSystemID: systemID,
            name: "Living Room",
            createdAt: created,
            modifiedAt: created
        )
        project.microphone = RoomCorrectionMicrophone(
            stableID: "fixture-mic",
            displayName: "Fixture Microphone",
            manufacturer: "Notch Sixty Tests",
            calibration: RoomCorrectionMicrophoneCalibration(
                sourceName: "fixture.cal",
                points: [
                    RoomCorrectionCalibrationPoint(frequencyHz: 20, gainDB: 0.5),
                    RoomCorrectionCalibrationPoint(frequencyHz: 1_000, gainDB: 0),
                    RoomCorrectionCalibrationPoint(frequencyHz: 20_000, gainDB: -0.5),
                ]
            )
        )
        project.sweep = RoomCorrectionSweepSettings(sampleRate: 48_000)

        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: [20, 100, 1_000, 10_000, 20_000],
            magnitudeDB: [2, 1, 0, -1, -2],
            phaseRadians: [0, -0.1, -0.2, -0.3, -0.4]
        )
        let measurement = RoomCorrectionMeasurement(
            name: "Center",
            capturedAt: created,
            sampleRate: 48_000,
            rawCapture: [0, 0.25, -0.25, 0],
            impulseResponse: [0, 1, 0],
            transferFunction: response,
            quality: RoomCorrectionMeasurementQuality(
                clipped: false,
                playbackPeakDBFS: -18,
                capturePeakDBFS: -12,
                estimatedNoiseFloorDBFS: -70,
                estimatedSNRDB: 58,
                sweepComplete: true,
                directArrivalSeconds: 0.012,
                usableLowHz: 25,
                usableHighHz: 19_000,
                warnings: []
            )
        )
        project.measurements = [measurement]
        project.aggregate = RoomCorrectionAggregateResponse(
            generatedAt: created,
            includedMeasurementIDs: [measurement.id],
            response: response
        )
        project.target = RoomCorrectionTargetCurve(
            name: "Gentle Tilt",
            points: [
                RoomCorrectionTargetPoint(frequencyHz: 20, gainDB: 3),
                RoomCorrectionTargetPoint(frequencyHz: 1_000, gainDB: 0),
                RoomCorrectionTargetPoint(frequencyHz: 20_000, gainDB: -2),
            ]
        )

        let design = RoomCorrectionDesign(
            name: "Living Room v1",
            createdAt: created,
            sampleRate: 48_000,
            parameters: RoomCorrectionDesignParameters(
                correctionLowHz: 25,
                correctionHighHz: 19_000,
                smoothingOctaves: 1.0 / 6.0,
                maximumBoostDB: 6,
                maximumCutDB: 12,
                requestedTapCount: 4_096
            ),
            filter: RoomCorrectionFilter(
                name: "Living Room v1",
                sampleRate: 48_000,
                leftTaps: [0.25, 0.5, 0.25],
                rightTaps: nil,
                declaredLatencyFrames: 1
            ),
            predictedResponse: response,
            recommendedHeadroomDB: 3,
            algorithmVersion: "pr40-fixture-v1"
        )
        project.designs = [design]
        project.selectedDesignID = design.id

        let savedURL = try store.save(project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertEqual(try store.load(project.id), project)
        XCTAssertEqual(try store.existingProjectIDs(), [project.id])
    }

    func testRoomCorrectionProjectStorePreservesCorruptFileForRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR40-Corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoomCorrectionProjectStore(rootDirectory: root)
        let id = UUID()
        let url = store.projectURL(for: id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ definitely-not-json".utf8).write(to: url, options: .atomic)

        XCTAssertThrowsError(try store.load(id)) { error in
            XCTAssertEqual(error as? RoomCorrectionProjectError, .corruptProject(id))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Corrupt project data must be left in place for explicit recovery rather than silently deleted"
        )
    }

    func testRoomCorrectionProjectRejectsUnsupportedSchemaBeforeWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR40-Version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoomCorrectionProjectStore(rootDirectory: root)
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Version Fixture")
        project.schemaVersion = RoomCorrectionProject.currentSchemaVersion + 1

        XCTAssertThrowsError(try store.save(project)) { error in
            XCTAssertEqual(
                error as? RoomCorrectionProjectError,
                .unsupportedVersion(RoomCorrectionProject.currentSchemaVersion + 1)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.projectURL(for: project.id).path))
    }
}
