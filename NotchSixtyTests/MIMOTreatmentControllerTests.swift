import XCTest
@testable import NotchSixty

/// E19 S8: the Room Treatment screen's model. Controls change the design input, the design stages through the host, the
/// permit refusals and arm refusals are shown by name, Arm needs a permit, and nothing arms by itself.
@MainActor
final class MIMOTreatmentControllerTests: XCTestCase {
    private final class FakeHost: MIMOTreatmentHost {
        let treatment: MIMOGraphTreatment
        var sampleRate: Double? = 48_000
        var context: MIMOGraphTreatment.Context
        var configuration: UnifiedGraphConfiguration?
        var staged: [UnifiedGraphMIMOStage] = []
        var video: MIMOVideoLatencyInput = .known(videoLatencyMode: false)
        var acceptance: MIMORoomTreatmentHardwareAcceptance?
        var readback: n60_mimo_readback?
        var registry = MIMOTreatmentQualificationRegistry.production

        init(flags: FeatureFlags, rate: Double = 48_000) {
            treatment = MIMOGraphTreatment(flags: flags)
            sampleRate = rate
            treatment.settle = {}
            treatment.publish = { _ in }
            context = MIMOGraphTreatment.Context(
                engineRunning: true, outputDeviceUID: "OUT-1", sampleRate: rate, stageAttached: true, hardLimitPresent: true,
                engineLeaseHeld: true, videoLatencyMode: false, outputTrimsDB: [0, 0], laneCount: 2)
            // A chain 12 dB below the hard limit leaves the designer room to treat (budget capped at 9 dB).
            var quiet = UnifiedGraphLane()
            quiet.preGain = 0.25
            var config = UnifiedGraphConfiguration(sampleRate: rate, lanes: [quiet, quiet])
            config.outputProtection = UnifiedGraphOutputProtection()
            configuration = config
        }

        func treatmentContext() -> MIMOGraphTreatment.Context { context }
        func treatmentSources() -> [MIMOTreatmentSourceInfo] {
            [MIMOTreatmentSourceInfo(source: .speaker(.frontLeft), lane: 0, name: "Front Left"),
             MIMOTreatmentSourceInfo(source: .speaker(.frontRight), lane: 1, name: "Front Right")]
        }
        func treatmentGraphConfiguration() -> UnifiedGraphConfiguration? { configuration }
        func stageTreatment(_ stage: UnifiedGraphMIMOStage, configuration: UnifiedGraphConfiguration) throws {
            staged.append(stage)
            treatment.stage(stage)
        }
        func issueTreatmentPermit(
            verification: MIMOTreatmentVerificationResult?, acceptance: MIMORoomTreatmentHardwareAcceptance?
        ) -> Result<MIMOGraphTreatment.Permit, MIMOTreatmentPermitRefusal> {
            treatment.issuePermit(
                context: context, videoLatency: video, verification: verification, acceptance: acceptance, registry: registry)
        }
        func requestTreatmentArm() async throws { try await treatment.requestArm(context: context) }
        func disarmTreatment() { treatment.userDisarm() }
        func treatmentReadback() -> n60_mimo_readback? { readback }
        func hardwareAcceptance() -> MIMORoomTreatmentHardwareAcceptance? { acceptance }
    }

    private func flags(on: Bool = true) -> FeatureFlags {
        FeatureFlags(
            defaults: UserDefaults(suiteName: "MIMOTreatmentControllerTests.\(UUID().uuidString)") ?? .standard,
            policy: .launchArgumentOnly,
            arguments: on ? [FeatureFlags.launchArgument, FeatureFlag.mimoTreatment.id] : [])
    }

    private let seats = [MultichannelCalibrationSeat(name: "Seat 1"), MultichannelCalibrationSeat(name: "Seat 2")]

