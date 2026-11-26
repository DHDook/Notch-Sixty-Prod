import Foundation

// E12 S28b1: the setter and the refusals for the single audition override slot (`auditionOverride`, a stored property
// on `AudioIOEngine`). Control plane, main actor; never called from an audio callback.

extension AudioIOEngine {
    /// Why an override cannot play right now, or nil when it can. `needsRoomCorrection` is true for the ABX sheet's lane
    /// override, which compares two designs and so needs a stored room correction to start from; a side that only turns
    /// room correction or bass off does not.
    func auditionOverrideUnavailableReason(needsRoomCorrection: Bool = true) -> String? {
        if nChannelTransportSession == nil, transportSession != nil {
            return RoomCorrectionInactiveReason.needsSpeakerProfile.message
        }
        guard nChannelTransportSession != nil, liveGraphEditsAvailable else {
            return "Start playback with music to compare by ear."
        }
        if needsRoomCorrection,
           !(roomCorrectionConfiguration.enabled && roomCorrectionConfiguration.lanes != nil) {
            return "Apply a room correction to the speaker profile first."
        }
        return nil
    }

    /// Why the system-level domains (room correction replaced or off, bass management, output gain) cannot be
    /// auditioned: live Quiet Zone or MIMO room treatment was designed on the secondary path that changing them moves,
    /// and a physical speaker-bus splitter (bi-amp or tri-amp) runs its own crossover after shared DSP.
    var auditionSystemDomainsRefusal: String? {
        if mimoGraphTreatment.isArmed || activeQuietZoneRuntimeTarget.active {
            return "Turn off room treatment to compare system settings."
        }
        if physicalSpeakerBusRoutingActive {
            return "Comparing system settings is not available with a bi-amp or tri-amp splitter."
        }
        return nil
    }

    /// Kept for the ABX sheet: same reason text as before.
    var roomCorrectionABXUnavailableReason: String? { auditionOverrideUnavailableReason() }

    /// True while the core is warming or fading to a republished graph (the switch an audition press causes).
    var graphRebuildInProgress: Bool { (nChannelTransportSession?.unifiedGraphReadback?.rebuildState ?? 0) != 0 }

    /// Sets (or, with nil, clears) the audition override and moves the running graph to it through the normal faded
    /// republish, every changed domain in the one graph. Throws and leaves the slot and the running graph as they were
    /// when the graph cannot take it. Clearing never fails to clear.
    func setAuditionOverride(_ override: AuditionOverride?) throws {
        if override == nil, auditionOverride == nil { return }
        if override == nil {
            auditionOverride = nil
            if nChannelTransportSession != nil { try republishLiveGraph(currentLiveGraphInputs) }
            return
        }
        guard let override else { return }
        guard override.isWellFormed else { throw AuditionOverrideError.malformed }
        // Value checks and the safety refusals come first, so they hold with or without a running session.
        if override.latencyPadFrames > N60_GRAPH_MAX_DELAY_FRAMES { throw AuditionOverrideError.padTooLong }
        if override.roomCorrection != .applied || override.bassManagement != nil || override.outputGainDB != nil,
           let reason = auditionSystemDomainsRefusal {
            throw AuditionOverrideError.unavailable(reason)
        }
        let isABXLanes = override.installedLanes != nil && override.bassManagement == nil
            && override.outputGainDB == nil
        if let reason = auditionOverrideUnavailableReason(needsRoomCorrection: isABXLanes) {
            throw RoomCorrectionABXError.unavailable(reason)
        }
        let previous = auditionOverride
        auditionOverride = override
        do { try republishLiveGraph(currentLiveGraphInputs) } catch {
            auditionOverride = previous
            throw error
        }
    }

    /// The ABX sheet's entry point (kept so its wiring does not change).
    func setRoomCorrectionABXOverride(_ override: AuditionOverride?) throws { try setAuditionOverride(override) }

    /// The bass-management configuration the graph build uses: the override's when it has one.
    func auditionedBassManagement(_ stored: BassManagementConfiguration) -> BassManagementConfiguration {
        auditionOverride?.bassManagement ?? stored
    }
    // MARK: Graph build shared with the live republish (E12 S28b2)

