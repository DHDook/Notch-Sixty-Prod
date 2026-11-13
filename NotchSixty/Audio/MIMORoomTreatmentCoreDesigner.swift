import Foundation

/// E19 S3: Swift face of the portable MIMO treatment design core (`n60/mimo.h`, design notes 3 and 4).
///
/// Control plane only: every call allocates and runs off the audio thread (an analysis task), never from a render
/// callback. The maths is in libn60core; this type marshals the plants, calls the core, checks the realised taps
/// against the solved response and maps core status codes to errors a screen can name.
///
/// Feature flag `e19.mimo-treatment` (default off): `design(_:flags:)` refuses with `.featureOff` while it is off, and
/// the existing `MIMORoomTreatmentDesigner` / `MIMORoomTreatmentFIRCompiler` path is untouched either way. Nothing
/// in the app calls this yet (wiring is S6, the screen is S8); it never produces output by itself, and live output
/// still needs a permit and the arm (design note 8).
struct MIMOTreatmentSourceSpec: Equatable, Sendable {
    var excluded = false
    var supportLowHz = 25.0
    var supportHighHz = 150.0
    /// Effort falls 12 dB/octave below this corner; 0 uses `supportLowHz`.
    var excursionCornerHz = 0.0
    var effortLimitDB = 9.0
    var gainLimitDB = 9.0
}

struct MIMOTreatmentSeatSpec: Equatable, Sendable {
    var included = true
    var weight = 1.0
}

/// One raw per-output impulse response at one seat, already through the known downstream chain (design note 2).
struct MIMOTreatmentPlant: Equatable, Sendable {
    var program: [Float]
    /// The control path; nil means the same as `program` (unrouted).
    var injection: [Float]?
    /// Onset of the direct sound in seconds. nil detects it as the largest sample (G6: the E24 onset replaces it).
    var arrivalSeconds: Double?
}

struct MIMOTreatmentRequest: Sendable {
    var sampleRate: Double
    var sources: [MIMOTreatmentSourceSpec]
    var seats: [MIMOTreatmentSeatSpec]
    var primarySeat = 0
    /// Bass time target, 0 to 20 ms (D1). Default 15 ms (E19 G11, owner decision of 10 Nov 2026).
    var tauSeconds = MIMOTreatmentRealisationLimits.recommendedTauSeconds
    /// T_target as a T60, 0.05 to 2 s (D2 supplies the default from the room).
    var decaySeconds = 0.3
    static let defaultTaps = 4_096
    var taps = MIMOTreatmentRequest.defaultTaps
    var regularisation = 1e-3
    var thermalLimitDB = -6.0
    var causalityLimitDB = -12.0
    /// `plants[source][seat]`; nil is a missing measurement, refused by name unless the source or seat is excluded.
    var plants: [[MIMOTreatmentPlant?]]
}

/// Realisation limits: the existing PR74 overshoot limits plus the in-band match of design note 3.
struct MIMOTreatmentRealisationLimits: Equatable, Sendable {
    var maximumDeviationDB = 0.25
    /// Gate used when the bass time target is below `shortTauSeconds`. Measured worst case over the eight standard
    /// rates and tau 0 to 10 ms is 0.28 dB (48 kHz, tau 0), so 0.35 dB leaves a margin (G11).
    var shortTauMaximumDeviationDB = 0.35
    static let shortTauSeconds = 0.010
    static let recommendedTauSeconds = 0.015

    func deviationGateDB(tau: Double) -> Double {
        tau < Self.shortTauSeconds - 1e-9 ? shortTauMaximumDeviationDB : maximumDeviationDB
    }

    /// Shown beside the bass time control when the target is below 10 ms; nil otherwise.
    static func shortTauNote(tau: Double) -> String? {
        guard tau < shortTauSeconds - 1e-9 else { return nil }
        return "A bass time target below 10 ms allows a slightly looser match. 15 ms is recommended."
    }
    var maximumEdgeEnergyFraction = MIMORoomTreatmentFIRCompileConfiguration.conservative.maximumEdgeEnergyFraction
    var maximumOvershootDB = MIMORoomTreatmentFIRCompileConfiguration.conservative.maximumCoefficientOvershootDB
    /// Energy before t = 0 above this (re total) earns advice to raise the bass time target.
    var adviseAbovePreEnergyDB = -30.0

    static let standard = MIMOTreatmentRealisationLimits()
}

