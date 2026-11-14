import Foundation

// E24 S5b1: the production `measureSeat` for the guided-setup window. It wraps the multichannel calibration
// controller: one microphone moved between seats keeps today's sequential path; one microphone per seat on a shared
// clock captures every requested seat in a single pass per source. Control plane only; the transport owns the realtime
// bridge. Design note 10 in docs/epics/E24.md.

/// What the setup window asks of a measuring service: one seat, or several (all in one pass when each has its own
/// microphone). `SystemSetupServices` refines this, so the simulated services keep their one-seat method.
protocol SystemSetupSeatMeasuring: Sendable {
    func measureSeat(index: Int, sampleRate: Double) async throws -> SystemSetupMeasurementRecord
    func measureSeats(_ indices: [Int], sampleRate: Double) async throws -> [SystemSetupMeasurementRecord]
}

extension SystemSetupSeatMeasuring {
    func measureSeats(_ indices: [Int], sampleRate: Double) async throws -> [SystemSetupMeasurementRecord] {
        var records: [SystemSetupMeasurementRecord] = []
        for index in indices { records.append(try await measureSeat(index: index, sampleRate: sampleRate)) }
        return records
    }
}

enum SeatMeasurerError: Error, Equatable, LocalizedError {
    case invalidSeat(Int)
    case notReady(String)
    /// A seat's microphone delivered nothing (a short capture or digital silence): the whole pass is discarded.
    case silentSeat(String)
    case incomplete(String)
    /// E24 S5b2: a microphone on another device could not hear the timing chirp clearly; the pass is discarded.
    case weakReference(String)

    var errorDescription: String? {
        switch self {
        case .invalidSeat(let index): "There is no seat \(index + 1)."
        case .notReady(let reason): reason
        case .silentSeat(let name): "No sound reached the microphone at \(name). Check its cable and level, then measure again; nothing from this pass was kept."
        case .incomplete(let name): "\(name) was not fully measured."
        case .weakReference(let name): "The microphone at \(name) could not hear the timing signal from the front-left speaker clearly. Move it closer to the listening position or raise the speaker level, then measure again; nothing from this pass was kept."
        }
    }
}

extension MeasurementReadiness {
    /// Why a per-seat pass over `seats` cannot start, or nil (design note 10). `sources` are the campaign's speakers and
    /// subwoofers (nil skips the check); microphones on different devices need the front-left speaker as timing reference.
    static func perSeatBlocker(
        seats: [MultichannelCalibrationSeat], devices: [AudioInputDevice], sources: [MultichannelCalibrationSource]? = nil
    ) -> Blocker? {
        if seats.count > MeasurementSeatPlan.maxSeats {
            return Blocker(reason: "One pass captures at most \(MeasurementSeatPlan.maxSeats) seats.", fix: nil)
        }
        var used: [String: String] = [:]
        var deviceIDs = Set<UInt32>()
        for seat in seats {
            guard let microphone = seat.microphone else {
                return Blocker(reason: "\(seat.name) has no microphone yet. Choose one for each seat.", fix: .selectMicrophone)
            }
            guard let device = devices.first(where: { $0.uid == microphone.deviceUID }) else {
                return Blocker(reason: "The microphone chosen for \(seat.name) is not connected.", fix: .selectMicrophone)
            }
            if let count = device.inputChannelCount, microphone.channelIndex >= count {
                return Blocker(
                    reason: "\(seat.name) uses input channel \(microphone.channelIndex + 1), but \(device.name) has only \(count). Choose a lower channel.",
                    fix: .selectMicrophone)
            }
            deviceIDs.insert(device.deviceID)
            let key = "\(microphone.deviceUID)#\(microphone.channelIndex)"
            if let other = used[key] {
                return Blocker(reason: "\(other) and \(seat.name) use the same microphone channel.", fix: .selectMicrophone)
            }
            used[key] = seat.name
        }
        if deviceIDs.count > 1, let sources, !sources.contains(CalibrationSeatMeasurer.referenceSource) {
            return Blocker(
                reason: "Microphones on different devices need a front-left speaker to play the timing signal. Describe one in Speakers, or use channels of one interface.",
                fix: nil)
        }
        return nil
    }
}

@MainActor
final class CalibrationSeatMeasurer: SystemSetupSeatMeasuring {
    /// The speaker whose chirp ties microphones on different devices to one clock.
    nonisolated static let referenceSource = MultichannelCalibrationSource.speaker(.frontLeft)

