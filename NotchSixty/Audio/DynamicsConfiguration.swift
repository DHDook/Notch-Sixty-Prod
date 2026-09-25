import Foundation

enum DynamicsConfigurationError: Error, LocalizedError, Equatable {
    case invalidDeEsser
    case invalidMultibandCompressor
    case invalidCompressor
    case invalidExpander
    case invalidPauseGate
    case invalidSoftClipper
    case invalidLimiter
    case invalidOversampling

    var errorDescription: String? {
        switch self {
        case .invalidDeEsser:
            return "De-Esser parameters are outside the supported production range."
        case .invalidMultibandCompressor:
            return "Multiband Compressor parameters are outside the supported production range."
        case .invalidCompressor:
            return "Compressor parameters are outside the supported production range."
        case .invalidExpander:
            return "Expander parameters are outside the supported production range."
        case .invalidPauseGate:
            return "Pause Gate parameters are outside the supported production range."
        case .invalidSoftClipper:
            return "Soft Clipper parameters are outside the supported production range."
        case .invalidLimiter:
            return "Limiter parameters are outside the supported production range."
        case .invalidOversampling:
            return "Oversampling configuration is invalid."
        }
    }
}

struct DeEsserConfiguration: Equatable, Sendable {
    static let frequencyRange = 2_000.0...10_000.0
    static let thresholdRange = -60.0...0.0

    var enabled = false
    var frequencyHz = 6_500.0
    var thresholdDB = -24.0
    var dynamicEQMode = true

    func validate() throws {
        guard frequencyHz.isFinite, Self.frequencyRange.contains(frequencyHz),
              thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB) else {
            throw DynamicsConfigurationError.invalidDeEsser
        }
    }
}

enum MultibandSlope: String, CaseIterable, Identifiable, Sendable {
    case gentle
    case steep

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .gentle: return "Gentle (LR4)"
        case .steep: return "Steep (LR8)"
        }
    }

    var cType: N60CrossoverTopology {
        switch self {
        case .gentle: return N60CrossoverTopologyLinkwitzRiley24
        case .steep: return N60CrossoverTopologyLinkwitzRiley48
        }
    }
}

struct MultibandCompressorConfiguration: Equatable, Sendable {
    static let lowMidFrequencyRange = 40.0...250.0
    static let midHighFrequencyRange = 1_000.0...8_000.0
    static let thresholdRange = -60.0...0.0

    var enabled = false
    var lowMidFrequencyHz = 120.0
    var midHighFrequencyHz = 3_500.0
    var slope: MultibandSlope = .gentle
    var lowThresholdDB = -18.0
    var midThresholdDB = -18.0
    var highThresholdDB = -18.0

    func validate() throws {
        guard lowMidFrequencyHz.isFinite,
              Self.lowMidFrequencyRange.contains(lowMidFrequencyHz),
              midHighFrequencyHz.isFinite,
              Self.midHighFrequencyRange.contains(midHighFrequencyHz),
              lowMidFrequencyHz < midHighFrequencyHz,
              lowThresholdDB.isFinite, Self.thresholdRange.contains(lowThresholdDB),
              midThresholdDB.isFinite, Self.thresholdRange.contains(midThresholdDB),
              highThresholdDB.isFinite, Self.thresholdRange.contains(highThresholdDB) else {
            throw DynamicsConfigurationError.invalidMultibandCompressor
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

enum OversamplingFactor: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case two = 2
    case four = 4

    var id: Int { rawValue }
    var displayName: String { "\(rawValue)×" }

    var cType: N60OversamplingFactor {
        switch self {
        case .one: return N60OversamplingFactor1x
        case .two: return N60OversamplingFactor2x
        case .four: return N60OversamplingFactor4x
        }
    }
}

enum SoftClipperCurve: String, CaseIterable, Identifiable, Sendable {
    case quadratic
    case cubic
    case sine
    case asymmetricTube

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .quadratic: return "Quadratic"
        case .cubic: return "Cubic"
        case .sine: return "Sine"
        case .asymmetricTube: return "Asymmetric Tube"
        }
    }

    var cType: N60ClipperCurveType {
        switch self {
        case .quadratic: return N60ClipperCurveQuadratic
        case .cubic: return N60ClipperCurveCubic
        case .sine: return N60ClipperCurveSine
        case .asymmetricTube: return N60ClipperCurveAsymmetricTube
        }
    }
}

struct SoftClipperConfiguration: Equatable, Sendable {
    static let driveRange = 0.0...12.0
    static let thresholdRange = -6.0...0.0
    static let kneeRange = 0.0...1.0

    var enabled = false
    var driveDB = 0.0
    var thresholdDB = -1.5
    var kneeSmooth = 0.5
    var curve: SoftClipperCurve = .quadratic
    var autoCompensateGain = true

