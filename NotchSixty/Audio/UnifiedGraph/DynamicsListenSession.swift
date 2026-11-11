import Foundation

/// E28 S7b: which dynamics stage is being listened to, and what it plays.
/// Sidechain listen plays the stage's detector input (after the sidechain filter, before any gain). Delta listen plays what
/// the stage removes: the dry signal minus the processed one before make-up. Multiband bands join in S7c.
enum DynamicsListenStage: CaseIterable, Equatable, Sendable {
    case compressor
    case expander

    var stageId: UInt32 {
        switch self {
        case .compressor: return UnifiedGraphConfiguration.compressorStageId
        case .expander: return UnifiedGraphConfiguration.expanderStageId
        }
    }

    /// Index of the live listen parameter in the stage's block (compressor [15], expander [12]).
    var paramIndex: UInt32 {
        switch self {
        case .compressor: return 15
        case .expander: return 12
        }
    }

    var displayName: String {
        switch self {
        case .compressor: return "Compressor"
        case .expander: return "Expander"
        }
    }
}

enum DynamicsListenMode: Float, Equatable, Sendable {
    case sidechain = 1
    case delta = 2

    var displayName: String { self == .sidechain ? "sidechain" : "delta (what it removes)" }
}

struct DynamicsListener: Equatable, Sendable {
    var stage: DynamicsListenStage
    var mode: DynamicsListenMode

    /// Text for the banner that names the stage while it plays.
    var bannerText: String { "Listening to the \(stage.displayName) \(mode.displayName). Downstream protection still applies." }
}

/// The session state of dynamics listening (design 13): at most one listener in the whole graph, never encoded in a profile
/// and never persisted. A request replaces the current listener. `clear()` runs on a profile switch, Stop, an output
/// change and Quit. Control plane only; the engine reads the parameter the host posts, never this object.
final class DynamicsListenSession: @unchecked Sendable {
    private let lock = NSLock()
    private var current: DynamicsListener?

    var listener: DynamicsListener? { lock.lock(); defer { lock.unlock() }; return current }

    /// Replaces the listener (nil clears). Returns true when the value changed.
    @discardableResult
    func request(_ listener: DynamicsListener?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current != listener else { return false }
        current = listener
        return true
    }

    @discardableResult
    func clear() -> Bool { request(nil) }

    /// The value of a stage's listen parameter for the current listener: 0 unless it is the listened stage.
    func parameterValue(for stage: DynamicsListenStage) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard let current, current.stage == stage else { return 0 }
        return current.mode.rawValue
    }
}
