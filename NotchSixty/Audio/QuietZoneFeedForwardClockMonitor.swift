import Foundation

/// Core Audio clock continuity is diagnostic only: neither ADC/DAC
/// conversion latency nor acoustic cancellation is established here.
enum QuietZoneFeedForwardClockFault: Error, Equatable, LocalizedError {
    case mismatchedRoute, invalidTimestamp, stalledClock, clockJump
    case excessiveDrift, staleWitness, stopped

    var errorDescription: String? {
        switch self {
        case .mismatchedRoute: return "DAC, route lease, microphone or rate changed."
        case .invalidTimestamp: return "Input/output observations are not on a valid monotonic timebase."
        case .stalledClock: return "A sample clock stopped or reversed."
        case .clockJump: return "A sample-frame counter jumped relative to host time."
        case .excessiveDrift: return "Input and output clocks drift beyond the tested tolerance."
        case .staleWitness: return "The recent input/output clock witnesses have expired."
        case .stopped: return "Clock monitoring permanently stopped after a fault."
        }
    }
}

struct QuietZoneFeedForwardClockStatus: Sendable {
    let inputRateHz: Double
    let outputRateHz: Double
    let relativeDriftPPM: Double
    let latestInputAtSeconds: Double
    let latestOutputAtSeconds: Double
    let observationCount: Int
    let firstFault: QuietZoneFeedForwardClockFault?
    let physicalLatencyVerified: Bool = false
    let liveANCQualified: Bool = false
}

/// Strictly single-owner CONTROL-plane clock watchdog; never call from
/// Core Audio's realtime callback. Uses PR97's two-second qualified trace.
final class QuietZoneFeedForwardClockMonitor {
    static let maximumCallbackGapSeconds = 0.5
    static let maximumWitnessAgeSeconds = 0.10
    static let maximumPairSkewSeconds = 0.05
    static let maximumResidualSeconds = 0.0005
    static let maximumRetainedObservations = 4_096

    private let rig: QuietZoneHardwareCalibrationRig
    private let initialRoute: QuietZoneHardwareClockRouteLease
    private var input: [QuietZoneHALClockObservation]
    private var output: [QuietZoneHALClockObservation]
    private var health: QuietZoneHALClockHealth
    private(set) var firstFault: QuietZoneFeedForwardClockFault?

    init(
        rig: QuietZoneHardwareCalibrationRig,
        route: QuietZoneHardwareClockRouteLease,
        initialTrace: QuietZoneHALClockTrace,
        now: Double
    ) throws {
        guard route.permits(
            outputID: rig.outputDeviceID,
            routeID: rig.routeID,
            sampleRate: rig.sampleRate
        ), initialTrace.inputDeviceID == rig.microphoneID,
           initialTrace.outputDeviceID == rig.outputDeviceID,
           initialTrace.nominalSampleRate.isFinite,
           abs(initialTrace.nominalSampleRate - rig.sampleRate) < 0.5
        else { throw QuietZoneFeedForwardClockFault.mismatchedRoute }
        let result: QuietZoneHALClockHealth
        do { result = try QuietZoneHALClockAnalyzer().analyze(initialTrace) }
        catch { throw QuietZoneFeedForwardClockFault.invalidTimestamp }
        guard let a = initialTrace.inputObservations.last?.hostTimeSeconds,
              let b = initialTrace.outputObservations.last?.hostTimeSeconds,
              now.isFinite, now >= a, now >= b,
              now - a <= Self.maximumWitnessAgeSeconds,
              now - b <= Self.maximumWitnessAgeSeconds,
              abs(a - b) <= Self.maximumPairSkewSeconds
        else { throw QuietZoneFeedForwardClockFault.staleWitness }
        self.rig = rig
        initialRoute = route
        input = initialTrace.inputObservations
        output = initialTrace.outputObservations
        health = result
    }

    private func halt(_ reason: QuietZoneFeedForwardClockFault)
        -> QuietZoneFeedForwardClockFault {
        if firstFault == nil { firstFault = reason }
        return firstFault!
    }

    func terminate() {
        if firstFault == nil { firstFault = .stopped }
    }

