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
