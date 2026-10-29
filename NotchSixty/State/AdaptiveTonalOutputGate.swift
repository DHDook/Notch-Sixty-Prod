import Foundation

/// Why the adaptive tonal gate is closed. A closed gate stops mailbox writes and holds the last
/// gain; it never plays anything itself.
enum AdaptiveTonalGateReason: String, Equatable, Sendable {
    case flagOff
    case notArmed
    case staleArm
    case rampingIn
    case noBaseline
    case seatWarning
    case seatHarm
    case guardTripped
    case leaseLapsed
    case pathOutOfTolerance
    case coreNotAdapting
    case coreFault

    var displayName: String {
        switch self {
        case .flagOff: return "Adaptive tuning is off"
        case .notArmed: return "Not armed"
        case .staleArm: return "Waiting for the audio path to catch up"
        case .rampingIn: return "Anti-noise is still fading in"
        case .noBaseline: return "Measuring the seat before adapting"
        case .seatWarning: return "Holding: the seat got a little louder"
        case .seatHarm: return "Stopped: the seat got louder"
        case .guardTripped: return "Stopped: the howl guard tripped"
        case .leaseLapsed: return "Stopped: the safety lease lapsed"
        case .pathOutOfTolerance: return "Holding: the microphone path changed"
        case .coreNotAdapting: return "Waiting for the microphone"
        case .coreFault: return "Stopped: the adaptive core faulted"
        }
    }
}

enum AdaptiveTonalGateDecision: Equatable, Sendable {
    case open
    case closed(AdaptiveTonalGateReason)

    var isOpen: Bool { self == .open }
}

/// Everything the gate looks at. The controller builds it once per poll.
struct AdaptiveTonalGateInput: Equatable, Sendable {
    /// The `e4.adaptive-tonal-live` flag.
    var flagEnabled: Bool
    var armed: Bool
    /// The arm token the controller took at arming, and the one the engine holds now.
    var controllerGeneration: UInt64?
    var engineGeneration: UInt64
    /// The offline target has reached the stage where it plays at full planned strength.
    var targetRampedIn: Bool
    var hasBaseline: Bool
    var verdict: DoNoHarmVerdict
    /// An S15 trip has happened since arming.
    var guardTripped: Bool
    /// The lease is required (`e4.engine-lease` on) and renewed.
    var leaseRequired: Bool
    var leaseRenewed: Bool
    /// The core's path is within the mic-moved tolerance, or a re-solve is running.
    var pathWithinTolerance: Bool
    var resolveRunning: Bool
    var coreAdapting: Bool
    var coreFault: Bool
}

/// The single route from the adaptive weights to audible output, replacing the old `mayPlay`.
/// Pure and deterministic. The kernel checks the arm generation on its own, so a gate bug cannot
/// play stale or unbounded gain; this gate only decides whether the worker may write.
enum AdaptiveTonalOutputGate {
    static func evaluate(_ input: AdaptiveTonalGateInput) -> AdaptiveTonalGateDecision {
        guard input.flagEnabled else { return .closed(.flagOff) }
        guard input.armed else { return .closed(.notArmed) }
        guard let generation = input.controllerGeneration, generation == input.engineGeneration else {
            return .closed(.staleArm)
        }
        guard input.targetRampedIn else { return .closed(.rampingIn) }
        guard input.hasBaseline else { return .closed(.noBaseline) }
        switch input.verdict {
        case .baselining: return .closed(.noBaseline)
        case .warning: return .closed(.seatWarning)
        case .harm: return .closed(.seatHarm)
        case .ok: break
        }
        if input.guardTripped { return .closed(.guardTripped) }
        if input.leaseRequired, !input.leaseRenewed { return .closed(.leaseLapsed) }
        if input.coreFault { return .closed(.coreFault) }
        if !input.pathWithinTolerance, !input.resolveRunning { return .closed(.pathOutOfTolerance) }
        guard input.coreAdapting else { return .closed(.coreNotAdapting) }
        return .open
    }
}
