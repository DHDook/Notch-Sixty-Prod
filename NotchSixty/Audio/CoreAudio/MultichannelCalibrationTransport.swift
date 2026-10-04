import CoreAudio
import Foundation

struct MultichannelCalibrationCapture: Equatable, Sendable {
    var samples: [Float]
}

enum MultichannelCalibrationTransportError: Error, Equatable, LocalizedError {
    case outputDeviceUnavailable(String)
    case invalidInputChannel(index: Int, availableChannels: Int)
    case outputChannelUnavailable(index: UInt32, availableChannels: Int)
    case sampleRateMismatch(role: String, expected: Double, actual: Double)
    case unsupportedPCMFormat(role: String, format: AudioStreamFormatDescription)
    case frameCountOverflow
    case bridgeAllocationFailed
    case ioProcUnavailable
    case closed
    case incompleteCapture
    case unsupportedRealtimeBufferLayout(UInt64)
    case operationFailed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .outputDeviceUnavailable(let uid):
            return "A calibrated output device is unavailable: \(uid)."
        case .invalidInputChannel(let index, let availableChannels):
            return "Measurement microphone channel \(index + 1) is unavailable; the selected input exposes \(availableChannels) channel(s)."
        case .outputChannelUnavailable(let index, let availableChannels):
            return "Calibration target output channel \(index + 1) is unavailable; the measurement device exposes \(availableChannels) channel(s)."
        case .sampleRateMismatch(let role, let expected, let actual):
            return "Multichannel calibration requires \(role) at \(expected) Hz; Core Audio reported \(actual) Hz."
        case .unsupportedPCMFormat(let role, let format):
            return "Multichannel calibration requires native 32-bit floating-point PCM for \(role); received \(format.sampleRate) Hz, \(format.channelCount) channel(s), \(format.bitsPerChannel)-bit."
        case .frameCountOverflow:
            return "The calibration sweep exceeds the bounded targeted measurement transport."
        case .bridgeAllocationFailed:
            return "Unable to allocate the precomputed targeted measurement bridge."
        case .ioProcUnavailable:
            return "Core Audio did not return a usable targeted calibration IOProc."
        case .closed:
            return "The targeted calibration transport is already closed."
        case .incompleteCapture:
            return "The targeted measurement stopped before its capture completed."
        case .unsupportedRealtimeBufferLayout(let count):
            return "The targeted measurement encountered \(count) unsupported realtime buffer-layout callback(s)."
        case .operationFailed(let operation, let status):
            return "Core Audio \(operation) failed with status \(status)."
        }
    }
}

/// One-source/one-physical-output measurement transport for PR58's source×seat
/// calibration campaign. The realtime bridge zeros every output lane before it
/// writes the selected target, so no non-target speaker can be energized by a
/// stale buffer. All aggregate construction, rate changes and allocations happen
/// on the control plane before the IOProc starts.
final class MultichannelCalibrationTransport {
    let routePlan: LiveNChannelOutputRoutePlan
    let input: AudioInputDevice
    let selectedInputChannelIndex: Int
    let program: RoomCorrectionSweepProgram
    let physicalOutputChannelIndex: UInt32

    private let orderedOutputs: [AudioOutputDevice]
    private var bridge: OpaquePointer?
    private var ioProcID: AudioDeviceIOProcID?
    private var calibrationDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var originalSampleRates: [AudioDeviceID: Double] = [:]
    private var isStarted = false
    private var isClosed = false

