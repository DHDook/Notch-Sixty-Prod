import Foundation

/// E28 S4: one row of the Dynamics page, described once. The page builds every slider and field from
/// these, and the tests check each against the engine's accepted ranges, so a slider can never offer a
/// value the engine rejects. Plain Swift; no UI and no engine access.
///
/// Owner decision 2 (7 Nov 2026): the slider keeps a useful range (`slider`), typed entry accepts the
/// full engine range (`config`), and the slider pins at its end for a value beyond it.
struct DynamicsParameterSpec: Identifiable {
    /// Writes beyond the single field. The pairs keep dependent values valid.
    enum Coupling: Equatable {
        case none
        /// Spectral Denoiser: any edit marks the preset Custom.
        case denoiserCustom
        /// Pause Gate: an edit that leaves the preset's values marks it Custom.
        case pauseGateCustom
        /// Voice Gate sensitivity: ceiling = value, floor = ceiling - 0.30 (not below 0).
        case voiceSensitivity
        /// Voice Gate floor stays at least 0.01 below the ceiling.
        case floorBelowCeiling
        /// Voice Gate ceiling stays at least 0.01 above the floor.
        case ceilingAboveFloor
        /// Dialogue Leveler Band Low stays at least 1 Hz below Band High (G19): the pair cannot be refused.
        case bandLowBelowHigh
        /// Dialogue Leveler Band High stays at least 1 Hz above Band Low.
        case bandHighAboveLow
    }

    let id: String
    /// The stage the row belongs to, named in a rejected-apply message.
    let stage: String
    let title: String
    let unit: ParameterUnit
    let keyPath: WritableKeyPath<DynamicsConfiguration, Double>
    /// The range the engine accepts; typed values clamp to it.
    let config: ClosedRange<Double>
    /// The range the slider spans (inside `config`).
    let slider: ClosedRange<Double>
    let scale: ParameterScale
    let stepKind: ParameterStepKind
    let digits: Int
    let formula: String?
    let coupling: Coupling
    /// The value Reset-by-double-click returns to (`DynamicsConfiguration()` default).
    var defaultValue: Double { DynamicsConfiguration()[keyPath: keyPath] }

    init(
        _ id: String,
        stage: String,
        _ title: String,
        _ unit: ParameterUnit,
        _ keyPath: WritableKeyPath<DynamicsConfiguration, Double>,
        config: ClosedRange<Double>,
        slider: ClosedRange<Double>,
        step: Double,
        digits: Int,
        formula: String? = nil,
        coupling: Coupling = .none
    ) {
        self.id = id
        self.stage = stage
        self.title = title
        self.unit = unit
        self.keyPath = keyPath
        self.config = config
        self.slider = slider
        self.digits = digits
        self.formula = formula
        self.coupling = coupling
        switch unit {
        case .hertz, .milliseconds:
            let floor = unit == .hertz ? 10.0 : 0.5
            scale = .logarithmic(floor: slider.lowerBound > 0 ? slider.lowerBound : floor)
            stepKind = .multiplicativeTime
        case .ratio:
            scale = .logarithmic(floor: slider.lowerBound)
            stepKind = .ratio
        case .decibels, .dbfs, .lufs:
            scale = .linear
            stepKind = .decibels
        case .seconds, .phon, .multiplier, .plain:
            scale = .linear
            stepKind = .linear(step: step)
        }
    }

    /// First value above the "off" stop of a log slider that starts at 0.
    var logFloor: Double {
        if case .logarithmic(let floor) = scale.kind { return floor }
        return slider.lowerBound
    }

    // MARK: Behaviour

    /// Slider position (0...1) of `value`; a value beyond the slider range pins at its end.
    func position(of value: Double) -> Double { scale.position(of: value, in: slider) }

    /// The value a slider position means, inside the slider range.
    func value(atPosition position: Double) -> Double { scale.value(at: position, in: slider) }

    func clamped(_ value: Double) -> Double { min(max(value, config.lowerBound), config.upperBound) }

    /// Parses typed text in this row's unit, clamped to the engine range; nil rejects the text.
    func parse(_ text: String, locale: Locale = .current) -> Double? {
        ValueParser.value(from: text, unit: unit, range: config, locale: locale)
    }

    func displayText(_ value: Double, locale: Locale = .current) -> String {
        ValueParser.displayText(value, digits: digits, locale: locale)
    }

    func nudged(_ value: Double, direction: EQNudge.Direction, step: EQNudge.Step) -> Double {
        ValueNudge.nudged(value, kind: stepKind, direction: direction, step: step, range: config, floor: logFloor)
    }

    /// Writes `value` (clamped to `config`) into `configuration`, with the row's coupling and the
    /// automatic makeup values that depend on it.
    func apply(_ value: Double, to configuration: inout DynamicsConfiguration) {
        let v = clamped(value)
        switch coupling {
        case .none:
            configuration[keyPath: keyPath] = v
        case .denoiserCustom:
            configuration[keyPath: keyPath] = v
            configuration.spectralDenoiser.markCustom()
        case .pauseGateCustom:
            configuration[keyPath: keyPath] = v
            configuration.pauseGate.markCustomIfNeeded()
        case .voiceSensitivity:
            configuration.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex = v
            configuration.dialogueRelativeLeveler.voiceGate.confidenceFloorIndex = max(0, v - 0.30)
        case .bandLowBelowHigh:
            configuration[keyPath: keyPath] = min(v, configuration.dialogueRelativeLeveler.bandHighHz - 1)
        case .bandHighAboveLow:
            configuration[keyPath: keyPath] = max(v, configuration.dialogueRelativeLeveler.bandLowHz + 1)
        case .floorBelowCeiling:
            let ceiling = configuration.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex
            configuration[keyPath: keyPath] = min(v, ceiling - 0.01)
        case .ceilingAboveFloor:
            let floor = configuration.dialogueRelativeLeveler.voiceGate.confidenceFloorIndex
            configuration[keyPath: keyPath] = max(v, floor + 0.01)
        }
        configuration.applyAutoMakeup()
    }

