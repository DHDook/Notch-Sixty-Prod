import Foundation

/// E19 S12b (flag `e19.self-qualification`, owner decisions D11 and D13, 23 Nov 2026): the probe arm that takes the treated
/// repeat measurement of a self-qualification (SQ5), and the evaluator that judges it.
///
/// This is a live MIMO path, so it is as narrow as the written authorisation says. A ticket is issued only after SQ1 to SQ4
/// pass. It lets the user arm the staged design for the measurement only, through the same `LiveTreatmentArm` and every gate
/// of the permit path, with the ticket in place of a permit and programme playback stopped. It is fingerprint-bound, held in
/// memory (never `Codable`, never persisted), ends after the last seat or 120 s per seat, and ends on any fault, refusal or
/// fingerprint change. It never becomes a permit and never arms by itself: launch, wake, device and rate changes leave it off.
/// Control plane only (main actor or offline); the realtime path sees only the stage's two live words, as for any arm.
enum MIMOTreatmentProbeLimits {
    /// D13: time one seat may stay armed.
    static let secondsPerSeat = 120.0
    /// SQ5: the untreated control capture must match the baseline within this, per third octave, 25 to 160 Hz.
    static let controlToleranceDB = 1.0
    /// SQ5: the measured treated level must match the prediction within this, per third octave, at every seat.
    static let treatedLevelToleranceDB = 3.0
    /// SQ5: the hard limit applies no gain reduction; this is the meter's own noise floor, not a budget.
    static let hardLimitReductionToleranceDB = 0.05
    static let bandCentersHz: [Double] = [25, 31.5, 40, 50, 63, 80, 100, 125, 160]
}

struct MIMOTreatmentProbeTicket: Equatable, Sendable {
    /// `MIMOGraphTreatment.currentFingerprint(selfQualified: true)` at issue; any change of it ends the probe.
    var fingerprint: String
    /// The included seats, in the order they are measured.
    var seatIDs: [UUID]
    var issuedAt: Date
}

enum MIMOTreatmentProbeEnd: Equatable, Sendable {
    case completed
    case timedOut(seat: UUID)
    case faulted
    case hardLimitActed
    case fingerprintChanged
    case featureOff
    case userStopped
    case interrupted(LiveTreatmentDisarmReason)

    var reason: String {
        switch self {
        case .completed: return "The treated measurement is finished."
        case .timedOut: return "A seat took longer than 120 seconds, so the treated measurement was stopped."
        case .faulted: return "The treatment monitor tripped during the treated measurement, so it was stopped."
        case .hardLimitActed: return "The output hard limit acted during the treated measurement, so it was stopped."
        case .fingerprintChanged: return "The design, output or chain changed, so the treated measurement was stopped."
        case .featureOff: return "Self-qualification was switched off."
        case .userStopped: return "You stopped the treated measurement."
        case .interrupted(let why): return why.message ?? "The treated measurement was stopped."
        }
    }
}

enum MIMOTreatmentProbeRefusal: Error, Equatable, Sendable {
    case featureOff
    case videoLatencyInputNotWired
    case videoLatencyMode
    case noStagedDesign
    case engineNotReady
    case probeAlreadyActive
    case selfQualificationRefused([MIMOTreatmentSelfQualificationFailure])

    var reason: String {
        switch self {
        case .featureOff: return "Room treatment self-qualification is switched off."
        case .videoLatencyInputNotWired: return "The treated measurement cannot start yet: the video latency setting is not available."
        case .videoLatencyMode: return "Room treatment is not available in video latency mode."
        case .noStagedDesign: return "No room treatment design is staged."
        case .engineNotReady: return "Start audio processing with the room treatment stage and the hard limit in place first."
        case .probeAlreadyActive: return "A treated measurement is already in progress."
        case .selfQualificationRefused(let failures): return failures.map(\.reason).joined(separator: " ")
        }
    }
}

/// One probe in progress or ended. Held by `MIMOGraphTreatment`; never stored on disk.
struct MIMOTreatmentProbeSession: Equatable, Sendable {
    var ticket: MIMOTreatmentProbeTicket
    var completedSeats: [UUID] = []
    var activeSeat: UUID?
    var seatDeadline: Date?
    var armed = false
    var worstHardLimitReductionDB = 0.0
    var hardLimitReadingSeen = false
    /// The first armed reading is discarded: the meter holds the peak since its last read, which predates the arm.
    var hardLimitPrimed = false
    var faultSeen = false
    var end: MIMOTreatmentProbeEnd?

    var isLive: Bool { end == nil }
}

/// What SQ5 judges beyond the decay and spatial criteria the verifier already runs on the treated provider's measurements.
enum MIMOTreatmentProbeFailure: Equatable, Sendable {
    case probeIncomplete
    case seatMissing(seat: Int)
    case captureSilent(seat: Int)
    case controlMismatch(seat: Int, bandHz: Double, differenceDB: Double)
    case treatedLevelMismatch(seat: Int, bandHz: Double, differenceDB: Double)
    case monitorLatched
    case hardLimitActed(reductionDB: Double)
    case hardLimitNotRead

