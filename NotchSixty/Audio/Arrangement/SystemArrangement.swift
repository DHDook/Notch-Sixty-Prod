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

    init(
        outputs: SystemOutputs,
        layout: OutputProgramLayout = .stereo,
        bass: BassHandling = .fullRange,
        subwooferCount: Int = 0,
        subOutputs: [PhysicalOutputEndpoint] = [],
        speakers: [ArrangedSpeaker] = [],
        realisation: ArrangementRealisation = .profile
    ) {
        self.outputs = outputs
        self.layout = layout
        self.bass = bass
        self.subwooferCount = subwooferCount
        self.subOutputs = subOutputs
        self.speakers = speakers
        self.realisation = realisation
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
