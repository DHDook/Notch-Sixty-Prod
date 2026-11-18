import Foundation

/// E33 S15 (G25, decisions 13 and 14): goal-based starting points for the Dynamics page. Each case is one pure function over a
/// `DynamicsConfiguration` with a written intent. Choosing one is an ordinary unsaved edit of the selected content preset: nothing
/// is stored as a mode, nothing is marked on the page, and the EQ, preamp and plug-in rack are never touched (they are not in a
/// `DynamicsConfiguration`). E30 night mode reuses `.lateNight` as its overlay (`E30`, owner decision 15).
///
/// A starting point owns the level controllers (loudness match, dialogue leveller, gain rider, automatic headroom, compressor,
/// multiband compressor, limiter) and sets all of them, so the result does not depend on what was on before. It leaves every
/// restoration, tone and routing processor alone (DC, infrasonic, mains, denoiser, de-esser, de-harsh, dynamic EQ, loudness
/// contour, expander, soft clipper, stereo mode and widener, pause gate, oversampling and per-output protection).
enum DynamicsStartingPoint: String, CaseIterable, Identifiable, Sendable {
    case lateNight
    case clearDialogue
    case evenVolume
    case protectSpeakers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lateNight: return "Late night"
        case .clearDialogue: return "Clear dialogue"
        case .evenVolume: return "Even volume"
        case .protectSpeakers: return "Protect speakers"
        }
    }

    /// What the recipe is for, in the words the menu shows under its name.
    var intent: String {
        switch self {
        case .lateNight: return "Quiet scenes stay audible and loud scenes are held down, so the loudness range is small and dialogue stays clear at low volume."
        case .clearDialogue: return "Speech is lifted against the rest of the programme, with a gentle compressor and a safe ceiling."
        case .evenVolume: return "Different programmes, ads and tracks play at about the same loudness, without squashing each one."
        case .protectSpeakers: return "A lower ceiling and automatic headroom so loud passages cannot overdrive the speakers. No level shaping otherwise."
        }
    }

    /// The Dynamics processors the recipe turns on, for the menu's help text and the tests.
    var processorsOn: [String] {
        switch self {
        case .lateNight: return ["Compressor", "Dialogue leveller", "Limiter"]
        case .clearDialogue: return ["Dialogue leveller", "Compressor", "Limiter"]
        case .evenVolume: return ["LUFS Match", "Compressor", "Limiter"]
        case .protectSpeakers: return ["Limiter", "Automatic headroom"]
        }
    }

    /// Returns `configuration` with this recipe applied to the level controllers.
    func applying(to configuration: DynamicsConfiguration) -> DynamicsConfiguration {
        var d = configuration
        d.loudnessMatch.enabled = false
        d.dialogueRelativeLeveler.enabled = false
        d.gainRider.enabled = false
        d.automaticHeadroom.enabled = false
        d.compressor.enabled = false
        d.multibandCompressor.enabled = false

        d.limiter.enabled = true
        d.limiter.attackMs = 0.1
        d.limiter.truePeakGuardEnabled = true
        // Auto Release is only honoured with the page flag; without it the stored fixed release stays in force.
        if LimiterAutoRelease.isAvailable { d.limiter.autoRelease = true }

        switch self {
        case .lateNight:
            setCompressor(&d, thresholdDB: -30, ratio: 3.0, kneeDB: 10, attackMs: 10, releaseMs: 250, makeupDB: 4)
            d.dialogueRelativeLeveler.enabled = true
            d.dialogueRelativeLeveler.targetGapDB = 10
            d.dialogueRelativeLeveler.boostRatio = 2.0
            d.dialogueRelativeLeveler.maxBoostDB = 8
            d.limiter.ceilingDB = -1.0
            d.limiter.lookAheadMs = 3.0
        case .clearDialogue:
            d.dialogueRelativeLeveler.enabled = true
            d.dialogueRelativeLeveler.targetGapDB = 12
            d.dialogueRelativeLeveler.boostRatio = 3.0
            d.dialogueRelativeLeveler.maxBoostDB = 10
            setCompressor(&d, thresholdDB: -24, ratio: 2.0, kneeDB: 8, attackMs: 20, releaseMs: 200, makeupDB: 1.5)
            d.limiter.ceilingDB = -1.0
            d.limiter.lookAheadMs = 2.0
        case .evenVolume:
            d.loudnessMatch.enabled = true
            d.loudnessMatch.targetLUFS = -16
            d.loudnessMatch.maxCorrectionDB = 12
            d.loudnessMatch.attackSeconds = 1
            d.loudnessMatch.releaseSeconds = 3
            setCompressor(&d, thresholdDB: -22, ratio: 1.8, kneeDB: 8, attackMs: 20, releaseMs: 200, makeupDB: 1)
            d.limiter.ceilingDB = -1.0
            d.limiter.lookAheadMs = 2.0
        case .protectSpeakers:
            d.automaticHeadroom.enabled = true
            d.automaticHeadroom.maxAttenuationDB = 12
            d.limiter.ceilingDB = -3.0
            d.limiter.lookAheadMs = 3.0
        }
        d.applyAutoMakeup()
        return d
    }

    private func setCompressor(
        _ d: inout DynamicsConfiguration, thresholdDB: Double, ratio: Double, kneeDB: Double,
        attackMs: Double, releaseMs: Double, makeupDB: Double
    ) {
        d.compressor = CompressorConfiguration()
        d.compressor.enabled = true
        d.compressor.thresholdDB = thresholdDB
        d.compressor.ratio = ratio
        d.compressor.kneeWidthDB = kneeDB
        d.compressor.attackMs = attackMs
        d.compressor.releaseMs = releaseMs
        d.compressor.makeupGainDB = makeupDB
    }
}

