import Foundation

/// PR99: independently captured A -> B -> A verification in three complete
/// measurement visits with one moved microphone and unchanged DAC/clock rig.
/// This is a numerical reviewer only; it NEVER drives hardware or authorizes ANC.
enum QuietZonePhysicalVerificationPosition: Int, CaseIterable, Sendable {
    case listenerFirst, neighboringSeat, listenerReturn
}

struct QuietZonePhysicalVerificationVisit: Sendable {
    let position: QuietZonePhysicalVerificationPosition
    let sessionID: UUID
    let rig: QuietZoneHardwareCalibrationRig
    let sessionStartedAt: Date
    let seatCaptures: [QuietZoneSeatAcceptanceCapture]
    let faultProbes: [QuietZoneHardwareFaultShutdownWitness]
}

enum QuietZonePhysicalVerificationFault: Error, Equatable, LocalizedError {
    case incompleteSurvey
    case wrongVisitOrder
    case changedHardwareRig
    case changedInstrumentOrSource
    case duplicatedEvidence
    case staleOrReorderedSessions
    case mismatchedFrequencyBands
    case movedReturnMicrophone
    case changedNoiseBaseline
    case unstableAttenuation
    case failedNumericalPreflight

    var errorDescription: String? {
        switch self {
        case .incompleteSurvey: return "Three complete primary–neighbor–primary measurement visits are required."
        case .wrongVisitOrder: return "Listener visit order must be A–B–A."
        case .changedHardwareRig: return "The microphone, DAC lease or sample-clock rig changed."
        case .changedInstrumentOrSource: return "The independent instrument or controlled source changed between visits."
        case .duplicatedEvidence: return "Each capture launch, fault event and measurement session must be unique."
        case .staleOrReorderedSessions: return "The campaign has expired or the visits overlap."
        case .mismatchedFrequencyBands: return "All visits must contain the same frequency bins."
        case .movedReturnMicrophone: return "The returned microphone position differs from the first seat."
        case .changedNoiseBaseline: return "The four independent OFF readings at the primary seat drifted too much."
        case .unstableAttenuation: return "The primary-seat cancellation result was not repeatable."
        case .failedNumericalPreflight: return "At least one complete external measurement set failed PR98 acceptance."
        }
    }
}

struct QuietZonePhysicalVerificationReview: Sendable {
    let rig: QuietZoneHardwareCalibrationRig
    let sessionIDs: [UUID]
    let firstPrimaryReductionDB: Double
    let neighboringSeatReductionDB: Double
    let returningPrimaryReductionDB: Double
    let worstMeasuredBandReductionDB: Double
    let largestPrimaryBaselineDifferenceDB: Double
    let primaryReductionRepeatDifferenceDB: Double
    let worstReportedShutdownSeconds: Double
    let uniqueExternalLaunchCount: Int
    let allThreeNumericalReviewsPassed: Bool = true

    /// All raw captures and witness provenance came from callers; a software
    /// result cannot certify instrument identity or acoustic reliability.
    let instrumentEvidenceIndependentlyAuthenticated: Bool = false
    let physicalAcousticReductionVerified: Bool = false
    let emergencyAnalogMuteVerified: Bool = false
    let liveANCQualified: Bool = false
    let outputConnected: Bool = false

    var reviewText: String {
        [
            "PR99 — three-visit physical ANC verification: PROVISIONAL ONLY",
            String(format: "Initial listener reduction: %.2f dB", firstPrimaryReductionDB),
            String(format: "Neighboring seat reduction: %.2f dB", neighboringSeatReductionDB),
            String(format: "Returned listener reduction: %.2f dB", returningPrimaryReductionDB),
            String(format: "Worst measured band reduction: %.2f dB", worstMeasuredBandReductionDB),
            String(format: "Primary baseline maximum drift: %.2f dB", largestPrimaryBaselineDifferenceDB),
            String(format: "Primary repeat improvement difference: %.2f dB", primaryReductionRepeatDifferenceDB),
            "Independent source / fault launches: \(uniqueExternalLaunchCount)",
            "Numerical bench criteria: passed for supplied records",
            "Independent instrument provenance: NOT AUTHENTICATED",
            "Measured physical attenuation: NOT VERIFIED",
            "Actual emergency analog mute: NOT VERIFIED",
            "Live ANC speaker output: DISCONNECTED"
        ].joined(separator: "\n")
    }
}

/// Bounded offline, control-thread-only A/B/A reproducibility assessment.
/// Does not treat three caller-supplied positive PR98 reviews as validation:
/// each underlying raw measurement is reanalyzed independently.
struct QuietZonePhysicalVerificationCampaignAnalyzer: Sendable {
    static let maximumCampaignSeconds: TimeInterval = 1800
    static let maximumReturnBaselineDifferenceDB = 1.5
    static let maximumPrimaryImprovementDifferenceDB = 1.5

