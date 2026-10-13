import Foundation

// MARK: - PR112A Slice 5: acceptance packet & runbook

enum HardwareAcceptanceReportGateState:
    String, Codable, Equatable, Sendable {
    case missing
    case excluded
    case blocked
    case failed
    case insufficientAuthority
    case insufficientScope
    case passed
}

struct HardwareAcceptanceReportScopeItem:
    Codable, Equatable, Sendable {
    var capability: HardwareAcceptanceCapability
    var included: Bool
    var exclusionReason: String?
}

struct HardwareAcceptanceReportGate:
    Codable, Equatable, Sendable {
    var id: HardwareAcceptanceGateID
    var title: String
    var requiredAuthority: HardwareAcceptanceEvidenceAuthority
    var state: HardwareAcceptanceReportGateState
    var accepted: Bool
    var observationID: UUID?
    var actualAuthority: HardwareAcceptanceEvidenceAuthority?
    var detail: String
    var supplementalCapabilities: [HardwareAcceptanceCapability]
}

struct HardwareAcceptanceReportArtifact:
    Codable, Equatable, Sendable {
    var gateID: HardwareAcceptanceGateID
    var observationID: UUID
    var label: String
    var identifier: String
    var sha256: String?
}

struct HardwareAcceptanceReportObservation:
    Codable, Equatable, Sendable {
    var id: UUID
    var recordedAt: Date
    var gateID: HardwareAcceptanceGateID
    var authority: HardwareAcceptanceEvidenceAuthority
    var outcome: HardwareAcceptanceObservationOutcome
    var reviewer: String
    var notes: String
    var coveredCapabilities: [HardwareAcceptanceCapability]
    var environment: HardwareAcceptanceEnvironment
    var artifacts: [HardwareAcceptanceArtifactReference]
}

struct HardwareAcceptanceRunbookStep:
    Codable, Equatable, Sendable {
    var gateID: HardwareAcceptanceGateID
    var title: String
    var includedInCampaign: Bool
    var requiredAuthority: HardwareAcceptanceEvidenceAuthority
    var currentState: HardwareAcceptanceReportGateState
    var objective: String
    var nextAction: String
    var safetyBoundary: String
}

struct HardwareAcceptanceReport:
    Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var generatedAt: Date
    var campaignIdentity: HardwareAcceptanceCampaignIdentity
    var scope: [HardwareAcceptanceReportScopeItem]
    var gates: [HardwareAcceptanceReportGate]
    var observations: [HardwareAcceptanceReportObservation]
    var artifactManifest: [HardwareAcceptanceReportArtifact]
    var unresolvedGateIDs: [HardwareAcceptanceGateID]
    var runbook: [HardwareAcceptanceRunbookStep]
    var physicalAcceptanceComplete: Bool
    var liveFeedForwardANCAuthorized: Bool

    // PR112A cannot confer commercial release or merge authority. Those
    // remain separate PR114 / owner-controlled decisions even if a future
    // physical campaign eventually passes every H01-H08 gate.
    var releaseAcceptanceComplete: Bool { false }
    var mayMergeIntoMain: Bool { false }
    var physicalEvidenceSuppliedByCI: Bool { false }
}

enum HardwareAcceptanceReportError:
    Error, Equatable, LocalizedError {
    case invalidCampaign
    case incompleteEvaluation

    var errorDescription: String? {
        switch self {
        case .invalidCampaign:
            return "Hardware acceptance report requires a valid campaign."
        case .incompleteEvaluation:
            return "Hardware acceptance evaluation did not produce every H01-H08 status."
        }
    }
}

