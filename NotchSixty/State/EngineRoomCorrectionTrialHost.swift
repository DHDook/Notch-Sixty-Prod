import CoreAudio
import Foundation

// E24 S3a: the live-graph side of verification. The correction under test is already published to the engine by the
// Correction step (the normal snapshot path), so the trial host does not republish it: it plays the `.sweep` generator
// on the running graph, captures the microphone and hands the capture to E10 S8's verifier. A failed verification is
// undone by the flow (`SystemSetupFlowModel.revertCorrection`), which restores the snapshot taken before the trial.

enum RoomCorrectionTrialError: Error, Equatable, LocalizedError {
    case playbackNotRunning
    case microphoneRequired
    case microphonePermissionRequired
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .playbackNotRunning:
            return "The check plays a sweep through the live graph, and playback is not running on it. Start playback of your music in the main window, then run the check."
        case .microphoneRequired: return "Choose the measurement microphone, then run the check."
        case .microphonePermissionRequired: return "Microphone access is needed to run the check. Allow it in System Settings."
        case .captureFailed(let detail): return "The microphone capture failed: \(detail)"
        }
    }
}

/// Plays one sweep through the running graph and returns what the microphone heard. The Core Audio boundary:
/// the harness replaces it with a reference-room render.
@MainActor
protocol TrialSweepPlaying: AnyObject {
    /// Throws `RoomCorrectionTrialError` when the sweep cannot be played now.
    func prepare() throws
    func playSweep(_ candidate: RoomCorrectionDeployCandidate) async throws -> [Float]
    /// Stops the generator and the capture. Safe to call when nothing plays.
    func stop()
}

final class EngineRoomCorrectionTrialHost: RoomCorrectionTrialHost, @unchecked Sendable {
    private let playback: TrialSweepPlaying

    init(playback: TrialSweepPlaying) { self.playback = playback }

    func applyTrial(_ candidate: RoomCorrectionDeployCandidate) async throws {
        try await MainActor.run { try playback.prepare() }
    }

    func captureSweep(for candidate: RoomCorrectionDeployCandidate) async throws -> [Float] {
        try await playback.playSweep(candidate)
    }

    func revertTrial() async { await MainActor.run { playback.stop() } }
}

/// The playback seam of the trial (E24 S11, Q4): tests inject a fake because the real engine cannot start without hardware.
@MainActor
protocol TrialPlaybackControlling: AnyObject {
    /// True when the running graph renderer can take the generator.
    var liveGraphAvailable: Bool { get }
    /// True when no playback runs at all (so the trial may start it).
    var isIdle: Bool { get }
    func start() throws
    func stop()
}

@MainActor
final class EngineTrialPlaybackControl: TrialPlaybackControlling {
    private let engine: AudioIOEngine
    init(engine: AudioIOEngine) { self.engine = engine }
    var liveGraphAvailable: Bool { engine.liveGraphEditsAvailable }
    var isIdle: Bool { engine.lifecycleState == .idle }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}

/// Verification needs the graph renderer (Q4): with playback idle it starts playback on the selected output (the sweep
/// mutes other audio) and stops it again afterwards, so the prior state (idle) is restored. Playback that was already
/// running is left running. Control thread only.
@MainActor
final class TrialPlaybackOwner {
    static let startTimeoutSeconds = 5.0
    private let control: TrialPlaybackControlling
    private let pollNanoseconds: UInt64
    private(set) var startedByTrial = false

    init(control: TrialPlaybackControlling, pollNanoseconds: UInt64 = 50_000_000) {
        self.control = control
        self.pollNanoseconds = pollNanoseconds
    }

