import Foundation

/// What the routing is validated against: the program layout's lanes, the bass-managed subwoofers and the device rate.
struct SpeakerRoutingContext: Equatable, Sendable {
    var programLanes: Int
    var subwoofers: Int
    var sampleRate: Double
}

enum SpeakerRoutingError: Equatable, Sendable {
    case noSpeakers
    case speakerWayCount(speaker: String, count: Int)
    case sourceOutOfRange(RoutingSource)
    /// The same physical output is claimed by two ways.
    case endpointReused(PhysicalOutputEndpoint)
    case channelCap(lanes: Int)
    case invalidFilter(way: String, reason: String)
    case invalidTrim(way: String)
    case invalidDelay(way: String)
    case invalidEQ(way: String)
    case invalidLimiter(way: String)
    case matrixGainOutOfRange
    /// A destination would need more than the 8 entries a ROUTE destination holds.
    case tooManyEntries(PhysicalOutputEndpoint)
    case invalidSampleRate
}

enum SpeakerRoutingWarning: Equatable, Sendable {
    /// Adjacent ways of one speaker leave a band that neither covers.
    case bandGap(speaker: String, lowerHz: Double, upperHz: Double)
    /// Adjacent ways overlap by more than the corners' tolerance.
    case bandOverlap(speaker: String, lowerHz: Double, upperHz: Double)
    /// Linear-phase ways compile as their IIR equivalent until E8 S7.
    case firRealisedAsIIR(way: String)
    case unroutedSource(RoutingSource)
}

struct SpeakerRoutingValidation: Equatable, Sendable {
    var errors: [SpeakerRoutingError] = []
    var warnings: [SpeakerRoutingWarning] = []
    var isValid: Bool { errors.isEmpty }
}

extension SpeakerRoutingConfiguration {
    /// The output lanes in order: every way's endpoint, then each matrix-only endpoint at first appearance.
    var outputEndpoints: [PhysicalOutputEndpoint] {
        var result: [PhysicalOutputEndpoint] = []
        for way in speakers.flatMap(\.ways) where !result.contains(way.endpoint) { result.append(way.endpoint) }
        for entry in matrix where !result.contains(entry.output) { result.append(entry.output) }
        return result
    }