    init(
        routePlan: LiveNChannelOutputRoutePlan,
        availableOutputs: [AudioOutputDevice],
        input: AudioInputDevice,
        inputChannelIndex: Int,
        program: RoomCorrectionSweepProgram,
        physicalOutputChannelIndex: UInt32
    ) throws {
        self.routePlan = routePlan
        self.input = input
        self.selectedInputChannelIndex = inputChannelIndex
        self.program = program
        self.physicalOutputChannelIndex = physicalOutputChannelIndex

        var ordered: [AudioOutputDevice] = []
        ordered.reserveCapacity(routePlan.orderedDeviceUIDs.count)
        for uid in routePlan.orderedDeviceUIDs {
            guard let output = availableOutputs.first(where: { $0.uid == uid }) else {
                throw MultichannelCalibrationTransportError.outputDeviceUnavailable(uid)
            }
            ordered.append(output)
        }
        self.orderedOutputs = ordered

        do {
            try prepareHardwareAndBridge()
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func start() throws {
        guard !isClosed else { throw MultichannelCalibrationTransportError.closed }
        guard !isStarted else { return }
        guard let bridge, let ioProcID else {
            throw MultichannelCalibrationTransportError.ioProcUnavailable
        }
        N60TargetedRoomMeasurementBridgeReset(bridge)
        try Self.check(
            AudioDeviceStart(calibrationDeviceID, ioProcID),
            operation: "start targeted multichannel measurement IOProc"
        )
        isStarted = true
    }

    func stop() {
        guard isStarted, let ioProcID else { return }
        AudioDeviceStop(calibrationDeviceID, ioProcID)
        isStarted = false
    }

    func snapshot() -> N60TargetedRoomMeasurementBridgeSnapshot? {
        guard let bridge else { return nil }
        return N60TargetedRoomMeasurementBridgeGetSnapshot(bridge)
    }

    func finishAndMaterialize() throws -> MultichannelCalibrationCapture {
        stop()
        guard let bridge else {
            close()
            throw MultichannelCalibrationTransportError.incompleteCapture
        }
        let snapshot = N60TargetedRoomMeasurementBridgeGetSnapshot(bridge)
        guard snapshot.unsupportedBufferLayouts == 0 else {
            let count = snapshot.unsupportedBufferLayouts
            close()
            throw MultichannelCalibrationTransportError.unsupportedRealtimeBufferLayout(count)
        }
        guard snapshot.complete else {
            close()
            throw MultichannelCalibrationTransportError.incompleteCapture
        }

        let frameCount = program.captureFrameCount
        var samples = [Float](repeating: 0, count: frameCount)
        let copied = samples.withUnsafeMutableBufferPointer { buffer in
            N60TargetedRoomMeasurementBridgeCopyCapture(
                bridge,
                buffer.baseAddress!,
                UInt32(buffer.count)
            )
        }
        guard copied == UInt32(frameCount) else {
            close()
            throw MultichannelCalibrationTransportError.incompleteCapture
        }
        close()
        return MultichannelCalibrationCapture(samples: samples)
    }

    func cancel() { close() }

    private func prepareHardwareAndBridge() throws {
        let sampleRate = program.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw MultichannelCalibrationTransportError.sampleRateMismatch(
                role: "measurement program",
                expected: sampleRate,
                actual: sampleRate
            )
        }
        guard physicalOutputChannelIndex < routePlan.physicalChannelCount else {
            throw MultichannelCalibrationTransportError.outputChannelUnavailable(
                index: physicalOutputChannelIndex,
                availableChannels: Int(routePlan.physicalChannelCount)
            )
        }
        guard let referenceOutput = orderedOutputs.first(where: { $0.uid == routePlan.referenceDeviceUID }) else {
            throw MultichannelCalibrationTransportError.outputDeviceUnavailable(routePlan.referenceDeviceUID)
        }

        let referenceRate = try Self.readNominalSampleRate(deviceID: referenceOutput.deviceID)
        guard abs(referenceRate - sampleRate) < 0.5 else {
            throw MultichannelCalibrationTransportError.sampleRateMismatch(
                role: "reference output",
                expected: sampleRate,
                actual: referenceRate
            )
        }

        // Non-reference devices and the measurement input may be temporarily moved
        // to the campaign rate. Every successful write is recorded immediately so
        // teardown restores the user's previous hardware state on any later error.
        for output in orderedOutputs where output.deviceID != referenceOutput.deviceID {
            try ensureSampleRate(output.deviceID, expected: sampleRate, role: "output \(output.name)")
        }
        if !orderedOutputs.contains(where: { $0.deviceID == input.deviceID }) {
            try ensureSampleRate(input.deviceID, expected: sampleRate, role: "measurement microphone")
        } else {
            let rate = try Self.readNominalSampleRate(deviceID: input.deviceID)
            guard abs(rate - sampleRate) < 0.5 else {
                throw MultichannelCalibrationTransportError.sampleRateMismatch(
                    role: "measurement microphone",
                    expected: sampleRate,
                    actual: rate
                )
            }
        }

        let useDirectDevice = orderedOutputs.count == 1 && input.deviceID == orderedOutputs[0].deviceID
        let aggregateInputChannel: Int
        if useDirectDevice {
            calibrationDeviceID = orderedOutputs[0].deviceID
            aggregateInputChannel = selectedInputChannelIndex
        } else {
            let aggregate = try makePrivateAggregate(referenceOutput: referenceOutput, sampleRate: sampleRate)
            aggregateDeviceID = aggregate.deviceID
            calibrationDeviceID = aggregate.deviceID
            aggregateInputChannel = aggregate.inputChannelIndex
        }

        let inputChannelCount = try Self.readChannelCount(
            deviceID: calibrationDeviceID,
            scope: kAudioObjectPropertyScopeInput,
            operation: "read targeted calibration input channel count"
        )
        guard aggregateInputChannel >= 0, aggregateInputChannel < inputChannelCount else {
            throw MultichannelCalibrationTransportError.invalidInputChannel(
                index: aggregateInputChannel,
                availableChannels: inputChannelCount
            )
        }
        let outputChannelCount = try Self.readChannelCount(
            deviceID: calibrationDeviceID,
            scope: kAudioObjectPropertyScopeOutput,
            operation: "read targeted calibration output channel count"
        )
        guard physicalOutputChannelIndex < UInt32(outputChannelCount) else {
            throw MultichannelCalibrationTransportError.outputChannelUnavailable(
                index: physicalOutputChannelIndex,
                availableChannels: outputChannelCount
            )
        }

        let inputFormat = AudioStreamFormatDescription(
            try Self.readStreamFormat(
                deviceID: calibrationDeviceID,
                scope: kAudioObjectPropertyScopeInput,
                operation: "read targeted calibration input format"
            )
        )
        let outputFormat = AudioStreamFormatDescription(
            try Self.readStreamFormat(
                deviceID: calibrationDeviceID,
                scope: kAudioObjectPropertyScopeOutput,
                operation: "read targeted calibration output format"
            )
        )
        try Self.validateFloatPCM(inputFormat, role: "measurement input")
        try Self.validateFloatPCM(outputFormat, role: "measurement output")
        try Self.validateSampleRate(inputFormat, expected: sampleRate, role: "measurement input")
        try Self.validateSampleRate(outputFormat, expected: sampleRate, role: "measurement output")

        let sweepFrames = try Self.checkedUInt32(program.sweepSamples.count)
        let leadInFrames = try Self.checkedUInt32(program.leadInFrames)
        let tailFrames = try Self.checkedUInt32(program.tailFrames)
        let inputChannel = try Self.checkedUInt32(aggregateInputChannel)
        bridge = program.sweepSamples.withUnsafeBufferPointer { buffer in
            N60TargetedRoomMeasurementBridgeCreate(
                buffer.baseAddress!,
                sweepFrames,
                leadInFrames,
                tailFrames,
                inputChannel,
                physicalOutputChannelIndex
            )
        }
        guard let bridge else {
            throw MultichannelCalibrationTransportError.bridgeAllocationFailed
        }
        guard N60TargetedRoomMeasurementBridgeGetSnapshot(bridge).totalFrameCount
            == UInt32(program.captureFrameCount) else {
            throw MultichannelCalibrationTransportError.frameCountOverflow
        }

        try Self.check(
            AudioDeviceCreateIOProcID(
                calibrationDeviceID,
                N60TargetedRoomMeasurementIOProc,
                UnsafeMutableRawPointer(bridge),
                &ioProcID
            ),
            operation: "create targeted multichannel measurement IOProc"
        )
        guard ioProcID != nil else {
            throw MultichannelCalibrationTransportError.ioProcUnavailable
        }
    }

    private func ensureSampleRate(
        _ deviceID: AudioDeviceID,
        expected: Double,
        role: String
    ) throws {
        let original = try Self.readNominalSampleRate(deviceID: deviceID)
        guard abs(original - expected) >= 0.5 else { return }
        originalSampleRates[deviceID] = original
        try Self.writeNominalSampleRate(
            deviceID: deviceID,
            sampleRate: expected,
            operation: "set \(role) sample rate"
        )
        let applied = try Self.readNominalSampleRate(deviceID: deviceID)
        guard abs(applied - expected) < 0.5 else {
            throw MultichannelCalibrationTransportError.sampleRateMismatch(
                role: role,
                expected: expected,
                actual: applied
            )
        }
    }

    private func makePrivateAggregate(
        referenceOutput: AudioOutputDevice,
        sampleRate: Double
    ) throws -> (deviceID: AudioDeviceID, inputChannelIndex: Int) {
        var subdevices: [[String: Any]] = []
        var aggregateInputOffset = 0
        var resolvedInputChannel: Int?

        for output in orderedOutputs {
            if output.deviceID == input.deviceID {
                resolvedInputChannel = aggregateInputOffset + selectedInputChannelIndex
            }
            let inputChannels = (try? Self.readChannelCount(
                deviceID: output.deviceID,
                scope: kAudioObjectPropertyScopeInput,
                operation: "read output subdevice input channel count"
            )) ?? 0
            aggregateInputOffset += inputChannels
            subdevices.append([
                kAudioSubDeviceUIDKey: output.uid,
                kAudioSubDeviceDriftCompensationKey: output.uid != routePlan.referenceDeviceUID,
            ])
        }

        if !orderedOutputs.contains(where: { $0.deviceID == input.deviceID }) {
            resolvedInputChannel = aggregateInputOffset + selectedInputChannelIndex
            subdevices.append([
                kAudioSubDeviceUIDKey: input.uid,
                kAudioSubDeviceDriftCompensationKey: true,
            ])
        }
        guard let resolvedInputChannel else {
            throw MultichannelCalibrationTransportError.invalidInputChannel(
                index: selectedInputChannelIndex,
                availableChannels: 0
            )
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notch Sixty Multichannel Calibration",
            kAudioAggregateDeviceUIDKey: "com.dhdook.NotchSixty.multichannel-calibration.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceMainSubDeviceKey: routePlan.referenceDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: routePlan.referenceDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
        ]
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
            operation: "create private multichannel calibration aggregate"
        )
        try Self.waitForDeviceAlive(deviceID)
        try Self.writeNominalSampleRate(
            deviceID: deviceID,
            sampleRate: sampleRate,
            operation: "set multichannel calibration aggregate sample rate"
        )
        let applied = try Self.readNominalSampleRate(deviceID: deviceID)
        guard abs(applied - sampleRate) < 0.5 else {
            throw MultichannelCalibrationTransportError.sampleRateMismatch(
                role: "calibration aggregate",
                expected: sampleRate,
                actual: applied
            )
        }
        let bufferFrames = try Self.readUInt32Property(
            objectID: referenceOutput.deviceID,
            selector: kAudioDevicePropertyBufferFrameSize,
            scope: kAudioObjectPropertyScopeGlobal,
            operation: "read reference output buffer size"
        )
        try Self.writeUInt32Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyBufferFrameSize,
            scope: kAudioObjectPropertyScopeGlobal,
            value: bufferFrames,
            operation: "set calibration aggregate buffer size"
        )
        return (deviceID, resolvedInputChannel)
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        stop()

