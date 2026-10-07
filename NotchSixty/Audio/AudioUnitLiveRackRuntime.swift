import AudioToolbox
import AVFAudio
import Darwin
import Foundation

enum AudioUnitLiveRackBuildError: Error, Equatable, LocalizedError {
    case invalidExecutionPlan
    case missingPreparedSlot(Int)
    case preparedStateChanged(Int)
    case componentUnavailable(Int)
    case liveInstantiationFailed(Int, String)
    case liveFormatFailed(Int, String)
    case liveResourceAllocationFailed(Int, String)
    case liveInvalidLatency(Int, seconds: Double)
    case liveInvalidTail(Int, seconds: Double)
    case liveLatencyChanged(Int, expected: Int, actual: Int)
    case liveTailChanged(Int, expected: Int, actual: Int)
    case stageFaultGateAllocationFailed(Int)
    case delayMemoryBudgetExceeded(Int)
    case scratchAllocationFailed
    case faultLatchAllocationFailed

    var errorDescription: String? {
        switch self {
        case .invalidExecutionPlan:
            return "Audio Unit live rack execution plan is invalid."
        case .missingPreparedSlot(let slot):
            return "Audio Unit rack slot \(slot + 1) has no matching offline preparation."
        case .preparedStateChanged(let slot):
            return "Audio Unit rack slot \(slot + 1) changed after offline preparation."
        case .componentUnavailable(let slot):
            return "Audio Unit rack slot \(slot + 1) no longer resolves to an installed component."
        case .liveInstantiationFailed(let slot, let reason):
            return "Audio Unit rack slot \(slot + 1) could not instantiate for live use. \(reason)"
        case .liveFormatFailed(let slot, let reason):
            return "Audio Unit rack slot \(slot + 1) rejected the live format. \(reason)"
        case .liveResourceAllocationFailed(let slot, let reason):
            return "Audio Unit rack slot \(slot + 1) could not allocate live render resources. \(reason)"
        case .liveInvalidLatency(let slot, let seconds):
            return "Audio Unit rack slot \(slot + 1) reported invalid live latency \(seconds) seconds."
        case .liveInvalidTail(let slot, let seconds):
            return "Audio Unit rack slot \(slot + 1) reported invalid live tail \(seconds) seconds."
        case .liveLatencyChanged(let slot, let expected, let actual):
            return "Audio Unit rack slot \(slot + 1) changed latency from \(expected) to \(actual) frames."
        case .liveTailChanged(let slot, let expected, let actual):
            return "Audio Unit rack slot \(slot + 1) changed tail from \(expected) to \(actual) frames."
        case .stageFaultGateAllocationFailed(let slot):
            return "Audio Unit rack slot \(slot + 1) could not allocate a lock-free fail-closed gate."
        case .delayMemoryBudgetExceeded(let bytes):
            return "Audio Unit rack requires \(bytes) bytes of latency compensation, exceeding the live memory budget."
        case .scratchAllocationFailed:
            return "Unable to allocate the fixed Audio Unit rack render scratch."
        case .faultLatchAllocationFailed:
            return "Unable to allocate the lock-free Audio Unit rack fault latch."
        }
    }
}

struct AudioUnitLiveRackFault: Equatable, Sendable {
    let faultCount: UInt64
    let slotIndex: Int
    let component: AudioUnitComponentIdentity?
    let reason: N60AudioUnitLiveRackFaultReason
    let renderStatus: OSStatus
    let detail: String?

    init(
        faultCount: UInt64,
        slotIndex: Int,
        component: AudioUnitComponentIdentity?,
        reason: N60AudioUnitLiveRackFaultReason,
        renderStatus: OSStatus,
        detail: String? = nil
    ) {
        self.faultCount = faultCount
        self.slotIndex = slotIndex
        self.component = component
        self.reason = reason
        self.renderStatus = renderStatus
        self.detail = detail
    }

    var description: String {
        if let detail {
            return detail
        }
        switch reason {
        case N60AudioUnitLiveRackFaultRenderStatus:
            return "Live Audio Unit render failed with OSStatus \(renderStatus)."
        case N60AudioUnitLiveRackFaultNonFiniteOutput:
            return "Live Audio Unit produced a non-finite output sample."
        case N60AudioUnitLiveRackFaultRuntimeInvariant:
            return "Live Audio Unit rack hit an impossible prepared-runtime invariant."
        case N60AudioUnitLiveRackFaultCPUOverrun:
            return "Live Audio Unit exceeded the severe realtime CPU budget repeatedly."
        default:
            return "Live Audio Unit rack reported an unknown runtime fault."
        }
    }
}

