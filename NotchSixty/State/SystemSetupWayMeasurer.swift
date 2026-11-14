import Foundation

// E19 S10b (G36): the way pass of the E24 seat flow. Each in-band way of a routed speaker is played alone (the Lab's protected
// excitation: passband-limited sweep, at most -24 dBFS, rendered through the way's own crossover, EQ, delay and limiter, played on
// its physical channel only) and captured at the seats; the analysed responses are stored per way and seat
// (`MultichannelWayCapture`). Control plane only; the transport owns the realtime bridge.

enum WayMeasurerError: Error, Equatable, LocalizedError {
    case routingRequired
    case nothingToMeasure
    case notReady(String)
    case wayChanged

    var errorDescription: String? {
        switch self {
        case .routingRequired: "Per-driver measurement needs the routing matrix switched on."
        case .nothingToMeasure: "Every driver in the treatment range already has a capture at every included seat."
        case .notReady(let reason): reason
        case .wayChanged: "The routing changed while a driver was being prepared; nothing was played. Measure again."
        }
    }
}

extension MultichannelCalibrationController {
    /// Highest per-driver sweep level (dBFS) the way pass uses: the protected excitation's own cap is -24.
    static let wayPassLevelDBFS = -30.0

    /// The excitation, route and analysis program for one way, bound to the current routing. Stops normal playback (E24 S2).
    func prepareWayPass(wayID: UUID) throws -> SpeakerMeasurementLabRoutedWayAcquisition {
        try synchronizeCampaign()
        guard microphone.permissionStatus == .authorized else {
            throw MultichannelCalibrationCampaignError.microphonePermissionRequired
        }
        guard let output = engine.selectedOutputDevice, let selectedOutputUID = engine.routeConfiguration.selectedOutputUID else {
            throw MultichannelCalibrationCampaignError.outputRequired
        }
        guard let routing = engine.speakerRoutingConfiguration, routing.enabled else { throw WayMeasurerError.routingRequired }
        setPlaybackNotice(MeasurementPlaybackPolicy.stopPlaybackIfRunning(engine))
        let settings = microphone.sweepSettings(sampleRate: output.nominalSampleRate, levelDBFS: Self.wayPassLevelDBFS)
        return try SpeakerMeasurementLabRoutedWayAcquisitionPlanner().prepare(
            wayID: wayID, routing: routing,
            environment: SpeakerMeasurementLabRoutedWayEnvironment(
                availableOutputs: engine.outputDevices, sampleRate: output.nominalSampleRate, selectedOutputUID: selectedOutputUID),
            sweep: settings)
    }
}

extension CalibrationSeatMeasurer {
    /// What is still missing for the routed design at the included seats, for the screen to say and for `measureWays`.
    func missingWayTargets(
        seatIDs: [UUID], overrides: [UUID: ClosedRange<Double>], excluded: Set<UUID>
    ) -> [MultichannelWayTarget] {
        guard let routing = calibration.engine.speakerRoutingConfiguration else { return [] }
        return MultichannelWayCaptureTargets.missing(
            routing: routing, seatIDs: seatIDs, captures: calibration.wayCaptures, overrides: overrides, excluded: excluded,
            sampleRate: calibration.engine.selectedOutputDevice?.nominalSampleRate ?? 0)
    }

    /// Captures every missing in-band way at the given seats (one way at a time; seats together when each has its own
    /// microphone, otherwise the single selected microphone at one seat) and stores each way's captures all at once.
    /// Returns how many captures were stored. Nothing is stored for a way whose pass failed.
    @discardableResult
    func measureWays(
        seatIDs: [UUID], overrides: [UUID: ClosedRange<Double>] = [:], excluded: Set<UUID> = []
    ) async throws -> Int {
        let targets = missingWayTargets(seatIDs: seatIDs, overrides: overrides, excluded: excluded)
        guard !targets.isEmpty else { throw WayMeasurerError.nothingToMeasure }
        let seats = seatIDs.compactMap { id in calibration.seats.first { $0.id == id } }
        let perSeat = calibration.seatMicrophoneMode == .perSeat
        if perSeat, let blocker = MeasurementReadiness.perSeatBlocker(seats: seats, devices: calibration.microphone.inputDevices) {
            throw WayMeasurerError.notReady(blocker.reason)
        }
        try calibration.beginExternalPass()
        var stored = 0
        do {
            var wayKeys: [(speakerID: UUID, wayID: UUID)] = []
            for target in targets where !wayKeys.contains(where: { $0.speakerID == target.speakerID && $0.wayID == target.wayID }) {
                wayKeys.append((target.speakerID, target.wayID))
            }
            for key in wayKeys {
                let group = seats.filter { seat in
                    targets.contains { $0.speakerID == key.speakerID && $0.wayID == key.wayID && $0.seatID == seat.id }
                }
                if group.isEmpty { continue }
                // One microphone moved between seats captures one seat per pass.
                stored += try await measureWay(key, group: perSeat ? group : Array(group.prefix(1)), perSeat: perSeat)
            }
            calibration.endExternalPass()
        } catch is CancellationError {
            calibration.endExternalPass()
            throw CancellationError()
        } catch {
            calibration.failExternalPass(error)
            throw error
        }
        return stored
    }

