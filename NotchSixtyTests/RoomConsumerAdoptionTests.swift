import XCTest
@testable import NotchSixty

/// E29 S7 (`e29.room-model`): consumers read the room model. Conversation Focus takes the chosen seat's music through
/// `SeatMusicFeed`; the seat map's staleness context carries output device, arrangement and gain; capture stamps flow
/// into the adapter (timing, session); room-correction positions can be located; a located linked seat keeps its
/// source and uncertainty; ANC path records and the head survey show on the map.
@MainActor
final class RoomConsumerAdoptionTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let centres = SpeechIntelligibilityBands.centersHz
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "adopt-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func spectrum(_ db: Double) -> [AmbientSpectrumBand] {
        (0..<64).map { i in
            let lo = 20 * pow(1000.0, Double(i) / 64)
            let hi = 20 * pow(1000.0, Double(i + 1) / 64)
            return AmbientSpectrumBand(
                lowerFrequencyHz: lo, centerFrequencyHz: (lo * hi).squareRoot(), upperFrequencyHz: hi, levelDBFS: db)
        }
    }

    private func delta(_ gain: Float, at index: Int = 64, frames: Int = 4096) -> [Float] {
        var h = [Float](repeating: 0, count: frames)
        h[index] = gain
        return h
    }

    private func channel(_ ir: [Float]) -> RoomCorrectionChannelMeasurement {
        var q = RoomCorrectionMeasurementQuality()
        q.sweepComplete = true
        return RoomCorrectionChannelMeasurement(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), rawCapture: [], impulseResponse: ir,
            transferFunction: nil, quality: q)
    }

    private func position(_ name: String, gain: Float, rate: Double = 48_000,
                          stamp: RoomCaptureStamp? = nil) -> RoomCorrectionMeasurementPosition {
        RoomCorrectionMeasurementPosition(
            name: name, sampleRate: rate, left: channel(delta(gain)), right: channel(delta(gain)), captureStamp: stamp)
    }

    private func map(_ project: RoomCorrectionProject, feed: SeatMusicFeed?, live: RoomModelLiveInputs? = nil,
                     geometry: RoomGeometryModel? = nil) -> RoomSeatMapController {
        let m = RoomSeatMapController(
            projectStore: RoomCorrectionProjectStore(rootDirectory: root), seatMusicFeed: feed, defaults: defaults)
        m.load(project: project, geometry: geometry, live: live)
        return m
    }

    // MARK: Conversation Focus (G16, G15)

    func testChosenSeatReachesTheFeedAndPredictsRelativeToTheMainSeat() throws {
        for rate in Self.rates {
            var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
            project.measurements = [position("Main", gain: 0.5, rate: rate), position("Side", gain: 0.25, rate: rate)]
            let feed = SeatMusicFeed()
            let m = map(project, feed: feed)
            let side = try XCTUnwrap(m.points.first { $0.name == "Side" })
            XCTAssertNil(feed.source, "nothing chosen: today's prediction")
            XCTAssertNil(feed.prediction(modeledPlayback: spectrum(-30)))
            m.setFocusSeat(side.id)
            XCTAssertEqual(feed.source?.seatName, "Side")
            let prediction = try XCTUnwrap(feed.prediction(modeledPlayback: spectrum(-30)), "rate \(rate)")
            // The side seat is half the amplitude of the main seat: 6 dB under the microphone's own level.
            let micBands = try XCTUnwrap(ThirdOctaveBandAggregator.aggregate(spectrum(-30))).bandLevelsDB
            for (level, mic) in zip(prediction.bandLevelsDB, micBands) {
                XCTAssertEqual(level, mic - 6.02, accuracy: 0.2, "rate \(rate)")
            }
            XCTAssertNil(feed.lastFallback)
        }
    }

    func testTheChosenSeatIsRememberedPerProject() throws {
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
        project.measurements = [position("Main", gain: 0.5), position("Side", gain: 0.25)]
        let first = map(project, feed: SeatMusicFeed())
        let side = try XCTUnwrap(first.points.first { $0.name == "Side" })
        first.setFocusSeat(side.id)
        let again = map(project, feed: SeatMusicFeed())
        XCTAssertEqual(again.focusSeatID, side.id)
        again.setFocusSeat(nil)
        XCTAssertNil(map(project, feed: SeatMusicFeed()).focusSeatID)
    }

    func testStaleReferenceFallsBackToTheMicrophone() throws {
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
        let old = RoomCaptureStamp(timingTier: nil, sessionID: nil, outputDeviceUID: "dac-A", arrangementRevision: "r1")
        project.measurements = [position("Main", gain: 0.5, stamp: old), position("Side", gain: 0.25, stamp: old)]
        let feed = SeatMusicFeed()
        var live = RoomModelLiveInputs(outputDeviceUID: "dac-A", arrangementRevision: "r1")
        var m = map(project, feed: feed, live: live)
        m.setFocusSeat(try XCTUnwrap(m.points.first { $0.name == "Side" }).id)
        XCTAssertNotNil(feed.prediction(modeledPlayback: spectrum(-30)))
        // The output device changed (G10): the paths are stale and Conversation Focus keeps its own estimate.
        live.outputDeviceUID = "dac-B"
        m = map(project, feed: feed, live: live)
        XCTAssertEqual(m.focusMessage, RoomModelRule.staleMessage)
        XCTAssertNil(feed.prediction(modeledPlayback: spectrum(-30)))
        XCTAssertEqual(feed.lastFallback, .stalePath)
        // The arrangement changed.
        live.outputDeviceUID = "dac-A"
        live.arrangementRevision = "r2"
        m = map(project, feed: feed, live: live)
        XCTAssertNil(feed.prediction(modeledPlayback: spectrum(-30)))
    }

    func testAVolumeChangeDoesNotMakeTheMusicEstimateStale() throws {
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
        var a = position("Main", gain: 0.5)
        var b = position("Side", gain: 0.25)
        a.outputGainDBAtMeasurement = -20
        b.outputGainDBAtMeasurement = -20
        project.measurements = [a, b]
        let feed = SeatMusicFeed()
        let m = map(project, feed: feed, live: RoomModelLiveInputs(outputGainDB: -10))
        m.setFocusSeat(try XCTUnwrap(m.points.first { $0.name == "Side" }).id)
        XCTAssertNotNil(feed.prediction(modeledPlayback: spectrum(-30)), "programme levels are live")
    }

    func testAnEstimatedSeatIsUsedWithItsConfidence() throws {
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
        project.measurements = ["A", "B", "C", "D"].map { position($0, gain: 0.5) }
        let feed = SeatMusicFeed()
        let m = map(project, feed: feed)
        let at = [(1.0, 2.0), (1.5, 2.0), (1.0, 2.5), (1.5, 2.5)]
        for (s, xy) in zip(m.points.filter { $0.kind == .seat }, at) { m.setPosition(s.id, x: xy.0, y: xy.1, z: 1.1) }
        for f in m.points.filter({ $0.kind == .speakerFeed }) {
            m.setPosition(f.id, x: f.id == RoomModelAdapter.leftFeedID ? 0.5 : 2, y: 0, z: 0.9)
        }
        let id = try XCTUnwrap(m.addUnmeasuredSeat(name: "Armchair", x: 1.2, y: 2.2))
        m.setFocusSeat(id)
        let prediction = try XCTUnwrap(feed.prediction(modeledPlayback: spectrum(-30)))
        XCTAssertTrue(prediction.derived)
        XCTAssertGreaterThan(prediction.meanConfidence, 0.8)
        let micBands = try XCTUnwrap(ThirdOctaveBandAggregator.aggregate(spectrum(-30))).bandLevelsDB
        for (level, mic) in zip(prediction.bandLevelsDB, micBands) { XCTAssertEqual(level, mic, accuracy: 0.6) }
    }

    func testFeedIsEmptyWhenTheMainSeatHasNoMeasurement() throws {
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
        project.measurements = []
        let feed = SeatMusicFeed()
        let m = map(project, feed: feed, geometry: RoomGeometryModel.template(projectID: project.id))
        m.setFocusSeat(try XCTUnwrap(m.points.first { $0.kind == .seat }).id)
        XCTAssertNil(feed.source)
        XCTAssertNotNil(m.focusMessage)
    }

    // MARK: Adapter (G1, G3, G10, G11)

    func testCaptureStampsFlowIntoPaths() throws {
        let stamp = RoomCaptureStamp(
            timingTier: "loopback", sessionID: "s1", outputDeviceUID: "dac-A", arrangementRevision: "r1")
        let built = RoomModelAdapter.build(RoomModelAdapterInput(positions: [position("Main", gain: 0.5, stamp: stamp)]))
        XCTAssertEqual(built.paths.count, 2)
        for path in built.paths {
            XCTAssertEqual(path.timingTier, .loopback)
            XCTAssertEqual(path.sessionID, "s1")
            XCTAssertEqual(path.stamps.outputDeviceUID, "dac-A")
            XCTAssertEqual(path.stamps.arrangementRevision, "r1")
        }
        XCTAssertTrue(built.paths[0].phaseComparable(with: built.paths[1]), "same session, rate and timing")
        let plain = RoomModelAdapter.build(RoomModelAdapterInput(positions: [position("Main", gain: 0.5)]))
        XCTAssertTrue(plain.paths.allSatisfy { $0.timingTier == .none && $0.sessionID == nil })
    }

    func testHeadSurveyIsPointOnlyAndAncRecordsAppearOnTheMap() throws {
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
        project.measurements = [position("Main", gain: 0.5)]
        let live = RoomModelLiveInputs(headSurvey: [RoomSurveyCoordinate(x: 2, y: 3, z: 1.1)])
        let m = map(project, feed: nil, live: live)
        let survey = try XCTUnwrap(m.points.first { $0.kind == .surveyPoint })
        XCTAssertEqual(survey.position?.x, 2)
        XCTAssertTrue(m.pathRows.allSatisfy { $0.sourceName != survey.name && $0.receiverName != survey.name })
    }

    // MARK: Locate from room-correction positions (G12) and linked seats (G13)

    private let left = RoomPosition(x: 1.5, y: 0.3, z: 0.9, source: .typed, uncertaintyMetres: nil)
    private let right = RoomPosition(x: 3.5, y: 0.3, z: 0.9, source: .typed, uncertaintyMetres: nil)
    private let seat = (x: 2.3, y: 2.6, z: 1.1)

    private func directIR(from speaker: RoomPosition, rate: Double) -> [Float] {
        let dx = speaker.x - seat.x, dy = speaker.y - seat.y, dz = speaker.z - seat.z
        let r = (dx * dx + dy * dy + dz * dz).squareRoot()
        let pos = r / 343.0 * rate
        var h = [Float](repeating: 0, count: Int(rate * 0.05))
        let c0 = Int(pos.rounded(.down))
        for t in (c0 - 15)...(c0 + 16) where t >= 0 && t < h.count {
            let x = Double(t) - pos
            let s = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            h[t] = Float(s * 0.5 * (1 + cos(Double.pi * x / 16)) / r)
        }
        return h
    }

    private func locatable(tier: String?) throws -> (RoomSeatMapController, UUID, RoomCorrectionProject) {
        let rate = 96_000.0
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
        project.measurements = [RoomCorrectionMeasurementPosition(
            name: "Main", sampleRate: rate, left: channel(directIR(from: left, rate: rate)),
            right: channel(directIR(from: right, rate: rate)),
            captureStamp: RoomCaptureStamp(timingTier: tier, sessionID: "s1"))]
        var geometry = RoomGeometryModel.template(projectID: project.id)
        geometry.leftSpeaker = RoomGeometryPoint3D(x: left.x, y: left.y, z: left.z)
        geometry.rightSpeaker = RoomGeometryPoint3D(x: right.x, y: right.y, z: right.z)
        let m = map(project, feed: nil, geometry: geometry)
        return (m, try XCTUnwrap(m.points.first { $0.name == "Main" }).id, project)
    }

    func testARoomCorrectionPositionWithLoopbackTimingCanBeLocated() throws {
        let (m, main, _) = try locatable(tier: "loopback")
        XCTAssertNil(m.locateUnavailableReason(for: main))
        m.locate(main)
        let located = try XCTUnwrap(m.points.first { $0.id == main }?.position)
        XCTAssertEqual(located.x, seat.x, accuracy: 0.02)
        XCTAssertEqual(located.y, seat.y, accuracy: 0.02)
    }

    func testARoomCorrectionPositionWithoutTimingIsStillRefused() throws {
        let (m, main, _) = try locatable(tier: nil)
        XCTAssertEqual(m.locateUnavailableReason(for: main), RoomLocateRefusal.noLoopbackTiming.message)
    }

    func testALocatedSeatLinkedToTheGeometryKeepsItsSourceAndUncertainty() throws {
        let (m, main, project) = try locatable(tier: "loopback")
        XCTAssertTrue(m.linkedPointIDs.contains(main))
        let geometry = try XCTUnwrap(m.locate(main))
        let kept = try XCTUnwrap(m.points.first { $0.id == main }?.position)
        XCTAssertEqual(kept.source, .acousticLocate)
        XCTAssertNotNil(kept.uncertaintyMetres)
        // After the geometry saves and the map reloads, the source survives while the coordinates match.
        let reload = RoomSeatMapController(
            projectStore: RoomCorrectionProjectStore(rootDirectory: root), defaults: defaults)
        reload.load(project: project, geometry: geometry)
        XCTAssertEqual(reload.points.first { $0.id == main }?.position?.source, .acousticLocate)
        // Moving the listener in the geometry elsewhere drops the located source.
        var moved = geometry
        moved.listener = RoomGeometryPoint3D(x: 1, y: 1, z: 1.1)
        reload.geometryChanged(moved)
        XCTAssertEqual(reload.points.first { $0.id == main }?.position?.source, .typed)
    }
}
