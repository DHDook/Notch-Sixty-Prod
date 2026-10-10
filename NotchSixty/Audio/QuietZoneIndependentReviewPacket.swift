import Foundation

/// Review acknowledgments are untrusted external assertions. Matching two
/// people to a digest does NOT cryptographically verify the instrument.
enum QuietZoneExternalReviewRole: String, CaseIterable, Sendable {
    case acoustics, electricalSafety
}

enum QuietZoneExternalReviewDecision: String, Sendable {
    case recommendFurtherHardwareReview, rejectEvidence
}

struct QuietZoneExternalReviewAcknowledgment: Sendable {
    let role: QuietZoneExternalReviewRole
    let reviewerID: String
    let evidenceSHA256Hex: String
    let reviewedAt: Date
    let decision: QuietZoneExternalReviewDecision
    let notes: String
}

enum QuietZoneExternalReviewFault: Error, Equatable {
    case incompleteReview, duplicateReviewer, mismatchedEvidence
    case expiredReview, rejectedEvidence, invalidReviewer
}

struct QuietZoneExternalReviewPacket: Sendable {
    let evidenceSHA256Hex: String
    let reviews: [QuietZoneExternalReviewAcknowledgment]
    let numericalAcceptance: Bool
    let independentRolesAcknowledged: Bool
    /// No key material, trusted instrument enrollment, or signatures exist.
    let reviewerIdentityCryptographicallyVerified: Bool = false
    let instrumentEvidenceIndependentlyAuthenticated: Bool = false
    let physicalAttenuationVerified: Bool = false
    let emergencyMuteHardwareVerified: Bool = false
    let liveANCQualified: Bool = false
    let outputConnected: Bool = false

    var reviewText: String {
        "PR99 review packet: two distinct claimed reviewers / digest " +
        evidenceSHA256Hex + " — numerical review ONLY; physical ANC unverified"
    }
}

/// Pure control-plane handoff. Requires two role-distinct reviewers and
/// unmodified canonical evidence, but cannot attest reviewer identity.
struct QuietZoneIndependentReviewPacketAnalyzer: Sendable {
    static let maximumReviewAgeSeconds: TimeInterval = 7 * 24 * 3600
    static let maximumReviewGapSeconds: TimeInterval = 24 * 3600

    func assess(
        package: QuietZonePhysicalEvidencePackage,
        reviews: [QuietZoneExternalReviewAcknowledgment],
        now: Date
    ) throws -> QuietZoneExternalReviewPacket {
        guard reviews.count == QuietZoneExternalReviewRole.allCases.count,
              Set(reviews.map(\.role)) ==
                Set(QuietZoneExternalReviewRole.allCases)
        else { throw QuietZoneExternalReviewFault.incompleteReview }
        guard try QuietZonePhysicalSpectralEvidenceAnalyzer().verifyDigest(
            canonicalJSON: package.canonicalJSON,
            expectedSHA256Hex: package.sha256Hex
        ) else { throw QuietZoneExternalReviewFault.mismatchedEvidence }
        guard package.rawSourceLaunchCount == 9,
              package.rawFaultWitnessCount == 15,
              package.campaignReview.allThreeNumericalReviewsPassed
        else { throw QuietZoneExternalReviewFault.mismatchedEvidence }

        var seen = Set<String>()
        for item in reviews {
            let reviewer = item.reviewerID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard reviewer.count >= 3, reviewer.count <= 128,
                  item.notes.utf8.count <= 4_096,
                  !item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw QuietZoneExternalReviewFault.invalidReviewer }
            guard seen.insert(reviewer.lowercased()).inserted else {
                throw QuietZoneExternalReviewFault.duplicateReviewer
            }
            guard item.evidenceSHA256Hex == package.sha256Hex else {
                throw QuietZoneExternalReviewFault.mismatchedEvidence
            }
            let age = now.timeIntervalSince(item.reviewedAt)
            guard age.isFinite, age >= 0,
                  age <= Self.maximumReviewAgeSeconds
            else { throw QuietZoneExternalReviewFault.expiredReview }
            guard item.decision == .recommendFurtherHardwareReview else {
                throw QuietZoneExternalReviewFault.rejectedEvidence
            }
        }
        let delta = abs(
            reviews[0].reviewedAt.timeIntervalSince(reviews[1].reviewedAt)
        )
        guard delta.isFinite,
              delta <= Self.maximumReviewGapSeconds
        else { throw QuietZoneExternalReviewFault.expiredReview }
        return .init(
            evidenceSHA256Hex: package.sha256Hex,
            reviews: reviews,
            numericalAcceptance: true,
            independentRolesAcknowledged: true
        )
    }
}
