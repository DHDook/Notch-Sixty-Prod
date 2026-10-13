import Foundation

// MARK: - PR112A remote hardware-acceptance infrastructure

/// Monotonic evidence authority. Higher authority may satisfy a lower
/// requirement, but remote CI can never satisfy a physical gate.
enum HardwareAcceptanceEvidenceAuthority:
    Int, Codable, CaseIterable, Comparable, Sendable {
    case remoteSoftware = 0
    case physicalHardware = 1
    case independentPhysicalReview = 2

    static func < (
        lhs: HardwareAcceptanceEvidenceAuthority,
        rhs: HardwareAcceptanceEvidenceAuthority
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum HardwareAcceptanceGateID:
    String, Codable, CaseIterable, Sendable {
    case h01DeviceLifecycleRecovery = "H01"
    case h02ThermalResourceSpeakerSafety = "H02"
    case h03MeasurementBaselines = "H03"
    case h04SpeakerOptimizerVerification = "H04"
    case h05AdvancedMeasurementLab = "H05"
    case h06FIRPhysicalAcceptance = "H06"
    case h07CoherentMainSubAlignment = "H07"
    case h08LiveFeedForwardANC = "H08"
}

enum HardwareAcceptanceCapability:
    String, Codable, CaseIterable, Sendable {
    case protectedSplitDriverMeasurement
    case coherentIndependentSubAlignment
    case liveFeedForwardANC
}

enum HardwareAcceptanceScopeRequirement:
    Equatable, Codable, Sendable {
    case required
    case conditional(HardwareAcceptanceCapability)
}

struct HardwareAcceptanceGateDefinition:
    Equatable, Codable, Sendable {
    var id: HardwareAcceptanceGateID
    var title: String
    var minimumAuthority: HardwareAcceptanceEvidenceAuthority
    var scopeRequirement: HardwareAcceptanceScopeRequirement
    var evidenceSummary: String
}

enum HardwareAcceptanceCatalog {
    static let gates: [HardwareAcceptanceGateDefinition] = [
        .init(
            id: .h01DeviceLifecycleRecovery,
            title: "Device & lifecycle recovery",
            minimumAuthority: .physicalHardware,
            scopeRequirement: .required,
            evidenceSummary:
                "Selected-device unplug/replug, same-UID recovery, sleep/wake, permissions, Stop/Start and Quit behavior on real hardware."
        ),
        .init(
            id: .h02ThermalResourceSpeakerSafety,
            title: "Thermal, resource & speaker safety",
            minimumAuthority: .independentPhysicalReview,
            scopeRequirement: .required,
            evidenceSummary:
                "Representative endurance, CPU/resource observation, dropout behavior, emergency mute and speaker-safe output review."
        ),
        .init(
            id: .h03MeasurementBaselines,
            title: "Speaker/Sub measurement baselines",
            minimumAuthority: .physicalHardware,
            scopeRequirement: .required,
            evidenceSummary:
                "Stable real-microphone speaker/sub baselines with source isolation and retained capture identity."
        ),
        .init(
            id: .h04SpeakerOptimizerVerification,
            title: "Speaker Optimizer verification",
            minimumAuthority: .independentPhysicalReview,
            scopeRequirement: .required,
            evidenceSummary:
                "Installed-speaker characterization, correction approval, fresh before/after measurement and rollback verification."
        ),
        .init(
            id: .h05AdvancedMeasurementLab,
            title: "Advanced Measurement Lab",
            minimumAuthority: .independentPhysicalReview,
            scopeRequirement:
                .conditional(.protectedSplitDriverMeasurement),
            evidenceSummary:
                "Whole-speaker Lab acceptance plus protected Low/Mid/High driver work only where independently routed, crossed-over and limited hardware exists."
        ),
        .init(
            id: .h06FIRPhysicalAcceptance,
            title: "FIR deployment & latency",
            minimumAuthority: .independentPhysicalReview,
            scopeRequirement: .required,
            evidenceSummary:
                "Real FIR latency/coherence/headroom, no clipping/XRuns, acoustic improvement, A/V coordination and rollback."
        ),
        .init(
            id: .h07CoherentMainSubAlignment,
            title: "Coherent Main/Sub alignment",
            minimumAuthority: .independentPhysicalReview,
            scopeRequirement:
                .conditional(.coherentIndependentSubAlignment),
            evidenceSummary:
                "Same-ADC microphone/reference and same-output-clock Main/Sub timing/polarity verification with a safe line-level reference."
        ),
        .init(
            id: .h08LiveFeedForwardANC,
            title: "Live feed-forward ANC",
            minimumAuthority: .independentPhysicalReview,
            scopeRequirement: .conditional(.liveFeedForwardANC),
            evidenceSummary:
                "Independent causality, clock and speaker-connected safety review. Remains disabled unless explicitly in release scope and passed."
        ),
    ]

    static func definition(
        _ id: HardwareAcceptanceGateID
    ) -> HardwareAcceptanceGateDefinition {
        // The static catalog is exhaustive by construction and is tested.
        gates.first { $0.id == id }!
    }
}

enum HardwareAcceptanceScopeDecision:
    Equatable, Codable, Sendable {
    case included
    case excluded(reason: String)

    var isIncluded: Bool {
        if case .included = self { return true }
        return false
    }

    var exclusionReason: String? {
        guard case .excluded(let reason) = self else { return nil }
        return reason
    }
}

struct HardwareAcceptanceCampaignIdentity:
    Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var commitSHA: String
    var branch: String
    var appVersion: String
    var appBuild: String
    var playbackSystemID: UUID

    func validated() throws -> Self {
        guard commitSHA.count >= 7,
              !branch.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              !appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              !appBuild.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            throw HardwareAcceptanceError.invalidCampaignIdentity
        }
        return self
    }
}