/// E33 S15 (G28): the level controllers that can work against each other when several are on.
enum DynamicsLevelStacking {
    /// Show the hint at three or more.
    static let hintThreshold = 3

    /// Names of the level controllers that are on, in chain order.
    static func activeNames(in d: DynamicsConfiguration) -> [String] {
        var names: [String] = []
        if d.loudnessMatch.enabled { names.append("LUFS Match") }
        if d.dialogueRelativeLeveler.enabled { names.append("Dialogue leveller") }
        if d.gainRider.enabled { names.append("Gain rider") }
        if d.automaticHeadroom.enabled { names.append("Automatic headroom") }
        if d.compressor.enabled { names.append("Compressor") }
        if d.multibandCompressor.enabled { names.append("Multiband compressor") }
        return names
    }

    static func hint(in d: DynamicsConfiguration) -> String? {
        let names = activeNames(in: d)
        guard names.count >= hintThreshold else { return nil }
        return "\(names.count) level controls are on together (\(names.joined(separator: ", "))). They each move the level, so they can work against one another. Turn one off if the sound pumps."
    }
}

/// E33 S15 (G27, display half): how the Limiter card says that output protection follows the programme limiter.
enum LimiterProtectionLine {
    enum Acting: Equatable { case none, limiter, protection, both }

    /// Which of the two is cutting level now. `limiterDB` is the programme limiter's gain reduction; `protectionDB` the largest
    /// reduction of any output's own limiter or hard limit.
    static func acting(limiterDB: Float, protectionDB: Float) -> Acting {
        let limiter = limiterDB.isFinite && limiterDB > 0.05
        let protection = protectionDB.isFinite && protectionDB > 0.05
        switch (limiter, protection) {
        case (false, false): return .none
        case (true, false): return .limiter
        case (false, true): return .protection
        case (true, true): return .both
        }
    }

    static func text(limiterOn: Bool, running: Bool, acting: Acting) -> String {
        var line = limiterOn
            ? "Output protection follows this limiter: it sees the signal after the limiter and catches anything that is left."
            : "The limiter is off, so output protection alone holds the outputs at its hard limit."
        guard running else { return line }
        switch acting {
        case .none: line += " Neither is reducing gain now."
        case .limiter: line += " Acting now: the limiter."
        case .protection: line += " Acting now: output protection."
        case .both: line += " Acting now: both."
        }
        return line
    }
}
