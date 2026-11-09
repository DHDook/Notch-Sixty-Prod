import Foundation

// E26 S6a: the ANC guard, inject and capture stages on the profile session's unified graph, with the sub lane as
// one actuator beside the mains (design 7: class A, one ANC_INJECT per actuator lane, after BASS_MGMT). Built dark
// behind `e26.sub-aware-anc`: no host feeds the anti-noise source lanes yet (owning slice: S6b/S7, see E26.md).
//
// Realtime contract (AGENTS.md section 4): this value is control plane only. It only describes core stages; the
// stages themselves are the E4 ANC stages, which allocate nothing in the callback, take no locks, and reset on a
// rebuild. Latency: none added. Sample rate: any the core accepts. Channels: one source lane per actuator plus one
// error lane, appended after the existing lanes. Authorisation exists only as the NOT-live `authorised` parameter in
// the snapshot, and defaults to false.

struct UnifiedGraphAncActuators: Equatable, Sendable {
    struct Actuator: Equatable, Sendable {
        /// The speaker lane the anti-noise is added to (a main, or the sub lane).
        var targetLane: Int
        /// Static injection gain, dB (-96...0).
        var gainDB: Float = 0
    }

    static let maxActuators = 6
    static let guardParameterCount = 28
    static let guardStageBase: UInt32 = 700
    static let injectStageBase: UInt32 = 710
    static let captureStageId: UInt32 = 720

    var actuators: [Actuator]
    /// Not live: nothing is injected or captured until the snapshot carries true.
    var authorised = false
    /// Capture ring per lane, frames (1...N60_GRAPH_MAX_DELAY_FRAMES).
    var captureFrames: UInt32
    /// Guard growth and ceiling limits, from the E4 defaults.
    var outputCeiling: Float = 0.9
    /// E26 S7b2: the anti-noise source lanes are filled by an `N60AncLaneFeed` registered as the graph's EXTERNAL
    /// stage (lanes: the two programme lanes, then the three source lanes; `stereoDirect`: then the two). Needs exactly
    /// three actuators (left main, right main, sub; two with `stereoDirect`), and no other EXTERNAL stage in the spec. The guards then have no error input.
    var hostFed = false
    /// E26 S7b2: the user's software volume, linear. With a host feed the bridge gain stays 1 and this gain sits in
    /// OUTPUT_GAIN stages on the programme and sub lanes, ahead of ANC_INJECT, so the anti-noise ignores app volume.
    var userOutputGain: Float = 1
    /// E26 S7b2: bumped to re-arm a tripped guard (ANC_GUARD param 11, ANC_INJECT param 3; both live).
    var rearmRevision: UInt32 = 0

    /// E6 S12h part 2b: the stereo session's feed (direct stereo, `N60AncLaneFeedConfig.directStereo`): two actuators
    /// (the left and right main), no sub lane and no splitter, so the EXTERNAL stage covers four lanes. Needs `hostFed`.
    var stereoDirect = false
    /// E6 S12h part 2b: the host callback's declared latency in frames, carried by the EXTERNAL stage (the AU rack's
    /// latency when the rack shares the stage through the feed's inner processor). 0 otherwise.
    var externalLatencyFrames: UInt32 = 0

    static let feedStageId: UInt32 = 730
    static let hostFedActuatorCount = 3
    static let stereoDirectActuatorCount = 2
    var feedActuatorCount: Int { stereoDirect ? Self.stereoDirectActuatorCount : Self.hostFedActuatorCount }
    /// The lanes the feed's EXTERNAL stage runs over, in the feed's channel order: programme left and right, then
    /// the left, right and sub anti-noise sources.
    func feedLaneMask(base: Int) -> UInt64 {
        (UInt64(1) << 0) | (UInt64(1) << 1) | (0..<feedActuatorCount).reduce(into: UInt64(0)) {
            $0 |= UInt64(1) << UInt64(sourceLane($1, base: base))
        }
    }

    /// Lanes appended to the graph: one anti-noise source per actuator, then the error microphone lane.
    var appendedLaneCount: Int { actuators.count + 1 }

    func sourceLane(_ index: Int, base: Int) -> Int { base + index }
    func errorLane(base: Int) -> Int { base + actuators.count }

