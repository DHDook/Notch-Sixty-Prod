import CryptoKit
import Foundation

// E26 S1: the bass path the anti-noise plays through, its fingerprint, and the plain record of a measurement through
// it. Pure value types on the control plane: no engine access, nothing realtime, nothing here arms or enables
// anything. Live ANC still comes only from the per-feature arm.

/// How a receiver (or a powered sub) handles bass downstream of the two feeds. The user declares it (owner decision of
/// 4 Nov 2026); the app cannot hear the difference, and the excursion caps depend on it.
enum ReceiverBass: Codable, Equatable, Sendable {
    static let defaultCrossoverHz = 80.0
    static let crossoverRangeHz = 40.0...200.0

    /// Not yet declared. Tonal and feed-forward live are refused (this refusal is always on, not flag-gated).
    case undeclared
    /// The receiver's sub pre-out adds no crossover or timing: the app's bass management is the only crossover.
    case openPreout
    /// The receiver's LFE out runs at the declared crossover; the combined path is measured through it.
    case calibratedLFE(crossoverHz: Double)

    var isDeclared: Bool { self != .undeclared }

    /// A calibrated crossover inside the supported range; any other value is treated as undeclared.
    var isValid: Bool {
        if case .calibratedLFE(let hz) = self { return hz.isFinite && Self.crossoverRangeHz.contains(hz) }
        return true
    }

    /// Plain-language setup note shown beside the declaration.
    static let setupNote = "For the best results with Notch Sixty, don't set a crossover in your receiver. "
        + "Set your speakers to Large and use the LFE or sub preout with no receiver crossover. "
        + "Notch Sixty then handles the bass split."

    private enum CodingKeys: String, CodingKey { case kind, crossoverHz }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "undeclared": self = .undeclared
        case "openPreout": self = .openPreout
        case "calibratedLFE":
            let hz = try c.decode(Double.self, forKey: .crossoverHz)
            // An out-of-range value cannot be trusted for the caps; it reads as not declared.
            self = Self.crossoverRangeHz.contains(hz) && hz.isFinite ? .calibratedLFE(crossoverHz: hz) : .undeclared
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown receiver bass declaration")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .undeclared: try c.encode("undeclared", forKey: .kind)
        case .openPreout: try c.encode("openPreout", forKey: .kind)
        case .calibratedLFE(let hz):
            try c.encode("calibratedLFE", forKey: .kind)
            try c.encode(hz, forKey: .crossoverHz)
        }
    }
}

/// What carries the bass between the feed the anti-noise joins and the room.
enum AncBassPath: Equatable, Sendable {
    /// Class B: full range, no bass management.
    case none
    /// Class C: mono bass on the pair. Not a sub for ANC: anti-noise bypasses `STEREO_CROSSOVER` and the drive frame
    /// already holds the recombined bass (pinned by `test_stereo_bass.cpp` and `harness_e26_anc_bypass.c`).
    case monoBassOnPair
    /// Classes D and E: a receiver or powered sub downstream of the two feeds.
    case downstream(ReceiverBass)
    /// The stereo-session bus splitter (app bass management on the two-channel session).
    case appSplitter(BassManagementConfiguration)
    /// Class A: a sub on its own output (S6).
    case subOutput

    /// Whether the path carries bass the anti-noise would have to cancel through a sub. Class C does not.
    var hasSubwooferForAnc: Bool {
        switch self {
        case .none, .monoBassOnPair: return false
        case .downstream, .appSplitter, .subOutput: return true
        }
    }

    var isDownstream: Bool { if case .downstream = self { return true } else { return false } }

    var receiverBass: ReceiverBass? { if case .downstream(let r) = self { return r } else { return nil } }

    fileprivate var tag: String {
        switch self {
        case .none: return "none"
        case .monoBassOnPair: return "monoBassOnPair"
        case .downstream: return "downstream"
        case .appSplitter: return "appSplitter"
        case .subOutput: return "subOutput"
        }
    }
}

/// Identifies the bass setup a measurement was made under. A mismatch makes the record stale.
struct AncBassPathFingerprint: Codable, Hashable, Sendable {
    var value: String
}

/// The resolved path and its fingerprint for the stored arrangement and the engine's bass management.
struct AncBassPathState: Equatable, Sendable {
    var path: AncBassPath
    var fingerprint: AncBassPathFingerprint

    static let staleMessage = "Your bass settings changed. Measure Quiet Zone again."

    /// Class from the arrangement when there is one (it decides which of the five paths applies); without an
    /// arrangement the two-channel session's own bass management decides between `.none` and `.appSplitter`.
    static func resolve(arrangement: SystemArrangement?, bassManagement: BassManagementConfiguration?) -> AncBassPathState {
        let path: AncBassPath
        if let arrangement {
            switch arrangement.arrangementClass {
            case .a: path = arrangement.bass == .dspToSubOutputs ? .subOutput : .none
            case .b: path = splitter(bassManagement)
            case .c: path = .monoBassOnPair
            case .d, .e: path = arrangement.hasDownstreamSubwoofer ? .downstream(arrangement.receiverBass) : .none
            }
        } else {
            path = splitter(bassManagement)
        }
        return AncBassPathState(
            path: path, fingerprint: fingerprint(path: path, arrangement: arrangement, splitter: bassManagement))
    }

    private static func splitter(_ bass: BassManagementConfiguration?) -> AncBassPath {
        if let bass, bass.enabled { return .appSplitter(bass) }
        return .none
    }