struct HardwareAcceptanceEnvironment:
    Equatable, Codable, Sendable {
    var macModel: String
    var macOSVersion: String
    var sampleRate: Double
    var ioBufferFrames: Int
    var outputDeviceName: String
    var outputDeviceUID: String
    var inputDeviceName: String?
    var inputDeviceUID: String?
    var microphoneIdentifier: String?
    var speakerTopology: String
    var referencePathDescription: String?

    func validated() throws -> Self {
        guard !macModel.isEmpty,
              !macOSVersion.isEmpty,
              sampleRate.isFinite,
              sampleRate > 0,
              ioBufferFrames > 0,
              !outputDeviceName.isEmpty,
              !outputDeviceUID.isEmpty,
              !speakerTopology.isEmpty else {
            throw HardwareAcceptanceError.invalidEnvironment
        }
        return self
    }
}

struct HardwareAcceptanceArtifactReference:
    Equatable, Codable, Sendable {
    var label: String
    /// Capture/session/report/build identifier. It need not be a file path.
    var identifier: String
    var sha256: String?

    func validated() throws -> Self {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              sha256.map({
                  $0.count == 64
                    && $0.allSatisfy { $0.isHexDigit }
              }) ?? true else {
            throw HardwareAcceptanceError.invalidArtifactReference
        }
        return self
    }
}

enum HardwareAcceptanceObservationOutcome:
    String, Equatable, Codable, Sendable {
    case passed
    case failed
    case blocked
}

struct HardwareAcceptanceObservation:
    Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    var recordedAt: Date = Date()
    var gateID: HardwareAcceptanceGateID
    var authority: HardwareAcceptanceEvidenceAuthority
    var outcome: HardwareAcceptanceObservationOutcome
    var environment: HardwareAcceptanceEnvironment
    var reviewer: String
    var notes: String
    var artifacts: [HardwareAcceptanceArtifactReference] = []

    func validated() throws -> Self {
        _ = try environment.validated()
        guard !reviewer.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              !notes.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              Set(artifacts.map(\.identifier)).count
                == artifacts.count else {
            throw HardwareAcceptanceError.invalidObservation
        }
        for artifact in artifacts {
            _ = try artifact.validated()
        }
        return self
    }
}

