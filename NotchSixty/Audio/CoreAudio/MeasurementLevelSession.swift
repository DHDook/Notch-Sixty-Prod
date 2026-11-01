import CoreAudio
import Foundation

// E24 S1, design note 3: the measurement-owned level session. It plays the E11 generator (clamp, 100 ms ramps,
// -6 dBFS RMS ceiling and auto-stop are the core's) on chosen physical output channels of the calibration
// aggregate and feeds the microphone channel to the SPL/RTA worker, with no playback session running. The
// realtime half is `N60LevelSessionProc.c`; this file is the control plane.
//
// Realtime/threads: everything here runs on the main actor. The graph, ring and context are built before the
// IOProc starts and destroyed after it stops. Stop posts active = 0, waits (bounded) for the callback to see
// the ramp reach silence, then stops the IOProc.

enum MeasurementLevelSessionError: Error, Equatable, LocalizedError {
    case outputRequired
    case microphoneRequired
    case microphonePermissionRequired
    case routeUnavailable(String)
    case noPlayableLane
    case laneUnavailable
    case invalidSettings
    case sessionBusy
    case deviceFailure(String)
    case graphRejected(String)

    var errorDescription: String? {
        switch self {
        case .outputRequired:
            return "Choose an output device first. The level noise plays on the output you selected."
        case .microphoneRequired:
            return "Choose a measurement microphone first. The meter listens to it while the noise plays."
        case .microphonePermissionRequired:
            return "Allow microphone access first (System Settings, Privacy and Security, Microphone), then try again."
        case .routeUnavailable(let reason):
            return "Your speaker layout cannot be played yet: \(reason)"
        case .noPlayableLane:
            return "None of the selected speakers is routed to an output channel on this device."
        case .laneUnavailable:
            return "That channel is not routed to an output channel on this device."
        case .invalidSettings:
            return "The noise settings are outside what the generator accepts at this sample rate."
        case .sessionBusy:
            return "The noise is already stopping. Wait a moment and try again."
        case .deviceFailure(let detail):
            return "The audio device could not start the noise: \(detail)"
        case .graphRejected(let detail):
            return "The noise generator was rejected (\(detail))."
        }
    }
}

/// One playable output lane of the level session: a program role routed to one physical channel.
struct LevelSessionLane: Equatable, Sendable {
    /// Index of the role in the program layout; this is the lane number the wizard and Generator card use.
    var roleIndex: Int
    var name: String
    var physicalChannel: UInt32
    var isLFE: Bool
}

struct LevelSessionRequest {
    var routePlan: LiveNChannelOutputRoutePlan
    var outputs: [AudioOutputDevice]
    var input: AudioInputDevice
    var inputChannel: Int
    var sampleRate: Double
    var lanes: [LevelSessionLane]
}

/// The Core Audio boundary of the session (the aggregate and its IOProc). Tests substitute a pump.
protocol LevelSessionTransporting: AnyObject {
    func start() throws
    func stop()
    func cancel()
    /// False when the device did not confirm the IOProc stopped.
    var didStopCleanly: Bool { get }
}

extension MultichannelCalibrationTransport: LevelSessionTransporting {}

/// Builds the transport for a request. `context` is the realtime context the IOProc renders; `channels[i]` is
/// the physical output channel of graph lane `i`.
typealias LevelSessionTransportFactory = (
    _ request: LevelSessionRequest, _ context: OpaquePointer, _ channels: [UInt32]
) throws -> any LevelSessionTransporting

