import Foundation

/// E33 S20 (G39): the speaker groups the Equalizer can carry its own band list for on a wide session. "All" is the
/// session's ordinary EQ (`StereoEQConfiguration` linked, independent or mid/side lists); each group below has one more
/// list that runs on that group's lanes only, on top of it.
///
/// Realtime: none. Pure value logic, built off the audio thread; the lists reach the core as ordinary per-lane PEQ
/// stages (`N60_STAGE_PEQ`, one per group lane), so no new realtime component exists. Sample rate: the biquads are
/// designed for the session rate. Channel count: any layout up to `N60_LAYOUT_MAX_CHANNELS`; lanes with a custom role
/// belong to no group. Latency: 0 (IIR), so every lane keeps the session's alignment. Reset: a rebuild or snapshot swap
/// resets the stages like any other PEQ stage. Allocation and synchronisation: none on the audio thread.
enum EQChannelGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case fronts, centre, surrounds, heights, lfe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fronts: return "Fronts"
        case .centre: return "Centre"
        case .surrounds: return "Surrounds"
        case .heights: return "Heights"
        case .lfe: return "LFE"
        }
    }

    /// Core role codes (`n60_channel_role`) in the group. Wides sit with the fronts, sides and rears are the surrounds,
    /// every top role is a height.
    func contains(roleCode: UInt32) -> Bool {
        switch self {
        case .fronts: return [1, 2, 9, 10].contains(roleCode)
        case .centre: return roleCode == 3
        case .surrounds: return (5...8).contains(roleCode)
        case .heights: return (11...16).contains(roleCode)
        case .lfe: return roleCode == 4
        }
    }

    /// The lanes of this group in a layout, ascending.
    func lanes(roleCodes: [UInt32]) -> [Int] {
        roleCodes.enumerated().filter { contains(roleCode: $0.element) }.map(\.offset)
    }

    /// Only the groups the layout has, in display order. A stereo session has none (it ignores group lists).
    static func available(roleCodes: [UInt32]) -> [EQChannelGroup] {
        guard roleCodes.count > 2 else { return [] }
        return allCases.filter { !$0.lanes(roleCodes: roleCodes).isEmpty }
    }

    /// Group lists are stored per layout: the key is the ordered role list, so a 5.1 list is not read by a 7.1 session.
    static func layoutKey(roleCodes: [UInt32]) -> String {
        roleCodes.map(String.init).joined(separator: "-")
    }

    /// True when no lane of the group is part of a left/right pair.
    func isUnpaired(shape: UnifiedGraphLayoutShape) -> Bool {
        let paired = Set(shape.pairs.flatMap { [$0.a, $0.b] })
        return Set(lanes(roleCodes: shape.roleCodes)).isDisjoint(with: paired)
    }
}

/// One group's compiled curve on one lane, as the graph translator takes it.
struct UnifiedGraphGroupEQ: Equatable, Sendable {
    var group: EQChannelGroup
    var lane: Int
    var sections: [UnifiedGraphPEQSection]
    /// Linear-phase EQ (G75): the lane's whole EQ (its session bands plus the group's) as one FIR, designed with the
    /// session's tap count so its latency equals the program FIR's. nil keeps the minimum-phase `sections`. The graph
    /// uses the FIR only when it also runs a program FIR of the same latency; otherwise it falls back to `sections`.
    var taps: [Float]?
    var declaredLatencyFrames: UInt32 = 0
}

extension StereoEQConfiguration {
    private func groupKey(_ group: EQChannelGroup, roleCodes: [UInt32]) -> String {
        EQChannelGroup.layoutKey(roleCodes: roleCodes) + "/" + group.rawValue
    }

    /// The band list of a group in a layout; empty when none was stored.
    func groupBands(_ group: EQChannelGroup, roleCodes: [UInt32]) -> [EQBand] {
        groupBandLists[groupKey(group, roleCodes: roleCodes)] ?? []
    }

    mutating func setGroupBands(_ bands: [EQBand], for group: EQChannelGroup, roleCodes: [UInt32]) {
        let key = groupKey(group, roleCodes: roleCodes)
        if bands.isEmpty { groupBandLists.removeValue(forKey: key) } else { groupBandLists[key] = bands }
    }

