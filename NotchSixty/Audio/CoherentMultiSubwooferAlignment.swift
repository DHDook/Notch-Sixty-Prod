import Foundation

struct CoherentMultiSubwooferAlignmentEvidenceGroup:
    Equatable, Sendable {
    var subwooferIndex: UInt32
    var reports: [SpeakerMeasurementLabCoherentTimingReport]
}

struct CoherentMultiSubwooferAlignmentSubPlan:
    Codable, Equatable, Sendable {
    var subwooferIndex: UInt32
    var signedRelativeDelayAdjustmentMilliseconds: Double
    /// Added physical delay after solving the one shared speaker delay.
    var subwooferDelayAdjustmentMilliseconds: Double
    var toggleSubwooferPolarity: Bool
    var resultingSubwooferPolarityInverted: Bool
    var predictedCoherenceBeforeDB: Double
    var predictedCoherenceAfterDB: Double
    var predictedImprovementDB: Double
}

struct CoherentMultiSubwooferAlignmentCandidate:
    Codable, Equatable, Sendable {
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var sampleRate: Double
    var crossoverFrequencyHz: Double
    var mainRoles: [OutputProgramRole]
    /// One common delay applied to every non-LFE semantic speaker.
    var speakerCommonDelayAdjustmentMilliseconds: Double
    var subwoofers: [CoherentMultiSubwooferAlignmentSubPlan]
    var predictedCoherenceBeforeDB: Double
    var predictedCoherenceAfterDB: Double
    var predictedImprovementDB: Double
    var evidenceConfidence: Double
    var acceptedForPreview: Bool
    var blockingReasons: [String]

    var previewOnly: Bool { true }
    var canDeploy: Bool { false }
    var isMeasuredVerification: Bool { false }
}

enum CoherentMultiSubwooferAlignmentError:
    Error, Equatable, LocalizedError {
    case multiSubProfileRequired
    case evidenceSetIncomplete
    case duplicateSubwoofer(UInt32)
    case mainRoleSetMismatch
    case crossSubIdentityMismatch
    case delayCapacityExceeded(MultichannelCalibrationSource)

    var errorDescription: String? {
        switch self {
        case .multiSubProfileRequired:
            return "Coordinated PR108 alignment requires at least two assigned physical subwoofers."
        case .evidenceSetIncomplete:
            return "Coordinated PR108 alignment requires one coherent evidence group for every assigned physical subwoofer."
        case .duplicateSubwoofer(let index):
            return "Coordinated PR108 evidence contains duplicate Sub \(index + 1)."
        case .mainRoleSetMismatch:
            return "Every physical Sub must be measured against the same set of Main speaker roles before coordinated alignment."
        case .crossSubIdentityMismatch:
            return "All coordinated Sub evidence must share one Playback System, route, microphone, sample rate and crossover context."
        case .delayCapacityExceeded(let source):
            return "The coordinated common-speaker/per-Sub delay materialization exceeds the realtime delay budget for \(source.displayName)."
        }
    }
}

