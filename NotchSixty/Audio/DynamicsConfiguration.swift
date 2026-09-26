import Foundation

enum DynamicsConfigurationError: Error, LocalizedError, Equatable {
    case invalidStereoWidener
    case invalidDCOffsetFilter
    case invalidInfrasonicFilter
    case invalidMainsNotch
    case invalidMainsHumDetector
    case invalidSpectralDenoiser
    case invalidLoudnessMatch
    case invalidLoudnessContour
    case invalidDialogueLeveler
    case invalidDynamicEQ
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
        case .invalidStereoWidener:
            return "Stereo Widener parameters are outside the supported production range."
        case .invalidDCOffsetFilter:
            return "DC Offset Filter configuration is invalid."
        case .invalidInfrasonicFilter:
            return "Infrasonic Filter parameters are outside the supported production range."
        case .invalidMainsNotch:
            return "Mains Hum Notch parameters are outside the supported production range."
        case .invalidMainsHumDetector:
            return "Mains Hum detector parameters are outside the supported production range."
        case .invalidSpectralDenoiser:
            return "Spectral Denoiser parameters are outside the supported production range."
        case .invalidLoudnessMatch:
            return "LUFS Loudness Match parameters are outside the supported production range."
        case .invalidLoudnessContour:
            return "Loudness Contour parameters are outside the supported production range."
        case .invalidDialogueLeveler:
            return "Dialogue Relative Leveler parameters are outside the supported production range."
        case .invalidDynamicEQ:
            return "Dynamic EQ parameters are outside the supported production range."
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


enum StereoProcessingMode: String, CaseIterable, Identifiable, Sendable {
    case stereo
    case wideMono
    case trueMono

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .stereo: return "Stereo"
        case .wideMono: return "Wide Mono"
        case .trueMono: return "True Mono"
        }
    }
    var cType: N60StereoMode {
        switch self {
        case .stereo: return N60StereoModeStereo
        case .wideMono: return N60StereoModeWideMono
        case .trueMono: return N60StereoModeTrueMono
        }
    }
}

struct StereoWidenerConfiguration: Equatable, Sendable {
    static let lowWidthRange = 0.0...1.0
    static let midWidthRange = 1.0...2.0
    static let highWidthRange = 1.0...2.0
    static let lowMidFrequencyRange = 80.0...500.0
    static let midHighFrequencyRange = 1_500.0...8_000.0

    var enabled = false
    var monoLowBand = true
    var lowWidth = 0.0
    var midWidth = 1.0
    var highWidth = 1.0
    var lowMidFrequencyHz = 200.0
    var midHighFrequencyHz = 4_000.0

    func validate() throws {
        guard lowWidth.isFinite, Self.lowWidthRange.contains(lowWidth),
              midWidth.isFinite, Self.midWidthRange.contains(midWidth),
              highWidth.isFinite, Self.highWidthRange.contains(highWidth),
              lowMidFrequencyHz.isFinite, Self.lowMidFrequencyRange.contains(lowMidFrequencyHz),
              midHighFrequencyHz.isFinite, Self.midHighFrequencyRange.contains(midHighFrequencyHz),
              lowMidFrequencyHz < midHighFrequencyHz else {
            throw DynamicsConfigurationError.invalidStereoWidener
        }
    }
}

struct DCOffsetFilterConfiguration: Equatable, Sendable {
    var enabled = false
}

enum InfrasonicSlope: String, CaseIterable, Identifiable, Sendable {
    case db24
    case db48
    case db96

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .db24: return "24 dB/oct"
        case .db48: return "48 dB/oct"
        case .db96: return "96 dB/oct"
        }
    }
    var cType: N60InfrasonicSlope {
        switch self {
        case .db24: return N60InfrasonicSlope24DBPerOctave
        case .db48: return N60InfrasonicSlope48DBPerOctave
        case .db96: return N60InfrasonicSlope96DBPerOctave
        }
    }
}

struct InfrasonicFilterConfiguration: Equatable, Sendable {
    static let cutoffRange = 10.0...30.0
    var enabled = false
    var cutoffHz = 18.0
    var slope: InfrasonicSlope = .db48

    func validate() throws {
        guard cutoffHz.isFinite, Self.cutoffRange.contains(cutoffHz) else {
            throw DynamicsConfigurationError.invalidInfrasonicFilter
        }
    }
}

