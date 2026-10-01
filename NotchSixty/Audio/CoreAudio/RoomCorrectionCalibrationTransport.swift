import CoreAudio
import Foundation

struct RoomCorrectionCalibrationCapture: Equatable, Sendable {
    var left: [Float]
    var right: [Float]
}

enum RoomCorrectionCalibrationTransportError: Error, Equatable, LocalizedError {
    case outputSampleRateMismatch(expected: Double, actual: Double)
    case sampleRateMismatch(role: String, expected: Double, actual: Double)
    case invalidInputChannel(index: Int, availableChannels: Int)
    case insufficientOutputChannels(Int)
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
        case .outputSampleRateMismatch(let expected, let actual):
            return "Room measurement requires the selected output to be running at \(expected) Hz; it is currently at \(actual) Hz."
        case .sampleRateMismatch(let role, let expected, let actual):
            return "Room measurement requires \(role) to run natively at \(expected) Hz; Core Audio reported \(actual) Hz."
        case .invalidInputChannel(let index, let availableChannels):
            return "Measurement microphone channel \(index + 1) is unavailable; the selected input exposes \(availableChannels) channel(s)."
        case .insufficientOutputChannels(let channels):
            return "Room measurement requires at least two physical output channels; the selected output exposes \(channels)."
        case .unsupportedPCMFormat(let role, let format):
            return "Room measurement requires native 32-bit floating-point PCM for \(role); received \(format.sampleRate) Hz, \(format.channelCount) channel(s), \(format.bitsPerChannel)-bit."
        case .frameCountOverflow:
            return "Room measurement requires more frames than the calibration transport supports."
        case .bridgeAllocationFailed:
            return "Unable to allocate the preallocated room-measurement realtime bridge."
        case .ioProcUnavailable:
            return "Core Audio did not return a usable room-measurement IOProc."
        case .closed:
            return "Room-measurement transport is already closed."
        case .incompleteCapture:
            return "Room measurement stopped before both loudspeaker passes were captured completely."
        case .unsupportedRealtimeBufferLayout(let count):
            return "Room measurement encountered \(count) unsupported realtime audio buffer layout callback(s)."
        case .operationFailed(let operation, let status):
            return "Core Audio \(operation) failed with status \(status)."
        }
    }
}

/// Calibration-only full-duplex Core Audio transport.
///
/// This object is intentionally separate from `CoreAudioTransportSession`. Normal
/// system-audio DSP must already be idle before `start()` is called. For separate
/// input/output devices it creates a private aggregate whose clock-leading/main
/// subdevice is the selected physical output and whose microphone subdevice uses
/// drift compensation. All realtime sweep/capture work remains in the C bridge.
final class RoomCorrectionCalibrationTransport {
    let output: AudioOutputDevice
    let input: AudioInputDevice
    let selectedInputChannelIndex: Int
    let plan: RoomCorrectionMeasurementPlan
    let topology: RoomCorrectionCalibrationTopology

    private var bridge: OpaquePointer?
    private var ioProcID: AudioDeviceIOProcID?
    private var calibrationDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var originalInputSampleRate: Double?
    private var inputSampleRateWasChanged = false
    private var isStarted = false
    private var isClosed = false

    init(
        output: AudioOutputDevice,
        input: AudioInputDevice,
        inputChannelIndex: Int,
        plan: RoomCorrectionMeasurementPlan
    ) throws {
        self.output = output
        self.input = input
        self.selectedInputChannelIndex = inputChannelIndex
        self.plan = plan
        self.topology = try RoomCorrectionCalibrationTopologyPlanner.validatedTopology(
            output: output,
            input: input,
            sampleRate: plan.program.sampleRate
        )

        do {
            try prepareHardwareAndBridge()
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
            throw RoomCorrectionCalibrationTransportError.closed
        }
        guard !isStarted else { return }
        guard let bridge, let ioProcID else {
            throw RoomCorrectionCalibrationTransportError.ioProcUnavailable
        }
        N60RoomMeasurementBridgeReset(bridge)
        try Self.check(
            AudioDeviceStart(calibrationDeviceID, ioProcID),
            operation: "start room-measurement IOProc"
        )
        isStarted = true
    }