    /// "Compressor: Ratio 120:1 was rejected. <engine reason>".
    func rejectionMessage(value: Double, reason: String) -> String {
        "\(stage): \(title) \(displayText(value))\(unit.suffix.isEmpty ? "" : " " + unit.suffix) was rejected and the previous value was kept. \(reason)"
    }
}

// MARK: - Table

extension DynamicsParameterSpec {
    static let compressorThresholdDB = DynamicsParameterSpec("compressorThresholdDB", stage: "Compressor", "Threshold", .decibels, \.compressor.thresholdDB, config: CompressorConfiguration.thresholdRange, slider: -60.0...0.0, step: 0.5, digits: 1)
    static let compressorRatio = DynamicsParameterSpec("compressorRatio", stage: "Compressor", "Ratio", .ratio, \.compressor.ratio, config: CompressorConfiguration.ratioRange, slider: 1.0...20.0, step: 0.1, digits: 1, formula: "compressor-ratio")
    static let compressorKneeWidthDB = DynamicsParameterSpec("compressorKneeWidthDB", stage: "Compressor", "Knee", .decibels, \.compressor.kneeWidthDB, config: CompressorConfiguration.kneeRange, slider: 0.0...20.0, step: 0.5, digits: 1)
    static let compressorAttackMs = DynamicsParameterSpec("compressorAttackMs", stage: "Compressor", "Attack", .milliseconds, \.compressor.attackMs, config: CompressorConfiguration.attackRange, slider: 0.1...100.0, step: 0.5, digits: 1, formula: "time-constant")
    static let compressorReleaseMs = DynamicsParameterSpec("compressorReleaseMs", stage: "Compressor", "Release", .milliseconds, \.compressor.releaseMs, config: CompressorConfiguration.releaseRange, slider: 5.0...1000.0, step: 5, digits: 0, formula: "time-constant")
    static let compressorMakeupGainDB = DynamicsParameterSpec("compressorMakeupGainDB", stage: "Compressor", "Makeup Gain", .decibels, \.compressor.makeupGainDB, config: CompressorConfiguration.makeupRange, slider: -24.0...24.0, step: 0.5, digits: 1)
    static let compressorSidechainHighPassHz = DynamicsParameterSpec("compressorSidechainHighPassHz", stage: "Compressor", "Sidechain High-Pass", .hertz, \.compressor.sidechainHighPassHz, config: CompressorConfiguration.sidechainHighPassRange, slider: 0.0...300.0, step: 5, digits: 0)
    static let multibandCompressorLowMidFrequencyHz = DynamicsParameterSpec("multibandCompressorLowMidFrequencyHz", stage: "Multiband", "Low / Mid", .hertz, \.multibandCompressor.lowMidFrequencyHz, config: MultibandCompressorConfiguration.lowMidFrequencyRange, slider: 40.0...250.0, step: 5, digits: 0)
    static let multibandCompressorMidHighFrequencyHz = DynamicsParameterSpec("multibandCompressorMidHighFrequencyHz", stage: "Multiband", "Mid / High", .hertz, \.multibandCompressor.midHighFrequencyHz, config: MultibandCompressorConfiguration.midHighFrequencyRange, slider: 1000.0...8000.0, step: 100, digits: 0)
    static let expanderThresholdDB = DynamicsParameterSpec("expanderThresholdDB", stage: "Expander", "Threshold", .decibels, \.expander.thresholdDB, config: ExpanderConfiguration.thresholdRange, slider: -60.0...0.0, step: 0.5, digits: 1)
    static let expanderRatio = DynamicsParameterSpec("expanderRatio", stage: "Expander", "Ratio", .ratio, \.expander.ratio, config: ExpanderConfiguration.ratioRange, slider: 1.0...4.0, step: 0.1, digits: 1, formula: "expander-ratio")
    static let expanderRangeDB = DynamicsParameterSpec("expanderRangeDB", stage: "Expander", "Range", .decibels, \.expander.rangeDB, config: ExpanderConfiguration.rangeRange, slider: -40.0...0.0, step: 0.5, digits: 1)
    static let expanderAttackMs = DynamicsParameterSpec("expanderAttackMs", stage: "Expander", "Attack", .milliseconds, \.expander.attackMs, config: ExpanderConfiguration.attackRange, slider: 0.1...100.0, step: 0.5, digits: 1, formula: "time-constant")
    static let expanderReleaseMs = DynamicsParameterSpec("expanderReleaseMs", stage: "Expander", "Release", .milliseconds, \.expander.releaseMs, config: ExpanderConfiguration.releaseRange, slider: 10.0...1000.0, step: 10, digits: 0, formula: "time-constant")
    static let pauseGateThresholdDBFS = DynamicsParameterSpec("pauseGateThresholdDBFS", stage: "Pause Gate", "Threshold", .dbfs, \.pauseGate.thresholdDBFS, config: PauseGateConfiguration.thresholdRange, slider: -80.0 ... -40.0, step: 1, digits: 0, coupling: .pauseGateCustom)
    static let pauseGateHoldMs = DynamicsParameterSpec("pauseGateHoldMs", stage: "Pause Gate", "Hold", .milliseconds, \.pauseGate.holdMs, config: PauseGateConfiguration.holdRange, slider: 100.0...2000.0, step: 25, digits: 0, coupling: .pauseGateCustom)
    static let pauseGateAttackMs = DynamicsParameterSpec("pauseGateAttackMs", stage: "Pause Gate", "Attack", .milliseconds, \.pauseGate.attackMs, config: PauseGateConfiguration.attackRange, slider: 1.0...100.0, step: 1, digits: 0, coupling: .pauseGateCustom)
    static let pauseGateReleaseMs = DynamicsParameterSpec("pauseGateReleaseMs", stage: "Pause Gate", "Release", .milliseconds, \.pauseGate.releaseMs, config: PauseGateConfiguration.releaseRange, slider: 10.0...500.0, step: 5, digits: 0, coupling: .pauseGateCustom)
    static let pauseGateHysteresisDB = DynamicsParameterSpec("pauseGateHysteresisDB", stage: "Pause Gate", "Hysteresis", .decibels, \.pauseGate.hysteresisDB, config: PauseGateConfiguration.hysteresisRange, slider: 0.0...6.0, step: 0.5, digits: 1, coupling: .pauseGateCustom)
    static let gainRiderTargetGainReductionDB = DynamicsParameterSpec("gainRiderTargetGainReductionDB", stage: "Gain Rider", "Target Gain Reduction", .decibels, \.gainRider.targetGainReductionDB, config: GainRiderConfiguration.targetRange, slider: 0.5...6.0, step: 0.5, digits: 1)
    static let gainRiderMaxReductionDB = DynamicsParameterSpec("gainRiderMaxReductionDB", stage: "Gain Rider", "Maximum Reduction", .decibels, \.gainRider.maxReductionDB, config: GainRiderConfiguration.maxReductionRange, slider: 3.0...12.0, step: 1, digits: 0)
    static let spectralDenoiserThresholdDBFS = DynamicsParameterSpec("spectralDenoiserThresholdDBFS", stage: "Spectral Denoiser", "Threshold", .dbfs, \.spectralDenoiser.thresholdDBFS, config: SpectralDenoiserConfiguration.thresholdRange, slider: -96.0 ... -30.0, step: 1, digits: 0, coupling: .denoiserCustom)
    static let spectralDenoiserReductionAmount = DynamicsParameterSpec("spectralDenoiserReductionAmount", stage: "Spectral Denoiser", "Reduction", .plain, \.spectralDenoiser.reductionAmount, config: SpectralDenoiserConfiguration.reductionRange, slider: 0.0...1.0, step: 0.01, digits: 2, coupling: .denoiserCustom)
    static let spectralDenoiserProtectedLowHz = DynamicsParameterSpec("spectralDenoiserProtectedLowHz", stage: "Spectral Denoiser", "Protect From", .hertz, \.spectralDenoiser.protectedLowHz, config: SpectralDenoiserConfiguration.protectedFrequencyRange, slider: 0.0...20000.0, step: 10, digits: 0, coupling: .denoiserCustom)
    static let spectralDenoiserProtectedHighHz = DynamicsParameterSpec("spectralDenoiserProtectedHighHz", stage: "Spectral Denoiser", "Protect To", .hertz, \.spectralDenoiser.protectedHighHz, config: SpectralDenoiserConfiguration.protectedFrequencyRange, slider: 0.0...20000.0, step: 10, digits: 0, coupling: .denoiserCustom)
    static let spectralDenoiserMinimumGain = DynamicsParameterSpec("spectralDenoiserMinimumGain", stage: "Spectral Denoiser", "Wiener / Minimum Gain", .plain, \.spectralDenoiser.minimumGain, config: SpectralDenoiserConfiguration.minimumGainRange, slider: 0.001...0.5, step: 0.001, digits: 3, coupling: .denoiserCustom)
    static let spectralDenoiserAttackMs = DynamicsParameterSpec("spectralDenoiserAttackMs", stage: "Spectral Denoiser", "Attack", .milliseconds, \.spectralDenoiser.attackMs, config: SpectralDenoiserConfiguration.attackRange, slider: 1.0...100.0, step: 1, digits: 0, coupling: .denoiserCustom)
    static let spectralDenoiserReleaseMs = DynamicsParameterSpec("spectralDenoiserReleaseMs", stage: "Spectral Denoiser", "Release", .milliseconds, \.spectralDenoiser.releaseMs, config: SpectralDenoiserConfiguration.releaseRange, slider: 5.0...500.0, step: 5, digits: 0, coupling: .denoiserCustom)
    static let deEsserFrequencyHz = DynamicsParameterSpec("deEsserFrequencyHz", stage: "De-Esser", "Frequency", .hertz, \.deEsser.frequencyHz, config: DeEsserConfiguration.frequencyRange, slider: 2000.0...10000.0, step: 50, digits: 0)
    static let deEsserDetectionQ = DynamicsParameterSpec("deEsserDetectionQ", stage: "De-Esser", "Detector Q", .plain, \.deEsser.detectionQ, config: DeEsserConfiguration.detectionQRange, slider: 0.5...8.0, step: 0.1, digits: 1)
    static let deEsserThresholdDB = DynamicsParameterSpec("deEsserThresholdDB", stage: "De-Esser", "Threshold", .decibels, \.deEsser.thresholdDB, config: DeEsserConfiguration.thresholdRange, slider: -60.0...0.0, step: 0.5, digits: 1)
    static let deEsserRatio = DynamicsParameterSpec("deEsserRatio", stage: "De-Esser", "Ratio", .ratio, \.deEsser.ratio, config: DeEsserConfiguration.ratioRange, slider: 1.0...20.0, step: 0.5, digits: 1)
    static let deEsserRangeDB = DynamicsParameterSpec("deEsserRangeDB", stage: "De-Esser", "Range", .decibels, \.deEsser.rangeDB, config: DeEsserConfiguration.rangeRange, slider: -24.0...0.0, step: 1, digits: 0)
    static let deEsserAttackMs = DynamicsParameterSpec("deEsserAttackMs", stage: "De-Esser", "Attack", .milliseconds, \.deEsser.attackMs, config: DeEsserConfiguration.attackRange, slider: 0.1...100.0, step: 0.1, digits: 1)
    static let deEsserReleaseMs = DynamicsParameterSpec("deEsserReleaseMs", stage: "De-Esser", "Release", .milliseconds, \.deEsser.releaseMs, config: DeEsserConfiguration.releaseRange, slider: 10.0...1000.0, step: 5, digits: 0)
    static let mainsNotchQ = DynamicsParameterSpec("mainsNotchQ", stage: "Mains Hum", "Global Q", .plain, \.mainsNotch.q, config: MainsNotchConfiguration.qRange, slider: 5.0...60.0, step: 1, digits: 0)
    static let infrasonicFilterCutoffHz = DynamicsParameterSpec("infrasonicFilterCutoffHz", stage: "Infrasonic Filter", "Cutoff", .hertz, \.infrasonicFilter.cutoffHz, config: InfrasonicFilterConfiguration.cutoffRange, slider: 10.0...30.0, step: 1, digits: 0)
    static let loudnessMatchTargetLUFS = DynamicsParameterSpec("loudnessMatchTargetLUFS", stage: "Loudness Match", "Target", .lufs, \.loudnessMatch.targetLUFS, config: LoudnessMatchConfiguration.targetRange, slider: -24.0 ... -10.0, step: 0.5, digits: 1)
    static let loudnessMatchMaxCorrectionDB = DynamicsParameterSpec("loudnessMatchMaxCorrectionDB", stage: "Loudness Match", "Maximum Correction", .decibels, \.loudnessMatch.maxCorrectionDB, config: LoudnessMatchConfiguration.maxCorrectionRange, slider: 3.0...20.0, step: 1, digits: 0)
    static let loudnessMatchAttackSeconds = DynamicsParameterSpec("loudnessMatchAttackSeconds", stage: "Loudness Match", "Attack", .seconds, \.loudnessMatch.attackSeconds, config: LoudnessMatchConfiguration.attackRange, slider: 0.3...5.0, step: 0.1, digits: 1)
    static let loudnessMatchReleaseSeconds = DynamicsParameterSpec("loudnessMatchReleaseSeconds", stage: "Loudness Match", "Release", .seconds, \.loudnessMatch.releaseSeconds, config: LoudnessMatchConfiguration.releaseRange, slider: 1.0...10.0, step: 0.1, digits: 1)
    static let loudnessContourStrength = DynamicsParameterSpec("loudnessContourStrength", stage: "Loudness Contour", "Strength", .plain, \.loudnessContour.strength, config: LoudnessContourConfiguration.strengthRange, slider: 0.0...1.0, step: 0.05, digits: 2)
    static let loudnessContourReferencePhons = DynamicsParameterSpec("loudnessContourReferencePhons", stage: "Loudness Contour", "Reference Level", .phon, \.loudnessContour.referencePhons, config: LoudnessContourConfiguration.referencePhonsRange, slider: 60.0...95.0, step: 1, digits: 0)
    static let loudnessContourMaxBoostDB = DynamicsParameterSpec("loudnessContourMaxBoostDB", stage: "Loudness Contour", "Maximum Boost", .decibels, \.loudnessContour.maxBoostDB, config: LoudnessContourConfiguration.maxBoostRange, slider: 6.0...20.0, step: 0.5, digits: 1)
    static let loudnessContourMaxCutDB = DynamicsParameterSpec("loudnessContourMaxCutDB", stage: "Loudness Contour", "Maximum Cut", .decibels, \.loudnessContour.maxCutDB, config: LoudnessContourConfiguration.maxCutRange, slider: 0.0...6.0, step: 0.5, digits: 1)
    static let dialogueRelativeLevelerBandLowHz = DynamicsParameterSpec("dialogueRelativeLevelerBandLowHz", stage: "Dialogue Leveler", "Band Low", .hertz, \.dialogueRelativeLeveler.bandLowHz, config: DialogueRelativeLevelerConfiguration.bandRange, slider: 100.0...8000.0, step: 50, digits: 0, coupling: .bandLowBelowHigh)
    static let dialogueRelativeLevelerBandHighHz = DynamicsParameterSpec("dialogueRelativeLevelerBandHighHz", stage: "Dialogue Leveler", "Band High", .hertz, \.dialogueRelativeLeveler.bandHighHz, config: DialogueRelativeLevelerConfiguration.bandRange, slider: 100.0...8000.0, step: 50, digits: 0, coupling: .bandHighAboveLow)
    static let dialogueRelativeLevelerTargetGapDB = DynamicsParameterSpec("dialogueRelativeLevelerTargetGapDB", stage: "Dialogue Leveler", "Target Gap", .decibels, \.dialogueRelativeLeveler.targetGapDB, config: DialogueRelativeLevelerConfiguration.targetGapRange, slider: 3.0...20.0, step: 0.5, digits: 1)
    static let dialogueRelativeLevelerBoostRatio = DynamicsParameterSpec("dialogueRelativeLevelerBoostRatio", stage: "Dialogue Leveler", "Boost Ratio", .ratio, \.dialogueRelativeLeveler.boostRatio, config: DialogueRelativeLevelerConfiguration.boostRatioRange, slider: 1.0...6.0, step: 0.1, digits: 1)
    static let dialogueRelativeLevelerMaxBoostDB = DynamicsParameterSpec("dialogueRelativeLevelerMaxBoostDB", stage: "Dialogue Leveler", "Maximum Boost", .decibels, \.dialogueRelativeLeveler.maxBoostDB, config: DialogueRelativeLevelerConfiguration.maxBoostRange, slider: 0.0...15.0, step: 0.5, digits: 1)
    static let dialogueRelativeLevelerAttackMs = DynamicsParameterSpec("dialogueRelativeLevelerAttackMs", stage: "Dialogue Leveler", "Attack", .milliseconds, \.dialogueRelativeLeveler.attackMs, config: DialogueRelativeLevelerConfiguration.attackRange, slider: 10.0...1000.0, step: 10, digits: 0)
    static let dialogueRelativeLevelerReleaseMs = DynamicsParameterSpec("dialogueRelativeLevelerReleaseMs", stage: "Dialogue Leveler", "Release", .milliseconds, \.dialogueRelativeLeveler.releaseMs, config: DialogueRelativeLevelerConfiguration.releaseRange, slider: 50.0...3000.0, step: 50, digits: 0)
    static let dialogueRelativeLevelerProgramGateThresholdDB = DynamicsParameterSpec("dialogueRelativeLevelerProgramGateThresholdDB", stage: "Dialogue Leveler", "Program Gate", .dbfs, \.dialogueRelativeLeveler.programGateThresholdDB, config: DialogueRelativeLevelerConfiguration.programGateRange, slider: -70.0 ... -30.0, step: 1, digits: 0)
    static let dialogueRelativeLevelerVoiceGateSensitivity = DynamicsParameterSpec("dialogueRelativeLevelerVoiceGateSensitivity", stage: "Dialogue Leveler", "Sensitivity", .plain, \.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex, config: 0.01...1.0, slider: 0.2...0.8, step: 0.05, digits: 2, coupling: .voiceSensitivity)
    static let dialogueRelativeLevelerVoiceGateMinConfidence = DynamicsParameterSpec("dialogueRelativeLevelerVoiceGateMinConfidence", stage: "Dialogue Leveler", "Minimum Confidence", .plain, \.dialogueRelativeLeveler.voiceGate.minConfidence, config: DialogueVoiceGateConfiguration.confidenceRange, slider: 0.0...0.6, step: 0.05, digits: 2)
    static let dialogueRelativeLevelerDetectorWindowMs = DynamicsParameterSpec("dialogueRelativeLevelerDetectorWindowMs", stage: "Dialogue Leveler", "Detector Window", .milliseconds, \.dialogueRelativeLeveler.detectorWindowMs, config: DialogueRelativeLevelerConfiguration.detectorWindowRange, slider: 50.0...500.0, step: 10, digits: 0)
    static let dialogueRelativeLevelerVoiceGateModulationCenterHz = DynamicsParameterSpec("dialogueRelativeLevelerVoiceGateModulationCenterHz", stage: "Dialogue Leveler", "Modulation Center", .hertz, \.dialogueRelativeLeveler.voiceGate.modulationCenterHz, config: DialogueVoiceGateConfiguration.centerRange, slider: 2.0...10.0, step: 0.5, digits: 1)
    static let dialogueRelativeLevelerVoiceGateModulationBandwidthHz = DynamicsParameterSpec("dialogueRelativeLevelerVoiceGateModulationBandwidthHz", stage: "Dialogue Leveler", "Modulation Bandwidth", .hertz, \.dialogueRelativeLeveler.voiceGate.modulationBandwidthHz, config: DialogueVoiceGateConfiguration.bandwidthRange, slider: 2.0...8.0, step: 0.5, digits: 1)
    static let dialogueRelativeLevelerVoiceGateEnvelopeWindowMs = DynamicsParameterSpec("dialogueRelativeLevelerVoiceGateEnvelopeWindowMs", stage: "Dialogue Leveler", "Envelope Window", .milliseconds, \.dialogueRelativeLeveler.voiceGate.envelopeWindowMs, config: DialogueVoiceGateConfiguration.envelopeWindowRange, slider: 5.0...30.0, step: 1, digits: 0)
    static let dialogueRelativeLevelerVoiceGateMeasurementWindowMs = DynamicsParameterSpec("dialogueRelativeLevelerVoiceGateMeasurementWindowMs", stage: "Dialogue Leveler", "Measurement Window", .milliseconds, \.dialogueRelativeLeveler.voiceGate.measurementWindowMs, config: DialogueVoiceGateConfiguration.measurementWindowRange, slider: 300.0...1500.0, step: 50, digits: 0)
    static let dialogueRelativeLevelerVoiceGateConfidenceFloorIndex = DynamicsParameterSpec("dialogueRelativeLevelerVoiceGateConfidenceFloorIndex", stage: "Dialogue Leveler", "Confidence Floor", .plain, \.dialogueRelativeLeveler.voiceGate.confidenceFloorIndex, config: DialogueVoiceGateConfiguration.confidenceRange, slider: 0.0...0.99, step: 0.01, digits: 2, coupling: .floorBelowCeiling)
    static let dialogueRelativeLevelerVoiceGateConfidenceCeilingIndex = DynamicsParameterSpec("dialogueRelativeLevelerVoiceGateConfidenceCeilingIndex", stage: "Dialogue Leveler", "Confidence Ceiling", .plain, \.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex, config: DialogueVoiceGateConfiguration.confidenceRange, slider: 0.01...1.0, step: 0.01, digits: 2, coupling: .ceilingAboveFloor)
    static let limiterCeilingDB = DynamicsParameterSpec("limiterCeilingDB", stage: "Limiter", "Ceiling", .decibels, \.limiter.ceilingDB, config: LimiterConfiguration.ceilingRange, slider: -20.0...0.0, step: 0.1, digits: 1)
    static let limiterAttackMs = DynamicsParameterSpec("limiterAttackMs", stage: "Limiter", "Attack", .milliseconds, \.limiter.attackMs, config: LimiterConfiguration.attackRange, slider: 0.1...50.0, step: 0.1, digits: 1)
    static let limiterReleaseMs = DynamicsParameterSpec("limiterReleaseMs", stage: "Limiter", "Release", .milliseconds, \.limiter.releaseMs, config: LimiterConfiguration.releaseRange, slider: 5.0...500.0, step: 5, digits: 0)
    static let limiterLookAheadMs = DynamicsParameterSpec("limiterLookAheadMs", stage: "Limiter", "Look-Ahead", .milliseconds, \.limiter.lookAheadMs, config: LimiterConfiguration.lookAheadRange, slider: 0.0...20.0, step: 0.5, digits: 1)
    static let softClipperDriveDB = DynamicsParameterSpec("softClipperDriveDB", stage: "Soft Clipper", "Drive", .decibels, \.softClipper.driveDB, config: SoftClipperConfiguration.driveRange, slider: 0.0...12.0, step: 0.5, digits: 1)
    static let softClipperThresholdDB = DynamicsParameterSpec("softClipperThresholdDB", stage: "Soft Clipper", "Threshold", .decibels, \.softClipper.thresholdDB, config: SoftClipperConfiguration.thresholdRange, slider: -6.0...0.0, step: 0.1, digits: 1)
    static let softClipperKneeSmooth = DynamicsParameterSpec("softClipperKneeSmooth", stage: "Soft Clipper", "Knee", .plain, \.softClipper.kneeSmooth, config: SoftClipperConfiguration.kneeRange, slider: 0.0...1.0, step: 0.01, digits: 2)
    static let softClipperAsymmetryTrimDB = DynamicsParameterSpec("softClipperAsymmetryTrimDB", stage: "Soft Clipper", "Asymmetry Trim", .decibels, \.softClipper.asymmetryTrimDB, config: SoftClipperConfiguration.asymmetryTrimRange, slider: -3.0...3.0, step: 0.1, digits: 1)
    static let automaticHeadroomMaxAttenuationDB = DynamicsParameterSpec("automaticHeadroomMaxAttenuationDB", stage: "Automatic Headroom", "Maximum Attenuation", .decibels, \.automaticHeadroom.maxAttenuationDB, config: AutomaticHeadroomConfiguration.maxAttenuationRange, slider: 3.0...24.0, step: 1, digits: 0)
    static let deHarshAmountDB = DynamicsParameterSpec("deHarshAmountDB", stage: "De-Harsh", "Amount", .decibels, \.deHarsh.amountDB, config: DeHarshConfiguration.amountRange, slider: -6.0...0.0, step: 0.1, digits: 1)
    static let deHarshFrequencyHz = DynamicsParameterSpec("deHarshFrequencyHz", stage: "De-Harsh", "Frequency", .hertz, \.deHarsh.frequencyHz, config: DeHarshConfiguration.frequencyRange, slider: 1500.0...10000.0, step: 50, digits: 0)
    static let stereoWidenerLowWidth = DynamicsParameterSpec("stereoWidenerLowWidth", stage: "Stereo Widener", "Low Width", .multiplier, \.stereoWidener.lowWidth, config: StereoWidenerConfiguration.lowWidthRange, slider: 0.0...1.0, step: 0.01, digits: 2)
    static let stereoWidenerLowMidFrequencyHz = DynamicsParameterSpec("stereoWidenerLowMidFrequencyHz", stage: "Stereo Widener", "Low / Mid Crossover", .hertz, \.stereoWidener.lowMidFrequencyHz, config: StereoWidenerConfiguration.lowMidFrequencyRange, slider: 80.0...500.0, step: 10, digits: 0)
    static let stereoWidenerMidWidth = DynamicsParameterSpec("stereoWidenerMidWidth", stage: "Stereo Widener", "Mid Width", .multiplier, \.stereoWidener.midWidth, config: StereoWidenerConfiguration.midWidthRange, slider: 1.0...2.0, step: 0.01, digits: 2)
    static let stereoWidenerMidHighFrequencyHz = DynamicsParameterSpec("stereoWidenerMidHighFrequencyHz", stage: "Stereo Widener", "Mid / High Crossover", .hertz, \.stereoWidener.midHighFrequencyHz, config: StereoWidenerConfiguration.midHighFrequencyRange, slider: 1500.0...8000.0, step: 100, digits: 0)
    static let stereoWidenerHighWidth = DynamicsParameterSpec("stereoWidenerHighWidth", stage: "Stereo Widener", "High Width", .multiplier, \.stereoWidener.highWidth, config: StereoWidenerConfiguration.highWidthRange, slider: 1.0...2.0, step: 0.01, digits: 2)