/// PR108 coordinated multi-Sub proposal.
///
/// Each Sub first receives its own bounded coherent optimum s_i where positive
/// means "delay this Sub" and negative means "advance this Sub". One physical
/// system cannot advance a Sub, and independent single-Sub compensation would
/// repeatedly add speaker delay.
///
/// The coordinated realization solves:
///
///     D_i - C = s_i
///
/// with one shared nonnegative speaker delay C and nonnegative per-Sub delays
/// D_i. The minimum-latency solution is:
///
///     C   = max(0, -min(s_i))
///     D_i = C + s_i
///
/// This preserves every independently measured relative optimum while adding
/// the least possible common latency. Capacity is then checked against the
/// CURRENT speaker/Sub calibration values before the candidate is accepted.
struct CoherentMultiSubwooferAlignmentPlanner: Sendable {
    func propose(
        evidenceGroups:
            [CoherentMultiSubwooferAlignmentEvidenceGroup],
        profile: OutputDeviceProfileConfiguration,
        bassManagementEnabled: Bool,
        crossoverFrequencyHz: Double,
        options: CoherentSubwooferAlignmentOptions = .init()
    ) throws -> CoherentMultiSubwooferAlignmentCandidate {
        guard profile.subwooferAssignments.count >= 2 else {
            throw CoherentMultiSubwooferAlignmentError
                .multiSubProfileRequired
        }
        let assigned = Set(
            profile.subwooferAssignments.map(\.index)
        )
        guard evidenceGroups.count == assigned.count,
              Set(evidenceGroups.map(\.subwooferIndex))
                == assigned else {
            throw CoherentMultiSubwooferAlignmentError
                .evidenceSetIncomplete
        }
        guard Set(evidenceGroups.map(\.subwooferIndex)).count
                == evidenceGroups.count else {
            let seen = Dictionary(
                grouping: evidenceGroups,
                by: \.subwooferIndex
            )
            let duplicate = seen.first {
                $0.value.count > 1
            }?.key ?? 0
            throw CoherentMultiSubwooferAlignmentError
                .duplicateSubwoofer(duplicate)
        }

        var permissiveOptions = options
        // A Sub that is already coherent must remain a valid no-op member of a
        // coordinated solve. Aggregate improvement is enforced after all Subs.
        permissiveOptions.minimumPredictedImprovementDB = 0

        var singles:
            [CoherentSubwooferAlignmentCandidate] = []
        singles.reserveCapacity(evidenceGroups.count)
        for group in evidenceGroups.sorted(by: {
            $0.subwooferIndex < $1.subwooferIndex
        }) {
            guard !group.reports.isEmpty,
                  group.reports.allSatisfy({
                      $0.subwoofer
                        == .subwoofer(group.subwooferIndex)
                  }) else {
                throw CoherentMultiSubwooferAlignmentError
                    .evidenceSetIncomplete
            }
            let candidate = try CoherentSubwooferAlignmentPlanner()
                .propose(
                    reports: group.reports,
                    profile: profile,
                    bassManagementEnabled:
                        bassManagementEnabled,
                    crossoverFrequencyHz:
                        crossoverFrequencyHz,
                    options: permissiveOptions,
                    coordinatedMultiSubwooferMode: true
                )
            singles.append(candidate)
        }

        guard let first = singles.first else {
            throw CoherentMultiSubwooferAlignmentError
                .evidenceSetIncomplete
        }
        let mainRoleSet = Set(first.mainRoles)
        guard singles.allSatisfy({
            $0.playbackSystemID == first.playbackSystemID
                && $0.routingSignature == first.routingSignature
                && $0.microphone == first.microphone
                && abs($0.sampleRate - first.sampleRate) < 0.5
                && abs(
                    $0.crossoverFrequencyHz
                        - first.crossoverFrequencyHz
                ) < 1.0e-9
        }) else {
            throw CoherentMultiSubwooferAlignmentError
                .crossSubIdentityMismatch
        }
        guard singles.allSatisfy({
            Set($0.mainRoles) == mainRoleSet
        }) else {
            throw CoherentMultiSubwooferAlignmentError
                .mainRoleSetMismatch
        }

        let minimumSigned = singles
            .map(\.signedRelativeDelayAdjustmentMilliseconds)
            .min() ?? 0
        let commonSpeakerDelay = max(0, -minimumSigned)

        try validateSpeakerCapacity(
            additionalMilliseconds: commonSpeakerDelay,
            profile: profile,
            sampleRate: first.sampleRate
        )

        var subPlans:
            [CoherentMultiSubwooferAlignmentSubPlan] = []
        subPlans.reserveCapacity(singles.count)
        for single in singles.sorted(by: {
            $0.subwooferIndex < $1.subwooferIndex
        }) {
            let addedSubDelay = max(
                0,
                commonSpeakerDelay
                    + single
                        .signedRelativeDelayAdjustmentMilliseconds
            )
            try validateSubCapacity(
                index: single.subwooferIndex,
                additionalMilliseconds: addedSubDelay,
                profile: profile,
                sampleRate: first.sampleRate
            )
            subPlans.append(
                CoherentMultiSubwooferAlignmentSubPlan(
                    subwooferIndex: single.subwooferIndex,
                    signedRelativeDelayAdjustmentMilliseconds:
                        single
                            .signedRelativeDelayAdjustmentMilliseconds,
                    subwooferDelayAdjustmentMilliseconds:
                        addedSubDelay,
                    toggleSubwooferPolarity:
                        single.toggleSubwooferPolarity,
                    resultingSubwooferPolarityInverted:
                        single
                            .resultingSubwooferPolarityInverted,
                    predictedCoherenceBeforeDB:
                        single.predictedCoherenceBeforeDB,
                    predictedCoherenceAfterDB:
                        single.predictedCoherenceAfterDB,
                    predictedImprovementDB:
                        single.predictedImprovementDB
                )
            )
        }

        let beforeEnergy = singles.reduce(0.0) {
            $0 + pow(
                10,
                $1.predictedCoherenceBeforeDB / 10
            )
        } / Double(singles.count)
        let afterEnergy = singles.reduce(0.0) {
            $0 + pow(
                10,
                $1.predictedCoherenceAfterDB / 10
            )
        } / Double(singles.count)
        let beforeDB = 10 * log10(max(1.0e-12, beforeEnergy))
        let afterDB = 10 * log10(max(1.0e-12, afterEnergy))
        let improvement = afterDB - beforeDB

        var blockers = singles.flatMap {
            $0.blockingReasons
        }
        if singles.contains(where: {
            !$0.acceptedForPreview
        }) {
            blockers.append(
                "At least one physical Sub lacks a bounded coherent timing/polarity solution."
            )
        }
        if improvement + 1.0e-9
            < options.minimumPredictedImprovementDB {
            blockers.append(
                "The coordinated multi-Sub solve does not provide enough aggregate crossover-coherence improvement."
            )
        }

        return CoherentMultiSubwooferAlignmentCandidate(
            playbackSystemID: first.playbackSystemID,
            routingSignature: first.routingSignature,
            microphone: first.microphone,
            sampleRate: first.sampleRate,
            crossoverFrequencyHz:
                first.crossoverFrequencyHz,
            mainRoles: first.mainRoles,
            speakerCommonDelayAdjustmentMilliseconds:
                commonSpeakerDelay,
            subwoofers: subPlans,
            predictedCoherenceBeforeDB: beforeDB,
            predictedCoherenceAfterDB: afterDB,
            predictedImprovementDB: improvement,
            evidenceConfidence:
                singles.map(\.evidenceConfidence).min() ?? 0,
            acceptedForPreview: blockers.isEmpty,
            blockingReasons: blockers
        )
    }

