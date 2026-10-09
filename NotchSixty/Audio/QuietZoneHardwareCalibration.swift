import Foundation

/// PR97 accepts instrumented evidence; it never starts HAL capture or emits audio.
struct QuietZoneHardwareCalibrationRig: Equatable, Sendable {
    let projectID: UUID
    let microphoneID: String
    let microphoneChannel: Int
    let outputDeviceID: String
    let routeID: String
    let sampleRate: Double
    let clockID: String
    let triggerID: String
}

enum QuietZoneHardwareCalibrationStep: Equatable, Sendable {
    case clock, electrical, listener, upstream, listenerReturn, physicalReview
}

enum QuietZoneHardwareCalibrationError: Error, Equatable {
    case invalidRig, invalidStep, wrongDevice, invalidClock, expired, incomplete
}

/// This diagnostic receipt cannot authorize live speaker output.
struct QuietZoneHardwareCalibrationReceipt: Sendable {
    let electricalRoundTripSeconds: Double
    let conservativeElectricalUpperBoundSeconds: Double
    let acousticPreviewSeconds: Double?
    let causalityReserveSeconds: Double?
    let timingReadiness: QuietZoneFeedForwardReadiness
    let liveANCQualified: Bool = false
    let acousticFlightTimeVerified: Bool = false
    let outputConnected: Bool = false
}

/// Strict sequence: simultaneous clocks -> independent electrical repetitions
/// -> listener/doorway/listener acoustic evidence -> physical review.
struct QuietZoneHardwareCalibrationSession: Sendable {
    static let maximumSessionSeconds: TimeInterval = 360
    let rig: QuietZoneHardwareCalibrationRig
    let startedAt: Date
    private(set) var clockTrace: QuietZoneHALClockTrace?
    private(set) var loopback: QuietZoneBenchLoopbackResult?
    private var survey: QuietZoneFeedForwardSurveySession
    private var usedPhysicalLaunchIDs: Set<String> = []
    private var physicalSourceID: String?

    init(rig: QuietZoneHardwareCalibrationRig, now: Date = Date()) throws {
        guard !rig.microphoneID.isEmpty, rig.microphoneChannel >= 0,
              !rig.outputDeviceID.isEmpty, !rig.routeID.isEmpty,
              !rig.clockID.isEmpty, !rig.triggerID.isEmpty,
              rig.sampleRate.isFinite, (8_000...192_000).contains(rig.sampleRate)
        else { throw QuietZoneHardwareCalibrationError.invalidRig }
        self.rig = rig
        startedAt = now
        survey = try QuietZoneFeedForwardSurveySession(
            projectID: rig.projectID, microphoneStableID: rig.microphoneID,
            microphoneChannel: rig.microphoneChannel,
            routeFingerprint: rig.routeID, clockID: rig.clockID,
            stimulusID: rig.triggerID, now: now
        )
    }

    var nextStep: QuietZoneHardwareCalibrationStep {
        if clockTrace == nil { return .clock }
        if loopback == nil { return .electrical }
        switch survey.nextStage {
        case .listener: return .listener
        case .upstream: return .upstream
        case .listenerReturn: return .listenerReturn
        case nil: return .physicalReview
        }
    }

    var arrivals: [QuietZoneFeedForwardArrival] { survey.arrivals }

    private func checkAge(_ now: Date) throws {
        let age = now.timeIntervalSince(startedAt)
        guard age.isFinite, age >= 0, age <= Self.maximumSessionSeconds else {
            throw QuietZoneHardwareCalibrationError.expired
        }
    }

    mutating func qualifyClock(
        _ trace: QuietZoneHALClockTrace, now: Date = Date()
    ) throws {
        try checkAge(now)
        guard nextStep == .clock else {
            throw QuietZoneHardwareCalibrationError.invalidStep
        }
        guard trace.inputDeviceID == rig.microphoneID,
              trace.outputDeviceID == rig.outputDeviceID,
              abs(trace.nominalSampleRate - rig.sampleRate) < 0.5
        else { throw QuietZoneHardwareCalibrationError.wrongDevice }
        do { _ = try QuietZoneHALClockAnalyzer().analyze(trace) }
        catch { throw QuietZoneHardwareCalibrationError.invalidClock }
        clockTrace = trace
    }

    mutating func qualifyLoopback(
        _ captures: [QuietZoneBenchLoopbackCapture], now: Date = Date()
    ) throws -> QuietZoneBenchLoopbackResult {
        try checkAge(now)
        guard nextStep == .electrical, let trace = clockTrace else {
            throw QuietZoneHardwareCalibrationError.invalidStep
        }
        guard captures.allSatisfy({
            $0.inputDeviceID == rig.microphoneID &&
            $0.outputDeviceID == rig.outputDeviceID &&
            $0.routeFingerprint == rig.routeID &&
            abs($0.nominalSampleRate - rig.sampleRate) < 0.5
        }) else { throw QuietZoneHardwareCalibrationError.wrongDevice }
        let measured = try QuietZoneBenchLoopbackAnalyzer()
            .analyze(captures, clock: trace)
        loopback = measured
        return measured
    }

