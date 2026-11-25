import Foundation

// E12 S16 (G16, G18): what the Speakers page and the distances-and-levels table need to decide, as plain values. No
// SwiftUI, no engine, nothing on an audio thread.

/// Which part of the system handles bass and routing right now.
enum SpeakersBassOwner: Equatable, Sendable {
    /// The speaker routing matrix (per-driver crossovers and routes).
    case routingMatrix
    /// The speaker arrangement's bass settings (the logical stereo crossover and the sub phase alignment).
    case arrangement
}

struct SpeakersPageModel: Equatable, Sendable {
    var owner: SpeakersBassOwner
    /// The line at the top of the page.
    var ownerLine: String
    /// The arrangement's bass cards are shown (the arrangement owns bass). The older Crossover Design and Sub Phase
    /// Alignment cards are retired (S16b); their settings are carried by `SpeakersBassMigration`.
    var showsArrangementBassCards: Bool
    /// The routing editor is open by default (the matrix owns routing).
    var routingEditorExpanded: Bool
    /// The older logical crossover is still playing while the matrix is in charge: shown read-only, with its reason.
    var legacyBassNote: String?
    /// Older bass settings that could not be carried keep playing and are shown read-only with their reason (S16b).
    var legacyBassSummary: String?

    static func make(
        matrixEnabled: Bool, bass: BassManagementConfiguration, legacyRoutingReason: String?,
        carry: SpeakersBassMigration.Outcome = .nothingToCarry
    ) -> SpeakersPageModel {
        if matrixEnabled {
            var note: String?
            if bass.enabled {
                note = "An older crossover is still playing (\(Int(bass.frequencyHz.rounded())) Hz, "
                    + "\(bass.topology.displayName)). The routing matrix is in charge of bass, so this setting is "
                    + "shown for reference and is not edited here. Turn it off by choosing a matrix template "
                    + "that includes the crossover."
            }
            return SpeakersPageModel(
                owner: .routingMatrix,
                ownerLine: "Bass and routing are handled by the routing matrix below. The arrangement's own bass settings are not used.",
                showsArrangementBassCards: false, routingEditorExpanded: true, legacyBassNote: note,
                legacyBassSummary: nil)
        }
        var line = "Bass is handled by your speaker arrangement"
        line += bass.enabled ? " (crossover \(Int(bass.frequencyHz.rounded())) Hz)." : " (no crossover is on)."
        line += " Open the routing matrix below to take over with per-driver control."
        if let legacyRoutingReason {
            line = "Bass and routing use an older physical crossover that the routing matrix cannot represent "
                + "(\(legacyRoutingReason)). It keeps playing as stored."
        }
        var summary: String?
        if case .keepsPlaying(let reason) = carry { summary = SpeakersBassMigration.summary(of: bass, reason: reason) }
        return SpeakersPageModel(
            owner: .arrangement, ownerLine: line, showsArrangementBassCards: true,
            routingEditorExpanded: false, legacyBassNote: nil, legacyBassSummary: summary)
    }
}

// MARK: Distances and levels (G18)

enum DistanceUnit: String, CaseIterable, Identifiable, Sendable {
    case metres, feet
    var id: String { rawValue }
    var title: String { self == .metres ? "m" : "ft" }
}

/// One speaker's row in the distances and levels table.
struct SpeakerFeedRow: Identifiable, Equatable, Sendable {
    enum Side: String, Sendable { case left, right }
    var side: Side
    var name: String
    var feed: SpeakerFeedCalibration
    /// The measured values, when an alignment was applied; nil otherwise.
    var measured: SpeakerFeedCalibration?
    var id: String { side.rawValue }
    /// A manual change from what was measured. Never true without a measurement to compare to.
    var isManual: Bool { measured.map { $0 != feed } ?? false }
}

enum SpeakerFeedTable {
    /// Speed of sound used to turn delay into distance (m/s, dry air near 20 C).
    static let speedOfSound = 343.0
    static let metresPerFoot = 0.3048

    /// The rows for a two-channel (feed session) arrangement; empty otherwise.
    static func rows(arrangement: SystemArrangement?, measured: MeasuredFeedCalibration?) -> [SpeakerFeedRow] {
        guard let arrangement, SystemSetupAdaptiveSteps.isFeedSession(arrangement) else { return [] }
        let alignment = arrangement.stereoAlignment ?? StereoBassAlignment()
        return [
            SpeakerFeedRow(side: .left, name: "Left", feed: alignment.left, measured: measured?.left),
            SpeakerFeedRow(side: .right, name: "Right", feed: alignment.right, measured: measured?.right),
        ]
    }

    /// The distance a delay stands for: a speaker nearer by this much needs this delay to arrive together.
    static func distance(delayMs: Double, unit: DistanceUnit) -> Double {
        let metres = delayMs * 0.001 * speedOfSound
        return unit == .metres ? metres : metres / metresPerFoot
    }

    static func delayMs(distance: Double, unit: DistanceUnit) -> Double {
        let metres = unit == .metres ? distance : distance * metresPerFoot
        return metres / speedOfSound * 1000
    }

    /// `alignment` with one speaker's feed changed. Values are clamped to the supported ranges.
    static func editing(
        _ alignment: StereoBassAlignment?, side: SpeakerFeedRow.Side, _ edit: (inout SpeakerFeedCalibration) -> Void
    ) -> StereoBassAlignment {
        var result = alignment ?? StereoBassAlignment()
        switch side {
        case .left: edit(&result.left); result.left = clamped(result.left)
        case .right: edit(&result.right); result.right = clamped(result.right)
        }
        return result
    }

    static func clamped(_ feed: SpeakerFeedCalibration) -> SpeakerFeedCalibration {
        var f = feed
        f.trimDB = min(max(f.trimDB.isFinite ? f.trimDB : 0, SpeakerFeedCalibration.trimRangeDB.lowerBound),
                       SpeakerFeedCalibration.trimRangeDB.upperBound)
        f.delayMs = min(max(f.delayMs.isFinite ? f.delayMs : 0, SpeakerFeedCalibration.delayRangeMs.lowerBound),
                        SpeakerFeedCalibration.delayRangeMs.upperBound)
        return f
    }

    /// Whether a system already has alignment or bass set (so a manual change should be able to read as out of date).
    static func hadConfiguration(arrangement: SystemArrangement?, bass: BassManagementConfiguration) -> Bool {
        let aligned = arrangement?.stereoAlignment.map { !($0.left.isIdentity && $0.right.isIdentity) } ?? false
        return aligned || bass.enabled
    }
}
