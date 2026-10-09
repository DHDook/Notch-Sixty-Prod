import Foundation

/// PR97 commissioning evidence is diagnostic ONLY. A local Boolean claiming
/// "instrumentedHardware" is not independent physical attestation.
enum QuietZoneCommissioningGate: String, CaseIterable, Sendable {
    case selectedOutput, halClocks, wiredLoopback, movableMicrophoneSurvey
    case referenceADC, processing, outputDAC, speakerToSeat
    case causalBudget, independentHardwareReview, acousticAcceptance

    var title: String {
        switch self {
        case .selectedOutput: return "Physical stereo output and session lease"
        case .halClocks: return "Simultaneous input/output HAL clocks"
        case .wiredLoopback: return "Three independent electrical loopbacks"
        case .movableMicrophoneSurvey: return "Listener → doorway → listener"
        case .referenceADC: return "Reference microphone acquisition"
        case .processing: return "DSP processing and scheduling"
        case .outputDAC: return "Physical DAC command-to-output"
        case .speakerToSeat: return "Speaker-to-seat acoustic delay"
        case .causalBudget: return "Conservative causal timing budget"
        case .independentHardwareReview: return "Independent hardware evidence review"
        case .acousticAcceptance: return "Measured ANC attenuation and stability"
        }
    }

    var latencyStage: QuietZonePhysicalLatencyStage? {
        switch self {
        case .referenceADC: return .referenceADC
        case .processing: return .referenceProcessing
        case .outputDAC: return .outputDAC
        case .speakerToSeat: return .speakerToSeat
        default: return nil
        }
    }
}

enum QuietZoneCommissioningStatus: String, Sendable {
    case missing, capturedUnverified, invalid, physicalVerificationRequired

    var caption: String {
        switch self {
        case .missing: return "Not measured"
        case .capturedUnverified: return "Recorded · unverified"
        case .invalid: return "Invalid · recapture"
        case .physicalVerificationRequired: return "Hardware review required"
        }
    }
}

struct QuietZoneCommissioningItem: Identifiable, Sendable {
    let gate: QuietZoneCommissioningGate
    let status: QuietZoneCommissioningStatus
    let explanation: String
    var id: QuietZoneCommissioningGate { gate }
}

struct QuietZoneCommissioningChecklist: Sendable {
    let items: [QuietZoneCommissioningItem]
    let conservativeReserveSeconds: Double?
    let causalReadiness: QuietZoneFeedForwardReadiness?
    let liveANCQualified: Bool = false
    let hardwareVerified: Bool = false
    let outputConnected: Bool = false

    func item(_ gate: QuietZoneCommissioningGate) -> QuietZoneCommissioningItem? {
        items.first(where: { $0.gate == gate })
    }
}

struct QuietZoneHardwareCommissioningEvaluator: Sendable {
    private func entry(
        _ gate: QuietZoneCommissioningGate,
        _ status: QuietZoneCommissioningStatus,
        _ explanation: String
    ) -> QuietZoneCommissioningItem {
        .init(gate: gate, status: status, explanation: explanation)
    }

    /// Persisted v1 plans are NOT a record of live output, loopback or four
    /// independent latency components, even if timingPath was populated.
    func preview(
        calibration: QuietZoneFeedForwardCalibration?
    ) -> QuietZoneCommissioningChecklist {
        let clock: QuietZoneCommissioningStatus
        if let trace = calibration?.halClockTrace {
            clock = trace.inputDeviceID == calibration?.microphoneStableID
                && (try? QuietZoneHALClockAnalyzer().analyze(trace)) != nil
                ? .capturedUnverified : .invalid
        } else {
            clock = .missing
        }
        let survey: QuietZoneCommissioningStatus
        if let calibration, calibration.arrivals.count == 3 {
            survey = validSurvey(
                calibration.arrivals, microphoneID: calibration.microphoneStableID
            ) ? .capturedUnverified : .invalid
        } else {
            survey = .missing
        }
        let rows = QuietZoneCommissioningGate.allCases.map { gate in
            switch gate {
            case .halClocks:
                return entry(gate, clock,
                    "Saved HAL clock evidence still needs active-route verification.")
            case .movableMicrophoneSurvey:
                return entry(gate, survey,
                    "Each source launch and clock sync needs physical verification.")
            case .independentHardwareReview:
                return entry(gate, .physicalVerificationRequired,
                    "External source calibration and all endpoint corrections remain unverified.")
            case .acousticAcceptance:
                return entry(gate, .physicalVerificationRequired,
                    "No noise-attenuation, coherence or stability acceptance exists yet.")
            default:
                return entry(gate, .missing,
                    "Required physical evidence is not available from a saved plan.")
            }
        }
        return .init(items: rows, conservativeReserveSeconds: nil,
                     causalReadiness: nil)
    }