    /// Makes sure the live graph is running. Throws `playbackNotRunning` when it cannot be (a renderer that cannot take the
    /// generator, or playback that did not reach the graph in time); anything this call started is stopped again.
    func acquire() async throws {
        if control.liveGraphAvailable { return }
        guard control.isIdle else { throw RoomCorrectionTrialError.playbackNotRunning }
        do { try control.start() } catch {
            throw RoomCorrectionTrialError.captureFailed("playback could not start (\(error.localizedDescription)).")
        }
        startedByTrial = true
        let deadline = Date().addingTimeInterval(Self.startTimeoutSeconds)
        while !control.liveGraphAvailable {
            if Date() >= deadline || Task.isCancelled {
                release()
                throw RoomCorrectionTrialError.playbackNotRunning
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    /// Stops playback only if `acquire` started it. Safe to call repeatedly.
    func release() {
        guard startedByTrial else { return }
        startedByTrial = false
        control.stop()
    }
}

/// The production sweep player: the generator joins the live graph (other audio muted for the sweep) and a microphone-only
/// IOProc fills a monitor ring that is drained after the sweep.
@MainActor
final class EngineTrialSweepPlayer: TrialSweepPlaying {
    /// Silence before the sweep and after its end plus the filter's latency.
    static let leadSeconds = 0.25
    static let tailSeconds = 0.6

    private let engine: AudioIOEngine
    private let microphone: RoomCorrectionCalibrationController
    private var capture: MicrophoneRingCapture?
    private let owner: TrialPlaybackOwner

    init(engine: AudioIOEngine, microphone: RoomCorrectionCalibrationController, playback: TrialPlaybackControlling? = nil) {
        self.engine = engine
        self.microphone = microphone
        owner = TrialPlaybackOwner(control: playback ?? EngineTrialPlaybackControl(engine: engine))
    }

    func prepare() throws {
        // Idle playback is allowed: `playSweep` starts it (Q4). Playback on a renderer that cannot take the generator is not.
        guard engine.liveGraphEditsAvailable || engine.lifecycleState == .idle else { throw RoomCorrectionTrialError.playbackNotRunning }
        guard microphone.selectedInputDevice != nil else { throw RoomCorrectionTrialError.microphoneRequired }
        guard microphone.permissionStatus == .authorized else { throw RoomCorrectionTrialError.microphonePermissionRequired }
    }

    func playSweep(_ candidate: RoomCorrectionDeployCandidate) async throws -> [Float] {
        try prepare()
        guard let input = microphone.selectedInputDevice else { throw RoomCorrectionTrialError.microphoneRequired }
        defer { stop() }
        try await owner.acquire()
        var settings = SignalGeneratorSettings()
        settings.kind = .sweep
        settings.lowHz = candidate.sweepStartHz
        settings.highHz = min(candidate.sweepEndHz, 0.45 * candidate.sampleRate)
        settings.periodFrames = candidate.sweepFrames
        settings.muteOtherAudio = true
        let capture = try MicrophoneRingCapture(
            device: input, channel: microphone.selectedInputChannelIndex, sampleRate: candidate.sampleRate)
        self.capture = capture
        try capture.start()
        try await Task.sleep(nanoseconds: UInt64(Self.leadSeconds * 1e9))
        do { try engine.setLiveGenerator(settings, selection: .lane(candidate.measuredLane)) } catch {
            throw RoomCorrectionTrialError.captureFailed("the sweep could not join the live graph (\(error.localizedDescription)).")
        }
        let seconds = Double(candidate.sweepFrames + Int(candidate.lanePlan.declaredLatencyFrames)) / candidate.sampleRate
        try await Task.sleep(nanoseconds: UInt64((seconds + Self.tailSeconds) * 1e9))
        _ = try? engine.setLiveGenerator(nil, selection: .allProgram(includeLFE: false))
        let samples = capture.drain()
        guard capture.overrunFrames == 0 else { throw RoomCorrectionTrialError.captureFailed("the capture buffer overran.") }
        return samples
    }

    func stop() {
        capture?.stop()
        capture = nil
        if engine.liveGenerator != nil {
            _ = try? engine.setLiveGenerator(nil, selection: .allProgram(includeLFE: false))
        }
        owner.release()
    }
}

/// A microphone-only IOProc that pushes one channel into a ring large enough for the whole sweep.
@MainActor
final class MicrophoneRingCapture {
    private let ring: MonitorSampleRing
    private let device: AudioInputDevice
    private var context: OpaquePointer?
    private var ioProc: AudioDeviceIOProcID?
    private var collected: [Float] = []
    private var running = false

    init(device: AudioInputDevice, channel: Int, sampleRate: Double) throws {
        self.device = device
        // Lead, a 3 s sweep at most, latency and tail: 6 s, rounded up to a power of two.
        var frames = 1 << 14
        while Double(frames) < sampleRate * 8 { frames <<= 1 }
        do { ring = try MonitorSampleRing(capacityFrames: frames) } catch {
            throw RoomCorrectionTrialError.captureFailed("no capture buffer.")
        }
        guard let created = N60MeasurementMonitorContextCreate(ring.handle, UInt32(channel)) else {
            throw RoomCorrectionTrialError.captureFailed("no capture context.")
        }
        context = created
    }

    var overrunFrames: UInt64 { ring.overrunFrames }

    func start() throws {
        guard let context else { return }
        var status = AudioDeviceCreateIOProcID(device.deviceID, N60MeasurementMonitorIOProc, UnsafeMutableRawPointer(context), &ioProc)
        guard status == noErr, ioProc != nil else { throw RoomCorrectionTrialError.captureFailed("OSStatus \(status).") }
        status = AudioDeviceStart(device.deviceID, ioProc)
        guard status == noErr else { throw RoomCorrectionTrialError.captureFailed("OSStatus \(status).") }
        running = true
    }

    func drain() -> [Float] {
        collected += ring.pop(maximum: ring.availableFrames)
        return collected
    }

    func stop() {
        if running, let ioProc {
            AudioDeviceStop(device.deviceID, ioProc)
            AudioDeviceDestroyIOProcID(device.deviceID, ioProc)
        }
        running = false
        ioProc = nil
        if let context { N60MeasurementMonitorContextDestroy(context) }
        context = nil
    }
}
