import Foundation

/// E19 S12b (D11, D13): the probe arm of `MIMOGraphTreatment`. See `MIMOTreatmentProbe.swift` for the rules. The ticket is the
/// only authority a probe arm has, it is one-shot, and it is never turned into a permit. Control plane, main actor.
extension MIMOGraphTreatment {
    /// Issues the one-shot ticket, or refuses with every reason. Needs both flags, a known latency mode that is off, a staged
    /// design on a running engine with the stage attached and the hard limit present, and SQ1 to SQ4 passing on the evidence.
    /// Never arms.
    @discardableResult
    func issueProbeTicket(
        context: Context, videoLatency: MIMOVideoLatencyInput, evidence: MIMOTreatmentSelfQualificationEvidence,
        registry: MIMOTreatmentQualificationRegistry = .production
    ) -> Result<MIMOTreatmentProbeTicket, MIMOTreatmentProbeRefusal> {
        guard flags.isEnabled(.mimoTreatment), flags.isEnabled(.selfQualification) else { return .failure(.featureOff) }
        switch videoLatency {
        case .unknown: return .failure(.videoLatencyInputNotWired)
        case .known(let mode): if mode || context.videoLatencyMode { return .failure(.videoLatencyMode) }
        }
        guard let stage else { return .failure(.noStagedDesign) }
        guard context.engineRunning, context.stageAttached, context.hardLimitPresent, context.engineLeaseHeld else {
            return .failure(.engineNotReady)
        }
        if probeSession?.isLive == true { return .failure(.probeAlreadyActive) }
        let failures = MIMOTreatmentSelfQualification.evaluate(evidence, decimation: stage.filters.decimation, registry: registry)
        guard failures.isEmpty else { return .failure(.selfQualificationRefused(failures)) }
        selfQualificationEvidenceDigest = evidence.bindingDigest
        let ticket = MIMOTreatmentProbeTicket(
            fingerprint: currentFingerprint(stage, context, selfQualified: true), seatIDs: evidence.includedSeats.map(\.id),
            issuedAt: clock())
        probeSession = MIMOTreatmentProbeSession(ticket: ticket)
        return .success(ticket)
    }

    /// The gates of a probe arm: every shared gate, then a live unarmed ticket whose fingerprint still matches, then programme
    /// stopped. The flag `e19.self-qualification` must still be on.
    func probeGateFailure(_ context: Context) -> ArmRefusal? {
        if let common = commonGateFailure(context) { return common }
        guard flags.isEnabled(.selfQualification), let session = probeSession, session.isLive, !session.armed,
              let stage else { return .noProbeTicket }
        guard session.ticket.fingerprint == currentFingerprint(stage, context, selfQualified: true) else { return .fingerprintMismatch }
        guard probeProgrammeMuted else { return .programmeNotStopped }
        return nil
    }

    /// The user action that starts the probe's fade-in. Nothing else calls it.
    func requestProbeArm(context: Context, refresh: (() -> Context)? = nil) async throws {
        try await armStage(context: context, refresh: refresh, probe: true)
    }

    /// The seat now being measured and the time it has left. Called by `armStage` once the arm word is written.
    func probeArmed() {
        guard var session = probeSession else { return }
        session.armed = true
        session.activeSeat = session.ticket.seatIDs.first(where: { !session.completedSeats.contains($0) })
        session.seatDeadline = session.activeSeat == nil ? nil : clock().addingTimeInterval(MIMOTreatmentProbeLimits.secondsPerSeat)
        probeSession = session
    }

    /// The treated capture at the active seat is stored. The probe moves to the next seat (new 120 s) or, after the last seat,
    /// ends and disarms with the normal fade.
    func probeSeatCaptured(_ seatID: UUID) {
        guard var session = probeSession, session.isLive, session.armed, session.activeSeat == seatID else { return }
        session.completedSeats.append(seatID)
        if let next = session.ticket.seatIDs.first(where: { !session.completedSeats.contains($0) }) {
            session.activeSeat = next
            session.seatDeadline = clock().addingTimeInterval(MIMOTreatmentProbeLimits.secondsPerSeat)
            probeSession = session
        } else {
            probeSession = session
            probeEnd(.completed)
        }
    }

    /// Ends the probe: the ticket is spent (a new one needs SQ1 to SQ4 again), and an armed stage fades out normally.
    func probeEnd(_ reason: MIMOTreatmentProbeEnd) {
        guard var session = probeSession, session.isLive else { return }
        session.end = reason
        session.activeSeat = nil
        session.seatDeadline = nil
        probeSession = session
        if armedAsProbe, arm.isArmed { arm.disarm(.user) }
    }

    func stopProbe() { probeEnd(.userStopped) }

    /// Before the arm word is written: a changed fingerprint, a switched-off flag or a lost engine ends a waiting ticket.
    func probeObserveUnarmed(context: Context) {
        guard let session = probeSession, session.isLive, !arm.isArmed else { return }
        if !flags.isEnabled(.selfQualification) || !flags.isEnabled(.mimoTreatment) { probeEnd(.featureOff); return }
        guard let stage else { probeEnd(.fingerprintChanged); return }
        if currentFingerprint(stage, context, selfQualified: true) != session.ticket.fingerprint { probeEnd(.fingerprintChanged) }
    }

    /// While armed as a probe: the per-seat time limit, the monitor and the hard limit. True when it ended the probe.
    func probeObserveArmed(readback: n60_mimo_readback?, hardLimitGainReductionDB: Double?) -> Bool {
        guard var session = probeSession, session.isLive else { return false }
        if !flags.isEnabled(.selfQualification) { probeEnd(.featureOff); return true }
        if let readback, readback.faultLatched != 0 { session.faultSeen = true }
        if hardLimitGainReductionDB != nil, !session.hardLimitPrimed {
            session.hardLimitPrimed = true
        } else if let reduction = hardLimitGainReductionDB {
            session.hardLimitReadingSeen = true
            session.worstHardLimitReductionDB = max(session.worstHardLimitReductionDB, abs(reduction))
        }
        probeSession = session
        if session.faultSeen { arm.disarm(.treatmentFault); return true }
        if session.worstHardLimitReductionDB > MIMOTreatmentProbeLimits.hardLimitReductionToleranceDB {
            probeEnd(.hardLimitActed); return true
        }
        if let deadline = session.seatDeadline, let seat = session.activeSeat, clock() >= deadline {
            probeEnd(.timedOut(seat: seat)); return true
        }
        return false
    }

    /// Any disarm the probe did not cause itself ends it, with the cause.
    func probeDidDisarm(_ reason: LiveTreatmentDisarmReason) {
        guard var session = probeSession, session.isLive, armedAsProbe else { return }
        switch reason {
        case .treatmentFault: session.end = .faulted
        case .downstreamChainChanged: session.end = .fingerprintChanged
        case .featureSwitchedOff: session.end = .featureOff
        case .user: session.end = .userStopped
        default: session.end = .interrupted(reason)
        }
        session.activeSeat = nil
        session.seatDeadline = nil
        probeSession = session
    }

    /// The SQ5 result of an ended probe, bound to the fingerprint it was taken on. Nil while the probe is live.
    func probeResult(seats: [MIMOTreatmentProbeEvaluator.SeatResponses], sampleRate: Double) -> MIMOTreatmentProbeResult? {
        guard let session = probeSession, !session.isLive else { return nil }
        return MIMOTreatmentProbeResult(
            fingerprint: session.ticket.fingerprint,
            failures: MIMOTreatmentProbeEvaluator.evaluate(seats: seats, sampleRate: sampleRate, session: session))
    }
}