    func validate(existingLanes: Int) throws {
        guard !actuators.isEmpty, actuators.count <= Self.maxActuators,
              existingLanes + appendedLaneCount <= Int(N60_GRAPH_MAX_CHANNELS),
              captureFrames >= 1, captureFrames <= N60_GRAPH_MAX_DELAY_FRAMES,
              outputCeiling > 0, outputCeiling <= 1,
              userOutputGain >= 0, userOutputGain <= 10_000,
              !hostFed || actuators.count == feedActuatorCount,
              hostFed || (!stereoDirect && externalLatencyFrames == 0),
              externalLatencyFrames <= N60_GRAPH_MAX_DELAY_FRAMES,
              Set(actuators.map(\.targetLane)).count == actuators.count else {
            throw UnifiedGraphError.invalidConfiguration("ANC actuators")
        }
        for a in actuators {
            guard a.targetLane >= 0, a.targetLane < existingLanes, a.gainDB.isFinite, a.gainDB >= -96, a.gainDB <= 0 else {
                throw UnifiedGraphError.invalidConfiguration("ANC actuator lane")
            }
        }
    }

    /// Places the stages in core rank order: guard and inject before PROTECTION (27), capture before the final
    /// stages (30). The spec's other stages are left untouched.
    func apply(to spec: inout UnifiedGraphSpec, existingLanes base: Int) throws {
        try validate(existingLanes: base)
        if hostFed, spec.stages.contains(where: { $0.kind == N60_STAGE_EXTERNAL.rawValue }) {
            throw UnifiedGraphError.invalidConfiguration("ANC feed needs the EXTERNAL stage")
        }
        let tail: Set<UInt32> = [
            N60_STAGE_PROTECTION.rawValue, N60_STAGE_MUTE.rawValue, N60_STAGE_ANC_CAPTURE.rawValue,
            N60_STAGE_FINAL_SANITISE.rawValue, N60_STAGE_FINAL_METER.rawValue,
        ]
        let final: Set<UInt32> = [N60_STAGE_FINAL_SANITISE.rawValue, N60_STAGE_FINAL_METER.rawValue]
        let error = errorLane(base: base)
        var guards: [UnifiedGraphStageSpec] = []
        var injects: [UnifiedGraphStageSpec] = []
        var mask: UInt64 = UInt64(1) << UInt64(error)
        for (i, a) in actuators.enumerated() {
            let source = sourceLane(i, base: base)
            var g = [Float](repeating: -100, count: Self.guardParameterCount)
            g[0] = hostFed ? -1 : Float(error); g[1] = -1; g[2] = 6; g[3] = 3; g[4] = 6; g[5] = 6; g[6] = 3
            g[7] = outputCeiling; g[8] = -60; g[9] = 0.005; g[10] = 0; g[11] = Float(rearmRevision)
            guards.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_ANC_GUARD.rawValue, stageId: Self.guardStageBase + UInt32(i), laneA: UInt32(source),
                params: g))
            injects.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_ANC_INJECT.rawValue, stageId: Self.injectStageBase + UInt32(i), laneA: UInt32(a.targetLane),
                params: hostFed
                    ? [Float(source), authorised ? 1 : 0, a.gainDB, Float(rearmRevision)]
                    : [Float(source), authorised ? 1 : 0, a.gainDB]))
            mask |= UInt64(1) << UInt64(a.targetLane)
        }
        let capture = UnifiedGraphStageSpec(
            kind: N60_STAGE_ANC_CAPTURE.rawValue, stageId: Self.captureStageId, laneA: 0, laneMask: mask,
            capacityFrames: captureFrames, params: [authorised ? 1 : 0])
        if hostFed {
            // The feed runs at the core's EXTERNAL position (12.5): after METER_OUT, before BASS_MGMT.
            let feedAt = spec.stages.firstIndex {
                UnifiedGraphProgramDSP.position(of: $0.kind) > UnifiedGraphProgramDSP.position(of: N60_STAGE_EXTERNAL.rawValue)
            } ?? spec.stages.count
            spec.stages.insert(UnifiedGraphStageSpec(
                kind: N60_STAGE_EXTERNAL.rawValue, stageId: Self.feedStageId, laneA: 0,
                laneMask: feedLaneMask(base: base), capacityFrames: externalLatencyFrames, params: [1]), at: feedAt)
        }
        let injectAt = spec.stages.firstIndex { tail.contains($0.kind) } ?? spec.stages.count
        spec.stages.insert(contentsOf: guards + injects, at: injectAt)
        let captureAt = spec.stages.firstIndex { final.contains($0.kind) } ?? spec.stages.count
        spec.stages.insert(capture, at: captureAt)
        // The configuration's `channelCount` already includes the appended lanes, so the spec's channels are set.
    }
}
