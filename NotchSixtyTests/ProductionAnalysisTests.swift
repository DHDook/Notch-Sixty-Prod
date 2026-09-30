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

    func testRoomCorrectionProjectRoundTripsPairedStereoMeasurementAndDesignAssets() throws {
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
            inputChannelIndex: 1,
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

        let leftResponse = RoomCorrectionFrequencyResponse(
            frequenciesHz: [20, 100, 1_000, 10_000, 20_000],
            magnitudeDB: [2, 1, 0, -1, -2],
            phaseRadians: [0, -0.1, -0.2, -0.3, -0.4]
        )
        let rightResponse = RoomCorrectionFrequencyResponse(
            frequenciesHz: [20, 100, 1_000, 10_000, 20_000],
            magnitudeDB: [1.5, 0.75, -0.25, -1.25, -2.5],
            phaseRadians: [0.05, -0.05, -0.15, -0.25, -0.35]
        )
        let quality = RoomCorrectionMeasurementQuality(
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
        let position = RoomCorrectionMeasurementPosition(
            name: "Center",
            sampleRate: 48_000,
            left: RoomCorrectionChannelMeasurement(
                capturedAt: created,
                rawCapture: [0, 0.25, -0.25, 0],
                impulseResponse: [0, 1, 0],
                transferFunction: leftResponse,
                quality: quality
            ),
            right: RoomCorrectionChannelMeasurement(
                capturedAt: created.addingTimeInterval(6),
                rawCapture: [0, 0.2, -0.15, 0],
                impulseResponse: [0, 0.9, 0],
                transferFunction: rightResponse,
                quality: quality
            )
        )
        project.measurements = [position]
        project.aggregate = RoomCorrectionAggregateResponse(
            generatedAt: created,
            includedPositionIDs: [position.id],
            leftResponse: leftResponse,
            rightResponse: rightResponse
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
                rightTaps: [0.2, 0.6, 0.2],
                declaredLatencyFrames: 1
            ),
            predictedLeftResponse: leftResponse,
            predictedRightResponse: rightResponse,
            recommendedHeadroomDB: 3,
            algorithmVersion: "pr40-fixture-v2"
        )
        project.designs = [design]
        project.selectedDesignID = design.id

        let savedURL = try store.save(project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertEqual(savedURL.lastPathComponent, "project-v2.json")
        XCTAssertEqual(try store.load(project.id), project)
        XCTAssertEqual(try store.existingProjectIDs(), [project.id])
    }

    func testRoomCorrectionProjectRejectsAggregateThatReferencesMissingPosition() throws {
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Invalid Aggregate")
        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: [20, 20_000],
            magnitudeDB: [0, 0],
            phaseRadians: nil
        )
        project.aggregate = RoomCorrectionAggregateResponse(
            generatedAt: Date(),
            includedPositionIDs: [UUID()],
            leftResponse: response,
            rightResponse: response
        )

        XCTAssertThrowsError(try project.validateForPersistence())
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

    func testRoomCorrectionSweepGeneratorIsDeterministicFiniteAndBounded() throws {
        let settings = RoomCorrectionSweepSettings(
            sampleRate: 48_000,
            startFrequencyHz: 20,
            endFrequencyHz: 20_000,
            durationSeconds: 0.25,
            levelDBFS: -18,
            leadInSeconds: 0.1,
            tailSeconds: 0.2,
            fadeSeconds: 0.01
        )
        let generator = RoomCorrectionSweepGenerator()
        let first = try generator.makeProgram(settings: settings)
        let second = try generator.makeProgram(settings: settings)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sweepSamples.count, 12_000)
        XCTAssertEqual(first.inverseFilter.count, first.sweepSamples.count)
        XCTAssertEqual(first.leadInFrames, 4_800)
        XCTAssertEqual(first.tailFrames, 9_600)
        XCTAssertEqual(first.captureFrameCount, 26_400)
        XCTAssertTrue(first.sweepSamples.allSatisfy(\.isFinite))
        XCTAssertTrue(first.inverseFilter.allSatisfy(\.isFinite))

        let expectedPeak = pow(10.0, -18.0 / 20.0)
        XCTAssertLessThanOrEqual(
            Double(first.sweepSamples.map { abs($0) }.max() ?? 0),
            expectedPeak + 0.000_001
        )
        XCTAssertLessThanOrEqual(first.inverseFilter.map { abs($0) }.max() ?? 0, 1.000_001)
    }

    func testRoomCorrectionSweepGeneratorRejectsNyquistUnsafeSweep() throws {
        let settings = RoomCorrectionSweepSettings(
            sampleRate: 44_100,
            startFrequencyHz: 20,
            endFrequencyHz: 21_900,
            durationSeconds: 1,
            levelDBFS: -18,
            leadInSeconds: 0,
            tailSeconds: 0,
            fadeSeconds: 0
        )

        XCTAssertThrowsError(try RoomCorrectionSweepGenerator().makeProgram(settings: settings)) { error in
            XCTAssertEqual(error as? RoomCorrectionSweepGenerationError, .invalidSettings)
        }
    }

    func testRoomCorrectionMeasurementPlanRoutesSequentialSpeakersAndExactCaptures() throws {
        let settings = RoomCorrectionSweepSettings(
            sampleRate: 1_000,
            startFrequencyHz: 20,
            endFrequencyHz: 400,
            durationSeconds: 0.1,
            levelDBFS: -6,
            leadInSeconds: 0.01,
            tailSeconds: 0.02,
            fadeSeconds: 0
        )
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: settings)
        let plan = try RoomCorrectionMeasurementPlan(program: program, settlingSeconds: 0.03)

        XCTAssertEqual(program.sweepSamples.count, 100)
        XCTAssertEqual(program.captureFrameCount, 130)
        XCTAssertEqual(plan.settlingFrames, 30)
        XCTAssertEqual(plan.leftPass.captureFrameCount, 130)
        XCTAssertEqual(plan.rightPass.captureFrameCount, 130)
        XCTAssertEqual(plan.rightPass.captureStartFrame, 160)
        XCTAssertEqual(plan.totalFrameCount, 290)

        XCTAssertEqual(
            plan.captureDestination(at: plan.leftPass.captureStartFrame),
            RoomCorrectionCaptureDestination(pass: .left, frameIndex: 0)
        )
        XCTAssertEqual(
            plan.captureDestination(at: plan.leftPass.captureEndFrameExclusive - 1),
            RoomCorrectionCaptureDestination(pass: .left, frameIndex: 129)
        )
        XCTAssertNil(plan.captureDestination(at: 145), "Inter-pass settling must not be captured")
        XCTAssertEqual(
            plan.captureDestination(at: plan.rightPass.captureStartFrame),
            RoomCorrectionCaptureDestination(pass: .right, frameIndex: 0)
        )

        let leftProbe = plan.outputFrame(at: plan.leftPass.sweepStartFrame + 1)
        XCTAssertNotEqual(leftProbe.left, 0)
        XCTAssertEqual(leftProbe.right, 0)

        let settlingProbe = plan.outputFrame(at: plan.leftPass.captureEndFrameExclusive + 1)
        XCTAssertEqual(settlingProbe.left, 0)
        XCTAssertEqual(settlingProbe.right, 0)

        let rightProbe = plan.outputFrame(at: plan.rightPass.sweepStartFrame + 1)
        XCTAssertEqual(rightProbe.left, 0)
        XCTAssertNotEqual(rightProbe.right, 0)
    }

    func testCalibrationStateMachineRejectsInvalidTransitions() throws {
        var machine = RoomCorrectionCalibrationStateMachine()
        XCTAssertEqual(machine.state, .idle)

        XCTAssertThrowsError(try machine.transition(to: .measuring)) { error in
            XCTAssertEqual(
                error as? RoomCorrectionCalibrationSessionError,
                .invalidTransition(from: .idle, to: .measuring)
            )
        }
        XCTAssertEqual(machine.state, .idle)

        try machine.transition(to: .ready)
        try machine.transition(to: .arming)
        try machine.transition(to: .measuring)
        try machine.transition(to: .analyzing)
        try machine.transition(to: .reviewing)
        XCTAssertEqual(machine.state, .reviewing)

        machine.cancelToIdle()
        XCTAssertEqual(machine.state, .idle)
    }

    func testCalibrationTopologyRequiresNativeRateAndUsesInputDriftCompensation() throws {
        let output = AudioOutputDevice(
            deviceID: 7,
            uid: "output",
            name: "Output Fixture",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 96_000)]
        )
        let sameDeviceInput = AudioInputDevice(
            deviceID: 7,
            uid: "same-device-input",
            name: "Same Device Input",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 48_000)]
        )
        let separateInput = AudioInputDevice(
            deviceID: 8,
            uid: "usb-mic",
            name: "USB Mic Fixture",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)]
        )

        XCTAssertEqual(
            try RoomCorrectionCalibrationTopologyPlanner.validatedTopology(
                output: output,
                input: sameDeviceInput,
                sampleRate: 48_000
            ),
            .direct(deviceID: 7)
        )
        XCTAssertEqual(
            try RoomCorrectionCalibrationTopologyPlanner.validatedTopology(
                output: output,
                input: separateInput,
                sampleRate: 96_000
            ),
            .privateAggregate(
                outputDeviceID: 7,
                inputDeviceID: 8,
                driftCompensateInput: true
            )
        )

        XCTAssertThrowsError(
            try RoomCorrectionCalibrationTopologyPlanner.validatedTopology(
                output: output,
                input: separateInput,
                sampleRate: 44_100
            )
        ) { error in
            XCTAssertEqual(
                error as? RoomCorrectionCalibrationSessionError,
                .unsupportedSampleRate(
                    sampleRate: 44_100,
                    outputName: "Output Fixture",
                    inputName: "USB Mic Fixture"
                )
            )
        }
    }

    func testCaptureBufferRequiresContiguousWritesBeforeComplete() throws {
        let buffer = try RoomCorrectionCaptureBuffer(capacityFrames: 3)

        XCTAssertFalse(buffer.write(3, at: 2), "Out-of-order writes must not create a false-complete capture")
        XCTAssertEqual(buffer.writtenFrames, 0)
        XCTAssertFalse(buffer.isComplete)
        XCTAssertThrowsError(try buffer.materialize()) { error in
            XCTAssertEqual(error as? RoomCorrectionCalibrationSessionError, .captureNotComplete)
        }

        XCTAssertTrue(buffer.write(1, at: 0))
        XCTAssertTrue(buffer.write(2, at: 1))
        XCTAssertTrue(buffer.write(3, at: 2))
        XCTAssertTrue(buffer.isComplete)
        XCTAssertEqual(try buffer.materialize(), [1, 2, 3])

        buffer.reset()
        XCTAssertEqual(buffer.writtenFrames, 0)
        XCTAssertFalse(buffer.isComplete)
    }

    func testRealtimeMeasurementSessionCapturesPairedPassesAcrossArbitraryQuanta() throws {
        let settings = RoomCorrectionSweepSettings(
            sampleRate: 1_000,
            startFrequencyHz: 20,
            endFrequencyHz: 400,
            durationSeconds: 0.01,
            levelDBFS: -12,
            leadInSeconds: 0.002,
            tailSeconds: 0.003,
            fadeSeconds: 0
        )
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: settings)
        let plan = try RoomCorrectionMeasurementPlan(program: program, settlingSeconds: 0.004)
        let session = try RoomCorrectionMeasurementRealtimeSession(plan: plan)

        XCTAssertEqual(program.captureFrameCount, 15)
        XCTAssertEqual(plan.leftPass.captureStartFrame, 0)
        XCTAssertEqual(plan.leftPass.captureEndFrameExclusive, 15)
        XCTAssertEqual(plan.rightPass.captureStartFrame, 19)
        XCTAssertEqual(plan.rightPass.captureEndFrameExclusive, 34)
        XCTAssertEqual(plan.totalFrameCount, 34)

        var renderedLeft: [Float] = []
        var renderedRight: [Float] = []
        for quantum in [7, 9, 18] {
            let start = session.frameCursor
            var microphone = (0..<quantum).map { Float(start + $0) }
            var left = [Float](repeating: -99, count: quantum)
            var right = [Float](repeating: -99, count: quantum)

            let consumed = microphone.withUnsafeMutableBufferPointer { microphoneBuffer in
                left.withUnsafeMutableBufferPointer { leftBuffer in
                    right.withUnsafeMutableBufferPointer { rightBuffer in
                        session.process(
                            microphone: UnsafePointer(microphoneBuffer.baseAddress!),
                            outputLeft: leftBuffer.baseAddress!,
                            outputRight: rightBuffer.baseAddress!,
                            frameCount: quantum
                        )
                    }
                }
            }
            XCTAssertEqual(consumed, quantum)
            renderedLeft.append(contentsOf: left)
            renderedRight.append(contentsOf: right)
        }

        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(try session.leftCapture.materialize(), (0..<15).map(Float.init))
        XCTAssertEqual(try session.rightCapture.materialize(), (19..<34).map(Float.init))
        XCTAssertEqual(renderedLeft.count, 34)
        XCTAssertEqual(renderedRight.count, 34)

        for index in renderedLeft.indices {
            XCTAssertFalse(
                renderedLeft[index] != 0 && renderedRight[index] != 0,
                "Only one loudspeaker may be excited at timeline frame \(index)"
            )
        }
        for index in 15..<19 {
            XCTAssertEqual(renderedLeft[index], 0)
            XCTAssertEqual(renderedRight[index], 0)
        }

        var microphone = [Float](repeating: 0, count: 4)
        var left = [Float](repeating: 1, count: 4)
        var right = [Float](repeating: 1, count: 4)
        let consumedAfterCompletion = microphone.withUnsafeMutableBufferPointer { microphoneBuffer in
            left.withUnsafeMutableBufferPointer { leftBuffer in
                right.withUnsafeMutableBufferPointer { rightBuffer in
                    session.process(
                        microphone: UnsafePointer(microphoneBuffer.baseAddress!),
                        outputLeft: leftBuffer.baseAddress!,
                        outputRight: rightBuffer.baseAddress!,
                        frameCount: 4
                    )
                }
            }
        }
        XCTAssertEqual(consumedAfterCompletion, 0)
        XCTAssertEqual(left, [0, 0, 0, 0])
        XCTAssertEqual(right, [0, 0, 0, 0])
    }
}
