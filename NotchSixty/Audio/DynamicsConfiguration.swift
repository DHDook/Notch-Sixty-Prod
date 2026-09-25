import Foundation

enum DynamicsConfigurationError: Error, LocalizedError, Equatable {
    case invalidCompressor
    case invalidExpander
    case invalidPauseGate

    var errorDescription: String? {
        switch self {
        case .invalidCompressor:
            return "Compressor parameters are outside the supported production range."
        case .invalidExpander:
            return "Expander parameters are outside the supported production range."
        case .invalidPauseGate:
            return "Pause Gate parameters are outside the supported production range."
        }
    }
}

struct CompressorConfiguration: Equatable, Sendable {
    static let thresholdRange = -96.0...0.0
    static let ratioRange = 1.0...100.0
    static let kneeRange = 0.0...24.0
    static let attackRange = 0.05...1_000.0
    static let releaseRange = 1.0...5_000.0
    static let makeupRange = -24.0...24.0

    var enabled = false
    var thresholdDB = -16.0
    var ratio = 3.5
    var kneeWidthDB = 6.0
    var attackMs = 25.0
    var releaseMs = 150.0
    var makeupGainDB = 0.0

    func validate() throws {
        guard thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),
              ratio.isFinite, Self.ratioRange.contains(ratio),
              kneeWidthDB.isFinite, Self.kneeRange.contains(kneeWidthDB),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              makeupGainDB.isFinite, Self.makeupRange.contains(makeupGainDB) else {
            throw DynamicsConfigurationError.invalidCompressor
        }
    }
}

struct ExpanderConfiguration: Equatable, Sendable {
    static let thresholdRange = -120.0...0.0
    static let ratioRange = 1.0...20.0
    static let rangeRange = -96.0...0.0
    static let attackRange = 0.05...1_000.0
    static let releaseRange = 1.0...5_000.0

    var enabled = false
    var thresholdDB = -35.0
    var ratio = 1.5
    var rangeDB = -12.0
    var attackMs = 5.0
    var releaseMs = 200.0

    func validate() throws {
        guard thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),
              ratio.isFinite, Self.ratioRange.contains(ratio),
              rangeDB.isFinite, Self.rangeRange.contains(rangeDB),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs) else {
            throw DynamicsConfigurationError.invalidExpander
        }
    }
}

struct PauseGateConfiguration: Equatable, Sendable {
    // Preserve the legacy product control ranges while independently rebuilding behavior.
    static let thresholdRange = -80.0 ... -40.0
    static let holdRange = 100.0...2_000.0
    static let attackRange = 1.0...100.0
    static let releaseRange = 10.0...500.0
    static let hysteresisRange = 0.0...6.0

    var enabled = false
    var thresholdDBFS = -60.0
    var holdMs = 500.0
    /// Product convention: Attack is the fade-out/close time.
    var attackMs = 10.0
    /// Product convention: Release is the fade-in/open time.
    var releaseMs = 200.0
    var hysteresisDB = 3.0

    func validate() throws {
        guard thresholdDBFS.isFinite, Self.thresholdRange.contains(thresholdDBFS),
              holdMs.isFinite, Self.holdRange.contains(holdMs),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              hysteresisDB.isFinite, Self.hysteresisRange.contains(hysteresisDB) else {
            throw DynamicsConfigurationError.invalidPauseGate
        }
    }
}

struct DynamicsConfiguration: Equatable, Sendable {
    var compressor = CompressorConfiguration()
    var expander = ExpanderConfiguration()
    var pauseGate = PauseGateConfiguration()

    func makeSnapshot(sampleRate: Double) throws -> N60DynamicsSnapshot {
        try compressor.validate()
        try expander.validate()
        try pauseGate.validate()

        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        guard N60DynamicsSnapshotSetCompressor(
            &snapshot,
            sampleRate,
            compressor.enabled,
            Float(compressor.thresholdDB),
            Float(compressor.ratio),
            Float(compressor.kneeWidthDB),
            Float(compressor.attackMs),
            Float(compressor.releaseMs),
            Float(compressor.makeupGainDB)
        ) else {
            throw DynamicsConfigurationError.invalidCompressor
        }
        guard N60DynamicsSnapshotSetExpander(
            &snapshot,
            sampleRate,
            expander.enabled,
            Float(expander.thresholdDB),
            Float(expander.ratio),
            Float(expander.rangeDB),
            Float(expander.attackMs),
            Float(expander.releaseMs)
        ) else {
            throw DynamicsConfigurationError.invalidExpander
        }
        guard N60DynamicsSnapshotSetPauseGate(
            &snapshot,
            sampleRate,
            pauseGate.enabled,
            Float(pauseGate.thresholdDBFS),
            Float(pauseGate.holdMs),
            Float(pauseGate.attackMs),
            Float(pauseGate.releaseMs),
            Float(pauseGate.hysteresisDB)
        ) else {
            throw DynamicsConfigurationError.invalidPauseGate
        }
        return snapshot
    }
}
