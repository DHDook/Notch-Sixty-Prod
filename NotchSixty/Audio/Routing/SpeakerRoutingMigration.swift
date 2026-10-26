import Foundation

// E8 S5: migrates the legacy physical crossover modes (mains + sub, bi-amp, tri-amp) and their routes and per-bus driver
// processing to a `SpeakerRoutingConfiguration`. Pure and deterministic: the same legacy inputs always give the same
// result, including the identifiers (they derive from the route identifiers). The legacy fields stay readable and
// written until E8 S10, so the flag-off path is untouched.
//
// Mapping, written against the legacy bridge splitter (`process_speaker_bus_splitter`):
// - LR24 is Linkwitz-Riley order 4 and LR48 order 8, each with its own corner.
// - Mains + sub: each main is high-passed at the lower corner; the sub reads (left + right) / 2 through a low-pass, then
//   the optional all-pass, the sub gain and the sub polarity. The graph sums program 0 and a matrix entry for program 1
//   into the sub output and the way trim carries the -6.02 dB of the mono mix.
// - Bi-amp: low is the low-pass and high the high-pass at the lower corner.
// - Tri-amp: low = LP1 (LP2 + HP2), which is LP1 plus an all-pass at the upper corner; mid = HP1 LP2; high = HP1 HP2.
//   The all-pass and the second high-pass are exact biquad cascades in the way's EQ.
// - Driver EQ, trim, polarity, delay and limiter carry over per way. The legacy limiter has an instant attack and a
//   50 ms release; the graph limiter takes its fastest attack and no look-ahead, so no latency is added.

enum SpeakerRoutingMigration {
    /// Why a legacy configuration was left unmigrated.
    enum Refusal: Equatable, Sendable {
        /// Routing or physical crossover mode is off, so there is nothing to migrate.
        case notApplicable
        /// The legacy configuration has no equivalent in the routing model; the text says why.
        case unsupported(String)
    }

    struct Result: Equatable, Sendable {
        var routing: SpeakerRoutingConfiguration?
        var refusal: Refusal?
    }

    /// The linear gain of 0.5 (the legacy mono sub mix) in dB.
    static let monoMixTrimDB = -6.020599913279624

    static func migrate(
        routing: MultiOutputRoutingConfiguration?,
        bassManagement: BassManagementConfiguration,
        driverProcessing: SpeakerDriverProcessingConfiguration?
    ) -> Result {
        guard let routing, routing.enabled, bassManagement.enabled,
              let mode = bassManagement.physicalOutputMode else {
            return Result(routing: nil, refusal: .notApplicable)
        }
        let routes = routing.enabledRoutes.filter { mode.supports(bus: $0.bus) }
        guard !routes.isEmpty else { return Result(routing: nil, refusal: .notApplicable) }

        let lower = bassManagement.frequencyHz
        let upper = bassManagement.upperFrequencyHz ?? max(lower + 1.0, lower * 2.0)
        let lowerTopology = bassManagement.topology
        let upperTopology = bassManagement.upperTopology ?? bassManagement.topology

        var speakers: [RoutedSpeaker] = []
        var matrix: [RoutingMatrixEntry] = []
        // Fixed speaker order: left drivers low to high, right drivers, the two full-range buses, the sub.
        let groups: [(name: String, source: Int, buses: [SpeakerOutputBus])] = [
            ("Left", 0, [.leftLow, .leftMid, .leftHigh]),
            ("Right", 1, [.rightLow, .rightMid, .rightHigh]),
            ("Left Full Range", 0, [.leftFullRange]),
            ("Right Full Range", 1, [.rightFullRange]),
            ("Sub", 0, [.subMono]),
        ]
        for group in groups {
            var ways: [RoutedWay] = []
            for bus in group.buses {
                guard let route = routes.first(where: { $0.bus == bus }) else { continue }
                guard routes.filter({ $0.bus == bus }).count == 1 else {
                    return Result(routing: nil, refusal: .unsupported("\(bus.displayName) has more than one route"))
                }
                var way = RoutedWay(
                    id: route.id, name: route.name.isEmpty ? bus.displayName : route.name,
                    endpoint: route.destination)
                applyBand(
                    to: &way, bus: bus, mode: mode, lower: lower, lowerTopology: lowerTopology,
                    upper: upper, upperTopology: upperTopology, bass: bassManagement)
                if let refusal = applyDriver(
                    to: &way, configuration: driverProcessing?.configuration(for: bus), bus: bus) {
                    return Result(routing: nil, refusal: refusal)
                }
                if bus == .subMono {
                    matrix.append(RoutingMatrixEntry(source: .program(1), output: route.destination, gain: 1))
                }
                ways.append(way)
            }
            guard let first = ways.first else { continue }
            speakers.append(RoutedSpeaker(
                id: Self.derivedID(from: first.id), name: group.name, source: .program(group.source), ways: ways))
        }
        let migrated = SpeakerRoutingConfiguration(enabled: true, speakers: speakers, matrix: matrix)
        // Structural check only: the corners are checked against the real rate when the graph is compiled.
        let context = SpeakerRoutingContext(programLanes: 2, subwoofers: 0, sampleRate: 384_000)
        let validation = migrated.validate(in: context)
        guard validation.isValid else {
            return Result(routing: nil, refusal: .unsupported("routing model rejects it: \(validation.errors)"))
        }
        return Result(routing: migrated, refusal: nil)
    }

    // MARK: Bands

