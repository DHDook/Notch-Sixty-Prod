import Foundation

/// E19 S6: the engine's side of the graph MIMO treatment (`MIMOGraphTreatment`). The engine hands the controller its
/// context (running, output, rate, stage attached, hard limit, lease, video mode, per-output trims), attaches the staged
/// stage to a new graph, keeps a control-plane poll running (the lease of design note 8: the treatment is armed only while
/// the poll runs) and forwards teardown causes. Nothing here arms: `requestMIMOTreatmentArm` is the user action, called by
/// the E19 S8 UI; the realtime path is untouched.
extension AudioIOEngine {
    static let mimoPollNanoseconds: UInt64 = 250_000_000

    func makeMIMOGraphTreatment() -> MIMOGraphTreatment {
        let treatment = MIMOGraphTreatment(flags: FeatureFlags())
        treatment.publish = { [weak self] stage in
            // A failed post throws; the controller keeps the word and re-posts it from every poll tick.
            guard let session = self?.nChannelTransportSession else { throw MIMOGraphTreatment.ArmRefusal.stageNotAttached }
            try session.applyMIMOStage(stage)
        }
        _ = addTransportTeardownObserver { [weak treatment, weak self] cause in
            treatment?.arm.transportTornDown(cause)
            // A planned stop is not a disarm cause of the switch, but the lease ends with the poll: the switch goes off too.
            if treatment?.isArmed == true { treatment?.arm.disarm(.engineStopped) }
            self?.stopMIMOPoll()
        }
        return treatment
    }

    /// The facts the controller decides on, read on the main actor.
    func mimoTreatmentContext() -> MIMOGraphTreatment.Context {
        let session = nChannelTransportSession
        let laneCount = session.map { $0.routePlan.programLayout.roles.count + Int($0.routePlan.subwooferCount) } ?? 0
        let settings = dynamicsConfiguration.outputProtection ?? OutputProtectionSettings()
        return MIMOGraphTreatment.Context(
            engineRunning: lifecycle.state == .running && session != nil,
            outputDeviceUID: session?.selectedOutput.uid,
            sampleRate: session?.outputFormat.sampleRate,
            stageAttached: session?.mimoStageAttached ?? false,
            hardLimitPresent: UnifiedGraphOutputProtection.current() != nil,
            engineLeaseHeld: mimoPollTask != nil,
            videoLatencyMode: mimoVideoLatencyMode,
            outputTrimsDB: (0..<laneCount).map { settings.lane($0).trimDB },
            laneCount: laneCount)
    }

    /// Stages a designed stage for the next start (idle only, like the legacy staging). Never arms.
    func stageMIMOTreatment(_ stage: UnifiedGraphMIMOStage?) throws {
        guard lifecycle.state == .idle else { throw LiveNChannelTransportError.configurationChangeRequiresRestart }
        mimoGraphTreatment.stage(stage)
    }

    /// The single user action that starts the 3 s fade-in. Throws the named refusal when a gate fails.
    func requestMIMOTreatmentArm() async throws {
        try await mimoGraphTreatment.requestArm(context: mimoTreatmentContext(), refresh: { [unowned self] in self.mimoTreatmentContext() })
    }

    func disarmMIMOTreatment() { mimoGraphTreatment.userDisarm() }

    /// Called while a new session's configuration is built: attaches the staged stage (disarmed, held) when the flag is on
    /// and the graph accepts it. A graph that refuses it (routed, Quiet Zone actuators, no hard limit) runs without the
    /// stage, so audio is never lost to the treatment, and the arm gate "stage attached" stays closed.
    func attachStagedMIMOTreatment(to configuration: inout UnifiedGraphConfiguration) {
        mimoGraphTreatment.graphRebuilt()
        guard FeatureFlags().isEnabled(.mimoTreatment), let stage = mimoGraphTreatment.stage else { return }
        var candidate = configuration
        candidate.mimo = stage
        guard (try? candidate.makeSpec()) != nil else { return }
        configuration.mimo = stage
        startMIMOPoll()
    }

    /// The control-plane keeper. While it runs the lease gate is open; each tick re-checks the arm switch against the
    /// live context and the stage's own fault latch.
    func startMIMOPoll() {
        guard mimoPollTask == nil else { return }
        mimoPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.mimoPollNanoseconds)
                guard let self, !Task.isCancelled else { return }
                self.pollMIMOTreatment()
            }
        }
    }

    func stopMIMOPoll() {
        mimoPollTask?.cancel()
        mimoPollTask = nil
    }

    func pollMIMOTreatment() {
        let context = mimoTreatmentContext()
        // The lease ends with the session: a stopped or failed start leaves no stale keeper behind.
        if lifecycle.state == .idle { stopMIMOPoll() }
        mimoGraphTreatment.observe(context: context, readback: nChannelTransportSession?.mimoReadback())
    }
}