enum MainsRegion: Int, CaseIterable, Identifiable, Sendable {
    case hz50 = 50
    case hz60 = 60

    var id: Int { rawValue }
    var displayName: String { "\(rawValue) Hz" }
    var fundamentalHz: Double { Double(rawValue) }
}

struct MainsNotchConfiguration: Equatable, Sendable {
    static let harmonicCountRange = 1...16
    static let qRange = 5.0...60.0
    static let depthRange = -40.0...0.0
    static let detectedFrequencyRange = 40.0...70.0
    static let maximumHarmonics = 16

    var enabled = false
    var region: MainsRegion = .hz60
    var detectedFundamentalHz: Double? = nil
    var continuousTracking = false
    var harmonicCount = 8
    var q = 30.0
    var harmonicDepthsDB: [Double] = [
        -24, -18, -15, -12, -10, -8, -6, -6,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]

    var fundamentalHz: Double { detectedFundamentalHz ?? region.fundamentalHz }

    mutating func selectRegion(_ newRegion: MainsRegion) {
        region = newRegion
        detectedFundamentalHz = nil
    }

    func validate() throws {
        guard Self.harmonicCountRange.contains(harmonicCount),
              q.isFinite, Self.qRange.contains(q),
              detectedFundamentalHz.map({ $0.isFinite && Self.detectedFrequencyRange.contains($0) }) ?? true,
              harmonicDepthsDB.count == Self.maximumHarmonics,
              harmonicDepthsDB.allSatisfy({ $0.isFinite && Self.depthRange.contains($0) }) else {
            throw DynamicsConfigurationError.invalidMainsNotch
        }
    }
}

enum SpectralDenoiserPreset: String, CaseIterable, Identifiable, Sendable {
    case natural
    case standard
    case aggressive
    case dehiss
    case custom

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .natural: return "Natural"
        case .standard: return "Standard"
        case .aggressive: return "Aggressive"
        case .dehiss: return "Dehiss"
        case .custom: return "Custom"
        }
    }

    var cType: N60DenoiserTuning {
        switch self {
        case .natural: return N60DenoiserTuningNatural
        case .aggressive: return N60DenoiserTuningAggressive
        case .dehiss: return N60DenoiserTuningDehiss
        case .custom: return N60DenoiserTuningCustom
        case .standard: return N60DenoiserTuningStandard
        }
    }
}

enum SpectralDenoiserQuality: String, CaseIterable, Identifiable, Sendable {
    case quality
    case high
    case ultra

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .quality: return "Quality"
        case .high: return "High"
        case .ultra: return "Ultra"
        }
    }
    var cType: N60DenoiserQuality {
        switch self {
        case .quality: return N60DenoiserQualityQuality
        case .high: return N60DenoiserQualityHigh
        case .ultra: return N60DenoiserQualityUltra
        }
    }
}

enum SpectralDenoiserProfileCommand: Equatable, Sendable {
    case none
    case capture
    case reset

    var cType: N60DenoiserProfileCommand {
        switch self {
        case .capture: return N60DenoiserProfileCommandCapture
        case .reset: return N60DenoiserProfileCommandReset
        case .none: return N60DenoiserProfileCommandNone
        }
    }
}

struct SpectralDenoiserConfiguration: Equatable, Sendable {
    static let reductionRange = 0.0...1.0
    static let thresholdRange = -96.0 ... -30.0
    static let protectedFrequencyRange = 0.0...20_000.0

    var enabled = false
    var preset: SpectralDenoiserPreset = .natural
    // Custom means visible user values have been edited. Preserve the last
    // named algorithm tuning so a tiny manual edit does not silently change
    // artifact-management behavior (especially Dehiss).
    var customBasePreset: SpectralDenoiserPreset = .natural
    var reductionAmount = 0.50
    var thresholdDBFS = -72.0
    var quality: SpectralDenoiserQuality = .high
    var protectedRangeEnabled = false
    var protectedLowHz = 0.0
    var protectedHighHz = 150.0
    var profileRevision: UInt32 = 0
    var profileCommand: SpectralDenoiserProfileCommand = .none

    var algorithmPreset: SpectralDenoiserPreset {
        preset == .custom ? customBasePreset : preset
    }