    private static func filter(_ topology: CrossoverTopology, _ hz: Double) -> CrossoverCore.FilterSpec {
        CrossoverCore.FilterSpec(family: .linkwitzRiley, order: topology == .linkwitzRiley24 ? 4 : 8, cornerHz: hz)
    }

    /// Q of each cascaded biquad of the legacy topology (one Butterworth chain per leg of a Linkwitz-Riley filter).
    private static func sectionQs(_ topology: CrossoverTopology) -> [Double] {
        switch topology {
        case .linkwitzRiley24: return [0.7071067811865476, 0.7071067811865476]
        case .linkwitzRiley48: return [0.5411961001461970, 1.3065629648763766, 0.5411961001461970, 1.3065629648763766]
        }
    }

    private static func applyBand(
        to way: inout RoutedWay, bus: SpeakerOutputBus, mode: SpeakerCrossoverMode,
        lower: Double, lowerTopology: CrossoverTopology, upper: Double, upperTopology: CrossoverTopology,
        bass: BassManagementConfiguration
    ) {
        switch (mode, bus) {
        case (_, .leftFullRange), (_, .rightFullRange):
            break
        case (.mainsSub, .leftHigh), (.mainsSub, .rightHigh), (.biAmp, .leftHigh), (.biAmp, .rightHigh),
             (.triAmp, .leftMid), (.triAmp, .rightMid), (.triAmp, .leftHigh), (.triAmp, .rightHigh):
            way.highPass = filter(lowerTopology, lower)
            if mode == .triAmp {
                if bus == .leftMid || bus == .rightMid {
                    way.lowPass = filter(upperTopology, upper)
                } else {
                    // HP1 HP2: the second high-pass is its exact biquad cascade.
                    way.eq += sectionQs(upperTopology).map { RoutingEQSection(type: 4, frequencyHz: upper, gainDB: 0, q: $0) }
                }
            }
        case (.biAmp, .leftLow), (.biAmp, .rightLow), (.triAmp, .leftLow), (.triAmp, .rightLow):
            way.lowPass = filter(lowerTopology, lower)
            if mode == .triAmp {
                // LP1 (LP2 + HP2) = LP1 times an all-pass at the upper corner.
                let qs = Array(sectionQs(upperTopology).prefix(upperTopology == .linkwitzRiley24 ? 1 : 2))
                way.eq += qs.map { RoutingEQSection(type: 6, frequencyHz: upper, gainDB: 0, q: $0) }
            }
        case (.mainsSub, .subMono):
            way.lowPass = filter(lowerTopology, lower)
            if bass.subPhaseAlignmentEnabled {
                way.eq.append(RoutingEQSection(
                    type: 6, frequencyHz: bass.subPhaseAlignmentFrequencyHz, gainDB: 0, q: bass.subPhaseAlignmentQ))
            }
            way.trimDB += bass.subGainDB + monoMixTrimDB
            way.polarityInverted = bass.subPolarityInverted
        default:
            break
        }
    }

    // MARK: Driver processing

    private static func typeCode(_ type: EQFilterType) -> Int? {
        switch type {
        case .peaking: return 0
        case .lowShelf: return 1
        case .highShelf: return 2
        case .notch: return 5
        case .allPass: return 6
        default: return nil
        }
    }

    private static func applyDriver(
        to way: inout RoutedWay, configuration: SpeakerDriverBusProcessingConfiguration?, bus: SpeakerOutputBus
    ) -> Refusal? {
        guard let configuration, configuration.enabled else { return nil }
        for band in configuration.eqBands where band.enabled {
            guard let code = typeCode(band.type) else {
                return .unsupported("\(bus.displayName) driver EQ shape \(band.type.rawValue)")
            }
            way.eq.append(RoutingEQSection(type: code, frequencyHz: band.frequencyHz, gainDB: band.gainDB, q: band.q))
        }
        way.trimDB += configuration.trimDB
        way.polarityInverted = way.polarityInverted != configuration.polarityInverted
        way.delayMilliseconds = configuration.delayMilliseconds
        if configuration.limiterEnabled {
            // The routing limiter ceiling is -20...0 dBFS; a lower legacy threshold would be loosened, so refuse.
            guard (-20.0...0.0).contains(configuration.limiterThresholdDBFS) else {
                return .unsupported("\(bus.displayName) limiter threshold \(configuration.limiterThresholdDBFS) dBFS")
            }
            way.limiter = RoutingLimiter(
                ceilingDB: configuration.limiterThresholdDBFS, attackMilliseconds: 0.1,
                releaseMilliseconds: 50, lookAheadMilliseconds: 0, truePeakGuard: false, oversampling: 1)
        }
        return nil
    }

    /// A stable identifier for a speaker: its first way's identifier with the last byte flipped.
    private static func derivedID(from id: UUID) -> UUID {
        var bytes = id.uuid
        bytes.15 ^= 0xA5
        return UUID(uuid: bytes)
    }
}

extension PlaybackSystemState {
    /// The state with `speakerRouting` filled from the legacy physical crossover, when the flag is on and none is stored.
    /// A stored routing is never replaced, so the result is idempotent. Legacy fields are left as they are.
    func migratingSpeakerRouting(enabled: Bool) -> PlaybackSystemState {
        guard enabled, speakerRouting == nil else { return self }
        let result = SpeakerRoutingMigration.migrate(
            routing: outputRouting, bassManagement: bassManagement, driverProcessing: speakerDriverProcessing)
        guard let routing = result.routing else { return self }
        var copy = self
        copy.speakerRouting = routing
        return copy
    }
}
