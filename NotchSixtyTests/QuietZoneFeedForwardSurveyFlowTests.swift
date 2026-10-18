import Foundation
import XCTest
@testable import NotchSixty

/// E4 S9b2: the feed-forward design measurement flow without hardware: the
/// channel rules, the survey store, the band assembly into the designer, and
/// the noise survey driven by a simulated two-channel capture, at the eight
/// standard rates.
final class QuietZoneFeedForwardSurveyFlowTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Rules

    func testReferenceChannelRules() throws {
        XCTAssertThrowsError(try QuietZoneFeedForwardSurveyRules.validateReferenceChannel(nil, errorChannel: 0)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSurveyError, .referenceChannelMissing)
        }
        XCTAssertThrowsError(try QuietZoneFeedForwardSurveyRules.validateReferenceChannel(1, errorChannel: 1)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSurveyError, .referenceIsErrorChannel)
        }
        XCTAssertThrowsError(try QuietZoneFeedForwardSurveyRules.validateReferenceChannel(-1, errorChannel: 0)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSurveyError, .referenceChannelUnavailable(-1))
        }
        XCTAssertEqual(try QuietZoneFeedForwardSurveyRules.validateReferenceChannel(1, errorChannel: 0), 1)
    }

    func testSurveyNeedsEightSegmentsAndKeepsLeakageOnlyForTheSameInputs() throws {
        let project = UUID()
        XCTAssertThrowsError(try QuietZoneFeedForwardSurveyRules.survey(
            projectID: project, microphoneStableID: "mic", errorChannel: 0, referenceChannel: 1,
            sampleRate: 48_000, bands: [], segments: 7, previous: nil, now: Date()
        )) { XCTAssertEqual($0 as? QuietZoneFeedForwardSurveyError, .notEnoughSegments(7)) }

        var previous = survey(project: project, rate: 48_000)
        previous.leakage = leakage(rate: 48_000)
        let same = try QuietZoneFeedForwardSurveyRules.survey(
            projectID: project, microphoneStableID: "test-mic", errorChannel: 0, referenceChannel: 1,
            sampleRate: 48_000, bands: previous.bands, segments: 100, previous: previous, now: Date()
        )
        XCTAssertEqual(same.leakage, previous.leakage)
        let moved = try QuietZoneFeedForwardSurveyRules.survey(
            projectID: project, microphoneStableID: "test-mic", errorChannel: 0, referenceChannel: 2,
            sampleRate: 48_000, bands: previous.bands, segments: 100, previous: previous, now: Date()
        )
        XCTAssertNil(moved.leakage)
    }

    // MARK: Store

    func testStoreRoundTripsAndRefusesAnotherMicrophone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("E4S9b2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuietZoneFeedForwardDesignSurveyStore(roomStore: RoomCorrectionProjectStore(rootDirectory: root))
        var project = RoomCorrectionProject(id: UUID(), playbackSystemID: UUID(), name: "Feed-forward")
        project.microphone = RoomCorrectionMicrophone(stableID: "test-mic", displayName: "Test mic")
        XCTAssertNil(try store.load(for: project))

        var saved = survey(project: project.id, rate: 96_000)
        saved.leakage = leakage(rate: 96_000)
        try store.save(saved, project: project)
        XCTAssertEqual(try store.load(for: project), saved)

        project.microphone?.stableID = "other-interface"
        XCTAssertThrowsError(try store.load(for: project)) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSurveyError, .incompatibleProject)
        }
        XCTAssertThrowsError(try store.save(saved, project: project))
    }

    // MARK: Band assembly and design

    func testBandsAssembleAndDesignAtEveryStandardRate() throws {
        for rate in rates {
            var s = survey(project: UUID(), rate: rate)
            s.bands[3].coherence = 0.5  // left out
            s.leakage = leakage(rate: rate)
            let seat = position(rate: rate, delayFrames: Int((0.004 * rate).rounded()))
            let result = try QuietZoneFeedForwardBandAssembler().assemble(survey: s, position: seat)
            XCTAssertEqual(result.bands.count, s.bands.count - 1, "\(rate) Hz")
            XCTAssertEqual(result.rejectedFrequenciesHz, [s.bands[3].frequencyHz])
            for band in result.bands {
                let angle = -2 * Double.pi * band.frequencyHz * (0.004 * rate).rounded() / rate
                XCTAssertEqual(band.leftSecondaryAtListener.real, 0.8 * cos(angle), accuracy: 1e-6, "\(rate) Hz")
                XCTAssertEqual(band.leftSecondaryAtListener.imaginary, 0.8 * sin(angle), accuracy: 1e-6)
                XCTAssertEqual(band.leftLeakageAtReference.magnitude, 0.02, accuracy: 1e-6)
                XCTAssertEqual(band.sourceToReference, ActiveQuietZoneComplex(real: 1, imaginary: 0))
            }
            guard case .design(let design, _) = QuietZoneFeedForwardSurveyRules.design(
                survey: s, position: seat, budget: plausibleBudget()
            ) else { return XCTFail("\(rate) Hz: the designer refused the assembled bands") }
            XCTAssertTrue(design.safePreviewOnly)
            XCTAssertEqual(design.bands.count, result.bands.count)
        }
    }

    func testNoDesignWithoutAPlausibleBudgetButTheBandsStay() throws {
        var s = survey(project: UUID(), rate: 48_000)
        s.leakage = leakage(rate: 48_000)
        let outcome = QuietZoneFeedForwardSurveyRules.design(
            survey: s, position: position(rate: 48_000, delayFrames: 100), budget: .missing
        )
        guard case .bandsOnly(let result, _) = outcome else { return XCTFail("expected bands only, got \(outcome)") }
        XCTAssertEqual(result.bands.count, s.bands.count)

        s.leakage = nil
        guard case .unavailable = QuietZoneFeedForwardSurveyRules.design(
            survey: s, position: position(rate: 48_000, delayFrames: 100), budget: plausibleBudget()
        ) else { return XCTFail("a survey without leakage must not design") }
        guard case .unavailable = QuietZoneFeedForwardSurveyRules.design(
            survey: nil, position: nil, budget: plausibleBudget()
        ) else { return XCTFail("no survey must not design") }
    }

    // MARK: Noise survey on a simulated capture

    /// e = 0.5 x delayed by 3 ms on the second channel of the same device.
    func testNoiseSurveyMeasuresTheReferenceToSeatTransferAtEveryStandardRate() throws {
        for rate in rates {
            let capture = SimulatedPairCapture(sampleRate: rate, delayFrames: Int((0.003 * rate).rounded()))
            let core = try XCTUnwrap(QuietZoneFeedForwardNoiseSurvey(sampleRate: rate))
            let run = QuietZoneFeedForwardNoiseSurveyRun(capture: capture, survey: core, durationSeconds: 10)
            try run.start()
            var progress = 0.0
            while progress < 1 {
                capture.produce(frames: Int(rate / 10))
                progress = try run.pump()
            }
            let result = run.finish()
            XCTAssertTrue(capture.closed)
            XCTAssertGreaterThanOrEqual(result.segments, QuietZoneFeedForwardSurveyGrid.minimumSegments, "\(rate) Hz")
            XCTAssertEqual(result.gaps, 0, "\(rate) Hz")
            XCTAssertEqual(result.bands.count, QuietZoneFeedForwardSurveyGrid.frequenciesHz.count)
            for band in result.bands {
                let angle = -2 * Double.pi * band.frequencyHz * Double(capture.delayFrames) / rate
                let error = hypot(band.referenceToSeat.real - 0.5 * cos(angle),
                                  band.referenceToSeat.imaginary - 0.5 * sin(angle))
                XCTAssertLessThan(error, 0.005, "\(rate) Hz at \(band.frequencyHz) Hz")
                XCTAssertGreaterThan(band.coherence, 0.999, "\(rate) Hz at \(band.frequencyHz) Hz")
            }
        }
    }

    func testALostCallbackIsAGapAndAFaultStopsTheRun() throws {
        let capture = SimulatedPairCapture(sampleRate: 48_000, delayFrames: 144)
        let core = try XCTUnwrap(QuietZoneFeedForwardNoiseSurvey(sampleRate: 48_000))
        let run = QuietZoneFeedForwardNoiseSurveyRun(capture: capture, survey: core, durationSeconds: 5)
        try run.start()
        capture.produce(frames: 48_000)
        capture.skip(frames: 512)
        capture.produce(frames: 48_000)
        _ = try run.pump()
        XCTAssertEqual(run.finish().gaps, 1)

        let failing = SimulatedPairCapture(sampleRate: 48_000, delayFrames: 144)
        failing.fault = true
        let second = QuietZoneFeedForwardNoiseSurveyRun(
            capture: failing, survey: try XCTUnwrap(QuietZoneFeedForwardNoiseSurvey(sampleRate: 48_000)),
            durationSeconds: 5
        )
        XCTAssertThrowsError(try second.pump()) {
            XCTAssertEqual($0 as? QuietZoneFeedForwardSurveyError, .captureFault)
        }
    }

    // MARK: Fixtures

    private func survey(project: UUID, rate: Double) -> QuietZoneFeedForwardDesignSurvey {
        let bands = QuietZoneFeedForwardSurveyGrid.frequenciesHz.map { f in
            let angle = -2 * Double.pi * f * 0.012
            return QuietZoneFeedForwardSurveyBand(
                frequencyHz: f,
                referenceToSeat: ActiveQuietZoneComplex(real: 0.02 * cos(angle), imaginary: 0.02 * sin(angle)),
                coherence: 0.97
            )
        }
        return QuietZoneFeedForwardDesignSurvey(
            projectID: project, microphoneStableID: "test-mic", errorChannel: 0, referenceChannel: 1,
            sampleRate: rate, capturedAt: Date(timeIntervalSince1970: 1_800_000_000), segments: 119, bands: bands
        )
    }

    private func impulse(rate: Double, delayFrames: Int, gain: Float) -> [Float] {
        var ir = [Float](repeating: 0, count: delayFrames + 16)
        ir[delayFrames] = gain
        return ir
    }

    private func leakage(rate: Double) -> QuietZoneFeedForwardLeakage {
        let d = Int((0.003 * rate).rounded())
        return QuietZoneFeedForwardLeakage(
            sampleRate: rate,
            leftImpulseResponse: impulse(rate: rate, delayFrames: d, gain: 0.02),
            rightImpulseResponse: impulse(rate: rate, delayFrames: d, gain: 0.02),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func position(rate: Double, delayFrames: Int) -> RoomCorrectionMeasurementPosition {
        func channel() -> RoomCorrectionChannelMeasurement {
            RoomCorrectionChannelMeasurement(
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000), rawCapture: [],
                impulseResponse: impulse(rate: rate, delayFrames: delayFrames, gain: 0.8),
                transferFunction: nil, quality: RoomCorrectionMeasurementQuality()
            )
        }
        return RoomCorrectionMeasurementPosition(name: "Seat", sampleRate: rate, left: channel(), right: channel())
    }

    private func plausibleBudget() -> QuietZoneFeedForwardBudget {
        QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible, acousticPreviewSeconds: 0.018,
            conservativePreviewSeconds: 0.016, antiNoisePathSeconds: 0.008,
            conservativeReserveSeconds: 0.007,
            geometryOnly: false, runtimeAvailable: false,
            explanation: "simulated fixture"
        )
    }
}