enum AudioUnitLiveRackControlPlaneIssue: Equatable, Sendable {
    case invalidLatency(
        slot: Int,
        component: AudioUnitComponentIdentity,
        seconds: Double
    )
    case invalidTail(
        slot: Int,
        component: AudioUnitComponentIdentity,
        seconds: Double
    )
    case latencyChanged(
        slot: Int,
        component: AudioUnitComponentIdentity,
        expected: Int,
        actual: Int
    )
    case tailChanged(
        slot: Int,
        component: AudioUnitComponentIdentity,
        expected: Int,
        actual: Int
    )

    var slotIndex: Int {
        switch self {
        case .invalidLatency(let slot, _, _),
             .invalidTail(let slot, _, _),
             .latencyChanged(let slot, _, _, _),
             .tailChanged(let slot, _, _, _):
            return slot
        }
    }

    var component: AudioUnitComponentIdentity {
        switch self {
        case .invalidLatency(_, let component, _),
             .invalidTail(_, let component, _),
             .latencyChanged(_, let component, _, _),
             .tailChanged(_, let component, _, _):
            return component
        }
    }

    var description: String {
        switch self {
        case .invalidLatency(let slot, _, let seconds):
            return "Live Audio Unit rack slot \(slot + 1) reported invalid latency \(seconds) seconds after activation."
        case .invalidTail(let slot, _, let seconds):
            return "Live Audio Unit rack slot \(slot + 1) reported invalid tail \(seconds) seconds after activation."
        case .latencyChanged(let slot, _, let expected, let actual):
            return "Live Audio Unit rack slot \(slot + 1) changed latency after activation from \(expected) to \(actual) frames."
        case .tailChanged(let slot, _, let expected, let actual):
            return "Live Audio Unit rack slot \(slot + 1) changed tail after activation from \(expected) to \(actual) frames."
        }
    }
}

enum AudioUnitLiveTimingValidator {
    static func frameCount(
        seconds: Double,
        sampleRate: Double,
        maximumSeconds: Double
    ) -> Int? {
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= maximumSeconds,
              sampleRate.isFinite,
              sampleRate > 0 else {
            return nil
        }
        let frames = ceil(seconds * sampleRate)
        guard frames.isFinite,
              frames >= 0,
              frames <= Double(Int.max) else {
            return nil
        }
        return Int(frames)
    }
}

struct AudioUnitLiveRenderWatchdog {
    static let severeOverrunMultiplier = 4.0
    static let minimumBudgetSeconds = 0.010
    static let consecutiveOverrunLimit = 3

    private(set) var consecutiveOverruns = 0

    static func budgetTicks(
        frameCount: Int,
        sampleRate: Double,
        ticksPerSecond: Double
    ) -> UInt64 {
        guard frameCount > 0,
              sampleRate.isFinite,
              sampleRate > 0,
              ticksPerSecond.isFinite,
              ticksPerSecond > 0 else {
            return UInt64.max
        }

        let bufferSeconds = Double(frameCount) / sampleRate
        let budgetSeconds = max(
            minimumBudgetSeconds,
            bufferSeconds * severeOverrunMultiplier
        )
        let ticks = ceil(budgetSeconds * ticksPerSecond)
        guard ticks.isFinite,
              ticks > 0,
              ticks < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(ticks)
    }

    mutating func observe(
        elapsedTicks: UInt64,
        budgetTicks: UInt64
    ) -> Bool {
        if elapsedTicks > budgetTicks {
            consecutiveOverruns = min(
                consecutiveOverruns + 1,
                Self.consecutiveOverrunLimit
            )
        } else {
            consecutiveOverruns = 0
        }
        return consecutiveOverruns >= Self.consecutiveOverrunLimit
    }
}

struct AudioUnitLiveRackBuildSlot {
    let slotIndex: Int
    let slot: AudioUnitRackSlotState
    let execution: AudioUnitRackSlotExecutionPlan
    let descriptor: AudioUnitComponentDescriptor?
    let offlineReport: AudioUnitOfflinePreparationReport?
}

struct AudioUnitLiveRackStageResult {
    let faultReason: N60AudioUnitLiveRackFaultReason
    let renderStatus: OSStatus

    static let success = AudioUnitLiveRackStageResult(
        faultReason: N60AudioUnitLiveRackFaultNone,
        renderStatus: noErr
    )
}

protocol AudioUnitLiveRackStageProcessing: AnyObject {
    var slotIndex: Int { get }
    var component: AudioUnitComponentIdentity? { get }
    var latencyFrames: Int { get }

    func controlPlaneHealthIssue()
        -> AudioUnitLiveRackControlPlaneIssue?

    func process(
        inputInterleaved: UnsafePointer<Float>,
        outputInterleaved: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleTime: Double
    ) -> AudioUnitLiveRackStageResult
}

extension AudioUnitLiveRackStageProcessing {
    func controlPlaneHealthIssue()
        -> AudioUnitLiveRackControlPlaneIssue? {
        nil
    }
}

