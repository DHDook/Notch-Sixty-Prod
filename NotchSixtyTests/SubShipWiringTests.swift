import XCTest
@testable import NotchSixty

/// E26 S7: end-to-end tests through production wiring with fakes at the hardware edge only. G5: `measureSubPath`
/// (and the chained leakage sweep) with fake transport and analysis factories. G12: the multi-seat controller branch
/// (fresh plant, stale plant, per-tone mode) on the real `ActiveQuietZoneController`.
@MainActor
final class SubShipWiringTests: XCTestCase {
    private struct OutputCatalog: OutputDeviceCataloging {
        let devices: [AudioOutputDevice]
        func outputDevices() throws -> [AudioOutputDevice] { devices }
    }

    private struct InputCatalog: InputDeviceCataloging {
        let devices: [AudioInputDevice]
        func inputDevices() throws -> [AudioInputDevice] { devices }
    }

    private struct Permission: MicrophonePermissionRequesting, Sendable {
        func currentStatus() -> MicrophonePermissionStatus { .authorized }
        func requestAccess() async -> MicrophonePermissionStatus { .authorized }
    }

    private final class FakeTransport: RoomCorrectionCalibrationTransporting {
        var started = 0, cancelled = 0
        func start() throws { started += 1 }
        func snapshot() -> N60RoomMeasurementBridgeSnapshot? {
            var s = N60RoomMeasurementBridgeSnapshot()
            s.frameCursor = 100
            s.totalFrameCount = 100
            s.complete = true
            return s
        }
        func finishAndMaterialize() throws -> RoomCorrectionCalibrationCapture { .init(left: [0], right: [0]) }
        func cancel() { cancelled += 1 }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func arrangement() -> SystemArrangement {
        SystemSetupArrangementPlanner.arrangement(
            deviceUID: "dac", detectedChannelCount: 8, channelsInUse: 2,
            choices: .init(layout: .fiveOne, bass: .downstreamReceiver, subwooferCount: 1, receiverBass: .openPreout))
    }

    private struct Rig {
        var survey: QuietZoneFeedForwardSurveyController
        var quietZone: ActiveQuietZoneController
        var project: RoomCorrectionProject
        var transports: [FakeTransport]
    }

    private final class Box { var transports: [FakeTransport] = [] }

    private func twin(rate: Double) -> RoomCorrectionMeasurementAnalysis {
        var ir = [Float](repeating: 0, count: Int(rate * 0.5))
        ir[Int(rate * 0.004)] = 0.3
        let quality = RoomCorrectionMeasurementQuality(clipped: false, estimatedSNRDB: 45, sweepComplete: true)
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: Date(), rawCapture: [0], impulseResponse: ir, transferFunction: nil, quality: quality)
        return RoomCorrectionMeasurementAnalysis(sampleRate: rate, left: channel, right: channel)
    }

