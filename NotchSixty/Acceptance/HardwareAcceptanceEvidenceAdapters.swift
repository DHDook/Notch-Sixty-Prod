import Foundation

enum HardwareAcceptanceLinkedEvidenceKind:
    String, Codable, Sendable {
    case speakerOptimizerBaseline
    case speakerOptimizerPEQVerification
    case measurementLabSession
    case speakerOptimizerFIRVerification
    case coherentSingleSubVerification
    case coherentMultiSubVerification
}

struct HardwareAcceptanceLinkedEvidence:
    Equatable, Sendable {
    var gateID: HardwareAcceptanceGateID
    var kind: HardwareAcceptanceLinkedEvidenceKind
    var playbackSystemID: UUID
    var routingSignature: String
    var recommendedOutcome: HardwareAcceptanceObservationOutcome
    var artifacts: [HardwareAcceptanceArtifactReference]
    var coveredCapabilities: [HardwareAcceptanceCapability]
    var summary: String

    /// Linking typed app evidence makes a later physical review auditable,
    /// but never proves that CI or the app authenticated real hardware.
    var automaticAuthority:
        HardwareAcceptanceEvidenceAuthority { .remoteSoftware }
    var canEstablishPhysicalAuthority: Bool { false }
    var canAuthorizeLiveFeedForwardANC: Bool { false }

    func validated() throws -> Self {
        guard gateID != .h01DeviceLifecycleRecovery,
              gateID != .h02ThermalResourceSpeakerSafety,
              gateID != .h08LiveFeedForwardANC,
              !routingSignature.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !summary.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !artifacts.isEmpty,
              Set(artifacts.map(\.identifier)).count
                == artifacts.count,
              Set(coveredCapabilities).count
                == coveredCapabilities.count else {
            throw HardwareAcceptanceEvidenceAdapterError
                .invalidLinkedEvidence
        }
        for artifact in artifacts {
            _ = try artifact.validated()
        }
        return self
    }
}

enum HardwareAcceptanceEvidenceAdapterError:
    Error, Equatable, LocalizedError {
    case invalidLinkedEvidence
    case identityMismatch
    case baselineRequired
    case measurementUnqualified
    case wholeSpeakerLabRequired
    case incompleteLabSession
    case verificationReceiptMismatch
    case verificationNotFinalized
    case coherentVerificationRejected

    var errorDescription: String? {
        switch self {
        case .invalidLinkedEvidence:
            return "Linked hardware-acceptance evidence is incomplete or invalid."
        case .identityMismatch:
            return "Linked evidence does not belong to one Playback System/routing identity."
        case .baselineRequired:
            return "H03 requires a Speaker Optimizer baseline measurement set."
        case .measurementUnqualified:
            return "The linked measurement did not pass its existing repeat/quality checks."
        case .wholeSpeakerLabRequired:
            return "H05 requires at least one whole-speaker Measurement Lab protocol."
        case .incompleteLabSession:
            return "H05 requires every selected Measurement Lab protocol to have all planned repeated captures."
        case .verificationReceiptMismatch:
            return "The measured verification does not match the linked finalization receipt."
        case .verificationNotFinalized:
            return "A provisional Apply is not H04/H06/H07 acceptance evidence until its measured verification was finalized."
        case .coherentVerificationRejected:
            return "The coherent Main/Sub measured verification was rejected."
        }
    }
}

struct HardwareAcceptanceEvidenceAdapter: Sendable {
    func h03Baseline(
        _ set: SpeakerOptimizerMeasurementSet
    ) throws -> HardwareAcceptanceLinkedEvidence {
        guard set.role == .baseline else {
            throw HardwareAcceptanceEvidenceAdapterError
                .baselineRequired
        }
        let report = try SpeakerOptimizerMeasurementEvidenceEvaluator()
            .evaluate(set)
        let outcome: HardwareAcceptanceObservationOutcome =
            report.optimizerReady ? .passed : .failed
        let artifacts = [
            HardwareAcceptanceArtifactReference(
                label: "Speaker Optimizer baseline set",
                identifier: set.id.uuidString
            )
        ] + set.captures.map {
            HardwareAcceptanceArtifactReference(
                label: "Baseline capture",
                identifier: $0.id.uuidString
            )
        }
        return try HardwareAcceptanceLinkedEvidence(
            gateID: .h03MeasurementBaselines,
            kind: .speakerOptimizerBaseline,
            playbackSystemID: set.playbackSystemID,
            routingSignature: set.routingSignature,
            recommendedOutcome: outcome,
            artifacts: artifacts,
            coveredCapabilities: [],
            summary:
                report.optimizerReady
                ? "Repeat-qualified Speaker Optimizer baseline; physical microphone placement/source isolation still require human hardware attestation."
                : "Speaker Optimizer baseline exists but failed its existing repeat/quality qualification."
        ).validated()
    }

