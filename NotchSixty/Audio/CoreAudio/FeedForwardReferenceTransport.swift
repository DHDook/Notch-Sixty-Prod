import CoreAudio
import Foundation

enum FeedForwardReferenceTransportError: Error, LocalizedError {
    case invalidInput
    case unsupportedFormat
    case bridgeUnavailable
    case ioProcUnavailable
    case closed
    case callbackFault
    case coreAudioFailure(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "Reference microphone channel is unavailable."
        case .unsupportedFormat: return "Reference input requires native 32-bit floating-point PCM."
        case .bridgeUnavailable: return "Could not allocate the realtime reference buffer."
        case .ioProcUnavailable: return "Core Audio reference callback is unavailable."
        case .closed: return "Reference capture has already been closed."
        case .callbackFault: return "Timestamp or format discontinuity in the reference callback; re-calibrate."
        case .coreAudioFailure(let action, let code):
            return "Core Audio \(action) failed (\(code))."
        }
    }
}

/// Input-only low-latency reference-capture substrate. Unlike PR90's ambient
/// 250ms FFT polling, the C IOProc timestamps *every incoming callback* and
/// writes samples to a bounded SPSC ring. This class never generates audio.
/// A separate verified DAC/output path is needed before feed-forward ANC can arm.
final class FeedForwardReferenceTransport {
    static let minimumCapacityFrames: UInt32 = 8_192
    /// The worker must drain the ring within this time, or frames drop and
    /// `read` / `readPair` fail closed.
    static let drainDeadlineSeconds = 0.25

    /// Power of two holding the drain deadline at the device rate (8,192
    /// frames minimum; 131,072 at 384 kHz).
    static func capacityFrames(sampleRate: Double) -> UInt32 {
        let needed = UInt32(min(max(sampleRate * drainDeadlineSeconds, 1), Double(1 << 24)).rounded(.up))
        var capacity = minimumCapacityFrames
        while capacity < needed { capacity <<= 1 }
        return capacity
    }

    let microphone: AudioInputDevice
    let inputChannelIndex: Int
    /// E4 S9b1: the error microphone's channel on the same device, captured
    /// sample-aligned with the reference (pair mode); nil for reference only.
    let errorChannelIndex: Int?
    let sampleRate: Double

    private var bridge: OpaquePointer?
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false
    private var closed = false

    init(microphone: AudioInputDevice, inputChannelIndex: Int, errorChannelIndex: Int? = nil) throws {
        self.microphone = microphone
        self.inputChannelIndex = inputChannelIndex
        self.errorChannelIndex = errorChannelIndex

        var channelProperty = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try Self.check(AudioObjectGetPropertyDataSize(
            microphone.deviceID, &channelProperty, 0, nil, &size),
            action: "reference channel count")
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            throw FeedForwardReferenceTransportError.invalidInput
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        try Self.check(AudioObjectGetPropertyData(
            microphone.deviceID, &channelProperty, 0, nil, &size, list),
            action: "reference channel layout")
        let channels = UnsafeMutableAudioBufferListPointer(list)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
        guard inputChannelIndex >= 0, inputChannelIndex < channels else {
            throw FeedForwardReferenceTransportError.invalidInput
        }
        if let errorChannelIndex {
            guard errorChannelIndex >= 0, errorChannelIndex < channels,
                  errorChannelIndex != inputChannelIndex else {
                throw FeedForwardReferenceTransportError.invalidInput
            }
        }

        var stream = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(
            microphone.deviceID, &stream, 0, nil, &size, &asbd),
            action: "reference input format")
        let format = AudioStreamFormatDescription(asbd)
        guard format.isFloatPCM, format.bitsPerChannel == 32,
              format.sampleRate.isFinite, format.sampleRate >= 8_000 else {
            throw FeedForwardReferenceTransportError.unsupportedFormat
        }
        sampleRate = format.sampleRate

