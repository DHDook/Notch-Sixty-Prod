import XCTest
@testable import NotchSixty

/// E19 S3: the Swift face of the MIMO design core. Flag off refuses, flag on equals a direct core call bit for bit,
/// the realisation checks fire, and every error names its source or seat.
@MainActor
final class MIMORoomTreatmentCoreDesignerTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    /// Two speakers and two seats: a direct arrival plus two decaying modes (40 and 70 Hz, 0.8 s T60) that each
    /// source and seat excites with its own gain and phase.
    private func plants(rate: Double, sources: Int = 2, seats: Int = 2) -> [[MIMOTreatmentPlant?]] {
        let length = Int(rate * 1.2)
        return (0..<sources).map { source in
            (0..<seats).map { seat in
                var ir = [Float](repeating: 0, count: length)
                let delay = Int(rate * (0.002 + 0.0003 * Double(source) + 0.0004 * Double(seat)))
                ir[delay] = 1
                let alpha = 6.907755 / (0.8 * rate)
                for (modeIndex, hz) in [40.0, 70.0].enumerated() {
                    let gain = 0.02 * (1 + 0.3 * Double((source + seat + modeIndex) % 3))
                    let phase = 0.7 * Double(source * 2 + seat + modeIndex)
                    for n in 0..<length {
                        let t = Double(n)
                        let v = gain * exp(-alpha * t) * sin(2 * Double.pi * hz * t / rate + phase)
                        ir[n] += Float(v)
                    }
                }
                return MIMOTreatmentPlant(program: ir, injection: nil, arrivalSeconds: nil)
            }
        }
    }

    private func request(rate: Double, tau: Double = 0.015) -> MIMOTreatmentRequest {
        var request = MIMOTreatmentRequest(
            sampleRate: rate,
            sources: [MIMOTreatmentSourceSpec](repeating: MIMOTreatmentSourceSpec(), count: 2),
            seats: [MIMOTreatmentSeatSpec](repeating: MIMOTreatmentSeatSpec(), count: 2),
            plants: plants(rate: rate)
        )
        request.tauSeconds = tau
        if let low = try? MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate) {
            request.taps = Int((1.0 * low.lowRateHz).rounded())
        }
        return request
    }

    /// The synthetic room here is a small under-determined one, so the in-band match is judged loosely; the strict
    /// 0.25 dB gate on the reference room at the eight rates is `n60core_mimo_realise` (core/tests).
    private var loose: MIMOTreatmentRealisationLimits {
        var limits = MIMOTreatmentRealisationLimits.standard
        limits.maximumDeviationDB = 3
        return limits
    }

    private func flags(on: Bool) -> FeatureFlags {
        let suite = "MIMOCoreDesignerTests.\(UUID().uuidString)"
        return FeatureFlags(
            defaults: UserDefaults(suiteName: suite) ?? .standard,
            policy: .launchArgumentOnly,
            arguments: on ? [FeatureFlags.launchArgument, FeatureFlag.mimoTreatment.id] : []
        )
    }

    func testFlagOffRefusesAndFlagOnDesigns() throws {
        let request = request(rate: 48_000)
        XCTAssertThrowsError(try MIMORoomTreatmentCoreDesigner.design(request, flags: flags(on: false))) {
            XCTAssertEqual($0 as? MIMORoomTreatmentCoreDesignError, .featureOff)
        }
        let result = try MIMORoomTreatmentCoreDesigner.design(request, flags: flags(on: true), limits: loose)
        XCTAssertEqual(result.filters.sourceCount, 2)
        XCTAssertEqual(result.filters.decimation, 16)
        XCTAssertFalse(FeatureFlag.mimoTreatment.defaultEnabled)
        XCTAssertTrue(FeatureFlag.all.contains(.mimoTreatment))
    }

    func testWrapperEqualsDirectCoreCallBitExactlyAtEveryRate() throws {
        for rate in rates {
            let request = request(rate: rate)
            let result = try MIMORoomTreatmentCoreDesigner.designUnchecked(request, limits: loose)

            var problem = n60_mimo_problem()
            n60_mimo_defaults(rate, 2, 2, &problem)
            problem.tau_seconds = request.tauSeconds
            problem.decay_seconds = request.decaySeconds
            problem.taps = UInt32(request.taps)
            var source = n60_mimo_source(
                excluded: 0, support_low_hz: 25, support_high_hz: 150, excursion_corner_hz: 0,
                effort_limit_db: 9, gain_limit_db: 9
            )
            for index in 0..<2 { _ = n60_mimo_problem_set_source(&problem, UInt32(index), &source) }
            var pointers: [UnsafeMutablePointer<Float>] = []
            defer { pointers.forEach { $0.deallocate() } }
            for s in 0..<2 {
                for m in 0..<2 {
                    let ir = try XCTUnwrap(request.plants[s][m]).program
                    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: ir.count)
                    pointer.initialize(from: ir, count: ir.count)
                    pointers.append(pointer)
                    _ = n60_mimo_problem_set_plant(&problem, UInt32(s), UInt32(m), pointer, UInt64(ir.count), nil, 0, -1)
                }
            }
            var taps = [Float](repeating: 0, count: 4 * request.taps)
            var info = n60_mimo_info()
            let status = n60_mimo_design(&problem, &taps, UInt64(taps.count), &info)
            XCTAssertEqual(status, N60_MIMO_OK, "rate \(rate)")
            XCTAssertEqual(result.filters.taps, taps, "rate \(rate): wrapper taps differ from the core")
            XCTAssertEqual(result.filters.lowRateHz, info.low_rate_hz, accuracy: 0)
        }
    }

    func testRealisationEdgeAndOvershootLimitsHoldAtEveryRate() throws {
        for rate in rates {
            let result = try MIMORoomTreatmentCoreDesigner.designUnchecked(request(rate: rate), limits: loose)
            XCTAssertTrue(result.realisation.maximumDeviationDB.isFinite, "rate \(rate)")
            XCTAssertLessThanOrEqual(result.realisation.edgeEnergyFraction, 0.12, "rate \(rate)")
            for overshoot in result.realisation.gainOvershootDB {
                XCTAssertLessThanOrEqual(overshoot, 0.35, "rate \(rate)")
            }
        }
    }

    func testTightLimitsRefuseAndName() throws {
        let request = request(rate: 48_000)
        var deviation = MIMOTreatmentRealisationLimits.standard
        deviation.maximumDeviationDB = 0.0001
        XCTAssertThrowsError(try MIMORoomTreatmentCoreDesigner.designUnchecked(request, limits: deviation)) {
            guard case .realisationDeviation = $0 as? MIMORoomTreatmentCoreDesignError else {
                return XCTFail("expected realisationDeviation, got \($0)")
            }
        }
        var edge = MIMOTreatmentRealisationLimits.standard
        edge.maximumEdgeEnergyFraction = -1
        XCTAssertThrowsError(try MIMORoomTreatmentCoreDesigner.designUnchecked(request, limits: edge)) {
            guard case .edgeEnergyTooHigh = $0 as? MIMORoomTreatmentCoreDesignError else {
                return XCTFail("expected edgeEnergyTooHigh, got \($0)")
            }
        }
        var overshoot = MIMOTreatmentRealisationLimits.standard
        overshoot.maximumOvershootDB = -100
        XCTAssertThrowsError(try MIMORoomTreatmentCoreDesigner.designUnchecked(request, limits: overshoot)) {
            guard case .overshoot(let kind, _, _, _) = $0 as? MIMORoomTreatmentCoreDesignError else {
                return XCTFail("expected overshoot, got \($0)")
            }
            XCTAssertEqual(kind, "gain")
        }
    }

    func testRequestErrorsNameTheSourceAndSeat() throws {
        var missing = request(rate: 48_000)
        missing.plants[1][0] = nil
        XCTAssertThrowsError(try MIMORoomTreatmentCoreDesigner.designUnchecked(missing)) {
            XCTAssertEqual($0 as? MIMORoomTreatmentCoreDesignError, .missingPlant(source: 1, seat: 0))
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("Source 2") == true)
        }
        // An excluded source or seat needs no measurement.
        var excluded = request(rate: 48_000)
        excluded.plants[1] = [nil, nil]
        excluded.sources[1].excluded = true
        do {
            _ = try MIMORoomTreatmentCoreDesigner.designUnchecked(excluded)
        } catch {
            // The synthetic room may not suit one source; the point is that nothing is reported missing.
            guard case .missingPlant = error as? MIMORoomTreatmentCoreDesignError else { return }
            XCTFail("an excluded source must not need a measurement")
        }

        var late = request(rate: 48_000)
        late.tauSeconds = 0.021
        XCTAssertThrowsError(try MIMORoomTreatmentCoreDesigner.designUnchecked(late)) {
            XCTAssertEqual($0 as? MIMORoomTreatmentCoreDesignError, .tauOutOfRange(0.021))
        }
        var rate = request(rate: 48_000)
        rate.sampleRate = 8_000
        XCTAssertThrowsError(try MIMORoomTreatmentCoreDesigner.designUnchecked(rate)) {
            XCTAssertEqual($0 as? MIMORoomTreatmentCoreDesignError, .sampleRateUnsupported(8_000))
        }
        var shape = request(rate: 48_000)
        shape.plants.removeLast()
        XCTAssertThrowsError(try MIMORoomTreatmentCoreDesigner.designUnchecked(shape))
    }

    func testDefaultTauAndShortTauGate() {
        XCTAssertEqual(MIMOTreatmentRequest(sampleRate: 48_000, sources: [], seats: [], plants: []).tauSeconds, 0.015)
        let limits = MIMOTreatmentRealisationLimits.standard
        XCTAssertEqual(limits.deviationGateDB(tau: 0.015), 0.25)
        XCTAssertEqual(limits.deviationGateDB(tau: 0.010), 0.25)
        XCTAssertEqual(limits.deviationGateDB(tau: 0.005), 0.35)
        XCTAssertNil(MIMOTreatmentRealisationLimits.shortTauNote(tau: 0.010))
        XCTAssertTrue(try XCTUnwrap(MIMOTreatmentRealisationLimits.shortTauNote(tau: 0.005)).contains("15 ms"))
    }

    func testPreEnergyIsShownAndAdvisesRaisingTau() throws {
        let late = try MIMORoomTreatmentCoreDesigner.designUnchecked(request(rate: 48_000, tau: 0.02), limits: loose)
        XCTAssertTrue(late.summary.advice.isEmpty, "tau at the 20 ms limit has nothing to raise")
        XCTAssertLessThan(late.summary.preEnergyDB, -12)
        // With no bass time target the solution holds too much before t = 0: refused, with a larger tau suggested.
        XCTAssertThrowsError(try MIMORoomTreatmentCoreDesigner.designUnchecked(request(rate: 48_000, tau: 0))) {
            guard case .tooMuchBeforeZero(let pre, let suggested) = $0 as? MIMORoomTreatmentCoreDesignError else {
                return XCTFail("expected tooMuchBeforeZero, got \($0)")
            }
            XCTAssertGreaterThan(pre, -12)
            XCTAssertEqual(suggested, 0.010)
        }
        XCTAssertEqual(MIMORoomTreatmentCoreDesigner.suggestedTau(from: 0), 0.010)
        XCTAssertEqual(try XCTUnwrap(MIMORoomTreatmentCoreDesigner.suggestedTau(from: 0.012)), 0.017, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(MIMORoomTreatmentCoreDesigner.suggestedTau(from: 0.018)), 0.020, accuracy: 1e-12)
        XCTAssertNil(MIMORoomTreatmentCoreDesigner.suggestedTau(from: 0.020))
        let message = MIMORoomTreatmentCoreDesignError.tooMuchBeforeZero(preEnergyDB: -9, suggestedTauSeconds: 0.01)
            .errorDescription
        XCTAssertTrue(message?.contains("10 ms") == true)
    }

    /// E19 S5: the headroom budget reaches the core as each source's `gainLimitDB`, and an impossible one refuses by name.
    func testHeadroomBudgetSetsLimitsAndRefusesByName() throws {
        func headroom(peak: Double, ceiling: Double) -> OutputHeadroom {
            OutputHeadroom(lane: 0, peakGainDB: peak, peakHz: 0, ceilingDB: ceiling, neededDB: 0, currentTrimDB: 0, incomplete: [])
        }
        XCTAssertEqual(MIMOTreatmentSourceSpec.gainBudgetDB(after: headroom(peak: 0, ceiling: 0)), 2.5, accuracy: 1e-9)
        XCTAssertEqual(MIMOTreatmentSourceSpec.gainBudgetDB(after: headroom(peak: 4, ceiling: -1), trimAllowanceDB: 0), -5.5, accuracy: 1e-9)

        let base = request(rate: 48_000)
        let budgeted = try base.applyingHeadroomBudgets([headroom(peak: 0, ceiling: 0), nil])
        XCTAssertEqual(budgeted.sources[0].gainLimitDB, 2.5, accuracy: 1e-9)
        XCTAssertEqual(budgeted.sources[1].gainLimitDB, base.sources[1].gainLimitDB)
        XCTAssertThrowsError(try base.applyingHeadroomBudgets([headroom(peak: 0, ceiling: 0), headroom(peak: 6, ceiling: 0)])) {
            XCTAssertEqual($0 as? MIMORoomTreatmentCoreDesignError, .headroom(source: 1))
        }
    }
}