    // E28 S7d: the extras (behind `e28.dynamics-extras`). Percent rows use the plain unit with "(%)" in the title.
    static let compressorMixPercent = DynamicsParameterSpec("compressorMixPercent", stage: "Compressor", "Mix (%)", .plain, \.compressor.mixPercentValue, config: CompressorConfiguration.mixRange, slider: 0.0...100.0, step: 1, digits: 0)
    static let compressorLinkPercent = DynamicsParameterSpec("compressorLinkPercent", stage: "Compressor", "Link (%)", .plain, \.compressor.linkPercentValue, config: CompressorConfiguration.linkRange, slider: 0.0...100.0, step: 1, digits: 0)
    static let compressorRMSWindowMs = DynamicsParameterSpec("compressorRMSWindowMs", stage: "Compressor", "Detector Window", .milliseconds, \.compressor.rmsWindowMsValue, config: CompressorConfiguration.rmsWindowRange, slider: 5.0...200.0, step: 1, digits: 0)
    static let compressorLookaheadMs = DynamicsParameterSpec("compressorLookaheadMs", stage: "Compressor", "Lookahead", .milliseconds, \.compressor.lookaheadTimeMs, config: CompressorConfiguration.lookaheadPageRange, slider: 1.0...10.0, step: 0.5, digits: 1)
    static let expanderHoldMs = DynamicsParameterSpec("expanderHoldMs", stage: "Expander", "Hold", .milliseconds, \.expander.holdMsValue, config: ExpanderConfiguration.holdRange, slider: 0.0...500.0, step: 5, digits: 0)
    static let expanderKneeDB = DynamicsParameterSpec("expanderKneeDB", stage: "Expander", "Knee", .decibels, \.expander.kneeDBValue, config: ExpanderConfiguration.kneeRange, slider: 0.0...24.0, step: 0.5, digits: 1)
    static let expanderRMSWindowMs = DynamicsParameterSpec("expanderRMSWindowMs", stage: "Expander", "Detector Window", .milliseconds, \.expander.rmsWindowMsValue, config: ExpanderConfiguration.rmsWindowRange, slider: 5.0...200.0, step: 1, digits: 0)
    static let expanderSidechainHighPassHz = DynamicsParameterSpec("expanderSidechainHighPassHz", stage: "Expander", "Sidechain High-Pass", .hertz, \.expander.sidechainHighPassHzValue, config: ExpanderConfiguration.sidechainHighPassRange, slider: 0.0...300.0, step: 5, digits: 0)
    static let expanderLinkPercent = DynamicsParameterSpec("expanderLinkPercent", stage: "Expander", "Link (%)", .plain, \.expander.linkPercentValue, config: ExpanderConfiguration.linkRange, slider: 0.0...100.0, step: 1, digits: 0)
    static let multibandRMSWindowMs = DynamicsParameterSpec("multibandRMSWindowMs", stage: "Multiband", "Detector Window", .milliseconds, \.multibandCompressor.rmsWindowMsValue, config: MultibandCompressorConfiguration.rmsWindowRange, slider: 5.0...200.0, step: 1, digits: 0)
    static let multibandLookaheadMs = DynamicsParameterSpec("multibandLookaheadMs", stage: "Multiband", "Lookahead", .milliseconds, \.multibandCompressor.lookaheadTimeMs, config: CompressorConfiguration.lookaheadPageRange, slider: 1.0...10.0, step: 0.5, digits: 1)

