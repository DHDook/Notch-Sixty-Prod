import Foundation

// E25 S1: the system arrangement model. Output channels (what the DAC exposes) and the speaker arrangement (what the
// listener has) are separate concepts, so a 5.1 system on one two-channel DAC is expressible. Pure value types: no Core
// Audio, no engine access, safe off the realtime thread, and rate-free (delays are never stored here).
// Nothing reads the stored arrangement unless `e25.outputs-and-speakers` is on; S3 wires the wizard.

/// The device the arrangement plays through, and how many of its output channels are used.
struct SystemOutputs: Codable, Equatable, Sendable {
    var deviceUID: String
    /// What the device reports (0 when unknown). Editable down by the user, never up.
    var detectedChannelCount: Int
    var channelsInUse: Int
}

/// How low frequencies reach the subwoofer or the mains.
enum BassHandling: String, Codable, CaseIterable, Sendable {
    /// No bass management: every speaker plays full range.
    case fullRange
    /// DSP crossover to one to eight physical sub outputs (needs a third output or more).
    case dspToSubOutputs
    /// Mono bass on the pair: the low band of L+R is shared by both mains. Runs on the stereo session.
    case dspMonoToMains
    /// A receiver sets the sub's level, delay and crossover; the app sees only the feeds.
    case downstreamReceiver
    /// A powered sub's own crossover sits downstream of the two feeds.
    case downstreamSubCrossover

    var isDownstream: Bool { self == .downstreamReceiver || self == .downstreamSubCrossover }
}

/// Where a speaker's signal comes from.
enum SpeakerFeedMapping: Codable, Equatable, Sendable {
    /// One physical output per speaker.
    case direct(PhysicalOutputEndpoint)
    /// The speaker is driven by a receiver from these feeds (zero-based output channels of the device).
    case viaDownstream([Int])

    private enum CodingKeys: String, CodingKey { case kind, endpoint, feeds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "direct":
            self = .direct(try c.decode(PhysicalOutputEndpoint.self, forKey: .endpoint))
        case "viaDownstream":
            self = .viaDownstream(try c.decode([Int].self, forKey: .feeds))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown speaker feed mapping")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .direct(let endpoint):
            try c.encode("direct", forKey: .kind)
            try c.encode(endpoint, forKey: .endpoint)
        case .viaDownstream(let feeds):
            try c.encode("viaDownstream", forKey: .kind)
            try c.encode(feeds, forKey: .feeds)
        }
    }
}

struct ArrangedSpeaker: Codable, Equatable, Sendable {
    var role: OutputProgramRole
    var feed: SpeakerFeedMapping
}

/// Which existing configuration realises a multi-output arrangement.
enum ArrangementRealisation: String, Codable, Sendable {
    /// An enabled Output Device Profile (the default, and what the wizard writes).
    case profile
    /// A speaker routing configuration (migrated profiles that already use one).
    case routing
}

struct SystemArrangement: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maxSubwoofers = 8

    var schemaVersion: Int = SystemArrangement.currentSchemaVersion
    var outputs: SystemOutputs
    var layout: OutputProgramLayout
    var bass: BassHandling
    /// Physical sub count, including subs a receiver drives (downstream). 0 to 8.
    var subwooferCount: Int
    /// Physical outputs fed by the DSP, one per sub. Non-empty only for `.dspToSubOutputs`.
    var subOutputs: [PhysicalOutputEndpoint] = []
    var speakers: [ArrangedSpeaker]
    var realisation: ArrangementRealisation = .profile
    /// E25 S2: the mono-bass filter and per-speaker feed calibration of the two-channel session. nil keeps the
    /// standard Linkwitz-Riley 24 crossover and an identity feed.
    var stereoAlignment: StereoBassAlignment?
    /// E25 S7: fold a wider program (5.1, 7.1) to the two feeds. nil keeps today's behaviour (the player folds).
    var foldDown: ProgramFoldDown?

    init(
        outputs: SystemOutputs,
        layout: OutputProgramLayout = .stereo,
        bass: BassHandling = .fullRange,
        subwooferCount: Int = 0,
        subOutputs: [PhysicalOutputEndpoint] = [],
        speakers: [ArrangedSpeaker] = [],
        realisation: ArrangementRealisation = .profile,
        stereoAlignment: StereoBassAlignment? = nil,
        foldDown: ProgramFoldDown? = nil
    ) {
        self.outputs = outputs
        self.layout = layout
        self.bass = bass
        self.subwooferCount = subwooferCount
        self.subOutputs = subOutputs
        self.speakers = speakers
        self.realisation = realisation
        self.stereoAlignment = stereoAlignment
        self.foldDown = foldDown
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version >= 1, version <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c, debugDescription: "unsupported arrangement schema \(version)")
        }
        schemaVersion = version
        outputs = try c.decode(SystemOutputs.self, forKey: .outputs)
        layout = try c.decode(OutputProgramLayout.self, forKey: .layout)
        bass = try c.decode(BassHandling.self, forKey: .bass)
        subwooferCount = try c.decode(Int.self, forKey: .subwooferCount)
        subOutputs = try c.decodeIfPresent([PhysicalOutputEndpoint].self, forKey: .subOutputs) ?? []
        speakers = try c.decode([ArrangedSpeaker].self, forKey: .speakers)
        realisation = try c.decodeIfPresent(ArrangementRealisation.self, forKey: .realisation) ?? .profile
        stereoAlignment = try c.decodeIfPresent(StereoBassAlignment.self, forKey: .stereoAlignment)
        foldDown = try c.decodeIfPresent(ProgramFoldDown.self, forKey: .foldDown)
    }

    /// The five classes the capability matrix and the wizard speak in.
    enum Class: String, CaseIterable, Sendable {
        /// Direct multi-output: one output per speaker.
        case a
        /// Two channels, full range.
        case b
        /// Two channels, mono bass on the pair.
        case c
        /// Two channels plus downstream bass (a powered sub's crossover, or a receiver at 2.1).
        case d
        /// Two channels into a receiver driving a 5.x or 7.x arrangement.
        case e
    }

    var arrangementClass: Class {
        if outputs.channelsInUse >= 3 { return .a }
        switch bass {
        case .dspMonoToMains: return .c
        case .downstreamReceiver, .downstreamSubCrossover:
            return layout.roles.filter { $0 != .lowFrequencyEffects }.count > 2 ? .e : .d
        case .fullRange, .dspToSubOutputs: return .b
        }
    }
}
// rules that turn them into core parameters; the stereo translator and the arrangement compiler consume them.

