import Foundation

// E12 S31 (decision 36, G67): a system that is already set up gets three shortcuts into the guided setup. Each opens
// the flow at the right step with the rest kept.

enum SystemSetupEntry: String, Equatable, Sendable, CaseIterable {
    /// The normal start at Output.
    case fresh
    /// New measurements: opens at Microphone and level (the room or the microphone may have moved), keeps the output
    /// and the speakers, drops the old measurements.
    case measureAgain
    /// Target only: opens at Correction with the measurements already taken; nothing is measured.
    case changeSound
    /// Opens at Speakers; the output is kept, the measurements are dropped because they were taken with the old routing.
    case changeSpeakers

    var title: String {
        switch self {
        case .fresh: return "Set up my system"
        case .measureAgain: return "Measure again"
        case .changeSound: return "Change the sound"
        case .changeSpeakers: return "Change speakers"
        }
    }

    var explanation: String {
        switch self {
        case .fresh: return "Choose your speakers, set levels and measure your room."
        case .measureAgain: return "Measure your room again and rebuild the correction. Your output and speakers are kept."
        case .changeSound: return "Pick a different target for the correction. Nothing is measured again."
        case .changeSpeakers: return "Change the speakers or the subwoofer, then measure again."
        }
    }

    /// The step the flow opens at.
    var startStep: SystemSetupStep {
        switch self {
        case .fresh: return .output
        case .measureAgain: return .microphone
        case .changeSound: return .correction
        case .changeSpeakers: return .topology
        }
    }

    /// Whether the old measurements are dropped when the flow opens.
    var dropsMeasurements: Bool { self == .measureAgain || self == .changeSpeakers }
}
