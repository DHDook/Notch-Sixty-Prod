import Foundation

/// E28 S7d: non-optional views of the optional S7 extras, so the Dynamics page's rows (which write `Double` key paths)
/// can drive them. A value equal to the default is stored as nil, so an untouched profile encodes exactly as before.
private func storedExtra(_ value: Double, default defaultValue: Double) -> Double? { value == defaultValue ? nil : value }

extension CompressorConfiguration {
    static let defaultLookaheadMs = 5.0
    /// The shortest and longest lookahead the page offers (design 12); the config range is wider.
    static let lookaheadPageRange = 1.0...10.0

    var mixPercentValue: Double {
        get { mixPercent ?? 100 }
        set { mixPercent = storedExtra(newValue, default: 100) }
    }
    var linkPercentValue: Double {
        get { linkPercent ?? 100 }
        set { linkPercent = storedExtra(newValue, default: 100) }
    }
    var rmsWindowMsValue: Double {
        get { rmsWindowMs ?? 50 }
        set { rmsWindowMs = storedExtra(newValue, default: 50) }
    }
    var rmsDetectorOn: Bool {
        get { rmsDetector ?? false }
        set { rmsDetector = newValue ? true : nil }
    }
    var lookaheadOn: Bool {
        get { (lookaheadMs ?? 0) > 0 }
        set { lookaheadMs = newValue ? lookaheadTimeMs : nil }
    }
    /// The lookahead time; 5 ms while the lookahead is off (what it becomes when first turned on). Writing turns it on.
    var lookaheadTimeMs: Double {
        get { (lookaheadMs ?? 0) > 0 ? (lookaheadMs ?? Self.defaultLookaheadMs) : Self.defaultLookaheadMs }
        set { lookaheadMs = newValue }
    }
}

extension ExpanderConfiguration {
    var holdMsValue: Double {
        get { holdMs ?? 0 }
        set { holdMs = storedExtra(newValue, default: 0) }
    }
    var kneeDBValue: Double {
        get { kneeDB ?? 0 }
        set { kneeDB = storedExtra(newValue, default: 0) }
    }
    var rmsWindowMsValue: Double {
        get { rmsWindowMs ?? 50 }
        set { rmsWindowMs = storedExtra(newValue, default: 50) }
    }
    var rmsDetectorOn: Bool {
        get { rmsDetector ?? false }
        set { rmsDetector = newValue ? true : nil }
    }
    var sidechainHighPassHzValue: Double {
        get { sidechainHighPassHz ?? 0 }
        set { sidechainHighPassHz = storedExtra(newValue, default: 0) }
    }
    var linkPercentValue: Double {
        get { linkPercent ?? 100 }
        set { linkPercent = storedExtra(newValue, default: 100) }
    }
}

extension MultibandCompressorConfiguration {
    var rmsWindowMsValue: Double {
        get { rmsWindowMs ?? 50 }
        set { rmsWindowMs = storedExtra(newValue, default: 50) }
    }
    var lookaheadOn: Bool {
        get { (lookaheadMs ?? 0) > 0 }
        set { lookaheadMs = newValue ? lookaheadTimeMs : nil }
    }
    var lookaheadTimeMs: Double {
        get { (lookaheadMs ?? 0) > 0 ? (lookaheadMs ?? CompressorConfiguration.defaultLookaheadMs) : CompressorConfiguration.defaultLookaheadMs }
        set { lookaheadMs = newValue }
    }

    /// Whether `band` (0 low, 1 mid, 2 high) is in the optional set.
    static func contains(_ set: Set<Int>?, _ band: Int) -> Bool { set?.contains(band) == true }

    /// Returns `set` with `band` added or removed; empty becomes nil so old profiles keep their encoding.
    static func toggled(_ set: Set<Int>?, band: Int, on: Bool) -> Set<Int>? {
        var bands = set ?? []
        if on { bands.insert(band) } else { bands.remove(band) }
        return bands.isEmpty ? nil : bands
    }
}

/// E28 S7d (G33, G10): the lookahead the compressor and multiband add to the program path, as plan stages, so the routing
/// editor's total, the FIR A/V-sync assessment and the hand-over alignment check all count what the core reports through
/// `n60_graph_latency_frames`. Both stages delay every program lane equally, so one figure is the path latency.
enum DynamicsLatency {
    /// Frames the enabled compressor and multiband lookaheads add at `sampleRate` (0 when the flag is off or none is on).
    static func programFrames(_ dynamics: DynamicsConfiguration, sampleRate: Double, flagOn: Bool) -> Int {
        stages(dynamics, sampleRate: sampleRate, flagOn: flagOn).reduce(0) { $0 + Int($1.latencyFrames) }
    }

    static func stages(_ dynamics: DynamicsConfiguration, sampleRate: Double, flagOn: Bool) -> [SpeakerRoutingProgramStage] {
        guard flagOn else { return [] }
        var out: [SpeakerRoutingProgramStage] = []
        if dynamics.compressor.enabled, let ms = dynamics.compressor.lookaheadMs, ms > 0 {
            let frames = CompressorConfiguration.lookaheadFrames(ms: ms, sampleRate: sampleRate)
            if frames > 0 { out.append(SpeakerRoutingProgramStage(name: "Compressor lookahead", latencyFrames: Double(frames))) }
        }
        if dynamics.multibandCompressor.enabled, let ms = dynamics.multibandCompressor.lookaheadMs, ms > 0 {
            let frames = CompressorConfiguration.lookaheadFrames(ms: ms, sampleRate: sampleRate)
            if frames > 0 { out.append(SpeakerRoutingProgramStage(name: "Multiband lookahead", latencyFrames: Double(frames))) }
        }
        return out
    }
}