private final class AudioUnitLiveDelayLine {
    let channelCount: Int
    let latencyFrames: Int
    private let storage: UnsafeMutablePointer<Float>?
    private var writeFrame = 0

    init(channelCount: Int, latencyFrames: Int) {
        self.channelCount = channelCount
        self.latencyFrames = latencyFrames
        if latencyFrames > 0 {
            let samples = latencyFrames * channelCount
            let allocated = UnsafeMutablePointer<Float>.allocate(capacity: samples)
            allocated.initialize(repeating: 0, count: samples)
            storage = allocated
        } else {
            storage = nil
        }
    }

    deinit {
        if let storage {
            storage.deinitialize(count: latencyFrames * channelCount)
            storage.deallocate()
        }
    }

    @inline(__always)
    func process(
        inputInterleaved: UnsafePointer<Float>,
        outputInterleaved: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard let storage, latencyFrames > 0 else {
            memcpy(
                outputInterleaved,
                inputInterleaved,
                frameCount * channelCount * MemoryLayout<Float>.size
            )
            return
        }

        var frame = 0
        while frame < frameCount {
            let ringBase = writeFrame * channelCount
            let inputBase = frame * channelCount
            var channel = 0
            while channel < channelCount {
                let ringIndex = ringBase + channel
                outputInterleaved[inputBase + channel] = storage[ringIndex]
                storage[ringIndex] = inputInterleaved[inputBase + channel]
                channel += 1
            }
            writeFrame += 1
            if writeFrame == latencyFrames {
                writeFrame = 0
            }
            frame += 1
        }
    }
}

final class AudioUnitLiveBypassStage: AudioUnitLiveRackStageProcessing {
    let slotIndex: Int
    let component: AudioUnitComponentIdentity?
    let latencyFrames: Int
    private let delay: AudioUnitLiveDelayLine

    init(
        slotIndex: Int,
        component: AudioUnitComponentIdentity?,
        channelCount: Int,
        latencyFrames: Int
    ) {
        self.slotIndex = slotIndex
        self.component = component
        self.latencyFrames = latencyFrames
        self.delay = AudioUnitLiveDelayLine(
            channelCount: channelCount,
            latencyFrames: latencyFrames
        )
    }

    func process(
        inputInterleaved: UnsafePointer<Float>,
        outputInterleaved: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleTime: Double
    ) -> AudioUnitLiveRackStageResult {
        _ = sampleTime
        guard channelCount == delay.channelCount else {
            memset(
                outputInterleaved,
                0,
                frameCount * max(channelCount, 0) * MemoryLayout<Float>.size
            )
            return AudioUnitLiveRackStageResult(
                faultReason: N60AudioUnitLiveRackFaultRuntimeInvariant,
                renderStatus: kAudio_ParamError
            )
        }
        delay.process(
            inputInterleaved: inputInterleaved,
            outputInterleaved: outputInterleaved,
            frameCount: frameCount
        )
        return .success
    }
}

final class AudioUnitLiveProcessStage: AudioUnitLiveRackStageProcessing {
    let slotIndex: Int
    let component: AudioUnitComponentIdentity?
    let latencyFrames: Int
    let tailFrames: Int

    private let unit: AVAudioUnit
    private let renderBlock: AURenderBlock
    private let outputBuffer: AVAudioPCMBuffer
    private let outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>
    private let channelCount: Int
    private let maximumFramesPerSlice: Int
    private let sampleRate: Double
    private let ticksPerSecond: Double
    private let wetDryMix: Float
    private let delay: AudioUnitLiveDelayLine
    private let dryScratch: UnsafeMutablePointer<Float>
    private let faultGate: OpaquePointer

    private var currentInput: UnsafePointer<Float>?
    private var currentFrameCount = 0
    private var renderWatchdog = AudioUnitLiveRenderWatchdog()

    private lazy var pullInputBlock: AURenderPullInputBlock = {
        [unowned self] _, _, requestedFrameCount, _, inputData in
        guard let source = self.currentInput else {
            return kAudio_ParamError
        }
        let requested = Int(requestedFrameCount)
        guard requested >= 0,
              requested <= self.currentFrameCount else {
            return kAudio_ParamError
        }

        let buffers = UnsafeMutableAudioBufferListPointer(inputData)
        guard buffers.count == self.channelCount else {
            return kAudio_ParamError
        }

        var channel = 0
        while channel < self.channelCount {
            guard let raw = buffers[channel].mData else {
                return kAudio_ParamError
            }
            let destination = raw.assumingMemoryBound(to: Float.self)
            var frame = 0
            while frame < requested {
                destination[frame] =
                    source[frame * self.channelCount + channel]
                frame += 1
            }
            buffers[channel].mDataByteSize = UInt32(
                requested * MemoryLayout<Float>.size
            )
            channel += 1
        }
        return noErr
    }

