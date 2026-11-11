import Foundation

/// E28 S7b: which dynamics stage is being listened to, and what it plays.
/// Sidechain listen plays the stage's detector input (after the sidechain filter, before any gain). Delta listen plays what
/// the stage removes: the dry signal minus the processed one before make-up. The three multiband bands join in S7c, each
/// with its own listen slot of the one MULTIBAND stage.
enum DynamicsListenStage: CaseIterable, Equatable, Sendable {
    case compressor
    case expander
    case multibandLow
    case multibandMid
    case multibandHigh

    /// The band index of a multiband listener (0 low, 1 mid, 2 high); nil for the compressor and expander.
    var band: Int? {
        switch self {
        case .multibandLow: return 0
        case .multibandMid: return 1
        case .multibandHigh: return 2
        default: return nil
        }
    }

    var stageId: UInt32 {
        switch self {
        case .compressor: return UnifiedGraphConfiguration.compressorStageId
        case .expander: return UnifiedGraphConfiguration.expanderStageId
        case .multibandLow, .multibandMid, .multibandHigh: return UnifiedGraphConfiguration.multibandStageId
        }
    }

    /// Index of the live listen parameter in the stage's block (compressor [15], expander [12]).
    var paramIndex: UInt32 {
        switch self {
        case .compressor: return 15
        case .expander: return 12
        case .multibandLow: return 35
        case .multibandMid: return 36
        case .multibandHigh: return 37
        }
    }

    var displayName: String {
        switch self {
        case .compressor: return "Compressor"
        case .expander: return "Expander"
        case .multibandLow: return "Multiband low band"
        case .multibandMid: return "Multiband mid band"
        case .multibandHigh: return "Multiband high band"
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
    private var soloed: Set<Int> = []

    var listener: DynamicsListener? { lock.lock(); defer { lock.unlock() }; return current }

    /// Replaces the listener (nil clears). Returns true when the value changed.
    @discardableResult
    func request(_ listener: DynamicsListener?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current != listener else { return false }
        current = listener
        return true
    }

    /// Clears the listener and every solo. True when anything was set.
    @discardableResult
    func clear() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let changed = current != nil || !soloed.isEmpty
        current = nil
        soloed = []
        return changed
    }

    /// Soloed multiband bands (0 low, 1 mid, 2 high); session state like the listener (E28 S7c).
    var soloBands: Set<Int> { lock.lock(); defer { lock.unlock() }; return soloed }

    @discardableResult
    func setSolo(_ bands: Set<Int>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let valid = bands.intersection([0, 1, 2])
        guard soloed != valid else { return false }
        soloed = valid
        return true
    }

    /// The value of a stage's listen parameter for the current listener: 0 unless it is the listened stage.
    func parameterValue(for stage: DynamicsListenStage) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard let current, current.stage == stage else { return 0 }
        return current.mode.rawValue
    }
}