enum HardwareAcceptanceGateStatus:
    Equatable, Sendable {
    case missing
    case excluded(reason: String)
    case blocked(observationID: UUID)
    case failed(observationID: UUID)
    case insufficientAuthority(
        observationID: UUID,
        actual: HardwareAcceptanceEvidenceAuthority,
        required: HardwareAcceptanceEvidenceAuthority
    )
    case passed(
        observationID: UUID,
        authority: HardwareAcceptanceEvidenceAuthority
    )

    var accepted: Bool {
        switch self {
        case .passed, .excluded:
            return true
        default:
            return false
        }
    }
}

struct HardwareAcceptanceEvaluation:
    Equatable, Sendable {
    var statuses: [HardwareAcceptanceGateID:
        HardwareAcceptanceGateStatus]
    var physicalAcceptanceComplete: Bool
    var liveFeedForwardANCAuthorized: Bool

    var unresolvedGateIDs: [HardwareAcceptanceGateID] {
        HardwareAcceptanceGateID.allCases.filter {
            statuses[$0]?.accepted != true
        }
    }
}

struct HardwareAcceptanceCampaign:
    Equatable, Codable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumObservationCount = 512

    var schemaVersion: Int = currentSchemaVersion
    var identity: HardwareAcceptanceCampaignIdentity
    /// Conditional gates must be explicitly included or excluded. Required
    /// gates are always included regardless of entries here.
    var scopeDecisions: [HardwareAcceptanceCapability:
        HardwareAcceptanceScopeDecision]
    var observations: [HardwareAcceptanceObservation] = []

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion,
              observations.count <= Self.maximumObservationCount else {
            throw HardwareAcceptanceError.unsupportedSchema
        }
        _ = try identity.validated()
        guard Set(observations.map(\.id)).count
                == observations.count else {
            throw HardwareAcceptanceError.duplicateObservation
        }
        for capability in HardwareAcceptanceCapability.allCases {
            guard let decision = scopeDecisions[capability] else {
                throw HardwareAcceptanceError.missingScopeDecision
            }
            if case .excluded(let reason) = decision,
               reason.trimmingCharacters(
                in: .whitespacesAndNewlines
               ).isEmpty {
                throw HardwareAcceptanceError.invalidScopeDecision
            }
        }
        for observation in observations {
            _ = try observation.validated()
        }
        return self
    }

    func appending(
        _ observation: HardwareAcceptanceObservation
    ) throws -> Self {
        _ = try validated()
        _ = try observation.validated()
        guard observations.count < Self.maximumObservationCount,
              !observations.contains(where: {
                  $0.id == observation.id
              }) else {
            throw HardwareAcceptanceError.duplicateObservation
        }
        var copy = self
        copy.observations.append(observation)
        return try copy.validated()
    }

    func evaluate() throws -> HardwareAcceptanceEvaluation {
        _ = try validated()
        var statuses: [HardwareAcceptanceGateID:
            HardwareAcceptanceGateStatus] = [:]

        for definition in HardwareAcceptanceCatalog.gates {
            if case .conditional(let capability)
                = definition.scopeRequirement,
               let decision = scopeDecisions[capability],
               !decision.isIncluded {
                statuses[definition.id] = .excluded(
                    reason: decision.exclusionReason!
                )
                continue
            }

            let candidates = observations
                .filter { $0.gateID == definition.id }
                .sorted {
                    if $0.recordedAt != $1.recordedAt {
                        return $0.recordedAt > $1.recordedAt
                    }
                    return $0.id.uuidString > $1.id.uuidString
                }

            guard let newest = candidates.first else {
                statuses[definition.id] = .missing
                continue
            }
            switch newest.outcome {
            case .failed:
                statuses[definition.id] = .failed(
                    observationID: newest.id
                )
            case .blocked:
                statuses[definition.id] = .blocked(
                    observationID: newest.id
                )
            case .passed:
                if newest.authority
                    >= definition.minimumAuthority {
                    statuses[definition.id] = .passed(
                        observationID: newest.id,
                        authority: newest.authority
                    )
                } else {
                    statuses[definition.id] =
                        .insufficientAuthority(
                            observationID: newest.id,
                            actual: newest.authority,
                            required:
                                definition.minimumAuthority
                        )
                }
            }
        }

        let complete = HardwareAcceptanceGateID.allCases
            .allSatisfy { statuses[$0]?.accepted == true }

        let liveANCIncluded =
            scopeDecisions[.liveFeedForwardANC]?.isIncluded == true
        let liveANCStatus = statuses[.h08LiveFeedForwardANC]
        let liveANCAuthorized: Bool
        if liveANCIncluded,
           case .passed(
                _,
                let authority
           ) = liveANCStatus,
           authority >= .independentPhysicalReview,
           complete {
            liveANCAuthorized = true
        } else {
            liveANCAuthorized = false
        }

        return HardwareAcceptanceEvaluation(
            statuses: statuses,
            physicalAcceptanceComplete: complete,
            liveFeedForwardANCAuthorized: liveANCAuthorized
        )
    }
}

