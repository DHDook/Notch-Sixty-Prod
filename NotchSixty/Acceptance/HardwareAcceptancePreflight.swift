import Foundation

// MARK: - PR112A Slice 4: read-only physical-test preflight

struct HardwareAcceptancePreflightAttestations:
    Equatable, Codable, Sendable {
    var protectedDriverWiringConfirmed = false
    var sameADCMicrophoneAndReferenceConfirmed = false
    var commonOutputClockConfirmed = false
    var safeLineLevelReferenceConfirmed = false
}

enum HardwareAcceptancePreflightBlockerCode:
    String, Codable, CaseIterable, Sendable {
    case campaignExcluded
    case engineNotIdle
    case playbackSystemMismatch
    case playbackSystemStateDirty
    case selectedOutputMissing
    case selectedOutputMismatch
    case inputDeviceRequired
    case microphoneRequired
    case protectedRoutingRequired
    case protectedDriverProcessingRequired
    case protectedDriverWiringUnconfirmed
    case commissioningDraftRequired
    case commissioningDraftStateDrift
    case commissioningDraftInvalid
    case independentSubRouteRequired
    case sameADCReferenceUnconfirmed
    case commonOutputClockUnconfirmed
    case safeLineLevelReferenceUnconfirmed
    case liveFeedForwardANCNotAuthorized
}

struct HardwareAcceptancePreflightBlocker:
    Identifiable, Equatable, Codable, Sendable {
    var id: HardwareAcceptancePreflightBlockerCode { code }
    var code: HardwareAcceptancePreflightBlockerCode
    var message: String
}

struct HardwareAcceptanceRuntimeSnapshot:
    Equatable, Sendable {
    var lifecycleState: AudioLifecycleState
    var selectedPlaybackSystem: PlaybackSystemProfile?
    var selectedPlaybackSystemIsDirty: Bool
    var engineSelectedOutputUID: String?
}

struct HardwareAcceptancePreflightResult:
    Equatable, Codable, Sendable {
    var evaluatedAt: Date
    var campaignID: UUID
    var gateID: HardwareAcceptanceGateID
    var blockers: [HardwareAcceptancePreflightBlocker]
    var warnings: [String]
    var commissioningDraftID: UUID?
    var commissioningSessionID: UUID?

    var readyToBeginPhysicalTest: Bool { blockers.isEmpty }

    /// A preflight is never acceptance evidence. These remain hard false even
    /// when every prerequisite is satisfied.
    var physicalAcceptanceEstablished: Bool { false }
    var canSatisfyHardwareGate: Bool { false }
    var canApplyDSP: Bool { false }
    var canDeploy: Bool { false }
    var canAuthorizeLiveFeedForwardANC: Bool { false }
    var mayMergeIntoMain: Bool { false }
}

