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
    case liveLatencyChanged(Int, expected: Int, actual: Int)
    case liveTailChanged(Int, expected: Int, actual: Int)
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
        case .liveLatencyChanged(let slot, let expected, let actual):
            return "Audio Unit rack slot \(slot + 1) changed latency from \(expected) to \(actual) frames."
        case .liveTailChanged(let slot, let expected, let actual):
            return "Audio Unit rack slot \(slot + 1) changed tail from \(expected) to \(actual) frames."
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

    var description: String {
        switch reason {
        case N60AudioUnitLiveRackFaultRenderStatus:
            return "Live Audio Unit render failed with OSStatus \(renderStatus)."
        case N60AudioUnitLiveRackFaultNonFiniteOutput:
            return "Live Audio Unit produced a non-finite output sample."
        case N60AudioUnitLiveRackFaultRuntimeInvariant:
            return "Live Audio Unit rack hit an impossible prepared-runtime invariant."
        default:
            return "Live Audio Unit rack reported an unknown runtime fault."
        }
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

    func process(
        inputInterleaved: UnsafePointer<Float>,
        outputInterleaved: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleTime: Double
    ) -> AudioUnitLiveRackStageResult
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

    private let unit: AVAudioUnit
    private let renderBlock: AURenderBlock
    private let outputBuffer: AVAudioPCMBuffer
    private let outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>
    private let channelCount: Int
    private let maximumFramesPerSlice: Int
    private let wetDryMix: Float
    private let delay: AudioUnitLiveDelayLine
    private let dryScratch: UnsafeMutablePointer<Float>

    private var currentInput: UnsafePointer<Float>?
    private var currentFrameCount = 0
    private var faulted = false

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
        latencyFrames: Int,
        wetDryMix: Float
    ) {
        self.slotIndex = slotIndex
        self.component = component
        self.unit = unit
        self.renderBlock = renderBlock
        self.outputBuffer = outputBuffer
        self.outputChannels = outputBuffer.floatChannelData!
        self.channelCount = channelCount
        self.maximumFramesPerSlice = maximumFramesPerSlice
        self.latencyFrames = latencyFrames
        self.wetDryMix = wetDryMix
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

                let latency = Int(
                    ceil(max(0, au.latency) * format.sampleRate)
                )
                let tail = Int(
                    ceil(max(0, au.tailTime) * format.sampleRate)
                )
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

        return AudioUnitLiveProcessStage(
            slotIndex: slotIndex,
            component: descriptor.identity,
            unit: unit,
            renderBlock: configured.renderBlock,
            outputBuffer: configured.buffer,
            channelCount: format.channelCount,
            maximumFramesPerSlice: format.maximumFramesPerSlice,
            latencyFrames: expectedLatency,
            wetDryMix: Float(slot.wetDryMix)
        )
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

        if faulted {
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

        let status = renderBlock(
            &flags,
            &timestamp,
            AVAudioFrameCount(frameCount),
            0,
            outputBuffer.mutableAudioBufferList,
            pullInputBlock
        )
        currentInput = nil
        currentFrameCount = 0

        if status != noErr {
            faulted = true
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

        let wet = wetDryMix
        let dry = 1.0 - wet
        var frame = 0
        while frame < frameCount {
            let base = frame * channelCount
            var channel = 0
            while channel < channelCount {
                let rendered = outputChannels[channel][frame]
                if !rendered.isFinite {
                    faulted = true
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
        guard data.count <= AudioUnitRackSlotState.maximumOpaqueStateBytes else {
            throw AudioUnitOfflinePreparationError.stateTooLarge(data.count)
        }
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let state = object as? [String: Any] else {
            throw AudioUnitOfflinePreparationError.stateDecodeFailed
        }
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
    private let faultLatch: UnsafeMutablePointer<N60AudioUnitLiveRackFaultLatch>
    private let componentsBySlot: [AudioUnitComponentIdentity?]

    private let monitorQueue = DispatchQueue(
        label: "com.dhdook.NotchSixty.audio-unit-live-rack-faults",
        qos: .utility
    )
    private var faultTimer: DispatchSourceTimer?
    private var observedFaultCount: UInt64 = 0

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

    func startFaultMonitoring(
        handler: @escaping @Sendable (AudioUnitLiveRackFault) -> Void
    ) {
        guard faultTimer == nil else { return }
        observedFaultCount =
            N60AudioUnitLiveRackFaultLatchGetSnapshot(faultLatch)
                .faultCount
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
            guard snapshot.faultCount > self.observedFaultCount else {
                return
            }
            self.observedFaultCount = snapshot.faultCount
            let slotIndex = Int(snapshot.lastSlotIndex)
            let component =
                self.componentsBySlot.indices.contains(slotIndex)
                ? self.componentsBySlot[slotIndex]
                : nil
            handler(AudioUnitLiveRackFault(
                faultCount: snapshot.faultCount,
                slotIndex: slotIndex,
                component: component,
                reason: snapshot.lastReason,
                renderStatus: snapshot.lastRenderStatus
            ))
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
