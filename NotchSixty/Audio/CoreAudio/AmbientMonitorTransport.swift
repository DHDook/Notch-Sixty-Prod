import CoreAudio
import Foundation

enum AmbientMonitorTransportError: Error, Equatable, LocalizedError {
    case invalidInputChannel(index: Int, availableChannels: Int)
    case unsupportedPCMFormat(sampleRate: Double, channels: Int, bits: Int)
    case invalidSampleRate(Double)
    case bridgeAllocationFailed
    case ioProcUnavailable
    case closed
    case unsupportedRealtimeBufferLayout(UInt64)
    case operationFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidInputChannel(let index, let availableChannels):
            return "Ambient monitor microphone channel \(index + 1) is unavailable; the selected input exposes \(availableChannels) channel(s)."
        case .unsupportedPCMFormat(let sampleRate, let channels, let bits):
            return "Ambient monitoring requires native 32-bit floating-point PCM; the microphone reports \(sampleRate) Hz, \(channels) channel(s), \(bits)-bit."
        case .invalidSampleRate(let sampleRate):
            return "Ambient monitor microphone sample rate \(sampleRate) Hz is invalid."
        case .bridgeAllocationFailed:
            return "Unable to allocate the ambient monitor realtime capture bridge."
        case .ioProcUnavailable:
            return "Core Audio did not return a usable ambient-monitor IOProc."
        case .closed:
            return "Ambient monitor transport is already closed."
        case .unsupportedRealtimeBufferLayout(let count):
            return "Ambient monitoring encountered \(count) unsupported input-buffer callback(s)."
        case .operationFailed(let operation, let status):
            return "Core Audio \(operation) failed with status \(status)."
        }
    }
}

/// Input-only microphone transport that may run alongside normal playback.
///
/// The HAL callback is implemented entirely in the C ambient-monitor bridge.
/// Swift only starts/stops hardware and drains the SPSC ring off the callback.
final class AmbientMonitorTransport {
    static let ringCapacityFrames: UInt32 = 131_072

    let input: AudioInputDevice
    let selectedInputChannelIndex: Int
    let sampleRate: Double

    private var bridge: OpaquePointer?
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private var isClosed = false

    init(
        input: AudioInputDevice,
        inputChannelIndex: Int
    ) throws {
        self.input = input
        self.selectedInputChannelIndex = inputChannelIndex

        let channelCount = try Self.readChannelCount(
            deviceID: input.deviceID
        )
        guard inputChannelIndex >= 0,
              inputChannelIndex < channelCount else {
            throw AmbientMonitorTransportError.invalidInputChannel(
                index: inputChannelIndex,
                availableChannels: channelCount
            )
        }

        let format = try Self.readInputStreamFormat(
            deviceID: input.deviceID
        )
        let description = AudioStreamFormatDescription(format)
        guard description.isFloatPCM,
              description.bitsPerChannel == 32 else {
            throw AmbientMonitorTransportError.unsupportedPCMFormat(
                sampleRate: description.sampleRate,
                channels: description.channelCount,
                bits: description.bitsPerChannel
            )
        }
        guard description.sampleRate.isFinite,
              description.sampleRate > 0 else {
            throw AmbientMonitorTransportError.invalidSampleRate(
                description.sampleRate
            )
        }
        self.sampleRate = description.sampleRate

        guard let bridge = N60AmbientMonitorBridgeCreate(
            Self.ringCapacityFrames,
            UInt32(inputChannelIndex)
        ) else {
            throw AmbientMonitorTransportError.bridgeAllocationFailed
        }
        self.bridge = bridge

        do {
            try Self.check(
                AudioDeviceCreateIOProcID(
                    input.deviceID,
                    N60AmbientMonitorIOProc,
                    UnsafeMutableRawPointer(bridge),
                    &ioProcID
                ),
                operation: "create ambient-monitor IOProc"
            )
            guard ioProcID != nil else {
                throw AmbientMonitorTransportError.ioProcUnavailable
            }
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func start() throws {
        guard !isClosed else {
            throw AmbientMonitorTransportError.closed
        }
        guard !isStarted else { return }
        guard let bridge, let ioProcID else {
            throw AmbientMonitorTransportError.ioProcUnavailable
        }
        N60AmbientMonitorBridgeReset(bridge)
        try Self.check(
            AudioDeviceStart(input.deviceID, ioProcID),
            operation: "start ambient-monitor IOProc"
        )
        isStarted = true
    }

    func stop() {
        guard isStarted, let ioProcID else { return }
        AudioDeviceStop(input.deviceID, ioProcID)
        isStarted = false
    }

    func snapshot() -> N60AmbientMonitorSnapshot? {
        guard let bridge else { return nil }
        return N60AmbientMonitorBridgeGetSnapshot(bridge)
    }

    func readAvailableFrames(
        maximumFrames: Int = Int(ringCapacityFrames)
    ) throws -> [Float] {
        guard !isClosed, let bridge else {
            throw AmbientMonitorTransportError.closed
        }
        let state = N60AmbientMonitorBridgeGetSnapshot(bridge)
        guard state.unsupportedBufferLayouts == 0 else {
            throw AmbientMonitorTransportError
                .unsupportedRealtimeBufferLayout(
                    state.unsupportedBufferLayouts
                )
        }
        let capacity = min(
            max(maximumFrames, 0),
            Int(state.availableFrames)
        )
        guard capacity > 0 else { return [] }

        var result = [Float](repeating: 0, count: capacity)
        let count = result.withUnsafeMutableBufferPointer { buffer in
            N60AmbientMonitorBridgeReadFrames(
                bridge,
                buffer.baseAddress!,
                UInt32(buffer.count)
            )
        }
        if Int(count) < result.count {
            result.removeLast(result.count - Int(count))
        }
        return result
    }

    func discardBufferedFrames() {
        guard let bridge else { return }
        N60AmbientMonitorBridgeDiscardFrames(bridge)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        stop()
        if let ioProcID {
            AudioDeviceDestroyIOProcID(input.deviceID, ioProcID)
            self.ioProcID = nil
        }
        if let bridge {
            N60AmbientMonitorBridgeDestroy(bridge)
            self.bridge = nil
        }
    }

    private static func readInputStreamFormat(
        deviceID: AudioDeviceID
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(
            MemoryLayout<AudioStreamBasicDescription>.size
        )
        try check(
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &format
            ),
            operation: "read ambient-monitor input format"
        )
        return format
    }

    private static func readChannelCount(
        deviceID: AudioDeviceID
    ) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &dataSize
            ),
            operation: "read ambient-monitor channel count"
        )
        guard dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(
            to: AudioBufferList.self,
            capacity: 1
        )
        try check(
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                list
            ),
            operation: "read ambient-monitor channel layout"
        )
        return UnsafeMutableAudioBufferListPointer(list)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func check(
        _ status: OSStatus,
        operation: String
    ) throws {
        guard status == noErr else {
            throw AmbientMonitorTransportError.operationFailed(
                operation: operation,
                status: status
            )
        }
    }
}
