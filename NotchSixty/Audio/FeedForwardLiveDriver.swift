import CoreAudio
import Foundation

/// E4 S25 follow-up: who feeds the live feed-forward reference ring. The engine owns one driver; it runs
/// the S25c pump on a 10 ms timer for as long as the shadow has published weights, and stops it (which
/// fades the filter out) on any fault. Starting it never arms anything: arming is only
/// `FeedForwardLiveArmGate`, and nothing sets the written authorisation yet.

/// Two control-plane readers share the speaker-drive anchor ring, which has one consumer. Whoever
/// pulls first reads the ring; every anchor is handed to each consumer once.
struct SpeakerDriveAnchorFanout: Sendable {
    enum Consumer: Sendable { case shadow, pump }

    /// Bounds a consumer that never drains (the ring itself holds 4,096).
    static let maximumPending = 8_192

    private var shadow: [N60SpeakerDriveAnchor] = []
    private var pump: [N60SpeakerDriveAnchor] = []

    /// Anchors newly read from the ring. A consumer with no demand still sees them (cheap, bounded).
    mutating func ingest(_ anchors: [N60SpeakerDriveAnchor]) {
        guard !anchors.isEmpty else { return }
        shadow.append(contentsOf: anchors)
        pump.append(contentsOf: anchors)
        if shadow.count > Self.maximumPending { shadow.removeFirst(shadow.count - Self.maximumPending) }
        if pump.count > Self.maximumPending { pump.removeFirst(pump.count - Self.maximumPending) }
    }

    mutating func drain(_ consumer: Consumer) -> [N60SpeakerDriveAnchor] {
        switch consumer {
        case .shadow:
            defer { shadow.removeAll(keepingCapacity: true) }
            return shadow
        case .pump:
            defer { pump.removeAll(keepingCapacity: true) }
            return pump
        }
    }

    mutating func reset() {
        shadow.removeAll()
        pump.removeAll()
    }
}

/// The drive recording runs while either the shadow (echo removal) or the pump (output clock fit) wants it.
struct SpeakerDriveDemandMux: Equatable, Sendable {
    var shadow = false
    var pump = false
    var requested: Bool { shadow || pump }
}

/// What the driver needs from the engine.
@MainActor
protocol FeedForwardLiveDriverHost: FeedForwardLiveReferenceSink {
    /// `e4.feedforward-live` is on and a stereo transport with a drive tap is running.
    var liveDriverAllowed: Bool { get }
    var liveDriverOutputRate: Double? { get }
    /// Seconds from an output host time to the sound leaving the speaker (output latency, safety
    /// offset, stream latency and the output buffer).
    func liveDriverOutputLatencySeconds() -> Double
    func pullPumpAnchors() -> [N60SpeakerDriveAnchor]
    func setPumpDriveDemand(_ requested: Bool)
}

/// Runs `FeedForwardLiveReferencePump` every 10 ms. Main actor. Realtime impact: none (the ring write is
/// the S25b single-producer push). Latency: `delaySeconds`, spent from the S24 lead budget, so the arm
/// gate must be given `lead - delaySeconds`. Sample rates: any up to 384 kHz (the pump resamples).
/// A pump that stopped itself (drift, residual, gap, capture failure) stays stopped until `stop()`;
/// the filter has already been faded out and nothing restarts it by itself.
@MainActor
final class FeedForwardLiveDriver {
    static let intervalNanoseconds: UInt64 = 10_000_000
    /// Spent on top of the measured latencies, for scheduling jitter.
    static let marginSeconds = 0.010

    enum State: Equatable {
        case idle
        case running
        case stopped(String)
    }

    struct Latencies: Equatable {
        /// Capture buffering the pump must wait out (the input buffer).
        var inputBufferingSeconds: Double
        /// The input's reported latency plus safety offset: the timestamp is this late.
        var inputLatencySeconds: Double
    }

    /// Delay the ring applies to the reference: output latency, input buffering and a margin.
    static func delaySeconds(outputLatency: Double, inputBuffering: Double) -> Double {
        max(outputLatency, 0) + max(inputBuffering, 0) + marginSeconds
    }