/// The crossover used when the DSP sends mono bass to the pair (`BassHandling.dspMonoToMains`). Any family at
/// 12, 24, 36 or 48 dB per octave. The default (Linkwitz-Riley 24) is what the legacy kernel runs.
struct MonoBassFilter: Codable, Equatable, Sendable {
    enum Family: String, Codable, CaseIterable, Sendable {
        case butterworth, bessel, linkwitzRiley

        /// The core's `N60_GRAPH_FILTER_*` value.
        var coreValue: Float {
            switch self {
            case .butterworth: return 0
            case .bessel: return 1
            case .linkwitzRiley: return 2
            }
        }
    }

    static let slopes = [12, 24, 36, 48]
    static let standard = MonoBassFilter()

    var family: Family = .linkwitzRiley
    var slopeDBPerOctave: Int = 24

    var order: Int { slopeDBPerOctave / 6 }
    var isValid: Bool { Self.slopes.contains(slopeDBPerOctave) }

    /// The legacy kernel runs Linkwitz-Riley 24 and 48 only.
    var legacyKernelCanRun: Bool { family == .linkwitzRiley && (slopeDBPerOctave == 24 || slopeDBPerOctave == 48) }

    /// Linkwitz-Riley orders 2 and 6 (12 and 36 dB per octave) sum flat only when the low-pass path is inverted.
    /// Butterworth and Bessel are not flat at the corner by design, and need no correction.
    var sumNeedsInversion: Bool { family == .linkwitzRiley && order % 4 == 2 }

    /// The `STEREO_CROSSOVER` trailer `[hp family, hp order, lp family, lp order]` (ABI v19).
    var trailer: [Float] { [family.coreValue, Float(order), family.coreValue, Float(order)] }
}

/// Trim, absolute delay and polarity for one speaker's feed, applied after all other processing.
struct SpeakerFeedCalibration: Codable, Equatable, Sendable {
    static let trimRangeDB = -20.0...20.0
    static let delayRangeMs = 0.0...50.0

    var trimDB: Double = 0
    var delayMs: Double = 0
    var polarityInverted = false

    var isIdentity: Bool { trimDB == 0 && delayMs == 0 && !polarityInverted }
    var isValid: Bool {
        trimDB.isFinite && delayMs.isFinite && Self.trimRangeDB.contains(trimDB) && Self.delayRangeMs.contains(delayMs)
    }
    var linearGain: Float { Float(pow(10.0, trimDB / 20.0)) }
    func delayFrames(sampleRate: Double) -> Double { delayMs * 0.001 * sampleRate }
}

/// Everything E25 S2 adds to the stereo session. `nil` fields leave the session exactly as before.
struct StereoBassAlignment: Codable, Equatable, Sendable {
    var monoBassFilter: MonoBassFilter?
    var left = SpeakerFeedCalibration()
    var right = SpeakerFeedCalibration()

    var isStandard: Bool {
        (monoBassFilter ?? .standard).legacyKernelCanRun && left.isIdentity && right.isIdentity
    }

    /// Why this cannot run, or nil. Checked before the alignment reaches the engine.
    var issue: StereoBassAlignmentIssue? {
        if let monoBassFilter, !monoBassFilter.isValid { return .invalidSlope(monoBassFilter.slopeDBPerOctave) }
        if !left.isValid || !right.isValid { return .calibrationOutOfRange }
        return nil
    }

    /// The legacy kernel (`e6.legacy-kernel`) cannot run this alignment; nil when it can.
    var legacyKernelRefusal: StereoBassAlignmentIssue? {
        if let monoBassFilter, !monoBassFilter.legacyKernelCanRun { return .legacyKernelFilter }
        if !left.isIdentity || !right.isIdentity { return .legacyKernelCalibration }
        return nil
    }
}

enum StereoBassAlignmentIssue: Error, Equatable, Sendable, LocalizedError {
    case invalidSlope(Int)
    case calibrationOutOfRange
    case legacyKernelFilter
    case legacyKernelCalibration

    var errorDescription: String? {
        switch self {
        case .invalidSlope(let slope):
            return "A mono-bass slope of \(slope) dB per octave is not supported; use 12, 24, 36 or 48."
        case .calibrationOutOfRange:
            return "Speaker trim must be within 20 dB and delay within 0 to 50 ms."
        case .legacyKernelFilter:
            return "This mono-bass filter needs the unified graph; the legacy kernel (e6.legacy-kernel) runs Linkwitz-Riley 24 and 48 dB per octave only."
        case .legacyKernelCalibration:
            return "Speaker trim, delay and polarity need the unified graph; the legacy kernel (e6.legacy-kernel) does not apply them."
        }
    }
}
