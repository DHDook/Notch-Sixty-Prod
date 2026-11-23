import XCTest
@testable import NotchSixty

/// E12 S11: plain verdicts, the Measure again refusal, and the no-calibration-file correction limit.
@MainActor
final class SystemSetupVerdictTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func clean() -> RoomCorrectionMeasurementQuality {
        var q = RoomCorrectionMeasurementQuality()
        q.sweepComplete = true
        q.capturePeakDBFS = -18
        q.estimatedNoiseFloorDBFS = -70
        q.estimatedSNRDB = 52
        q.repeatCount = 4
        q.rejectedRepeats = []
        q.driftPPM = 5
        return q
    }

    func testCleanMeasurementIsGood() {
        let verdict = MeasurementVerdictRules.verdict(for: clean())
        XCTAssertEqual(verdict.level, .good)
        XCTAssertFalse(verdict.reason.isEmpty)
    }

    func testInjectedNoiseLowersTheVerdictInSteps() {
        var q = clean()
        q.estimatedSNRDB = 36
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .usable)
        q.estimatedSNRDB = 25
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .limited)
        q.estimatedSNRDB = 12
        let verdict = MeasurementVerdictRules.verdict(for: q)
        XCTAssertEqual(verdict.level, .measureAgain)
        XCTAssertTrue(verdict.reason.contains("noise"), verdict.reason)
    }

    func testWeakSignalAndHotSignal() {
        var q = clean()
        q.capturePeakDBFS = -45
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .limited)
        q.capturePeakDBFS = -60
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .measureAgain)
        q.capturePeakDBFS = -1
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .limited)
    }

    func testClippingAndIncompleteSweepMeanMeasureAgain() {
        var q = clean()
        q.clipped = true
        let clipped = MeasurementVerdictRules.verdict(for: q)
        XCTAssertEqual(clipped.level, .measureAgain)
        XCTAssertTrue(clipped.reason.lowercased().contains("clip"), clipped.reason)
        q = clean()
        q.sweepComplete = false
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .measureAgain)
    }

    func testMovedMicrophoneRejectsRepeatsAndSaysMeasureAgain() {
        var q = clean()
        q.rejectedRepeats = [1]
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .usable)
        q.rejectedRepeats = [1, 2]
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .limited)
        q.rejectedRepeats = [1, 2, 3]
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .measureAgain)
    }

    func testDriftLowersTheVerdict() {
        var q = clean()
        q.driftPPM = 80
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .usable)
        q.driftPPM = -400
        XCTAssertEqual(MeasurementVerdictRules.verdict(for: q).level, .limited)
    }

    func testSeatVerdictIsTheWorstSourceAndNamesIt() {
        var bad = clean()
        bad.estimatedSNRDB = 10
        let verdict = MeasurementVerdictRules.verdict(forSeat: [("Front left", clean()), ("Front right", bad)])
        XCTAssertEqual(verdict?.level, .measureAgain)
        XCTAssertTrue(verdict?.reason.hasPrefix("Front right:") == true, verdict?.reason ?? "")
        XCTAssertNil(MeasurementVerdictRules.verdict(forSeat: []))
    }

    // MARK: Flow refusal

    private func runningFlow() throws -> SystemSetupFlow {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: PlaybackSystemState(associatedOutputUID: "uid-a", outputGainDB: -3))
        return flow
    }

    func testMeasureAgainSeatRefusesNextWithTheReason() throws {
        var flow = try runningFlow()
        flow.choices.seatNames = ["Seat 1"]
        flow.choices.measurementIDs = [UUID()]
        XCTAssertNil(flow.unmetPrecondition(for: .measure))
        flow.choices.seatVerdicts = [SeatMeasurementVerdict(
            seatName: "Seat 1", verdict: MeasurementVerdict(level: .limited, reason: "Noisy room."))]
        XCTAssertNil(flow.unmetPrecondition(for: .measure), "Limited still goes on")
        flow.choices.seatVerdicts = [SeatMeasurementVerdict(
            seatName: "Seat 1", verdict: MeasurementVerdict(level: .measureAgain, reason: "The microphone clipped."))]
        let reason = try XCTUnwrap(flow.unmetPrecondition(for: .measure))
        XCTAssertTrue(reason.contains("Seat 1") && reason.contains("clipped"), reason)
    }

    func testSessionsSavedBeforeVerdictsStillDecode() throws {
        let data = try JSONEncoder().encode(SystemSetupChoices())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "seatVerdicts")
        object.removeValue(forKey: "correctionLimitOverrideHz")
        let old = try JSONSerialization.data(withJSONObject: object)
        let choices = try JSONDecoder().decode(SystemSetupChoices.self, from: old)
        XCTAssertNil(choices.seatVerdicts)
        XCTAssertNil(MeasurementVerdictRules.blockingReason(choices.seatVerdicts))
    }

    // MARK: Correction limit

    func testLimitHoldsWithoutACalibrationFileAndLiftsWithOne() {
        XCTAssertEqual(SystemSetupCorrectionLimit.limitHz(calibrationFile: nil), 300)
        XCTAssertEqual(SystemSetupCorrectionLimit.limitHz(calibrationFile: ""), 300)
        XCTAssertNil(SystemSetupCorrectionLimit.limitHz(calibrationFile: "umik-1.txt"))
        XCTAssertNil(SystemSetupCorrectionLimit.limitHz(calibrationFile: "umik-1.txt", overrideHz: 500))
        XCTAssertEqual(SystemSetupCorrectionLimit.limitHz(calibrationFile: nil, overrideHz: 500), 500)
        XCTAssertEqual(SystemSetupCorrectionLimit.limitHz(calibrationFile: nil, overrideHz: 5_000), 1_000)
        XCTAssertEqual(SystemSetupCorrectionPlan.parameters(limitHz: nil), SystemSetupCorrectionPlan.defaultParameters)
        XCTAssertEqual(SystemSetupCorrectionPlan.parameters(limitHz: 300).correctionHighHz, 300)
    }

    /// A designed grid on a reference-style two-seat room is silent above the limit and untouched well below it, at
    /// every rate.
    func testDesignedCorrectionStopsAtTheLimitAtEveryRate() throws {
        let frequencies = try RoomCorrectionCore.gridFrequencies()
        for rate in Self.rates {
            let label = "\(rate) Hz"
            let seats = (0..<2).map { index -> RoomCorrectionCore.SeatImpulseResponse in
                var ir = [Float](repeating: 0, count: Int(rate * 0.25))
                let arrival = Int(rate * (0.004 + 0.0005 * Double(index)))
                ir[arrival] = 1
                ir[arrival + Int(rate * 0.006)] = 0.45  // a reflection makes a comb to correct
                return .init(samples: ir, arrivalFrames: Double(arrival), weight: 1)
            }
            var design = try RoomCorrectionCore.designGrid(seats: seats, sampleRate: rate, mainSeat: 0, mode: .video)
            let original = design
            XCTAssertTrue(design.correctionDB.contains { $0 != 0 }, label)
            SystemSetupCorrectionLimit.apply(to: &design, frequenciesHz: frequencies, limitHz: 300)
            for (index, f) in frequencies.enumerated() {
                if f >= 300 {
                    XCTAssertEqual(design.correctionDB[index], 0, label)
                    XCTAssertEqual(design.correctionPhaseRadians[index], 0, label)
                } else if f <= 300 / pow(2, SystemSetupCorrectionLimit.taperOctaves) {
                    XCTAssertEqual(design.correctionDB[index], original.correctionDB[index], label)
                } else {
                    XCTAssertLessThanOrEqual(abs(design.correctionDB[index]), abs(original.correctionDB[index]) + 1e-12, label)
                }
            }
        }
    }

    // MARK: Production model on the reference room

    func testReferenceRoomVerdictsAreNotMeasureAgainAndLimitFollowsTheCalibrationFile() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate, seats: 3, outputChannels: 2)
            defer { rig.tearDown() }
            let model = rig.model
            let label = "\(rate) Hz"
            model.verdictsEnabled = true
            model.begin(preset: .quick)
            model.chooseOutput(uid: OfflineSetupRig.outputUID)
            model.next()
            model.selectMicrophone(uid: OfflineSetupRig.inputUID)
            model.acceptSweepLevel(measuredSPLdBC: 75)
            model.next()
            model.prepareMeasure()
            model.addSeat()
            await model.measureAll()
            let verdicts = try XCTUnwrap(model.choices.seatVerdicts, label)
            XCTAssertEqual(verdicts.count, 1, label)
            XCTAssertNotEqual(verdicts[0].verdict.level, .measureAgain, "\(label): \(verdicts[0].verdict.reason)")
            XCTAssertFalse(verdicts[0].verdict.reason.isEmpty, label)
            model.next()
            XCTAssertEqual(model.step, .alignment, "\(label): \(model.message ?? "")")
            XCTAssertEqual(model.correctionLimitHz, 300, label)
        }
    }

    func testFlagOffLeavesTheFlowAsItWas() async throws {
        let rig = try OfflineSetupRig(rate: 48_000, seats: 3, outputChannels: 2)
        defer { rig.tearDown() }
        rig.model.verdictsEnabled = false
        XCTAssertNil(rig.model.correctionLimitHz)
        XCTAssertTrue(rig.model.seatVerdicts.isEmpty)
    }
}