struct MIMOTreatmentRealisation: Equatable, Sendable {
    var maximumDeviationDB: Double
    var maximumDeviationHz: Double
    var edgeEnergyFraction: Double
    var gainOvershootDB: [Double]
    var effortOvershootDB: [Double]
}

/// What a screen shows about a design (rendered by S8).
struct MIMOTreatmentDesignSummary: Equatable, Sendable {
    var preEnergyDB: Double
    var maximumDeviationDB: Double
    var regularisationSteps: Int
    var peakGainDB: [Double]
    var thermalDB: [Double]
    /// Plain-language advice, empty when the design is comfortable.
    var advice: [String]
}

struct MIMOTreatmentFilterSet: Equatable, Sendable {
    let sampleRate: Double
    let lowRateHz: Double
    let decimation: Int
    let sourceCount: Int
    let tapCount: Int
    let tauSeconds: Double
    /// Flattened `[output source][input feed][tap]` at the low rate; the delta on top of the tau delay.
    let taps: [Float]
    /// Solved per-bin response (re, im interleaved), `[source][feed][bin]`, on a 0.5 Hz grid from `gridLowHz`.
    let solved: [Float]
    let gridLowHz: Double
    let gridBins: Int
}

struct MIMOTreatmentDesignResult: Equatable, Sendable {
    let filters: MIMOTreatmentFilterSet
    let realisation: MIMOTreatmentRealisation
    let summary: MIMOTreatmentDesignSummary
}

enum MIMORoomTreatmentCoreDesignError: Error, Equatable, LocalizedError {
    case featureOff
    case invalidRequest(String)
    case sampleRateUnsupported(Double)
    case tauOutOfRange(Double)
    case missingPlant(source: Int, seat: Int)
    case supportRangeInvalid
    case plantsUnusable
    case headroom(source: Int)
    case thermal(source: Int)
    case tooMuchBeforeZero(preEnergyDB: Double, suggestedTauSeconds: Double?)
    case realisationDeviation(actualDB: Double, atHz: Double, maximumDB: Double)
    case edgeEnergyTooHigh(actual: Double, maximum: Double)
    case overshoot(kind: String, source: Int, actualDB: Double, maximumDB: Double)
    case core(Int32)

    var errorDescription: String? {
        switch self {
        case .featureOff:
            return "MIMO room treatment is switched off."
        case .invalidRequest(let reason):
            return "MIMO treatment request is invalid: \(reason)."
        case .sampleRateUnsupported(let rate):
            return "MIMO treatment does not support \(rate) Hz."
        case .tauOutOfRange(let tau):
            return "The bass time target of \(tau * 1_000) ms is outside 0 to 20 ms."
        case .missingPlant(let source, let seat):
            return "Source \(source + 1) has no measurement at seat \(seat + 1). Measure it or exclude it."
        case .supportRangeInvalid:
            return "A source's support range is invalid, or every source is excluded."
        case .plantsUnusable:
            return "The measurements carry no energy in the treatment band."
        case .headroom(let source):
            return "Source \(source + 1) cannot meet its headroom budget at any regularisation."
        case .thermal(let source):
            return "Source \(source + 1) cannot meet the thermal budget (treatment at most 6 dB under the program)."
        case .tooMuchBeforeZero(let pre, let suggested):
            let hint = suggested.map { " Raise the bass time target to about \(Int(($0 * 1_000).rounded())) ms." } ?? ""
            return "The solution holds \(Int(pre.rounded())) dB of energy before t = 0, which a causal filter cannot realise.\(hint)"
        case .realisationDeviation(let actual, let hz, let maximum):
            return "The compiled filter differs from the solved response by \(actual) dB at \(hz) Hz, above \(maximum) dB."
        case .edgeEnergyTooHigh(let actual, let maximum):
            return "MIMO filter energy near the end of the taps is \(actual), above \(maximum)."
        case .overshoot(let kind, let source, let actual, let maximum):
            return "Source \(source + 1) \(kind) overshoots its limit by \(actual) dB, above \(maximum) dB."
        case .core(let status):
            return "MIMO design core returned status \(status)."
        }
    }
}

extension MIMOTreatmentSourceSpec {
    /// The gain budget (dB) a source may reach, from the headroom of what follows the MIMO stage on its output.
    /// `headroom` is the `HeadroomModel` result for that output with the MIMO stage left out; the treatment may cost the
    /// program up to `trimAllowanceDB` of output trim (the assistant's Apply). Negative: even the untreated path does not fit.
    static func gainBudgetDB(
        after headroom: OutputHeadroom,
        trimAllowanceDB: Double = N60_HEADROOM_MIMO_TRIM_ALLOWANCE_DB
    ) -> Double {
        n60_headroom_mimo_budget_db(headroom.ceilingDB, trimAllowanceDB, headroom.peakGainDB)
    }
}