/// Two sample-aligned channels: the reference is seeded noise, the error the
/// reference delayed and halved. `skip` drops frames as a lost callback would.
private final class SimulatedPairCapture: QuietZoneFeedForwardPairCapturing {
    let sampleRate: Double
    let delayFrames: Int
    var closed = false
    var fault = false
    private var pending: [(N60FeedForwardReferenceFrame, Float)] = []
    private var history: [Float]  // ring of the last delayFrames + 1 samples
    private var position = 0
    private var time = 0.0
    private var state: UInt64 = 0x1234_5678

    init(sampleRate: Double, delayFrames: Int) {
        self.sampleRate = sampleRate
        self.delayFrames = delayFrames
        history = [Float](repeating: 0, count: delayFrames + 1)
    }

    func start() throws {}

    func produce(frames: Int) {
        let block = 512
        var made = 0
        while made < frames {
            let count = min(block, frames - made)
            for offset in 0..<count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let x = Float(Int64(bitPattern: state >> 11) % 2_000_000 - 1_000_000) / 10_000_000
                history[position] = x
                position = (position + 1) % history.count
                var frame = N60FeedForwardReferenceFrame()
                frame.sample = x
                frame.firstFrameSampleTime = time
                frame.frameOffset = UInt32(offset)
                frame.firstFrameHostTime = 1
                pending.append((frame, 0.5 * history[position]))  // the oldest: delayFrames ago
            }
            time += Double(count)
            made += count
        }
    }

    func skip(frames: Int) { time += Double(frames) }

    func readPair(maximumFrames: Int) throws -> (reference: [N60FeedForwardReferenceFrame], error: [Float]) {
        if fault { throw FeedForwardReferenceTransportError.callbackFault }
        let count = min(maximumFrames, pending.count)
        let chunk = pending.prefix(count)
        pending.removeFirst(count)
        return (chunk.map(\.0), chunk.map(\.1))
    }

    func close() { closed = true }
}