    /// SHA-256 over a canonical JSON of the path tag, the splitter fields (when the path is the app splitter) and the
    /// whole arrangement (its outputs, layout, bass, subs, feed calibration, mono-bass filter and receiver
    /// declaration), so every splitter field and every arrangement edit changes it.
    ///
    /// E26 S7c: the direct-output path (class A) also hashes the splitter configuration (the bass the DSP sends to the
    /// sub output) and a version tag, so a record from before S7c, or measured under other bass settings, reads stale.
    static func fingerprint(
        path: AncBassPath, arrangement: SystemArrangement?, splitter: BassManagementConfiguration? = nil
    ) -> AncBassPathFingerprint {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data(path.tag.utf8)
        if case .appSplitter(let bass) = path, let json = try? encoder.encode(bass) { data.append(json) }
        if let arrangement, let json = try? encoder.encode(arrangement) { data.append(json) }
        if case .subOutput = path {
            data.append(Data("|subOutput-v2".utf8))
            if let splitter, let json = try? encoder.encode(splitter) { data.append(json) }
        }
        let digest = SHA256.hash(data: data)
        return AncBassPathFingerprint(value: digest.map { String(format: "%02x", $0) }.joined())
    }

    enum Freshness: Equatable, Sendable {
        case fresh
        case stale(String)
    }

    /// Whether a measurement stamped with `stored` still describes the current bass setup. A measurement with no stamp
    /// (made before E26) reads as `.none`: fresh where no bass path is in play, stale where one is.
    func freshness(of stored: AncBassPathFingerprint?) -> Freshness {
        guard let stored else {
            switch path {
            case .none, .monoBassOnPair: return .fresh
            case .downstream, .appSplitter, .subOutput: return .stale(Self.staleMessage)
            }
        }
        return stored == fingerprint ? .fresh : .stale(Self.staleMessage)
    }
}

/// The plain, documented form of a measurement through the combined path. A later shared room model can absorb it
/// unchanged (that model stays parked). Offline value; nothing here reaches the engine.
struct CombinedAncPathRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    /// The band the record covers, hertz.
    static let bandHz = 15.0...500.0

    enum Source: String, Codable, Sendable {
        /// The pre-split left or right feed.
        case feedLeft, feedRight
        /// The sub lane of a sub on its own output (class A).
        case subLane
        /// E26 S7c: one hardware output on its own, measured at the reference microphone, with the splitter's bus
        /// content for that output (`outputChannel` and `outputRole` say which).
        case outputLeakage
    }

    /// E26 S7c: the output roles a leakage record can name; any number of outputs may be stored.
    enum OutputRole: String, Codable, Sendable { case leftMain, rightMain, sub }

    enum Destination: String, Codable, Sendable {
        case seatMicrophone, referenceMicrophone
    }

    var schemaVersion: Int = CombinedAncPathRecord.currentSchemaVersion
    var source: Source
    var destination: Destination
    var bandLowHz: Double = CombinedAncPathRecord.bandHz.lowerBound
    var bandHighHz: Double = CombinedAncPathRecord.bandHz.upperBound
    /// Length of the measurement window, seconds.
    var windowSeconds: Double
    var sampleRate: Double
    var fingerprint: AncBassPathFingerprint
    var impulseResponse: [Float]
    /// E26 S7c (schema 2): which hardware output a `.outputLeakage` record belongs to; nil for the older sources.
    var outputChannel: Int?
    var outputRole: OutputRole?

    var isValid: Bool {
        schemaVersion >= 1 && schemaVersion <= Self.currentSchemaVersion
            && bandLowHz.isFinite && bandHighHz.isFinite && bandLowHz >= Self.bandHz.lowerBound
            && bandHighHz <= Self.bandHz.upperBound && bandLowHz < bandHighHz
            && windowSeconds.isFinite && windowSeconds > 0 && sampleRate.isFinite && sampleRate > 0
            && (source != .outputLeakage || (schemaVersion >= 2 && (outputChannel ?? -1) >= 0 && outputRole != nil))
            && !impulseResponse.isEmpty && impulseResponse.allSatisfy(\.isFinite)
            && Double(impulseResponse.count) / sampleRate <= windowSeconds + 1.0 / sampleRate
    }

    init(
        source: Source, destination: Destination, windowSeconds: Double, sampleRate: Double,
        fingerprint: AncBassPathFingerprint, impulseResponse: [Float],
        outputChannel: Int? = nil, outputRole: OutputRole? = nil
    ) {
        self.outputChannel = outputChannel
        self.outputRole = outputRole
        self.source = source
        self.destination = destination
        self.windowSeconds = windowSeconds
        self.sampleRate = sampleRate
        self.fingerprint = fingerprint
        self.impulseResponse = impulseResponse
    }

    /// Decoding rejects a newer schema and any invalid record, so a damaged file reads as no record.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        source = try c.decode(Source.self, forKey: .source)
        destination = try c.decode(Destination.self, forKey: .destination)
        bandLowHz = try c.decode(Double.self, forKey: .bandLowHz)
        bandHighHz = try c.decode(Double.self, forKey: .bandHighHz)
        windowSeconds = try c.decode(Double.self, forKey: .windowSeconds)
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        fingerprint = try c.decode(AncBassPathFingerprint.self, forKey: .fingerprint)
        impulseResponse = try c.decode([Float].self, forKey: .impulseResponse)
        outputChannel = try c.decodeIfPresent(Int.self, forKey: .outputChannel)
        outputRole = try c.decodeIfPresent(OutputRole.self, forKey: .outputRole)
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c, debugDescription: "invalid combined ANC path record")
        }
    }
}
