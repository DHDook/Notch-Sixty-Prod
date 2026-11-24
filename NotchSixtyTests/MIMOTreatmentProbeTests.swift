import XCTest
@testable import NotchSixty

/// E19 S12b (SQ5, D11, D13): the probe arm for the treated repeat measurement, behind `e19.self-qualification`. The probe never
/// arms by itself, never yields a permit, and ends on the last seat, the 120 s limit, a fault, a hard-limit action or a change.
@MainActor
final class MIMOTreatmentProbeTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let seatIDs = [UUID(), UUID(), UUID()]
    private var now = Date(timeIntervalSince1970: 1_000_000)

    private func flags(selfQualification: Bool = true) -> FeatureFlags {
        FeatureFlags(
            defaults: UserDefaults(suiteName: "MIMOTreatmentProbeTests.\(UUID().uuidString)") ?? .standard,
            policy: .launchArgumentOnly,
            arguments: [
                FeatureFlags.launchArgument,
                FeatureFlag.mimoTreatment.id + (selfQualification ? ",\(FeatureFlag.selfQualification.id)" : ""),
            ])
    }

    private func stage(rate: Double, sources: Int = 2) throws -> UnifiedGraphMIMOStage {
        let low = try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate)
        let filters = MIMOTreatmentFilterSet(
            sampleRate: rate, lowRateHz: low.lowRateHz, decimation: low.decimation, sourceCount: sources, tapCount: 16,
            tauSeconds: 0.015, taps: [Float](repeating: 0, count: sources * sources * 16), solved: [], gridLowHz: 0, gridBins: 0)
        var stage = try UnifiedGraphMIMOStage(filters: filters, sourceLanes: Array(0..<sources))
        stage.supportRangesHz = [30, 150, 30, 150]
        return stage
    }

    private func context(rate: Double, uid: String = "OUT-1", trim: Double = 0) -> MIMOGraphTreatment.Context {
        MIMOGraphTreatment.Context(
            engineRunning: true, outputDeviceUID: uid, sampleRate: rate, stageAttached: true, hardLimitPresent: true,
            engineLeaseHeld: true, videoLatencyMode: false, outputTrimsDB: [trim, 0], laneCount: 2, selfQualificationBinding: "engine-1")
    }

    private func decay() -> MIMOTreatmentVerificationResult {
        MIMOTreatmentVerificationResult(
            failures: [], predictedMedianImprovement: 0.4, measuredMedianImprovement: 0.4, baselineBands: [], predictedBands: [],
            measuredBands: [])
    }

    private func evidence(rate: Double, sources: Int = 2) -> MIMOTreatmentSelfQualificationEvidence {
        let seats = seatIDs.map { MIMOTreatmentSelfQualificationEvidence.Seat(id: $0, included: true, weight: 1) }
        let captures = seatIDs.flatMap { seat in
            (0..<sources).map { lane in
                MIMOTreatmentSelfQualificationEvidence.Capture(
                    seatID: seat, lane: lane, sampleRate: rate, microphoneUID: "MIC-1", reliableBands: 7,
                    thirdOctaveSNRDB: [38, 40, 41, 40, 39, 42, 40, 38, 37], digest: "cap-\(seat.uuidString.prefix(4))-\(lane)")
            }
        }
        let budgets = (0..<sources).map {
            MIMOTreatmentSelfQualificationEvidence.SourceBudget(
                source: $0, headroomReserveDB: 4.5, excursionLimitHz: 28, effortSlopeBelowLimitDBPerOctave: 18)
        }
        let report = MIMORoomTreatmentVerificationReport(
            sampleRate: rate, seatIDs: [], sources: [], frequenciesHz: [], sourceReports: [], baselineSpatialRMSErrorDB: 5,
            treatedSpatialRMSErrorDB: 3, spatialRMSErrorImprovementDB: 2, maximumAbsoluteMeanLevelShiftDB: 0.5,
            worstSeatErrorIncreaseDB: 0, accepted: true)
        return MIMOTreatmentSelfQualificationEvidence(
            sampleRate: rate, sourceCount: sources, seats: seats, captures: captures, headroomBudgetedSources: sources, laneCount: sources,
            protectedLaneCount: sources, quietZoneActuatorPresent: false, budgets: budgets, thermalDeltaRMSDB: -9,
            predictedDecay: decay(), predictedSpatial: report)
    }

    private func registry(for stage: UnifiedGraphMIMOStage) -> MIMOTreatmentQualificationRegistry {
        MIMOTreatmentQualificationRegistry(
            records: [],
            engineBaselines: [
                MIMOTreatmentEngineBaseline(
                    decimation: stage.filters.decimation, recordedAt: Date(), longRunThermalPassed: true, protectionChainPassed: true,
                    stopStartPassed: true, unplugReplugPassed: true, sleepWakePassed: true, audibleArtifactCheckPassed: true)
            ])
    }

    private struct Rig {
        var treatment: MIMOGraphTreatment
        var design: UnifiedGraphMIMOStage
        var evidence: MIMOTreatmentSelfQualificationEvidence
        var rate: Double
    }

    private func rig(rate: Double, sq: Bool = true) throws -> Rig {
        let treatment = MIMOGraphTreatment(flags: flags(selfQualification: sq))
        treatment.publish = { _ in }
        treatment.settle = {}
        treatment.clock = { [unowned self] in self.now }
        let design = try stage(rate: rate)
        treatment.stage(design)
        return Rig(treatment: treatment, design: design, evidence: evidence(rate: rate), rate: rate)
    }

    private func ticket(_ r: Rig) -> Result<MIMOTreatmentProbeTicket, MIMOTreatmentProbeRefusal> {
        r.treatment.issueProbeTicket(
            context: context(rate: r.rate), videoLatency: .known(videoLatencyMode: false), evidence: r.evidence,
            registry: registry(for: r.design))
    }

    /// A ticket, programme stopped and the user's arm.
    private func armed(rate: Double) async throws -> Rig {
        let r = try rig(rate: rate)
        guard case .success = ticket(r) else { throw XCTSkip("no ticket") }
        r.treatment.probeProgrammeMuted = true
        try await r.treatment.requestProbeArm(context: context(rate: rate))
        return r
    }

    private func readback(fault: Bool = false) -> n60_mimo_readback {
        var rb = n60_mimo_readback()
        rb.structSize = UInt32(MemoryLayout<n60_mimo_readback>.size)
        rb.faultLatched = fault ? 1 : 0
        return rb
    }

    // MARK: Ticket needs SQ1 to SQ4

    func testTicketIsIssuedOnlyWhenEverySQ1ToSQ4CriterionPassesAtEveryRate() throws {
        for rate in rates {
            let r = try rig(rate: rate)
            guard case .success(let t) = ticket(r) else { return XCTFail("\(rate)") }
            XCTAssertEqual(t.seatIDs, seatIDs, "\(rate)")
            XCTAssertFalse(r.treatment.isArmed, "\(rate): a ticket never arms")
            XCTAssertNil(r.treatment.permit, "\(rate): a ticket is not a permit")
        }
    }

    func testTicketRefusedWhenACriterionFailsOrNoBaselineOrFlagOff() throws {
        var r = try rig(rate: 48_000)
        r.evidence.seats[2].included = false
        guard case .failure(.selfQualificationRefused(let f)) = ticket(r) else { return XCTFail("seats") }
        XCTAssertTrue(f.contains(.tooFewSeats(included: 2)))

        r = try rig(rate: 48_000)
        let none = r.treatment.issueProbeTicket(
            context: context(rate: 48_000), videoLatency: .known(videoLatencyMode: false), evidence: r.evidence, registry: .production)
        guard case .failure(.selfQualificationRefused(let g)) = none else { return XCTFail("baseline") }
        XCTAssertTrue(g.contains(.engineBaselineMissing(decimation: r.design.filters.decimation)), "production holds none until E22")

        let off = try rig(rate: 48_000, sq: false)
        XCTAssertEqual(ticket(off), .failure(.featureOff))
        XCTAssertNil(off.treatment.probeSession)

        let unknown = try rig(rate: 48_000)
        XCTAssertEqual(
            unknown.treatment.issueProbeTicket(
                context: context(rate: 48_000), videoLatency: .unknown, evidence: unknown.evidence, registry: registry(for: unknown.design)),
            .failure(.videoLatencyInputNotWired))
        var notReady = context(rate: 48_000)
        notReady.stageAttached = false
        XCTAssertEqual(
            unknown.treatment.issueProbeTicket(
                context: notReady, videoLatency: .known(videoLatencyMode: false), evidence: unknown.evidence,
                registry: registry(for: unknown.design)),
            .failure(.engineNotReady))
    }

    // MARK: Arming needs a user action and every gate

    func testProbeArmNeedsTicketProgrammeStoppedAndEveryGate() async throws {
        let r = try rig(rate: 48_000)
        // No ticket: refused, nothing armed.
        await XCTAssertThrowsErrorAsync(try await r.treatment.requestProbeArm(context: self.context(rate: 48_000))) {
            XCTAssertEqual($0 as? MIMOGraphTreatment.ArmRefusal, .noProbeTicket)
        }
        guard case .success = ticket(r) else { return XCTFail() }
        // Programme still playing: refused.
        await XCTAssertThrowsErrorAsync(try await r.treatment.requestProbeArm(context: self.context(rate: 48_000))) {
            XCTAssertEqual($0 as? MIMOGraphTreatment.ArmRefusal, .programmeNotStopped)
        }
        r.treatment.probeProgrammeMuted = true
        for mutate: (inout MIMOGraphTreatment.Context) -> Void in [
            { $0.stageAttached = false }, { $0.hardLimitPresent = false }, { $0.engineLeaseHeld = false },
            { $0.videoLatencyMode = true }, { $0.engineRunning = false }, { $0.outputDeviceUID = nil },
        ] {
            var c = context(rate: 48_000)
            mutate(&c)
            XCTAssertNotNil(r.treatment.probeGateFailure(c))
        }
        XCTAssertEqual(r.treatment.probeGateFailure(context(rate: 48_000, trim: 1)), .fingerprintMismatch, "a changed trim")
        XCTAssertFalse(r.treatment.isArmed)
        try await r.treatment.requestProbeArm(context: context(rate: 48_000))
        XCTAssertTrue(r.treatment.isArmed)
        XCTAssertEqual(r.treatment.probeSession?.activeSeat, seatIDs[0])
        XCTAssertNil(r.treatment.permit, "a probe never yields a permit")
    }

    func testProbeArmsAtEveryRate() async throws {
        for rate in rates {
            let r = try await armed(rate: rate)
            XCTAssertTrue(r.treatment.isArmed, "\(rate)")
            XCTAssertEqual(r.treatment.stage?.armed, true, "\(rate)")
            XCTAssertNil(r.treatment.permit, "\(rate)")
        }
    }

    func testNothingArmsOnItsOwnLaunchWakeDeviceOrRateChange() async throws {
        let r = try rig(rate: 48_000)
        r.treatment.observe(context: context(rate: 48_000), readback: nil)
        XCTAssertFalse(r.treatment.isArmed, "launch, with no ticket")
        guard case .success = ticket(r) else { return XCTFail() }
        r.treatment.probeProgrammeMuted = true
        r.treatment.observe(context: context(rate: 48_000), readback: nil)
        r.treatment.observe(context: context(rate: 96_000), readback: nil)
        XCTAssertFalse(r.treatment.isArmed, "a rate change with a ticket held does not arm")
        let newDevice = try rig(rate: 48_000)
        guard case .success = ticket(newDevice) else { return XCTFail() }
        newDevice.treatment.observe(context: context(rate: 48_000, uid: "OUT-2"), readback: nil)
        XCTAssertFalse(newDevice.treatment.isArmed, "an output change does not arm")
        XCTAssertEqual(newDevice.treatment.probeSession?.end, .fingerprintChanged)
        await XCTAssertThrowsErrorAsync(try await newDevice.treatment.requestProbeArm(context: self.context(rate: 48_000))) {
            XCTAssertEqual($0 as? MIMOGraphTreatment.ArmRefusal, .noProbeTicket, "a spent ticket cannot arm")
        }
    }

    // MARK: Ends

    func testProbeEndsAfterTheLastSeatAndTheTicketIsSpent() async throws {
        let r = try await armed(rate: 48_000)
        for (index, seat) in seatIDs.enumerated() {
            XCTAssertEqual(r.treatment.probeSession?.activeSeat, seat)
            XCTAssertTrue(r.treatment.isArmed, "seat \(index)")
            r.treatment.probeSeatCaptured(seat)
        }
        XCTAssertEqual(r.treatment.probeSession?.end, .completed)
        XCTAssertFalse(r.treatment.isArmed)
        XCTAssertEqual(r.treatment.stage?.trip, false, "the normal fade, not a trip")
        XCTAssertNil(r.treatment.permit)
        XCTAssertEqual(r.treatment.gateFailure(context(rate: 48_000)), .noPermit)
        await XCTAssertThrowsErrorAsync(try await r.treatment.requestProbeArm(context: self.context(rate: 48_000))) {
            XCTAssertEqual($0 as? MIMOGraphTreatment.ArmRefusal, .noProbeTicket)
        }
    }

    func testEachSeatHasItsOwn120SecondLimit() async throws {
        let r = try await armed(rate: 48_000)
        now.addTimeInterval(100)
        r.treatment.observe(context: context(rate: 48_000), readback: readback(), hardLimitGainReductionDB: 0)
        XCTAssertTrue(r.treatment.isArmed)
        r.treatment.probeSeatCaptured(seatIDs[0])
        now.addTimeInterval(100)
        r.treatment.observe(context: context(rate: 48_000), readback: readback(), hardLimitGainReductionDB: 0)
        XCTAssertTrue(r.treatment.isArmed, "seat 2 has a fresh 120 s")
        now.addTimeInterval(20.5)
        r.treatment.observe(context: context(rate: 48_000), readback: readback(), hardLimitGainReductionDB: 0)
        XCTAssertFalse(r.treatment.isArmed)
        XCTAssertEqual(r.treatment.probeSession?.end, .timedOut(seat: seatIDs[1]))
        XCTAssertEqual(r.treatment.stage?.trip, false)
    }

    func testFaultHardLimitAndChangeEndTheProbe() async throws {
        var r = try await armed(rate: 96_000)
        r.treatment.observe(context: context(rate: 96_000), readback: readback(fault: true), hardLimitGainReductionDB: 0)
        XCTAssertEqual(r.treatment.probeSession?.end, .faulted)
        XCTAssertFalse(r.treatment.isArmed)
        XCTAssertEqual(r.treatment.stage?.trip, true, "a fault trips")

        r = try await armed(rate: 96_000)
        r.treatment.observe(context: context(rate: 96_000), readback: readback(), hardLimitGainReductionDB: 3)
        XCTAssertTrue(r.treatment.isArmed, "the first reading predates the arm and is discarded")
        r.treatment.observe(context: context(rate: 96_000), readback: readback(), hardLimitGainReductionDB: 0.5)
        XCTAssertEqual(r.treatment.probeSession?.end, .hardLimitActed)
        XCTAssertFalse(r.treatment.isArmed)

        r = try await armed(rate: 96_000)
        r.treatment.observe(context: context(rate: 96_000, trim: 2), readback: readback(), hardLimitGainReductionDB: 0)
        XCTAssertEqual(r.treatment.probeSession?.end, .fingerprintChanged)
        XCTAssertFalse(r.treatment.isArmed)

        r = try await armed(rate: 96_000)
        r.treatment.observe(context: context(rate: 96_000, uid: "OUT-9"), readback: readback(), hardLimitGainReductionDB: 0)
        XCTAssertFalse(r.treatment.isArmed, "a device change disarms")
        XCTAssertNotEqual(r.treatment.probeSession?.end, .completed)

        r = try await armed(rate: 96_000)
        r.treatment.stopProbe()
        XCTAssertEqual(r.treatment.probeSession?.end, .userStopped)
        XCTAssertFalse(r.treatment.isArmed)

        r = try await armed(rate: 96_000)
        r.treatment.graphRebuilt()
        XCTAssertFalse(r.treatment.isArmed, "a rebuild disarms")
        XCTAssertNotEqual(r.treatment.probeSession?.end, .completed)
        XCTAssertNotNil(r.treatment.probeSession?.end)
    }

    // MARK: SQ5 evaluation

    private func response(rate: Double, scale: Float = 1) -> [Float] {
        let length = Int(rate * 0.6)
        var ir = [Float](repeating: 0, count: length)
        for (k, hz) in MIMOTreatmentProbeLimits.bandCentersHz.enumerated() {
            let gain = 0.1 * Float(1 + k % 3)
            for n in 0..<length {
                let t = Double(n) / rate
                ir[n] += scale * gain * Float(exp(-t * 9) * sin(2 * Double.pi * hz * t))
            }
        }
        return ir
    }

    private func completedSession(hardLimit: Double = 0, read: Bool = true, fault: Bool = false) -> MIMOTreatmentProbeSession {
        var s = MIMOTreatmentProbeSession(
            ticket: MIMOTreatmentProbeTicket(fingerprint: "fp", seatIDs: [seatIDs[0]], issuedAt: now))
        s.end = .completed
        s.hardLimitReadingSeen = read
        s.worstHardLimitReductionDB = hardLimit
        s.faultSeen = fault
        return s
    }

    private func seat(rate: Double, controlDB: Double = 0, treatedDB: Double = 0) -> MIMOTreatmentProbeEvaluator.SeatResponses {
        func scale(_ db: Double) -> Float { Float(pow(10, db / 20)) }
        return MIMOTreatmentProbeEvaluator.SeatResponses(
            seatID: seatIDs[0], baseline: response(rate: rate), control: response(rate: rate, scale: scale(controlDB)),
            predictedTreated: response(rate: rate, scale: 0.5), measuredTreated: response(rate: rate, scale: 0.5 * scale(treatedDB)))
    }

    func testSQ5TolerancesPassAtOneAndThreeDBAndRefuseJustBeyondAtEveryRate() {
        for rate in rates {
            let session = completedSession()
            XCTAssertEqual(
                MIMOTreatmentProbeEvaluator.evaluate(seats: [seat(rate: rate, controlDB: 0.99, treatedDB: -2.99)], sampleRate: rate, session: session),
                [], "\(rate)")
            let control = MIMOTreatmentProbeEvaluator.evaluate(
                seats: [seat(rate: rate, controlDB: 1.02)], sampleRate: rate, session: session)
            XCTAssertFalse(control.isEmpty, "\(rate)")
            XCTAssertTrue(control.allSatisfy { if case .controlMismatch = $0 { return true } else { return false } }, "\(rate)")
            let level = MIMOTreatmentProbeEvaluator.evaluate(
                seats: [seat(rate: rate, treatedDB: 3.02)], sampleRate: rate, session: session)
            XCTAssertFalse(level.isEmpty, "\(rate)")
            XCTAssertTrue(level.allSatisfy { if case .treatedLevelMismatch = $0 { return true } else { return false } }, "\(rate)")
            XCTAssertFalse(level.map(\.reason).joined().isEmpty)
        }
    }

    func testSQ5RefusesAnIncompleteProbeAMonitorTripAndAHardLimitThatActedOrWasNeverRead() {
        let good = [seat(rate: 48_000)]
        XCTAssertEqual(MIMOTreatmentProbeEvaluator.evaluate(seats: good, sampleRate: 48_000, session: nil), [.probeIncomplete])
        var live = completedSession()
        live.end = .timedOut(seat: seatIDs[0])
        XCTAssertEqual(MIMOTreatmentProbeEvaluator.evaluate(seats: good, sampleRate: 48_000, session: live), [.probeIncomplete])
        XCTAssertEqual(
            MIMOTreatmentProbeEvaluator.evaluate(seats: good, sampleRate: 48_000, session: completedSession(fault: true)), [.monitorLatched])
        XCTAssertEqual(
            MIMOTreatmentProbeEvaluator.evaluate(seats: good, sampleRate: 48_000, session: completedSession(read: false)), [.hardLimitNotRead])
        XCTAssertEqual(
            MIMOTreatmentProbeEvaluator.evaluate(seats: good, sampleRate: 48_000, session: completedSession(hardLimit: 0.4)),
            [.hardLimitActed(reductionDB: 0.4)])
        XCTAssertEqual(
            MIMOTreatmentProbeEvaluator.evaluate(seats: [], sampleRate: 48_000, session: completedSession()), [.seatMissing(seat: 0)])
        var silent = seat(rate: 48_000)
        silent.control = [Float](repeating: 0, count: 100)
        XCTAssertEqual(
            MIMOTreatmentProbeEvaluator.evaluate(seats: [silent], sampleRate: 48_000, session: completedSession()), [.captureSilent(seat: 0)])
    }

    // MARK: A probe never yields a permit; SQ5 gates the self-qualified one

    func testPermitNeedsAPassingProbeResultTakenOnThisDesign() throws {
        let r = try rig(rate: 48_000)
        var e = r.evidence
        r.treatment.updateSelfQualificationEvidence(e)
        func issue(_ e: MIMOTreatmentSelfQualificationEvidence) -> Result<MIMOGraphTreatment.Permit, MIMOTreatmentPermitRefusal> {
            r.treatment.issuePermit(
                context: context(rate: 48_000), videoLatency: .known(videoLatencyMode: false), verification: decay(), acceptance: nil,
                registry: registry(for: r.design), selfQualification: e)
        }
        XCTAssertEqual(issue(e), .failure(.selfQualificationRefused([.treatedProbeMissing])))
        e.probeResult = MIMOTreatmentProbeResult(fingerprint: "another design", failures: [])
        XCTAssertEqual(issue(e), .failure(.selfQualificationRefused([.treatedProbeMissing])))
        r.treatment.updateSelfQualificationEvidence(e)
        let fp = r.treatment.currentFingerprint(r.design, context(rate: 48_000), selfQualified: true)
        e.probeResult = MIMOTreatmentProbeResult(fingerprint: fp, failures: [.monitorLatched])
        XCTAssertEqual(issue(e), .failure(.selfQualificationRefused([.treatedProbeFailed([.monitorLatched])])))
        XCTAssertNil(r.treatment.permit)
        e.probeResult = MIMOTreatmentProbeResult(fingerprint: fp, failures: [])
        guard case .success(let permit) = issue(e) else { return XCTFail("a passing probe earns the permit") }
        XCTAssertEqual(permit.basis, .selfQualification)
        XCTAssertFalse(r.treatment.isArmed, "the permit never arms")
    }

    // MARK: The runner

    @MainActor
    private final class FakeCapturer: TreatmentProbeCapturing {
        var rate: Double
        var failOnTreated = false
        var stopped: [Bool] = []
        init(rate: Double) { self.rate = rate }
        func setProgrammeStopped(_ stopped: Bool) throws { self.stopped.append(stopped) }
        func capture(seatID: UUID, treated: Bool) async throws -> [MultichannelCalibrationMeasurement] {
            if treated, failOnTreated { throw MIMOTreatmentProbeRunnerError.notReady("stimulus failed") }
            let channel = RoomCorrectionChannelMeasurement(
                capturedAt: Date(), rawCapture: [], impulseResponse: [Float](repeating: 0.01, count: 8), transferFunction: nil,
                quality: RoomCorrectionMeasurementQuality())
            return [MultichannelCalibrationMeasurement(seatID: seatID, source: .subwoofer(0), sampleRate: rate, channel: channel)]
        }
    }

    func testRunnerTakesControlsThenTheArmedPassAndDisarmsAfterTheLastSeat() async throws {
        let r = try rig(rate: 48_000)
        guard case .success = ticket(r) else { return XCTFail() }
        let capturer = FakeCapturer(rate: 48_000)
        let runner = MIMOTreatmentProbeRunner(
            treatment: r.treatment, capturer: capturer,
            armProbe: { [self] in try await r.treatment.requestProbeArm(context: self.context(rate: 48_000)) })
        await XCTAssertThrowsErrorAsync(try await runner.armAndMeasureTreated()) {
            XCTAssertEqual(($0 as? MIMOTreatmentProbeRunnerError), .notReady("Take the untreated check at every seat first."))
        }
        try await runner.captureControls()
        XCTAssertFalse(r.treatment.isArmed, "controls are taken with the stage off")
        XCTAssertEqual(runner.controlMeasurements.count, 3)
        try await runner.armAndMeasureTreated()
        XCTAssertEqual(runner.treatedMeasurements.count, 3)
        XCTAssertEqual(r.treatment.probeSession?.end, .completed)
        XCTAssertFalse(r.treatment.isArmed)
        XCTAssertFalse(r.treatment.probeProgrammeMuted)
        XCTAssertEqual(capturer.stopped.last, false, "programme is restored")
        XCTAssertNil(r.treatment.permit)
    }

    func testRunnerStopsTheProbeWhenACaptureFailsAndWithoutACapturerNothingIsTaken() async throws {
        let r = try rig(rate: 48_000)
        guard case .success = ticket(r) else { return XCTFail() }
        let capturer = FakeCapturer(rate: 48_000)
        capturer.failOnTreated = true
        let runner = MIMOTreatmentProbeRunner(
            treatment: r.treatment, capturer: capturer,
            armProbe: { [self] in try await r.treatment.requestProbeArm(context: self.context(rate: 48_000)) })
        try await runner.captureControls()
        await XCTAssertThrowsErrorAsync(try await runner.armAndMeasureTreated()) { _ in }
        XCTAssertFalse(r.treatment.isArmed)
        XCTAssertEqual(r.treatment.probeSession?.end, .userStopped)
        XCTAssertTrue(runner.treatedMeasurements.isEmpty)

        let r2 = try rig(rate: 48_000)
        guard case .success = ticket(r2) else { return XCTFail() }
        let bare = MIMOTreatmentProbeRunner(treatment: r2.treatment, capturer: nil, armProbe: {})
        await XCTAssertThrowsErrorAsync(try await bare.captureControls()) {
            XCTAssertEqual($0 as? MIMOTreatmentProbeRunnerError, .captureUnavailable)
        }
        XCTAssertFalse(r2.treatment.isArmed)
    }

    func testFlagIsStillOffByDefault() {
        XCTAssertFalse(FeatureFlag.selfQualification.resolvedDefault)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void, _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch { handler(error) }
}
