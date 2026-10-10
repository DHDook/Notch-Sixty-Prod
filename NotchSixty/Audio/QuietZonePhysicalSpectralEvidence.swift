import Foundation
import CryptoKit

/// Additional PR99 review failures. These do not grant live speaker access.
enum QuietZonePhysicalSpectralFault: Error, Equatable, LocalizedError {
    case failedCampaign
    case inconsistentFrequencyReduction
    case invalidEvidence
    case corruptedEvidencePackage

    var errorDescription: String? {
        switch self {
        case .failedCampaign:
            return "A complete A–B–A raw acoustic campaign must pass PR99 first."
        case .inconsistentFrequencyReduction:
            return "The return-to-listener improvement differs in an individual frequency band."
        case .invalidEvidence:
            return "A raw evidence field or spectral power cannot be represented faithfully."
        case .corruptedEvidencePackage:
            return "The evidence package digest no longer matches its canonical payload."
        }
    }
}

struct QuietZonePhysicalFrequencyVerification: Sendable {
    let frequencyHz: Double
    let primaryFirstReductionDB: Double
    let neighboringSeatReductionDB: Double
    let primaryReturnReductionDB: Double
    let primaryRepeatDifferenceDB: Double
    let worstObservedReductionDB: Double
    let primaryFourBaselineSpanDB: Double
}

/// A self-consistent, portable *record digest*, not an independent signature.
struct QuietZonePhysicalEvidencePackage: Sendable {
    let schemaVersion: Int
    let canonicalJSON: String
    let sha256Hex: String
    let frequencyResults: [QuietZonePhysicalFrequencyVerification]
    let campaignReview: QuietZonePhysicalVerificationReview
    let maximumPrimaryBandRepeatDifferenceDB: Double
    let worstFrequencyReductionDB: Double
    let rawSourceLaunchCount: Int
    let rawFaultWitnessCount: Int

    // The digest cannot authenticate any microphone, sound meter or human.
    let recordsDigestVerified: Bool = true
    let instrumentEvidenceIndependentlyAuthenticated: Bool = false
    let physicalAcousticReductionVerified: Bool = false
    let emergencyAnalogMuteVerified: Bool = false
    let outputConnected: Bool = false
    let liveANCQualified: Bool = false

    var reviewText: String {
        var lines = [
            "PR99 spectral evidence — PROVISIONAL / instrument UNVERIFIED",
            "SHA-256 (integrity only): \(sha256Hex)",
            "Measured bins: \(frequencyResults.count)",
            String(format: "Worst-band benefit: %.2f dB",
                   worstFrequencyReductionDB),
            String(format: "Worst A-return band variation: %.2f dB",
                   maximumPrimaryBandRepeatDifferenceDB),
            "Raw launches: \(rawSourceLaunchCount)",
            "Raw fault witnesses: \(rawFaultWitnessCount)"
        ]
        for band in frequencyResults {
            lines.append(
                String(format: "%.1f Hz: A %.2f dB; B %.2f dB; A-return %.2f dB",
                       band.frequencyHz, band.primaryFirstReductionDB,
                       band.neighboringSeatReductionDB,
                       band.primaryReturnReductionDB)
            )
        }
        lines.append("Physical evidence authenticated: NO")
        lines.append("Speaker ANC output connected: NO")
        return lines.joined(separator: "\n")
    }
}

struct QuietZonePhysicalSpectralEvidenceAnalyzer: Sendable {
    /// Independent of the earlier *aggregate* 1.5 dB improvement tolerance:
    /// it is not acceptable to hide a >1.5 dB single-bin discrepancy with
    /// compensating improvements elsewhere in the measured spectrum.
    static let maximumPrimaryBandRepeatDifferenceDB = 1.5
    static let schemaVersion = 1