    private weak var host: (any FeedForwardLiveDriverHost)?
    private let pollsAutomatically: Bool
    private let hostSeconds: (UInt64) -> Double
    private var pump: FeedForwardLiveReferencePump?
    private var loop: Task<Void, Never>?
    private(set) var state: State = .idle
    private(set) var delaySeconds: Double?
    private(set) var lastReport: FeedForwardLiveReferencePump.Report?

    init(
        host: any FeedForwardLiveDriverHost, pollsAutomatically: Bool = true,
        hostSeconds: @escaping (UInt64) -> Double = CrossDevicePairCapture.machSeconds
    ) {
        self.host = host
        self.pollsAutomatically = pollsAutomatically
        self.hostSeconds = hostSeconds
    }

    deinit { loop?.cancel() }

    /// Starts the pump on a capture made by `makeReference`. False (state unchanged or stopped) when the
    /// flag is off, no drive tap exists, a pump already runs, or the capture cannot be opened.
    @discardableResult
    func start(latencies: Latencies, makeReference: () throws -> QuietZoneFeedForwardSingleCapturing) -> Bool {
        guard state == .idle, let host, host.liveDriverAllowed, let outputRate = host.liveDriverOutputRate else {
            return false
        }
        let delay = Self.delaySeconds(
            outputLatency: host.liveDriverOutputLatencySeconds(), inputBuffering: latencies.inputBufferingSeconds)
        do {
            let reference = try makeReference()
            let pump = FeedForwardLiveReferencePump(
                reference: reference, sink: host, outputRate: outputRate, delaySeconds: delay,
                referenceLatencySeconds: latencies.inputLatencySeconds, hostSeconds: hostSeconds)
            try pump.start()
            self.pump = pump
        } catch {
            state = .stopped("reference capture could not start: \(error.localizedDescription)")
            return false
        }
        delaySeconds = delay
        host.setPumpDriveDemand(true)
        state = .running
        if pollsAutomatically {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(nanoseconds: Self.intervalNanoseconds)
                }
            }
        }
        return true
    }

    /// One pump cycle (the timer calls this; tests call it directly).
    func tick() {
        guard state == .running, let pump, let host else { return }
        lastReport = pump.step(anchors: host.pullPumpAnchors())
        if case .stopped(let reason) = pump.state { finish(reason) }
    }

    /// Ends the pump (marking the reference lost, which fades the filter) and returns to idle.
    func stop() {
        loop?.cancel()
        loop = nil
        pump?.stop()
        pump = nil
        if state != .idle { host?.setPumpDriveDemand(false) }
        state = .idle
        delaySeconds = nil
    }

    private func finish(_ reason: String) {
        loop?.cancel()
        loop = nil
        host?.setPumpDriveDemand(false)
        pump = nil
        state = .stopped(reason)
    }
}

/// What the shadow asks of the engine: keep the reference ring filled from this microphone channel.
@MainActor
protocol FeedForwardLiveReferenceDriving: AnyObject {
    func startLiveReference(device: AudioInputDevice, channel: Int)
    func stopLiveReference()
}

/// Core Audio latency of a device, in seconds (control plane only).
enum AudioDeviceLatencyReader {
    struct Reading: Equatable {
        /// Device latency, safety offset and first-stream latency.
        var latencySeconds: Double
        var bufferSeconds: Double
    }

    static func read(deviceID: AudioDeviceID, input: Bool, fallbackRate: Double) -> Reading {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let rate = rateOf(deviceID) ?? fallbackRate
        guard rate > 0 else { return Reading(latencySeconds: 0, bufferSeconds: 0) }
        let latency = uint32(deviceID, kAudioDevicePropertyLatency, scope)
        let safety = uint32(deviceID, kAudioDevicePropertySafetyOffset, scope)
        let buffer = uint32(deviceID, kAudioDevicePropertyBufferFrameSize, scope)
        var stream: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size >= 4 {
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ids) == noErr, let first = ids.first {
                stream = uint32(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        return Reading(
            latencySeconds: Double(latency &+ safety &+ stream) / rate, bufferSeconds: Double(buffer) / rate)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func rateOf(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }
}