    /// Builds the graph configuration for `inputs` on the running N-channel session without publishing it. The live
    /// republish and the audition analysis both call this, so what a side is measured on is what it would play.
    func makeLiveGraphConfiguration(
        session: CoreAudioNChannelTransportSession, inputs: LiveGraphInputs, routing: SpeakerRoutingConfiguration?
    ) throws -> UnifiedGraphConfiguration {
        let rate = session.outputFormat.sampleRate
        // The delta refusal comes before the program build so a refused edit costs nothing (G51).
        if session.routePlan.isRouted, inputs.playback.auditionMode == .delta {
            throw LiveNChannelTransportError.routingRefused("the delta audition is not available with speaker routing; switch to Processed or Reference.")
        }
        guard let shape = UnifiedGraphLayoutShape(roles: session.routePlan.programLayout.roles) else {
            throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
        }
        let folds = foldsStereoCrossover(
            routePlan: session.routePlan, bass: renderBassManagementConfiguration(inputs.bass), requiresRackFree: true)
        if !folds { try requireNoCrossoverAudition(inputs.bass) }
        let program = try makeUnifiedProgramDSP(
            sampleRate: rate, shape: shape, virtualSpeakers: false,
            subwooferCount: Int(session.routePlan.subwooferCount), foldStereoCrossover: folds, inputs: inputs)
        var configuration: UnifiedGraphConfiguration
        if session.routePlan.isRouted {
            guard let activeRouting = routing ?? speakerRoutingConfiguration, activeRouting.enabled else {
                throw LiveNChannelTransportError.routingRefused("the session is routed but no routing is set.")
            }
            configuration = try makeRoutedGraphConfiguration(
                routing: activeRouting, routePlan: session.routePlan, sampleRate: rate, inputs: inputs)
        } else {
            switch UnifiedGraphTranslator.nChannelEligibility(
                routePlan: session.routePlan, sampleRate: rate, gainConfiguration: inputs.gain,
                bassManagementConfiguration: renderBassManagementConfiguration(inputs.bass), programDSP: program
            ) {
            case .success(let built): configuration = built
            case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
            }
        }
        if let generator = inputs.generator {
            guard let mask = generator.selection.mask(laneCount: shape.laneCount, lfeLane: shape.lfeLane),
                  let params = generator.stageParams(sampleRate: rate) else {
                throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected)
            }
            configuration.generatorParams = params
            configuration.generatorLaneMask = mask
        }
        return configuration
    }

    // MARK: Sides of a system comparison (E12 S28b2)

    /// The graph spec a side would play (content settings `content` or the stored ones, with `override` in the slot),
    /// built exactly as a republish builds it but never published. The slot and the stored configuration are put back.
    func auditionSideSpec(content: ContentABAuditionState?, override: AuditionOverride?) throws -> UnifiedGraphSpec {
        guard let session = nChannelTransportSession, liveGraphEditsAvailable else {
            throw AuditionOverrideError.unavailable("Start playback with music to compare by ear.")
        }
        let previous = auditionOverride
        auditionOverride = override
        defer { auditionOverride = previous }
        var inputs = currentLiveGraphInputs
        if let content {
            inputs.stereoEQ = content.stereoEQ
            inputs.dynamics = content.dynamics
            inputs.gain.inputPreampDB = content.inputPreampDB
            inputs.gain.headroomAttenuationDB = content.headroomAttenuationDB
        }
        return try makeLiveGraphConfiguration(session: session, inputs: inputs, routing: nil).makeSpec()
    }

    /// Moves the running graph to a side in one faded republish: its content settings (with `attenuationDB` taken off the
    /// input) and its override together, or back to the stored system with a nil override. Throws and leaves the slot and
    /// the running graph as they were. The system-domain refusals apply as in `setAuditionOverride`.
    func applyAuditionSide(
        content: ContentABAuditionState, attenuationDB: Double, override: AuditionOverride?
    ) throws {
        if let override {
            guard override.isWellFormed else { throw AuditionOverrideError.malformed }
            if override.latencyPadFrames > N60_GRAPH_MAX_DELAY_FRAMES { throw AuditionOverrideError.padTooLong }
            if override.roomCorrection != .applied || override.bassManagement != nil || override.outputGainDB != nil,
               let reason = auditionSystemDomainsRefusal {
                throw AuditionOverrideError.unavailable(reason)
            }
            if let reason = auditionOverrideUnavailableReason(needsRoomCorrection: false) {
                throw AuditionOverrideError.unavailable(reason)
            }
        }
        let previous = auditionOverride
        auditionOverride = override
        do {
            try transitionContentAuditionState(
                content, additionalInputAttenuationDB: attenuationDB, forceRepublish: previous != override)
        } catch {
            auditionOverride = previous
            throw error
        }
    }

    /// Asks the open comparison (if any) to end and restore before a live treatment arms (design note 7: an arm during a
    /// test ends it first). The page sets `auditionEndRequest`; nothing else calls it.
    func endAuditionForArming() { auditionEndRequest?() }

    /// Program lanes and subwoofers of the running session, for the page's eligibility table; nil without a session.
    var auditionLayout: (programLanes: Int, subwoofers: Int)? {
        guard let session = nChannelTransportSession,
              let shape = UnifiedGraphLayoutShape(roles: session.routePlan.programLayout.roles) else { return nil }
        return (shape.laneCount, Int(session.routePlan.subwooferCount))
    }
}
