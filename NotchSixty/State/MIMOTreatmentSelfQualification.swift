import CryptoKit
import Foundation

/// E19 S12a (flag `e19.self-qualification`, criteria SQ1 to SQ4 and SQ7, owner decisions D10 to D14, 23 Nov 2026): the evidence a
/// room's own measurements must supply for a self-qualified permit, and the evaluator that judges it.
///
/// Every field is a measurement or a value the app computed (`MIMOGraphHeadroom`, the plant model, the planner). Nothing here
/// reads a tick box: `MIMORoomTreatmentSourceSafetyDeclaration` booleans are never evidence. Criterion values are product-only
/// constants and not adjustable (SQ6). The SQ5 treated repeat measurement is part of the verification result `issuePermit`
/// already requires; the probe arm that takes it in production is S12b, so no production permit is issuable before that.
/// Control plane only (main actor or offline). Nothing here arms.
struct MIMOTreatmentSelfQualificationEvidence: Equatable, Sendable {
    struct Seat: Equatable, Sendable {
        var id: UUID
        var included: Bool
        var weight: Double
    }

    /// One baseline capture: per source (routed: per in-band way) at one seat.
    struct Capture: Equatable, Sendable {
        var seatID: UUID
        /// Source index, or in-band way index when routed.
        var lane: Int
        var sampleRate: Double
        var microphoneUID: String?
        /// Reliable third-octave decay bands in 25 to 160 Hz.
        var reliableBands: Int
        /// In-band SNR (dB) of every third octave the design uses.
        var thirdOctaveSNRDB: [Double]
        var digest: String
    }

    /// The computed (never declared) budgets of one source, or one in-band way when routed.
    struct SourceBudget: Equatable, Sendable {
        var source: Int
        /// min(hard-limit headroom, way limiter threshold) minus the designed peak, dB.
        var headroomReserveDB: Double
        /// The measured -10 dB excursion point (the lower limit); nil when none was measured.
        var excursionLimitHz: Double?
        /// How fast the designed effort falls below that limit, dB per octave.
        var effortSlopeBelowLimitDBPerOctave: Double
    }

    var sampleRate: Double
    var routed = false
    var sourceCount: Int
    var seats: [Seat]
    var captures: [Capture]
    /// How many sources `MIMOGraphHeadroom.budgetedRequest` covered with a bounded budget.
    var headroomBudgetedSources: Int
    var laneCount: Int
    /// Output lanes that carry the hard limit and the user protection stage.
    var protectedLaneCount: Int
    var quietZoneActuatorPresent: Bool
    var budgets: [SourceBudget]
    /// Designed in-band delta RMS re programme, dB (D5).
    var thermalDeltaRMSDB: Double?
    /// The verification of the predicted treated response (decay), from the setup's own plants.
    var predictedDecay: MIMOTreatmentVerificationResult?
    /// The PR75 spatial report of the predicted treated response.
    var predictedSpatial: MIMORoomTreatmentVerificationReport?

    var includedSeats: [Seat] { seats.filter(\.included) }

    /// The microphone every capture used (nil when they disagree or none is recorded).
    var microphoneUID: String? {
        let uids = Set(captures.map { $0.microphoneUID ?? "" })
        guard uids.count == 1, let uid = uids.first, !uid.isEmpty else { return nil }
        return uid
    }