    func h04PEQVerification(
        _ report: SpeakerOptimizerPostApplyVerificationReport,
        finalization:
            SpeakerOptimizerPEQVerificationFinalizationReceipt
    ) throws -> HardwareAcceptanceLinkedEvidence {
        guard finalization.applyReceiptID == report.applyReceiptID,
              finalization.verificationMeasurementSetID
                == report.verificationMeasurementSetID,
              finalization.playbackSystemID
                == report.playbackSystemID else {
            throw HardwareAcceptanceEvidenceAdapterError
                .verificationReceiptMismatch
        }
        let outcome: HardwareAcceptanceObservationOutcome =
            report.accepted ? .passed : .failed
        return try HardwareAcceptanceLinkedEvidence(
            gateID: .h04SpeakerOptimizerVerification,
            kind: .speakerOptimizerPEQVerification,
            playbackSystemID: report.playbackSystemID,
            routingSignature: report.routingSignature,
            recommendedOutcome: outcome,
            artifacts: [
                .init(
                    label: "Speaker Optimizer PEQ Apply receipt",
                    identifier: report.applyReceiptID.uuidString
                ),
                .init(
                    label: "Speaker Optimizer baseline set",
                    identifier:
                        report.baselineMeasurementSetID.uuidString
                ),
                .init(
                    label: "Speaker Optimizer verification set",
                    identifier:
                        report.verificationMeasurementSetID.uuidString
                ),
            ],
            coveredCapabilities: [],
            summary:
                report.accepted
                ? "Finalized fresh PEQ measured verification linked. H04 still needs independent physical-review authority."
                : "Finalized PEQ verification was rejected and should remain failed/rolled back."
        ).validated()
    }

    func h05MeasurementLab(
        _ session: SpeakerMeasurementLabSession
    ) throws -> HardwareAcceptanceLinkedEvidence {
        do { try session.validateStructure() }
        catch {
            throw HardwareAcceptanceEvidenceAdapterError
                .incompleteLabSession
        }

        let wholeSpeaker = session.protocols.filter {
            $0.request.mode == .wholeSpeakerOnAxis
                || $0.request.mode == .wholeSpeakerOffAxis
        }
        guard !wholeSpeaker.isEmpty else {
            throw HardwareAcceptanceEvidenceAdapterError
                .wholeSpeakerLabRequired
        }
        guard session.protocols.allSatisfy({ labProtocol in
            session.captures.filter {
                $0.protocolID == labProtocol.id
            }.count == labProtocol.request.repeatCount
        }) else {
            throw HardwareAcceptanceEvidenceAdapterError
                .incompleteLabSession
        }

        let compact = try SpeakerMeasurementLabReportBuilder()
            .build(session: session)
        let protectedProtocols = session.protocols.filter {
            $0.request.mode == .protectedDriverNearField
        }
        let protectedCoverage = try protectedDriverCoverage(
            session: session,
            protocols: protectedProtocols
        )
        let hasUnavailableAnalysis =
            compact.analysisSummaries.contains { !$0.available }

        return try HardwareAcceptanceLinkedEvidence(
            gateID: .h05AdvancedMeasurementLab,
            kind: .measurementLabSession,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            recommendedOutcome:
                hasUnavailableAnalysis ? .blocked : .passed,
            artifacts: [
                .init(
                    label: "Measurement Lab session",
                    identifier: session.id.uuidString
                )
            ] + session.captures.map {
                .init(
                    label: "Measurement Lab capture",
                    identifier: $0.id.uuidString
                )
            },
            coveredCapabilities:
                protectedCoverage
                ? [.protectedSplitDriverMeasurement]
                : [],
            summary:
                hasUnavailableAnalysis
                ? "Completed whole-speaker Lab session contains unavailable analysis products; review blockers before physical H05 acceptance."
                : "Completed whole-speaker Lab session linked. Physical geometry, microphone placement, speaker safety and reviewer authority remain human-verified."
        ).validated()
    }

