import Combine
import Foundation

enum HardwareAcceptanceWorkflowError:
    Error, Equatable, LocalizedError {
    case campaignRequired
    case physicalAttestationRequired
    case independentReviewAttestationRequired
    case gateExcludedFromScope
    case invalidSupplementalCoverage

    var errorDescription: String? {
        switch self {
        case .campaignRequired:
            return "Create or load a hardware acceptance campaign first."
        case .physicalAttestationRequired:
            return "Physical-hardware evidence requires explicit confirmation that the observation was performed on the recorded hardware."
        case .independentReviewAttestationRequired:
            return "Independent physical review evidence requires a separate explicit reviewer attestation."
        case .gateExcludedFromScope:
            return "This conditional gate is excluded from the current campaign scope. Change scope only by creating a new campaign."
        case .invalidSupplementalCoverage:
            return "The observation claims supplemental coverage that does not belong to this gate or is excluded from campaign scope."
        }
    }
}

@MainActor
final class HardwareAcceptanceController: ObservableObject {
    let store: HardwareAcceptanceCampaignStore

    @Published private(set)
    var campaign: HardwareAcceptanceCampaign?
    @Published private(set)
    var evaluation: HardwareAcceptanceEvaluation?
    @Published private(set)
    var errorDescription: String?

    init(store: HardwareAcceptanceCampaignStore =
        HardwareAcceptanceCampaignStore()) {
        self.store = store
    }

    func prepareForUse() {
        do {
            try loadMostRecentCampaign()
            errorDescription = nil
        } catch {
            campaign = nil
            evaluation = nil
            errorDescription = error.localizedDescription
        }
    }

    func createCampaign(
        identity: HardwareAcceptanceCampaignIdentity,
        scopeDecisions: [HardwareAcceptanceCapability:
            HardwareAcceptanceScopeDecision]
    ) throws {
        let value = HardwareAcceptanceCampaign(
            identity: identity,
            scopeDecisions: scopeDecisions
        )
        _ = try value.validated()
        try store.create(value)
        campaign = value
        evaluation = try value.evaluate()
        errorDescription = nil
    }

    func loadCampaign(_ id: UUID) throws {
        guard let value = try store.load(id) else {
            throw HardwareAcceptanceWorkflowError
                .campaignRequired
        }
        campaign = value
        evaluation = try value.evaluate()
        errorDescription = nil
    }

    func loadMostRecentCampaign() throws {
        let ids = try store.existingCampaignIDs()
        var values: [HardwareAcceptanceCampaign] = []
        values.reserveCapacity(ids.count)
        for id in ids {
            guard let value = try store.load(id) else { continue }
            values.append(value)
        }
        guard let newest = values.max(by: {
            if $0.identity.createdAt != $1.identity.createdAt {
                return $0.identity.createdAt
                    < $1.identity.createdAt
            }
            return $0.identity.id.uuidString
                < $1.identity.id.uuidString
        }) else {
            campaign = nil
            evaluation = nil
            errorDescription = nil
            return
        }
        campaign = newest
        evaluation = try newest.evaluate()
        errorDescription = nil
    }

    func recordObservation(
        _ observation: HardwareAcceptanceObservation,
        physicalAttestationConfirmed: Bool,
        independentReviewAttestationConfirmed: Bool
    ) throws {
        guard let current = campaign else {
            throw HardwareAcceptanceWorkflowError
                .campaignRequired
        }
        let definition = HardwareAcceptanceCatalog
            .definition(observation.gateID)

        if case .conditional(let capability)
            = definition.scopeRequirement,
           current.scopeDecisions[capability]?.isIncluded
            != true {
            throw HardwareAcceptanceWorkflowError
                .gateExcludedFromScope
        }

        let allowedSupplemental = Set(
            definition.supplementalCapabilities
        )
        let claimedSupplemental = Set(
            observation.coveredCapabilities
        )
        guard claimedSupplemental.isSubset(
            of: allowedSupplemental
        ),
        claimedSupplemental.allSatisfy({
            current.scopeDecisions[$0]?.isIncluded == true
        }) else {
            throw HardwareAcceptanceWorkflowError
                .invalidSupplementalCoverage
        }

        if observation.authority >= .physicalHardware,
           !physicalAttestationConfirmed {
            throw HardwareAcceptanceWorkflowError
                .physicalAttestationRequired
        }
        if observation.authority
            >= .independentPhysicalReview,
           !independentReviewAttestationConfirmed {
            throw HardwareAcceptanceWorkflowError
                .independentReviewAttestationRequired
        }

        let updated = try store.append(
            observation,
            to: current.identity.id
        )
        campaign = updated
        evaluation = try updated.evaluate()
        errorDescription = nil
    }

    func status(
        for gate: HardwareAcceptanceGateID
    ) -> HardwareAcceptanceGateStatus {
        evaluation?.statuses[gate] ?? .missing
    }

    func isGateIncluded(
        _ gate: HardwareAcceptanceGateID
    ) -> Bool {
        let definition = HardwareAcceptanceCatalog
            .definition(gate)
        switch definition.scopeRequirement {
        case .required:
            return true
        case .conditional(let capability):
            return campaign?.scopeDecisions[capability]?
                .isIncluded == true
        }
    }

    func supplementalCapabilityIsIncluded(
        _ capability: HardwareAcceptanceCapability
    ) -> Bool {
        campaign?.scopeDecisions[capability]?
            .isIncluded == true
    }
}
