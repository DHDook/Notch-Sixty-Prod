import Foundation

// E8 S3: the speaker routing model. Pure value types: no Core Audio, no engine access, safe off the realtime thread.
// The compiler (`SpeakerRoutingCompiler`) turns this into a `UnifiedGraphConfiguration`; validation lives in
// `SpeakerRoutingValidation.swift`. Nothing here is wired to the live session yet (E8 S4).

/// A graph lane that feeds a speaker: a program lane of the layout, or a bass-managed subwoofer lane.
struct RoutingSource: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case program, sub }
    var kind: Kind
    var index: Int

    static func program(_ index: Int) -> RoutingSource { RoutingSource(kind: .program, index: index) }
    static func sub(_ index: Int) -> RoutingSource { RoutingSource(kind: .sub, index: index) }
}

/// One driver EQ section (types 0 to 7 of the core PEQ).
struct RoutingEQSection: Codable, Equatable, Sendable {
    var type: Int
    var frequencyHz: Double
    var gainDB: Double
    var q: Double
}

/// A per-way limiter (a PROTECTION stage on that way's lane).
struct RoutingLimiter: Codable, Equatable, Sendable {
    var ceilingDB: Double = -1
    var attackMilliseconds: Double = 1
    var releaseMilliseconds: Double = 100
    var lookAheadMilliseconds: Double = 1
    var truePeakGuard = false
    var oversampling = 1
}

/// How a way's crossover is realised. Linear-phase FIR arrives with E8 S7; until then it compiles as its IIR equivalent
/// and validation says so.
enum RoutingRealisation: String, Codable, Sendable {
    case iir
    case fir
}

/// E8 B1: a way's measured near-field response (and an optional gated far-field capture above `mergeHz`), from which the
/// compiler designs the driver linearisation (minimum phase, or linear phase when the way is FIR). Optional and additive:
/// profiles saved without it decode unchanged, so the schema version stays.
struct RoutedWayLinearisation: Codable, Equatable, Sendable {
    var nearField: CrossoverCore.ResponseCapture
    var farField: CrossoverCore.ResponseCapture?
    var mergeHz: Double = 0
}

/// One driver: its physical output, its band-limiting filters and its per-driver processing.
struct RoutedWay: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var endpoint: PhysicalOutputEndpoint
    /// nil means no filter (full range on that edge).
    var highPass: CrossoverCore.FilterSpec?
    var lowPass: CrossoverCore.FilterSpec?
    var realisation: RoutingRealisation = .iir
    var eq: [RoutingEQSection] = []
    var trimDB: Double = 0
    var polarityInverted = false
    /// User delay for this driver, on top of the latency alignment the compiler adds.
    var delayMilliseconds: Double = 0
    var limiter: RoutingLimiter?
    /// nil means the driver is not linearised.
    var linearisation: RoutedWayLinearisation?
}

/// One speaker: a source and 1 to 8 ways.
struct RoutedSpeaker: Identifiable, Codable, Equatable, Sendable {
    static let maxWays = 8
    var id: UUID = UUID()
    var name: String = ""
    var source: RoutingSource
    var ways: [RoutedWay]
}

/// A raw matrix entry added on top of the ways, for sums and splits: `gain` x `source` goes to `output`. An output that
/// no way owns becomes a plain, unfiltered output lane.
struct RoutingMatrixEntry: Codable, Equatable, Sendable {
    var source: RoutingSource
    var output: PhysicalOutputEndpoint
    var gain: Double = 1
}

struct SpeakerRoutingConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    /// Largest graph: program + sub + output lanes (`N60_GRAPH_MAX_CHANNELS`).
    static let maxGraphLanes = 64

    var schemaVersion: Int
    var enabled: Bool
    var speakers: [RoutedSpeaker]
    var matrix: [RoutingMatrixEntry]

    init(
        schemaVersion: Int = SpeakerRoutingConfiguration.currentSchemaVersion,
        enabled: Bool = true,
        speakers: [RoutedSpeaker] = [],
        matrix: [RoutingMatrixEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.speakers = speakers
        self.matrix = matrix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version >= 1, version <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c, debugDescription: "unsupported routing schema \(version)")
        }
        schemaVersion = version
        enabled = try c.decode(Bool.self, forKey: .enabled)
        speakers = try c.decode([RoutedSpeaker].self, forKey: .speakers)
        matrix = try c.decodeIfPresent([RoutingMatrixEntry].self, forKey: .matrix) ?? []
    }

    var wayCount: Int { speakers.reduce(0) { $0 + $1.ways.count } }
}

/// The common cases. Each builds a configuration from physical endpoints; none reuses a legacy mode type.
enum SpeakerRoutingTemplate: Sendable {
    /// Each main lane drives one full-range output; each sub lane drives one output.
    case mainsPlusSub
    /// Each main is a low way plus a high way split at one corner (Linkwitz-Riley order 4).
    case twoWay
    /// Each main is low, mid and high ways split at two corners.
    case threeWay

    struct Main: Sendable {
        var lane: Int
        var name: String
        /// Low to high: one endpoint for mains + sub, two for 2-way, three for 3-way.
        var endpoints: [PhysicalOutputEndpoint]
    }

    var waysPerMain: Int {
        switch self {
        case .mainsPlusSub: return 1
        case .twoWay: return 2
        case .threeWay: return 3
        }
    }

