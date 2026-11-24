import XCTest
@testable import NotchSixty

/// E19 S12a (SQ1 to SQ4, SQ7): the self-qualified permit basis behind `e19.self-qualification`. The evidence is synthetic but
/// every criterion is judged by the production evaluator; the decay verifier itself is covered in `MIMOTreatmentPermitTests`.
@MainActor
final class MIMOTreatmentSelfQualificationTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let seatIDs = [UUID(), UUID(), UUID()]

    private func flags(selfQualification: Bool) -> FeatureFlags {
        FeatureFlags(
            defaults: UserDefaults(suiteName: "MIMOTreatmentSelfQualificationTests.\(UUID().uuidString)") ?? .standard,
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

    private func context(rate: Double, binding: String = "engine-1") -> MIMOGraphTreatment.Context {
        MIMOGraphTreatment.Context(
            engineRunning: true, outputDeviceUID: "OUT-1", sampleRate: rate, stageAttached: true, hardLimitPresent: true,
            engineLeaseHeld: true, videoLatencyMode: false, outputTrimsDB: [0, 0], laneCount: 2, selfQualificationBinding: binding)
    }

    private func spatial(improvement: Double = 2) -> MIMORoomTreatmentVerificationReport {
        MIMORoomTreatmentVerificationReport(
            sampleRate: 48_000, seatIDs: [], sources: [], frequenciesHz: [], sourceReports: [], baselineSpatialRMSErrorDB: 5,
            treatedSpatialRMSErrorDB: 3, spatialRMSErrorImprovementDB: improvement, maximumAbsoluteMeanLevelShiftDB: 0.5,
            worstSeatErrorIncreaseDB: 0, accepted: true)
    }

    private func decay(improvement: Double = 0.4, failures: [MIMOTreatmentVerificationFailure] = [], repeatMeasured: Bool = true)
        -> MIMOTreatmentVerificationResult
    {
        MIMOTreatmentVerificationResult(
            failures: failures, predictedMedianImprovement: improvement, measuredMedianImprovement: repeatMeasured ? improvement : nil,
            baselineBands: [], predictedBands: [], measuredBands: repeatMeasured ? [] : nil)
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
        return MIMOTreatmentSelfQualificationEvidence(
            sampleRate: rate, sourceCount: sources, seats: seats, captures: captures, headroomBudgetedSources: sources, laneCount: sources,
            protectedLaneCount: sources, quietZoneActuatorPresent: false, budgets: budgets, thermalDeltaRMSDB: -9,
            predictedDecay: decay(), predictedSpatial: spatial())
    }

    private func registry(for stage: UnifiedGraphMIMOStage, complete: Bool = true) -> MIMOTreatmentQualificationRegistry {
        MIMOTreatmentQualificationRegistry(
            records: [],
            engineBaselines: [
                MIMOTreatmentEngineBaseline(
                    decimation: stage.filters.decimation, recordedAt: Date(), longRunThermalPassed: complete, protectionChainPassed: true,
                    stopStartPassed: true, unplugReplugPassed: true, sleepWakePassed: true, audibleArtifactCheckPassed: true)
            ])
    }

    private func controller(rate: Double, sq: Bool = true) throws -> (MIMOGraphTreatment, UnifiedGraphMIMOStage) {
        let treatment = MIMOGraphTreatment(flags: flags(selfQualification: sq))
        treatment.publish = { _ in }
        treatment.settle = {}
        let design = try stage(rate: rate)
        treatment.stage(design)
        return (treatment, design)
    }

    private func issue(
        _ t: MIMOGraphTreatment, _ design: UnifiedGraphMIMOStage, _ e: MIMOTreatmentSelfQualificationEvidence?, rate: Double,
        verification: MIMOTreatmentVerificationResult? = nil, registry reg: MIMOTreatmentQualificationRegistry? = nil
    ) -> Result<MIMOGraphTreatment.Permit, MIMOTreatmentPermitRefusal> {
        t.issuePermit(
            context: context(rate: rate), videoLatency: .known(videoLatencyMode: false), verification: verification ?? decay(),
            acceptance: nil, registry: reg ?? registry(for: design), selfQualification: e)
    }

    private func failures(_ r: Result<MIMOGraphTreatment.Permit, MIMOTreatmentPermitRefusal>) -> [MIMOTreatmentSelfQualificationFailure] {
        if case .failure(.selfQualificationRefused(let f)) = r { return f }
        return []
    }

    // MARK: A room that meets every criterion

    func testAMeasuredRoomEarnsASelfQualifiedPermitAtEveryRate() throws {
        for rate in rates {
            let (t, design) = try controller(rate: rate)
            let e = evidence(rate: rate)
            t.updateSelfQualificationEvidence(e)
            let r = issue(t, design, e, rate: rate)
            guard case .success(let permit) = r else { return XCTFail("\(rate): \(r)") }
            XCTAssertEqual(permit.basis, .selfQualification, "\(rate)")
            XCTAssertNil(t.gateFailure(context(rate: rate)), "\(rate): the permit satisfies the gate; it does not arm")
            XCTAssertFalse(t.isArmed, "\(rate): issuing never arms")
        }
    }

    func testNoPermitWithoutAnEngineBaselineAndProductionRegistryHoldsNone() throws {
        XCTAssertTrue(MIMOTreatmentQualificationRegistry.production.engineBaselines.isEmpty, "E22 files the baselines")
        let (t, design) = try controller(rate: 48_000)
        let none = issue(t, design, evidence(rate: 48_000), rate: 48_000, registry: .production)
        XCTAssertEqual(failures(none), [.engineBaselineMissing(decimation: design.filters.decimation)])
        let incomplete = issue(t, design, evidence(rate: 48_000), rate: 48_000, registry: registry(for: design, complete: false))
        XCTAssertEqual(failures(incomplete), [.engineBaselineMissing(decimation: design.filters.decimation)])
        XCTAssertNil(t.permit)
    }

    func testNoPermitWithoutTheTreatedRepeatMeasurement() throws {
        let (t, design) = try controller(rate: 48_000)
        let r = issue(t, design, evidence(rate: 48_000), rate: 48_000, verification: decay(repeatMeasured: false))
        XCTAssertEqual(r, .failure(.verificationFailed([.repeatMeasurementMissing])))
    }

    // MARK: Each criterion missed alone

    private func assertRefused(
        _ mutate: (inout MIMOTreatmentSelfQualificationEvidence) -> Void, _ expected: MIMOTreatmentSelfQualificationFailure,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for rate in [48_000.0, 384_000.0] {
            let (t, design) = try controller(rate: rate)
            var e = evidence(rate: rate)
            mutate(&e)
            let f = failures(issue(t, design, e, rate: rate))
            XCTAssertTrue(f.contains(expected), "\(rate): \(f)", file: file, line: line)
            XCTAssertNil(t.permit, file: file, line: line)
            XCTAssertFalse(expected.reason.isEmpty, file: file, line: line)
        }
    }

    func testEachPreconditionMissedAloneIsRefusedByName() throws {
        try assertRefused({ $0.seats[2].included = false }, .tooFewSeats(included: 2))
        try assertRefused({ $0.sourceCount = 9 }, .sourceCountOutOfRange(9))
        try assertRefused({ $0.sourceCount = 1 }, .sourceCountOutOfRange(1))
        try assertRefused({ $0.headroomBudgetedSources = 1 }, .headroomNotBudgeted)
        try assertRefused({ $0.protectedLaneCount = 1 }, .protectionMissing(protected: 1, lanes: 2))
        try assertRefused({ $0.quietZoneActuatorPresent = true }, .quietZoneActuatorOnGraph)
    }

    func testEachMeasurementQualityCriterionMissedAloneIsRefused() throws {
        try assertRefused({ $0.captures[0].sampleRate = 44_100 }, .wrongSampleRate(seat: 0))
        try assertRefused({ $0.captures[1].microphoneUID = "MIC-2" }, .microphoneNotOne)
        try assertRefused({ $0.captures[0].microphoneUID = nil }, .microphoneNotOne)
        try assertRefused({ $0.captures.removeLast() }, .capturesIncomplete)
        try assertRefused({ $0.captures[2].reliableBands = 4 }, .tooFewReliableBands(seat: 1, bands: 4))
        try assertRefused({ $0.captures[0].thirdOctaveSNRDB[3] = 29.5 }, .snrTooLow(seat: 0, snrDB: 29.5))
    }

    func testPredictionCriteriaMissedAloneAreRefused() throws {
        try assertRefused({ $0.predictedDecay = nil }, .predictionMissing)
        try assertRefused({ $0.predictedDecay = self.decay(improvement: 0.05) }, .predictedDecayFailed)
        try assertRefused(
            { $0.predictedDecay = self.decay(failures: [.decayWorsened(phase: .predicted, seat: 0, bandHz: 63, ratio: 1.3)]) },
            .predictedDecayFailed)
        try assertRefused({ $0.predictedSpatial = self.spatial(improvement: 0.4) }, .predictedSpatialFailed("improvement too small"))
    }

    func testBudgetsAreComputedAndMissedAloneAreRefused() throws {
        try assertRefused({ $0.budgets[0].headroomReserveDB = 2.9 }, .headroomReserveTooSmall(source: 0, reserveDB: 2.9))
        try assertRefused({ $0.budgets[1].excursionLimitHz = nil }, .excursionLimitMissing(source: 1))
        try assertRefused({ $0.budgets[0].effortSlopeBelowLimitDBPerOctave = 11 }, .excursionSlopeTooShallow(source: 0, slope: 11))
        try assertRefused({ $0.thermalDeltaRMSDB = -5.5 }, .thermalBudgetExceeded(deltaDB: -5.5))
        try assertRefused({ $0.thermalDeltaRMSDB = nil }, .thermalBudgetExceeded(deltaDB: nil))
    }

    func testBoundaryValuesPass() throws {
        let (t, design) = try controller(rate: 96_000)
        var e = evidence(rate: 96_000)
        e.budgets[0].headroomReserveDB = 3.0
        e.budgets[1].effortSlopeBelowLimitDBPerOctave = 12
        e.thermalDeltaRMSDB = -6
        e.captures[0].reliableBands = 5
        e.captures[0].thirdOctaveSNRDB[0] = 30
        t.updateSelfQualificationEvidence(e)
        guard case .success = issue(t, design, e, rate: 96_000) else { return XCTFail("boundaries must pass") }
    }

    func testNothingInTheEvidenceIsADeclaration() {
        // The old safety declaration is not part of the evidence type; booleans cannot satisfy a criterion.
        let declaration = MIMORoomTreatmentSourceSafetyDeclaration(
            source: .subwoofer(0), safeMinimumFrequencyHz: 20, safeMaximumFrequencyHz: 200, reservedHeadroomDB: 6,
            excursionModelConfirmed: true, thermalModelConfirmed: true, finalProtectionChainConfirmed: true)
        XCTAssertTrue(declaration.validate(requiredLowHz: 30, requiredHighHz: 150))
        var e = evidence(rate: 48_000)
        e.budgets = []
        XCTAssertTrue(
            MIMOTreatmentSelfQualification.evaluate(
                e, decimation: 16, registry: MIMOTreatmentQualificationRegistry(
                    records: [], engineBaselines: [MIMOTreatmentEngineBaseline(
                        decimation: 16, recordedAt: Date(), longRunThermalPassed: true, protectionChainPassed: true, stopStartPassed: true,
                        unplugReplugPassed: true, sleepWakePassed: true, audibleArtifactCheckPassed: true)])
            ).contains(.headroomNotBudgeted), "a declaration cannot stand in for computed budgets")
    }

    // MARK: Flag off

    func testFlagOffBehavesAsToday() throws {
        let (t, design) = try controller(rate: 48_000, sq: false)
        let r = issue(t, design, evidence(rate: 48_000), rate: 48_000)
        XCTAssertEqual(r, .failure(.hardwareAcceptanceRequired))
        XCTAssertNil(t.permit)
        XCTAssertFalse(FeatureFlag.selfQualification.resolvedDefault)
        XCTAssertTrue(FeatureFlag.all.contains(.selfQualification))
        // A class qualification still wins before self-qualification is even considered.
        let key = MIMOGraphTreatment.classKey(stage: design)
        let reg = MIMOTreatmentQualificationRegistry(records: [
            MIMOTreatmentClassQualification(
                key: key, qualifiedAt: Date(), longRunThermalPassed: true, protectionChainPassed: true, stopStartPassed: true,
                unplugReplugPassed: true, sleepWakePassed: true, audibleArtifactCheckPassed: true)])
        guard case .success(let permit) = issue(t, design, nil, rate: 48_000, registry: reg) else { return XCTFail() }
        XCTAssertEqual(permit.basis, .classQualification)
        XCTAssertEqual(permit.fingerprint, t.currentFingerprint(design, context(rate: 48_000), selfQualified: false))
    }

    func testFlagOnWithoutEvidenceIsRefusedAndTurningTheFlagOffVoidsAPermit() throws {
        let (t, design) = try controller(rate: 48_000)
        XCTAssertEqual(failures(issue(t, design, nil, rate: 48_000)), [.evidenceMissing])
        let e = evidence(rate: 48_000)
        t.updateSelfQualificationEvidence(e)
        guard case .success = issue(t, design, e, rate: 48_000) else { return XCTFail() }
        XCTAssertNil(t.gateFailure(context(rate: 48_000)))
        let off = MIMOGraphTreatment(flags: flags(selfQualification: false))
        off.stage(design)
        off.setPermit(t.permit)
        XCTAssertEqual(off.gateFailure(context(rate: 48_000)), .noPermit)
    }

    // MARK: SQ7: every bound field changed alone voids the permit

    func testEveryBoundFieldChangedAloneVoidsTheSelfQualifiedPermit() throws {
        let rate = 48_000.0
        let (t, design) = try controller(rate: rate)
        let e = evidence(rate: rate)
        t.updateSelfQualificationEvidence(e)
        guard case .success = issue(t, design, e, rate: rate) else { return XCTFail() }
        let base = context(rate: rate)
        XCTAssertNil(t.gateFailure(base))

        // Engine-held: ceiling, protection settings and domain versions travel in the binding string.
        var changedEngine = base
        changedEngine.selfQualificationBinding = "engine-2"
        XCTAssertEqual(t.gateFailure(changedEngine), .fingerprintMismatch)
        let a = MIMOTreatmentSelfQualification.engineBinding(protection: OutputProtectionSettings())
        var protection = OutputProtectionSettings()
        protection.lanes[0] = OutputProtectionSettings.Lane(enabled: true, ceilingDB: -9, trimDB: 0)
        XCTAssertNotEqual(a, MIMOTreatmentSelfQualification.engineBinding(protection: protection))
        XCTAssertTrue(a.contains("mimo=\(N60_MIMO_ABI_VERSION)") && a.contains("graph=\(N60_GRAPH_ABI_VERSION)")
            && a.contains("headroom=\(N60_HEADROOM_ABI_VERSION)") && a.contains("limit=\(UnifiedGraphOutputProtection.hardLimitCeilingDB)"))

        // Graph-held (existing fingerprint): trim, output UID, lane count.
        var trim = base; trim.outputTrimsDB = [0, -1]
        XCTAssertEqual(t.gateFailure(trim), .fingerprintMismatch)
        var uid = base; uid.outputDeviceUID = "OUT-2"
        XCTAssertEqual(t.gateFailure(uid), .fingerprintMismatch)
        var lanes = base; lanes.laneCount = 3
        XCTAssertEqual(t.gateFailure(lanes), .fingerprintMismatch)

        // Evidence-held: seat count, include, weight, capture digest, microphone.
        let mutations: [(String, (inout MIMOTreatmentSelfQualificationEvidence) -> Void)] = [
            ("seat count", { $0.seats.append(.init(id: UUID(), included: false, weight: 1)) }),
            ("include", { $0.seats[0].included = false }),
            ("weight", { $0.seats[1].weight = 0.5 }),
            ("capture digest", { $0.captures[3].digest = "other" }),
            ("microphone", { for i in $0.captures.indices { $0.captures[i].microphoneUID = "MIC-2" } }),
        ]
        for (name, mutate) in mutations {
            var changed = e
            mutate(&changed)
            t.updateSelfQualificationEvidence(changed)
            XCTAssertEqual(t.gateFailure(base), .fingerprintMismatch, name)
            t.updateSelfQualificationEvidence(e)
            XCTAssertNil(t.gateFailure(base), "\(name) restored")
        }
    }

    func testAnArmedSelfQualifiedTreatmentDisarmsWhenTheEvidenceChanges() async throws {
        let rate = 48_000.0
        let (t, design) = try controller(rate: rate)
        let e = evidence(rate: rate)
        t.updateSelfQualificationEvidence(e)
        guard case .success = issue(t, design, e, rate: rate) else { return XCTFail() }
        try await t.requestArm(context: context(rate: rate), refresh: { self.context(rate: rate) })
        XCTAssertTrue(t.isArmed, "the user's arm action, with every gate")
        var changed = e
        changed.seats[0].weight = 0.25
        t.updateSelfQualificationEvidence(changed)
        t.observe(context: context(rate: rate), readback: nil)
        XCTAssertFalse(t.isArmed)
    }
}