    private init(
        slotIndex: Int,
        component: AudioUnitComponentIdentity,
        unit: AVAudioUnit,
        renderBlock: @escaping AURenderBlock,
        outputBuffer: AVAudioPCMBuffer,
        channelCount: Int,
        maximumFramesPerSlice: Int,
        sampleRate: Double,
        latencyFrames: Int,
        tailFrames: Int,
        wetDryMix: Float,
        faultGate: OpaquePointer
    ) {
        self.slotIndex = slotIndex
        self.component = component
        self.unit = unit
        self.renderBlock = renderBlock
        self.outputBuffer = outputBuffer
        self.outputChannels = outputBuffer.floatChannelData!
        self.channelCount = channelCount
        self.maximumFramesPerSlice = maximumFramesPerSlice
        self.sampleRate = sampleRate
        self.ticksPerSecond = Self.currentTicksPerSecond()
        self.latencyFrames = latencyFrames
        self.tailFrames = tailFrames
        self.wetDryMix = wetDryMix
        self.faultGate = faultGate
        self.delay = AudioUnitLiveDelayLine(
            channelCount: channelCount,
            latencyFrames: latencyFrames
        )
        let scratchSamples = maximumFramesPerSlice * channelCount
        self.dryScratch = UnsafeMutablePointer<Float>.allocate(
            capacity: scratchSamples
        )
        self.dryScratch.initialize(repeating: 0, count: scratchSamples)

        // Force block creation on the control plane. The first realtime call
        // must never trigger lazy block allocation.
        _ = self.pullInputBlock
    }

    deinit {
        N60AudioUnitStageFaultGateDestroy(faultGate)
        dryScratch.deinitialize(
            count: maximumFramesPerSlice * channelCount
        )
        dryScratch.deallocate()
        unit.withAUAudioUnit { au in
            if au.renderResourcesAllocated {
                au.deallocateRenderResources()
            }
        }
    }

    static func build(
        slotIndex: Int,
        slot: AudioUnitRackSlotState,
        descriptor: AudioUnitComponentDescriptor,
        report: AudioUnitOfflinePreparationReport,
        format: AudioUnitRackProcessingFormat
    ) async throws -> AudioUnitLiveProcessStage {
        guard report.component == descriptor.identity,
              report.format == format,
              report.probe.component == descriptor.identity else {
            throw AudioUnitLiveRackBuildError.missingPreparedSlot(slotIndex)
        }
        guard slot.opaqueFullState == report.capturedFullState else {
            throw AudioUnitLiveRackBuildError.preparedStateChanged(slotIndex)
        }

        let unit: AVAudioUnit
        do {
            unit = try await instantiate(descriptor.identity)
        } catch {
            throw AudioUnitLiveRackBuildError.liveInstantiationFailed(
                slotIndex,
                error.localizedDescription
            )
        }

        let configured: (
            renderBlock: AURenderBlock,
            buffer: AVAudioPCMBuffer,
            latencyFrames: Int,
            tailFrames: Int
        )
        do {
            configured = try unit.withAUAudioUnit { au in
                guard au.inputBusses.count > 0,
                      au.outputBusses.count > 0,
                      let avFormat = AVAudioFormat(
                        standardFormatWithSampleRate: format.sampleRate,
                        channels: AVAudioChannelCount(format.channelCount)
                      ),
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: avFormat,
                        frameCapacity: AVAudioFrameCount(
                            format.maximumFramesPerSlice
                        )
                      ),
                      buffer.floatChannelData != nil else {
                    throw AudioUnitLiveRackBuildError.liveFormatFailed(
                        slotIndex,
                        "Unable to create the exact non-interleaved Float32 live format."
                    )
                }

                do {
                    try au.inputBusses[0].setFormat(avFormat)
                    try au.outputBusses[0].setFormat(avFormat)
                    au.inputBusses[0].isEnabled = true
                    au.maximumFramesToRender = AUAudioFrameCount(
                        format.maximumFramesPerSlice
                    )
                    if let state = slot.opaqueFullState {
                        try restoreState(state, to: au)
                    }
                } catch let error as AudioUnitLiveRackBuildError {
                    throw error
                } catch {
                    throw AudioUnitLiveRackBuildError.liveFormatFailed(
                        slotIndex,
                        error.localizedDescription
                    )
                }

                do {
                    try au.allocateRenderResources()
                } catch {
                    throw AudioUnitLiveRackBuildError
                        .liveResourceAllocationFailed(
                            slotIndex,
                            error.localizedDescription
                        )
                }

                let latencySeconds = au.latency
                guard let latency = AudioUnitLiveTimingValidator.frameCount(
                    seconds: latencySeconds,
                    sampleRate: format.sampleRate,
                    maximumSeconds:
                        AudioUnitProbeResult.maximumLatencySeconds
                ) else {
                    throw AudioUnitLiveRackBuildError.liveInvalidLatency(
                        slotIndex,
                        seconds: latencySeconds
                    )
                }

                let tailSeconds = au.tailTime
                guard let tail = AudioUnitLiveTimingValidator.frameCount(
                    seconds: tailSeconds,
                    sampleRate: format.sampleRate,
                    maximumSeconds:
                        AudioUnitProbeResult.maximumTailSeconds
                ) else {
                    throw AudioUnitLiveRackBuildError.liveInvalidTail(
                        slotIndex,
                        seconds: tailSeconds
                    )
                }
                return (au.renderBlock, buffer, latency, tail)
            }
        } catch {
            unit.withAUAudioUnit { au in
                if au.renderResourcesAllocated {
                    au.deallocateRenderResources()
                }
            }
            throw error
        }