    /// Two sources, two seats: a direct arrival plus two decaying modes, as in the designer tests.
    private func measurements(rate: Double, sources: [MultichannelCalibrationSource]) -> [MultichannelCalibrationMeasurement] {
        let length = Int(rate * 3.0)
        var out: [MultichannelCalibrationMeasurement] = []
        for (si, source) in sources.enumerated() {
            for (ki, seat) in seats.enumerated() {
                var ir = [Float](repeating: 0, count: length)
                ir[Int(rate * (0.002 + 0.0003 * Double(si) + 0.0004 * Double(ki)))] = 1
                let alpha = 6.907755 / (0.8 * rate)
                for (mode, hz) in [40.0, 70.0].enumerated() {
                    let gain = 0.2 * (1 + 0.3 * Double((si + ki + mode) % 3))
                    let phase = 0.7 * Double(si * 2 + ki + mode)
                    for n in 0..<length {
                        ir[n] += Float(gain * exp(-alpha * Double(n)) * sin(2 * Double.pi * hz * Double(n) / rate + phase))
                    }
                }
                let channel = RoomCorrectionChannelMeasurement(
                    capturedAt: Date(), rawCapture: [], impulseResponse: ir, transferFunction: nil,
                    quality: RoomCorrectionMeasurementQuality())
                out.append(MultichannelCalibrationMeasurement(seatID: seat.id, source: source, sampleRate: rate, channel: channel))
            }
        }
        return out
    }

    private var loose: MIMOTreatmentRealisationLimits {
        var limits = MIMOTreatmentRealisationLimits.standard
        limits.maximumDeviationDB = 6
        return limits
    }

