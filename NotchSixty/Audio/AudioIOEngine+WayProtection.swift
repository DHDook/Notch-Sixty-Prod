import Foundation

// E8 S13: the live gain reduction of each routed way's limiter, for the way row in the routing editor. Kept out of
// `AudioIOEngine.swift` (no slice makes it longer).
extension AudioIOEngine {
    /// Gain reduction in dB (0 or more) per physical output, since the last call (read and reset in the core). Empty
    /// when the render is not routed or no way has a limiter. Called by the routing editor only.
    func routedWayGainReductions() -> [PhysicalOutputEndpoint: Float] {
        guard let routing = speakerRoutingConfiguration, routing.enabled,
              let host = transportSession?.unifiedGraphReadback ?? nChannelTransportSession?.unifiedGraphReadback else { return [:] }
        let endpoints = routing.outputEndpoints
        let first = Int(host.outputChannels) - endpoints.count
        guard first >= 0 else { return [:] }
        var out: [PhysicalOutputEndpoint: Float] = [:]
        for (lane, reduction) in host.routedWayGainReductions() {
            let position = lane - first
            if endpoints.indices.contains(position) { out[endpoints[position]] = max(0, reduction) }
        }
        return out
    }
}