    /// Reports actual in-memory staged observations and exact route identity,
    /// but never treats user-supplied hardware provenance flags as attestation.
    func assess(
        session: QuietZoneHardwareCalibrationSession,
        run: QuietZonePhysicalLatencyMeasurementRun?,
        currentOutput: QuietZoneHardwareHALClockAcquisition.Route?,
        plan: QuietZoneFeedForwardCalibration?,
        project: RoomCorrectionProject?,
        now: Date = Date()
    ) -> QuietZoneCommissioningChecklist {
        let rig = session.rig
        let elapsed = now.timeIntervalSince(session.startedAt)
        let fresh = elapsed.isFinite && elapsed >= 0
            && elapsed <= QuietZoneHardwareCalibrationSession.maximumSessionSeconds
        let sameRun = run?.rig == rig && run?.startedAt == session.startedAt
        let observedStages: [QuietZonePhysicalLatencyEvidence]?
        if fresh, sameRun, let run, run.isComplete {
            observedStages = try? run.measurements(now: now)
        } else {
            observedStages = nil
        }
        let physicalBudget: QuietZonePhysicalLatencyReport?
        if fresh, let run, sameRun, observedStages != nil,
           let plan, let project {
            physicalBudget = try? session.evaluateInstrumentedLatencyRun(
                run, plan: plan, project: project, now: now
            )
        } else {
            physicalBudget = nil
        }

        let rows = QuietZoneCommissioningGate.allCases.map { gate in
            switch gate {
            case .selectedOutput:
                guard let route = currentOutput else {
                    return entry(gate, .missing,
                        "The selected running physical speaker output is unavailable.")
                }
                let matches = route.outputID == rig.outputDeviceID
                    && route.routeID == rig.routeID
                    && route.sampleRate.isFinite
                    && abs(route.sampleRate - rig.sampleRate) < 0.5
                return entry(gate,
                    matches && fresh ? .capturedUnverified : .invalid,
                    "A different output session, device or rate invalidates this calibration.")
            case .halClocks:
                guard let trace = session.clockTrace else {
                    return entry(gate, .missing, "Observe the input and output clocks together.")
                }
                let valid = fresh
                    && trace.inputDeviceID == rig.microphoneID
                    && trace.outputDeviceID == rig.outputDeviceID
                    && abs(trace.nominalSampleRate - rig.sampleRate) < 0.5
                    && (try? QuietZoneHALClockAnalyzer().analyze(trace)) != nil
                return entry(gate, valid ? .capturedUnverified : .invalid,
                    "HAL drift evidence is not electrical or acoustic latency.")
            case .wiredLoopback:
                guard let result = session.loopback else {
                    return entry(gate, .missing, "Record three independent wired loopbacks.")
                }
                let valid = fresh && result.validatedForElectricalBench
                    && result.routeFingerprint == rig.routeID
                    && result.repetitions >= 3
                    && result.electricalRoundTripSeconds.isFinite
                    && result.conservativeUpperBoundSeconds.isFinite
                    && result.conservativeUpperBoundSeconds
                        >= result.electricalRoundTripSeconds
                return entry(gate, valid ? .capturedUnverified : .invalid,
                    "Electrical round-trip must never replace speaker-to-seat flight time.")
            case .movableMicrophoneSurvey:
                let arrivals = session.arrivals
                guard !arrivals.isEmpty else {
                    return entry(gate, .missing, "Capture listener, upstream, listener-return.")
                }
                guard arrivals.count == 3 else {
                    return entry(gate, .missing, "\(arrivals.count) of 3 positions captured.")
                }
                let valid = fresh && validSurvey(
                    arrivals, microphoneID: rig.microphoneID
                ) && arrivals.allSatisfy {
                    $0.synchronizedClockID == rig.clockID
                        && $0.routeFingerprint == rig.routeID
                        && $0.microphoneChannel == rig.microphoneChannel
                        && abs($0.sampleRate - rig.sampleRate) < 0.5
                }
                return entry(gate, valid ? .capturedUnverified : .invalid,
                    "Physical source and emission clock still need independent review.")
            case .referenceADC, .processing, .outputDAC, .speakerToSeat:
                guard let stage = gate.latencyStage, let run else {
                    return entry(gate, .missing,
                        "Record three independent physical start/end timestamp pairs.")
                }
                guard sameRun && fresh else {
                    return entry(gate, .invalid,
                        "The measurement run is stale or tied to a different route lease.")
                }
                let count = run.count(stage)
                guard count >= 3 else {
                    return entry(gate, .missing, "\(count) of 3 repetitions recorded.")
                }
                if run.isComplete && observedStages == nil {
                    return entry(gate, .invalid,
                        "Completed repetition set failed the validation checks.")
                }
                return entry(gate, .capturedUnverified,
                    "\(count) repetitions assembled; physical endpoint provenance unverified.")
            case .causalBudget:
                if let physicalBudget {
                    return entry(gate,
                        physicalBudget.readiness == .physicallyPlausible
                            ? .capturedUnverified : .invalid,
                        String(format: "Conservative timing reserve %.3f ms; not cancellation proof.",
                               physicalBudget.conservativeReserveSeconds * 1000))
                }
                if run?.isComplete == true && plan != nil && project != nil {
                    return entry(gate, .invalid,
                        "The full measurement sequence did not qualify the causal budget.")
                }
                return entry(gate, .missing,
                    "Needs a valid A/B/A survey and four separately measured latency stages.")
            case .independentHardwareReview:
                return entry(gate, .physicalVerificationRequired,
                    "An independently calibrated instrument must substantiate timestamps, source and corrections.")
            case .acousticAcceptance:
                return entry(gate, .physicalVerificationRequired,
                    "Verify measured attenuation, coherence and stability at the listener before live ANC.")
            }
        }
        return .init(items: rows,
            conservativeReserveSeconds: physicalBudget?.conservativeReserveSeconds,
            causalReadiness: physicalBudget?.readiness)
    }