enum HardwareAcceptanceError:
    Error, Equatable, LocalizedError {
    case invalidCampaignIdentity
    case invalidEnvironment
    case invalidArtifactReference
    case invalidObservation
    case invalidScopeDecision
    case missingScopeDecision
    case duplicateObservation
    case unsupportedSchema
    case corruptPersistence
    case campaignIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidCampaignIdentity:
            return "Hardware acceptance campaign identity is incomplete."
        case .invalidEnvironment:
            return "Physical hardware environment metadata is incomplete or invalid."
        case .invalidArtifactReference:
            return "Hardware acceptance artifact reference is invalid."
        case .invalidObservation:
            return "Hardware acceptance observation is incomplete or invalid."
        case .invalidScopeDecision:
            return "Excluded hardware capability needs an explicit reason."
        case .missingScopeDecision:
            return "Every topology-conditional capability needs an explicit included/excluded decision."
        case .duplicateObservation:
            return "Hardware acceptance evidence IDs must be unique and append-only."
        case .unsupportedSchema:
            return "Hardware acceptance campaign schema is unsupported."
        case .corruptPersistence:
            return "Hardware acceptance campaign data is corrupt; existing evidence was not overwritten."
        case .campaignIdentityMismatch:
            return "Loaded hardware acceptance campaign identity does not match the requested campaign."
        }
    }
}

struct HardwareAcceptanceCampaignStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? Self.defaultRootDirectory()
    }

    func url(for campaignID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(campaignID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    func create(_ campaign: HardwareAcceptanceCampaign) throws {
        _ = try campaign.validated()
        let path = url(for: campaign.identity.id)
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw HardwareAcceptanceError.duplicateObservation
        }
        try persist(campaign, to: path)
    }

    func load(_ campaignID: UUID)
        throws -> HardwareAcceptanceCampaign? {
        let path = url(for: campaignID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let campaign = try decoder.decode(
                HardwareAcceptanceCampaign.self,
                from: Data(contentsOf: path)
            )
            guard campaign.identity.id == campaignID else {
                throw HardwareAcceptanceError
                    .campaignIdentityMismatch
            }
            return try campaign.validated()
        } catch let error as HardwareAcceptanceError {
            throw error
        } catch {
            throw HardwareAcceptanceError.corruptPersistence
        }
    }

    @discardableResult
    func append(
        _ observation: HardwareAcceptanceObservation,
        to campaignID: UUID
    ) throws -> HardwareAcceptanceCampaign {
        guard let current = try load(campaignID) else {
            throw HardwareAcceptanceError
                .campaignIdentityMismatch
        }
        let updated = try current.appending(observation)
        try persist(updated, to: url(for: campaignID))
        return updated
    }

    private func persist(
        _ campaign: HardwareAcceptanceCampaign,
        to path: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(campaign).write(
            to: path,
            options: .atomic
        )
    }

    private static func defaultRootDirectory() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return root
            .appendingPathComponent(
                "Notch Sixty",
                isDirectory: true
            )
            .appendingPathComponent(
                "Hardware Acceptance",
                isDirectory: true
            )
    }
}
