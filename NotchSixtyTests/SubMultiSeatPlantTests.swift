import XCTest
@testable import NotchSixty

// E26 S6c: the measured per-seat plant (seats x L/R) decides how the multi-seat design treats a shared sub.
final class SubMultiSeatPlantTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let solver = ActiveQuietZoneSpatialPlanner()

    private func z(_ r: Double, _ i: Double = 0) -> ActiveQuietZoneComplex { ActiveQuietZoneComplex(real: r, imaginary: i) }

    private func config() -> ActiveQuietZoneConfiguration {
        var c = ActiveQuietZoneConfiguration()
        c.maximumPerSourceTonePeakDBFS = -12
        c.maximumAggregateSourcePeakDBFS = -9
        c.targetReductionDB = 6
        return c
    }

    private func impulse(delaySamples: Int, gain: Float, length: Int) -> [Float] {
        var ir = [Float](repeating: 0, count: length)
        ir[delaySamples] = gain
        return ir
    }

    /// Two seats at `rate`. `shared`: both feeds reach each seat through one path (rank one); otherwise L favours
    /// seat A and R favours seat B.
    private func fixture(rate: Double, shared: Bool, frequencyHz: Double = 80)
        -> (RoomCorrectionProject, ActiveQuietZoneSpatialCalibration) {
        let projectID = UUID(), systemID = UUID(), a = UUID(), b = UUID()
        var project = RoomCorrectionProject(id: projectID, playbackSystemID: systemID, name: "Sub multi-seat")
        project.microphone = RoomCorrectionMicrophone(stableID: "mic", displayName: "Mic")
        let delay = Int((0.004 * rate).rounded())
        let length = delay + 8
        func channel(_ ir: [Float]) -> RoomCorrectionChannelMeasurement {
            RoomCorrectionChannelMeasurement(
                capturedAt: Date(), rawCapture: [0], impulseResponse: ir, transferFunction: nil,
                quality: RoomCorrectionMeasurementQuality(clipped: false, estimatedSNRDB: 45, sweepComplete: true))
        }
        func seat(_ id: UUID, _ name: String, left: Float, right: Float, rightDelay: Int) -> RoomCorrectionMeasurementPosition {
            RoomCorrectionMeasurementPosition(
                id: id, name: name, included: true, weight: 1, sampleRate: rate,
                left: channel(impulse(delaySamples: delay, gain: left, length: length)),
                right: channel(impulse(delaySamples: rightDelay, gain: right, length: length)))
        }
        project.measurements = shared
            ? [seat(a, "A", left: 1, right: 1, rightDelay: delay), seat(b, "B", left: 0.7, right: 0.7, rightDelay: delay)]
            : [seat(a, "A", left: 1, right: 0.1, rightDelay: delay + 3), seat(b, "B", left: 0.1, right: 1, rightDelay: delay + 3)]
        func disturbance(_ id: UUID) -> ActiveQuietZoneSpatialDisturbance {
            ActiveQuietZoneSpatialDisturbance(
                positionID: id, ratioToAnchor: z(1), coherence: 0.99, phaseClosureRadians: 0.01, frequencyDriftHz: 0.01)
        }
        let calibration = ActiveQuietZoneSpatialCalibration(
            projectID: projectID, playbackSystemID: systemID, anchorPositionID: a, microphoneStableID: "mic",
            microphoneInputChannelIndex: 0, sampleRate: rate,
            positions: [ActiveQuietZoneSpatialPosition(id: a, weight: 1), ActiveQuietZoneSpatialPosition(id: b, weight: 1)],
            surveys: [ActiveQuietZoneSpatialToneSurvey(
                frequencyHz: frequencyHz, capturedAt: Date(), commonPhaseReferenceValidated: true,
                disturbances: [disturbance(a), disturbance(b)])])
        return (project, calibration)
    }

    func testGramConditionAgreesWithTheTwoByTwoFormula() {
        let a = z(1, 0.2), b = z(0.4, -0.3), c = z(-0.2, 0.5), d = z(0.9, 0.1)
        let closed = BassPlantConditioning.conditionDB(leftToFirst: a, rightToFirst: b, leftToSecond: c, rightToSecond: d)
        let gram = BassPlantConditioning.assess(frequencyHz: 50, seats: [(a, b), (c, d)]).conditionDB
        XCTAssertEqual(gram, closed, accuracy: 1.0e-9)
    }

    func testRankOneSeatsAreCommonModeAndDegenerateInputIsNever() {
        let same = BassPlantConditioning.assess(frequencyHz: 50, seats: [(z(1), z(1)), (z(0.7), z(0.7))])
        XCTAssertEqual(same.mode, .commonMode)
        XCTAssertEqual(BassPlantConditioning.assess(frequencyHz: 50, seats: [(z(1), z(1))]).mode, .commonMode)
        XCTAssertEqual(BassPlantConditioning.assess(frequencyHz: 50, seats: []).mode, .commonMode)
        XCTAssertEqual(
            BassPlantConditioning.assess(frequencyHz: 50, seats: [(z(.nan), z(1)), (z(1), z(1))]).mode, .commonMode)
        let separate = BassPlantConditioning.assess(frequencyHz: 50, seats: [(z(1), z(0.1)), (z(0.1), z(1))])
        XCTAssertEqual(separate.mode, .free)
    }

    func testStricterNeverLoosens() {
        let modes: [BassPlantConditioningMode] = [.free, .tikhonov(lambdaScale: 3), .tikhonov(lambdaScale: 6), .commonMode]
        for x in modes {
            for y in modes {
                let r = BassPlantConditioning.stricter(x, y)
                func rank(_ m: BassPlantConditioningMode) -> Double {
                    switch m {
                    case .free: return 0
                    case .tikhonov(let s): return s
                    case .commonMode: return 100
                    }
                }
                XCTAssertEqual(rank(r), max(rank(x), rank(y)))
            }
        }
    }

    func testSeatPlantAndSolveAtEveryRate() throws {
        for rate in rates {
            let shared = fixture(rate: rate, shared: true)
            let plant = try solver.bassConditioning(calibration: shared.1, project: shared.0, frequencyHz: 80)
            XCTAssertEqual(plant.mode, .commonMode, "\(rate)")
            let common = try solver.solve(
                calibration: shared.1, project: shared.0, frequencyHz: 80, liveAnchorDisturbance: z(0.025),
                availableInjectionPeak: 0.12, quietZoneConfiguration: config(), bassConditioning: plant.mode)
            XCTAssertEqual(common.leftOutput.real, common.rightOutput.real, accuracy: 1.0e-12, "\(rate)")
            XCTAssertEqual(common.leftOutput.imaginary, common.rightOutput.imaginary, accuracy: 1.0e-12, "\(rate)")
            XCTAssertGreaterThanOrEqual(common.weightedReductionDB, 1, "\(rate)")
            XCTAssertGreaterThanOrEqual(common.worstSeatReductionDB, -0.5, "\(rate)")

            let apart = fixture(rate: rate, shared: false)
            let free = try solver.bassConditioning(calibration: apart.1, project: apart.0, frequencyHz: 80)
            XCTAssertEqual(free.mode, .free, "\(rate)")
        }
    }

    func testTikhonovDrivesNoHarderThanFree() throws {
        let (project, calibration) = fixture(rate: 48_000, shared: false)
        func solve(_ mode: BassPlantConditioningMode) throws -> ActiveQuietZoneSpatialSolution {
            try solver.solve(
                calibration: calibration, project: project, frequencyHz: 80, liveAnchorDisturbance: z(0.025),
                availableInjectionPeak: 0.12, quietZoneConfiguration: config(), bassConditioning: mode)
        }
        let free = try solve(.free)
        let tight = try solve(.tikhonov(lambdaScale: 10))
        let freeDrive = free.leftOutput.magnitude + free.rightOutput.magnitude
        let tightDrive = tight.leftOutput.magnitude + tight.rightOutput.magnitude
        XCTAssertLessThanOrEqual(tightDrive, freeDrive + 1.0e-12)
        // Default argument is the free solve, so existing callers are unchanged.
        let implicit = try solver.solve(
            calibration: calibration, project: project, frequencyHz: 80, liveAnchorDisturbance: z(0.025),
            availableInjectionPeak: 0.12, quietZoneConfiguration: config())
        XCTAssertEqual(implicit, free)
    }
}