    /// The S7 extra rows with a numeric field (every one is disabled with a reason where the kernel renders).
    static let extras: [DynamicsParameterSpec] = [
        compressorMixPercent, compressorLinkPercent, compressorRMSWindowMs, compressorLookaheadMs,
        expanderHoldMs, expanderKneeDB, expanderRMSWindowMs, expanderSidechainHighPassHz, expanderLinkPercent,
        multibandRMSWindowMs, multibandLookaheadMs,
    ]

    /// The Mains Hum harmonic depth for harmonic `index` (0-based).
    static func harmonicDepth(_ index: Int) -> DynamicsParameterSpec {
        DynamicsParameterSpec(
            "mainsNotchHarmonicDepth\(index)", stage: "Mains Hum", "Harmonic \(index + 1) depth", .decibels,
            \.mainsNotch.harmonicDepthsDB[index],
            config: MainsNotchConfiguration.depthRange, slider: -40.0...0.0, step: 1, digits: 0
        )
    }

    /// One multiband band's seven rows. `band` is 0 low, 1 mid, 2 high.
    static func multibandBand(_ band: Int) -> [DynamicsParameterSpec] {
        let prefix = ["low", "mid", "high"][band]
        let stage = ["Multiband Low Band", "Multiband Mid Band", "Multiband High Band"][band]
        typealias M = MultibandCompressorConfiguration
        func kp(_ suffix: String) -> WritableKeyPath<DynamicsConfiguration, Double> {
            switch (prefix, suffix) {
            case ("low", "Threshold"): return \.multibandCompressor.lowThresholdDB
            case ("mid", "Threshold"): return \.multibandCompressor.midThresholdDB
            case ("high", "Threshold"): return \.multibandCompressor.highThresholdDB
            case ("low", "Ratio"): return \.multibandCompressor.lowRatio
            case ("mid", "Ratio"): return \.multibandCompressor.midRatio
            case ("high", "Ratio"): return \.multibandCompressor.highRatio
            case ("low", "Attack"): return \.multibandCompressor.lowAttackMs
            case ("mid", "Attack"): return \.multibandCompressor.midAttackMs
            case ("high", "Attack"): return \.multibandCompressor.highAttackMs
            case ("low", "Release"): return \.multibandCompressor.lowReleaseMs
            case ("mid", "Release"): return \.multibandCompressor.midReleaseMs
            case ("high", "Release"): return \.multibandCompressor.highReleaseMs
            case ("low", "Knee"): return \.multibandCompressor.lowKneeDB
            case ("mid", "Knee"): return \.multibandCompressor.midKneeDB
            case ("high", "Knee"): return \.multibandCompressor.highKneeDB
            case ("low", "Makeup"): return \.multibandCompressor.lowMakeupGainDB
            case ("mid", "Makeup"): return \.multibandCompressor.midMakeupGainDB
            case ("high", "Makeup"): return \.multibandCompressor.highMakeupGainDB
            case ("low", _): return \.multibandCompressor.lowSidechainHighPassHz
            case ("mid", _): return \.multibandCompressor.midSidechainHighPassHz
            default: return \.multibandCompressor.highSidechainHighPassHz
            }
        }
        func spec(_ suffix: String, _ title: String, _ unit: ParameterUnit, _ config: ClosedRange<Double>,
                  _ slider: ClosedRange<Double>, _ step: Double, _ digits: Int) -> DynamicsParameterSpec {
            DynamicsParameterSpec("multiband\(prefix.capitalized)\(suffix)", stage: stage, title, unit, kp(suffix),
                                  config: config, slider: slider, step: step, digits: digits)
        }
        return [
            spec("Threshold", "Threshold", .decibels, M.thresholdRange, -60.0...0.0, 0.5, 1),
            spec("Ratio", "Ratio", .ratio, M.ratioRange, 1.0...20.0, 0.5, 1),
            spec("Attack", "Attack", .milliseconds, M.attackRange, 1.0...200.0, 1, 0),
            spec("Release", "Release", .milliseconds, M.releaseRange, 10.0...1_000.0, 10, 0),
            spec("Knee", "Knee", .decibels, M.kneeRange, 0.0...20.0, 0.5, 1),
            spec("Makeup", "Makeup Gain", .decibels, M.makeupRange, -12.0...12.0, 0.5, 1),
            spec("Sidechain", "Sidechain High-Pass", .hertz, M.sidechainRange, 0.0...300.0, 5, 0),
        ]
    }