struct HardwareAcceptanceReportBuilder: Sendable {
    func build(
        campaign: HardwareAcceptanceCampaign,
        generatedAt: Date = Date()
    ) throws -> HardwareAcceptanceReport {
        do {
            _ = try campaign.validated()
        } catch {
            throw HardwareAcceptanceReportError.invalidCampaign
        }
        let evaluation = try campaign.evaluate()
        guard evaluation.statuses.count
                == HardwareAcceptanceGateID.allCases.count else {
            throw HardwareAcceptanceReportError.incompleteEvaluation
        }

        let scope = HardwareAcceptanceCapability.allCases.map {
            capability in
            let decision = campaign.scopeDecisions[capability]!
            return HardwareAcceptanceReportScopeItem(
                capability: capability,
                included: decision.isIncluded,
                exclusionReason: decision.exclusionReason
            )
        }

        let gates = HardwareAcceptanceCatalog.gates.map {
            definition -> HardwareAcceptanceReportGate in
            gateReport(
                definition: definition,
                status: evaluation.statuses[definition.id]!
            )
        }

        let observations = campaign.observations
            .sorted {
                if $0.recordedAt != $1.recordedAt {
                    return $0.recordedAt < $1.recordedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map {
                HardwareAcceptanceReportObservation(
                    id: $0.id,
                    recordedAt: $0.recordedAt,
                    gateID: $0.gateID,
                    authority: $0.authority,
                    outcome: $0.outcome,
                    reviewer: $0.reviewer,
                    notes: $0.notes,
                    coveredCapabilities:
                        $0.coveredCapabilities.sorted {
                            $0.rawValue < $1.rawValue
                        },
                    environment: $0.environment,
                    artifacts: $0.artifacts.sorted {
                        if $0.label != $1.label {
                            return $0.label < $1.label
                        }
                        return $0.identifier < $1.identifier
                    }
                )
            }

        let artifacts = campaign.observations.flatMap {
            observation in
            observation.artifacts.map {
                HardwareAcceptanceReportArtifact(
                    gateID: observation.gateID,
                    observationID: observation.id,
                    label: $0.label,
                    identifier: $0.identifier,
                    sha256: $0.sha256
                )
            }
        }.sorted {
            if $0.gateID.rawValue != $1.gateID.rawValue {
                return $0.gateID.rawValue < $1.gateID.rawValue
            }
            if $0.observationID != $1.observationID {
                return $0.observationID.uuidString
                    < $1.observationID.uuidString
            }
            return $0.identifier < $1.identifier
        }

        let runbook = HardwareAcceptanceCatalog.gates.map {
            definition in
            let gate = gates.first { $0.id == definition.id }!
            return runbookStep(
                definition: definition,
                gate: gate,
                campaign: campaign
            )
        }

        return HardwareAcceptanceReport(
            generatedAt: generatedAt,
            campaignIdentity: campaign.identity,
            scope: scope,
            gates: gates,
            observations: observations,
            artifactManifest: artifacts,
            unresolvedGateIDs:
                evaluation.unresolvedGateIDs.sorted {
                    $0.rawValue < $1.rawValue
                },
            runbook: runbook,
            physicalAcceptanceComplete:
                evaluation.physicalAcceptanceComplete,
            liveFeedForwardANCAuthorized:
                evaluation.liveFeedForwardANCAuthorized
        )
    }

    private func gateReport(
        definition: HardwareAcceptanceGateDefinition,
        status: HardwareAcceptanceGateStatus
    ) -> HardwareAcceptanceReportGate {
        switch status {
        case .missing:
            return report(
                definition, state: .missing,
                detail: "No acceptance observation recorded."
            )
        case .excluded(let reason):
            return report(
                definition, state: .excluded,
                accepted: true,
                detail: "Excluded by immutable campaign scope: \(reason)"
            )
        case .blocked(let observationID):
            return report(
                definition, state: .blocked,
                observationID: observationID,
                detail: "Latest observation is BLOCKED."
            )
        case .failed(let observationID):
            return report(
                definition, state: .failed,
                observationID: observationID,
                detail: "Latest observation FAILED."
            )
        case .insufficientAuthority(
            let observationID,
            let actual,
            let required
        ):
            return report(
                definition,
                state: .insufficientAuthority,
                observationID: observationID,
                actualAuthority: actual,
                detail:
                    "Latest PASS has \(authorityName(actual)) authority; \(authorityName(required)) is required."
            )
        case .insufficientScope(
            let observationID,
            let missing
        ):
            return report(
                definition,
                state: .insufficientScope,
                observationID: observationID,
                detail:
                    "Latest PASS omitted required campaign coverage: \(missing.map(\.rawValue).sorted().joined(separator: ", "))."
            )
        case .passed(
            let observationID,
            let authority
        ):
            return report(
                definition,
                state: .passed,
                accepted: true,
                observationID: observationID,
                actualAuthority: authority,
                detail:
                    "Accepted by \(authorityName(authority)) evidence."
            )
        }
    }

    private func report(
        _ definition: HardwareAcceptanceGateDefinition,
        state: HardwareAcceptanceReportGateState,
        accepted: Bool = false,
        observationID: UUID? = nil,
        actualAuthority: HardwareAcceptanceEvidenceAuthority? = nil,
        detail: String
    ) -> HardwareAcceptanceReportGate {
        HardwareAcceptanceReportGate(
            id: definition.id,
            title: definition.title,
            requiredAuthority: definition.minimumAuthority,
            state: state,
            accepted: accepted,
            observationID: observationID,
            actualAuthority: actualAuthority,
            detail: detail,
            supplementalCapabilities:
                definition.supplementalCapabilities.sorted {
                    $0.rawValue < $1.rawValue
                }
        )
    }

    private func runbookStep(
        definition: HardwareAcceptanceGateDefinition,
        gate: HardwareAcceptanceReportGate,
        campaign: HardwareAcceptanceCampaign
    ) -> HardwareAcceptanceRunbookStep {
        let included: Bool
        if case .conditional(let capability)
            = definition.scopeRequirement {
            included =
                campaign.scopeDecisions[capability]?.isIncluded == true
        } else {
            included = true
        }

        return HardwareAcceptanceRunbookStep(
            gateID: definition.id,
            title: definition.title,
            includedInCampaign: included,
            requiredAuthority: definition.minimumAuthority,
            currentState: gate.state,
            objective: definition.evidenceSummary,
            nextAction: nextAction(
                gate: gate,
                included: included
            ),
            safetyBoundary: safetyBoundary(
                for: definition.id
            )
        )
    }

    private func nextAction(
        gate: HardwareAcceptanceReportGate,
        included: Bool
    ) -> String {
        guard included else {
            return "No physical procedure in this campaign; preserve the recorded exclusion reason."
        }
        if gate.accepted {
            return "Retain the accepted evidence and repeat only if hardware, routing, build, or measured state changes."
        }
        switch gate.state {
        case .missing:
            return "Run the recorded physical procedure and append evidence at the required authority."
        case .blocked:
            return "Resolve the recorded blocker, rerun the physical procedure, and append a new observation; never edit older evidence."
        case .failed:
            return "Correct the failure, rerun the complete physical procedure, and append a new independent observation."
        case .insufficientAuthority:
            return "Repeat or review the procedure at the required physical evidence authority; remote software evidence cannot be promoted."
        case .insufficientScope:
            return "Repeat the gate while exercising every included supplemental capability and record that coverage explicitly."
        case .excluded, .passed:
            return "No unresolved physical action."
        }
    }

    private func safetyBoundary(
        for gate: HardwareAcceptanceGateID
    ) -> String {
        switch gate {
        case .h01DeviceLifecycleRecovery:
            return "Use normal device lifecycle operations only; acceptance infrastructure does not start or mutate audio."
        case .h02ThermalResourceSpeakerSafety:
            return "Keep emergency mute or stop available and use speaker-safe levels; CI cannot establish thermal or loudspeaker safety."
        case .h03MeasurementBaselines:
            return "Use a calibrated real microphone and input identity and preserve the raw capture or session IDs."
        case .h04SpeakerOptimizerVerification:
            return "Require fresh before and after physical measurements and verified rollback; a stored optimizer receipt alone is insufficient."
        case .h05AdvancedMeasurementLab:
            return "Whole-speaker Lab remains mandatory. Protected driver work requires genuinely independent amplification, crossover and limiter protection."
        case .h06FIRPhysicalAcceptance:
            return "Verify real latency, headroom, clipping or XRuns, acoustic outcome and rollback on hardware; software convolution tests are insufficient."
        case .h07CoherentMainSubAlignment:
            return "Use microphone and safe line-level reference channels on the same ADC and a common output clock. Never feed speaker-level output directly into an ADC."
        case .h08LiveFeedForwardANC:
            return "Remain disabled unless deliberately in scope and independently physically reviewed; PR112A provides no live ANC authorization."
        }
    }

    private func authorityName(
        _ authority: HardwareAcceptanceEvidenceAuthority
    ) -> String {
        switch authority {
        case .remoteSoftware:
            return "remote-software"
        case .physicalHardware:
            return "physical-hardware"
        case .independentPhysicalReview:
            return "independent-physical-review"
        }
    }
}

struct HardwareAcceptanceReportExporter: Sendable {
    func jsonData(
        _ report: HardwareAcceptanceReport
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(report)
    }

    func markdownData(
        _ report: HardwareAcceptanceReport
    ) -> Data {
        Data(markdown(report).utf8)
    }

    func markdown(
        _ report: HardwareAcceptanceReport
    ) -> String {
        var lines: [String] = []
        lines.append("# Notch Sixty Hardware Acceptance Packet")
        lines.append("")
        lines.append("Campaign: \(report.campaignIdentity.id.uuidString)")
        lines.append(
            "Source: \(report.campaignIdentity.commitSHA) on \(report.campaignIdentity.branch)"
        )
        lines.append(
            "App: \(report.campaignIdentity.appVersion) (\(report.campaignIdentity.appBuild))"
        )
        lines.append(
            "Playback System: \(report.campaignIdentity.playbackSystemID.uuidString)"
        )
        lines.append("")
        lines.append(
            "Physical acceptance complete: \(report.physicalAcceptanceComplete ? "YES" : "NO")"
        )
        lines.append(
            "Live feed-forward ANC authorized: \(report.liveFeedForwardANCAuthorized ? "YES" : "NO")"
        )
        lines.append("Release acceptance complete: NO")
        lines.append("May merge into main: NO")
        lines.append("")
        lines.append(
            "PR112A reports evidence only. Remote CI cannot create physical evidence or release/merge authority."
        )
        lines.append("")
        lines.append("## Gate status")
        lines.append("")
        lines.append("| Gate | Status | Required authority | Detail |")
        lines.append("| --- | --- | --- | --- |")
        for gate in report.gates {
            lines.append(
                "| \(gate.id.rawValue) · \(escape(gate.title)) | \(gate.state.rawValue) | \(authorityName(gate.requiredAuthority)) | \(escape(gate.detail)) |"
            )
        }
        lines.append("")
        lines.append("## Unresolved gates")
        lines.append("")
        if report.unresolvedGateIDs.isEmpty {
            lines.append("None within the physical H01-H08 campaign.")
        } else {
            for id in report.unresolvedGateIDs {
                lines.append(
                    "- \(id.rawValue) · \(HardwareAcceptanceCatalog.definition(id).title)"
                )
            }
        }
        lines.append("")
        lines.append("## Scope")
        lines.append("")
        for item in report.scope {
            let value = item.included
                ? "included"
                : "excluded - \(item.exclusionReason ?? "no reason")"
            lines.append("- \(item.capability.rawValue): \(value)")
        }
        lines.append("")
        lines.append("## Artifact manifest")
        lines.append("")
        if report.artifactManifest.isEmpty {
            lines.append("No artifact references recorded.")
        } else {
            for artifact in report.artifactManifest {
                var suffix = ""
                if let sha = artifact.sha256 {
                    suffix = " · SHA-256 \(sha)"
                }
                lines.append(
                    "- \(artifact.gateID.rawValue) · \(escape(artifact.label)): \(artifact.identifier)\(suffix)"
                )
            }
        }
        lines.append("")
        lines.append("## Physical runbook")
        lines.append("")
        for step in report.runbook {
            lines.append(
                "### \(step.gateID.rawValue) · \(step.title)"
            )
            lines.append("")
            lines.append(
                "- In campaign: \(step.includedInCampaign ? "yes" : "no")"
            )
            lines.append(
                "- Required authority: \(authorityName(step.requiredAuthority))"
            )
            lines.append(
                "- Current state: \(step.currentState.rawValue)"
            )
            lines.append("- Objective: \(step.objective)")
            lines.append("- Next: \(step.nextAction)")
            lines.append(
                "- Safety boundary: \(step.safetyBoundary)"
            )
            lines.append("")
        }
        lines.append("## Evidence log")
        lines.append("")
        if report.observations.isEmpty {
            lines.append("No evidence observations recorded.")
        }
        for observation in report.observations {
            lines.append(
                "### \(observation.gateID.rawValue) · \(observation.outcome.rawValue.uppercased())"
            )
            lines.append("")
            lines.append(
                "- Observation: \(observation.id.uuidString)"
            )
            lines.append(
                "- Authority: \(authorityName(observation.authority))"
            )
            lines.append("- Reviewer: \(observation.reviewer)")
            lines.append("- Notes: \(observation.notes)")
            lines.append(
                "- Environment: \(observation.environment.macModel), \(observation.environment.macOSVersion), \(Int(observation.environment.sampleRate)) Hz / \(observation.environment.ioBufferFrames) frames"
            )
            lines.append(
                "- Output: \(observation.environment.outputDeviceName) (\(observation.environment.outputDeviceUID))"
            )
            if let input = observation.environment.inputDeviceUID {
                lines.append("- Input UID: \(input)")
            }
            if let mic = observation.environment.microphoneIdentifier {
                lines.append("- Microphone: \(mic)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func authorityName(
        _ authority: HardwareAcceptanceEvidenceAuthority
    ) -> String {
        switch authority {
        case .remoteSoftware:
            return "remote software"
        case .physicalHardware:
            return "physical hardware"
        case .independentPhysicalReview:
            return "independent physical review"
        }
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
