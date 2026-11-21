import Foundation

/// E33 S4 (behind `e33.page-enhancements`): the parts of the Dynamics page that are decisions rather than drawing,
/// kept in plain Swift so tests can check them without a window. No engine access, no realtime path.

// MARK: - Chain numbers and the dynamic EQ link row (design 10)

extension ProductionDynamicsLayout {
    /// "1 Input & Clean-up" ... "6 Output": the number is the group's place in `groups`, so a reordered chain renumbers itself.
    static func numberedTitle(of group: Group, in groups: [Group] = ProductionDynamicsLayout.groups) -> String {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return group.title }
        return "\(index + 1) \(group.title)"
    }

    /// Where the dynamic EQ link row sits: before the first group that runs after the EQ stage, so it reads at the EQ's place in the chain.
    static func eqRowIndex(in groups: [Group] = ProductionDynamicsLayout.groups) -> Int {
        groups.firstIndex(where: { $0.runsAfterEQ }) ?? groups.count
    }
}

/// One dynamic band in the link row.
struct DynamicsEQLinkEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    /// "Band 2: 250 Hz".
    let title: String
}

enum DynamicsEQLink {
    /// The bands whose dynamic mode is on and takes effect (enabled band, a type that supports it), in frequency order.
    static func activeBands(_ bands: [EQBand]) -> [DynamicsEQLinkEntry] {
        let ordered = bands.sorted { $0.frequencyHz < $1.frequencyHz }
        var entries: [DynamicsEQLinkEntry] = []
        for (index, band) in ordered.enumerated() where band.enabled && band.dynamic.enabled && band.type.supportsDynamicEQ {
            entries.append(DynamicsEQLinkEntry(id: band.id, title: "Band \(index + 1): \(EQBandPanelModel.frequencyText(band.frequencyHz))"))
        }
        return entries
    }

    /// The row's one-line summary: "Dynamic EQ: 2 bands on" or "Dynamic EQ: no bands on".
    static func summary(count: Int) -> String {
        switch count {
        case 0: return "Dynamic EQ: no bands on"
        case 1: return "Dynamic EQ: 1 band on"
        default: return "Dynamic EQ: \(count) bands on"
        }
    }
}

/// The band the Equalizer page should select when it next appears. The Dynamics page sets it and switches page; the
/// Equalizer takes it once. Main actor only; no persistence.
@MainActor
final class EQBandFocusRequest {
    static let shared = EQBandFocusRequest()
    private var pending: UUID?
    func request(_ id: UUID) { pending = id }
    /// Returns the requested band once, then forgets it.
    func take() -> UUID? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - Navigator row accessibility

enum DynamicsNavigatorAccessibility {
    static func label(title: String, subtitle: String) -> String { "\(title), \(subtitle)" }
    static func value(isOn: Bool) -> String { isOn ? "On" : "Off" }
}

extension ProductionDynamicsModule {
    /// Whether the processor is doing anything under `configuration` (the navigator dot, the active count, the empty-telemetry reason).
    func isActive(in d: DynamicsConfiguration) -> Bool {
        switch self {
        case .compressor: return d.compressor.enabled
        case .multiband: return d.multibandCompressor.enabled
        case .expander: return d.expander.enabled
        case .pauseGate: return d.pauseGate.enabled
        case .gainRider: return d.gainRider.enabled
        case .denoiser: return d.spectralDenoiser.enabled
        case .deEsser: return d.deEsser.enabled
        case .mainsHum: return d.mainsNotch.enabled || d.mainsNotch.continuousTracking
        case .infrasonic: return d.infrasonicFilter.enabled
        case .loudnessMatch: return d.loudnessMatch.enabled
        case .loudnessContour: return d.loudnessContour.enabled
        case .dialogueLeveler: return d.dialogueRelativeLeveler.enabled
        case .limiter: return d.limiter.enabled
        case .softClipper: return d.softClipper.enabled
        case .automaticHeadroom: return d.automaticHeadroom.enabled
        case .oversampling: return d.oversampling != .one
        case .deHarsh: return d.deHarsh.enabled
        case .stereoWidener: return d.stereoWidener.enabled
        case .stereoMode: return d.stereoMode != .stereo
        case .dcOffset: return d.dcOffsetFilter.enabled
        }
    }
}

extension ProductionDynamicsTelemetryKind {
    /// The navigator module a telemetry panel belongs to.
    var module: ProductionDynamicsModule {
        switch self {
        case .compressor: return .compressor
        case .multiband: return .multiband
        case .expander: return .expander
        case .pauseGate: return .pauseGate
        case .gainRider: return .gainRider
        case .denoiser: return .denoiser
        case .deEsser: return .deEsser
        case .mainsHum: return .mainsHum
        case .loudnessMatch: return .loudnessMatch
        case .loudnessContour: return .loudnessContour
        case .dialogue: return .dialogueLeveler
        case .limiter: return .limiter
        }
    }
}

// MARK: - Empty telemetry says why

enum DynamicsTelemetryEmptyReason {
    /// Stopped first (nothing runs), then the processor being off, then "no frames yet".
    static func text(isRunning: Bool, processorTitle: String, processorOn: Bool) -> String {
        if !isRunning { return "Audio is stopped. Start processing to view live status." }
        if !processorOn { return "\(processorTitle) is off. Turn it on to view live status." }
        return "Waiting for the first frames from the engine."
    }
}

// MARK: - Slider: relative grab, 30 Hz commits (design 13)

/// A drag on a Dynamics slider. The value moves by the distance dragged from the grab point (a click alone changes
/// nothing), Option drags at a tenth of the speed, at most 30 commits per second go out while dragging, and a final
/// commit goes out on release when the last position was not sent.
struct DynamicsSliderDrag: Equatable, Sendable {
    static let commitsPerSecond = 30.0
    static let minimumInterval = 1.0 / commitsPerSecond

