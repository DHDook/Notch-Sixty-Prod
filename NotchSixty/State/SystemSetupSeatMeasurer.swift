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

    var errorDescription: String? {
        switch self {
        case .invalidSeat(let index): "There is no seat \(index + 1)."
        case .notReady(let reason): reason
        case .silentSeat(let name): "No sound reached the microphone at \(name). Check its cable and level, then measure again; nothing from this pass was kept."
        case .incomplete(let name): "\(name) was not fully measured."
        }
    }
}

extension MeasurementReadiness {
    /// Why a per-seat pass over `seats` cannot start, or nil (design note 10). Separate devices wait for S5b2.
    static func perSeatBlocker(seats: [MultichannelCalibrationSeat], devices: [AudioInputDevice]) -> Blocker? {
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
            deviceIDs.insert(device.deviceID)
            let key = "\(microphone.deviceUID)#\(microphone.channelIndex)"
            if let other = used[key] {
                return Blocker(reason: "\(other) and \(seat.name) use the same microphone channel.", fix: .selectMicrophone)
            }
            used[key] = seat.name
        }
        if deviceIDs.count > 1 {
            return Blocker(reason: "Microphones on different devices arrive in the next update. Use channels of one interface for now.", fix: nil)
        }
        return nil
    }
}

@MainActor
final class CalibrationSeatMeasurer: SystemSetupSeatMeasuring {
    typealias TransportProvider = @MainActor (MultichannelSeatPass) -> MultiMicTransportFactory
    typealias SeatAnalysis = @Sendable (
        [Float], RoomCorrectionSweepProgram, RoomCorrectionMicrophoneCalibration?, [Double]?
    ) async throws -> RoomCorrectionChannelMeasurement
    typealias ArrivalOperation = @Sendable ([Float], RoomCorrectionSweepProgram) async throws -> [Double]?

    let calibration: MultichannelCalibrationController
    private let transport: TransportProvider
    private let analysis: SeatAnalysis
    private let arrivals: ArrivalOperation
    private let pollSeconds: Double

    init(
        calibration: MultichannelCalibrationController,
        pollSeconds: Double = 0.02,
        transport: @escaping TransportProvider = { pass in
            MultichannelCalibrationTransport.multiMicFactory(
                routePlan: pass.routePlan, outputs: pass.outputs, program: pass.program,
                physicalOutputChannelIndex: pass.physicalOutputChannel, referenceProgram: nil)
        },
        analysis: @escaping SeatAnalysis = { samples, program, microphone, arrivals in
            try await Task.detached(priority: .userInitiated) {
                try RoomCorrectionMeasurementAnalyzer().analyzeSingleChannel(
                    rawCapture: samples, program: program, microphoneCalibration: microphone, repeatArrivals: arrivals)
            }.value
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
        if let blocker = MeasurementReadiness.perSeatBlocker(seats: seats, devices: calibration.microphone.inputDevices) {
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
        let pass = try calibration.prepareSeatPass(for: source)
        let devices = calibration.microphone.inputDevices
        let plan = try MeasurementSeatPlan(seats: group.map { seat in
            let microphone = seat.microphone!
            return MeasurementSeat(device: devices.first { $0.uid == microphone.deviceUID }!, channelIndex: microphone.channelIndex)
        })
        let program = pass.program
        let timeout = Double(program.captureFrameCount) / pass.sampleRate + 15
        let captures: [[Float]]
        do {
            captures = try await MultiMicMeasurementRunner.capture(
                plan: plan, timeoutSeconds: timeout, pollSeconds: pollSeconds, makeTransport: transport(pass))
        } catch MultiMicError.missingMic(let seat) {
            throw SeatMeasurerError.silentSeat(group.indices.contains(seat) ? group[seat].name : "seat \(seat + 1)")
        }
        try Task.checkCancellation()
        // The primary seat's per-repeat arrivals serve every seat, so the seats stay on one timeline.
        let shared = program.repeatCount > 1 ? try await arrivals(captures[0], program) : nil
        var results: [(seatID: UUID, source: MultichannelCalibrationSource, channel: RoomCorrectionChannelMeasurement)] = []
        for (k, seat) in group.enumerated() {
            try Task.checkCancellation()
            let channel = try await analysis(captures[k], program, seat.microphone?.calibration, shared)
            results.append((seat.id, source, channel))
        }
        try Task.checkCancellation()
        try calibration.storeSeatMeasurements(results, sampleRate: pass.sampleRate)
    }
}