extension MIMOTreatmentRequest {
    /// This request with every included source's `gainLimitDB` set to the lower of its own limit and the headroom budget
    /// of its output. `headrooms[s]` is nil when the chain is unknown (the source keeps its own limit). A source whose
    /// budget is below 0 dB refuses by name instead of designing against an impossible limit.
    func applyingHeadroomBudgets(
        _ headrooms: [OutputHeadroom?],
        trimAllowanceDB: Double = N60_HEADROOM_MIMO_TRIM_ALLOWANCE_DB
    ) throws -> MIMOTreatmentRequest {
        var out = self
        for index in out.sources.indices where !out.sources[index].excluded && index < headrooms.count {
            guard let headroom = headrooms[index] else { continue }
            let budget = MIMOTreatmentSourceSpec.gainBudgetDB(after: headroom, trimAllowanceDB: trimAllowanceDB)
            guard budget >= 0 else { throw MIMORoomTreatmentCoreDesignError.headroom(source: index) }
            out.sources[index].gainLimitDB = min(out.sources[index].gainLimitDB, budget)
        }
        return out
    }
}

enum MIMORoomTreatmentCoreDesigner {
    static var abiVersion: UInt32 { n60_mimo_abi_version() }

    /// Decimation factor and low rate for a device rate (D = 16, 32, 64, 128 by family).
    static func lowRate(forSampleRate sampleRate: Double) throws -> (decimation: Int, lowRateHz: Double) {
        var decimation: UInt32 = 0
        var low = 0.0
        guard n60_mimo_low_rate(sampleRate, &decimation, &low) == N60_MIMO_OK else {
            throw MIMORoomTreatmentCoreDesignError.sampleRateUnsupported(sampleRate)
        }
        return (Int(decimation), low)
    }

    /// Flag-gated entry. Off: refuses, and nothing else in the app changes.
    @MainActor
    static func design(
        _ request: MIMOTreatmentRequest,
        flags: FeatureFlags,
        limits: MIMOTreatmentRealisationLimits = .standard
    ) throws -> MIMOTreatmentDesignResult {
        guard flags.isEnabled(.mimoTreatment) else {
            throw MIMORoomTreatmentCoreDesignError.featureOff
        }
        return try designUnchecked(request, limits: limits)
    }

