import Foundation

/// E11 S9b: which microphone channels are the seats of one pass, and the runner that drives the
/// K-input transport and hands its captures to `MeasurementCore.processMultiMic`.
///
/// Control plane only. The transport owns the realtime bridge; this file never runs in a callback.

/// One seat: a channel of an input device.
struct MeasurementSeat: Equatable, Sendable, Identifiable {
    var device: AudioInputDevice
    var channelIndex: Int
    var id: String { "\(device.uid)#\(channelIndex)" }
    var name: String { "\(device.name) ch \(channelIndex + 1)" }
}

enum MeasurementSeatPlanError: Error, Equatable, LocalizedError {
    case tooManySeats
    case duplicateSeat
    case invalidChannel

    var errorDescription: String? {
        switch self {
        case .tooManySeats: "A pass captures at most \(MeasurementSeatPlan.maxSeats) seats."
        case .duplicateSeat: "That microphone channel is already a seat."
        case .invalidChannel: "Choose a microphone channel of 1 or more."
        }
    }
}

struct MeasurementSeatPlan: Equatable, Sendable {
    static let maxSeats = 16

    private(set) var seats: [MeasurementSeat] = []

    init() {}

    init(seats: [MeasurementSeat]) throws {
        for seat in seats { try add(seat) }
    }

    mutating func add(_ seat: MeasurementSeat) throws {
        guard seat.channelIndex >= 0 else { throw MeasurementSeatPlanError.invalidChannel }
        guard !seats.contains(where: { $0.id == seat.id }) else { throw MeasurementSeatPlanError.duplicateSeat }
        guard seats.count < Self.maxSeats else { throw MeasurementSeatPlanError.tooManySeats }
        seats.append(seat)
    }

    mutating func remove(id: String) { seats.removeAll { $0.id == id } }

    var isEmpty: Bool { seats.isEmpty }

    /// One device: K channels share one clock. Several devices: a drift-compensated private
    /// aggregate with per-mic acoustic timing, which the UI labels as less precise.
    var mode: MultiMicMode {
        Set(seats.map(\.device.deviceID)).count > 1 ? .separateDevices : .sharedClock
    }

    /// Separate microphones need the reference speaker's timing chirp in the pass.
    var requiresTimingChirp: Bool { mode == .separateDevices }

    var multiMicSeats: [MultiMicSeat] {
        seats.enumerated().map { MultiMicSeat(id: $0.offset, label: "Seat \($0.offset + 1): \($0.element.name)") }
    }

    var primary: MultichannelSeatInput? {
        seats.first.map { MultichannelSeatInput(device: $0.device, channelIndex: $0.channelIndex) }
    }

    var additional: [MultichannelSeatInput] {
        seats.dropFirst().map { MultichannelSeatInput(device: $0.device, channelIndex: $0.channelIndex) }
    }
}

enum MultiMicRunError: Error, Equatable, LocalizedError {
    case emptyPlan
    case transportUnavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .emptyPlan: "Add at least one seat before measuring."
        case .transportUnavailable: "The capture transport reported no state."
        case .timedOut: "The multi-microphone capture did not finish in time."
        }
    }
}

/// Builds the K-input transport for a plan (the real one wraps `MultichannelCalibrationTransport`).
typealias MultiMicTransportFactory = (
    _ primary: MultichannelSeatInput, _ additional: [MultichannelSeatInput]
) throws -> any MultichannelCalibrationTransporting

enum MultiMicMeasurementRunner {
    /// Runs one pass and returns one record per seat. The transport is always cancelled on failure
    /// or task cancellation, which restores any device rate it changed.
    static func run(
        plan: MeasurementSeatPlan,
        pass: MultiMicPass,
        sampleRate: Double,
        timeoutSeconds: Double,
        pollSeconds: Double = 0.02,
        makeTransport: MultiMicTransportFactory
    ) async throws -> [MultiMicSeatRecord] {
        let capture = try await captureMaterialized(
            plan: plan, timeoutSeconds: timeoutSeconds, pollSeconds: pollSeconds, makeTransport: makeTransport)
        return try records(from: capture, plan: plan, pass: pass, sampleRate: sampleRate)
    }