    /// Every fixed row of the page (harmonic depths are built per index).
    static let all: [DynamicsParameterSpec] = extras + [
        compressorThresholdDB,
        compressorRatio,
        compressorKneeWidthDB,
        compressorAttackMs,
        compressorReleaseMs,
        compressorMakeupGainDB,
        compressorSidechainHighPassHz,
        multibandCompressorLowMidFrequencyHz,
        multibandCompressorMidHighFrequencyHz,
        expanderThresholdDB,
        expanderRatio,
        expanderRangeDB,
        expanderAttackMs,
        expanderReleaseMs,
        pauseGateThresholdDBFS,
        pauseGateHoldMs,
        pauseGateAttackMs,
        pauseGateReleaseMs,
        pauseGateHysteresisDB,
        gainRiderTargetGainReductionDB,
        gainRiderMaxReductionDB,
        spectralDenoiserThresholdDBFS,
        spectralDenoiserReductionAmount,
        spectralDenoiserProtectedLowHz,
        spectralDenoiserProtectedHighHz,
        spectralDenoiserMinimumGain,
        spectralDenoiserAttackMs,
        spectralDenoiserReleaseMs,
        deEsserFrequencyHz,
        deEsserDetectionQ,
        deEsserThresholdDB,
        deEsserRatio,
        deEsserRangeDB,
        deEsserAttackMs,
        deEsserReleaseMs,
        mainsNotchQ,
        infrasonicFilterCutoffHz,
        loudnessMatchTargetLUFS,
        loudnessMatchMaxCorrectionDB,
        loudnessMatchAttackSeconds,
        loudnessMatchReleaseSeconds,
        loudnessContourStrength,
        loudnessContourReferencePhons,
        loudnessContourMaxBoostDB,
        loudnessContourMaxCutDB,
        dialogueRelativeLevelerBandLowHz,
        dialogueRelativeLevelerBandHighHz,
        dialogueRelativeLevelerTargetGapDB,
        dialogueRelativeLevelerBoostRatio,
        dialogueRelativeLevelerMaxBoostDB,
        dialogueRelativeLevelerAttackMs,
        dialogueRelativeLevelerReleaseMs,
        dialogueRelativeLevelerProgramGateThresholdDB,
        dialogueRelativeLevelerVoiceGateSensitivity,
        dialogueRelativeLevelerVoiceGateMinConfidence,
        dialogueRelativeLevelerDetectorWindowMs,
        dialogueRelativeLevelerVoiceGateModulationCenterHz,
        dialogueRelativeLevelerVoiceGateModulationBandwidthHz,
        dialogueRelativeLevelerVoiceGateEnvelopeWindowMs,
        dialogueRelativeLevelerVoiceGateMeasurementWindowMs,
        dialogueRelativeLevelerVoiceGateConfidenceFloorIndex,
        dialogueRelativeLevelerVoiceGateConfidenceCeilingIndex,
        limiterCeilingDB,
        limiterAttackMs,
        limiterReleaseMs,
        limiterLookAheadMs,
        softClipperDriveDB,
        softClipperThresholdDB,
        softClipperKneeSmooth,
        softClipperAsymmetryTrimDB,
        automaticHeadroomMaxAttenuationDB,
        deHarshAmountDB,
        deHarshFrequencyHz,
        stereoWidenerLowWidth,
        stereoWidenerLowMidFrequencyHz,
        stereoWidenerMidWidth,
        stereoWidenerMidHighFrequencyHz,
        stereoWidenerHighWidth,
    ] + (0..<3).flatMap { multibandBand($0) }
}