        let expectedLatency = report.probe.latencyFrames
        guard abs(configured.latencyFrames - expectedLatency) <= 1 else {
            unit.withAUAudioUnit { au in
                if au.renderResourcesAllocated {
                    au.deallocateRenderResources()
                }
            }
            throw AudioUnitLiveRackBuildError.liveLatencyChanged(
                slotIndex,
                expected: expectedLatency,
                actual: configured.latencyFrames
            )
        }
        let expectedTail = report.probe.tailFrames
        guard abs(configured.tailFrames - expectedTail) <= 1 else {
            unit.withAUAudioUnit { au in
                if au.renderResourcesAllocated {
                    au.deallocateRenderResources()
                }
            }
            throw AudioUnitLiveRackBuildError.liveTailChanged(
                slotIndex,
                expected: expectedTail,
                actual: configured.tailFrames
            )
        }

        guard let faultGate = N60AudioUnitStageFaultGateCreate() else {
            unit.withAUAudioUnit { au in
                if au.renderResourcesAllocated {
                    au.deallocateRenderResources()
                }
            }
            throw AudioUnitLiveRackBuildError
                .stageFaultGateAllocationFailed(slotIndex)
        }

        return AudioUnitLiveProcessStage(
            slotIndex: slotIndex,
            component: descriptor.identity,
            unit: unit,
            renderBlock: configured.renderBlock,
            outputBuffer: configured.buffer,
            channelCount: format.channelCount,
            maximumFramesPerSlice: format.maximumFramesPerSlice,
            sampleRate: format.sampleRate,
            latencyFrames: expectedLatency,
            tailFrames: expectedTail,
            wetDryMix: Float(slot.wetDryMix),
            faultGate: faultGate
        )
    }

    func controlPlaneHealthIssue()
        -> AudioUnitLiveRackControlPlaneIssue? {
        guard let component else { return nil }

        let issue: AudioUnitLiveRackControlPlaneIssue? =
            unit.withAUAudioUnit { au in
                let latencySeconds = au.latency
                guard let currentLatency =
                    AudioUnitLiveTimingValidator.frameCount(
                        seconds: latencySeconds,
                        sampleRate: sampleRate,
                        maximumSeconds:
                            AudioUnitProbeResult.maximumLatencySeconds
                    ) else {
                    return .invalidLatency(
                        slot: slotIndex,
                        component: component,
                        seconds: latencySeconds
                    )
                }
                if abs(currentLatency - latencyFrames) > 1 {
                    return .latencyChanged(
                        slot: slotIndex,
                        component: component,
                        expected: latencyFrames,
                        actual: currentLatency
                    )
                }

                let tailSeconds = au.tailTime
                guard let currentTail =
                    AudioUnitLiveTimingValidator.frameCount(
                        seconds: tailSeconds,
                        sampleRate: sampleRate,
                        maximumSeconds:
                            AudioUnitProbeResult.maximumTailSeconds
                    ) else {
                    return .invalidTail(
                        slot: slotIndex,
                        component: component,
                        seconds: tailSeconds
                    )
                }
                if abs(currentTail - tailFrames) > 1 {
                    return .tailChanged(
                        slot: slotIndex,
                        component: component,
                        expected: tailFrames,
                        actual: currentTail
                    )
                }
                return nil
            }

        if issue != nil {
            N60AudioUnitStageFaultGateTrip(faultGate)
        }
        return issue
    }

    func process(
        inputInterleaved: UnsafePointer<Float>,
        outputInterleaved: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleTime: Double
    ) -> AudioUnitLiveRackStageResult {
        guard channelCount == self.channelCount,
              frameCount >= 0,
              frameCount <= maximumFramesPerSlice else {
            memset(
                outputInterleaved,
                0,
                max(frameCount, 0) * max(channelCount, 0)
                    * MemoryLayout<Float>.size
            )
            return AudioUnitLiveRackStageResult(
                faultReason: N60AudioUnitLiveRackFaultRuntimeInvariant,
                renderStatus: kAudio_ParamError
            )
        }

        delay.process(
            inputInterleaved: inputInterleaved,
            outputInterleaved: dryScratch,
            frameCount: frameCount
        )

        if N60AudioUnitStageFaultGateIsTripped(faultGate) {
            memcpy(
                outputInterleaved,
                dryScratch,
                frameCount * channelCount * MemoryLayout<Float>.size
            )
            return .success
        }

        currentInput = inputInterleaved
        currentFrameCount = frameCount
        outputBuffer.frameLength = AVAudioFrameCount(frameCount)

        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid

        let renderStart = mach_absolute_time()
        let status = renderBlock(
            &flags,
            &timestamp,
            AVAudioFrameCount(frameCount),
            0,
            outputBuffer.mutableAudioBufferList,
            pullInputBlock
        )
        let renderElapsed = mach_absolute_time() &- renderStart
        currentInput = nil
        currentFrameCount = 0

        if status != noErr {
            N60AudioUnitStageFaultGateTrip(faultGate)
            memcpy(
                outputInterleaved,
                dryScratch,
                frameCount * channelCount * MemoryLayout<Float>.size
            )
            return AudioUnitLiveRackStageResult(
                faultReason: N60AudioUnitLiveRackFaultRenderStatus,
                renderStatus: status
            )
        }

        if frameCount > 0 {
            let budgetTicks = AudioUnitLiveRenderWatchdog.budgetTicks(
                frameCount: frameCount,
                sampleRate: sampleRate,
                ticksPerSecond: ticksPerSecond
            )
            if renderWatchdog.observe(
                elapsedTicks: renderElapsed,
                budgetTicks: budgetTicks
            ) {
                N60AudioUnitStageFaultGateTrip(faultGate)
                memcpy(
                    outputInterleaved,
                    dryScratch,
                    frameCount * channelCount * MemoryLayout<Float>.size
                )
                return AudioUnitLiveRackStageResult(
                    faultReason: N60AudioUnitLiveRackFaultCPUOverrun,
                    renderStatus: noErr
                )
            }
        }

        let wet = wetDryMix
        let dry = 1.0 - wet
        var frame = 0
        while frame < frameCount {
            let base = frame * channelCount
            var channel = 0
            while channel < channelCount {
                let rendered = outputChannels[channel][frame]
                if !rendered.isFinite {
                    N60AudioUnitStageFaultGateTrip(faultGate)
                    memcpy(
                        outputInterleaved,
                        dryScratch,
                        frameCount * channelCount
                            * MemoryLayout<Float>.size
                    )
                    return AudioUnitLiveRackStageResult(
                        faultReason:
                            N60AudioUnitLiveRackFaultNonFiniteOutput,
                        renderStatus: noErr
                    )
                }
                outputInterleaved[base + channel] =
                    rendered * wet + dryScratch[base + channel] * dry
                channel += 1
            }
            frame += 1
        }
        return .success
    }

    private static func currentTicksPerSecond() -> Double {
        var info = mach_timebase_info_data_t()
        let status = mach_timebase_info(&info)
        guard status == KERN_SUCCESS,
              info.numer > 0,
              info.denom > 0 else {
            return 1_000_000_000
        }
        return 1_000_000_000
            * Double(info.denom)
            / Double(info.numer)
    }

    private static func instantiate(
        _ identity: AudioUnitComponentIdentity
    ) async throws -> AVAudioUnit {
        let description = AudioComponentDescription(
            componentType: identity.componentType,
            componentSubType: identity.componentSubType,
            componentManufacturer: identity.componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return try await withCheckedThrowingContinuation {
            continuation in
            AVAudioUnit.instantiate(
                with: description,
                options: []
            ) { unit, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(
                        throwing: AudioUnitOfflinePreparationError
                            .instantiationFailed(
                                "The system returned neither a unit nor an error."
                            )
                    )
                }
            }
        }
    }

    private static func restoreState(
        _ data: Data,
        to au: AUAudioUnit
    ) throws {
        let state = try AudioUnitOpaqueStateCodec.decodeDictionary(data)
        au.fullState = state
        guard au.fullState != nil else {
            throw AudioUnitOfflinePreparationError.stateRestoreFailed
        }
    }
}

