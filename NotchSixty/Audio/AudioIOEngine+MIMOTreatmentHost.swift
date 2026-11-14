import Foundation

/// E19 S8: the engine's side of the Room Treatment screen (`MIMOTreatmentController`). Control plane, main actor. It stages
/// designs (live when the graph runs), reads the video latency mode from the installed room correction, holds the readback for
/// the screen and forwards Arm and Bypass. It never arms by itself: `requestMIMOTreatmentArm` keeps every gate and
/// `LiveTreatmentArm`.
extension AudioIOEngine: MIMOTreatmentHost {
    var treatment: MIMOGraphTreatment { mimoGraphTreatment }

    var sampleRate: Double? { nChannelTransportSession?.outputFormat.sampleRate }

    /// E19 G30: the room-correction latency mode as the treatment sees it. Video mode (minimum phase) refuses; a correction
    /// with neither a lane plan nor a filter has no stated mode, so it stays `.unknown` and no permit is issued.
    static func videoLatencyInput(for room: RoomCorrectionConfiguration) -> MIMOVideoLatencyInput {
        guard room.enabled else { return .known(videoLatencyMode: false) }
        if let design = room.lanes?.design { return .known(videoLatencyMode: design.latencyMode == .video) }
        // G35: a legacy single filter has no stated mode, but its declared latency is the mode: a minimum-phase filter
        // declares none (video mode), a linear or mixed phase filter declares its group delay (music mode).
        if let filter = room.filter { return .known(videoLatencyMode: filter.declaredLatencyFrames == 0) }
        return .unknown
    }

    func refreshMIMOVideoLatencyInput() {
        let next = Self.videoLatencyInput(for: roomCorrectionConfiguration)
        if mimoVideoLatencyInput != next { mimoVideoLatencyInput = next }
    }

    func treatmentContext() -> MIMOGraphTreatment.Context { mimoTreatmentContext() }

    func treatmentSources() -> [MIMOTreatmentSourceInfo] {
        guard let session = nChannelTransportSession else { return [] }
        let roles = session.routePlan.programLayout.roles
        var infos = roles.enumerated().map { MIMOTreatmentSourceInfo(source: .speaker($1), lane: $0, name: $1.displayName) }
        for index in 0..<Int(session.routePlan.subwooferCount) {
            let source = MultichannelCalibrationSource.subwoofer(UInt32(index))
            infos.append(MIMOTreatmentSourceInfo(source: source, lane: roles.count + index, name: source.displayName))
        }
        if let routing = speakerRoutingConfiguration {
            for speaker in routing.speakers {
                let window = mimoGraphTreatment.routedSupportOverrides[speaker.id] ?? MIMORoutedTreatmentPlanner.defaultSupportHz
                let lane = speaker.source.kind == .program ? speaker.source.index : roles.count + speaker.source.index
                guard let index = infos.firstIndex(where: { $0.lane == lane }) else { continue }
                infos[index].inBandWays = MIMORoutedTreatmentPlanner
                    .inBandWays(of: speaker, lowHz: window.lowerBound, highHz: window.upperBound)
                    .map { $0.name.isEmpty ? $0.id.uuidString : $0.name }
                if !speaker.name.isEmpty { infos[index].name = speaker.name }
            }
        }
        return infos
    }

    func treatmentGraphConfiguration() -> UnifiedGraphConfiguration? {
        guard lifecycle.state == .running else { return nil }
        return nChannelTransportSession?.publishedGraphConfiguration
    }

    /// Stages a design. Idle: for the next start. Running: the graph takes the new stage through the stored-stage republish,
    /// which goes through `graphRebuilt` first (E19 G27), so the switch is off and the delta held until a re-arm (G23).
    func stageTreatment(_ stage: UnifiedGraphMIMOStage, configuration: UnifiedGraphConfiguration) throws {
        guard let session = nChannelTransportSession, lifecycle.state == .running else {
            try stageMIMOTreatment(stage)
            return
        }
        mimoGraphTreatment.graphRebuilt()
        mimoGraphTreatment.stage(stage)
        do {
            try session.applyMIMOStage(mimoGraphTreatment.stage ?? stage)
        } catch {
            mimoGraphTreatment.stage(nil)
            throw error
        }
        mimoGraphTreatment.chainDigest = MIMOGraphTreatment.chainDigest(of: configuration)
        startMIMOPoll()
    }

    func issueTreatmentPermit(
        verification: MIMOTreatmentVerificationResult?, acceptance: MIMORoomTreatmentHardwareAcceptance?
    ) -> Result<MIMOGraphTreatment.Permit, MIMOTreatmentPermitRefusal> {
        refreshMIMOVideoLatencyInput()
        return issueMIMOTreatmentPermit(verification: verification, acceptance: acceptance)
    }

    func requestTreatmentArm() async throws {
        refreshMIMOVideoLatencyInput()
        try await requestMIMOTreatmentArm()
    }

    func disarmTreatment() { disarmMIMOTreatment() }

    func treatmentReadback() -> n60_mimo_readback? { nChannelTransportSession?.peekMIMOReadback() }

    func treatmentRouting() -> SpeakerRoutingConfiguration? { speakerRoutingConfiguration }

    /// The engine holds no captures: the Room Treatment controller reads them from the seat flow's store (E19 S10b, G36).
    func treatmentWayCaptures() -> [MIMORoutedWayCapture] { [] }

    func setTreatmentSupportOverrides(_ overrides: [UUID: ClosedRange<Double>]) {
        mimoGraphTreatment.routedSupportOverrides = overrides
    }

    /// No production source of hardware acceptance records exists before E22 (bench), so none is offered.
    func hardwareAcceptance() -> MIMORoomTreatmentHardwareAcceptance? { nil }
}