    mutating func addAcousticCapture(
        _ capture: QuietZoneFeedForwardProbeCapture,
        projectID: UUID, now: Date = Date()
    ) throws -> QuietZoneFeedForwardArrival {
        try checkAge(now)
        guard loopback != nil else {
            throw QuietZoneHardwareCalibrationError.invalidStep
        }
        guard capture.sampleRate.isFinite,
              abs(capture.sampleRate - rig.sampleRate) < 0.5,
              capture.microphoneDeviceID == rig.microphoneID,
              capture.microphoneChannel == rig.microphoneChannel,
              capture.routeFingerprint == rig.routeID,
              capture.synchronizedClockID == rig.clockID,
              capture.sourceTriggerID == rig.triggerID
        else { throw QuietZoneHardwareCalibrationError.wrongDevice }
        var candidate = survey
        do {
            let value = try candidate.add(
                capture, projectID: projectID, capturedAt: now
            )
            survey = candidate
            return value
        } catch {
            // PR96 clears the full survey on a failed listener-return drift
            // check; preserve that invalidation instead of hiding it.
            if (error as? QuietZoneFeedForwardError) == .sourceDrift {
                survey = candidate
            }
            throw error
        }
    }

    /// PR97's instrumented ingestion endpoint. Unlike the lower-level PR96
    /// survey API, a real three-position run must present three different
    /// physical launches from the SAME calibrated external source fixture.
    mutating func addInstrumentedSourceCapture(
        _ capture: QuietZoneFeedForwardProbeCapture,
        launch: QuietZoneInstrumentedSourceLaunch,
        projectID: UUID,
        now: Date = Date()
    ) throws -> QuietZoneFeedForwardArrival {
        guard !launch.launchID.isEmpty,
              !usedPhysicalLaunchIDs.contains(launch.launchID) else {
            throw QuietZoneInstrumentedProbeError.replayedLaunch
        }
        guard launch.physicalClockCalibrationVerified,
              launch.oneSigmaTimingUncertaintySeconds.isFinite,
              (0...0.0005).contains(launch.oneSigmaTimingUncertaintySeconds)
        else { throw QuietZoneInstrumentedProbeError.uncalibratedTrigger }
        guard !launch.physicalSourceID.isEmpty,
              launch.sourceFixtureID == rig.triggerID,
              launch.synchronizedClockID == rig.clockID,
              launch.routeLeaseID == rig.routeID,
              launch.sampleRate.isFinite,
              abs(launch.sampleRate - rig.sampleRate) < 0.5,
              capture.sourceTriggerID == launch.sourceFixtureID,
              capture.synchronizedClockID == launch.synchronizedClockID,
              capture.routeFingerprint == launch.routeLeaseID,
              capture.emittedProbe == launch.emittedProbe,
              physicalSourceID.map({ $0 == launch.physicalSourceID }) ?? true
        else { throw QuietZoneInstrumentedProbeError.incompatibleSource }
        do {
            let arrival = try addAcousticCapture(
                capture, projectID: projectID, now: now
            )
            usedPhysicalLaunchIDs.insert(launch.launchID)
            physicalSourceID = launch.physicalSourceID
            return arrival
        } catch {
            if (error as? QuietZoneFeedForwardError) == .sourceDrift {
                usedPhysicalLaunchIDs.removeAll()
                physicalSourceID = nil
            }
            throw error
        }
    }

    /// Produces a physically decomposed timing-budget receipt only after
    /// the offline A/B/A survey and electrical bench sequence completed.
    /// It never turns an electrical round-trip number into an ADC/DAC or
    /// acoustic secondary-path measurement and never authorizes live ANC.
    func evaluatePhysicalLatency(
        plan: QuietZoneFeedForwardCalibration,
        project: RoomCorrectionProject,
        stages: [QuietZonePhysicalLatencyEvidence],
        now: Date = Date()
    ) throws -> QuietZonePhysicalLatencyReport {
        try checkAge(now)
        guard nextStep == .physicalReview,
              let trace = clockTrace, loopback != nil,
              plan.projectID == rig.projectID,
              project.id == rig.projectID else {
            throw QuietZoneHardwareCalibrationError.incomplete
        }
        var draft = plan
        draft.halClockTrace = trace
        let (committed, _) = try survey.committed(
            to: draft, project: project, now: now
        )
        return try QuietZonePhysicalLatencyBudgetAnalyzer().analyze(
            rig: rig, plan: committed, project: project,
            clock: trace, stages: stages,
            sessionStartedAt: startedAt, now: now
        )
    }

    /// Collect timestamp-differenced physical witnesses using the exact rig
    /// and refuse to build a causal timing estimate from an incomplete run.
    func evaluateInstrumentedLatencyRun(
        _ run: QuietZonePhysicalLatencyMeasurementRun,
        plan: QuietZoneFeedForwardCalibration,
        project: RoomCorrectionProject,
        now: Date = Date()
    ) throws -> QuietZonePhysicalLatencyReport {
        guard run.rig == rig, run.startedAt == startedAt else {
            throw QuietZoneHardwareCalibrationError.wrongDevice
        }
        return try evaluatePhysicalLatency(
            plan: plan, project: project,
            stages: run.measurements(now: now), now: now
        )
    }

    func report(
        plan: QuietZoneFeedForwardCalibration,
        project: RoomCorrectionProject,
        now: Date = Date()
    ) throws -> QuietZoneHardwareCalibrationReceipt {
        try checkAge(now)
        guard nextStep == .physicalReview,
              let trace = clockTrace, let measured = loopback,
              project.id == rig.projectID, plan.projectID == rig.projectID,
              plan.microphoneStableID == rig.microphoneID
        else { throw QuietZoneHardwareCalibrationError.incomplete }
        var draft = plan
        draft.halClockTrace = trace
        let (_, budget) = try survey.committed(
            to: draft, project: project, now: now
        )
        return QuietZoneHardwareCalibrationReceipt(
            electricalRoundTripSeconds: measured.electricalRoundTripSeconds,
            conservativeElectricalUpperBoundSeconds:
                measured.conservativeUpperBoundSeconds,
            acousticPreviewSeconds: budget.acousticPreviewSeconds,
            causalityReserveSeconds: budget.conservativeReserveSeconds,
            timingReadiness: budget.readiness
        )
    }
}