final class AudioUnitLiveRackRuntime: @unchecked Sendable {
    static let maximumDelayMemoryBytes = 128 * 1_024 * 1_024

    let format: AudioUnitRackProcessingFormat
    let totalLatencyFrames: Int
    let stages: [any AudioUnitLiveRackStageProcessing]

    private let scratchA: UnsafeMutablePointer<Float>
    private let scratchB: UnsafeMutablePointer<Float>
    private let scratchSampleCount: Int
    private let faultLatch: OpaquePointer
    private let componentsBySlot: [AudioUnitComponentIdentity?]

    private let monitorQueue = DispatchQueue(
        label: "com.dhdook.NotchSixty.audio-unit-live-rack-faults",
        qos: .utility
    )
    private var faultTimer: DispatchSourceTimer?
    private var observedFaultCount: UInt64 = 0
    private var emittedFaultCount: UInt64 = 0
    private var reportedControlPlaneFaultSlots: Set<Int> = []

    init(
        format: AudioUnitRackProcessingFormat,
        totalLatencyFrames: Int,
        stages: [any AudioUnitLiveRackStageProcessing],
        componentsBySlot: [AudioUnitComponentIdentity?]
    ) throws {
        try format.validate()
        self.format = format
        self.totalLatencyFrames = totalLatencyFrames
        self.stages = stages
        self.componentsBySlot = componentsBySlot
        self.scratchSampleCount =
            format.maximumFramesPerSlice * format.channelCount

        let a = UnsafeMutablePointer<Float>.allocate(
            capacity: scratchSampleCount
        )
        let b = UnsafeMutablePointer<Float>.allocate(
            capacity: scratchSampleCount
        )
        a.initialize(repeating: 0, count: scratchSampleCount)
        b.initialize(repeating: 0, count: scratchSampleCount)
        self.scratchA = a
        self.scratchB = b

        guard let latch = N60AudioUnitLiveRackFaultLatchCreate() else {
            a.deinitialize(count: scratchSampleCount)
            b.deinitialize(count: scratchSampleCount)
            a.deallocate()
            b.deallocate()
            throw AudioUnitLiveRackBuildError.faultLatchAllocationFailed
        }
        self.faultLatch = latch
    }