// MARK: - Automatic makeup

/// E28 S4 (design 9): makeup that restores the level a compressor removes at a typical programme level.
/// Swift only: it sets the same `makeupGainDB` the engine already reads.
enum AutoMakeup {
    /// The programme level the makeup is matched at.
    static let referenceLevelDB = -18.0

    /// Static gain of a soft-knee compressor at `inputDB` (Giannoulis, Massberg and Reiss, JAES 60(6),
    /// 2012; the same curve as the core stage). Zero or negative.
    static func staticGainDB(inputDB: Double, thresholdDB: Double, ratio: Double, kneeDB: Double) -> Double {
        let slope = 1 / max(ratio, 1) - 1
        let over = inputDB - thresholdDB
        if kneeDB <= 0 {
            return over > 0 ? slope * over : 0
        }
        let half = kneeDB / 2
        if over >= half { return slope * over }
        if over > -half {
            let k = over + half
            return slope * k * k / (2 * kneeDB)
        }
        return 0
    }

    /// Makeup in dB: minus the static gain at the reference level, rounded to 0.1 dB and clamped.
    static func makeupDB(thresholdDB: Double, ratio: Double, kneeDB: Double, range: ClosedRange<Double>) -> Double {
        let gain = staticGainDB(inputDB: referenceLevelDB, thresholdDB: thresholdDB, ratio: ratio, kneeDB: kneeDB)
        let rounded = (-gain * 10).rounded() / 10 + 0
        return min(max(rounded, range.lowerBound), range.upperBound)
    }
}