    mutating func applyPreset(_ value: SpectralDenoiserPreset) {
        guard value != .custom else {
            markCustom()
            return
        }
        preset = value
        customBasePreset = value
        quality = .high
        protectedLowHz = 0
        protectedHighHz = 150
        switch value {
        case .natural:
            thresholdDBFS = -72
            reductionAmount = 0.50
            protectedRangeEnabled = false
        case .standard:
            thresholdDBFS = -60
            reductionAmount = 0.50
            protectedRangeEnabled = false
        case .aggressive:
            thresholdDBFS = -48
            reductionAmount = 0.50
            protectedRangeEnabled = false
        case .dehiss:
            thresholdDBFS = -58
            reductionAmount = 0.40
            protectedRangeEnabled = true
        case .custom:
            break
        }
    }

    mutating func markCustom() {
        if preset != .custom {
            customBasePreset = preset
            preset = .custom
        }
    }

    mutating func requestProfileCapture() {
        profileRevision &+= 1
        profileCommand = .capture
    }

    mutating func resetProfile() {
        profileRevision &+= 1
        profileCommand = .reset
    }

    func validate(sampleRate: Double) throws {
        let nyquist = sampleRate * 0.5
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000,
              reductionAmount.isFinite, Self.reductionRange.contains(reductionAmount),
              thresholdDBFS.isFinite, Self.thresholdRange.contains(thresholdDBFS),
              protectedLowHz.isFinite, Self.protectedFrequencyRange.contains(protectedLowHz),
              protectedHighHz.isFinite, Self.protectedFrequencyRange.contains(protectedHighHz),
              protectedLowHz <= protectedHighHz,
              protectedHighHz < nyquist else {
            throw DynamicsConfigurationError.invalidSpectralDenoiser
        }
    }
}

struct LoudnessMatchConfiguration: Equatable, Sendable {
    static let targetRange = -24.0 ... -10.0
    static let maxCorrectionRange = 3.0...20.0
    static let attackRange = 0.3...5.0
    static let releaseRange = 1.0...10.0

    var enabled = false
    var dialogueGateEnabled = false
    var targetLUFS = -16.0
    var maxCorrectionDB = 12.0
    var attackSeconds = 1.0
    var releaseSeconds = 3.0

    func validate() throws {
        guard targetLUFS.isFinite, Self.targetRange.contains(targetLUFS),
              maxCorrectionDB.isFinite, Self.maxCorrectionRange.contains(maxCorrectionDB),
              attackSeconds.isFinite, Self.attackRange.contains(attackSeconds),
              releaseSeconds.isFinite, Self.releaseRange.contains(releaseSeconds) else {
            throw DynamicsConfigurationError.invalidLoudnessMatch
        }
    }
}

struct LoudnessContourConfiguration: Equatable, Sendable {
    static let strengthRange = 0.0...1.0
    var enabled = false
    var strength = 1.0

    func validate() throws {
        guard strength.isFinite, Self.strengthRange.contains(strength) else {
            throw DynamicsConfigurationError.invalidLoudnessContour
        }
    }
}

struct DialogueVoiceGateConfiguration: Equatable, Sendable {
    static let centerRange = 2.0...10.0
    static let bandwidthRange = 2.0...8.0
    static let envelopeWindowRange = 5.0...30.0
    static let measurementWindowRange = 300.0...1_500.0
    static let confidenceRange = 0.0...1.0

    var enabled = false
    var modulationCenterHz = 5.0
    var modulationBandwidthHz = 5.0
    var envelopeWindowMs = 15.0
    var measurementWindowMs = 700.0
    var confidenceFloorIndex = 0.15
    var confidenceCeilingIndex = 0.45
    var minConfidence = 0.2

    func validate() throws {
        guard modulationCenterHz.isFinite, Self.centerRange.contains(modulationCenterHz),
              modulationBandwidthHz.isFinite, Self.bandwidthRange.contains(modulationBandwidthHz),
              envelopeWindowMs.isFinite, Self.envelopeWindowRange.contains(envelopeWindowMs),
              measurementWindowMs.isFinite, Self.measurementWindowRange.contains(measurementWindowMs),
              confidenceFloorIndex.isFinite, Self.confidenceRange.contains(confidenceFloorIndex),
              confidenceCeilingIndex.isFinite, Self.confidenceRange.contains(confidenceCeilingIndex),
              confidenceCeilingIndex > confidenceFloorIndex,
              minConfidence.isFinite, Self.confidenceRange.contains(minConfidence) else {
            throw DynamicsConfigurationError.invalidDialogueLeveler
        }
    }
}