    /// Each update must contain actual *concurrently running* input and
    /// output callback observations translated to common host seconds.
    /// Never silently rebaseline after a rate change or device restart.
    func observe(
        input newInput: QuietZoneHALClockObservation,
        output newOutput: QuietZoneHALClockObservation,
        route: QuietZoneHardwareClockRouteLease,
        now: Double
    ) throws -> QuietZoneFeedForwardClockStatus {
        if firstFault != nil { throw QuietZoneFeedForwardClockFault.stopped }
        guard route == initialRoute,
              route.permits(
                outputID: rig.outputDeviceID,
                routeID: rig.routeID,
                sampleRate: rig.sampleRate
              )
        else { throw halt(.mismatchedRoute) }
        guard let oldInput = input.last, let oldOutput = output.last,
              now.isFinite,
              [newInput.hostTimeSeconds, newInput.sampleFrame,
               newOutput.hostTimeSeconds, newOutput.sampleFrame]
                .allSatisfy({ $0.isFinite && $0 >= 0 }),
              newInput.hostTimeSeconds <= now,
              newOutput.hostTimeSeconds <= now,
              abs(newInput.hostTimeSeconds - newOutput.hostTimeSeconds)
                <= Self.maximumPairSkewSeconds
        else { throw halt(.invalidTimestamp) }
        guard newInput.hostTimeSeconds > oldInput.hostTimeSeconds,
              newOutput.hostTimeSeconds > oldOutput.hostTimeSeconds,
              newInput.sampleFrame > oldInput.sampleFrame,
              newOutput.sampleFrame > oldOutput.sampleFrame
        else { throw halt(.stalledClock) }
        let dtInput = newInput.hostTimeSeconds - oldInput.hostTimeSeconds
        let dtOutput = newOutput.hostTimeSeconds - oldOutput.hostTimeSeconds
        guard dtInput <= Self.maximumCallbackGapSeconds,
              dtOutput <= Self.maximumCallbackGapSeconds,
              now - newInput.hostTimeSeconds <= Self.maximumWitnessAgeSeconds,
              now - newOutput.hostTimeSeconds <= Self.maximumWitnessAgeSeconds
        else { throw halt(.staleWitness) }
        let inputError = abs(
            (newInput.sampleFrame - oldInput.sampleFrame)
            / health.measuredInputRateHz - dtInput
        )
        let outputError = abs(
            (newOutput.sampleFrame - oldOutput.sampleFrame)
            / health.measuredOutputRateHz - dtOutput
        )
        guard inputError.isFinite, outputError.isFinite,
              inputError <= Self.maximumResidualSeconds,
              outputError <= Self.maximumResidualSeconds
        else { throw halt(.clockJump) }

        // Bounded, overlapping >=2-second window for ongoing drift testing.
        // This is not a physical source/DAC timestamp calibration.
        input.append(newInput)
        output.append(newOutput)
        let cutoff = min(newInput.hostTimeSeconds, newOutput.hostTimeSeconds) - 3
        while input.count > 9 && input[1].hostTimeSeconds < cutoff {
            input.removeFirst()
        }
        while output.count > 9 && output[1].hostTimeSeconds < cutoff {
            output.removeFirst()
        }
        guard input.count <= Self.maximumRetainedObservations,
              output.count <= Self.maximumRetainedObservations
        else { throw halt(.staleWitness) }
        let trace = QuietZoneHALClockTrace(
            inputDeviceID: rig.microphoneID, outputDeviceID: rig.outputDeviceID,
            nominalSampleRate: rig.sampleRate,
            inputObservations: input, outputObservations: output
        )
        do {
            health = try QuietZoneHALClockAnalyzer().analyze(trace)
        } catch QuietZoneHALClockError.excessiveDrift {
            throw halt(.excessiveDrift)
        } catch {
            throw halt(.clockJump)
        }
        return status()
    }

    func requireFresh(
        route: QuietZoneHardwareClockRouteLease,
        now: Double
    ) throws {
        if firstFault != nil { throw QuietZoneFeedForwardClockFault.stopped }
        guard route == initialRoute else { throw halt(.mismatchedRoute) }
        guard let a = input.last?.hostTimeSeconds,
              let b = output.last?.hostTimeSeconds,
              now.isFinite, now >= a, now >= b,
              now - a <= Self.maximumWitnessAgeSeconds,
              now - b <= Self.maximumWitnessAgeSeconds
        else { throw halt(.staleWitness) }
    }