struct HardwareAcceptancePreflightAnalyzer: Sendable {
    func evaluate(
        campaign: HardwareAcceptanceCampaign,
        gateID: HardwareAcceptanceGateID,
        runtime: HardwareAcceptanceRuntimeSnapshot,
        environment: HardwareAcceptanceEnvironment,
        attestations: HardwareAcceptancePreflightAttestations,
        commissioningDraft: ProtectedDriverCommissioningDraft? = nil,
        evaluatedAt: Date = Date()
    ) -> HardwareAcceptancePreflightResult {
        var blockers: [HardwareAcceptancePreflightBlocker] = []
        var warnings: [String] = []

        let definition = HardwareAcceptanceCatalog.definition(gateID)
        if case .conditional(let capability)
            = definition.scopeRequirement,
           campaign.scopeDecisions[capability]?.isIncluded != true {
            blockers.append(
                .init(
                    code: .campaignExcluded,
                    message:
                        "\(gateID.rawValue) is excluded from this campaign scope. Start a new campaign to change scope."
                )
            )
        }

        guard let profile = runtime.selectedPlaybackSystem else {
            blockers.append(
                .init(
                    code: .playbackSystemMismatch,
                    message:
                        "Select the Playback System frozen into this acceptance campaign."
                )
            )
            return result(
                campaign: campaign,
                gateID: gateID,
                blockers: blockers,
                warnings: warnings,
                commissioningDraft: commissioningDraft,
                evaluatedAt: evaluatedAt
            )
        }

        if profile.id != campaign.identity.playbackSystemID {
            blockers.append(
                .init(
                    code: .playbackSystemMismatch,
                    message:
                        "Selected Playback System does not match the campaign identity."
                )
            )
        }
        if runtime.selectedPlaybackSystemIsDirty {
            blockers.append(
                .init(
                    code: .playbackSystemStateDirty,
                    message:
                        "Current Playback System differs from its saved profile. Save/revert it before physical acceptance work."
                )
            )
        }
        if runtime.lifecycleState != .idle {
            blockers.append(
                .init(
                    code: .engineNotIdle,
                    message:
                        "Stop processing before preflight; hardware acceptance begins from the idle control-plane state."
                )
            )
        }

        let selectedUID = runtime.engineSelectedOutputUID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedUID?.isEmpty != false {
            blockers.append(
                .init(
                    code: .selectedOutputMissing,
                    message:
                        "No stable selected physical output UID is active."
                )
            )
        } else {
            if environment.outputDeviceUID != selectedUID {
                blockers.append(
                    .init(
                        code: .selectedOutputMismatch,
                        message:
                            "Recorded physical output UID does not match the engine-selected output."
                    )
                )
            }
            if let associated = profile.state.associatedOutputUID,
               associated != selectedUID {
                blockers.append(
                    .init(
                        code: .selectedOutputMismatch,
                        message:
                            "Playback System is associated with a different physical output UID."
                    )
                )
            }
        }

        switch gateID {
        case .h01DeviceLifecycleRecovery:
            break

        case .h02ThermalResourceSpeakerSafety:
            warnings.append(
                "Preflight can verify identity only; real thermal, dropout, emergency-mute and speaker-safety behavior still require observation."
            )

        case .h03MeasurementBaselines,
             .h04SpeakerOptimizerVerification,
             .h06FIRPhysicalAcceptance:
            requireMeasurementInput(
                environment,
                blockers: &blockers
            )

        case .h05AdvancedMeasurementLab:
            requireMeasurementInput(
                environment,
                blockers: &blockers
            )
            if campaign.scopeDecisions[
                .protectedSplitDriverMeasurement
            ]?.isIncluded == true {
                validateProtectedDriverPreflight(
                    profile: profile,
                    draft: commissioningDraft,
                    attested:
                        attestations.protectedDriverWiringConfirmed,
                    blockers: &blockers,
                    warnings: &warnings
                )
            }

        case .h07CoherentMainSubAlignment:
            requireMeasurementInput(
                environment,
                blockers: &blockers
            )
            validateCoherentSubPreflight(
                profile: profile,
                environment: environment,
                attestations: attestations,
                blockers: &blockers,
                warnings: &warnings
            )

        case .h08LiveFeedForwardANC:
            blockers.append(
                .init(
                    code: .liveFeedForwardANCNotAuthorized,
                    message:
                        "PR112A never authorizes speaker-connected feed-forward ANC. H08 requires its separate physical safety protocol and independent review."
                )
            )
        }

        return result(
            campaign: campaign,
            gateID: gateID,
            blockers: blockers,
            warnings: warnings,
            commissioningDraft: commissioningDraft,
            evaluatedAt: evaluatedAt
        )
    }

    private func requireMeasurementInput(
        _ environment: HardwareAcceptanceEnvironment,
        blockers: inout [HardwareAcceptancePreflightBlocker]
    ) {
        if environment.inputDeviceUID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty != false {
            blockers.append(
                .init(
                    code: .inputDeviceRequired,
                    message:
                        "This gate requires a recorded physical ADC/input-device UID."
                )
            )
        }
        if environment.microphoneIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty != false {
            blockers.append(
                .init(
                    code: .microphoneRequired,
                    message:
                        "This gate requires the real measurement microphone/calibration identity."
                )
            )
        }
    }

    private func validateProtectedDriverPreflight(
        profile: PlaybackSystemProfile,
        draft: ProtectedDriverCommissioningDraft?,
        attested: Bool,
        blockers: inout [HardwareAcceptancePreflightBlocker],
        warnings: inout [String]
    ) {
        guard profile.state.outputRouting?.enabled == true,
              profile.state.bassManagement.enabled else {
            blockers.append(
                .init(
                    code: .protectedRoutingRequired,
                    message:
                        "Split-driver work requires enabled protected multi-output routing and active bass/crossover management."
                )
            )
            return
        }
        guard profile.state.speakerDriverProcessing != nil else {
            blockers.append(
                .init(
                    code: .protectedDriverProcessingRequired,
                    message:
                        "Split-driver work requires the protected per-driver processing state with limiter provenance."
                )
            )
            return
        }
        guard attested else {
            blockers.append(
                .init(
                    code: .protectedDriverWiringUnconfirmed,
                    message:
                        "Confirm the independently amplified driver wiring and protective crossover/limiter topology before any exposed-driver test."
                )
            )
            return
        }
        guard let draft else {
            blockers.append(
                .init(
                    code: .commissioningDraftRequired,
                    message:
                        "No matching PR111 commissioning draft is available for rollback/state-drift review."
                )
            )
            return
        }
        do {
            _ = try draft.validated()
            try ProtectedDriverCommissioningPlanner()
                .validateCurrentState(profile, against: draft)
        } catch ProtectedDriverCommissioningError.currentStateDrift {
            blockers.append(
                .init(
                    code: .commissioningDraftStateDrift,
                    message:
                        "Playback System changed since the PR111 commissioning draft; regenerate the draft before physical driver work."
                )
            )
            return
        } catch {
            blockers.append(
                .init(
                    code: .commissioningDraftInvalid,
                    message:
                        "PR111 commissioning provenance is invalid for the current system."
                )
            )
            return
        }

        guard draft.playbackSystemID == profile.id,
              !draft.canApply,
              !draft.canDeploy,
              draft.rollbackSnapshotAvailable,
              draft.stateDriftCheckRequired,
              draft.requiresPhysicalCombinedDriverCapture else {
            blockers.append(
                .init(
                    code: .commissioningDraftInvalid,
                    message:
                        "Commissioning draft no longer preserves the PR111 hardware-blocked rollback contract."
                )
            )
            return
        }

        let protectedBuses = draft.affectedBuses
        let processing = draft.rollbackPlaybackSystemState
            .speakerDriverProcessing
        guard !protectedBuses.isEmpty,
              protectedBuses.allSatisfy({
                  processing?.configuration(for: $0)
                    .limiterEnabled == true
              }) else {
            blockers.append(
                .init(
                    code: .protectedDriverProcessingRequired,
                    message:
                        "Every affected exposed-driver bus must retain limiter protection."
                )
            )
            return
        }

        warnings.append(
            "PR111 timing/polarity/PEQ remain unapplied. This preflight only permits the later protected combined-driver verification procedure to begin."
        )
    }