    /// The same design without the flag check (tests and the worker that the gated entry calls).
    static func designUnchecked(
        _ request: MIMOTreatmentRequest,
        limits: MIMOTreatmentRealisationLimits = .standard
    ) throws -> MIMOTreatmentDesignResult {
        let sourceCount = request.sources.count
        let seatCount = request.seats.count
        guard sourceCount >= 1, sourceCount <= Int(N60_MIMO_MAX_SOURCES) else {
            throw MIMORoomTreatmentCoreDesignError.invalidRequest("source count \(sourceCount)")
        }
        guard seatCount >= 1, seatCount <= Int(N60_MIMO_MAX_SEATS) else {
            throw MIMORoomTreatmentCoreDesignError.invalidRequest("seat count \(seatCount)")
        }
        guard request.plants.count == sourceCount, request.plants.allSatisfy({ $0.count == seatCount }) else {
            throw MIMORoomTreatmentCoreDesignError.invalidRequest("plants must be [source][seat]")
        }
        guard request.primarySeat >= 0, request.primarySeat < seatCount else {
            throw MIMORoomTreatmentCoreDesignError.invalidRequest("primary seat")
        }
        guard request.tauSeconds.isFinite, request.tauSeconds >= 0,
              request.tauSeconds <= N60_MIMO_MAX_TAU_SECONDS else {
            throw MIMORoomTreatmentCoreDesignError.tauOutOfRange(request.tauSeconds)
        }
        let (decimation, lowRate) = try lowRate(forSampleRate: request.sampleRate)

        var problem = n60_mimo_problem()
        n60_mimo_defaults(request.sampleRate, UInt32(sourceCount), UInt32(seatCount), &problem)
        problem.primary_seat = UInt32(request.primarySeat)
        problem.tau_seconds = request.tauSeconds
        problem.decay_seconds = request.decaySeconds
        problem.taps = UInt32(clamping: request.taps)
        problem.regularisation = request.regularisation
        problem.thermal_limit_db = request.thermalLimitDB
        problem.causality_limit_db = request.causalityLimitDB

        for (index, spec) in request.sources.enumerated() {
            var source = n60_mimo_source(
                excluded: spec.excluded ? 1 : 0,
                support_low_hz: spec.supportLowHz,
                support_high_hz: spec.supportHighHz,
                excursion_corner_hz: spec.excursionCornerHz,
                effort_limit_db: spec.effortLimitDB,
                gain_limit_db: spec.gainLimitDB
            )
            _ = n60_mimo_problem_set_source(&problem, UInt32(index), &source)
        }
        for (index, spec) in request.seats.enumerated() {
            var seat = n60_mimo_seat(included: spec.included ? 1 : 0, weight: spec.weight)
            _ = n60_mimo_problem_set_seat(&problem, UInt32(index), &seat)
        }

        // The core reads raw pointers during the call: copy each plant into storage that outlives it.
        var allocations: [UnsafeMutablePointer<Float>] = []
        defer { allocations.forEach { $0.deallocate() } }
        func stable(_ values: [Float]) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(values.count, 1))
            pointer.initialize(from: values, count: values.count)
            allocations.append(pointer)
            return pointer
        }
        for source in 0..<sourceCount where !request.sources[source].excluded {
            for seat in 0..<seatCount where request.seats[seat].included {
                guard let plant = request.plants[source][seat], !plant.program.isEmpty else {
                    throw MIMORoomTreatmentCoreDesignError.missingPlant(source: source, seat: seat)
                }
                let program = stable(plant.program)
                let injection = plant.injection.map { stable($0) }
                _ = n60_mimo_problem_set_plant(
                    &problem, UInt32(source), UInt32(seat),
                    program, UInt64(plant.program.count),
                    injection, UInt64(plant.injection?.count ?? 0),
                    plant.arrivalSeconds ?? -1
                )
            }
        }

        let total = sourceCount * sourceCount * Int(problem.taps)
        // The solved readback needs grid_bins <= 1,700 (0.5 Hz steps up to 0.4 of the low rate, at most 1,200 Hz).
        let solvedCapacity = sourceCount * sourceCount * 1_700 * 2
        var taps = [Float](repeating: 0, count: total)
        var solved = [Float](repeating: 0, count: solvedCapacity)
        var info = n60_mimo_info()
        let status = taps.withUnsafeMutableBufferPointer { t in
            solved.withUnsafeMutableBufferPointer { s in
                n60_mimo_design_solved(&problem, t.baseAddress, UInt64(t.count), s.baseAddress, UInt64(s.count), &info)
            }
        }
        if status != N60_MIMO_OK {
            throw mapped(status, info: info, request: request)
        }

        var report = n60_mimo_realisation()
        let checkStatus = taps.withUnsafeBufferPointer { t in
            solved.withUnsafeBufferPointer { s in
                n60_mimo_realise_check(
                    &problem, t.baseAddress, UInt64(t.count), s.baseAddress, UInt64(s.count), &info, &report
                )
            }
        }
        guard checkStatus == N60_MIMO_OK else { throw MIMORoomTreatmentCoreDesignError.core(checkStatus) }

        let realisation = MIMOTreatmentRealisation(
            maximumDeviationDB: report.max_deviation_db,
            maximumDeviationHz: report.max_deviation_hz,
            edgeEnergyFraction: report.edge_energy_fraction,
            gainOvershootDB: values(report.gain_overshoot_db, count: sourceCount),
            effortOvershootDB: values(report.effort_overshoot_db, count: sourceCount)
        )
        try enforce(realisation, request: request, info: info, limits: limits)

        let summary = MIMOTreatmentDesignSummary(
            preEnergyDB: info.pre_energy_db,
            maximumDeviationDB: realisation.maximumDeviationDB,
            regularisationSteps: Int(info.regularisation_steps),
            peakGainDB: values(info.peak_gain_db, count: sourceCount),
            thermalDB: values(info.thermal_db, count: sourceCount),
            advice: advice(preEnergyDB: info.pre_energy_db, tau: request.tauSeconds, limits: limits)
        )
        let bins = Int(info.grid_bins)
        // Keep only the used part of the solved readback: [source][feed][bin] with `bins` per pair.
        var packed = [Float](repeating: 0, count: sourceCount * sourceCount * bins * 2)
        for pair in 0..<(sourceCount * sourceCount) {
            let from = pair * bins * 2
            packed.replaceSubrange(from..<(from + bins * 2), with: solved[from..<(from + bins * 2)])
        }
        let filters = MIMOTreatmentFilterSet(
            sampleRate: request.sampleRate,
            lowRateHz: lowRate,
            decimation: decimation,
            sourceCount: sourceCount,
            tapCount: Int(problem.taps),
            tauSeconds: request.tauSeconds,
            taps: taps,
            solved: packed,
            gridLowHz: info.grid_low_hz,
            gridBins: bins
        )
        return MIMOTreatmentDesignResult(filters: filters, realisation: realisation, summary: summary)
    }

    // MARK: Checks

    private static func enforce(
        _ realisation: MIMOTreatmentRealisation,
        request: MIMOTreatmentRequest,
        info: n60_mimo_info,
        limits: MIMOTreatmentRealisationLimits
    ) throws {
        if realisation.edgeEnergyFraction > limits.maximumEdgeEnergyFraction {
            throw MIMORoomTreatmentCoreDesignError.edgeEnergyTooHigh(
                actual: realisation.edgeEnergyFraction, maximum: limits.maximumEdgeEnergyFraction
            )
        }
        for source in 0..<request.sources.count where !request.sources[source].excluded {
            if realisation.gainOvershootDB[source] > limits.maximumOvershootDB {
                throw MIMORoomTreatmentCoreDesignError.overshoot(
                    kind: "gain", source: source,
                    actualDB: realisation.gainOvershootDB[source], maximumDB: limits.maximumOvershootDB
                )
            }
            if realisation.effortOvershootDB[source] > limits.maximumOvershootDB {
                throw MIMORoomTreatmentCoreDesignError.overshoot(
                    kind: "effort", source: source,
                    actualDB: realisation.effortOvershootDB[source], maximumDB: limits.maximumOvershootDB
                )
            }
        }
        let gate = limits.deviationGateDB(tau: request.tauSeconds)
        if realisation.maximumDeviationDB > gate {
            throw MIMORoomTreatmentCoreDesignError.realisationDeviation(
                actualDB: realisation.maximumDeviationDB, atHz: realisation.maximumDeviationHz,
                maximumDB: gate
            )
        }
    }

    private static func mapped(
        _ status: Int32, info: n60_mimo_info, request: MIMOTreatmentRequest
    ) -> MIMORoomTreatmentCoreDesignError {
        switch status {
        case N60_MIMO_ERR_RATE: return .sampleRateUnsupported(request.sampleRate)
        case N60_MIMO_ERR_TAU: return .tauOutOfRange(request.tauSeconds)
        case N60_MIMO_ERR_MISSING_PLANT:
            return .missingPlant(source: Int(max(info.bad_source, 0)), seat: Int(max(info.bad_seat, 0)))
        case N60_MIMO_ERR_SUPPORT: return .supportRangeInvalid
        case N60_MIMO_ERR_UNUSABLE: return .plantsUnusable
        case N60_MIMO_ERR_HEADROOM: return .headroom(source: Int(max(info.bad_source, 0)))
        case N60_MIMO_ERR_THERMAL: return .thermal(source: Int(max(info.bad_source, 0)))
        case N60_MIMO_ERR_CAUSALITY:
            return .tooMuchBeforeZero(
                preEnergyDB: info.pre_energy_db,
                suggestedTauSeconds: suggestedTau(from: request.tauSeconds)
            )
        default: return .core(status)
        }
    }

    /// A larger bass time target moves the causal cut away from the solution (G8). nil when already at the 20 ms limit.
    static func suggestedTau(from tau: Double) -> Double? {
        let limit = N60_MIMO_MAX_TAU_SECONDS
        guard tau < limit - 1e-6 else { return nil }
        return min(limit, max(tau + 0.005, 0.010))
    }

    private static func advice(
        preEnergyDB: Double, tau: Double, limits: MIMOTreatmentRealisationLimits
    ) -> [String] {
        var notes: [String] = []
        if let note = MIMOTreatmentRealisationLimits.shortTauNote(tau: tau) { notes.append(note) }
        guard preEnergyDB > limits.adviseAbovePreEnergyDB, let suggested = suggestedTau(from: tau) else { return notes }
        return notes + [
            "\(Int(preEnergyDB.rounded())) dB of the solution lies before t = 0. A later bass time target "
                + "(about \(Int((suggested * 1_000).rounded())) ms) gives a closer match."
        ]
    }

    private static func values<T>(_ tuple: T, count: Int) -> [Double] {
        withUnsafeBytes(of: tuple) { raw in
            Array(raw.bindMemory(to: Double.self).prefix(count))
        }
    }
}