    /// `crossoverHz` holds one corner per crossover (none, one or two), ascending. Returns nil on a mismatch.
    func build(
        mains: [Main],
        subs: [PhysicalOutputEndpoint] = [],
        crossoverHz: [Double] = []
    ) -> SpeakerRoutingConfiguration? {
        guard crossoverHz.count == waysPerMain - 1,
              mains.allSatisfy({ $0.endpoints.count == waysPerMain }) else { return nil }
        func spec(_ hz: Double) -> CrossoverCore.FilterSpec {
            CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: hz)
        }
        var speakers: [RoutedSpeaker] = []
        for main in mains {
            let ways: [RoutedWay] = main.endpoints.enumerated().map { index, endpoint in
                RoutedWay(
                    name: waysPerMain == 1 ? main.name : "\(main.name) \(Self.wayNames(waysPerMain)[index])",
                    endpoint: endpoint,
                    highPass: index == 0 ? nil : spec(crossoverHz[index - 1]),
                    lowPass: index == waysPerMain - 1 ? nil : spec(crossoverHz[index]))
            }
            speakers.append(RoutedSpeaker(name: main.name, source: .program(main.lane), ways: ways))
        }
        for (index, endpoint) in subs.enumerated() {
            speakers.append(RoutedSpeaker(
                name: "Sub \(index + 1)", source: .sub(index),
                ways: [RoutedWay(name: "Sub \(index + 1)", endpoint: endpoint)]))
        }
        return SpeakerRoutingConfiguration(speakers: speakers)
    }

    private static func wayNames(_ count: Int) -> [String] {
        count == 2 ? ["Low", "High"] : ["Low", "Mid", "High"]
    }
}

// E8 S4: the live plan for a routed session.
extension SpeakerRoutingConfiguration {
    /// Highest sub index used plus one (0 when no way or matrix entry reads a sub lane).
    var subwooferSourceCount: Int {
        let sources = speakers.map(\.source) + matrix.map(\.source)
        return (sources.filter { $0.kind == .sub }.map(\.index).max() ?? -1) + 1
    }

    /// Flattens `outputEndpoints` onto the selected output and any other devices they name: the selected output is
    /// the reference device and comes first, the rest follow in order of first use. Output lane `i` lands on the
    /// physical channel of the `i`-th endpoint. Throws `LiveNChannelTransportError.routingRefused` with the reason.
    func makeLivePlan(
        programLayout: OutputProgramLayout,
        availableDevices: [AudioOutputDevice],
        sampleRate: Double,
        selectedOutputUID: String,
        bassManagementEnabled: Bool
    ) throws -> LiveNChannelOutputRoutePlan {
        let endpoints = outputEndpoints
        guard !endpoints.isEmpty else { throw LiveNChannelTransportError.routingRefused("The routing has no outputs.") }
        guard sampleRate.isFinite, sampleRate > 0 else { throw OutputDeviceProfileError.invalidSampleRate(sampleRate) }
        var orderedUIDs = [selectedOutputUID]
        for endpoint in endpoints where !orderedUIDs.contains(endpoint.deviceUID) { orderedUIDs.append(endpoint.deviceUID) }
        guard endpoints.contains(where: { $0.deviceUID == selectedOutputUID }) else {
            throw OutputDeviceProfileError.selectedOutputNotRouted(selectedOutputUID)
        }
        let byUID = Dictionary(availableDevices.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        var offsets: [String: UInt32] = [:]
        var total: UInt64 = 0
        for uid in orderedUIDs {
            guard let device = byUID[uid] else { throw OutputDeviceProfileError.outputDeviceUnavailable(uid) }
            guard device.supports(sampleRate: sampleRate) else {
                throw OutputDeviceProfileError.sampleRateUnsupported(deviceUID: uid, sampleRate: sampleRate)
            }
            offsets[uid] = UInt32(total)
            total += UInt64(device.outputChannelCount)
            guard total <= UInt64(N60_LIVE_MAX_PHYSICAL_CHANNELS) else {
                throw OutputDeviceProfileError.physicalChannelCountOverflow
            }
        }
        var physical: [UInt32] = []
        for endpoint in endpoints {
            guard let device = byUID[endpoint.deviceUID], let offset = offsets[endpoint.deviceUID] else {
                throw OutputDeviceProfileError.outputDeviceUnavailable(endpoint.deviceUID)
            }
            guard endpoint.channelIndex < device.outputChannelCount else {
                throw OutputDeviceProfileError.outputChannelUnavailable(
                    deviceUID: endpoint.deviceUID, channelIndex: endpoint.channelIndex,
                    channelCount: device.outputChannelCount)
            }
            physical.append(offset + endpoint.channelIndex)
        }
        let subs = subwooferSourceCount
        let plan = LiveNChannelOutputRoutePlan(
            programLayout: programLayout,
            orderedDeviceUIDs: orderedUIDs,
            referenceDeviceUID: selectedOutputUID,
            physicalChannelCount: UInt32(total),
            programPhysicalChannels: [UInt32](repeating: UInt32.max, count: Int(N60_MAX_PROGRAM_CHANNELS)),
            subwooferPhysicalChannels: [UInt32](repeating: UInt32.max, count: Int(N60_MAX_SUBWOOFER_OUTPUTS)),
            subwooferCount: UInt32(subs),
            bassManagementEnabled: bassManagementEnabled,
            speakerCalibrations: [:],
            subwooferCalibrations: [PhysicalSubwooferCalibration?](repeating: nil, count: subs),
            routedOutputPhysicalChannels: physical
        )
        _ = try plan.makeRealtimeOutputMap()
        return plan
    }
}