    func h06FIRVerification(
        _ report: SpeakerOptimizerPostApplyVerificationReport,
        finalization:
            SpeakerOptimizerFIRVerificationFinalizationReceipt
    ) throws -> HardwareAcceptanceLinkedEvidence {
        guard finalization.applyReceiptID == report.applyReceiptID,
              finalization.verificationMeasurementSetID
                == report.verificationMeasurementSetID,
              finalization.playbackSystemID
                == report.playbackSystemID else {
            throw HardwareAcceptanceEvidenceAdapterError
                .verificationReceiptMismatch
        }
        return try HardwareAcceptanceLinkedEvidence(
            gateID: .h06FIRPhysicalAcceptance,
            kind: .speakerOptimizerFIRVerification,
            playbackSystemID: report.playbackSystemID,
            routingSignature: report.routingSignature,
            recommendedOutcome:
                report.accepted ? .passed : .failed,
            artifacts: [
                .init(
                    label: "Speaker Optimizer FIR Apply receipt",
                    identifier: report.applyReceiptID.uuidString
                ),
                .init(
                    label: "FIR baseline measurement set",
                    identifier:
                        report.baselineMeasurementSetID.uuidString
                ),
                .init(
                    label: "FIR verification measurement set",
                    identifier:
                        report.verificationMeasurementSetID.uuidString
                ),
            ],
            coveredCapabilities: [],
            summary:
                report.accepted
                ? "Finalized FIR measured verification linked. Real latency/headroom/XRun/A-V and acoustic review remain H06 physical work."
                : "Finalized FIR verification was rejected and cannot satisfy H06."
        ).validated()
    }

    func h07SingleSubVerification(
        _ report: CoherentSubwooferAlignmentVerificationReport,
        finalization:
            CoherentSubwooferAlignmentVerificationFinalizationReceipt
    ) throws -> HardwareAcceptanceLinkedEvidence {
        guard finalization.applyReceiptID == report.applyReceiptID,
              finalization.verificationSessionID
                == report.verificationSessionID,
              finalization.playbackSystemID
                == report.playbackSystemID else {
            throw HardwareAcceptanceEvidenceAdapterError
                .verificationReceiptMismatch
        }
        return try coherentLinkedEvidence(
            kind: .coherentSingleSubVerification,
            playbackSystemID: report.playbackSystemID,
            routingSignature: report.routingSignature,
            applyReceiptID: report.applyReceiptID,
            verificationSessionID: report.verificationSessionID,
            accepted: report.accepted,
            summary:
                report.accepted
                ? "Finalized coherent single-Sub measured verification linked. Same-ADC/reference wiring and output-clock safety still require independent physical review."
                : "Coherent single-Sub measured verification was rejected."
        )
    }

    func h07MultiSubVerification(
        _ report:
            CoherentMultiSubwooferAlignmentVerificationReport,
        finalization:
            CoherentMultiSubwooferAlignmentVerificationFinalizationReceipt
    ) throws -> HardwareAcceptanceLinkedEvidence {
        guard finalization.applyReceiptID == report.applyReceiptID,
              finalization.playbackSystemID
                == report.playbackSystemID else {
            throw HardwareAcceptanceEvidenceAdapterError
                .verificationReceiptMismatch
        }
        return try coherentLinkedEvidence(
            kind: .coherentMultiSubVerification,
            playbackSystemID: report.playbackSystemID,
            routingSignature: report.routingSignature,
            applyReceiptID: report.applyReceiptID,
            verificationSessionID: report.verificationSessionID,
            accepted: report.accepted,
            summary:
                report.accepted
                ? "Finalized coordinated multi-Sub measured verification linked. Same-ADC/reference and output-clock topology remain independently reviewed H07 evidence."
                : "Coordinated multi-Sub measured verification was rejected."
        )
    }

    private func coherentLinkedEvidence(
        kind: HardwareAcceptanceLinkedEvidenceKind,
        playbackSystemID: UUID,
        routingSignature: String,
        applyReceiptID: UUID,
        verificationSessionID: UUID,
        accepted: Bool,
        summary: String
    ) throws -> HardwareAcceptanceLinkedEvidence {
        try HardwareAcceptanceLinkedEvidence(
            gateID: .h07CoherentMainSubAlignment,
            kind: kind,
            playbackSystemID: playbackSystemID,
            routingSignature: routingSignature,
            recommendedOutcome: accepted ? .passed : .failed,
            artifacts: [
                .init(
                    label: "Coherent alignment Apply receipt",
                    identifier: applyReceiptID.uuidString
                ),
                .init(
                    label: "Coherent verification Lab session",
                    identifier: verificationSessionID.uuidString
                ),
            ],
            coveredCapabilities: [
                .coherentIndependentSubAlignment
            ],
            summary: summary
        ).validated()
    }

    private func protectedDriverCoverage(
        session: SpeakerMeasurementLabSession,
        protocols: [SpeakerMeasurementLabProtocol]
    ) throws -> Bool {
        guard !protocols.isEmpty else { return false }
        for labProtocol in protocols {
            guard let bus = labProtocol.protectedDriverBus else {
                return false
            }
            let captures = session.captures.filter {
                $0.protocolID == labProtocol.id
            }
            guard captures.count == labProtocol.request.repeatCount,
                  captures.allSatisfy({
                      $0.protectedDriverProvenance?
                        .validatesProtectedPath(for: bus)
                        == true
                        && $0.quality.sweepComplete
                        && !$0.quality.clipped
                  }) else {
                return false
            }
        }
        return true
    }
}