        let capacity = Self.capacityFrames(sampleRate: sampleRate)
        let created = errorChannelIndex.map {
            N60FeedForwardReferenceBridgeCreatePair(
                capacity, UInt32(inputChannelIndex), UInt32($0))
        } ?? N60FeedForwardReferenceBridgeCreate(
            capacity, UInt32(inputChannelIndex))
        guard let bridge = created else {
            throw FeedForwardReferenceTransportError.bridgeUnavailable
        }
        self.bridge = bridge
        do {
            try Self.check(AudioDeviceCreateIOProcID(
                microphone.deviceID,
                N60FeedForwardReferenceIOProc,
                UnsafeMutableRawPointer(bridge),
                &ioProcID),
                action: "register reference callback")
            guard ioProcID != nil else {
                throw FeedForwardReferenceTransportError.ioProcUnavailable
            }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func start() throws {
        guard !closed else { throw FeedForwardReferenceTransportError.closed }
        guard !started else { return }
        guard let bridge, let ioProcID else {
            throw FeedForwardReferenceTransportError.ioProcUnavailable
        }
        N60FeedForwardReferenceBridgeReset(bridge)
        try Self.check(
            AudioDeviceStart(microphone.deviceID, ioProcID),
            action: "start timestamped reference")
        started = true
    }

    func stop() {
        guard started, let ioProcID else { return }
        AudioDeviceStop(microphone.deviceID, ioProcID)
        started = false
    }

    func snapshot() -> N60FeedForwardReferenceSnapshot? {
        guard let bridge else { return nil }
        return N60FeedForwardReferenceBridgeGetSnapshot(bridge)
    }

    /// Off the realtime callback; no `Task.sleep(250ms)`/ambient FFT needed.
    /// Data still needs a correctly time-aligned DAC/anti-noise output path.
    func read(maximumFrames: Int = 256)
        throws -> [N60FeedForwardReferenceFrame] {
        guard !closed, let bridge else {
            throw FeedForwardReferenceTransportError.closed
        }
        let snap = N60FeedForwardReferenceBridgeGetSnapshot(bridge)
        guard snap.unsupportedBufferLayouts == 0,
              snap.invalidTimestamps == 0,
              snap.droppedFrames == 0 else {
            throw FeedForwardReferenceTransportError.callbackFault
        }
        let length = min(max(maximumFrames, 0), Int(snap.availableFrames))
        guard length > 0 else { return [] }
        var frames = [N60FeedForwardReferenceFrame](
            repeating: N60FeedForwardReferenceFrame(),
            count: length)
        let count = frames.withUnsafeMutableBufferPointer { buffer in
            N60FeedForwardReferenceBridgeRead(
                bridge, buffer.baseAddress!, UInt32(buffer.count))
        }
        if Int(count) < frames.count {
            frames.removeLast(frames.count - Int(count))
        }
        return frames
    }

    /// Pair mode: reference frames with the error samples recorded with them.
    /// Fails closed like `read` on any callback fault.
    func readPair(maximumFrames: Int = 8_192)
        throws -> (reference: [N60FeedForwardReferenceFrame], error: [Float]) {
        guard !closed, let bridge, errorChannelIndex != nil else {
            throw FeedForwardReferenceTransportError.closed
        }
        let snap = N60FeedForwardReferenceBridgeGetSnapshot(bridge)
        guard snap.unsupportedBufferLayouts == 0,
              snap.invalidTimestamps == 0,
              snap.droppedFrames == 0 else {
            throw FeedForwardReferenceTransportError.callbackFault
        }
        let length = min(max(maximumFrames, 0), Int(snap.availableFrames))
        guard length > 0 else { return ([], []) }
        var frames = [N60FeedForwardReferenceFrame](repeating: N60FeedForwardReferenceFrame(), count: length)
        var errors = [Float](repeating: 0, count: length)
        let count = frames.withUnsafeMutableBufferPointer { f in
            errors.withUnsafeMutableBufferPointer { e in
                N60FeedForwardReferenceBridgeReadPair(
                    bridge, f.baseAddress!, e.baseAddress!, UInt32(length))
            }
        }
        frames.removeLast(length - Int(count))
        errors.removeLast(length - Int(count))
        return (frames, errors)
    }

    func close() {
        guard !closed else { return }
        closed = true
        stop()
        if let ioProcID {
            AudioDeviceDestroyIOProcID(microphone.deviceID, ioProcID)
            self.ioProcID = nil
        }
        if let bridge {
            N60FeedForwardReferenceBridgeDestroy(bridge)
            self.bridge = nil
        }
    }

    private static func check(_ code: OSStatus, action: String) throws {
        guard code == noErr else {
            throw FeedForwardReferenceTransportError
                .coreAudioFailure(action, code)
        }
    }
}