    typealias TransportProvider = @MainActor (MultichannelSeatPass) -> MultiMicTransportFactory
    typealias SeatAnalysis = @Sendable (
        [Float], RoomCorrectionSweepProgram, RoomCorrectionMicrophoneCalibration?, [Double]?
    ) async throws -> RoomCorrectionChannelMeasurement
    typealias ArrivalOperation = @Sendable ([Float], RoomCorrectionSweepProgram) async throws -> [Double]?

    /// E19 S10b: the transport for one routed way: the way's carrier route, its sweep, and the protected waveform it plays.
    typealias WayTransportProvider = @MainActor (SpeakerMeasurementLabRoutedWayAcquisition, [AudioOutputDevice]) -> MultiMicTransportFactory

    let calibration: MultichannelCalibrationController
    private let transport: TransportProvider
    let wayTransport: WayTransportProvider
    let analysis: SeatAnalysis
    private let arrivals: ArrivalOperation
    let pollSeconds: Double

    init(
        calibration: MultichannelCalibrationController,
        pollSeconds: Double = 0.02,
        transport: @escaping TransportProvider = { pass in
            MultichannelCalibrationTransport.multiMicFactory(
                routePlan: pass.routePlan, outputs: pass.outputs, program: pass.program,
                physicalOutputChannelIndex: pass.physicalOutputChannel, referenceProgram: pass.referenceProgram,
                outputSweepSamples: pass.outputSweepSamples)
        },
        analysis: @escaping SeatAnalysis = { samples, program, microphone, arrivals in
            try await Task.detached(priority: .userInitiated) {
                try RoomCorrectionMeasurementAnalyzer().analyzeSingleChannel(
                    rawCapture: samples, program: program, microphoneCalibration: microphone, repeatArrivals: arrivals)
            }.value
        },
        wayTransport: @escaping WayTransportProvider = { acquisition, outputs in
            MultichannelCalibrationTransport.multiMicFactory(
                routePlan: acquisition.binding.carrierRoutePlan, outputs: outputs, program: acquisition.sweepProgram,
                physicalOutputChannelIndex: acquisition.binding.physicalOutputChannelIndex, referenceProgram: nil,
                outputSweepSamples: acquisition.excitation.renderedSamples)
        },
        arrivals: @escaping ArrivalOperation = { samples, program in
            try await Task.detached(priority: .userInitiated) {
                try RoomCorrectionMeasurementAnalyzer().repeatArrivals(rawCapture: samples, program: program)
            }.value
        }
    ) {
        self.calibration = calibration
        self.pollSeconds = pollSeconds
        self.transport = transport
        self.wayTransport = wayTransport
        self.analysis = analysis
        self.arrivals = arrivals
    }

    func measureSeat(index: Int, sampleRate: Double) async throws -> SystemSetupMeasurementRecord {
        try await measureSeats([index], sampleRate: sampleRate)[0]
    }

    func measureSeats(_ indices: [Int], sampleRate: Double) async throws -> [SystemSetupMeasurementRecord] {
        try calibration.synchronizeCampaign()
        let seats = try indices.map { index -> MultichannelCalibrationSeat in
            guard calibration.seats.indices.contains(index) else { throw SeatMeasurerError.invalidSeat(index) }
            return calibration.seats[index]
        }
        switch calibration.seatMicrophoneMode {
        case .movedMicrophone: try await measureMoved(seats)
        case .perSeat: try await measurePerSeat(seats)
        }
        return try zip(indices, seats).map { index, seat in
            guard calibration.missingSources(for: seat.id).isEmpty else { throw SeatMeasurerError.incomplete(seat.name) }
            return SystemSetupMeasurementRecord(id: seat.id, seatIndex: index, sampleRate: sampleRate)
        }
    }

    // MARK: One microphone moved between seats: today's begin/finish pair, one source at a time