    func validate() throws {
        guard driveDB.isFinite, Self.driveRange.contains(driveDB),
              thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),
              kneeSmooth.isFinite, Self.kneeRange.contains(kneeSmooth) else {
            throw DynamicsConfigurationError.invalidSoftClipper
        }
    }
}

struct LimiterConfiguration: Equatable, Sendable {
    static let ceilingRange = -20.0...0.0
    static let attackRange = 0.1...50.0
    static let releaseRange = 5.0...500.0
    static let lookAheadRange = 0.0...20.0

    // Deliberately disabled by default during the commercial rewrite. Presets can
    // opt in explicitly rather than introducing hidden limiting at first launch.
    var enabled = false
    var ceilingDB = -0.2
    var attackMs = 0.1
    var releaseMs = 20.0
    var lookAheadMs = 2.0

    func validate() throws {
        guard ceilingDB.isFinite, Self.ceilingRange.contains(ceilingDB),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              lookAheadMs.isFinite, Self.lookAheadRange.contains(lookAheadMs) else {
            throw DynamicsConfigurationError.invalidLimiter
        }
    }
}

struct DynamicsConfiguration: Equatable, Sendable {
    var deEsser = DeEsserConfiguration()
    var multibandCompressor = MultibandCompressorConfiguration()
    var compressor = CompressorConfiguration()
    var expander = ExpanderConfiguration()
    var softClipper = SoftClipperConfiguration()
    var limiter = LimiterConfiguration()
    var oversampling: OversamplingFactor = .one
    var pauseGate = PauseGateConfiguration()

    func makeSnapshot(sampleRate: Double) throws -> N60DynamicsSnapshot {
        try deEsser.validate()
        try multibandCompressor.validate()
        try compressor.validate()
        try expander.validate()
        try pauseGate.validate()

        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        guard N60DynamicsSnapshotSetDeEsser(
            &snapshot,
            sampleRate,
            deEsser.enabled,
            deEsser.frequencyHz,
            Float(deEsser.thresholdDB),
            deEsser.dynamicEQMode
        ) else { throw DynamicsConfigurationError.invalidDeEsser }
        guard N60DynamicsSnapshotSetMultibandCompressor(
            &snapshot,
            sampleRate,
            multibandCompressor.enabled,
            multibandCompressor.lowMidFrequencyHz,
            multibandCompressor.midHighFrequencyHz,
            multibandCompressor.slope.cType,
            Float(multibandCompressor.lowThresholdDB),
            Float(multibandCompressor.midThresholdDB),
            Float(multibandCompressor.highThresholdDB)
        ) else { throw DynamicsConfigurationError.invalidMultibandCompressor }
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
        ) else { throw DynamicsConfigurationError.invalidCompressor }
        guard N60DynamicsSnapshotSetExpander(
            &snapshot,
            sampleRate,
            expander.enabled,
            Float(expander.thresholdDB),
            Float(expander.ratio),
            Float(expander.rangeDB),
            Float(expander.attackMs),
            Float(expander.releaseMs)
        ) else { throw DynamicsConfigurationError.invalidExpander }
        guard N60DynamicsSnapshotSetPauseGate(
            &snapshot,
            sampleRate,
            pauseGate.enabled,
            Float(pauseGate.thresholdDBFS),
            Float(pauseGate.holdMs),
            Float(pauseGate.attackMs),
            Float(pauseGate.releaseMs),
            Float(pauseGate.hysteresisDB)
        ) else { throw DynamicsConfigurationError.invalidPauseGate }
        return snapshot
    }

    func makeProtectionSnapshot(sampleRate: Double) throws -> N60ProtectionSnapshot {
        try softClipper.validate()
        try limiter.validate()
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= N60_PROTECTION_MAX_SAMPLE_RATE else {
            throw DynamicsConfigurationError.invalidOversampling
        }

        var snapshot = N60ProtectionSnapshotMakeBypassed(sampleRate)
        guard N60ProtectionSnapshotSetOversamplingFactor(&snapshot, oversampling.cType) else {
            throw DynamicsConfigurationError.invalidOversampling
        }
        guard N60ProtectionSnapshotSetSoftClipper(
            &snapshot,
            softClipper.enabled,
            Float(softClipper.driveDB),
            Float(softClipper.thresholdDB),
            Float(softClipper.kneeSmooth),
            softClipper.curve.cType,
            softClipper.autoCompensateGain
        ) else { throw DynamicsConfigurationError.invalidSoftClipper }
        guard N60ProtectionSnapshotSetLimiter(
            &snapshot,
            limiter.enabled,
            Float(limiter.ceilingDB),
            Float(limiter.attackMs),
            Float(limiter.releaseMs),
            Float(limiter.lookAheadMs)
        ) else { throw DynamicsConfigurationError.invalidLimiter }
        return snapshot
    }
}