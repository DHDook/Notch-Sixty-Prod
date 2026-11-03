import Foundation

// E25 S1: derive a `SystemArrangement` from a stored playback system, deterministically and idempotently.
//   - routing enabled        -> direct, from the routing speakers (checked first, as `buildTransport` does);
//   - profile enabled        -> direct, with its subs;
//   - neither, bass off      -> 2.0 full range;
//   - neither, bass on       -> mono bass on the pair (exactly today's recombined stereo crossover).
// Pure: nothing here writes the state. S3 calls it from the wizard when the flag is on.

enum SystemArrangementMigration {
    /// `detectedChannelCount` is what the device reports now (0 when unknown); the stored state does not know it.
    /// Returns nil when the stored configuration has no arrangement equivalent (a legacy physical crossover, or a
    /// routing whose lanes do not fit a layout); the stored fields then keep working exactly as before.
    static func derive(from state: PlaybackSystemState, detectedChannelCount: Int = 0) -> SystemArrangement? {
        if let existing = state.systemArrangement { return existing }
        if let routing = state.speakerRouting, routing.enabled {
            return fromRouting(routing, state: state, detected: detectedChannelCount)
        }
        if let profile = state.outputDeviceProfile, profile.enabled {
            return fromProfile(profile, state: state, detected: detectedChannelCount)
        }
        guard state.bassManagement.physicalOutputMode == nil else { return nil }
        let uid = state.associatedOutputUID ?? ""
        return SystemArrangement(
            outputs: SystemOutputs(deviceUID: uid, detectedChannelCount: detectedChannelCount, channelsInUse: 2),
            layout: .stereo,
            bass: state.bassManagement.enabled ? .dspMonoToMains : .fullRange,
            subwooferCount: 0,
            speakers: [
                ArrangedSpeaker(role: .frontLeft, feed: .direct(PhysicalOutputEndpoint(deviceUID: uid, channelIndex: 0))),
                ArrangedSpeaker(role: .frontRight, feed: .direct(PhysicalOutputEndpoint(deviceUID: uid, channelIndex: 1))),
            ])
    }

    /// Fills `systemArrangement` when it is empty. Idempotent: a second call changes nothing.
    static func migrated(_ state: PlaybackSystemState, detectedChannelCount: Int = 0) -> PlaybackSystemState {
        guard state.systemArrangement == nil,
              let arrangement = derive(from: state, detectedChannelCount: detectedChannelCount) else { return state }
        var result = state
        result.systemArrangement = arrangement
        return result
    }

    private static func fromProfile(
        _ profile: OutputDeviceProfileConfiguration, state: PlaybackSystemState, detected: Int
    ) -> SystemArrangement? {
        let endpoints = profile.speakerAssignments.map(\.destination) + profile.subwooferAssignments.map(\.destination)
        guard let uid = endpoints.first?.deviceUID ?? state.associatedOutputUID,
              endpoints.allSatisfy({ $0.deviceUID == uid }) else { return nil }
        let subs = profile.subwooferAssignments.sorted { $0.index < $1.index }.map(\.destination)
        let inUse = max(2, Int((endpoints.map(\.channelIndex).max() ?? 1)) + 1)
        return SystemArrangement(
            outputs: SystemOutputs(deviceUID: uid, detectedChannelCount: detected, channelsInUse: inUse),
            layout: profile.programLayout,
            bass: subs.isEmpty ? .fullRange : .dspToSubOutputs,
            subwooferCount: subs.count,
            subOutputs: subs,
            speakers: profile.speakerAssignments.map { ArrangedSpeaker(role: $0.role, feed: .direct($0.destination)) })
    }

    private static func fromRouting(
        _ routing: SpeakerRoutingConfiguration, state: PlaybackSystemState, detected: Int
    ) -> SystemArrangement? {
        // Only the plain mains-plus-sub shape has an arrangement equivalent.
        guard routing.matrix.isEmpty,
              let subs = routing.subEndpoints,
              !routing.speakers.contains(where: { $0.ways.count != 1 && $0.source.kind == .program }) else { return nil }
        let mains = routing.speakers.filter { $0.source.kind == .program }.sorted { $0.source.index < $1.source.index }
        let layoutRoles: [(OutputProgramLayout, [OutputProgramRole])] = [
            .stereo, .threeOne, .fiveOne, .sevenOne, .fiveOneTwo, .fiveOneFour, .sevenOneFour, .nineOneSix,
        ].map { ($0, $0.roles.filter { $0 != .lowFrequencyEffects }) }
        guard let (layout, roles) = layoutRoles.first(where: { $0.1.count == mains.count }),
              mains.map(\.source.index) == Array(0..<mains.count) else { return nil }
        let endpoints = mains.compactMap { $0.ways.first?.endpoint }
        guard endpoints.count == mains.count,
              let uid = endpoints.first?.deviceUID,
              (endpoints + subs).allSatisfy({ $0.deviceUID == uid }) else { return nil }
        let inUse = max(2, Int(((endpoints + subs).map(\.channelIndex).max() ?? 1)) + 1)
        return SystemArrangement(
            outputs: SystemOutputs(deviceUID: uid, detectedChannelCount: detected, channelsInUse: inUse),
            layout: layout,
            bass: subs.isEmpty ? .fullRange : .dspToSubOutputs,
            subwooferCount: subs.count,
            subOutputs: subs,
            speakers: zip(roles, endpoints).map { ArrangedSpeaker(role: $0, feed: .direct($1)) },
            realisation: .routing)
    }

}

extension SpeakerRoutingConfiguration {
    /// The single output of each sub speaker in sub-index order, or nil when a sub has more than one way.
    fileprivate var subEndpoints: [PhysicalOutputEndpoint]? {
        let subs = speakers.filter { $0.source.kind == .sub }.sorted { $0.source.index < $1.source.index }
        guard subs.allSatisfy({ $0.ways.count == 1 }), subs.map(\.source.index) == Array(0..<subs.count) else { return nil }
        return subs.compactMap { $0.ways.first?.endpoint }
    }
}