    func validate(in context: SpeakerRoutingContext) -> SpeakerRoutingValidation {
        var v = SpeakerRoutingValidation()
        guard context.sampleRate.isFinite, context.sampleRate >= 8_000 else {
            v.errors.append(.invalidSampleRate)
            return v
        }
        if speakers.isEmpty { v.errors.append(.noSpeakers) }
        func label(_ speaker: RoutedSpeaker) -> String { speaker.name.isEmpty ? speaker.id.uuidString : speaker.name }
        func label(_ way: RoutedWay) -> String { way.name.isEmpty ? way.id.uuidString : way.name }
        func sourceOK(_ s: RoutingSource) -> Bool {
            s.index >= 0 && s.index < (s.kind == .program ? context.programLanes : context.subwoofers)
        }

        var seen: Set<PhysicalOutputEndpoint> = []
        var reported: Set<PhysicalOutputEndpoint> = []
        var used: Set<RoutingSource> = []
        let nyquistLimit = 0.49 * context.sampleRate
        for speaker in speakers {
            if !sourceOK(speaker.source) { v.errors.append(.sourceOutOfRange(speaker.source)) }
            used.insert(speaker.source)
            if !(1...RoutedSpeaker.maxWays).contains(speaker.ways.count) {
                v.errors.append(.speakerWayCount(speaker: label(speaker), count: speaker.ways.count))
            }
            for way in speaker.ways {
                let name = label(way)
                if !seen.insert(way.endpoint).inserted, reported.insert(way.endpoint).inserted {
                    v.errors.append(.endpointReused(way.endpoint))
                }
                for spec in [way.highPass, way.lowPass].compactMap({ $0 }) {
                    if !spec.family.orders.contains(spec.order) {
                        v.errors.append(.invalidFilter(way: name, reason: "order"))
                    } else if !spec.cornerHz.isFinite || spec.cornerHz < 1 || spec.cornerHz > nyquistLimit {
                        v.errors.append(.invalidFilter(way: name, reason: "corner"))
                    }
                }
                if !(-60.0...24.0).contains(way.trimDB) { v.errors.append(.invalidTrim(way: name)) }
                if !way.delayMilliseconds.isFinite || way.delayMilliseconds < 0 { v.errors.append(.invalidDelay(way: name)) }
                if way.eq.count > Int(N60_PEQ_MAX_SECTIONS)
                    || way.eq.contains(where: { !(0...7).contains($0.type) || !(-24.0...24.0).contains($0.gainDB) }) {
                    v.errors.append(.invalidEQ(way: name))
                }
                if let l = way.limiter,
                   !(-20.0...0.0).contains(l.ceilingDB) || ![1, 2, 4].contains(l.oversampling)
                    || !(0.1...50.0).contains(l.attackMilliseconds) || !(5.0...500.0).contains(l.releaseMilliseconds)
                    || !(0.0...20.0).contains(l.lookAheadMilliseconds) {
                    v.errors.append(.invalidLimiter(way: name))
                }
            }
            v.warnings += Self.bandWarnings(speaker: label(speaker), ways: speaker.ways)
        }
        var entriesPerOutput: [PhysicalOutputEndpoint: Int] = [:]
        for speaker in speakers { for way in speaker.ways { entriesPerOutput[way.endpoint, default: 0] += 1 } }
        for entry in matrix {
            if !sourceOK(entry.source) { v.errors.append(.sourceOutOfRange(entry.source)) }
            used.insert(entry.source)
            if !entry.gain.isFinite || abs(entry.gain) > 100 { v.errors.append(.matrixGainOutOfRange) }
            entriesPerOutput[entry.output, default: 0] += 1
        }
        for (endpoint, count) in entriesPerOutput where count > Int(N60_ROUTE_MAX_ENTRIES) {
            v.errors.append(.tooManyEntries(endpoint))
        }
        let lanes = context.programLanes + context.subwoofers + outputEndpoints.count
        if lanes > Self.maxGraphLanes { v.errors.append(.channelCap(lanes: lanes)) }
        // Every sub lane should feed something; unused program lanes are normal (the LFE lane, for one).
        for index in 0..<max(0, context.subwoofers) where !used.contains(.sub(index)) {
            v.warnings.append(.unroutedSource(.sub(index)))
        }
        return v
    }

    /// Adjacent ways sorted by band: the lower way's low-pass corner against the upper way's high-pass corner.
    private static func bandWarnings(speaker: String, ways: [RoutedWay]) -> [SpeakerRoutingWarning] {
        let banded = ways.filter { $0.highPass != nil || $0.lowPass != nil }
        guard banded.count == ways.count, ways.count > 1 else { return [] }
        // Order by the band's lower edge (no high-pass means it starts at the bottom).
        let ordered = ways.sorted { ($0.highPass?.cornerHz ?? 0) < ($1.highPass?.cornerHz ?? 0) }
        var result: [SpeakerRoutingWarning] = []
        for index in 0..<(ordered.count - 1) {
            let lower = ordered[index], upper = ordered[index + 1]
            guard let lp = lower.lowPass?.cornerHz, let hp = upper.highPass?.cornerHz else {
                // An open edge facing a neighbour is an overlap of the whole band.
                result.append(.bandOverlap(speaker: speaker, lowerHz: lower.lowPass?.cornerHz ?? 0,
                                           upperHz: upper.highPass?.cornerHz ?? 0))
                continue
            }
            if hp > lp * 1.001 {
                result.append(.bandGap(speaker: speaker, lowerHz: lp, upperHz: hp))
            } else if hp < lp * 0.999 {
                result.append(.bandOverlap(speaker: speaker, lowerHz: lp, upperHz: hp))
            }
        }
        return result
    }
}