    private func measureMoved(_ seats: [MultichannelCalibrationSeat]) async throws {
        for seat in seats {
            while !calibration.missingSources(for: seat.id).isEmpty {
                try calibration.beginNextMeasurement(seatID: seat.id)
                while calibration.state == .measuring {
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1e9))
                    if Task.isCancelled { calibration.cancelMeasurement(); throw CancellationError() }
                    if try await calibration.finishMeasurementIfComplete() { break }
                }
                if calibration.state == .failed { throw SeatMeasurerError.notReady(calibration.lastErrorDescription ?? "The measurement failed.") }
            }
        }
    }

    // MARK: One microphone per seat: one K-microphone pass per source

    private func measurePerSeat(_ seats: [MultichannelCalibrationSeat]) async throws {
        if let blocker = MeasurementReadiness.perSeatBlocker(
            seats: seats, devices: calibration.microphone.inputDevices, sources: calibration.sources) {
            throw SeatMeasurerError.notReady(blocker.reason)
        }
        try calibration.beginExternalPass()
        do {
            for source in calibration.sources {
                let group = seats.filter { calibration.missingSources(for: $0.id).contains(source) }
                if group.isEmpty { continue }
                try await measureGroup(group, source: source)
            }
            calibration.endExternalPass()
        } catch is CancellationError {
            calibration.endExternalPass()
            throw CancellationError()
        } catch {
            calibration.failExternalPass(error)
            throw error
        }
    }

    private func measureGroup(_ group: [MultichannelCalibrationSeat], source: MultichannelCalibrationSource) async throws {
        var pass = try calibration.prepareSeatPass(for: source)
        let devices = calibration.microphone.inputDevices
        let plan = try MeasurementSeatPlan(seats: group.map { seat in
            let microphone = seat.microphone!
            return MeasurementSeat(device: devices.first { $0.uid == microphone.deviceUID }!, channelIndex: microphone.channelIndex)
        })
        // The program the analyser sees. Separate devices play a longer one with the timing chirp ahead of the sweep.
        let program = pass.program
        var timing: SeparateDeviceTiming?
        if plan.requiresTimingChirp {
            let t = try SeparateDeviceTiming(program: program)
            timing = t
            if source == Self.referenceSource {
                pass.outputSweepSamples = t.outputSweep(program)
            } else {
                let referencePass = try calibration.prepareSeatPass(for: Self.referenceSource)
                pass.program = t.extendedProgram(program)
                pass.referenceProgram = t.referenceProgram(outputChannel: referencePass.physicalOutputChannel)
            }
        }
        let frames = timing.map { $0.extendedFrameCount(of: program) } ?? program.captureFrameCount
        let timeout = Double(frames) / pass.sampleRate + 15
        var captures: [[Float]]
        do {
            captures = try await MultiMicMeasurementRunner.capture(
                plan: plan, timeoutSeconds: timeout, pollSeconds: pollSeconds, makeTransport: transport(pass))
            if let timing { captures = try timing.align(captures).captures }
        } catch MultiMicError.missingMic(let seat) {
            throw SeatMeasurerError.silentSeat(group.indices.contains(seat) ? group[seat].name : "seat \(seat + 1)")
        } catch MultiMicError.weakReference(let seat) {
            throw SeatMeasurerError.weakReference(group.indices.contains(seat) ? group[seat].name : "seat \(seat + 1)")
        }
        try Task.checkCancellation()
        // On one clock the primary seat's per-repeat arrivals serve every seat, so the seats stay on one timeline.
        // Separate devices drift against each other (tens of ppm), so each seat tracks its own repeats.
        let shared = program.repeatCount > 1 && timing == nil ? try await arrivals(captures[0], program) : nil
        var results: [(seatID: UUID, source: MultichannelCalibrationSource, channel: RoomCorrectionChannelMeasurement)] = []
        for (k, seat) in group.enumerated() {
            try Task.checkCancellation()
            var channel = try await analysis(captures[k], program, seat.microphone?.calibration, shared)
            if timing != nil { channel.quality.warnings.append(MultiMicMode.separateDevices.timingWarning) }
            results.append((seat.id, source, channel))
        }
        try Task.checkCancellation()
        try calibration.storeSeatMeasurements(results, sampleRate: pass.sampleRate)
    }
}

extension MultiMicMode {
    /// Shown on the seat's result rows (E24 S5b2).
    var timingWarning: String {
        "Microphones on separate devices: timing between seats comes from the front-left speaker's chirp and is less precise."
    }
}

extension MultichannelCalibrationController {
    /// How the per-seat microphones are clocked, or nil when they are not per seat or no seat has a microphone yet.
    var seatClockMode: MultiMicMode? {
        guard seatMicrophoneMode == .perSeat else { return nil }
        let uids = Set(includedSeats.compactMap { $0.microphone?.deviceUID })
        guard !uids.isEmpty else { return nil }
        return uids.count > 1 ? .separateDevices : .sharedClock
    }
}