    func stop() {
        guard isStarted, let ioProcID else { return }
        AudioDeviceStop(calibrationDeviceID, ioProcID)
        isStarted = false
    }

    func snapshot() -> N60RoomMeasurementBridgeSnapshot? {
        guard let bridge else { return nil }
        return N60RoomMeasurementBridgeGetSnapshot(bridge)
    }

    /// Stops hardware, verifies exact paired capture completion, copies the two
    /// bounded C capture buffers to ordinary Swift project memory, then releases
    /// the calibration IOProc/aggregate and restores any temporary mic rate.
    func finishAndMaterialize() throws -> RoomCorrectionCalibrationCapture {
        stop()
        guard let bridge else {
            close()
            throw RoomCorrectionCalibrationTransportError.incompleteCapture
        }
        let snapshot = N60RoomMeasurementBridgeGetSnapshot(bridge)
        guard snapshot.unsupportedBufferLayouts == 0 else {
            let count = snapshot.unsupportedBufferLayouts
            close()
            throw RoomCorrectionCalibrationTransportError.unsupportedRealtimeBufferLayout(count)
        }
        guard snapshot.complete else {
            close()
            throw RoomCorrectionCalibrationTransportError.incompleteCapture
        }

        let captureFrames = plan.program.captureFrameCount
        var left = [Float](repeating: 0, count: captureFrames)
        var right = [Float](repeating: 0, count: captureFrames)
        let leftCopied = left.withUnsafeMutableBufferPointer { buffer in
            N60RoomMeasurementBridgeCopyLeftCapture(
                bridge,
                buffer.baseAddress!,
                UInt32(buffer.count)
            )
        }
        let rightCopied = right.withUnsafeMutableBufferPointer { buffer in
            N60RoomMeasurementBridgeCopyRightCapture(
                bridge,
                buffer.baseAddress!,
                UInt32(buffer.count)
            )
        }
        guard leftCopied == UInt32(captureFrames), rightCopied == UInt32(captureFrames) else {
            close()
            throw RoomCorrectionCalibrationTransportError.incompleteCapture
        }

        close()
        return RoomCorrectionCalibrationCapture(left: left, right: right)
    }

    func cancel() {
        close()
    }