        if let ioProcID, calibrationDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioDeviceDestroyIOProcID(calibrationDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        }
        calibrationDeviceID = AudioDeviceID(kAudioObjectUnknown)

        for (deviceID, sampleRate) in originalSampleRates {
            try? Self.writeNominalSampleRate(
                deviceID: deviceID,
                sampleRate: sampleRate,
                operation: "restore calibration device sample rate"
            )
        }
        originalSampleRates.removeAll()

        if let bridge {
            N60TargetedRoomMeasurementBridgeDestroy(bridge)
            self.bridge = nil
        }
    }

    private static func validateFloatPCM(
        _ format: AudioStreamFormatDescription,
        role: String
    ) throws {
        guard format.isFloatPCM, format.bitsPerChannel == 32 else {
            throw MultichannelCalibrationTransportError.unsupportedPCMFormat(role: role, format: format)
        }
    }

    private static func validateSampleRate(
        _ format: AudioStreamFormatDescription,
        expected: Double,
        role: String
    ) throws {
        guard format.sampleRate.isFinite, abs(format.sampleRate - expected) < 0.5 else {
            throw MultichannelCalibrationTransportError.sampleRateMismatch(
                role: role,
                expected: expected,
                actual: format.sampleRate
            )
        }
    }

    private static func checkedUInt32(_ value: Int) throws -> UInt32 {
        guard value >= 0, UInt64(value) <= UInt64(UInt32.max) else {
            throw MultichannelCalibrationTransportError.frameCountOverflow
        }
        return UInt32(value)
    }

    private static func readStreamFormat(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &format),
            operation: operation
        )
        return format
    }

    private static func readChannelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            operation: operation
        )
        guard dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, list),
            operation: operation
        )
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private static func readNominalSampleRate(deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value),
            operation: "read targeted calibration nominal sample rate"
        )
        return value
    }

    private static func writeNominalSampleRate(
        deviceID: AudioDeviceID,
        sampleRate: Double,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(sampleRate)
        try check(
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float64>.size),
                &value
            ),
            operation: operation
        )
    }

    private static func readUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value),
            operation: operation
        )
        return value
    }

    private static func writeUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: UInt32,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        try check(
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &mutableValue
            ),
            operation: operation
        )
    }

    private static func waitForDeviceAlive(_ deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for _ in 0..<40 {
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
            if status == noErr, alive != 0 { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw MultichannelCalibrationTransportError.operationFailed(
            operation: "wait for private calibration aggregate",
            status: kAudioHardwareUnspecifiedError
        )
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw MultichannelCalibrationTransportError.operationFailed(
                operation: operation,
                status: status
            )
        }
    }
}
