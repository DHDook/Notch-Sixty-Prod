import XCTest
@testable import NotchSixty

/// E29 S6 (`e29.room-model`): the interpolation wrapper at the eight rates, music at the seat against the
/// convolution truth, the fallback when confidence is low, the Conversation Focus input taking the seat model, and
/// estimated seats on the seat map (shown with confidence, never stored).
@MainActor
final class MusicAtSeatTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let centres = SpeechIntelligibilityBands.centersHz

    private func delta(_ gain: Float, at index: Int = 64, frames: Int = 4096) -> [Float] {
        var h = [Float](repeating: 0, count: frames)
        h[index] = gain
        return h
    }

    private func pos(_ x: Double, _ y: Double, _ z: Double = 1.1) -> RoomPosition {
        RoomPosition(x: x, y: y, z: z, source: .typed, uncertaintyMetres: nil)
    }

    // MARK: Wrapper

    func testMeasuredBandLevelsMatchTheGainAtEveryRate() throws {
        for rate in Self.rates {
            let r = try XCTUnwrap(RoomModelInterpolator.measured(impulseResponse: delta(0.5), sampleRate: rate))
            XCTAssertEqual(r.origin, .measured)
            for centre in centres {
                let k = try XCTUnwrap(r.bandIndex(nearest: centre))
                XCTAssertTrue(r.available[k], "rate \(rate) band \(centre)")
                XCTAssertEqual(r.levelsDB[k], -6.02, accuracy: 0.1, "rate \(rate) band \(centre)")
                XCTAssertEqual(r.confidence[k], 1)
            }
        }
    }

    func testDerivedFromAGridCarriesConfidenceAndRefusesOutsideTrust() throws {
        let grid = [pos(1, 2), pos(1.5, 2), pos(1, 2.5), pos(1.5, 2.5)]
        let neighbours = grid.map { RoomNeighbourPath(position: $0, impulseResponse: delta(0.5), phaseTrusted: false) }
        for rate in Self.rates {
            let r = RoomModelInterpolator.derive(
                source: pos(0.5, 0, 0.9), query: pos(1.2, 2.2), sampleRate: rate, neighbours: neighbours)
            let derived = try XCTUnwrap(try? r.get(), "rate \(rate)")
            XCTAssertTrue(derived.isDerived)
            XCTAssertGreaterThan(derived.meanConfidence, 0.8, "rate \(rate)")
            let k = try XCTUnwrap(derived.bandIndex(nearest: 1_000))
            XCTAssertEqual(derived.levelsDB[k], -6.02, accuracy: 0.5, "rate \(rate)")
        }
        let far = RoomModelInterpolator.derive(
            source: pos(0.5, 0, 0.9), query: pos(4, 6), sampleRate: 48_000, neighbours: neighbours)
        XCTAssertEqual(far, .failure(.outsideTrust))
        XCTAssertEqual(RoomModelInterpolator.derive(
            source: pos(0, 0), query: pos(1, 1), sampleRate: 48_000, neighbours: []), .failure(.noNeighbours))
    }

    func testPowerSumOfTwoEqualFeedsAddsThreeDecibels() throws {
        let one = try XCTUnwrap(RoomModelInterpolator.measured(impulseResponse: delta(0.5), sampleRate: 48_000))
        let sum = try XCTUnwrap(RoomBandResponse.powerSum([one, one]))
        let k = try XCTUnwrap(sum.bandIndex(nearest: 1_000))
        XCTAssertEqual(sum.levelsDB[k] - one.levelsDB[k], 3.01, accuracy: 0.01)
    }

    // MARK: Predictor

    /// Convolution truth: a tone at each band centre through the impulse response, level read from the output.
    private func convolvedLevelDB(centre: Double, rate: Double, ir: [Float], amplitude: Double) -> Double {
        let n = 16_384
        let x = (0..<n).map { amplitude * sin(2 * .pi * centre * Double($0) / rate) }
        var y = [Double](repeating: 0, count: n)
        for (t, tap) in ir.enumerated() where tap != 0 {
            for i in t..<n { y[i] += Double(tap) * x[i - t] }
        }
        let tail = y[2_048...]
        let power = tail.reduce(0.0) { $0 + $1 * $1 } / Double(tail.count)
        return 10 * log10(power)
    }

    func testPredictedBandLevelsMatchTheConvolutionAtEveryRate() throws {
        let ir = delta(0.35, at: 40)
        let programmeAmplitude = 0.2
        let programmeDB = 10 * log10(programmeAmplitude * programmeAmplitude / 2)
        for rate in Self.rates {
            let seat = try XCTUnwrap(RoomModelInterpolator.measured(impulseResponse: ir, sampleRate: rate))
            let input = MusicAtSeatInput(programmeBandLevelsDB: Array(repeating: programmeDB, count: centres.count), seat: seat)
            let prediction = try MusicAtSeatPredictor.predict(input).get()
            XCTAssertFalse(prediction.derived)
            for (i, centre) in centres.enumerated() {
                let truth = convolvedLevelDB(centre: centre, rate: rate, ir: ir, amplitude: programmeAmplitude)
                XCTAssertEqual(prediction.bandLevelsDB[i], truth, accuracy: 0.5, "rate \(rate) band \(centre)")
            }
        }
    }

    func testOutputGainChangeSincePathMeasuredIsAdded() throws {
        let seat = try XCTUnwrap(RoomModelInterpolator.measured(impulseResponse: delta(1), sampleRate: 48_000))
        var input = MusicAtSeatInput(programmeBandLevelsDB: Array(repeating: -30, count: centres.count), seat: seat)
        let base = try MusicAtSeatPredictor.predict(input).get().bandLevelsDB[0]
        input.currentOutputGainDB = -12
        input.measuredOutputGainDB = -18
        XCTAssertEqual(try MusicAtSeatPredictor.predict(input).get().bandLevelsDB[0] - base, 6, accuracy: 1e-9)
        input.measuredOutputGainDB = nil
        XCTAssertEqual(try MusicAtSeatPredictor.predict(input).get().bandLevelsDB[0], base, accuracy: 1e-9)
    }

    func testFallbackWhenConfidenceIsLowMissingStaleOrUnavailable() throws {
        var seat = try XCTUnwrap(RoomModelInterpolator.measured(impulseResponse: delta(0.5), sampleRate: 48_000))
        let programme = Array(repeating: -30.0, count: centres.count)
        XCTAssertEqual(MusicAtSeatPredictor.predict(MusicAtSeatInput(programmeBandLevelsDB: programme, seat: nil)),
                       .failure(.noSeatResponse))
        XCTAssertEqual(MusicAtSeatPredictor.predict(MusicAtSeatInput(programmeBandLevelsDB: [1, 2], seat: seat)),
                       .failure(.invalidProgramme))
        XCTAssertEqual(MusicAtSeatPredictor.predict(
            MusicAtSeatInput(programmeBandLevelsDB: programme, seat: seat, seatPathStale: true)), .failure(.stalePath))
        var low = seat
        low.confidence = low.confidence.map { _ in 0.2 }
        XCTAssertEqual(MusicAtSeatPredictor.predict(MusicAtSeatInput(programmeBandLevelsDB: programme, seat: low)),
                       .failure(.lowConfidence))
        let k = try XCTUnwrap(seat.bandIndex(nearest: 1_000))
        seat.available[k] = false
        XCTAssertEqual(MusicAtSeatPredictor.predict(MusicAtSeatInput(programmeBandLevelsDB: programme, seat: seat)),
                       .failure(.bandUnavailable))
    }

    // MARK: Conversation Focus input

    private func spectrum(_ db: Double) -> [AmbientSpectrumBand] {
        (0..<64).map { i in
            let lo = 20 * pow(1000.0, Double(i) / 64)
            let hi = 20 * pow(1000.0, Double(i + 1) / 64)
            return AmbientSpectrumBand(
                lowerFrequencyHz: lo, centerFrequencyHz: (lo * hi).squareRoot(), upperFrequencyHz: hi, levelDBFS: db)
        }
    }

    func testBuilderUsesTheSeatPredictionOnlyWhenGiven() throws {
        let seat = try XCTUnwrap(RoomModelInterpolator.measured(impulseResponse: delta(0.5), sampleRate: 48_000))
        let prediction = try MusicAtSeatPredictor.predict(
            MusicAtSeatInput(programmeBandLevelsDB: Array(repeating: -20, count: centres.count), seat: seat)).get()
        let cuts = Array(repeating: 2.0, count: centres.count)
        func build(_ seatMusic: MusicAtSeatPrediction?) throws -> ConversationUnmaskingInput {
            try ConversationUnmaskingInputBuilder.build(
                residual: spectrum(-50), playback: spectrum(-30), baseline: spectrum(-70), appliedCutsDB: cuts,
                speechConfidence: 1, seatMusic: seatMusic).get()
        }
        let today = try build(nil)
        let seated = try build(prediction)
        XCTAssertNotEqual(today.musicBandLevelsDB, seated.musicBandLevelsDB)
        for i in 0..<centres.count {
            XCTAssertEqual(seated.musicBandLevelsDB[i], prediction.bandLevelsDB[i] + 2, accuracy: 1e-9)
        }
        XCTAssertEqual(today.speechBandLevelsDB, seated.speechBandLevelsDB)
    }

    // MARK: Seat map

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("music-seat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func channel() -> RoomCorrectionChannelMeasurement {
        var q = RoomCorrectionMeasurementQuality()
        q.sweepComplete = true
        return RoomCorrectionChannelMeasurement(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), rawCapture: [], impulseResponse: delta(0.5, frames: 2048),
            transferFunction: nil, quality: q)
    }

    private var project: RoomCorrectionProject!

    private func mapWithGrid() -> RoomSeatMapController {
        var p = RoomCorrectionProject(playbackSystemID: UUID(), name: "Lounge")
        p.measurements = ["A", "B", "C", "D"].map {
            RoomCorrectionMeasurementPosition(name: $0, sampleRate: 48_000, left: channel(), right: channel())
        }
        project = p
        let map = RoomSeatMapController(projectStore: RoomCorrectionProjectStore(rootDirectory: root))
        map.load(project: p, geometry: nil)
        let seats = map.points.filter { $0.kind == .seat }
        let at = [(1.0, 2.0), (1.5, 2.0), (1.0, 2.5), (1.5, 2.5)]
        for (s, xy) in zip(seats, at) { map.setPosition(s.id, x: xy.0, y: xy.1, z: 1.1) }
        for feed in map.points.filter({ $0.kind == .speakerFeed }) {
            map.setPosition(feed.id, x: feed.id == RoomModelAdapter.leftFeedID ? 0.5 : 2, y: 0, z: 0.9)
        }
        return map
    }

    func testAnUnmeasuredSeatBetweenMeasuredOnesIsEstimatedWithConfidence() throws {
        let map = mapWithGrid()
        XCTAssertTrue(map.derivedRows.isEmpty)
        let id = try XCTUnwrap(map.addUnmeasuredSeat(name: "Armchair", x: 1.2, y: 2.2))
        let row = try XCTUnwrap(map.derivedRows.first { $0.id == id })
        XCTAssertGreaterThan(try XCTUnwrap(row.meanConfidence), 0.8)
        XCTAssertTrue(row.text.contains("confidence"))
        XCTAssertTrue(row.text.contains("not used for room correction"))
        XCTAssertNotNil(map.derivedResponses[id])
        map.removeUnmeasuredSeat(id)
        XCTAssertTrue(map.derivedRows.isEmpty)
    }

    func testAnUnmeasuredSeatFarFromAnyMeasuredSeatGetsNoEstimate() throws {
        let map = mapWithGrid()
        let id = try XCTUnwrap(map.addUnmeasuredSeat(name: "Far", x: 5, y: 7))
        let row = try XCTUnwrap(map.derivedRows.first { $0.id == id })
        XCTAssertNil(row.meanConfidence)
        XCTAssertNil(map.derivedResponses[id])
        XCTAssertTrue(row.text.hasPrefix("No estimate"))
    }

    func testUnmeasuredSeatsPersistButEstimatesAreNotStored() throws {
        let map = mapWithGrid()
        let id = try XCTUnwrap(map.addUnmeasuredSeat(name: "Armchair", x: 1.2, y: 2.2))
        let again = RoomSeatMapController(projectStore: RoomCorrectionProjectStore(rootDirectory: root))
        again.load(project: project, geometry: nil)
        XCTAssertEqual(again.points.first { $0.id == id }?.name, "Armchair")
        XCTAssertNotNil(again.derivedResponses[id], "estimated again on load, not read from disk")
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".wav") }, "no impulse response is written for an estimate")
    }
}
