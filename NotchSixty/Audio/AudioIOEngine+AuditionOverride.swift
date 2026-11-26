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
}