    /// Bind individual scheduled sample frames to the same qualified
    /// input and output timebases, not merely to unrelated healthy traces.
    /// Absolute acoustic/ADC delay still needs external instrument review.
    func requireFrameMapping(
        referenceFrame: Double,
        acousticHostSeconds: Double,
        outputFrame: Double,
        outputHostSeconds: Double
    ) throws {
        if firstFault != nil { throw QuietZoneFeedForwardClockFault.stopped }
        guard let a = input.last, let b = output.last,
              referenceFrame.isFinite, referenceFrame >= 0,
              outputFrame.isFinite, outputFrame >= 0,
              acousticHostSeconds.isFinite, acousticHostSeconds >= 0,
              outputHostSeconds.isFinite, outputHostSeconds >= 0
        else { throw halt(.invalidTimestamp) }
        let referenceAt = a.hostTimeSeconds +
            (referenceFrame - a.sampleFrame) / health.measuredInputRateHz
        let outputAt = b.hostTimeSeconds +
            (outputFrame - b.sampleFrame) / health.measuredOutputRateHz
        guard referenceAt.isFinite, outputAt.isFinite,
              abs(referenceAt - acousticHostSeconds) <= 0.002,
              abs(outputAt - outputHostSeconds) <=
                Self.maximumResidualSeconds
        else { throw halt(.clockJump) }
    }

    func status() -> QuietZoneFeedForwardClockStatus {
        .init(
            inputRateHz: health.measuredInputRateHz,
            outputRateHz: health.measuredOutputRateHz,
            relativeDriftPPM: health.relativeDriftPPM,
            latestInputAtSeconds: input.last?.hostTimeSeconds ?? 0,
            latestOutputAtSeconds: output.last?.hostTimeSeconds ?? 0,
            observationCount: min(input.count, output.count),
            firstFault: firstFault
        )
    }
}

/// A **new guarded entry point** to PR98's disconnected native transport.
/// Cannot schedule a frame without a fresh PR97-qualified clock watchdog.
final class QuietZoneClockGuardedShadowTransport {
    private let watchdog: QuietZoneFeedForwardClockMonitor
    private let shadow: QuietZoneNativeShadowTimingTransport

    init(
        plan: QuietZoneFeedForwardSchedulingPlan,
        candidate: QuietZoneCausalFIRCandidate,
        initialTrace: QuietZoneHALClockTrace,
        route: QuietZoneHardwareClockRouteLease,
        routeLeaseToken: UInt64,
        synchronizedClockToken: UInt64,
        now: Double
    ) throws {
        watchdog = try .init(
            rig: plan.rig, route: route, initialTrace: initialTrace, now: now
        )
        shadow = try .init(
            plan: plan, candidate: candidate,
            routeLeaseToken: routeLeaseToken,
            synchronizedClockToken: synchronizedClockToken
        )
    }

    func observe(
        input: QuietZoneHALClockObservation,
        output: QuietZoneHALClockObservation,
        route: QuietZoneHardwareClockRouteLease,
        now: Double
    ) throws -> QuietZoneFeedForwardClockStatus {
        do {
            return try watchdog.observe(
                input: input, output: output, route: route, now: now
            )
        } catch {
            shadow.stopForClockFault()
            throw error
        }
    }

    func ingest(
        referenceFrame: N60FeedForwardReferenceFrame,
        witnessed: QuietZoneFeedForwardReferenceDeadlineEvent,
        output: N60FFDeadlineOutputWitness,
        route: QuietZoneHardwareClockRouteLease
    ) throws {
        do {
            try watchdog.requireFresh(
                route: route, now: witnessed.evaluatedAtHostSeconds
            )
            try watchdog.requireFrameMapping(
                referenceFrame: referenceFrame.firstFrameSampleTime
                    + Double(referenceFrame.frameOffset),
                acousticHostSeconds: witnessed.referenceAcousticHostSeconds,
                outputFrame: output.firstFrame,
                outputHostSeconds: output.firstFrameHostSeconds
            )
            _ = try shadow.ingest(
                referenceFrame: referenceFrame,
                witnessed: witnessed, output: output
            )
        } catch {
            shadow.stopForClockFault()
            throw error
        }
    }

    func status() -> QuietZoneFeedForwardClockStatus { watchdog.status() }
    func snapshot() -> N60FFDeadlineSnapshot { shadow.snapshot() }
    func readDiagnostics() -> [N60FFDeadlineRecord] {
        shadow.readDiagnostics()
    }
    func close() {
        watchdog.terminate()
        shadow.close()
    }
    var outputConnected: Bool { false }
    var liveANCQualified: Bool { false }
}