    /// E24 S5b1: the pass up to the captures (start, poll, timeout, cancel), one raw capture per seat in plan order.
    /// A seat the transport did not deliver, or delivered as digital silence, fails the whole pass with
    /// `MultiMicError.missingMic(seat:)`, so no partial set is ever analysed or stored.
    static func capture(
        plan: MeasurementSeatPlan,
        timeoutSeconds: Double,
        pollSeconds: Double = 0.02,
        makeTransport: MultiMicTransportFactory
    ) async throws -> [[Float]] {
        let capture = try await captureMaterialized(
            plan: plan, timeoutSeconds: timeoutSeconds, pollSeconds: pollSeconds, makeTransport: makeTransport)
        var captures: [[Float]?] = [capture.samples] + capture.seatSamples.map { Optional($0) }
        while captures.count < plan.seats.count { captures.append(nil) }
        let length = captures.compactMap { $0?.count }.max() ?? 0
        return try captures.prefix(plan.seats.count).enumerated().map { index, samples in
            guard let samples, samples.count == length, samples.contains(where: { $0 != 0 }) else {
                throw MultiMicError.missingMic(seat: index)
            }
            return samples
        }
    }

    private static func captureMaterialized(
        plan: MeasurementSeatPlan,
        timeoutSeconds: Double,
        pollSeconds: Double,
        makeTransport: MultiMicTransportFactory
    ) async throws -> MultichannelCalibrationCapture {
        guard let primary = plan.primary else { throw MultiMicRunError.emptyPlan }
        let transport = try makeTransport(primary, plan.additional)
        do {
            try transport.start()
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while true {
                try Task.checkCancellation()
                guard let snapshot = transport.snapshot() else { throw MultiMicRunError.transportUnavailable }
                if snapshot.complete { break }
                if Date() > deadline { throw MultiMicRunError.timedOut }
                try await Task.sleep(nanoseconds: UInt64(pollSeconds * 1e9))
            }
            return try transport.finishAndMaterialize()
        } catch {
            transport.cancel()
            throw error
        }
    }

    /// A seat the transport did not deliver is a missing mic and fails the whole pass.
    static func records(
        from capture: MultichannelCalibrationCapture, plan: MeasurementSeatPlan, pass: MultiMicPass, sampleRate: Double
    ) throws -> [MultiMicSeatRecord] {
        var captures: [[Float]?] = [capture.samples] + capture.seatSamples.map { Optional($0) }
        while captures.count < plan.seats.count { captures.append(nil) }
        if captures.count > plan.seats.count { captures.removeLast(captures.count - plan.seats.count) }
        return try MeasurementCore.processMultiMic(
            captures: captures, seats: plan.multiMicSeats, mode: plan.mode, pass: pass, sampleRate: sampleRate
        )
    }
}

extension MultichannelCalibrationTransport {
    /// The factory used by the flag-on flow: sweep on `outputChannel`, optional timing chirp on its own channel.
    static func multiMicFactory(
        routePlan: LiveNChannelOutputRoutePlan,
        outputs: [AudioOutputDevice],
        program: RoomCorrectionSweepProgram,
        physicalOutputChannelIndex: UInt32,
        referenceProgram: MultichannelReferenceProgram?
    ) -> MultiMicTransportFactory {
        { primary, additional in
            try MultichannelCalibrationTransport(
                routePlan: routePlan,
                availableOutputs: outputs,
                input: primary.device,
                inputChannelIndex: primary.channelIndex,
                program: program,
                physicalOutputChannelIndex: physicalOutputChannelIndex,
                additionalSeats: additional,
                referenceProgram: referenceProgram
            )
        }
    }
}