    deinit {
        faultTimer?.cancel()
        faultTimer = nil
        N60AudioUnitLiveRackFaultLatchDestroy(faultLatch)
        scratchA.deinitialize(count: scratchSampleCount)
        scratchB.deinitialize(count: scratchSampleCount)
        scratchA.deallocate()
        scratchB.deallocate()
    }

    static func build(
        format: AudioUnitRackProcessingFormat,
        plan: AudioUnitRackExecutionPlan,
        slots: [AudioUnitLiveRackBuildSlot]
    ) async throws -> AudioUnitLiveRackRuntime? {
        try format.validate()
        guard plan.format == format,
              plan.slots.count == slots.count else {
            throw AudioUnitLiveRackBuildError.invalidExecutionPlan
        }

        let active = slots.filter {
            $0.execution.mode != .empty
        }
        if active.isEmpty {
            return nil
        }

        let delaySamples = active.reduce(0) {
            $0 + max(0, $1.execution.latencyFrames)
                * format.channelCount
        }
        let delayBytes = delaySamples * MemoryLayout<Float>.size
        guard delayBytes <= maximumDelayMemoryBytes else {
            throw AudioUnitLiveRackBuildError
                .delayMemoryBudgetExceeded(delayBytes)
        }

        var stages: [any AudioUnitLiveRackStageProcessing] = []
        stages.reserveCapacity(active.count)
        var componentsBySlot = [AudioUnitComponentIdentity?](
            repeating: nil,
            count: slots.count
        )

        for buildSlot in slots {
            componentsBySlot[buildSlot.slotIndex] =
                buildSlot.slot.component
            switch buildSlot.execution.mode {
            case .empty:
                continue
            case .latencyMatchedBypass:
                stages.append(
                    AudioUnitLiveBypassStage(
                        slotIndex: buildSlot.slotIndex,
                        component: buildSlot.slot.component,
                        channelCount: format.channelCount,
                        latencyFrames:
                            buildSlot.execution.latencyFrames
                    )
                )
            case .process:
                guard let descriptor = buildSlot.descriptor else {
                    throw AudioUnitLiveRackBuildError
                        .componentUnavailable(buildSlot.slotIndex)
                }
                guard let report = buildSlot.offlineReport else {
                    throw AudioUnitLiveRackBuildError
                        .missingPreparedSlot(buildSlot.slotIndex)
                }
                let stage = try await AudioUnitLiveProcessStage.build(
                    slotIndex: buildSlot.slotIndex,
                    slot: buildSlot.slot,
                    descriptor: descriptor,
                    report: report,
                    format: format
                )
                stages.append(stage)
            }
        }

        return try AudioUnitLiveRackRuntime(
            format: format,
            totalLatencyFrames: plan.totalLatencyFrames,
            stages: stages,
            componentsBySlot: componentsBySlot
        )
    }

    var processor: N60AudioUnitLiveRackProcessor {
        var result = N60AudioUnitLiveRackProcessor()
        result.context = Unmanaged.passUnretained(self).toOpaque()
        result.process = N60AudioUnitLiveRackSwiftProcess
        result.channelCount = UInt32(format.channelCount)
        result.maximumFramesPerSlice =
            UInt32(format.maximumFramesPerSlice)
        result.latencyFrames = UInt64(max(totalLatencyFrames, 0))
        return result
    }