    private func prepareHardwareAndBridge() throws {
        let sampleRate = plan.program.sampleRate
        let actualOutputSampleRate = try Self.readNominalSampleRate(deviceID: output.deviceID)
        guard abs(actualOutputSampleRate - sampleRate) < 0.5 else {
            throw RoomCorrectionCalibrationTransportError.outputSampleRateMismatch(
                expected: sampleRate,
                actual: actualOutputSampleRate
            )
        }

        let outputChannelCount = try Self.readChannelCount(
            deviceID: output.deviceID,
            scope: kAudioObjectPropertyScopeOutput,
            operation: "read room-measurement output channel count"
        )
        guard outputChannelCount >= 2 else {
            throw RoomCorrectionCalibrationTransportError.insufficientOutputChannels(outputChannelCount)
        }

        let inputChannelCount = try Self.readChannelCount(
            deviceID: input.deviceID,
            scope: kAudioObjectPropertyScopeInput,
            operation: "read room-measurement input channel count"
        )
        guard selectedInputChannelIndex >= 0, selectedInputChannelIndex < inputChannelCount else {
            throw RoomCorrectionCalibrationTransportError.invalidInputChannel(
                index: selectedInputChannelIndex,
                availableChannels: inputChannelCount
            )
        }

        let outputFormat = AudioStreamFormatDescription(
            try Self.readStreamFormat(
                deviceID: output.deviceID,
                scope: kAudioObjectPropertyScopeOutput,
                operation: "read room-measurement output format"
            )
        )
        try Self.validateFloatPCM(outputFormat, role: "physical output")
        try Self.validateSampleRate(outputFormat, expected: sampleRate, role: "physical output stream")

        var aggregateInputChannelIndex = selectedInputChannelIndex
        switch topology {
        case .direct:
            calibrationDeviceID = output.deviceID
        case .privateAggregate:
            originalInputSampleRate = try Self.readNominalSampleRate(deviceID: input.deviceID)
            if let originalInputSampleRate, abs(originalInputSampleRate - sampleRate) >= 0.5 {
                try Self.writeNominalSampleRate(
                    deviceID: input.deviceID,
                    sampleRate: sampleRate,
                    operation: "set measurement microphone sample rate"
                )
                // Mark immediately after a successful device write so teardown
                // restores the user's prior rate even if verification or later
                // aggregate setup fails.
                inputSampleRateWasChanged = true
                let applied = try Self.readNominalSampleRate(deviceID: input.deviceID)
                guard abs(applied - sampleRate) < 0.5 else {
                    throw RoomCorrectionCalibrationTransportError.sampleRateMismatch(
                        role: "measurement microphone",
                        expected: sampleRate,
                        actual: applied
                    )
                }
            }

            let outputInputChannels = (try? Self.readChannelCount(
                deviceID: output.deviceID,
                scope: kAudioObjectPropertyScopeInput,
                operation: "read aggregate output-subdevice input channel count"
            )) ?? 0
            aggregateInputChannelIndex = outputInputChannels + selectedInputChannelIndex

            let aggregateDescription = Self.aggregateDescription(output: output, input: input)
            try Self.check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &aggregateDeviceID
                ),
                operation: "create private room-measurement aggregate"
            )
            calibrationDeviceID = aggregateDeviceID