    private(set) var position: Double
    private var lastX: Double
    private var lastCommitTime: Double?
    private var committedPosition: Double
    private let startPosition: Double
    /// Thumb travel in points: the track width less the thumb diameter, so the thumb follows the pointer.
    private let travel: Double

    init(startPosition: Double, startX: Double, trackWidth: Double, thumbDiameter: Double = 16) {
        self.position = startPosition
        self.startPosition = startPosition
        self.committedPosition = startPosition
        self.lastX = startX
        self.travel = max(trackWidth - thumbDiameter, 1)
    }

    /// Whether the pointer has moved the value since the grab.
    var hasMoved: Bool { position != startPosition }

    /// Applies a drag event; returns the position to commit now, or nil when it is a click, unchanged, or inside the 30 Hz interval.
    mutating func update(x: Double, fine: Bool, time: Double) -> Double? {
        let delta = (x - lastX) / travel * (fine ? 0.1 : 1)
        lastX = x
        position = min(max(position + delta, 0), 1)
        guard hasMoved, position != committedPosition else { return nil }
        if let last = lastCommitTime, time - last < Self.minimumInterval { return nil }
        lastCommitTime = time
        committedPosition = position
        return position
    }

    /// The release: the final position when it was not already committed.
    func finish() -> Double? {
        hasMoved && position != committedPosition ? position : nil
    }
}

// MARK: - Field limits shown on sliders (design 13)

extension DynamicsParameterSpec {
    /// "field: 1–100:1" when typed entry accepts more than the slider spans; nil when they match.
    var fieldLimitNote: String? {
        guard config.lowerBound < slider.lowerBound || config.upperBound > slider.upperBound else { return nil }
        let low = displayText(config.lowerBound)
        let high = displayText(config.upperBound)
        let suffix = unit.suffix
        let text: String
        switch unit {
        case .ratio: text = "\(low)–\(high)\(suffix)"
        default: text = suffix.isEmpty ? "\(low)–\(high)" : "\(low)–\(high) \(suffix)"
        }
        return "field: \(text)"
    }
}

/// E33 G21: the frozen kernel (the "legacy kernel" flag, or the fallback when the graph cannot be built) renders three
/// multiband bands whatever the page asks for, so the page says so rather than show a band count that is not heard.
enum MultibandKernelNote {
    static let text = "The legacy audio kernel is rendering: it plays three multiband bands, split at the first two crossovers, whatever the band count."

    static func note(bandCount: Int, graphRendering: Bool) -> String? {
        bandCount > 3 && !graphRendering ? text : nil
    }
}