    private func rig(rate: Double = 48_000, on: Bool = true) throws -> (MIMOTreatmentController, FakeHost) {
        let host = FakeHost(flags: flags(on: on), rate: rate)
        let all = measurements(rate: rate, sources: [.speaker(.frontLeft), .speaker(.frontRight)])
        let taps = Int(try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate).lowRateHz)
        let controller = MIMOTreatmentController(
            host: host, flags: flags(on: on), seats: { self.seats }, baseline: { all }, limits: loose, taps: taps)
        controller.refreshSources()
        controller.decayTarget = .seconds(0.3)
        controller.setTau(milliseconds: 20)
        return (controller, host)
    }

    // MARK: Tests

    func testControlsChangeTheDesignInput() async throws {
        let (controller, host) = try rig()
        XCTAssertEqual(controller.rows.map(\.name), ["Front Left", "Front Right"])
        controller.setTau(milliseconds: 20)
        controller.decayTarget = .seconds(0.3)
        controller.setSupport(lowHz: 30, highHz: 120, lane: 0)
        controller.setIncluded(false, lane: 1)
        await controller.design()
        XCTAssertEqual(controller.phase, .designed, "\(controller.phase)")
        let stage = try XCTUnwrap(host.staged.last)
        XCTAssertEqual(Array(stage.supportRangesHz.prefix(3)), [30, 120, stage.supportRangesHz[2]])
        // G34: the unedited row comes from the capture's -10 dB point, inside the planner's window; the edited row keeps its range.
        XCTAssertTrue((15.0...60.0).contains(stage.supportRangesHz[2]), "\(stage.supportRangesHz)")
        XCTAssertEqual(stage.supportRangesHz[3], 150)
        XCTAssertEqual(stage.filters.tauSeconds, 0.020, accuracy: 1e-9)
        XCTAssertEqual(controller.designedDecaySeconds, 0.3)
        // The excluded source's row of the delta is exactly zero.
        let taps = stage.filters.tapCount
        let row1 = stage.filters.taps[(1 * 2 + 0) * taps ..< (1 * 2 + 2) * taps]
        XCTAssertTrue(row1.allSatisfy { $0 == 0 })
        XCTAssertEqual(controller.seatDecays.count, 2)
        XCTAssertFalse(controller.isArmed, "designing never arms")
    }

    func testTauIsClampedAndShortTauShowsTheNote() throws {
        let (controller, _) = try rig()
        controller.setTau(milliseconds: 99)
        XCTAssertEqual(controller.tauMilliseconds, 20)
        controller.setTau(milliseconds: -3)
        XCTAssertEqual(controller.tauMilliseconds, 0)
        XCTAssertNotNil(controller.shortTauNote)
        controller.setTau(milliseconds: 15)
        XCTAssertNil(controller.shortTauNote)
    }

    func testPredictedDecayIsShorterAfterThanBeforeAtThreeRates() async throws {
        for rate in [48_000.0, 96_000.0, 384_000.0] {
            let (controller, _) = try rig(rate: rate)
            controller.decayTarget = .seconds(0.5)
            await controller.design()
            XCTAssertEqual(controller.phase, .designed, "rate \(rate): \(controller.phase)")
            for seat in controller.seatDecays {
                let before = try XCTUnwrap(seat.beforeSeconds, "rate \(rate)")
                let after = try XCTUnwrap(seat.afterSeconds, "rate \(rate)")
                XCTAssertLessThan(after, before, "rate \(rate) \(seat.name)")
            }
        }
    }

    func testDesignRefusalsAreNamed() async throws {
        let (controller, host) = try rig()
        host.configuration = nil
        await controller.design()
        XCTAssertEqual(controller.phase, .failed(MIMOTreatmentController.InputError.audioNotRunning.localizedDescription))
        host.configuration = FakeHost(flags: flags()).configuration
        host.sampleRate = 44_100
        await controller.design()
        guard case .failed(let text) = controller.phase else { return XCTFail("expected a failure") }
        XCTAssertTrue(text.contains("Re-measure"), text)
        controller.setIncluded(false, lane: 0)
        controller.setIncluded(false, lane: 1)
        XCTAssertFalse(controller.canDesign)
    }

    func testFlagOffHidesTheControlsAndRefusesToDesign() async throws {
        let (controller, host) = try rig(on: false)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canDesign)
        await controller.design()
        guard case .failed = controller.phase else { return XCTFail("flag off must refuse") }
        XCTAssertTrue(host.staged.isEmpty)
        XCTAssertFalse(controller.canArm)
    }

    func testArmIsDisabledWithoutAPermitAndEveryRefusalIsNamed() async throws {
        let (controller, host) = try rig()
        await controller.design()
        XCTAssertFalse(controller.permitHeld)
        XCTAssertFalse(controller.canArm)
        XCTAssertFalse(controller.canBypass)

        // No treated repeat measurement: the verifier names it, and the hardware gate names itself too.
        controller.requestPermit()
        XCTAssertTrue(controller.permitRefusals.contains(MIMOTreatmentVerificationFailure.repeatMeasurementMissing.reason), "\(controller.permitRefusals)")
        XCTAssertFalse(controller.canArm)

        // Video latency mode is its own named refusal.
        host.video = .known(videoLatencyMode: true)
        controller.requestPermit()
        XCTAssertEqual(controller.permitRefusals, [MIMOTreatmentPermitRefusal.videoLatencyMode.reason])
        // An unwired latency input is named too.
        host.video = .unknown
        controller.requestPermit()
        XCTAssertEqual(controller.permitRefusals, [MIMOTreatmentPermitRefusal.videoLatencyInputNotWired.reason])

        // The arm itself refuses by name without a permit.
        await controller.arm()
        XCTAssertEqual(controller.armMessage, MIMOGraphTreatment.ArmRefusal.noPermit.localizedDescription)
        XCTAssertFalse(controller.isArmed)
    }

    func testProductionRegistryIssuesNoPermitEvenWithAGoodRepeatMeasurement() async throws {
        let host = FakeHost(flags: flags())
        let all = measurements(rate: 48_000, sources: [.speaker(.frontLeft), .speaker(.frontRight)])
        let taps = Int(try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: 48_000).lowRateHz)
        // The treated repeat is the predicted response, so decay checks pass; hardware acceptance is what is missing.
        let controller = MIMOTreatmentController(
            host: host, flags: flags(), seats: { self.seats }, baseline: { all }, treated: { all }, limits: loose, taps: taps)
        controller.refreshSources()
        await controller.design()
        controller.requestPermit()
        XCTAssertFalse(controller.permitRefusals.isEmpty)
        XCTAssertFalse(controller.permitHeld, "E22 fills the qualification table; no permit exists before it")
        XCTAssertFalse(controller.canArm)
    }

    func testArmAndBypassWorkOnlyWithAPermitAndNothingArmsByItself() async throws {
        let (controller, host) = try rig()
        await controller.design()
        let stage = try XCTUnwrap(host.treatment.stage)
        host.treatment.setPermit(.init(fingerprint: host.treatment.currentFingerprint(stage, host.context)))
        controller.refreshReadout()
        XCTAssertFalse(controller.isArmed, "a permit alone never arms")
        XCTAssertTrue(controller.canArm)
        XCTAssertFalse(controller.canBypass)
        await controller.arm()
        XCTAssertTrue(controller.isArmed)
        XCTAssertTrue(controller.canBypass)
        XCTAssertFalse(controller.canArm)
        controller.bypass()
        XCTAssertFalse(controller.isArmed)
        XCTAssertEqual(controller.armStateLabel, "Off")
    }

    func testArmRefusalFromAGateIsShownByName() async throws {
        let (controller, host) = try rig()
        await controller.design()
        let stage = try XCTUnwrap(host.treatment.stage)
        host.treatment.setPermit(.init(fingerprint: host.treatment.currentFingerprint(stage, host.context)))
        host.context.hardLimitPresent = false
        await controller.arm()
        XCTAssertEqual(controller.armMessage, MIMOGraphTreatment.ArmRefusal.hardLimitMissing.localizedDescription)
        XCTAssertEqual(controller.gates.first { $0.name == "Output hard limit present" }?.passed, false)
        XCTAssertFalse(controller.isArmed)
    }

    func testLiveReadoutShowsPerSourceRatiosAndFaultNames() async throws {
        let (controller, host) = try rig()
        await controller.design()
        var readback = n60_mimo_readback()
        readback.state = 2
        readback.sourceCount = 2
        readback.boundRatioMax.0 = 0.25
        readback.deltaPeak.1 = 0.1
        host.readback = readback
        controller.refreshReadout()
        XCTAssertEqual(controller.armStateLabel, "Armed")
        XCTAssertEqual(try XCTUnwrap(controller.readout[0].liveBoundRatioDB), 10 * log10(0.25), accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(controller.readout[1].livePeakDeltaDBFS), -20, accuracy: 1e-4)
        XCTAssertNotNil(controller.readout[0].headroomBudgetDB)
        readback.faultLatched = 1
        readback.faultReason = 2
        host.readback = readback
        controller.refreshReadout()
        XCTAssertEqual(controller.armStateLabel, "Fault: thermal budget")
    }

    func testReadbackMaxMerge() {
        let merged = n60_mimo_readback.maxMerged((1, 5, 0, 0, 0, 0, 0, 0), (3, 2, 0, 0, 0, 0, 0, 9))
        XCTAssertEqual(n60_mimo_readback.values(merged), [3, 5, 0, 0, 0, 0, 0, 9])
    }

    func testVideoLatencyInputFollowsTheInstalledRoomCorrection() {
        var room = RoomCorrectionConfiguration()
        XCTAssertEqual(AudioIOEngine.videoLatencyInput(for: room), .known(videoLatencyMode: false), "no correction, no video mode")
        room.enabled = true
        XCTAssertEqual(AudioIOEngine.videoLatencyInput(for: room), .unknown, "no lane plan states no mode")
        // G35: a legacy single filter states its mode through its declared latency.
        room.filter = RoomCorrectionFilter(name: "min", sampleRate: nil, leftTaps: [1, 0.5], rightTaps: nil, declaredLatencyFrames: 0)
        XCTAssertEqual(AudioIOEngine.videoLatencyInput(for: room), .known(videoLatencyMode: true), "minimum phase is video mode")
        room.filter?.declaredLatencyFrames = 128
        XCTAssertEqual(AudioIOEngine.videoLatencyInput(for: room), .known(videoLatencyMode: false), "a declared latency is music mode")
    }

    func testEngineHeldReadbackIsNilWithoutASession() {
        let engine = AudioIOEngine()
        XCTAssertNil(engine.treatmentReadback())
        XCTAssertTrue(engine.treatmentSources().isEmpty)
        XCTAssertNil(engine.treatmentGraphConfiguration())
    }
}
