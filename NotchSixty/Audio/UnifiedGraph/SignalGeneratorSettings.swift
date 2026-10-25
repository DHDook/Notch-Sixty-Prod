import Foundation

/// E11 S7: the measurement signal generator's settings and their mapping onto the core GENERATOR stage
/// (`n60/graph.h`, "Generator (ABI v14)"). Pure value type; Swift decides, the core only sees the parameters.
struct SignalGeneratorSettings: Equatable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case white = 0, pink, bandLimitedPink, sine, periodicPink
    }

    /// Safety defaults (design note 8): -20 dBFS RMS, ceiling -6, 10 minute auto-stop.
    static let defaultLevelDB = -20.0
    static let hardCeilingDB = -6.0
    static let maxAutoStopSeconds = 600.0
    static let rampSeconds = 0.1

    var kind: Kind = .pink
    var levelDB = SignalGeneratorSettings.defaultLevelDB
    var ceilingDB = SignalGeneratorSettings.hardCeilingDB
    var sineHz = 1000.0
    var lowHz = 20.0
    var highHz = 20_000.0
    var periodFrames = 65_536
    var seed = 1
    var muteOtherAudio = true
    var autoStopSeconds = SignalGeneratorSettings.maxAutoStopSeconds
    /// The generator never keeps running across an output-device change.
    var stopOnOutputChange = true

    /// IEC 61260 band centres: `bandFraction` 1 is octave, 3 is third-octave. Edges sit at centre / 2^(1/2n), centre * 2^(1/2n).
    static func bandEdges(centerHz: Double, bandFraction: Int) -> (low: Double, high: Double) {
        let half = pow(2.0, 1.0 / (2.0 * Double(max(bandFraction, 1))))
        return (centerHz / half, centerHz * half)
    }

    mutating func selectBand(centerHz: Double, bandFraction: Int) {
        let edges = Self.bandEdges(centerHz: centerHz, bandFraction: bandFraction)
        kind = .bandLimitedPink
        lowHz = edges.low
        highHz = edges.high
    }

    /// Level after the ceiling clamp, never above -6 dBFS.
    var effectiveLevelDB: Double {
        min(levelDB, min(ceilingDB, Self.hardCeilingDB))
    }

    /// The core stage parameters (11 floats), or nil when the settings cannot form a valid stage at `sampleRate`.
    func stageParams(active: Bool, sampleRate: Double) -> [Float]? {
        let nyquistLimit = 0.45 * sampleRate
        guard levelDB >= -120, levelDB <= 0, ceilingDB >= -60, ceilingDB <= Self.hardCeilingDB,
              autoStopSeconds >= 0.001, autoStopSeconds <= Self.maxAutoStopSeconds,
              seed >= 0, seed <= 16_777_216 else { return nil }
        switch kind {
        case .sine:
            guard sineHz >= 1, sineHz <= nyquistLimit else { return nil }
        case .bandLimitedPink:
            guard lowHz >= 10, highHz <= nyquistLimit, highHz >= 1.05 * lowHz else { return nil }
        case .periodicPink:
            guard periodFrames >= 256, periodFrames <= 1_048_576,
                  periodFrames & (periodFrames - 1) == 0 else { return nil }
        case .white, .pink:
            break
        }
        return [
            Float(kind.rawValue), Float(levelDB), Float(ceilingDB), Float(sineHz), Float(lowHz), Float(highHz),
            Float(periodFrames), Float(seed), muteOtherAudio ? 1 : 0, active ? 1 : 0, Float(autoStopSeconds),
        ]
    }
}
