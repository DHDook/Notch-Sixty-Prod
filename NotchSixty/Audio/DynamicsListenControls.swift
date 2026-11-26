import Foundation

/// E28 S7d: the Dynamics page's listen and solo controls. Control plane only (main actor, the host lock); the engine never
/// reads this state, it reads the parameters the host posts.
extension AudioIOEngine {
    /// Makes `listener` the only listener (nil stops). Throws, leaving the state unchanged, when nothing renders or the
    /// stage has no listen slot (flag off).
    func setDynamicsListener(_ listener: DynamicsListener?) throws {
        guard listener == nil || FeatureFlags().isEnabled(.dynamicsExtras) else {
            throw DynamicsExtrasError.flagOff
        }
        guard let host = dynamicsListenHost else {
            if listener == nil { setDynamicsListenerMirror(nil, solo: dynamicsSoloBands); return }
            throw DynamicsExtrasError.notRunning
        }
        try host.setListener(listener)
        setDynamicsListenerMirror(host.listenSession.listener, solo: host.listenSession.soloBands)
    }

    /// Solos the given multiband bands (empty clears).
    func setDynamicsSoloBands(_ bands: Set<Int>) throws {
        guard bands.isEmpty || FeatureFlags().isEnabled(.dynamicsExtras) else { throw DynamicsExtrasError.flagOff }
        guard let host = dynamicsListenHost else {
            if bands.isEmpty { setDynamicsListenerMirror(dynamicsListener, solo: []); return }
            throw DynamicsExtrasError.notRunning
        }
        try host.setSoloBands(bands)
        setDynamicsListenerMirror(host.listenSession.listener, solo: host.listenSession.soloBands)
    }

    /// Ends listening and solo (profile switch, Stop, output change, Quit). A failed clear post is retried once and then
    /// reported through `lastErrorDescription` instead of being swallowed (G37).
    func clearDynamicsListening() {
        surfaceDynamicsListenRepostFailure(clearing: false)
        defer { setDynamicsListenerMirror(nil, solo: []) }
        guard let host = dynamicsListenHost else { return }
        if !host.clearListener() {
            if !host.clearListener() {
                reportDynamicsListenError("Dynamics listening could not be switched off; stop and start processing to clear it.")
            }
        }
    }
}

extension AudioIOEngine {
    /// A rebuild that could not post the listener again leaves the core silent while the page shows a listener; say so and end
    /// the listener so the page matches the core (E28 S7d part 3, G37).
    func surfaceDynamicsListenRepostFailure(clearing: Bool = true) {
        guard let host = dynamicsListenHost, host.takeListenRepostFailure() else { return }
        if clearing { clearDynamicsListening() }
        reportDynamicsListenError("Dynamics listening could not be restored after the change, so it was switched off. Choose Listen again.")
    }
}

enum DynamicsExtrasError: LocalizedError, Equatable {
    case flagOff
    case notRunning

    var errorDescription: String? {
        switch self {
        case .flagOff: return "Dynamics extras are turned off."
        case .notRunning: return "Start processing to listen or solo."
        }
    }
}

/// E28 S7d (G8): whether the S7 extras can play, and the reason shown beside a disabled control. Pure; the page feeds it the
/// flag and the engine's renderer state.
struct DynamicsExtrasAvailability: Equatable {
    static let notRunningReason = "Start processing to listen or solo."

    var flagOn: Bool
    var running: Bool

    /// Rows and toggles that change the sound: usable when the flag is on.
    var extrasEnabled: Bool { flagOn }
    var extrasDisabledReason: String? { nil }

    /// Listen and solo also need something running.
    var listenEnabled: Bool { extrasEnabled && running }
    var listenDisabledReason: String? {
        guard flagOn else { return nil }
        return running ? nil : Self.notRunningReason
    }

        var bypassEnabled: Bool { flagOn }

    /// "adds X ms" for a lookahead of `ms` at `sampleRate`: the frames the core rounds to, over the rate.
    static func addsText(ms: Double, sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate > 0 else { return String(format: "adds about %.1f ms", ms) }
        let frames = CompressorConfiguration.lookaheadFrames(ms: ms, sampleRate: sampleRate)
        return String(format: "adds %.2f ms (%d frames)", Double(frames) / sampleRate * 1000, frames)
    }
}
