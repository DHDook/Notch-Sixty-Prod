import Foundation

// E12 S29: the frame around the guided-setup steps: the step list down the side, the rough time remaining, and the
// summary shown after Save. Pure values, so the shell is tested without a window.

enum SystemSetupStepState: Equatable, Sendable {
    case done, current, upcoming
}

struct SystemSetupStepRow: Identifiable, Equatable, Sendable {
    var step: SystemSetupStep
    var state: SystemSetupStepState
    /// A finished step can be reopened; the current and later steps cannot be jumped to.
    var canOpen: Bool
    var id: SystemSetupStep { step }
}

enum SystemSetupShell {
    /// The steps the list shows for this run. Bass is left out when there is no subwoofer or mono bass to design,
    /// (the step on screen still shows the reason when a run lands there).
    static func listedSteps(
        presetSteps: [SystemSetupStep], bassIsListed: Bool
    ) -> [SystemSetupStep] {
        presetSteps.filter { $0 != .bass || bassIsListed }
    }

    static func rows(
        listed: [SystemSetupStep], current: SystemSetupStep, completed: Set<SystemSetupStep>, skipped: Set<SystemSetupStep>
    ) -> [SystemSetupStepRow] {
        // The step on screen may be an unlisted Bass: the position then follows the step before it.
        let currentIndex = listed.lastIndex { $0.index <= current.index } ?? 0
        return listed.enumerated().map { offset, step in
            let state: SystemSetupStepState
            if step == current || (offset == currentIndex && !listed.contains(current)) {
                state = .current
            } else if completed.contains(step) || skipped.contains(step) && step.index < current.index {
                state = .done
            } else {
                state = .upcoming
            }
            return SystemSetupStepRow(step: step, state: state, canOpen: state == .done && completed.contains(step))
        }
    }

    /// Position (1-based) and total for the progress line.
    static func position(listed: [SystemSetupStep], current: SystemSetupStep) -> (position: Int, total: Int) {
        let index = listed.lastIndex { $0.index <= current.index } ?? 0
        return (index + 1, max(listed.count, 1))
    }
}

enum SystemSetupTimeEstimate {
    /// Rough minutes a step takes. Measure is per seat (a sweep for each speaker at each seat).
    static func minutes(_ step: SystemSetupStep, seats: Int) -> Int {
        switch step {
        case .output: return 1
        case .topology: return 2
        case .microphone: return 3
        case .room: return 2
        case .measure: return 3 * max(seats, 1)
        case .alignment: return 1
        case .bass: return 2
        case .correction: return 2
        case .verify: return 2
        case .save: return 1
        }
    }

    /// Minutes left from the step on screen (included) to the end, over the listed steps. The step on screen counts
    /// in full, so the figure never reads zero before Save.
    static func minutesRemaining(listed: [SystemSetupStep], from current: SystemSetupStep, seats: Int) -> Int {
        listed.filter { $0.index >= current.index }.reduce(0) { $0 + minutes($1, seats: seats) }
    }

    static func label(minutes: Int) -> String {
        minutes <= 1 ? "About a minute left" : "About \(minutes) minutes left"
    }
}

/// What the page after Save shows (decision 37).
struct SystemSetupSummary: Equatable, Sendable {
    var profileName: String
    var notVerified: Bool
    var verificationHeadline: String?
    var lines: [String]

    static func make(
        profileName: String, outputName: String?, sampleRate: Double?, arrangementText: String?,
        alignmentApplied: Bool, bassApplied: Bool, correctionApplied: Bool, designKind: SystemSetupDesignKind,
        seatCount: Int, notVerified: Bool, verificationHeadline: String?
    ) -> SystemSetupSummary {
        var lines: [String] = []
        if let outputName {
            let rate = sampleRate.map { String(format: " at %g kHz", $0 / 1_000) } ?? ""
            lines.append("Output: \(outputName)\(rate)")
        }
        if let arrangementText { lines.append("Speakers: \(arrangementText)") }
        if seatCount > 0 { lines.append("Measured \(seatCount) \(seatCount == 1 ? "seat" : "seats")") }
        if alignmentApplied { lines.append("Speakers aligned in level, timing and polarity") }
        if bassApplied { lines.append("Bass blended") }
        if correctionApplied {
            lines.append(designKind == .mixedPhase ? "Room correction on (sharper, with a small delay)" : "Room correction on")
        }
        return SystemSetupSummary(
            profileName: profileName, notVerified: notVerified, verificationHeadline: verificationHeadline, lines: lines)
    }
}
