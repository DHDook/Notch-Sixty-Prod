import Foundation

/// E19 S12b (D11): drives the probe's measurement sequence and holds its captures. The capture itself (the E24 stimulus played
/// through the armed stage, programme stopped) is behind `TreatmentProbeCapturing`; the probe's authority, limits and gates are
/// `MIMOGraphTreatment`'s. Order (SQ5): an untreated control capture at every seat first, then one user-armed pass over the
/// seats with the stage armed, then the SQ5 evaluation. Control plane, main actor. Nothing here arms except through `armProbe`,
/// which is the engine's user-action path with every gate.
@MainActor
protocol TreatmentProbeCapturing: AnyObject {
    /// Stops (or restores) programme playback for the measurement. Throws when it cannot.
    func setProgrammeStopped(_ stopped: Bool) throws
    /// One capture of every source at the seat: with the stage unarmed (control) or armed (treated).
    func capture(seatID: UUID, treated: Bool) async throws -> [MultichannelCalibrationMeasurement]
}

enum MIMOTreatmentProbeRunnerError: Error, Equatable, LocalizedError {
    case captureUnavailable
    case noTicket
    case notReady(String)
    case probeEnded(MIMOTreatmentProbeEnd)

    var errorDescription: String? {
        switch self {
        case .captureUnavailable: return "The treated measurement cannot capture yet: the stimulus path through the armed stage is not available."
        case .noTicket: return "The treated measurement is not approved: its checks have not passed."
        case .notReady(let why): return why
        case .probeEnded(let end): return end.reason
        }
    }
}

@MainActor
final class MIMOTreatmentProbeRunner: ObservableObject {
    private let treatment: MIMOGraphTreatment
    private let capturer: TreatmentProbeCapturing?
    private let armProbe: () async throws -> Void

    /// Untreated captures (stage unarmed) and treated captures (probe armed), in memory only; the permit flow reads the treated
    /// ones through `MIMOTreatmentController`'s treated provider.
    private(set) var controlMeasurements: [MultichannelCalibrationMeasurement] = []
    private(set) var treatedMeasurements: [MultichannelCalibrationMeasurement] = []
    @Published private(set) var latestResult: MIMOTreatmentProbeResult?
    @Published private(set) var message: String?

    init(treatment: MIMOGraphTreatment, capturer: TreatmentProbeCapturing?, armProbe: @escaping () async throws -> Void) {
        self.treatment = treatment
        self.capturer = capturer
        self.armProbe = armProbe
    }

    private func ticketSeats() throws -> [UUID] {
        guard let session = treatment.probeSession, session.isLive else { throw MIMOTreatmentProbeRunnerError.noTicket }
        return session.ticket.seatIDs
    }

    /// Step 1: the untreated control capture at every seat. Stage unarmed; nothing arms.
    func captureControls() async throws {
        let seats = try ticketSeats()
        guard let capturer else { throw MIMOTreatmentProbeRunnerError.captureUnavailable }
        controlMeasurements = []
        treatedMeasurements = []
        latestResult = nil
        do {
            try capturer.setProgrammeStopped(true)
            defer { try? capturer.setProgrammeStopped(false) }
            for seat in seats {
                try Task.checkCancellation()
                controlMeasurements.append(contentsOf: try await capturer.capture(seatID: seat, treated: false))
            }
        } catch {
            message = error.localizedDescription
            throw error
        }
    }

    /// Step 2 (user action): arm the probe and take the treated capture at each seat in turn. The probe ends after the last seat,
    /// on the 120 s limit, a fault, a refusal or a fingerprint change; whichever happens, the stage is disarmed when this returns.
    func armAndMeasureTreated() async throws {
        let seats = try ticketSeats()
        guard let capturer else { throw MIMOTreatmentProbeRunnerError.captureUnavailable }
        guard Set(controlMeasurements.map(\.seatID)) == Set(seats) else {
            throw MIMOTreatmentProbeRunnerError.notReady("Take the untreated check at every seat first.")
        }
        treatedMeasurements = []
        var cleanupFailure: String?
        do {
            try capturer.setProgrammeStopped(true)
            // The capturer owns `probeProgrammeMuted`: set once the stimulus is installed, cleared before it is removed.
            defer {
                do { try capturer.setProgrammeStopped(false) } catch {
                    cleanupFailure = "The measurement signal could not be removed (\(error.localizedDescription)); restart the audio engine to restore programme audio."
                }
            }
            try await armProbe()
            for seat in seats {
                try Task.checkCancellation()
                let captured = try await capturer.capture(seatID: seat, treated: true)
                // A probe that ended during the capture (limit, fault, change) makes this capture invalid.
                guard let session = treatment.probeSession, session.isLive, session.armed else {
                    throw MIMOTreatmentProbeRunnerError.probeEnded(treatment.probeSession?.end ?? .userStopped)
                }
                treatedMeasurements.append(contentsOf: captured)
                treatment.probeSeatCaptured(seat)
            }
        } catch {
            treatment.stopProbe()
            message = [error.localizedDescription, cleanupFailure].compactMap { $0 }.joined(separator: " ")
            throw error
        }
        message = cleanupFailure
    }

    /// Step 3: judges SQ5 on the ended probe. `baseline` and `predicted` are the design's per-seat responses (summed over the
    /// sources, at the device rate).
    @discardableResult
    func evaluate(baseline: [UUID: [Float]], predicted: [UUID: [Float]], sampleRate: Double) -> MIMOTreatmentProbeResult? {
        guard let session = treatment.probeSession else { return nil }
        func summed(_ list: [MultichannelCalibrationMeasurement], _ seat: UUID) -> [Float] {
            MIMOTreatmentController.sum(list.filter { $0.seatID == seat }.map(\.channel.impulseResponse))
        }
        let seats = session.ticket.seatIDs.map {
            MIMOTreatmentProbeEvaluator.SeatResponses(
                seatID: $0, baseline: baseline[$0] ?? [], control: summed(controlMeasurements, $0),
                predictedTreated: predicted[$0] ?? [], measuredTreated: summed(treatedMeasurements, $0))
        }
        latestResult = treatment.probeResult(seats: seats, sampleRate: sampleRate)
        return latestResult
    }
}
