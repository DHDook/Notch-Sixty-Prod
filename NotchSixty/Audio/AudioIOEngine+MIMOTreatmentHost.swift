import Foundation

/// E19 S8: the engine's side of the Room Treatment screen (`MIMOTreatmentController`). Control plane, main actor. It stages
/// designs (live when the graph runs), reads the video latency mode from the installed room correction, holds the readback for
/// the screen and forwards Arm and Bypass. It never arms by itself: `requestMIMOTreatmentArm` keeps every gate and
/// `LiveTreatmentArm`.
extension AudioIOEngine: MIMOTreatmentHost {
    var treatment: MIMOGraphTreatment { mimoGraphTreatment }

    var sampleRate: Double? { nChannelTransportSession?.outputFormat.sampleRate }

    /// E19 G30: the room-correction latency mode as the treatment sees it. Video mode (minimum phase) refuses; a correction
    /// without a lane plan has no stated mode, so it stays `.unknown` and no permit is issued.
    static func videoLatencyInput(for room: RoomCorrectionConfiguration) -> MIMOVideoLatencyInput {
        guard room.enabled else { return .known(videoLatencyMode: false) }
        guard let design = room.lanes?.design else { return .unknown }
        return .known(videoLatencyMode: design.latencyMode == .video)
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

    /// No production source of hardware acceptance records exists before E22 (bench), so none is offered.
    func hardwareAcceptance() -> MIMORoomTreatmentHardwareAcceptance? { nil }
}