    private func makeRig(rate: Double, box: Box, analyses: Counter) throws -> (QuietZoneFeedForwardSurveyController, ActiveQuietZoneController, RoomCorrectionProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let output = AudioOutputDevice(
            deviceID: 11, uid: "out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: rate, maximum: rate)])
        let input = AudioInputDevice(
            deviceID: 22, uid: "mic", name: "Mic", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: rate, maximum: rate)])
        let engine = AudioIOEngine(deviceCatalog: OutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: output.uid)
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        try profiles.replaceSelectedSystemArrangement(arrangement())
        let calibration = RoomCorrectionCalibrationController(
            engine: engine, inputCatalog: InputCatalog(devices: [input]), permissionClient: Permission())
        calibration.prepareForUse()
        calibration.selectInput(uid: "mic")
        let projects = RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("rc", isDirectory: true)))
        try projects.startNewProject()
        var project = try XCTUnwrap(projects.project)
        project.microphone = RoomCorrectionMicrophone(stableID: "mic", displayName: "Mic")
        try projects.adoptProject(project)
        let ambient = AmbientCompensationController(
            engine: engine, profiles: profiles, microphone: calibration, projects: projects)
        let quietZone = ActiveQuietZoneController(engine: engine, profiles: profiles, ambient: ambient)
        quietZone.subAwareAncEnabled = true
        let suite = UserDefaults(suiteName: "SubShipWiringTests-\(UUID().uuidString)")!
        let analysis = twin(rate: rate)
        let survey = QuietZoneFeedForwardSurveyController(
            quietZone: quietZone, calibration: calibration, defaults: suite,
            transportFactory: { _, _, _, _ in
                let t = FakeTransport()
                box.transports.append(t)
                return t
            },
            analysisOperation: { _, _, _ in
                analyses.bump()
                return analysis
            })
        return (survey, quietZone, project)
    }

    private func waitIdle(_ c: QuietZoneFeedForwardSurveyController) async throws {
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 150_000_000)
            if c.activity == .idle { return }
        }
        XCTFail("measurement did not finish: \(c.message)")
    }

    func testMeasureSubPathThroughProductionWiringAtEveryRate() async throws {
        for rate in rates {
            let box = Box(), analyses = Counter()
            let (survey, quietZone, _) = try makeRig(rate: rate, box: box, analyses: analyses)
            survey.measureSubPath()
            XCTAssertEqual(survey.activity, .measuringLeakage(progress: 0), "\(rate): \(survey.message)")
            try await waitIdle(survey)
            XCTAssertEqual(box.transports.count, 1, "\(rate)")
            XCTAssertEqual(box.transports[0].started, 1, "\(rate)")
            XCTAssertEqual(analyses.count, 1, "\(rate)")
            let report = try XCTUnwrap(quietZone.subSweepReport, "\(rate): \(survey.message)")
            XCTAssertEqual(report.fingerprint, quietZone.ancBassPathState.fingerprint, "\(rate)")
            XCTAssertEqual(report.sampleRate, rate, "\(rate)")
            XCTAssertFalse(survey.message.isEmpty)
        }
    }

    func testChainedLeakageSweepStampsTheBassFingerprint() async throws {
        let rate = 48_000.0
        let box = Box(), analyses = Counter()
        let (survey, quietZone, project) = try makeRig(rate: rate, box: box, analyses: analyses)
        // The leakage sweep belongs to a noise survey made with the same channels.
        survey.setReferenceChannel(1)
        let store = QuietZoneFeedForwardDesignSurveyStore(roomStore: quietZone.ambient.projects.store)
        let noise = QuietZoneFeedForwardDesignSurvey(
            projectID: project.id, microphoneStableID: "mic", errorChannel: 0, referenceChannel: 1,
            sampleRate: rate, capturedAt: Date(), segments: 10, bands: [])
        try store.save(noise, project: project)
        survey.refresh()
        XCTAssertNotNil(survey.survey)

        survey.measureSubPath(thenLeakage: true)
        try await waitIdle(survey)
        // Give the chained measurement a moment to start, then wait for it.
        try await Task.sleep(nanoseconds: 300_000_000)
        try await waitIdle(survey)
        XCTAssertNotNil(quietZone.subSweepReport)
        XCTAssertEqual(box.transports.count, 1 + QuietZoneFeedForwardSurveyController.leakageRepeats)
        XCTAssertEqual(analyses.count, 1 + QuietZoneFeedForwardSurveyController.leakageRepeats)
        let updated = try XCTUnwrap(survey.survey, survey.message)
        XCTAssertEqual(updated.echoBassFingerprint, quietZone.ancBassPathState.fingerprint)
        XCTAssertNotNil(updated.echoModel)
    }

    func testMeasureSubPathRefusesWithoutASubOrWithPlaybackRunning() throws {
        let box = Box(), analyses = Counter()
        let (survey, quietZone, _) = try makeRig(rate: 48_000, box: box, analyses: analyses)
        quietZone.subAwareAncEnabled = false
        survey.measureSubPath()
        XCTAssertEqual(survey.activity, .idle)
        XCTAssertEqual(box.transports.count, 0)
        XCTAssertEqual(survey.message, QuietZoneFeedForwardSurveyError.subPathNotNeeded.localizedDescription)
    }

    // MARK: G12: the multi-seat controller branch

    private func z(_ r: Double) -> ActiveQuietZoneComplex { ActiveQuietZoneComplex(real: r, imaginary: 0) }

    private func plantBand(hz: Double, left: Double, right: Double) -> QuietZoneVirtualSeatBand {
        QuietZoneVirtualSeatBand(
            frequencyHz: hz, sourceToReference: z(1), sourceToListener: z(0.02), leftSecondaryAtListener: z(left),
            rightSecondaryAtListener: z(right), leftLeakageAtReference: z(0.2), rightLeakageAtReference: z(0.2),
            measuredCoherence: 0.98)
    }

    private func seats(rate: Double, shared: Bool) -> (RoomCorrectionProject, ActiveQuietZoneSpatialCalibration) {
        let projectID = UUID(), systemID = UUID(), a = UUID(), b = UUID()
        var project = RoomCorrectionProject(id: projectID, playbackSystemID: systemID, name: "Seats")
        project.microphone = RoomCorrectionMicrophone(stableID: "mic", displayName: "Mic")
        let delay = Int((0.004 * rate).rounded())
        func ir(_ at: Int, _ gain: Float) -> [Float] {
            var v = [Float](repeating: 0, count: delay + 8)
            v[at] = gain
            return v
        }
        func channel(_ v: [Float]) -> RoomCorrectionChannelMeasurement {
            RoomCorrectionChannelMeasurement(
                capturedAt: Date(), rawCapture: [0], impulseResponse: v, transferFunction: nil,
                quality: RoomCorrectionMeasurementQuality(clipped: false, estimatedSNRDB: 45, sweepComplete: true))
        }
        func seat(_ id: UUID, _ l: Float, _ r: Float, _ rd: Int) -> RoomCorrectionMeasurementPosition {
            RoomCorrectionMeasurementPosition(
                id: id, name: "S", included: true, weight: 1, sampleRate: rate,
                left: channel(ir(delay, l)), right: channel(ir(rd, r)))
        }
        project.measurements = shared
            ? [seat(a, 1, 1, delay), seat(b, 0.7, 0.7, delay)]
            : [seat(a, 1, 0.1, delay + 3), seat(b, 0.1, 1, delay + 3)]
        func dist(_ id: UUID) -> ActiveQuietZoneSpatialDisturbance {
            ActiveQuietZoneSpatialDisturbance(
                positionID: id, ratioToAnchor: z(1), coherence: 0.99, phaseClosureRadians: 0.01, frequencyDriftHz: 0.01)
        }
        let calibration = ActiveQuietZoneSpatialCalibration(
            projectID: projectID, playbackSystemID: systemID, anchorPositionID: a, microphoneStableID: "mic",
            microphoneInputChannelIndex: 0, sampleRate: rate,
            positions: [ActiveQuietZoneSpatialPosition(id: a, weight: 1), ActiveQuietZoneSpatialPosition(id: b, weight: 1)],
            surveys: [ActiveQuietZoneSpatialToneSurvey(
                frequencyHz: 80, capturedAt: Date(), commonPhaseReferenceValidated: true, disturbances: [dist(a), dist(b)])])
        return (project, calibration)
    }

    func testSpatialBassModeFreshStalePerToneAtEveryRate() async throws {
        for rate in rates {
            let (_, quietZone, _) = try makeRig(rate: rate, box: Box(), analyses: Counter())
            quietZone.attachExcursionCap { ExcursionLimits(mainLowerLimitHz: 45, subCrossoverHz: 80) }
            let fresh = quietZone.ancBassPathState.fingerprint

            // Flag off: nothing changes, whatever the plant.
            quietZone.subAwareAncEnabled = false
            let free = seats(rate: rate, shared: false)
            XCTAssertEqual(try quietZone.spatialBassMode(calibration: free.1, project: free.0, frequencyHz: 80), .free)
            quietZone.subAwareAncEnabled = true

            // No plant measured: refused, never the free solve.
            XCTAssertThrowsError(try quietZone.spatialBassMode(calibration: free.1, project: free.0, frequencyHz: 80), "\(rate)") {
                XCTAssertEqual($0 as? ActiveQuietZoneControllerError,
                               .subAwareRefused(SubAwareAncReadiness.plantMissingMessage))
            }
            // A plant stamped for another setup is stale: refused.
            quietZone.setBassPlant(BassPlantMap(bands: [plantBand(hz: 80, left: 1, right: 0.1)]), fingerprint: nil)
            XCTAssertThrowsError(try quietZone.spatialBassMode(calibration: free.1, project: free.0, frequencyHz: 80), "stale \(rate)")

            // Fresh plant, separable seats: the seat plant is free, so the single-seat plant's own mode decides.
            quietZone.setBassPlant(BassPlantMap(bands: [plantBand(hz: 80, left: 1, right: 0.1)]), fingerprint: fresh)
            let single = quietZone.bassPlantMap.mode(atHz: 80)
            XCTAssertNotEqual(single, .commonMode, "\(rate)")
            XCTAssertEqual(try quietZone.spatialBassMode(calibration: free.1, project: free.0, frequencyHz: 80), single, "\(rate)")

            // Seats that see one shared path: common mode even though the single-seat plant is free.
            let shared = seats(rate: rate, shared: true)
            XCTAssertEqual(try quietZone.spatialBassMode(calibration: shared.1, project: shared.0, frequencyHz: 80),
                           .commonMode, "seat plant is stricter, \(rate)")

            // A rank-one single-seat plant tightens separable seats (stricter of the two never loosens).
            quietZone.setBassPlant(BassPlantMap(bands: [plantBand(hz: 80, left: 1, right: 1)]), fingerprint: fresh)
            XCTAssertEqual(try quietZone.spatialBassMode(calibration: free.1, project: free.0, frequencyHz: 80),
                           .commonMode, "plant is stricter, \(rate)")

            // Per tone: the plant is looked up at each tone's own frequency.
            quietZone.setBassPlant(BassPlantMap(bands: [
                plantBand(hz: 40, left: 1, right: 1), plantBand(hz: 80, left: 1, right: 0.1),
            ]), fingerprint: fresh)
            let at40 = try quietZone.spatialBassMode(calibration: free.1, project: free.0, frequencyHz: 40)
            let at80 = try quietZone.spatialBassMode(calibration: free.1, project: free.0, frequencyHz: 80)
            XCTAssertEqual(at80, quietZone.bassPlantMap.mode(atHz: 80), "\(rate)")
            XCTAssertEqual(at40, .commonMode, "\(rate)")
            XCTAssertNotEqual(at40, at80, "per-tone mode differs, \(rate)")
        }
    }
}