    private func measureWay(
        _ key: (speakerID: UUID, wayID: UUID), group: [MultichannelCalibrationSeat], perSeat: Bool
    ) async throws -> Int {
        let acquisition = try calibration.prepareWayPass(wayID: key.wayID)
        let devices = calibration.microphone.inputDevices
        var inputs: [MeasurementSeat] = []
        if perSeat {
            for seat in group {
                guard let mic = seat.microphone, let device = devices.first(where: { $0.uid == mic.deviceUID }) else {
                    throw WayMeasurerError.notReady("The microphone chosen for \(seat.name) is not connected.")
                }
                inputs.append(MeasurementSeat(device: device, channelIndex: mic.channelIndex))
            }
        } else {
            guard let device = calibration.microphone.selectedInputDevice else {
                throw WayMeasurerError.notReady("Choose a measurement microphone first.")
            }
            inputs = [MeasurementSeat(device: device, channelIndex: calibration.microphone.selectedInputChannelIndex)]
        }
        let plan = try MeasurementSeatPlan(seats: inputs)
        let program = acquisition.analysisProgram
        let timeout = Double(program.captureFrameCount) / program.sampleRate + 15
        var captures: [[Float]]
        do {
            captures = try await MultiMicMeasurementRunner.capture(
                plan: plan, timeoutSeconds: timeout, pollSeconds: pollSeconds,
                makeTransport: wayTransport(acquisition, calibration.engine.outputDevices))
        } catch MultiMicError.missingMic(let seat) {
            throw SeatMeasurerError.silentSeat(group.indices.contains(seat) ? group[seat].name : "seat \(seat + 1)")
        }
        try Task.checkCancellation()
        // The routing may have changed while the sweep played: a stale capture is never stored.
        guard acquisition.binding.matchesCurrentState(routing: calibration.engine.speakerRoutingConfiguration) else {
            throw WayMeasurerError.wayChanged
        }
        var results: [(speakerID: UUID, wayID: UUID, seatID: UUID, channel: RoomCorrectionChannelMeasurement)] = []
        for (k, seat) in group.enumerated() {
            try Task.checkCancellation()
            let channel = try await analysis(
                captures[k], program, perSeat ? seat.microphone?.calibration : calibration.microphone.microphoneCalibration, nil)
            results.append((key.speakerID, key.wayID, seat.id, channel))
        }
        try Task.checkCancellation()
        try calibration.storeWayCaptures(results, sampleRate: program.sampleRate)
        return results.count
    }
}

/// E19 S10b: the Room Treatment screen's view of the way pass. Wraps the seat measurer and the stored captures.
@MainActor
final class CalibrationTreatmentWayMeasurer: TreatmentWayMeasuring {
    private let calibration: MultichannelCalibrationController
    private let measurer: CalibrationSeatMeasurer

    init(calibration: MultichannelCalibrationController, measurer: CalibrationSeatMeasurer? = nil) {
        self.calibration = calibration
        self.measurer = measurer ?? CalibrationSeatMeasurer(calibration: calibration)
    }

    private var includedSeatIDs: [UUID] { calibration.seats.filter { $0.included && $0.weight > 0 }.map(\.id) }

    func missingWayNotes(overrides: [UUID: ClosedRange<Double>], excluded: Set<UUID>) -> [String] {
        measurer.missingWayTargets(seatIDs: includedSeatIDs, overrides: overrides, excluded: excluded).map { target in
            let seat = calibration.seats.first { $0.id == target.seatID }?.name ?? "a seat"
            let speaker = target.speakerName.isEmpty ? "Speaker" : target.speakerName
            let way = target.wayName.isEmpty ? "driver" : target.wayName
            return "\(speaker), \(way), at \(seat)"
        }
    }

    func measureMissingWays(overrides: [UUID: ClosedRange<Double>], excluded: Set<UUID>) async throws -> Int {
        var seatIDs = includedSeatIDs
        // One microphone moved between seats: one seat per pass, so the user moves it between presses.
        if calibration.seatMicrophoneMode == .movedMicrophone {
            let missing = Set(measurer.missingWayTargets(seatIDs: seatIDs, overrides: overrides, excluded: excluded).map(\.seatID))
            if let first = seatIDs.first(where: { missing.contains($0) }) { seatIDs = [first] }
        }
        return try await measurer.measureWays(seatIDs: seatIDs, overrides: overrides, excluded: excluded)
    }

    func wayCaptures() -> [MIMORoutedWayCapture] { calibration.routedWayCaptures() }
}