extension DynamicsConfiguration {
    /// Sets the makeup of every compressor or band whose automatic makeup is on.
    mutating func applyAutoMakeup() {
        if compressor.autoMakeupGain == true {
            compressor.makeupGainDB = AutoMakeup.makeupDB(
                thresholdDB: compressor.thresholdDB, ratio: compressor.ratio,
                kneeDB: compressor.kneeWidthDB, range: CompressorConfiguration.makeupRange)
        }
        guard let bands = multibandCompressor.autoMakeupBands, !bands.isEmpty else { return }
        typealias M = MultibandCompressorConfiguration
        func makeup(_ t: Double, _ r: Double, _ k: Double) -> Double {
            AutoMakeup.makeupDB(thresholdDB: t, ratio: r, kneeDB: k, range: M.makeupRange)
        }
        if bands.contains(0) {
            multibandCompressor.lowMakeupGainDB = makeup(multibandCompressor.lowThresholdDB, multibandCompressor.lowRatio, multibandCompressor.lowKneeDB)
        }
        if bands.contains(1) {
            multibandCompressor.midMakeupGainDB = makeup(multibandCompressor.midThresholdDB, multibandCompressor.midRatio, multibandCompressor.midKneeDB)
        }
        if bands.contains(2) {
            multibandCompressor.highMakeupGainDB = makeup(multibandCompressor.highThresholdDB, multibandCompressor.highRatio, multibandCompressor.highKneeDB)
        }
    }
}