    var reason: String {
        switch self {
        case .probeIncomplete: return "The treated measurement did not finish every seat."
        case .seatMissing(let s): return "Seat \(s + 1) has no treated or control measurement."
        case .captureSilent(let s): return "Seat \(s + 1): a measurement was silent."
        case .controlMismatch(let s, let hz, let d):
            return String(format: "Seat %d: the untreated check differs from the first measurement by %.1f dB at %.0f Hz (1 dB allowed); the room or seat changed.", s + 1, d, hz)
        case .treatedLevelMismatch(let s, let hz, let d):
            return String(format: "Seat %d: the treated level differs from the prediction by %.1f dB at %.0f Hz (3 dB allowed).", s + 1, d, hz)
        case .monitorLatched: return "The treatment monitor tripped during the treated measurement."
        case .hardLimitActed(let db): return String(format: "The output hard limit reduced gain by %.1f dB during the treated measurement.", db)
        case .hardLimitNotRead: return "The hard limit was not read during the treated measurement."
        }
    }
}

/// The outcome of one probe, bound to the design it was taken on. Part of the evidence `issuePermit` reads.
struct MIMOTreatmentProbeResult: Equatable, Sendable {
    var fingerprint: String
    var failures: [MIMOTreatmentProbeFailure]
    var passed: Bool { failures.isEmpty }
}

enum MIMOTreatmentProbeEvaluator {
    /// The four impulse responses of one seat (each already the sum over the design's sources) at the device rate.
    struct SeatResponses: Sendable {
        var seatID: UUID
        var baseline: [Float]
        var control: [Float]
        var predictedTreated: [Float]
        var measuredTreated: [Float]
    }

    /// Third-octave levels (dB) of an impulse response over 25 to 160 Hz, from a decimated copy so every rate costs the same.
    /// Each band is the mean power at five frequencies within plus or minus a sixth of an octave of its centre (Goertzel).
    static func thirdOctaveLevelsDB(_ impulse: [Float], sampleRate: Double) -> [Double]? {
        guard let low = try? MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: sampleRate),
              let decimated = try? MIMOTreatmentController.decimate(impulse, rate: sampleRate), !decimated.isEmpty else { return nil }
        let rate = low.lowRateHz
        let x = decimated.prefix(Int(rate)).map(Double.init)
        var levels: [Double] = []
        for center in MIMOTreatmentProbeLimits.bandCentersHz {
            var power = 0.0
            for k in -2...2 {
                let f = center * pow(2, Double(k) / 12)
                let w = 2 * Double.pi * f / rate
                let c = 2 * cos(w)
                var s1 = 0.0, s2 = 0.0
                for v in x {
                    let s0 = v + c * s1 - s2
                    s2 = s1
                    s1 = s0
                }
                power += s1 * s1 + s2 * s2 - c * s1 * s2
            }
            power /= 5
            guard power > 0, power.isFinite else { return nil }
            levels.append(10 * log10(power))
        }
        return levels
    }

    /// Every SQ5 failure of the probe (empty means it passed). `session` is the ended probe; nil or not completed is a failure.
    static func evaluate(
        seats: [SeatResponses], sampleRate: Double, session: MIMOTreatmentProbeSession?
    ) -> [MIMOTreatmentProbeFailure] {
        var failures: [MIMOTreatmentProbeFailure] = []
        guard let session, session.end == .completed else { return [.probeIncomplete] }
        if session.faultSeen { failures.append(.monitorLatched) }
        if !session.hardLimitReadingSeen {
            failures.append(.hardLimitNotRead)
        } else if session.worstHardLimitReductionDB > MIMOTreatmentProbeLimits.hardLimitReductionToleranceDB {
            failures.append(.hardLimitActed(reductionDB: session.worstHardLimitReductionDB))
        }
        for (index, seatID) in session.ticket.seatIDs.enumerated() {
            guard let seat = seats.first(where: { $0.seatID == seatID }),
                  !seat.baseline.isEmpty, !seat.control.isEmpty, !seat.predictedTreated.isEmpty, !seat.measuredTreated.isEmpty else {
                failures.append(.seatMissing(seat: index)); continue
            }
            guard let base = thirdOctaveLevelsDB(seat.baseline, sampleRate: sampleRate),
                  let control = thirdOctaveLevelsDB(seat.control, sampleRate: sampleRate),
                  let predicted = thirdOctaveLevelsDB(seat.predictedTreated, sampleRate: sampleRate),
                  let measured = thirdOctaveLevelsDB(seat.measuredTreated, sampleRate: sampleRate) else {
                failures.append(.captureSilent(seat: index)); continue
            }
            for (band, hz) in MIMOTreatmentProbeLimits.bandCentersHz.enumerated() {
                let controlDiff = control[band] - base[band]
                if abs(controlDiff) > MIMOTreatmentProbeLimits.controlToleranceDB {
                    failures.append(.controlMismatch(seat: index, bandHz: hz, differenceDB: controlDiff))
                }
                let levelDiff = measured[band] - predicted[band]
                if abs(levelDiff) > MIMOTreatmentProbeLimits.treatedLevelToleranceDB {
                    failures.append(.treatedLevelMismatch(seat: index, bandHz: hz, differenceDB: levelDiff))
                }
            }
        }
        return failures
    }
}
