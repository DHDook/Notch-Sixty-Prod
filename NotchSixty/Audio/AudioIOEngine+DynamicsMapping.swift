import Foundation

/// E33 S12 (G22): the session the Dynamics page describes. The page prints `DynamicsSessionMapping.actsOnText` for this
/// shape, the same table `UnifiedGraphProgramDSP` builds its lane sets from. Control plane only.
extension AudioIOEngine {
    struct DynamicsSessionDescription {
        var shape: UnifiedGraphLayoutShape
        var virtualSpeakers: Bool
        var eqMode: UnifiedGraphProgramDSP.EQMode
    }

    /// The layout and EQ lane set of the current session: a routed or N-channel session, a Virtual Speakers session, or
    /// the stereo pair when nothing wide is running. Nil only if the core cannot describe the layout.
    var dynamicsSessionDescription: DynamicsSessionDescription? {
        let roles: [OutputProgramRole]
        var virtual = false
        if let session = nChannelTransportSession {
            roles = session.routePlan.programLayout.roles
        } else if let session = binauralHeadphoneTransportSession {
            roles = session.programLayout.roles
            virtual = true
        } else {
            roles = [.frontLeft, .frontRight]
        }
        guard let shape = UnifiedGraphLayoutShape(roles: roles) else { return nil }
        let mode: UnifiedGraphProgramDSP.EQMode
        switch stereoEQConfiguration.bypassed ? .linked : stereoEQConfiguration.channelMode {
        case .linked: mode = .linked
        case .independent: mode = .independent
        case .midSide: mode = .midSide
        }
        return DynamicsSessionDescription(shape: shape, virtualSpeakers: virtual, eqMode: mode)
    }

    func dynamicsActsOnText(for module: ProductionDynamicsModule) -> String? {
        guard let description = dynamicsSessionDescription else { return nil }
        return DynamicsSessionMapping.actsOnText(
            for: module, shape: description.shape, virtualSpeakers: description.virtualSpeakers, eqMode: description.eqMode)
    }
}

extension AudioIOEngine {
    /// E33 S18 (G35): the Equalizer page's "Applies to" line for the current session, from `EQSessionReach`.
    var eqReachText: String? {
        guard let description = dynamicsSessionDescription else { return nil }
        let mode: UnifiedGraphProgramDSP.EQMode
        switch stereoEQConfiguration.channelMode {
        case .linked: mode = .linked
        case .independent: mode = .independent
        case .midSide: mode = .midSide
        }
        return EQSessionReach.pageText(
            shape: description.shape, mode: mode, virtualSpeakers: description.virtualSpeakers)
    }
}
