import Foundation

// E12 S6: pure logic behind the Verify and Save steps of the guided setup (design notes 7 to 9).
// No SwiftUI, no engine, nothing here runs on an audio thread. Gated by `e12.guided-setup` at the
// call sites. It adds no DSP: verification evidence comes from E10 S8's post-apply report and the
// Room insights come from the existing Room Advisor analyser.

// MARK: - Verification

enum SystemSetupVerificationError: Error, Equatable, LocalizedError {
    /// The live-graph measurement is not wired to this build of the flow.
    case measurementUnavailable
    case timedOut(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .measurementUnavailable:
            return "The result could not be measured again in this build, so the correction is saved as Not verified."
        case .timedOut(let seconds):
            return "The check did not finish in \(Int(seconds)) seconds, so the correction was reverted."
        }
    }
}

/// Measures the main seat again through the live graph after the correction is applied, and returns
/// the predicted-against-measured evidence. The real implementation wraps E10 S8's verifier.
@MainActor
protocol SystemSetupPostApplyMeasuring: AnyObject {
    func measureMainSeat(predictedErrorDB: Double, sampleRate: Double) async throws -> SystemSetupVerificationReport
}

/// Used until the live-graph host is wired: verification is reported as unavailable, never as passed.
@MainActor
final class UnconnectedSystemSetupPostApplyMeasurer: SystemSetupPostApplyMeasuring {
    func measureMainSeat(predictedErrorDB: Double, sampleRate: Double) async throws -> SystemSetupVerificationReport {
        throw SystemSetupVerificationError.measurementUnavailable
    }
}

extension SystemSetupVerificationReport {
    /// Maps E10 S8's stored report to the flow's report. `predictedErrorDB` is the main seat's predicted
    /// error against the target after correction; the measured error is the largest band mismatch.
    init(postApply: RoomCorrectionPostApplyReport, predictedErrorDB: Double) {
        self.init(
            passed: postApply.passed, predictedErrorDB: predictedErrorDB,
            measuredErrorDB: postApply.maxMagnitudeErrorDB, sampleRate: postApply.sampleRate)
    }
}

/// What the Verify step tells the user.
struct SystemSetupVerificationSummary: Equatable, Sendable {
    enum Verdict: Equatable, Sendable { case verified, notVerified, failed }

    var verdict: Verdict
    var headline: String
    var detail: String

    static func make(
        report: SystemSetupVerificationReport?, designKind: SystemSetupDesignKind, failure: String? = nil
    ) -> SystemSetupVerificationSummary {
        guard let report else {
            return .init(
                verdict: .notVerified, headline: "Not verified",
                detail: failure ?? "The result has not been measured again. You can still save, and the profile is labelled Not verified.")
        }
        if report.passed {
            return .init(
                verdict: .verified, headline: "Verified",
                detail: String(
                    format: "Predicted error %.1f dB, measured %.1f dB at the main seat.",
                    report.predictedErrorDB, report.measuredErrorDB))
        }
        if designKind == .minimumPhase {
            return .init(
                verdict: .notVerified, headline: "Not verified",
                detail: String(
                    format: "Measured error %.1f dB against a prediction of %.1f dB. The correction is kept and the profile is labelled Not verified.",
                    report.measuredErrorDB, report.predictedErrorDB))
        }
        return .init(
            verdict: .failed, headline: "Verification failed",
            detail: "The measured result did not match the design, so the correction was reverted.")
    }
}

// MARK: - Room insights (design note 8)

struct SystemSetupRoomInsight: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var isImportant: Bool
}

enum SystemSetupRoomInsights {
    /// Kinds of finding that EQ cannot fix: they are about the room itself, so the card points to treatment or placement.
    static let kinds: Set<RoomTreatmentAdvisorFindingKind> = [
        .lowFrequencyRinging, .deepBassCancellation, .boundaryInterferenceCandidate, .earlyReflection,
    ]

    /// Low-band decay above this is called out even when the advisor raised no ringing finding.
    static let longDecaySeconds = 0.6
    static let decayBandHz = 35.0...200.0

    static func make(report: RoomTreatmentAdvisorReport?) -> [SystemSetupRoomInsight] {
        guard let report else { return [] }
        var insights = report.findings
            .filter { kinds.contains($0.kind) && $0.severity != .information }
            .sorted { $0.severity.rawValue > $1.severity.rawValue }
            .map {
                SystemSetupRoomInsight(
                    id: $0.id, title: $0.title, detail: $0.recommendation, isImportant: $0.severity == .important)
            }
        let low = report.bandDecayMeasurements.filter {
            decayBandHz.contains($0.frequencyHz) && $0.fitR2 >= RoomTreatmentAdvisorAnalyzer.minimumDecayFitR2
        }
        if !low.isEmpty, !insights.contains(where: { $0.id == "rt60" }) {
            let mean = low.map(\.t20DerivedRT60Seconds).reduce(0, +) / Double(low.count)
            if mean >= longDecaySeconds {
                insights.append(
                    SystemSetupRoomInsight(
                        id: "rt60", title: "Bass decays slowly",
                        detail: String(
                            format: "Low bass takes about %.1f s to die away. EQ cannot shorten it; bass traps or speaker and listening-position changes can.",
                            mean),
                        isImportant: false))
            }
        }
        return insights
    }
}

// MARK: - Save (design note 7 and 9)

enum SystemSetupSaveNaming {
    static let notVerifiedSuffix = " (Not verified)"

    /// The stored profile name: the label travels with the profile so it is visible wherever profiles are listed.
    static func profileName(_ proposed: String, notVerified: Bool) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespaces)
        guard notVerified, !trimmed.hasSuffix(notVerifiedSuffix) else { return trimmed }
        return trimmed + notVerifiedSuffix
    }

    static func defaultName(outputName: String?) -> String {
        let base = outputName?.trimmingCharacters(in: .whitespaces) ?? ""
        return base.isEmpty ? "My system" : "\(base) setup"
    }
}