    private func validSurvey(
        _ captures: [QuietZoneFeedForwardArrival],
        microphoneID: String
    ) -> Bool {
        guard captures.count == 3,
              captures.map(\.position) == [
                .listenerFirst, .upstream, .listenerReturn
              ] else { return false }
        let first = captures[0]
        guard !first.sourceTriggerID.isEmpty,
              !first.synchronizedClockID.isEmpty,
              !first.routeFingerprint.isEmpty,
              first.sampleRate.isFinite else { return false }
        for capture in captures {
            guard capture.sourceTriggerID == first.sourceTriggerID,
                  capture.synchronizedClockID == first.synchronizedClockID,
                  capture.routeFingerprint == first.routeFingerprint,
                  capture.sampleRate.isFinite,
                  abs(capture.sampleRate - first.sampleRate) < 0.5,
                  capture.microphoneDeviceID == microphoneID,
                  capture.microphoneChannel == first.microphoneChannel,
                  capture.arrivalAfterTriggerSeconds.isFinite,
                  (0...2).contains(capture.arrivalAfterTriggerSeconds),
                  capture.oneSigmaTimingUncertaintySeconds.isFinite,
                  (0...QuietZoneFeedForwardBudgetAnalyzer.maximumArrivalUncertaintySeconds)
                      .contains(capture.oneSigmaTimingUncertaintySeconds),
                  capture.snrDB.isFinite,
                  capture.snrDB >= QuietZoneFeedForwardBudgetAnalyzer.minimumSNRDB,
                  !capture.clipped
            else { return false }
        }
        return abs(captures[0].arrivalAfterTriggerSeconds
                       - captures[2].arrivalAfterTriggerSeconds)
            <= QuietZoneFeedForwardBudgetAnalyzer.maximumListenerRepeatDifferenceSeconds
    }
}
