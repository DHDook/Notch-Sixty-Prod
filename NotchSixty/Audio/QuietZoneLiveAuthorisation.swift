import Foundation

/// E4 S3: the single decision on whether speaker ANC may play live anti-noise.
///
/// Criteria and targets come from `docs/ANC_QUALIFICATION.md` (sections 2, 3
/// and 5). Every PR97/PR99/latency report keeps its own `liveANCQualified =
/// false`: each one is evidence, and no single report can authorise. Only
/// `LiveANCAuthorisation.evaluate` combines evidence into a decision.
///
/// Nothing in the app builds the bench attestations (howl detector, analog
/// mute) or the owner sign-off yet, so in shipping code the decision is always
/// "not authorised". E4 S10 adds the only path that records them.

/// The hardware a record is valid for. A different output device, reference
/// or error input, or sample rate needs its own record.
struct LiveANCBinding: Hashable, Sendable {
    let outputDeviceUID: String
    let inputDeviceUID: String
    let sampleRate: Double

    func matches(_ other: LiveANCBinding) -> Bool {
        outputDeviceUID == other.outputDeviceUID
            && inputDeviceUID == other.inputDeviceUID
            && abs(sampleRate - other.sampleRate) < 0.5
    }
}

enum LiveANCRequirement: String, CaseIterable, Sendable {
    case timing
    case latencyBudget
    case acousticTargets
    case howlDetector
    case analogMute
    case ownerSignOff

    var title: String {
        switch self {
        case .timing: return "PR97 timing qualified for this interface"
        case .latencyBudget: return "Latency budget met at this rate"
        case .acousticTargets: return "PR99 campaign passed against the published targets"
        case .howlDetector: return "Howl detector qualified at this rate"
        case .analogMute: return "Emergency analog mute verified on the bench"
        case .ownerSignOff: return "Owner sign-off recorded"
        }
    }

    /// Measurements that must come from one campaign (section 5).
    var isCampaignMeasurement: Bool {
        switch self {
        case .timing, .latencyBudget, .acousticTargets: return true
        case .howlDetector, .analogMute, .ownerSignOff: return false
        }
    }
}

/// One piece of evidence toward authorisation.
protocol LiveANCEvidence: Sendable {
    var requirement: LiveANCRequirement { get }
    var binding: LiveANCBinding { get }
    var recordedAt: Date { get }
    /// Nil when the evidence meets its criterion; otherwise why it does not.
    var shortfall: String? { get }
}

/// Proposed targets from `docs/ANC_QUALIFICATION.md`, accepted with #157.
enum QuietZoneQualificationTargets {
    static let primaryTonalReductionDB = 15.0
    static let primaryBroadbandBandReductionDB = 6.0
    static let quietZoneTonalReductionDB = 10.0
    static let maximumOtherSeatIncreaseDB = 1.0
    static let maximumWaterbedIncreaseDB = 0.5
    static let maximumRepeatDifferenceDB = 1.5
    static let maximumBaselineDriftDB = 1.5
    static let howlTripSeconds = 0.050
    static let howlMuteRampSeconds = 0.010
    static let campaignSeconds: TimeInterval = 1800
}

enum LiveANCAuthorisation {
    enum Reason: Equatable, Sendable {
        case missing(LiveANCRequirement)
        case duplicate(LiveANCRequirement)
        case wrongHardware(LiveANCRequirement)
        case shortfall(LiveANCRequirement, String)
        case campaignTooLong
        case signOffBeforeEvidence

        var description: String {
            switch self {
            case .missing(let r):
                return "Missing: \(r.title)."
            case .duplicate(let r):
                return "More than one record for: \(r.title)."
            case .wrongHardware(let r):
                return "Recorded on other hardware or at another rate: \(r.title)."
            case .shortfall(let r, let why):
                return "\(r.title): \(why)"
            case .campaignTooLong:
                return "Timing, latency and acoustic measurements must come from one campaign of at most 30 minutes."
            case .signOffBeforeEvidence:
                return "The owner sign-off predates the evidence it approves."
            }
        }
    }

    struct Decision: Equatable, Sendable {
        let binding: LiveANCBinding
        let reasons: [Reason]

        var authorised: Bool { reasons.isEmpty }
    }

    static func evaluate(
        _ evidence: [any LiveANCEvidence],
        for binding: LiveANCBinding
    ) -> Decision {
        var reasons: [Reason] = []
        var accepted: [LiveANCRequirement: any LiveANCEvidence] = [:]

        for requirement in LiveANCRequirement.allCases {
            let items = evidence.filter { $0.requirement == requirement }
            guard let item = items.first else {
                reasons.append(.missing(requirement))
                continue
            }
            if items.count > 1 {
                reasons.append(.duplicate(requirement))
                continue
            }
            guard item.binding.matches(binding) else {
                reasons.append(.wrongHardware(requirement))
                continue
            }
            if let why = item.shortfall {
                reasons.append(.shortfall(requirement, why))
                continue
            }
            accepted[requirement] = item
        }

        let campaign = accepted.values
            .filter { $0.requirement.isCampaignMeasurement }
            .map(\.recordedAt)
        if let first = campaign.min(), let last = campaign.max(),
           last.timeIntervalSince(first)
            > QuietZoneQualificationTargets.campaignSeconds {
            reasons.append(.campaignTooLong)
        }
        if let signOff = accepted[.ownerSignOff],
           let lastEvidence = accepted.values
            .filter({ $0.requirement != .ownerSignOff })
            .map(\.recordedAt).max(),
           signOff.recordedAt < lastEvidence {
            reasons.append(.signOffBeforeEvidence)
        }
        return Decision(binding: binding, reasons: reasons)
    }
}