    private func validateCoherentSubPreflight(
        profile: PlaybackSystemProfile,
        environment: HardwareAcceptanceEnvironment,
        attestations: HardwareAcceptancePreflightAttestations,
        blockers: inout [HardwareAcceptancePreflightBlocker],
        warnings: inout [String]
    ) {
        guard let routing = profile.state.outputRouting,
              routing.enabled,
              routing.enabledRoutes.contains(where: {
                  $0.bus == .subMono
              }) else {
            blockers.append(
                .init(
                    code: .independentSubRouteRequired,
                    message:
                        "H07 requires an independently addressable Sub output route; a receiver pre-out chained from stereo mains is not sufficient."
                )
            )
            return
        }

        if !attestations.sameADCMicrophoneAndReferenceConfirmed {
            blockers.append(
                .init(
                    code: .sameADCReferenceUnconfirmed,
                    message:
                        "Confirm microphone and electrical reference are captured on separate channels of the same physical ADC."
                )
            )
        }
        if !attestations.commonOutputClockConfirmed {
            blockers.append(
                .init(
                    code: .commonOutputClockUnconfirmed,
                    message:
                        "Confirm Main and Sub playback share the required output clock domain."
                )
            )
        }
        if !attestations.safeLineLevelReferenceConfirmed
            || environment.referencePathDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty != false {
            blockers.append(
                .init(
                    code: .safeLineLevelReferenceUnconfirmed,
                    message:
                        "Document and confirm a safe line-level electrical reference. Never feed powered speaker/amplifier output into an ADC input."
                )
            )
        }
        warnings.append(
            "These confirmations are preflight declarations only; H07 still requires fresh coherent physical evidence and independent review."
        )
    }

    private func result(
        campaign: HardwareAcceptanceCampaign,
        gateID: HardwareAcceptanceGateID,
        blockers: [HardwareAcceptancePreflightBlocker],
        warnings: [String],
        commissioningDraft: ProtectedDriverCommissioningDraft?,
        evaluatedAt: Date
    ) -> HardwareAcceptancePreflightResult {
        HardwareAcceptancePreflightResult(
            evaluatedAt: evaluatedAt,
            campaignID: campaign.identity.id,
            gateID: gateID,
            blockers: blockers,
            warnings: warnings,
            commissioningDraftID: commissioningDraft?.id,
            commissioningSessionID: commissioningDraft?.sessionID
        )
    }
}

struct HardwareAcceptanceCommissioningDraftLocator: Sendable {
    let store: ProtectedDriverCommissioningDraftStore

    init(
        store: ProtectedDriverCommissioningDraftStore =
            ProtectedDriverCommissioningDraftStore()
    ) {
        self.store = store
    }

    func latest(
        for playbackSystemID: UUID
    ) throws -> ProtectedDriverCommissioningDraft? {
        guard FileManager.default.fileExists(
            atPath: store.rootDirectory.path
        ) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(
            at: store.rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var matches: [ProtectedDriverCommissioningDraft] = []
        for file in files
        where file.pathExtension.lowercased() == "json" {
            guard let sessionID = UUID(
                uuidString:
                    file.deletingPathExtension().lastPathComponent
            ),
            let draft = try? store.load(sessionID),
            draft.playbackSystemID == playbackSystemID else {
                continue
            }
            matches.append(draft)
        }
        return matches.max {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
