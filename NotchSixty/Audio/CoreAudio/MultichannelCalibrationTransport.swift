import CoreAudio
import Foundation

struct MultichannelCalibrationCapture: Equatable, Sendable {
    var samples: [Float]
    /// Optional simultaneous second input captured on the exact same IOProc
    /// timeline. PR106 uses this for an electrical/shared-time reference.
    var referenceSamples: [Float]? = nil
    /// E11 S9b: captures of every seat after the first (`additionalSeats` order), same length and
    /// timeline as `samples`. Empty for the ordinary one-microphone pass.
    var seatSamples: [[Float]] = []
}

/// E11 S9b: one more microphone channel captured in the same pass.
struct MultichannelSeatInput: Equatable, Sendable {
    var device: AudioInputDevice
    var channelIndex: Int
}

/// E11 S9b: second output program (the acoustic timing chirp) played on its own output channel.
struct MultichannelReferenceProgram: Equatable, Sendable {
    var samples: [Float]
    var startFrame: Int
    var outputChannelIndex: UInt32
}
enum MultichannelCalibrationTransportError: Error, Equatable, LocalizedError {
    case outputDeviceUnavailable(String)
    case invalidInputChannel(index: Int, availableChannels: Int)
    case outputChannelUnavailable(index: UInt32, availableChannels: Int)
    case sampleRateMismatch(role: String, expected: Double, actual: Double)
    case unsupportedPCMFormat(role: String, format: AudioStreamFormatDescription)
    case frameCountOverflow
    case invalidOutputProgram
    case invalidSeatPlan
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
        case .invalidOutputProgram:
            return "The targeted measurement output program is empty, non-finite, or otherwise invalid."
        case .invalidSeatPlan:
            return "The seat list repeats a microphone channel or exceeds 16 seats."
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
    let referenceInputChannelIndex: Int?
    let program: RoomCorrectionSweepProgram
    let physicalOutputChannelIndex: UInt32
    /// E11 S9b: seats after the first; empty for the ordinary one-microphone pass.
    let additionalSeats: [MultichannelSeatInput]
    let referenceProgram: MultichannelReferenceProgram?
    /// E11 S9b: true when every seat is a channel of one device (one clock).
    var isSharedClock: Bool {
        additionalSeats.allSatisfy { $0.device.deviceID == input.deviceID }
    }
    /// Optional control-plane pre-rendered output. Ordinary calibration uses
    /// program.sweepSamples unchanged; protected-driver Lab acquisition may
    /// supply a longer crossover/limiter-rendered waveform while analysis
    /// still deconvolves against the original upstream sweep.
    private let outputSweepSamples: [Float]
    private let orderedOutputs: [AudioOutputDevice]
    private var bridge: UnsafeMutablePointer<N60TargetedRoomMeasurementBridge>?
    /// E24 S1: when set, the transport runs the Level step's generator-only render path (`N60LevelSessionIOProc`)
    /// on the same aggregate instead of the sweep bridge. The caller owns the context and outlives the transport.
    private let levelContext: OpaquePointer?
    private let levelOutputChannels: [UInt32]
    var isLevelSession: Bool { levelContext != nil }
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
        referenceInputChannelIndex: Int? = nil,
        program: RoomCorrectionSweepProgram,
        physicalOutputChannelIndex: UInt32,
        outputSweepSamples: [Float]? = nil,
        additionalSeats: [MultichannelSeatInput] = [],
        referenceProgram: MultichannelReferenceProgram? = nil,
        levelContext: OpaquePointer? = nil,
        levelOutputChannels: [UInt32] = []
    ) throws {
        self.levelContext = levelContext
        self.levelOutputChannels = levelOutputChannels
        var seen: Set<String> = ["\(input.deviceID):\(inputChannelIndex)"]
        for seat in additionalSeats {
            guard seen.insert("\(seat.device.deviceID):\(seat.channelIndex)").inserted else {
                throw MultichannelCalibrationTransportError.invalidSeatPlan
            }
        }
        guard additionalSeats.count <= 15 else {
            throw MultichannelCalibrationTransportError.invalidSeatPlan
        }
        self.additionalSeats = additionalSeats
        self.referenceProgram = referenceProgram
        self.routePlan = routePlan
        self.input = input
        self.selectedInputChannelIndex = inputChannelIndex
        self.referenceInputChannelIndex = referenceInputChannelIndex
        self.program = program
        self.physicalOutputChannelIndex = physicalOutputChannelIndex
        self.outputSweepSamples = outputSweepSamples ?? program.sweepSamples
        guard !self.outputSweepSamples.isEmpty,
              self.outputSweepSamples.allSatisfy(\.isFinite) else {
            throw MultichannelCalibrationTransportError.invalidOutputProgram
        }

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
        guard let ioProcID, bridge != nil || levelContext != nil else {
            throw MultichannelCalibrationTransportError.ioProcUnavailable
        }
        if let bridge { N60TargetedRoomMeasurementBridgeReset(bridge) }
        try Self.check(
            AudioDeviceStart(calibrationDeviceID, ioProcID),
            operation: "start targeted multichannel measurement IOProc"
        )
        isStarted = true
    }

    func stop() {
        guard isStarted, let ioProcID else { return }
        let status = AudioDeviceStop(calibrationDeviceID, ioProcID)
        if status == noErr { isStarted = false } else { stopFailed = true; isStarted = false }
    }

    /// True when Core Audio did not confirm the IOProc stopped; the level session then leaks its context rather
    /// than free memory a running callback may still read.
    private(set) var stopFailed = false
    var didStopCleanly: Bool { !stopFailed }

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

        let frameCount = Int(snapshot.totalFrameCount)
        guard frameCount > 0 else {
            close()
            throw MultichannelCalibrationTransportError.incompleteCapture
        }
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
        var referenceSamples: [Float]?
        if referenceInputChannelIndex != nil {
            var reference = [Float](repeating: 0, count: frameCount)
            let referenceCopied =
                reference.withUnsafeMutableBufferPointer { buffer in
                    N60TargetedRoomMeasurementBridgeCopyReferenceCapture(
                        bridge,
                        buffer.baseAddress!,
                        UInt32(buffer.count)
                    )
                }
            guard referenceCopied == UInt32(frameCount) else {
                close()
                throw MultichannelCalibrationTransportError.incompleteCapture
            }
            referenceSamples = reference
        }
        var seatSamples: [[Float]] = []
        for index in 0..<additionalSeats.count {
            var seat = [Float](repeating: 0, count: frameCount)
            let seatCopied = seat.withUnsafeMutableBufferPointer { buffer in
                N60TargetedRoomMeasurementBridgeCopyExtraCapture(
                    bridge,
                    UInt32(index),
                    buffer.baseAddress!,
                    UInt32(buffer.count)
                )
            }
            guard seatCopied == UInt32(frameCount) else {
                close()
                throw MultichannelCalibrationTransportError.incompleteCapture
            }
            seatSamples.append(seat)
        }
        close()
        return MultichannelCalibrationCapture(
            samples: samples,
            referenceSamples: referenceSamples,
            seatSamples: seatSamples
        )
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
        let physicalInputChannelCount = try Self.readChannelCount(
            deviceID: input.deviceID,
            scope: kAudioObjectPropertyScopeInput,
            operation: "read physical measurement microphone channel count"
        )
        guard selectedInputChannelIndex >= 0,
              selectedInputChannelIndex < physicalInputChannelCount else {
            throw MultichannelCalibrationTransportError.invalidInputChannel(
                index: selectedInputChannelIndex,
                availableChannels: physicalInputChannelCount
            )
        }
        if let referenceInputChannelIndex {
            guard referenceInputChannelIndex >= 0,
                  referenceInputChannelIndex < physicalInputChannelCount,
                  referenceInputChannelIndex != selectedInputChannelIndex else {
                throw MultichannelCalibrationTransportError.invalidInputChannel(
                    index: referenceInputChannelIndex,
                    availableChannels: physicalInputChannelCount
                )
            }
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

        var movedDevices: Set<AudioDeviceID> = [input.deviceID]
        for seat in additionalSeats where movedDevices.insert(seat.device.deviceID).inserted {
            let channels = try Self.readChannelCount(
                deviceID: seat.device.deviceID,
                scope: kAudioObjectPropertyScopeInput,
                operation: "read seat microphone channel count"
            )
            guard seat.channelIndex >= 0, seat.channelIndex < channels else {
                throw MultichannelCalibrationTransportError.invalidInputChannel(
                    index: seat.channelIndex,
                    availableChannels: channels
                )
            }
            if !orderedOutputs.contains(where: { $0.deviceID == seat.device.deviceID }) {
                try ensureSampleRate(seat.device.deviceID, expected: sampleRate, role: "seat microphone \(seat.device.name)")
            }
        }
        for seat in additionalSeats where seat.device.deviceID == input.deviceID {
            guard seat.channelIndex >= 0, seat.channelIndex < physicalInputChannelCount else {
                throw MultichannelCalibrationTransportError.invalidInputChannel(
                    index: seat.channelIndex,
                    availableChannels: physicalInputChannelCount
                )
            }
        }
        let useDirectDevice = orderedOutputs.count == 1
            && input.deviceID == orderedOutputs[0].deviceID
            && additionalSeats.allSatisfy { $0.device.deviceID == input.deviceID }
        let aggregateInputChannel: Int
        let aggregateReferenceInputChannel: Int?
        var aggregateSeatChannels: [Int] = additionalSeats.map(\.channelIndex)
        if useDirectDevice {
            calibrationDeviceID = orderedOutputs[0].deviceID
            aggregateInputChannel = selectedInputChannelIndex
            aggregateReferenceInputChannel = referenceInputChannelIndex
        } else {
            let aggregate = try makePrivateAggregate(
                referenceOutput: referenceOutput,
                sampleRate: sampleRate
            )
            aggregateDeviceID = aggregate.deviceID
            calibrationDeviceID = aggregate.deviceID
            aggregateInputChannel = aggregate.inputChannelIndex
            aggregateReferenceInputChannel = aggregate.referenceInputChannelIndex
            aggregateSeatChannels = aggregate.seatChannelIndices
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
        if let aggregateReferenceInputChannel {
            guard aggregateReferenceInputChannel >= 0,
                  aggregateReferenceInputChannel < inputChannelCount,
                  aggregateReferenceInputChannel != aggregateInputChannel else {
                throw MultichannelCalibrationTransportError.invalidInputChannel(
                    index: aggregateReferenceInputChannel,
                    availableChannels: inputChannelCount
                )
            }
        }
        for channel in aggregateSeatChannels {
            guard channel >= 0, channel < inputChannelCount else {
                throw MultichannelCalibrationTransportError.invalidInputChannel(
                    index: channel,
                    availableChannels: inputChannelCount
                )
            }
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

        for channel in levelOutputChannels where channel >= UInt32(outputChannelCount) {
            throw MultichannelCalibrationTransportError.outputChannelUnavailable(
                index: channel,
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

        if let levelContext {
            N60LevelSessionContextSetInputChannel(levelContext, try Self.checkedUInt32(aggregateInputChannel))
            try Self.check(
                AudioDeviceCreateIOProcID(
                    calibrationDeviceID,
                    N60LevelSessionIOProc,
                    UnsafeMutableRawPointer(levelContext),
                    &ioProcID
                ),
                operation: "create level-session IOProc"
            )
            guard ioProcID != nil else {
                throw MultichannelCalibrationTransportError.ioProcUnavailable
            }
            return
        }
        let sweepFrames = try Self.checkedUInt32(outputSweepSamples.count)
        let leadInFrames = try Self.checkedUInt32(program.leadInFrames)
        let tailFrames = try Self.checkedUInt32(program.tailFrames)
        let inputChannel = try Self.checkedUInt32(aggregateInputChannel)
        // The K-seat bridge has no shared-time reference input; refuse rather than drop it silently.
        guard additionalSeats.isEmpty || aggregateReferenceInputChannel == nil else {
            throw MultichannelCalibrationTransportError.invalidSeatPlan
        }
        var seatChannels: [UInt32] = [inputChannel]
        for channel in aggregateSeatChannels {
            seatChannels.append(try Self.checkedUInt32(channel))
        }
        bridge = outputSweepSamples.withUnsafeBufferPointer { buffer in
            if seatChannels.count > 1 {
                return seatChannels.withUnsafeBufferPointer { channels in
                    N60TargetedRoomMeasurementBridgeCreateMultiInput(
                        buffer.baseAddress!,
                        sweepFrames,
                        leadInFrames,
                        tailFrames,
                        channels.baseAddress!,
                        UInt32(channels.count),
                        physicalOutputChannelIndex
                    )
                }
            }
            if let aggregateReferenceInputChannel,
               let referenceChannel = try? Self.checkedUInt32(
                   aggregateReferenceInputChannel
               ) {
                return N60TargetedRoomMeasurementBridgeCreateDualInput(
                    buffer.baseAddress!,
                    sweepFrames,
                    leadInFrames,
                    tailFrames,
                    inputChannel,
                    referenceChannel,
                    physicalOutputChannelIndex
                )
            }
            return N60TargetedRoomMeasurementBridgeCreate(
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
        if let referenceProgram {
            let attached = referenceProgram.samples.withUnsafeBufferPointer { buffer -> Bool in
                guard let base = buffer.baseAddress,
                      let start = try? Self.checkedUInt32(referenceProgram.startFrame),
                      let count = try? Self.checkedUInt32(buffer.count),
                      referenceProgram.samples.allSatisfy(\.isFinite) else { return false }
                return N60TargetedRoomMeasurementBridgeAttachReferenceProgram(
                    bridge, base, count, start, referenceProgram.outputChannelIndex)
            }
            guard attached,
                  referenceProgram.outputChannelIndex < UInt32(outputChannelCount) else {
                throw MultichannelCalibrationTransportError.invalidOutputProgram
            }
        }
        let expectedCaptureFrames = program.leadInFrames
            + outputSweepSamples.count
            + program.tailFrames
        guard expectedCaptureFrames > 0,
              expectedCaptureFrames <= Int(UInt32.max),
              N60TargetedRoomMeasurementBridgeGetSnapshot(bridge).totalFrameCount
                == UInt32(expectedCaptureFrames) else {
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
    ) throws -> (
        deviceID: AudioDeviceID,
        inputChannelIndex: Int,
        referenceInputChannelIndex: Int?,
        seatChannelIndices: [Int]
    ) {
        var subdevices: [[String: Any]] = []
        var aggregateInputOffset = 0
        var resolvedInputChannel: Int?
        var resolvedReferenceInputChannel: Int?

        var deviceOffsets: [AudioDeviceID: Int] = [:]
        for output in orderedOutputs {
            deviceOffsets[output.deviceID] = aggregateInputOffset
            if output.deviceID == input.deviceID {
                resolvedInputChannel =
                    aggregateInputOffset + selectedInputChannelIndex
                if let referenceInputChannelIndex {
                    resolvedReferenceInputChannel =
                        aggregateInputOffset + referenceInputChannelIndex
                }
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
            deviceOffsets[input.deviceID] = aggregateInputOffset
            resolvedInputChannel =
                aggregateInputOffset + selectedInputChannelIndex
            if let referenceInputChannelIndex {
                resolvedReferenceInputChannel =
                    aggregateInputOffset + referenceInputChannelIndex
            }
            subdevices.append([
                kAudioSubDeviceUIDKey: input.uid,
                kAudioSubDeviceDriftCompensationKey: true,
            ])
            aggregateInputOffset += (try Self.readChannelCount(
                deviceID: input.deviceID,
                scope: kAudioObjectPropertyScopeInput,
                operation: "read measurement microphone input channel count"
            ))
        }
        // E11 S9b: every further seat device joins the private aggregate once, drift compensated.
        for seat in additionalSeats where deviceOffsets[seat.device.deviceID] == nil {
            deviceOffsets[seat.device.deviceID] = aggregateInputOffset
            subdevices.append([
                kAudioSubDeviceUIDKey: seat.device.uid,
                kAudioSubDeviceDriftCompensationKey: true,
            ])
            aggregateInputOffset += (try Self.readChannelCount(
                deviceID: seat.device.deviceID,
                scope: kAudioObjectPropertyScopeInput,
                operation: "read seat microphone input channel count"
            ))
        }
        let resolvedSeatChannels = additionalSeats.map {
            (deviceOffsets[$0.device.deviceID] ?? 0) + $0.channelIndex
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
        return (
            deviceID,
            resolvedInputChannel,
            resolvedReferenceInputChannel,
            resolvedSeatChannels
        )
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