    func compile(
        rig: QuietZoneHardwareCalibrationRig,
        visits: [QuietZonePhysicalVerificationVisit],
        now: Date
    ) throws -> QuietZonePhysicalEvidencePackage {
        let campaign: QuietZonePhysicalVerificationReview
        do {
            campaign = try QuietZonePhysicalVerificationCampaignAnalyzer().analyze(
                rig: rig, visits: visits, now: now
            )
        } catch {
            throw QuietZonePhysicalSpectralFault.failedCampaign
        }
        guard visits.count == 3,
              visits.allSatisfy({ $0.seatCaptures.count == 3 }),
              let base = visits.first?.seatCaptures.first?.bands
        else { throw QuietZonePhysicalSpectralFault.invalidEvidence }

        var result: [QuietZonePhysicalFrequencyVerification] = []
        var largestDifference = 0.0
        var leastReduction = Double.infinity
        for index in base.indices {
            var improvements: [Double] = []
            for visit in visits {
                let before = visit.seatCaptures[0].bands[index].levelDBSPL
                let during = visit.seatCaptures[1].bands[index].levelDBSPL
                let after = visit.seatCaptures[2].bands[index].levelDBSPL
                // PR98 uses linear-power average of independent OFF captures.
                let baselinePower = (pow(10, before / 10) + pow(10, after / 10))
                    / 2.0
                let treatmentPower = pow(10, during / 10)
                let reduction = 10 * log10(baselinePower / treatmentPower)
                guard reduction.isFinite else {
                    throw QuietZonePhysicalSpectralFault.invalidEvidence
                }
                improvements.append(reduction)
            }
            let repeatDifference = abs(improvements[0] - improvements[2])
            let allPrimaryOff = [
                visits[0].seatCaptures[0].bands[index].levelDBSPL,
                visits[0].seatCaptures[2].bands[index].levelDBSPL,
                visits[2].seatCaptures[0].bands[index].levelDBSPL,
                visits[2].seatCaptures[2].bands[index].levelDBSPL
            ]
            guard let biggest = allPrimaryOff.max(),
                  let smallest = allPrimaryOff.min(),
                  repeatDifference.isFinite else {
                throw QuietZonePhysicalSpectralFault.invalidEvidence
            }
            largestDifference = max(largestDifference, repeatDifference)
            let worst = improvements.min() ?? -.infinity
            leastReduction = min(leastReduction, worst)
            result.append(.init(
                frequencyHz: base[index].frequencyHz,
                primaryFirstReductionDB: improvements[0],
                neighboringSeatReductionDB: improvements[1],
                primaryReturnReductionDB: improvements[2],
                primaryRepeatDifferenceDB: repeatDifference,
                worstObservedReductionDB: worst,
                primaryFourBaselineSpanDB: biggest - smallest
            ))
        }
        guard largestDifference <= Self.maximumPrimaryBandRepeatDifferenceDB
        else { throw QuietZonePhysicalSpectralFault.inconsistentFrequencyReduction }

        // All native Double fields are serialized as EXACT IEEE-754 bit
        // patterns: no rounding, locale dependence, hidden +/-0 or lost
        // floating-point precision across independent exports.
        func ieee(_ value: Double) throws -> String {
            guard value.isFinite else {
                throw QuietZonePhysicalSpectralFault.invalidEvidence
            }
            return String(format: "%016llx", value.bitPattern)
        }
        func timestamp(_ date: Date) throws -> String {
            try ieee(date.timeIntervalSince1970)
        }
        let rigFields: [String] = [
            "RIG", rig.projectID.uuidString.lowercased(), rig.microphoneID,
            String(rig.microphoneChannel), rig.outputDeviceID, rig.routeID,
            try ieee(rig.sampleRate), rig.clockID, rig.triggerID
        ]
        var canonical: [[String]] = [
            ["SCHEMA", "PR99_PHYSICAL_EVIDENCE", String(Self.schemaVersion)],
            rigFields
        ]
        for visit in visits {
            canonical.append([
                "VISIT", String(visit.position.rawValue),
                visit.sessionID.uuidString.lowercased(),
                try timestamp(visit.sessionStartedAt)
            ])
            for capture in visit.seatCaptures {
                canonical.append([
                    "SOURCE", String(capture.phase.rawValue),
                    capture.sessionID.uuidString.lowercased(),
                    capture.launchID, capture.independentSourceID,
                    capture.instrumentCalibrationID,
                    capture.listenerPositionID,
                    try timestamp(capture.measuredAt),
                    try ieee(capture.measuredCoherence),
                    try ieee(capture.maximumSeatLevelDBSPL),
                    capture.speakerOutputClipped ? "1" : "0",
                    try ieee(capture.maximumLeftSamplePeak),
                    try ieee(capture.maximumRightSamplePeak)
                ])
                for b in capture.bands {
                    canonical.append([
                        "BAND", try ieee(b.frequencyHz),
                        try ieee(b.levelDBSPL)
                    ])
                }
            }
            for witness in visit.faultProbes {
                canonical.append([
                    "FAULT", witness.fault.rawValue,
                    witness.sessionID.uuidString.lowercased(),
                    witness.launchID, witness.instrumentCalibrationID,
                    try timestamp(witness.measuredAt),
                    try ieee(witness.detectedAtHostSeconds),
                    try ieee(witness.physicalMuteReachedAtHostSeconds),
                    try ieee(witness.outputResidualDBFS),
                    witness.noAutomaticRearmObserved ? "1" : "0"
                ])
            }
        }
        let data = try JSONEncoder().encode(canonical)
        guard let json = String(data: data, encoding: .utf8) else {
            throw QuietZonePhysicalSpectralFault.invalidEvidence
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return .init(
            schemaVersion: Self.schemaVersion,
            canonicalJSON: json,
            sha256Hex: digest,
            frequencyResults: result,
            campaignReview: campaign,
            maximumPrimaryBandRepeatDifferenceDB: largestDifference,
            worstFrequencyReductionDB: leastReduction,
            rawSourceLaunchCount: visits.reduce(0) {
                $0 + $1.seatCaptures.count
            },
            rawFaultWitnessCount: visits.reduce(0) {
                $0 + $1.faultProbes.count
            }
        )
    }

    /// Validates package integrity only, never signatures or sound-meter
    /// authenticity. A malicious recorder can alter data AND recompute hash.
    func verifyDigest(
        canonicalJSON: String,
        expectedSHA256Hex: String
    ) throws -> Bool {
        guard let bytes = canonicalJSON.data(using: .utf8),
              expectedSHA256Hex.count == 64,
              expectedSHA256Hex.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              let rows = try? JSONDecoder().decode([[String]].self, from: bytes),
              rows.first == ["SCHEMA", "PR99_PHYSICAL_EVIDENCE",
                             String(Self.schemaVersion)],
              let roundtrip = try? JSONEncoder().encode(rows),
              roundtrip == bytes
        else { throw QuietZonePhysicalSpectralFault.corruptedEvidencePackage }
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256Hex else {
            throw QuietZonePhysicalSpectralFault.corruptedEvidencePackage
        }
        return true
    }
}