    /// SQ7: the evidence-held part of the permit's binding: seat set (count, include, weights), capture digests, microphone UID.
    var bindingDigest: String {
        var hasher = SHA256()
        let seatText = seats.map { "\($0.id.uuidString):\($0.included ? 1 : 0):\(String(format: "%.4f", $0.weight))" }.joined(separator: ",")
        let captureText = captures.map { "\($0.seatID.uuidString):\($0.lane):\($0.digest)" }.joined(separator: ",")
        hasher.update(data: Data("seats=\(seats.count)[\(seatText)]|caps=[\(captureText)]|mic=\(microphoneUID ?? "-")".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// An engine baseline: the E22 bench record of the six PR75 hardware checks for the shipping engine in one rate family (SQ6, D10).
/// Product-only; the production registry holds none until E22 files them.
struct MIMOTreatmentEngineBaseline: Equatable, Sendable {
    /// Decimation of the rate family: 16, 32, 64 or 128.
    var decimation: Int
    var recordedAt: Date
    var longRunThermalPassed: Bool
    var protectionChainPassed: Bool
    var stopStartPassed: Bool
    var unplugReplugPassed: Bool
    var sleepWakePassed: Bool
    var audibleArtifactCheckPassed: Bool

    var isComplete: Bool {
        longRunThermalPassed && protectionChainPassed && stopStartPassed && unplugReplugPassed && sleepWakePassed
            && audibleArtifactCheckPassed
    }
}

/// One named reason a self-qualification does not pass. Each is a separate criterion.
enum MIMOTreatmentSelfQualificationFailure: Equatable, Sendable {
    case evidenceMissing
    case sourceCountOutOfRange(Int)
    case tooFewSeats(included: Int)
    case headroomNotBudgeted
    case protectionMissing(protected: Int, lanes: Int)
    case quietZoneActuatorOnGraph
    case engineBaselineMissing(decimation: Int)
    case wrongSampleRate(seat: Int)
    case microphoneNotOne
    case capturesIncomplete
    case tooFewReliableBands(seat: Int, bands: Int)
    case snrTooLow(seat: Int, snrDB: Double)
    case predictionMissing
    case predictedDecayFailed
    case predictedSpatialFailed(String)
    case headroomReserveTooSmall(source: Int, reserveDB: Double)
    case excursionLimitMissing(source: Int)
    case excursionSlopeTooShallow(source: Int, slope: Double)
    case thermalBudgetExceeded(deltaDB: Double?)

    var reason: String {
        switch self {
        case .evidenceMissing: return "No self-qualification evidence has been collected for this design."
        case .sourceCountOutOfRange(let n): return "Self-qualification needs 2 to 8 sources; this setup has \(n)."
        case .tooFewSeats(let n): return "Self-qualification needs at least 3 measured seats; \(n) included."
        case .headroomNotBudgeted: return "The design's headroom budget has not been computed for every source."
        case .protectionMissing(let p, let l): return "The hard limit and output protection cover \(p) of \(l) outputs; every output needs them."
        case .quietZoneActuatorOnGraph: return "A Quiet Zone actuator is on the graph; room treatment cannot be self-qualified with it."
        case .engineBaselineMissing(let d): return "No engine baseline qualification is on file for this sample rate family (decimation \(d))."
        case .wrongSampleRate(let seat): return "Seat \(seat + 1): a measurement was not taken at the device sample rate."
        case .microphoneNotOne: return "The measurements must all come from one microphone."
        case .capturesIncomplete: return "Every source and included seat needs a baseline measurement."
        case .tooFewReliableBands(let seat, let n): return "Seat \(seat + 1): only \(n) bass bands had a usable decay; 5 are needed."
        case .snrTooLow(let seat, let db): return String(format: "Seat %d: the measurement is only %.0f dB above the noise; 30 dB is needed.", seat + 1, db)
        case .predictionMissing: return "The predicted treated response has not been computed."
        case .predictedDecayFailed: return "The predicted bass decay does not improve enough, or gets worse in a band."
        case .predictedSpatialFailed(let why): return "The predicted seat-to-seat levels fail: \(why)."
        case .headroomReserveTooSmall(let s, let db): return String(format: "Source %d keeps only %.1f dB of headroom after the design; 3 dB is needed.", s + 1, db)
        case .excursionLimitMissing(let s): return "Source \(s + 1) has no measured excursion limit."
        case .excursionSlopeTooShallow(let s, let slope): return String(format: "Source %d: the design falls only %.0f dB per octave below its excursion limit; 12 is needed.", s + 1, slope)
        case .thermalBudgetExceeded: return "The designed bass effort exceeds the thermal budget of -6 dB re programme."
        }
    }
}

enum MIMOTreatmentSelfQualification {
    // Product-only criterion values (SQ6): not parameters of any caller.
    static let minimumSources = 2, maximumSources = 8
    static let minimumIncludedSeats = 3
    static let minimumSNRDB = 30.0
    static let minimumHeadroomReserveDB = 3.0
    static let minimumEffortSlopeDBPerOctave = 12.0
    static let maximumThermalDeltaRMSDB = -6.0

    /// Judges SQ1 (the evidence-held parts), SQ2, SQ3 and SQ4 and returns every failure; empty means all pass.
    /// The context-held parts of SQ1 (flags, latency, staged design, hard limit present) are `issuePermit`'s own checks.
    static func evaluate(
        _ evidence: MIMOTreatmentSelfQualificationEvidence, decimation: Int, registry: MIMOTreatmentQualificationRegistry
    ) -> [MIMOTreatmentSelfQualificationFailure] {
        var failures: [MIMOTreatmentSelfQualificationFailure] = []
        let criteria = MIMOTreatmentDecayCriteria.conservative
        let spatialLimits = MIMORoomTreatmentVerificationConfiguration.conservative

        // SQ1
        if !(minimumSources...maximumSources).contains(evidence.sourceCount) { failures.append(.sourceCountOutOfRange(evidence.sourceCount)) }
        let included = evidence.includedSeats
        if included.count < minimumIncludedSeats { failures.append(.tooFewSeats(included: included.count)) }
        if evidence.headroomBudgetedSources < evidence.sourceCount { failures.append(.headroomNotBudgeted) }
        if evidence.protectedLaneCount < evidence.laneCount || evidence.laneCount == 0 {
            failures.append(.protectionMissing(protected: evidence.protectedLaneCount, lanes: evidence.laneCount))
        }
        if evidence.quietZoneActuatorPresent { failures.append(.quietZoneActuatorOnGraph) }
        if !registry.engineBaselines.contains(where: { $0.decimation == decimation && $0.isComplete }) {
            failures.append(.engineBaselineMissing(decimation: decimation))
        }

        // SQ2
        if evidence.microphoneUID == nil { failures.append(.microphoneNotOne) }
        for (seatIndex, seat) in included.enumerated() {
            let caps = evidence.captures.filter { $0.seatID == seat.id }
            let lanes = Set(caps.map(\.lane))
            if lanes.count < evidence.sourceCount || lanes.count != caps.count { failures.append(.capturesIncomplete) }
            for cap in caps {
                if abs(cap.sampleRate - evidence.sampleRate) >= 0.5 { failures.append(.wrongSampleRate(seat: seatIndex)); break }
            }
            if let worst = caps.map(\.reliableBands).min(), worst < criteria.minimumReliableBandsPerSeat {
                failures.append(.tooFewReliableBands(seat: seatIndex, bands: worst))
            }
            let snrs = caps.flatMap(\.thirdOctaveSNRDB)
            if caps.contains(where: { $0.thirdOctaveSNRDB.isEmpty }) {
                failures.append(.snrTooLow(seat: seatIndex, snrDB: 0))
            } else if let low = snrs.min(), low < minimumSNRDB {
                failures.append(.snrTooLow(seat: seatIndex, snrDB: low))
            }
        }

        // SQ3
        if let decay = evidence.predictedDecay, let spatial = evidence.predictedSpatial {
            let relevant = decay.failures.contains { failure in
                switch failure {
                case .noSeats: return true
                case .seatCountMismatch(let p), .decayNotReliable(let p, _, _), .decayNotShortened(let p, _),
                     .decayWorsened(let p, _, _, _), .analysisFailed(let p): return p == .predicted
                default: return false
                }
            }
            if relevant || (decay.predictedMedianImprovement ?? 0) < criteria.minimumMedianT30Improvement {
                failures.append(.predictedDecayFailed)
            }
            var why: [String] = []
            if spatial.spatialRMSErrorImprovementDB < spatialLimits.minimumSpatialRMSErrorImprovementDB { why.append("improvement too small") }
            if spatial.maximumAbsoluteMeanLevelShiftDB > spatialLimits.maximumAbsoluteMeanLevelShiftDB { why.append("mean level shifts too much") }
            if spatial.worstSeatErrorIncreaseDB > spatialLimits.maximumWorstSeatErrorIncreaseDB { why.append("a seat gets worse") }
            if spatial.treatedSpatialRMSErrorDB > spatialLimits.maximumTreatedSpatialRMSErrorDB { why.append("treated spread too large") }
            if spatial.sourceReports.contains(where: {
                $0.treatedSpatialRMSErrorDB - $0.baselineSpatialRMSErrorDB > spatialLimits.maximumPerSourceSpatialRMSErrorDegradationDB
            }) { why.append("a source gets worse") }
            if !why.isEmpty { failures.append(.predictedSpatialFailed(why.joined(separator: ", "))) }
        } else {
            failures.append(.predictionMissing)
        }

        // SQ4
        for budget in evidence.budgets {
            if !budget.headroomReserveDB.isFinite || budget.headroomReserveDB < minimumHeadroomReserveDB {
                failures.append(.headroomReserveTooSmall(source: budget.source, reserveDB: budget.headroomReserveDB))
            }
            if let limit = budget.excursionLimitHz, limit.isFinite, limit > 0 {
                if !(budget.effortSlopeBelowLimitDBPerOctave >= minimumEffortSlopeDBPerOctave) {
                    failures.append(.excursionSlopeTooShallow(source: budget.source, slope: budget.effortSlopeBelowLimitDBPerOctave))
                }
            } else {
                failures.append(.excursionLimitMissing(source: budget.source))
            }
        }
        if evidence.budgets.count < evidence.sourceCount { failures.append(.headroomNotBudgeted) }
        if let delta = evidence.thermalDeltaRMSDB, delta.isFinite, delta <= maximumThermalDeltaRMSDB {
        } else {
            failures.append(.thermalBudgetExceeded(deltaDB: evidence.thermalDeltaRMSDB))
        }
        return failures
    }

    /// SQ7: the engine-held part of the binding. Hard-limit ceiling, the protection settings and the MIMO, graph and headroom
    /// domain versions. A change of any of them voids a self-qualified permit.
    static func engineBinding(protection: OutputProtectionSettings) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(protection)).flatMap { String(data: $0, encoding: .utf8) } ?? "-"
        return "limit=\(UnifiedGraphOutputProtection.hardLimitCeilingDB)|prot=\(json)|mimo=\(N60_MIMO_ABI_VERSION)|graph=\(N60_GRAPH_ABI_VERSION)|headroom=\(N60_HEADROOM_ABI_VERSION)"
    }
}