            try Self.writeNominalSampleRate(
                deviceID: aggregateDeviceID,
                sampleRate: sampleRate,
                operation: "set room-measurement aggregate sample rate"
            )
            let aggregateSampleRate = try Self.readNominalSampleRate(deviceID: aggregateDeviceID)
            guard abs(aggregateSampleRate - sampleRate) < 0.5 else {
                throw RoomCorrectionCalibrationTransportError.sampleRateMismatch(
                    role: "room-measurement aggregate",
                    expected: sampleRate,
                    actual: aggregateSampleRate
                )
            }
            let outputBufferFrames = try Self.readUInt32Property(
                objectID: output.deviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read physical output buffer size for room measurement"
            )
            try Self.writeUInt32Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                value: outputBufferFrames,
                operation: "set room-measurement aggregate buffer size"
            )
        }

        let inputFormat = AudioStreamFormatDescription(
            try Self.readStreamFormat(
                deviceID: calibrationDeviceID,
                scope: kAudioObjectPropertyScopeInput,
                operation: "read room-measurement device input format"
            )
        )
        let calibrationOutputFormat = AudioStreamFormatDescription(
            try Self.readStreamFormat(
                deviceID: calibrationDeviceID,
                scope: kAudioObjectPropertyScopeOutput,
                operation: "read room-measurement device output format"
            )
        )
        try Self.validateFloatPCM(inputFormat, role: "measurement input")
        try Self.validateFloatPCM(calibrationOutputFormat, role: "measurement output")
        try Self.validateSampleRate(inputFormat, expected: sampleRate, role: "measurement input stream")
        try Self.validateSampleRate(calibrationOutputFormat, expected: sampleRate, role: "measurement output stream")

        let calibrationInputChannels = try Self.readChannelCount(
            deviceID: calibrationDeviceID,
            scope: kAudioObjectPropertyScopeInput,
            operation: "read calibration input channel count"
        )
        guard aggregateInputChannelIndex >= 0, aggregateInputChannelIndex < calibrationInputChannels else {
            throw RoomCorrectionCalibrationTransportError.invalidInputChannel(
                index: aggregateInputChannelIndex,
                availableChannels: calibrationInputChannels
            )
        }
        let calibrationOutputChannels = try Self.readChannelCount(
            deviceID: calibrationDeviceID,
            scope: kAudioObjectPropertyScopeOutput,
            operation: "read calibration output channel count"
        )
        guard calibrationOutputChannels >= 2 else {
            throw RoomCorrectionCalibrationTransportError.insufficientOutputChannels(calibrationOutputChannels)
        }

        let sweepFrames = try Self.checkedUInt32(plan.program.sweepSamples.count)
        let leadInFrames = try Self.checkedUInt32(plan.program.leadInFrames)
        let tailFrames = try Self.checkedUInt32(plan.program.tailFrames)
        let settlingFrames = try Self.checkedUInt32(plan.settlingFrames)
        let inputChannel = try Self.checkedUInt32(aggregateInputChannelIndex)

        bridge = plan.program.sweepSamples.withUnsafeBufferPointer { buffer in
            N60RoomMeasurementBridgeCreate(
                buffer.baseAddress!,
                sweepFrames,
                leadInFrames,
                tailFrames,
                settlingFrames,
                inputChannel
            )
        }
        guard let bridge else {
            throw RoomCorrectionCalibrationTransportError.bridgeAllocationFailed
        }

        let clientData = UnsafeMutableRawPointer(bridge)
        try Self.check(
            AudioDeviceCreateIOProcID(
                calibrationDeviceID,
                N60RoomMeasurementIOProc,
                clientData,
                &ioProcID
            ),
            operation: "create room-measurement IOProc"
        )
        guard ioProcID != nil else {
            throw RoomCorrectionCalibrationTransportError.ioProcUnavailable
        }
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

        if inputSampleRateWasChanged, let originalInputSampleRate {
            try? Self.writeNominalSampleRate(
                deviceID: input.deviceID,
                sampleRate: originalInputSampleRate,
                operation: "restore measurement microphone sample rate"
            )
        }
        inputSampleRateWasChanged = false
        originalInputSampleRate = nil

        if let bridge {
            N60RoomMeasurementBridgeDestroy(bridge)
            self.bridge = nil
        }
    }

    private static func validateFloatPCM(
        _ format: AudioStreamFormatDescription,
        role: String
    ) throws {
        guard format.isFloatPCM, format.bitsPerChannel == 32 else {
            throw RoomCorrectionCalibrationTransportError.unsupportedPCMFormat(
                role: role,
                format: format
            )
        }
    }

    private static func validateSampleRate(
        _ format: AudioStreamFormatDescription,
        expected: Double,
        role: String
    ) throws {
        guard format.sampleRate.isFinite, abs(format.sampleRate - expected) < 0.5 else {
            throw RoomCorrectionCalibrationTransportError.sampleRateMismatch(
                role: role,
                expected: expected,
                actual: format.sampleRate
            )
        }
    }

    private static func aggregateDescription(
        output: AudioOutputDevice,
        input: AudioInputDevice
    ) -> [String: Any] {
        let outputEntry: [String: Any] = [
            kAudioSubDeviceUIDKey: output.uid,
            kAudioSubDeviceDriftCompensationKey: false,
        ]
        let inputEntry: [String: Any] = [
            kAudioSubDeviceUIDKey: input.uid,
            kAudioSubDeviceDriftCompensationKey: true,
        ]
        return [
            kAudioAggregateDeviceNameKey: "Notch Sixty Room Measurement",
            kAudioAggregateDeviceUIDKey: "com.dhdook.NotchSixty.room-measurement.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey: [outputEntry, inputEntry],
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceClockDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
        ]
    }

    private static func checkedUInt32(_ value: Int) throws -> UInt32 {
        guard value >= 0, UInt64(value) <= UInt64(UInt32.max) else {
            throw RoomCorrectionCalibrationTransportError.frameCountOverflow
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
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
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
            operation: "read measurement device nominal sample rate"
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

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw RoomCorrectionCalibrationTransportError.operationFailed(
                operation: operation,
                status: status
            )
        }
    }
}