struct DialogueRelativeLevelerConfiguration: Equatable, Sendable {
    static let bandRange = 100.0...8_000.0
    static let targetGapRange = 3.0...20.0
    static let boostRatioRange = 1.0...6.0
    static let maxBoostRange = 0.0...15.0
    static let detectorWindowRange = 50.0...500.0
    static let attackRange = 10.0...1_000.0
    static let releaseRange = 50.0...3_000.0
    static let programGateRange = -70.0 ... -30.0

    var enabled = false
    var bandLowHz = 300.0
    var bandHighHz = 3_500.0
    var targetGapDB = 10.0
    var boostRatio = 2.0
    var maxBoostDB = 8.0
    var detectorWindowMs = 300.0
    var attackMs = 150.0
    var releaseMs = 900.0
    var programGateThresholdDB = -50.0
    var voiceGate = DialogueVoiceGateConfiguration()

    func validate(sampleRate: Double) throws {
        try voiceGate.validate()
        guard sampleRate.isFinite, sampleRate > 0,
              bandLowHz.isFinite, Self.bandRange.contains(bandLowHz),
              bandHighHz.isFinite, Self.bandRange.contains(bandHighHz),
              bandLowHz < bandHighHz, bandHighHz < sampleRate * 0.45,
              targetGapDB.isFinite, Self.targetGapRange.contains(targetGapDB),
              boostRatio.isFinite, Self.boostRatioRange.contains(boostRatio),
              maxBoostDB.isFinite, Self.maxBoostRange.contains(maxBoostDB),
              detectorWindowMs.isFinite, Self.detectorWindowRange.contains(detectorWindowMs),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              programGateThresholdDB.isFinite, Self.programGateRange.contains(programGateThresholdDB) else {
            throw DynamicsConfigurationError.invalidDialogueLeveler
        }
    }
}

enum DynamicEQDirection: String, CaseIterable, Identifiable, Sendable {
    case cutOnly
    case boostOnly
    case both

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cutOnly: return "Cut Only"
        case .boostOnly: return "Boost Only"
        case .both: return "Both"
        }
    }
    var cType: N60DynamicEQDirection {
        switch self {
        case .cutOnly: return N60DynamicEQDirectionCutOnly
        case .boostOnly: return N60DynamicEQDirectionBoostOnly
        case .both: return N60DynamicEQDirectionBoth
        }
    }
}

enum DynamicEQDetectorMode: String, CaseIterable, Identifiable, Sendable {
    case peak
    case rms

    var id: String { rawValue }
    var displayName: String { self == .peak ? "Peak" : "RMS" }
    var cType: N60DynamicEQDetectorMode {
        self == .peak ? N60DynamicEQDetectorPeak : N60DynamicEQDetectorRMS
    }
}

struct DynamicEQBandConfiguration: Equatable, Sendable {
    static let frequencyRange = 20.0...20_000.0
    static let qRange = 0.4...8.0
    static let staticGainRange = -18.0...6.0
    static let thresholdRange = -60.0...0.0
    static let ratioRange = 1.0...10.0
    static let rangeRange = -24.0...0.0
    static let attackRange = 1.0...100.0
    static let releaseRange = 10.0...1_000.0
    static let boostThresholdRange = -60.0...0.0
    static let boostRatioRange = 1.0...10.0
    static let maxBoostRange = 0.0...12.0
    static let rmsWindowRange = 5.0...200.0

    var enabled = true
    var frequencyHz = 1_000.0
    var q = 1.0
    var staticGainDB = 0.0
    var thresholdDB = -24.0
    var ratio = 2.0
    var rangeDB = -24.0
    var attackMs = 10.0
    var releaseMs = 100.0
    var direction: DynamicEQDirection = .cutOnly
    var boostThresholdDB = -40.0
    var boostRatio = 2.0
    var maxBoostDB = 6.0
    var detectorMode: DynamicEQDetectorMode = .peak
    var rmsWindowMs = 50.0