    func controlPlaneHealthIssues()
        -> [AudioUnitLiveRackControlPlaneIssue] {
        stages.compactMap { $0.controlPlaneHealthIssue() }
    }

    func startFaultMonitoring(
        includeExistingFaults: Bool = false,
        handler: @escaping @Sendable (AudioUnitLiveRackFault) -> Void
    ) {
        guard faultTimer == nil else { return }
        let snapshot =
            N60AudioUnitLiveRackFaultLatchGetSnapshot(faultLatch)
        observedFaultCount =
            includeExistingFaults ? 0 : snapshot.faultCount
        emittedFaultCount = 0
        reportedControlPlaneFaultSlots.removeAll(keepingCapacity: true)

        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(100),
            repeating: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot =
                N60AudioUnitLiveRackFaultLatchGetSnapshot(
                    self.faultLatch
                )

            if snapshot.faultCount > self.observedFaultCount {
                self.observedFaultCount = snapshot.faultCount
                self.emittedFaultCount = max(
                    self.emittedFaultCount + 1,
                    snapshot.faultCount
                )
                let slotIndex = Int(snapshot.lastSlotIndex)
                let component =
                    self.componentsBySlot.indices.contains(slotIndex)
                    ? self.componentsBySlot[slotIndex]
                    : nil
                handler(AudioUnitLiveRackFault(
                    faultCount: self.emittedFaultCount,
                    slotIndex: slotIndex,
                    component: component,
                    reason: snapshot.lastReason,
                    renderStatus: snapshot.lastRenderStatus
                ))
            }

            for issue in self.controlPlaneHealthIssues() {
                guard !self.reportedControlPlaneFaultSlots.contains(
                    issue.slotIndex
                ) else {
                    continue
                }
                self.reportedControlPlaneFaultSlots.insert(
                    issue.slotIndex
                )
                self.emittedFaultCount += 1
                handler(AudioUnitLiveRackFault(
                    faultCount: self.emittedFaultCount,
                    slotIndex: issue.slotIndex,
                    component: issue.component,
                    reason: N60AudioUnitLiveRackFaultRuntimeInvariant,
                    renderStatus: noErr,
                    detail: issue.description
                ))
            }
        }
        faultTimer = timer
        timer.resume()
    }

    func stopFaultMonitoring() {
        faultTimer?.cancel()
        faultTimer = nil
    }

    @inline(__always)
    func process(
        inputInterleaved: UnsafePointer<Float>,
        outputInterleaved: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleTime: Double
    ) -> Bool {
        guard frameCount >= 0,
              frameCount <= format.maximumFramesPerSlice,
              channelCount == format.channelCount else {
            if frameCount > 0, channelCount > 0 {
                memset(
                    outputInterleaved,
                    0,
                    frameCount * channelCount
                        * MemoryLayout<Float>.size
                )
            }
            N60AudioUnitLiveRackFaultLatchRecord(
                faultLatch,
                UInt32.max,
                N60AudioUnitLiveRackFaultRuntimeInvariant,
                kAudio_ParamError
            )
            return false
        }

        let sampleCount = frameCount * channelCount
        memcpy(
            scratchA,
            inputInterleaved,
            sampleCount * MemoryLayout<Float>.size
        )

        var current: UnsafeMutablePointer<Float> = scratchA
        var next: UnsafeMutablePointer<Float> = scratchB
        for stage in stages {
            let result = stage.process(
                inputInterleaved: UnsafePointer(current),
                outputInterleaved: next,
                frameCount: frameCount,
                channelCount: channelCount,
                sampleTime: sampleTime
            )
            if result.faultReason != N60AudioUnitLiveRackFaultNone {
                N60AudioUnitLiveRackFaultLatchRecord(
                    faultLatch,
                    UInt32(stage.slotIndex),
                    result.faultReason,
                    result.renderStatus
                )
            }
            swap(&current, &next)
        }

        memcpy(
            outputInterleaved,
            current,
            sampleCount * MemoryLayout<Float>.size
        )
        return true
    }
}

@_cdecl("N60AudioUnitLiveRackSwiftProcess")
func N60AudioUnitLiveRackSwiftProcess(
    _ context: UnsafeMutableRawPointer?,
    _ inputInterleaved: UnsafePointer<Float>,
    _ outputInterleaved: UnsafeMutablePointer<Float>,
    _ frameCount: UInt32,
    _ channelCount: UInt32,
    _ sampleTime: Double
) -> Bool {
    guard let context else { return false }
    let runtime = Unmanaged<AudioUnitLiveRackRuntime>
        .fromOpaque(context)
        .takeUnretainedValue()
    return runtime.process(
        inputInterleaved: inputInterleaved,
        outputInterleaved: outputInterleaved,
        frameCount: Int(frameCount),
        channelCount: Int(channelCount),
        sampleTime: sampleTime
    )
}