    func analyze(
        rig: QuietZoneHardwareCalibrationRig,
        visits: [QuietZonePhysicalVerificationVisit],
        now: Date
    ) throws -> QuietZonePhysicalVerificationReview {
        guard visits.count == QuietZonePhysicalVerificationPosition.allCases.count
        else { throw QuietZonePhysicalVerificationFault.incompleteSurvey }
        guard visits.map(\.position) ==
            QuietZonePhysicalVerificationPosition.allCases
        else { throw QuietZonePhysicalVerificationFault.wrongVisitOrder }
        guard now.timeIntervalSince1970.isFinite,
              now >= visits[0].sessionStartedAt,
              now.timeIntervalSince(visits[0].sessionStartedAt)
                  <= Self.maximumCampaignSeconds
        else { throw QuietZonePhysicalVerificationFault.staleOrReorderedSessions }

        var sessions = Set<UUID>()
        var launchIDs = Set<String>()
        var previousEnd: Date?
        var calibrationID: String?
        var sourceID: String?
        var frequencyBins: [Double]?
        var primaryPositionID: String?
        var firstAndLastOff: [[QuietZoneSeatPowerBand]] = []
        var reports: [QuietZoneHardwareAcceptanceReview] = []

        for visit in visits {
            guard visit.rig == rig else {
                throw QuietZonePhysicalVerificationFault.changedHardwareRig
            }
            guard sessions.insert(visit.sessionID).inserted else {
                throw QuietZonePhysicalVerificationFault.duplicatedEvidence
            }
            let timestamps = visit.seatCaptures.map(\.measuredAt)
                + visit.faultProbes.map(\.measuredAt)
            guard timestamps.count == 8,
                  let lastEvent = timestamps.max(),
                  visit.sessionStartedAt <= lastEvent,
                  now >= lastEvent,
                  previousEnd.map({ visit.sessionStartedAt > $0 }) ?? true
            else { throw QuietZonePhysicalVerificationFault.staleOrReorderedSessions }
            previousEnd = lastEvent

            // Require raw PR98 measurements and FIVE independently claimed
            // external fault probes per visit. Never trust summary Bool flags.
            let testNow = lastEvent.addingTimeInterval(0.25)
            let result: QuietZoneHardwareAcceptanceReview
            do {
                result = try QuietZoneHardwareAcceptanceAnalyzer().analyze(
                    rig: rig, sessionID: visit.sessionID,
                    sessionStartedAt: visit.sessionStartedAt,
                    captures: visit.seatCaptures, faultProbes: visit.faultProbes,
                    now: testNow
                )
            } catch {
                throw QuietZonePhysicalVerificationFault.failedNumericalPreflight
            }
            reports.append(result)
            guard let first = visit.seatCaptures.first else {
                throw QuietZonePhysicalVerificationFault.incompleteSurvey
            }
            if calibrationID == nil { calibrationID = first.instrumentCalibrationID }
            if sourceID == nil { sourceID = first.independentSourceID }
            guard first.instrumentCalibrationID == calibrationID,
                  first.independentSourceID == sourceID,
                  visit.seatCaptures.allSatisfy({
                      $0.instrumentCalibrationID == calibrationID
                      && $0.independentSourceID == sourceID
                  }),
                  visit.faultProbes.allSatisfy({
                      $0.instrumentCalibrationID == calibrationID
                  })
            else { throw QuietZonePhysicalVerificationFault.changedInstrumentOrSource }
            let bins = first.bands.map(\.frequencyHz)
            if frequencyBins == nil { frequencyBins = bins }
            guard bins == frequencyBins else {
                throw QuietZonePhysicalVerificationFault.mismatchedFrequencyBands
            }
            if visit.position == .listenerFirst {
                primaryPositionID = first.listenerPositionID
            }
            if visit.position == .listenerReturn {
                guard first.listenerPositionID == primaryPositionID else {
                    throw QuietZonePhysicalVerificationFault.movedReturnMicrophone
                }
            }
            if visit.position == .neighboringSeat {
                guard first.listenerPositionID != primaryPositionID else {
                    throw QuietZonePhysicalVerificationFault.movedReturnMicrophone
                }
            }
            for id in visit.seatCaptures.map(\.launchID)
                + visit.faultProbes.map(\.launchID) {
                guard launchIDs.insert(id).inserted else {
                    throw QuietZonePhysicalVerificationFault.duplicatedEvidence
                }
            }
            if visit.position != .neighboringSeat {
                firstAndLastOff.append(visit.seatCaptures[0].bands)
                firstAndLastOff.append(visit.seatCaptures[2].bands)
            }
        }

        guard firstAndLastOff.count == 4,
              let sample = firstAndLastOff.first else {
            throw QuietZonePhysicalVerificationFault.incompleteSurvey
        }
        var largestDrift = 0.0
        for idx in sample.indices {
            let levels = firstAndLastOff.map { $0[idx].levelDBSPL }
            let drift = (levels.max() ?? 0) - (levels.min() ?? 0)
            largestDrift = max(largestDrift, drift)
            guard drift <= Self.maximumReturnBaselineDifferenceDB else {
                throw QuietZonePhysicalVerificationFault.changedNoiseBaseline
            }
        }
        let repeatDifference = abs(
            reports[0].integratedReductionDB - reports[2].integratedReductionDB
        )
        guard repeatDifference <=
            Self.maximumPrimaryImprovementDifferenceDB else {
            throw QuietZonePhysicalVerificationFault.unstableAttenuation
        }
        return .init(
            rig: rig, sessionIDs: visits.map(\.sessionID),
            firstPrimaryReductionDB: reports[0].integratedReductionDB,
            neighboringSeatReductionDB: reports[1].integratedReductionDB,
            returningPrimaryReductionDB: reports[2].integratedReductionDB,
            worstMeasuredBandReductionDB: reports.map(
                \.worstFrequencyReductionDB).min() ?? 0,
            largestPrimaryBaselineDifferenceDB: largestDrift,
            primaryReductionRepeatDifferenceDB: repeatDifference,
            worstReportedShutdownSeconds: reports.map(
                \.worstPhysicalMuteSeconds).max() ?? 0,
            uniqueExternalLaunchCount: launchIDs.count
        )
    }
}