    /// The per-lane curves the graph runs for the groups of `shape`. Empty on a stereo session (group lists are
    /// ignored), when the EQ is bypassed, or when no group has an enabled band. Lists are only written by the group
    /// selector, which stays dark behind `e33.page-enhancements` until S11, so flag-off sessions never carry one.
    /// A band that a plain biquad cannot carry (FIR, Linkwitz transform, dynamic) is refused by name.
    func groupCurves(shape: UnifiedGraphLayoutShape, sampleRate: Double) throws -> [UnifiedGraphGroupEQ] {
        guard !bypassed, shape.laneCount > 2, !groupBandLists.isEmpty else { return [] }
        var result: [UnifiedGraphGroupEQ] = []
        for group in EQChannelGroup.allCases {
            let bands = groupBands(group, roleCodes: shape.roleCodes)
            guard bands.contains(where: \.enabled) else { continue }
            guard bands.count <= EQConfiguration.maximumBandCount else {
                throw EQConfigurationError.tooManyBands(bands.count)
            }
            var sections: [UnifiedGraphPEQSection] = []
            for (index, band) in bands.enumerated() where band.enabled {
                guard band.type != .fir, band.type != .linkwitzTransform, !band.dynamic.enabled else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
                guard try EQBandRules.validate(band, index: index, sampleRate: sampleRate) else { continue }
                for compiled in try band.compiledSections(sampleRate: sampleRate) {
                    sections.append(UnifiedGraphPEQSection(
                        type: Int(compiled.type.rawValue), frequencyHz: compiled.frequencyHz,
                        gainDB: compiled.gainDB, q: compiled.q))
                }
            }
            guard !sections.isEmpty else { continue }
            for lane in group.lanes(roleCodes: shape.roleCodes) {
                result.append(UnifiedGraphGroupEQ(group: group, lane: lane, sections: sections))
            }
        }
        if phaseMode == .linearPhase, channelMode != .midSide {
            try attachGroupFIR(&result, shape: shape, sampleRate: sampleRate)
        }
        return result.sorted { $0.lane < $1.lane }
    }

    /// E33 S20 part 3 (G75): linear phase keeps every lane aligned by giving each group lane one FIR of its session
    /// curve times its group curve. Lanes with equal band lists share one design. Mixed phase keeps the group's
    /// minimum-phase biquads (latency 0 on every lane, so alignment holds; the group lanes do not get the all-pass
    /// phase correction, a stated limit).
    private func attachGroupFIR(
        _ entries: inout [UnifiedGraphGroupEQ], shape: UnifiedGraphLayoutShape, sampleRate: Double
    ) throws {
        let reach = EQSessionReach.reach(shape: shape, mode: channelMode == .independent ? .independent : .linked)
        var designs: [(bands: [EQBand], taps: [Float], latency: UInt32)] = []
        for index in entries.indices {
            let lane = entries[index].lane
            let session: [EQBand]
            if reach.firstCurveLanes.contains(lane) {
                session = channelMode == .independent ? leftBands : linkedBands
            } else if reach.secondCurveLanes.contains(lane) {
                session = rightBands
            } else {
                session = []
            }
            let bands = (session + groupBands(entries[index].group, roleCodes: shape.roleCodes)).filter(\.enabled)
            if let hit = designs.first(where: { $0.bands == bands }) {
                entries[index].taps = hit.taps
                entries[index].declaredLatencyFrames = hit.latency
                continue
            }
            var configuration = StereoEQConfiguration()
            configuration.channelMode = .linked
            configuration.phaseMode = .linearPhase
            configuration.linkedBands = bands
            let design = try EQFIRDesigner.design(configuration, sampleRate: sampleRate)
            designs.append((bands, design.left, design.declaredLatencyFrames))
            entries[index].taps = design.left
            entries[index].declaredLatencyFrames = design.declaredLatencyFrames
        }
    }

    /// G85: the most boost, in dB, any one group adds on top of the session curve (sum of positive static gains, the
    /// same conservative rule as the session's own). Zero on a stereo session, when bypassed or with no group lists.
    func groupStaticBoostDB(roleCodes: [UInt32]) -> Double {
        guard !bypassed, roleCodes.count > 2, !groupBandLists.isEmpty else { return 0 }
        return EQChannelGroup.allCases.map { group in
            groupBands(group, roleCodes: roleCodes).lazy.filter(\.enabled).reduce(0.0) { $0 + max(0.0, $1.gainDB) }
        }.max() ?? 0
    }
}