// MARK: - Evidence from existing reports

/// PR97: a qualified HAL clock trace for the reference input and output.
struct LiveANCTimingEvidence: LiveANCEvidence {
    let trace: QuietZoneHALClockTrace
    let health: QuietZoneHALClockHealth
    let recordedAt: Date

    var requirement: LiveANCRequirement { .timing }
    var binding: LiveANCBinding {
        LiveANCBinding(
            outputDeviceUID: trace.outputDeviceID,
            inputDeviceUID: trace.inputDeviceID,
            sampleRate: trace.nominalSampleRate
        )
    }
    var shortfall: String? {
        health.qualifiedForLoopbackBench
            ? nil : "the HAL clock trace did not qualify."
    }
}

/// The measured four-stage latency budget with its safety reserve.
struct LiveANCLatencyEvidence: LiveANCEvidence {
    let report: QuietZonePhysicalLatencyReport

    var requirement: LiveANCRequirement { .latencyBudget }
    var binding: LiveANCBinding {
        let first = report.stageEvidence.first
        return LiveANCBinding(
            outputDeviceUID: first?.outputDeviceID ?? "",
            inputDeviceUID: first?.microphoneDeviceID ?? "",
            sampleRate: first?.sampleRate ?? 0
        )
    }
    var recordedAt: Date {
        report.stageEvidence.map(\.capturedAt).max() ?? .distantPast
    }
    var shortfall: String? {
        let stages = report.stageEvidence
        guard let first = stages.first else {
            return "no stage measurements."
        }
        guard stages.allSatisfy({
            $0.outputDeviceID == first.outputDeviceID
                && $0.microphoneDeviceID == first.microphoneDeviceID
                && abs($0.sampleRate - first.sampleRate) < 0.5
        }) else {
            return "stages were measured on different hardware or rates."
        }
        guard report.readiness == .physicallyPlausible else {
            return "timing readiness is \(report.readiness.rawValue)."
        }
        guard report.spareAfterSafetyReserveSeconds >= 0 else {
            return String(
                format: "the reference lead is %.2f ms short of the safety reserve.",
                -report.spareAfterSafetyReserveSeconds * 1000
            )
        }
        return nil
    }
}

/// PR99: the A→B→A campaign, checked against section 2's targets.
struct LiveANCAcousticEvidence: LiveANCEvidence {
    let review: QuietZonePhysicalVerificationReview
    let inputDeviceUID: String
    let recordedAt: Date

    var requirement: LiveANCRequirement { .acousticTargets }
    var binding: LiveANCBinding {
        LiveANCBinding(
            outputDeviceUID: review.rig.outputDeviceID,
            inputDeviceUID: inputDeviceUID,
            sampleRate: review.rig.sampleRate
        )
    }
    var shortfall: String? {
        typealias T = QuietZoneQualificationTargets
        if !review.instrumentEvidenceIndependentlyAuthenticated
            || !review.physicalAcousticReductionVerified {
            return "the reduction is not independently verified."
        }
        let primary = min(
            review.firstPrimaryReductionDB,
            review.returningPrimaryReductionDB
        )
        if primary < T.primaryTonalReductionDB {
            return String(
                format: "primary seat reduction %.1f dB is below %.0f dB.",
                primary, T.primaryTonalReductionDB
            )
        }
        if review.neighboringSeatReductionDB < -T.maximumOtherSeatIncreaseDB {
            return String(
                format: "the neighbouring seat is %.1f dB louder.",
                -review.neighboringSeatReductionDB
            )
        }
        if review.primaryReductionRepeatDifferenceDB
            > T.maximumRepeatDifferenceDB {
            return "the primary seat result did not repeat within 1.5 dB."
        }
        if review.largestPrimaryBaselineDifferenceDB
            > T.maximumBaselineDriftDB {
            return "the ANC-off baseline drifted by more than 1.5 dB."
        }
        return nil
    }
}

/// A bench check signed by the person who ran it (howl detector, analog mute).
struct LiveANCBenchAttestation: LiveANCEvidence {
    let requirement: LiveANCRequirement
    let binding: LiveANCBinding
    let recordedAt: Date
    let operatorName: String
    let passed: Bool
    let note: String

    var shortfall: String? {
        guard requirement == .howlDetector || requirement == .analogMute else {
            return "a bench attestation cannot stand in for this requirement."
        }
        return passed ? nil : "the bench check failed (\(note))."
    }
}

struct LiveANCOwnerSignOff: LiveANCEvidence {
    let binding: LiveANCBinding
    let recordedAt: Date
    let signedBy: String

    var requirement: LiveANCRequirement { .ownerSignOff }
    var shortfall: String? {
        signedBy.trimmingCharacters(in: .whitespaces).isEmpty
            ? "no signer recorded." : nil
    }
}