    func validate(sampleRate: Double) throws {
        guard frequencyHz.isFinite, Self.frequencyRange.contains(frequencyHz), frequencyHz < sampleRate * 0.5,
              q.isFinite, Self.qRange.contains(q),
              staticGainDB.isFinite, Self.staticGainRange.contains(staticGainDB),
              thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),
              ratio.isFinite, Self.ratioRange.contains(ratio),
              rangeDB.isFinite, Self.rangeRange.contains(rangeDB),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              boostThresholdDB.isFinite, Self.boostThresholdRange.contains(boostThresholdDB),
              boostRatio.isFinite, Self.boostRatioRange.contains(boostRatio),
              maxBoostDB.isFinite, Self.maxBoostRange.contains(maxBoostDB),
              rmsWindowMs.isFinite, Self.rmsWindowRange.contains(rmsWindowMs) else {
            throw DynamicsConfigurationError.invalidDynamicEQ
        }
    }
}

struct DynamicEQConfiguration: Equatable, Sendable {
    static let maximumBandCount = Int(N60_DYNAMIC_EQ_MAX_BANDS)
    var enabled = false
    var bands: [DynamicEQBandConfiguration] = []

    func validate(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0, bands.count <= Self.maximumBandCount else {
            throw DynamicsConfigurationError.invalidDynamicEQ
        }
        try bands.forEach { try $0.validate(sampleRate: sampleRate) }
    }
}

struct DeEsserConfiguration: Equatable, Sendable {
    static let frequencyRange = 2_000.0...10_000.0
    static let thresholdRange = -60.0...0.0
    static let ratioRange = 1.0...20.0
    static let rangeRange = -24.0...0.0
    static let detectionQRange = 0.5...8.0
    static let attackRange = 0.1...100.0
    static let releaseRange = 10.0...1_000.0

    var enabled = false
    var frequencyHz = 6_500.0
    var thresholdDB = -24.0
    var ratio = 4.0
    var rangeDB = -24.0
    var detectionQ = 2.0
    var attackMs = 1.0
    var releaseMs = 50.0
    var dynamicEQMode = true

    func validate() throws {
        guard frequencyHz.isFinite, Self.frequencyRange.contains(frequencyHz),
              thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),
              ratio.isFinite, Self.ratioRange.contains(ratio),
              rangeDB.isFinite, Self.rangeRange.contains(rangeDB),
              detectionQ.isFinite, Self.detectionQRange.contains(detectionQ),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs) else {
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
    static let ratioRange = 1.0...20.0
    static let attackRange = 1.0...200.0
    static let releaseRange = 10.0...1_000.0
    static let kneeRange = 0.0...20.0
    static let sidechainRange = 0.0...300.0
    static let makeupRange = -12.0...12.0

    var enabled = false
    var lowMidFrequencyHz = 120.0
    var midHighFrequencyHz = 3_500.0
    var lowMidSlope: MultibandSlope = .gentle
    var midHighSlope: MultibandSlope = .gentle
    var lowThresholdDB = -18.0
    var midThresholdDB = -18.0
    var highThresholdDB = -18.0
    var lowRatio = 3.0
    var midRatio = 3.0
    var highRatio = 3.0
    var lowAttackMs = 10.0
    var midAttackMs = 10.0
    var highAttackMs = 10.0
    var lowReleaseMs = 150.0
    var midReleaseMs = 150.0
    var highReleaseMs = 150.0
    var lowKneeDB = 6.0
    var midKneeDB = 6.0
    var highKneeDB = 6.0
    var lowSidechainHighPassHz = 0.0
    var midSidechainHighPassHz = 0.0
    var highSidechainHighPassHz = 0.0
    var lowMakeupGainDB = 0.0
    var midMakeupGainDB = 0.0
    var highMakeupGainDB = 0.0

    // Compatibility convenience for the previous shared slope control.
    var slope: MultibandSlope {
        get { lowMidSlope }
        set { lowMidSlope = newValue; midHighSlope = newValue }
    }

    func validate() throws {
        let thresholds = [lowThresholdDB, midThresholdDB, highThresholdDB]
        let ratios = [lowRatio, midRatio, highRatio]
        let attacks = [lowAttackMs, midAttackMs, highAttackMs]
        let releases = [lowReleaseMs, midReleaseMs, highReleaseMs]
        let knees = [lowKneeDB, midKneeDB, highKneeDB]
        let sidechains = [lowSidechainHighPassHz, midSidechainHighPassHz, highSidechainHighPassHz]
        let makeups = [lowMakeupGainDB, midMakeupGainDB, highMakeupGainDB]
        guard lowMidFrequencyHz.isFinite, Self.lowMidFrequencyRange.contains(lowMidFrequencyHz),
              midHighFrequencyHz.isFinite, Self.midHighFrequencyRange.contains(midHighFrequencyHz),
              lowMidFrequencyHz < midHighFrequencyHz,
              thresholds.allSatisfy({ $0.isFinite && Self.thresholdRange.contains($0) }),
              ratios.allSatisfy({ $0.isFinite && Self.ratioRange.contains($0) }),
              attacks.allSatisfy({ $0.isFinite && Self.attackRange.contains($0) }),
              releases.allSatisfy({ $0.isFinite && Self.releaseRange.contains($0) }),
              knees.allSatisfy({ $0.isFinite && Self.kneeRange.contains($0) }),
              sidechains.allSatisfy({ $0.isFinite && Self.sidechainRange.contains($0) }),
              makeups.allSatisfy({ $0.isFinite && Self.makeupRange.contains($0) }) else {
            throw DynamicsConfigurationError.invalidMultibandCompressor
        }
    }
}