    private func validateSpeakerCapacity(
        additionalMilliseconds: Double,
        profile: OutputDeviceProfileConfiguration,
        sampleRate: Double
    ) throws {
        for assignment in profile.speakerAssignments
        where assignment.role != .lowFrequencyEffects {
            let proposed =
                (assignment.calibration?
                    .delayMilliseconds ?? 0)
                + additionalMilliseconds
            guard SemanticSpeakerCalibration
                    .delayRangeMilliseconds
                    .contains(proposed),
                  proposed * sampleRate / 1_000
                    <= Double(
                        N60_PROGRAM_LANE_MAX_DELAY_FRAMES
                    ) else {
                throw CoherentMultiSubwooferAlignmentError
                    .delayCapacityExceeded(
                        .speaker(assignment.role)
                    )
            }
        }
    }

    private func validateSubCapacity(
        index: UInt32,
        additionalMilliseconds: Double,
        profile: OutputDeviceProfileConfiguration,
        sampleRate: Double
    ) throws {
        guard let assignment =
                profile.subwooferAssignments.first(where: {
                    $0.index == index
                }) else {
            throw CoherentMultiSubwooferAlignmentError
                .evidenceSetIncomplete
        }
        let proposed =
            (assignment.calibration?.delayMilliseconds ?? 0)
            + additionalMilliseconds
        guard PhysicalSubwooferCalibration
                .delayRangeMilliseconds.contains(proposed),
              proposed * sampleRate / 1_000
                <= Double(N60_SUBWOOFER_MAX_DELAY_FRAMES) else {
            throw CoherentMultiSubwooferAlignmentError
                .delayCapacityExceeded(.subwoofer(index))
        }
    }
}
