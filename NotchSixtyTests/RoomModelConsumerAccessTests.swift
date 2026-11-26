import XCTest
@testable import NotchSixty

/// E29 S7 part 2 (G5, G18): production capture into `RoomModelStore`, and designers reading through the model. A
/// design through the model is bit-identical to one from the direct inputs at all eight rates; estimated seats and
/// stale paths are refused with the shared message; the seat map keeps captured paths when it saves.
@MainActor
final class RoomModelConsumerAccessTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private struct Catalog: OutputDeviceCataloging { func outputDevices() throws -> [AudioOutputDevice] { [] } }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func fixture() -> (profiles: ProductProfileController, controller: RoomCorrectionProjectController, store: RoomCorrectionProjectStore) {
        let profiles = ProductProfileController(
            engine: AudioIOEngine(deviceCatalog: Catalog()), storageURL: root.appendingPathComponent("profiles-v1.json"))
        let store = RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("Room Correction", isDirectory: true))
        return (profiles, RoomCorrectionProjectController(profiles: profiles, store: store), store)
    }

    private func sweep(_ rate: Double) -> RoomCorrectionSweepSettings {
        RoomCorrectionSweepSettings(
            sampleRate: rate, startFrequencyHz: 20, endFrequencyHz: min(20_000, rate * 0.45), durationSeconds: 5,
            levelDBFS: -18, leadInSeconds: 0.5, tailSeconds: 1, fadeSeconds: 0.02)
    }

    private var mic: RoomCorrectionMicrophone {
        RoomCorrectionMicrophone(
            stableID: "mic-1", displayName: "Measurement Mic", manufacturer: nil, inputChannelIndex: 0, calibration: nil)
    }

    private func analysis(_ t: TimeInterval, rate: Double, left: Double, right: Double) -> RoomCorrectionMeasurementAnalysis {
        var q = RoomCorrectionMeasurementQuality()
        q.sweepComplete = true
        q.estimatedSNRDB = 45
        q.playbackPeakDBFS = -18
        q.capturePeakDBFS = -12
        q.estimatedNoiseFloorDBFS = -70
        q.directArrivalSeconds = 0.01
        q.usableLowHz = 100
        q.usableHighHz = 1_000
        func ch(_ db: Double) -> RoomCorrectionChannelMeasurement {
            let f = [100.0, 1_000]
            return RoomCorrectionChannelMeasurement(
                capturedAt: Date(timeIntervalSince1970: t), rawCapture: [Float(t), 0.25], impulseResponse: [1, 0, 0.5],
                transferFunction: RoomCorrectionFrequencyResponse(
                    frequenciesHz: f, magnitudeDB: [db, db], phaseRadians: [-0.1, -0.2]),
                quality: q)
        }
        return RoomCorrectionMeasurementAnalysis(sampleRate: rate, left: ch(left), right: ch(right))
    }

    private let parameters = RoomCorrectionDesignParameters(
        correctionLowHz: 80, correctionHighHz: 2_000, smoothingOctaves: 1.0 / 6.0, maximumBoostDB: 4,
        maximumCutDB: 6, requestedTapCount: 1_024)

    private func gate(derived: Set<UUID> = [], context: RoomModelContext? = nil)
        -> (RoomModelConsumer, [RoomCorrectionMeasurementPosition]) throws -> [RoomCorrectionMeasurementPosition] {
        { consumer, positions in
            let model = RoomModelAdapter.build(RoomModelAdapterInput(positions: positions))
            return try RoomModelConsumerAccess.positions(
                positions, model: model, context: context, consumer: consumer, derivedPointIDs: derived)
        }
    }

    // MARK: Bit-identical through the model (G18)

    func testRoomCorrectionDesignThroughTheModelIsBitIdenticalAtEveryRate() throws {
        for rate in Self.rates {
            let f = fixture()
            try f.controller.retainMeasurement(
                analysis(1, rate: rate, left: -2, right: 2), sweep: sweep(rate), microphone: mic)
            try f.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
            let direct = try f.controller.generateDesign(parameters: parameters, name: "D", createdAt: Date(timeIntervalSince1970: 9))
            f.controller.roomModelGate = gate()
            let viaModel = try f.controller.generateDesign(parameters: parameters, name: "D", createdAt: Date(timeIntervalSince1970: 9))
            XCTAssertEqual(direct.filter.leftTaps, viaModel.filter.leftTaps, "\(rate)")
            XCTAssertEqual(direct.filter.rightTaps, viaModel.filter.rightTaps, "\(rate)")
            XCTAssertEqual(direct.sourcePositions, viaModel.sourcePositions, "\(rate)")
        }
    }

    func testPositionsComeBackUnchanged() throws {
        let f = fixture()
        try f.controller.retainMeasurement(analysis(1, rate: 48_000, left: 0, right: 0), sweep: sweep(48_000), microphone: mic)
        let p = f.controller.positions
        let out = try gate()(.roomCorrectionDesign, p)
        XCTAssertEqual(out, p)
    }

    // MARK: Refusals (G18)

    func testAnEstimatedSeatIsRefusedByEveryDesigner() throws {
        let f = fixture()
        try f.controller.retainMeasurement(analysis(1, rate: 48_000, left: 0, right: 0), sweep: sweep(48_000), microphone: mic)
        try f.controller.setTarget(RoomCorrectionBuiltInTarget.flat.curve)
        let id = try XCTUnwrap(f.controller.positions.first?.id)
        f.controller.roomModelGate = gate(derived: [id])
        XCTAssertThrowsError(try f.controller.generateDesign(parameters: parameters)) {
            XCTAssertEqual($0 as? RoomModelAccessError, .derivedPathRefused(consumer: .roomCorrectionDesign, pointID: id))
        }
        XCTAssertTrue(f.controller.designs.isEmpty)
        let model = RoomModel()
        for consumer in RoomModelConsumer.allCases {
            XCTAssertThrowsError(try RoomModelConsumerAccess.seats([id], model: model, context: nil, consumer: consumer, derivedPointIDs: [id])) {
                XCTAssertEqual($0 as? RoomModelAccessError, .derivedPathRefused(consumer: consumer, pointID: id))
            }
        }
    }

    func testAStalePathIsRefusedWithTheSharedMessage() throws {
        let f = fixture()
        var stamped = RoomCorrectionMeasurementPosition(
            name: "Seat", sampleRate: 48_000,
            left: analysis(1, rate: 48_000, left: 0, right: 0).left, right: analysis(1, rate: 48_000, left: 0, right: 0).right,
            captureStamp: RoomCaptureStamp(timingTier: nil, sessionID: nil, outputDeviceUID: "dac-a", arrangementRevision: "r1"))
        stamped.outputGainDBAtMeasurement = -6
        let model = RoomModelAdapter.build(RoomModelAdapterInput(positions: [stamped]))
        _ = f
        let changed = RoomModelContext(arrangementRevision: "r2", outputDeviceUID: "dac-a")
        XCTAssertThrowsError(try RoomModelConsumerAccess.positions(
            [stamped], model: model, context: changed, consumer: .quietZoneDesign)) {
            XCTAssertEqual($0 as? RoomModelAccessError, .stale(consumer: .quietZoneDesign, reasons: [.arrangement]))
            XCTAssertEqual(String(describing: $0), RoomModelRule.staleMessage)
        }
        let same = RoomModelContext(arrangementRevision: "r1", outputDeviceUID: "dac-a")
        XCTAssertNoThrow(try RoomModelConsumerAccess.positions([stamped], model: model, context: same, consumer: .quietZoneDesign))
    }

    func testAncRecordsPassUnchangedAndStaleOnesAreRefused() throws {
        let rec = CombinedAncPathRecord(
            source: .feedLeft, destination: .seatMicrophone, windowSeconds: 1, sampleRate: 48_000,
            fingerprint: AncBassPathFingerprint(value: "a"), impulseResponse: [1, 0.5])
        let model = RoomModelAdapter.build(RoomModelAdapterInput(combinedAncRecords: [rec]))
        XCTAssertEqual(try RoomModelConsumerAccess.ancRecords([rec], model: model, context: nil, consumer: .subPathDesign), [rec])
        let active = RoomModelContext(bassFingerprint: AncBassPathFingerprint(value: "b"), bassPathActive: true)
        XCTAssertThrowsError(try RoomModelConsumerAccess.ancRecords([rec], model: model, context: active, consumer: .subPathDesign)) {
            XCTAssertEqual($0 as? RoomModelAccessError, .stale(consumer: .subPathDesign, reasons: [.bassPath]))
        }
    }

    // MARK: Production capture (G5)

    func testRetainingAPositionCapturesItsPathsAndImpulseResponses() throws {
        for rate in Self.rates {
            let f = fixture()
            let context = RoomModelContext(arrangementRevision: "r1", outputDeviceUID: "dac-a")
            f.controller.captureStamp = { RoomCaptureStamp(timingTier: nil, sessionID: nil, outputDeviceUID: "dac-a", arrangementRevision: "r1") }
            f.controller.roomModelRecorder = { [weak f = f.controller] position, projectID, _ in
                guard let f else { return }
                _ = try RoomModelCapture.record(position, projectID: projectID, store: f.store, context: context)
            }
            let id = try f.controller.retainMeasurement(
                analysis(1, rate: rate, left: 0, right: 0), sweep: sweep(rate), microphone: mic)
            let projectID = try XCTUnwrap(f.controller.project?.id)
            let doc = try RoomModelStore.load(from: RoomModelCapture.directory(store: f.store, projectID: projectID))
            XCTAssertEqual(doc.modelID, RoomModelCapture.modelID(for: projectID))
            XCTAssertEqual(doc.model.paths.count, 2, "\(rate)")
            for path in doc.model.paths {
                XCTAssertEqual(path.receiver, id)
                XCTAssertEqual(path.sampleRate, rate)
                XCTAssertEqual(path.stamps.outputDeviceUID, "dac-a")
                XCTAssertEqual(path.stamps.arrangementRevision, "r1")
                XCTAssertEqual(doc.impulseResponses[path.id], [1, 0, 0.5])
            }
            XCTAssertNil(f.controller.lastErrorDescription)
            f.profiles.setSelectedRoomModelID(doc.modelID)
            XCTAssertEqual(f.profiles.selectedSystemProfile?.roomModelID, doc.modelID)
        }
    }

    func testAnUnstampableCaptureStillRetainsAndReportsTheModelFailure() throws {
        let f = fixture()
        f.controller.roomModelRecorder = { position, projectID, _ in
            _ = try RoomModelCapture.record(position, projectID: projectID, store: f.store, context: RoomModelContext())
        }
        try f.controller.retainMeasurement(analysis(1, rate: 48_000, left: 0, right: 0), sweep: sweep(48_000), microphone: mic)
        XCTAssertEqual(f.controller.positions.count, 1)
        XCTAssertNotNil(f.controller.lastErrorDescription)
    }

    func testTheSeatMapKeepsCapturedPathsWhenItSavesAndDoesNotCallMeasuredSeatsEstimates() throws {
        let f = fixture()
        f.controller.captureStamp = { RoomCaptureStamp(timingTier: nil, sessionID: nil, outputDeviceUID: "dac-a", arrangementRevision: "r1") }
        f.controller.roomModelRecorder = { position, projectID, _ in
            _ = try RoomModelCapture.record(
                position, projectID: projectID, store: f.store,
                context: RoomModelContext(arrangementRevision: "r1", outputDeviceUID: "dac-a"))
        }
        let id = try f.controller.retainMeasurement(
            analysis(1, rate: 96_000, left: 0, right: 0), sweep: sweep(96_000), microphone: mic)
        let project = try XCTUnwrap(f.controller.project)
        let map = RoomSeatMapController(
            projectStore: f.store, defaults: try XCTUnwrap(UserDefaults(suiteName: "access-\(UUID().uuidString)")))
        map.load(project: project, geometry: nil)
        map.setPosition(id, x: 1, y: 2, z: 1.1)
        XCTAssertTrue(map.unmeasuredSeatIDs.isEmpty)
        let doc = try RoomModelStore.load(from: RoomModelCapture.directory(store: f.store, projectID: project.id))
        XCTAssertEqual(doc.model.paths.count, 2)
        XCTAssertEqual(doc.model.point(id)?.position?.x, 1)
        XCTAssertEqual(doc.impulseResponses.count, 2)
        // A seat nobody measured is the only estimate the store knows about.
        let extra = try XCTUnwrap(map.addUnmeasuredSeat(name: "Armchair", x: 2, y: 2))
        let derived = RoomModelCapture.derivedSeatIDs(store: f.store, projectID: project.id, measuredIDs: [id])
        XCTAssertEqual(derived, [extra])
    }
}