enum CompressorTopology: String, CaseIterable, Identifiable, Sendable {
    case feedForward
    case feedBack
    var id: String { rawValue }
    var displayName: String { self == .feedForward ? "Feed-Forward" : "Feed-Back" }
    var cType: N60CompressorTopology { self == .feedForward ? N60CompressorTopologyFeedForward : N60CompressorTopologyFeedBack }
}

struct CompressorConfiguration: Equatable, Sendable {
    static let thresholdRange = -96.0...0.0
    static let ratioRange = 1.0...100.0
    static let kneeRange = 0.0...24.0
    static let attackRange = 0.05...1_000.0
    static let releaseRange = 1.0...5_000.0
    static let makeupRange = -24.0...24.0
    static let sidechainHighPassRange = 0.0...300.0

    var enabled = false
    var thresholdDB = -16.0
    var ratio = 3.5
    var kneeWidthDB = 6.0
    var attackMs = 25.0
    var releaseMs = 150.0
    var makeupGainDB = 0.0
    var topology: CompressorTopology = .feedForward
    var programDependentRelease = false
    var sidechainHighPassHz = 0.0

    func validate() throws {
        guard thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),
              ratio.isFinite, Self.ratioRange.contains(ratio),
              kneeWidthDB.isFinite, Self.kneeRange.contains(kneeWidthDB),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              makeupGainDB.isFinite, Self.makeupRange.contains(makeupGainDB),
              sidechainHighPassHz.isFinite, Self.sidechainHighPassRange.contains(sidechainHighPassHz) else {
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
    var stereoMode: StereoProcessingMode = .stereo
    var stereoWidener = StereoWidenerConfiguration()
    var dcOffsetFilter = DCOffsetFilterConfiguration()
    var infrasonicFilter = InfrasonicFilterConfiguration()
    var mainsNotch = MainsNotchConfiguration()
    var spectralDenoiser = SpectralDenoiserConfiguration()
    var loudnessMatch = LoudnessMatchConfiguration()
    var loudnessContour = LoudnessContourConfiguration()
    var dialogueRelativeLeveler = DialogueRelativeLevelerConfiguration()
    var dynamicEQ = DynamicEQConfiguration()
    var deEsser = DeEsserConfiguration()
    var multibandCompressor = MultibandCompressorConfiguration()
    var compressor = CompressorConfiguration()
    var expander = ExpanderConfiguration()
    var softClipper = SoftClipperConfiguration()
    var limiter = LimiterConfiguration()
    var oversampling: OversamplingFactor = .one
    var pauseGate = PauseGateConfiguration()

    func makeSnapshot(sampleRate: Double) throws -> N60DynamicsSnapshot {
        try stereoWidener.validate()
        try infrasonicFilter.validate()
        try mainsNotch.validate()
        try spectralDenoiser.validate(sampleRate: sampleRate)
        try loudnessMatch.validate()
        try loudnessContour.validate()
        try dialogueRelativeLeveler.validate(sampleRate: sampleRate)
        try dynamicEQ.validate(sampleRate: sampleRate)
        try deEsser.validate()
        try multibandCompressor.validate()
        try compressor.validate()
        try expander.validate()
        try pauseGate.validate()

        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        guard N60DynamicsSnapshotSetStereoMode(&snapshot, stereoMode.cType) else { throw DynamicsConfigurationError.invalidStereoWidener }
        guard N60DynamicsSnapshotSetStereoWidener(
            &snapshot,
            sampleRate,
            stereoWidener.enabled,
            stereoWidener.monoLowBand,
            stereoWidener.lowMidFrequencyHz,
            stereoWidener.midHighFrequencyHz,
            Float(stereoWidener.lowWidth),
            Float(stereoWidener.midWidth),
            Float(stereoWidener.highWidth)
        ) else { throw DynamicsConfigurationError.invalidStereoWidener }
        guard N60DynamicsSnapshotSetDCOffsetFilter(&snapshot, sampleRate, dcOffsetFilter.enabled) else { throw DynamicsConfigurationError.invalidDCOffsetFilter }
        guard N60DynamicsSnapshotSetInfrasonicFilter(&snapshot, sampleRate, infrasonicFilter.enabled, infrasonicFilter.cutoffHz, infrasonicFilter.slope.cType) else { throw DynamicsConfigurationError.invalidInfrasonicFilter }
        let mainsDepths = mainsNotch.harmonicDepthsDB.map(Float.init)
        let mainsConfigured = mainsDepths.withUnsafeBufferPointer { depths in
            N60DynamicsSnapshotSetMainsNotch(
                &snapshot,
                sampleRate,
                mainsNotch.enabled,
                mainsNotch.fundamentalHz,
                UInt32(mainsNotch.harmonicCount),
                Float(mainsNotch.q),
                depths.baseAddress!,
                UInt32(depths.count)
            )
        }
        guard mainsConfigured else { throw DynamicsConfigurationError.invalidMainsNotch }
        guard N60DynamicsSnapshotSetMainsHumDetector(
            &snapshot,
            sampleRate,
            true,
            mainsNotch.region.fundamentalHz
        ) else { throw DynamicsConfigurationError.invalidMainsHumDetector }
        guard N60DynamicsSnapshotSetSpectralDenoiser(
            &snapshot,
            sampleRate,
            spectralDenoiser.enabled,
            spectralDenoiser.algorithmPreset.cType,
            spectralDenoiser.quality.cType,
            Float(spectralDenoiser.reductionAmount),
            Float(spectralDenoiser.thresholdDBFS),
            spectralDenoiser.protectedRangeEnabled,
            Float(spectralDenoiser.protectedLowHz),
            Float(spectralDenoiser.protectedHighHz),
            spectralDenoiser.profileRevision,
            spectralDenoiser.profileCommand.cType
        ) else { throw DynamicsConfigurationError.invalidSpectralDenoiser }
        guard N60DynamicsSnapshotSetLoudnessMatch(
            &snapshot,
            sampleRate,
            loudnessMatch.enabled,
            loudnessMatch.dialogueGateEnabled,
            Float(loudnessMatch.targetLUFS),
            Float(loudnessMatch.maxCorrectionDB),
            Float(loudnessMatch.attackSeconds),
            Float(loudnessMatch.releaseSeconds)
        ) else { throw DynamicsConfigurationError.invalidLoudnessMatch }
        guard N60DynamicsSnapshotSetLoudnessContour(&snapshot, sampleRate, loudnessContour.enabled, Float(loudnessContour.strength)) else { throw DynamicsConfigurationError.invalidLoudnessContour }
        guard N60DynamicsSnapshotSetDialogueLeveler(
            &snapshot,
            sampleRate,
            dialogueRelativeLeveler.enabled,
            dialogueRelativeLeveler.bandLowHz,
            dialogueRelativeLeveler.bandHighHz,
            Float(dialogueRelativeLeveler.targetGapDB),
            Float(dialogueRelativeLeveler.boostRatio),
            Float(dialogueRelativeLeveler.maxBoostDB),
            Float(dialogueRelativeLeveler.detectorWindowMs),
            Float(dialogueRelativeLeveler.attackMs),
            Float(dialogueRelativeLeveler.releaseMs),
            Float(dialogueRelativeLeveler.programGateThresholdDB),
            dialogueRelativeLeveler.voiceGate.enabled,
            Float(dialogueRelativeLeveler.voiceGate.modulationCenterHz),
            Float(dialogueRelativeLeveler.voiceGate.modulationBandwidthHz),
            Float(dialogueRelativeLeveler.voiceGate.envelopeWindowMs),
            Float(dialogueRelativeLeveler.voiceGate.measurementWindowMs),
            Float(dialogueRelativeLeveler.voiceGate.confidenceFloorIndex),
            Float(dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex),
            Float(dialogueRelativeLeveler.voiceGate.minConfidence)
        ) else { throw DynamicsConfigurationError.invalidDialogueLeveler }
        guard N60DynamicsSnapshotSetDynamicEQEnabled(&snapshot, dynamicEQ.enabled) else {
            throw DynamicsConfigurationError.invalidDynamicEQ
        }
        for (index, band) in dynamicEQ.bands.enumerated() {
            guard N60DynamicsSnapshotSetDynamicEQBand(
                &snapshot,
                sampleRate,
                UInt32(index),
                band.enabled,
                band.frequencyHz,
                Float(band.q),
                Float(band.staticGainDB),
                Float(band.thresholdDB),
                Float(band.ratio),
                Float(band.rangeDB),
                Float(band.attackMs),
                Float(band.releaseMs),
                band.direction.cType,
                Float(band.boostThresholdDB),
                Float(band.boostRatio),
                Float(band.maxBoostDB),
                band.detectorMode.cType,
                Float(band.rmsWindowMs)
            ) else { throw DynamicsConfigurationError.invalidDynamicEQ }
        }
        guard N60DynamicsSnapshotSetDeEsserAdvanced(
            &snapshot,
            sampleRate,
            deEsser.enabled,
            deEsser.frequencyHz,
            Float(deEsser.thresholdDB),
            Float(deEsser.ratio),
            Float(deEsser.rangeDB),
            Float(deEsser.detectionQ),
            Float(deEsser.attackMs),
            Float(deEsser.releaseMs),
            deEsser.dynamicEQMode
        ) else { throw DynamicsConfigurationError.invalidDeEsser }
        guard N60DynamicsSnapshotSetMultibandCompressorAdvanced(
            &snapshot,
            sampleRate,
            multibandCompressor.enabled,
            multibandCompressor.lowMidFrequencyHz,
            multibandCompressor.midHighFrequencyHz,
            multibandCompressor.lowMidSlope.cType,
            multibandCompressor.midHighSlope.cType,
            Float(multibandCompressor.lowThresholdDB), Float(multibandCompressor.midThresholdDB), Float(multibandCompressor.highThresholdDB),
            Float(multibandCompressor.lowRatio), Float(multibandCompressor.midRatio), Float(multibandCompressor.highRatio),
            Float(multibandCompressor.lowAttackMs), Float(multibandCompressor.midAttackMs), Float(multibandCompressor.highAttackMs),
            Float(multibandCompressor.lowReleaseMs), Float(multibandCompressor.midReleaseMs), Float(multibandCompressor.highReleaseMs),
            Float(multibandCompressor.lowKneeDB), Float(multibandCompressor.midKneeDB), Float(multibandCompressor.highKneeDB),
            Float(multibandCompressor.lowSidechainHighPassHz), Float(multibandCompressor.midSidechainHighPassHz), Float(multibandCompressor.highSidechainHighPassHz),
            Float(multibandCompressor.lowMakeupGainDB), Float(multibandCompressor.midMakeupGainDB), Float(multibandCompressor.highMakeupGainDB)
        ) else { throw DynamicsConfigurationError.invalidMultibandCompressor }
        guard N60DynamicsSnapshotSetCompressorAdvanced(
            &snapshot,
            sampleRate,
            compressor.enabled,
            Float(compressor.thresholdDB),
            Float(compressor.ratio),
            Float(compressor.kneeWidthDB),
            Float(compressor.attackMs),
            Float(compressor.releaseMs),
            Float(compressor.makeupGainDB),
            compressor.topology.cType,
            compressor.programDependentRelease,
            Float(compressor.sidechainHighPassHz)
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