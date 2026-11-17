import Foundation

/// E33 S12 (G22): the single table that says which lanes each Dynamics processor acts on, on a stereo, N-channel,
/// routed or Virtual Speakers (binaural) session. It extends the E6 D2 mapping (`docs/epics/E6.md`) to every processor
/// on the Dynamics page. `UnifiedGraphProgramDSP.apply` takes its lane sets from here, and the Dynamics page prints its
/// "Acts on" line from here, so the page, the translator and the docs cannot drift apart.
///
/// Realtime: none. Pure value logic, built off the audio thread. Sample rate and channel count: independent of both.
enum DynamicsSessionMapping {
    /// How a processor's lanes relate to the layout.
    enum Scope: Equatable, Sendable {
        /// Every program lane, the LFE and unpaired lanes included.
        case everyLane
        /// Every program lane except the LFE (the EQ lane set in Linked and Mid/Side).
        case nonLFE
        /// The left/right pair members only (the EQ lane set in Independent); the centre and LFE pass through.
        case pairedLanes
        /// The front left and right pair only; every other lane passes through untouched.
        case frontPair
        /// The two ears of a Virtual Speakers session, after binaural rendering.
        case ears
    }

    struct Mapping: Equatable, Sendable {
        var scope: Scope
        /// The lanes the processor's stage writes, ascending (front pair: left then right).
        var lanes: [Int]
        /// One detector and one gain for the whole lane set, so the image is preserved.
        var linked: Bool
        /// The lanes the detector hears (empty when the processor has no detector). Includes the LFE where the lane set does.
        var detectorLanes: [Int]
        /// Set when the session cannot host the processor: the graph throws this named reason instead of dropping it.
        var refusal: UnifiedGraphFallbackReason?
        var laneMask: UInt64 { lanes.reduce(into: UInt64(0)) { $0 |= UInt64(1) << UInt64($1) } }
    }

    static func mapping(
        for module: ProductionDynamicsModule,
        shape: UnifiedGraphLayoutShape,
        virtualSpeakers: Bool,
        eqMode: UnifiedGraphProgramDSP.EQMode = .linked
    ) -> Mapping {
        let all = Array(0..<shape.laneCount)
        let lfe = shape.lfeLane
        let nonLFE = all.filter { $0 != lfe }
        let paired = (shape.leftMembers + shape.rightMembers).sorted()
        func front() -> Mapping {
            guard let fl = shape.frontLeft, let fr = shape.frontRight else {
                return Mapping(scope: .frontPair, lanes: [], linked: false, detectorLanes: [], refusal: .noFrontPair)
            }
            let lanes = [fl, fr]
            return Mapping(scope: .frontPair, lanes: lanes, linked: false, detectorLanes: lanes, refusal: nil)
        }
        switch module {
        case .dcOffset, .infrasonic, .mainsHum, .automaticHeadroom:
            // Cleanup filters are per channel: a pair instance for each layout pair and a single-lane instance for every
            // other lane (centre, LFE). Automatic headroom is one gain ahead of the graph, so it reaches every lane.
            return Mapping(scope: .everyLane, lanes: all, linked: false, detectorLanes: [], refusal: nil)
        case .denoiser:
            let covered = eqMode == .independent ? paired : nonLFE
            return Mapping(scope: eqMode == .independent ? .pairedLanes : .nonLFE, lanes: covered, linked: false,
                           detectorLanes: covered, refusal: nil)
        case .stereoMode, .stereoWidener, .deHarsh, .deEsser, .loudnessMatch, .loudnessContour, .dialogueLeveler,
             .multiband:
            var mapping = front()
            if !module.hasDetector { mapping.detectorLanes = [] }
            return mapping
        case .compressor, .expander:
            return Mapping(scope: .everyLane, lanes: all, linked: true, detectorLanes: all, refusal: nil)
        case .pauseGate:
            if virtualSpeakers { return Mapping(scope: .ears, lanes: [0, 1], linked: true, detectorLanes: [0, 1], refusal: nil) }
            return Mapping(scope: .everyLane, lanes: all, linked: true, detectorLanes: all, refusal: nil)
        case .gainRider, .softClipper, .limiter, .oversampling:
            // Protection (sub lanes stay with E9). Virtual Speakers: on the ears, ahead of the layout's own safety limiter.
            if virtualSpeakers { return Mapping(scope: .ears, lanes: [0, 1], linked: true, detectorLanes: [0, 1], refusal: nil) }
            return Mapping(scope: .everyLane, lanes: all, linked: true, detectorLanes: all, refusal: nil)
        }
    }

    /// The short "Acts on" line for the Dynamics page. `sessionLanes` is 2 for a stereo session.
    static func actsOnText(
        for module: ProductionDynamicsModule,
        shape: UnifiedGraphLayoutShape,
        virtualSpeakers: Bool,
        eqMode: UnifiedGraphProgramDSP.EQMode = .linked
    ) -> String {
        let mapping = mapping(for: module, shape: shape, virtualSpeakers: virtualSpeakers, eqMode: eqMode)
        if mapping.refusal != nil {
            return "Unavailable: this layout has no front left and right pair"
        }
        let linkedSuffix = mapping.linked ? ", linked" : ""
        if shape.laneCount == 2, !virtualSpeakers {
            return "Left and right" + linkedSuffix
        }
        switch mapping.scope {
        case .everyLane:
            let lfeNote = shape.lfeLane != nil ? " (LFE included)" : ""
            return "All speakers" + linkedSuffix + lfeNote
        case .nonLFE:
            return shape.lfeLane != nil ? "All speakers except the LFE" : "All speakers"
        case .pairedLanes:
            return "Left and right pairs only; centre and LFE pass through"
        case .frontPair:
            return virtualSpeakers
                ? "Front pair of the virtual speakers; the others pass through"
                : "Front pair only; the other speakers pass through"
        case .ears:
            return "Both ears, after binaural rendering" + linkedSuffix
        }
    }
}

extension ProductionDynamicsModule {
    /// Whether the processor listens to the signal to decide what to do (the table's detector column).
    fileprivate var hasDetector: Bool {
        switch self {
        case .stereoMode, .stereoWidener, .dcOffset, .infrasonic, .mainsHum, .automaticHeadroom, .oversampling: return false
        default: return true
        }
    }
}