enum LevelSessionHardware {
    static let transportFactory: LevelSessionTransportFactory = { request, context, channels in
        // The transport wants a sweep program for its rate; the level session plays none of it.
        let program = RoomCorrectionSweepProgram(
            settings: RoomCorrectionSweepSettings(sampleRate: request.sampleRate),
            sampleRate: request.sampleRate, sweepSamples: [0], inverseFilter: [0], leadInFrames: 0, tailFrames: 0)
        do {
            return try MultichannelCalibrationTransport(
                routePlan: request.routePlan, availableOutputs: request.outputs, input: request.input,
                inputChannelIndex: request.inputChannel, program: program,
                physicalOutputChannelIndex: channels[0], levelContext: context, levelOutputChannels: channels)
        } catch {
            throw MeasurementLevelSessionError.deviceFailure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}

enum LevelSessionEnd: Equatable {
    case stopped
    /// The generator's own auto-stop (at most 10 minutes) ran out.
    case autoStopped
}

@MainActor
final class MeasurementLevelSession {
    static let maxBlockFrames: UInt32 = 4096
    /// The most the stop waits for the 100 ms ramp to reach silence before stopping the IOProc anyway.
    static let stopWaitSeconds = 0.6

    private(set) var isRunning = false
    /// Called when the session ended without a `stop()` call.
    var onEnded: ((LevelSessionEnd) -> Void)?
    private(set) var ring: MonitorSampleRing?
    private(set) var sampleRate = 0.0

    private let makeTransport: LevelSessionTransportFactory
    private var host: UnifiedGraphHost?
    private var context: OpaquePointer?
    private var transport: (any LevelSessionTransporting)?
    private var request: LevelSessionRequest?
    private var watchdog: Task<Void, Never>?
    private var isStopping = false

    init(transport: @escaping LevelSessionTransportFactory = LevelSessionHardware.transportFactory) {
        makeTransport = transport
    }

    func start(_ request: LevelSessionRequest, settings: SignalGeneratorSettings, selection: SignalGeneratorLaneSelection) throws {
        guard !isStopping else { throw MeasurementLevelSessionError.sessionBusy }
        guard !isRunning else { return try update(settings, selection: selection) }
        guard !request.lanes.isEmpty else { throw MeasurementLevelSessionError.noPlayableLane }
        let mask = try laneMask(for: selection, in: request)
        let spec = try makeSpec(request, settings: settings, mask: mask, active: true)

        let host: UnifiedGraphHost
        do { host = try UnifiedGraphHost(spec: spec) } catch {
            throw MeasurementLevelSessionError.graphRejected("\(error)")
        }
        guard let graph = host.rawGraph else { throw MeasurementLevelSessionError.graphRejected("no graph") }
        let channels = request.lanes.map(\.physicalChannel)
        let ring: MonitorSampleRing
        do { ring = try MonitorSampleRing(capacityFrames: MeasurementInputMonitor.ringFrames(sampleRate: request.sampleRate)) }
        catch { host.release(); throw MeasurementLevelSessionError.deviceFailure("no memory for the meter") }
        let created = channels.withUnsafeBufferPointer {
            N60LevelSessionContextCreate(graph, ring.handle, 0, $0.baseAddress!, UInt32($0.count), Self.maxBlockFrames)
        }
        guard let created else { host.release(); throw MeasurementLevelSessionError.deviceFailure("no memory for the session") }
        let transport: any LevelSessionTransporting
        do {
            transport = try makeTransport(request, created, channels)
            try transport.start()
        } catch {
            host.release()
            N60LevelSessionContextDestroy(created)
            // (The transport never started, so no callback can reference the context.)
            if let known = error as? MeasurementLevelSessionError { throw known }
            throw MeasurementLevelSessionError.deviceFailure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        self.host = host
        context = created
        self.transport = transport
        self.request = request
        self.ring = ring
        sampleRate = request.sampleRate
        isRunning = true
        let deadline = settings.autoStopSeconds + 0.4
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard !Task.isCancelled else { return }
            self?.finishAutomatically()
        }
    }

    /// Live level or lane change while playing: parameter posts, or a faded rebuild when the lanes change.
    func update(_ settings: SignalGeneratorSettings, selection: SignalGeneratorLaneSelection) throws {
        guard isRunning, let host, let request else { return }
        let spec = try makeSpec(request, settings: settings, mask: try laneMask(for: selection, in: request), active: true)
        do { _ = try host.apply(spec) } catch { throw MeasurementLevelSessionError.graphRejected("\(error)") }
    }

    /// Ramps the generator to silence (100 ms), then stops the IOProc and releases the aggregate.
    func stop() {
        guard isRunning, !isStopping, let host, let context else { return }
        isStopping = true
        watchdog?.cancel()
        var quiet = host.spec
        var rampPosted = false
        if let index = quiet.stages.firstIndex(where: { $0.stageId == UnifiedGraphConfiguration.generatorStageId }),
           quiet.stages[index].params.count == 11 {
            quiet.stages[index].params[9] = 0
            rampPosted = (try? host.apply(quiet)) != nil
        }
        N60LevelSessionContextRequestStop(context)
        let deadline = Date().addingTimeInterval(Self.stopWaitSeconds)
        while rampPosted, !N60LevelSessionContextSnapshot(context).rampDone, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        teardown()
        isStopping = false
    }

    // MARK: -

    private func finishAutomatically() {
        guard isRunning, !isStopping else { return }
        teardown()
        onEnded?(.autoStopped)
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        transport?.stop()
        transport?.cancel()
        let clean = transport?.didStopCleanly ?? true
        transport = nil
        // If the device did not confirm the stop, a callback may still run: leak rather than free what it reads.
        if clean {
            if let context { N60LevelSessionContextDestroy(context) }
            host?.release()
        }
        context = nil
        host = nil
        request = nil
        isRunning = false
    }

    private func laneMask(for selection: SignalGeneratorLaneSelection, in request: LevelSessionRequest) throws -> UInt64 {
        let translated: SignalGeneratorLaneSelection
        switch selection {
        case .lane(let roleIndex):
            guard let graphLane = request.lanes.firstIndex(where: { $0.roleIndex == roleIndex }) else {
                throw MeasurementLevelSessionError.laneUnavailable
            }
            translated = .lane(graphLane)
        case .allProgram:
            translated = selection
        }
        guard let mask = translated.mask(
            laneCount: request.lanes.count, lfeLane: request.lanes.firstIndex(where: \.isLFE)) else {
            throw MeasurementLevelSessionError.noPlayableLane
        }
        return mask
    }

    private func makeSpec(_ request: LevelSessionRequest, settings: SignalGeneratorSettings, mask: UInt64, active: Bool) throws -> UnifiedGraphSpec {
        guard let params = settings.stageParams(active: active, sampleRate: request.sampleRate) else {
            throw MeasurementLevelSessionError.invalidSettings
        }
        let lanes = UInt32(request.lanes.count)
        return UnifiedGraphSpec(
            sampleRate: request.sampleRate, maxBlockFrames: Self.maxBlockFrames, inputChannels: lanes, outputChannels: lanes,
            stages: [UnifiedGraphStageSpec(
                kind: N60_STAGE_GENERATOR.rawValue, stageId: UnifiedGraphConfiguration.generatorStageId,
                laneA: 0, laneMask: mask, params: params)],
            denoiserPark: nil)
    }
}
