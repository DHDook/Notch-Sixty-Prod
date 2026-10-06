import AudioToolbox
import AVFAudio
import Foundation

struct AudioUnitOfflineRenderMetrics: Codable, Equatable, Sendable {
    let renderedFrames: Int
    let renderPassCount: Int
    let channelCount: Int
    let maximumAbsoluteSample: Double
    let rmsByChannel: [Double]
    let allSamplesFinite: Bool
}

struct AudioUnitOfflinePreparationReport: Codable, Equatable, Sendable {
    let component: AudioUnitComponentIdentity
    let format: AudioUnitRackProcessingFormat
    let probe: AudioUnitProbeResult
    let capturedFullState: Data?
    let stateRestored: Bool
    let stateRecaptured: Bool
    let initialRender: AudioUnitOfflineRenderMetrics
    let postResetRender: AudioUnitOfflineRenderMetrics
    let latencyStableAcrossReset: Bool
    let tailStableAcrossReset: Bool
    let renderResourcesReleased: Bool

    func validate() throws {
        try probe.validate(for: format)
        guard probe.component == component else {
            throw AudioUnitOfflinePreparationError.componentIdentityMismatch
        }
        guard initialRender.channelCount == format.channelCount,
              postResetRender.channelCount == format.channelCount,
              initialRender.renderedFrames > 0,
              postResetRender.renderedFrames > 0,
              initialRender.allSamplesFinite,
              postResetRender.allSamplesFinite else {
            throw AudioUnitOfflinePreparationError.invalidOfflineRender
        }
        guard latencyStableAcrossReset else {
            throw AudioUnitOfflinePreparationError.latencyChangedAcrossReset
        }
        guard tailStableAcrossReset else {
            throw AudioUnitOfflinePreparationError.tailChangedAcrossReset
        }
        guard renderResourcesReleased else {
            throw AudioUnitOfflinePreparationError.renderResourcesNotReleased
        }
        if let capturedFullState,
           capturedFullState.count
            > AudioUnitRackSlotState.maximumOpaqueStateBytes {
            throw AudioUnitOfflinePreparationError.stateTooLarge(
                capturedFullState.count
            )
        }
    }
}

protocol AudioUnitOfflinePreparing {
    func prepare(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        restoringState: Data?
    ) async throws -> AudioUnitOfflinePreparationReport
}

enum AudioUnitOfflinePreparationError: Error, Equatable, LocalizedError {
    case incompatibleComponent(String)
    case instantiationFailed(String)
    case componentIdentityMismatch
    case missingInputBus
    case missingOutputBus
    case formatConfigurationFailed(String)
    case stateDecodeFailed
    case stateRestoreFailed
    case stateCaptureFailed
    case stateTooLarge(Int)
    case renderResourceAllocationFailed(String)
    case renderBlockUnavailable
    case renderFailed(OSStatus)
    case invalidOfflineRender
    case nonFiniteOutput
    case latencyChangedAcrossReset
    case tailChangedAcrossReset
    case renderResourcesNotReleased

    var errorDescription: String? {
        switch self {
        case .incompatibleComponent(let reason):
            return "Audio Unit is incompatible with the requested offline format. \(reason)"
        case .instantiationFailed(let reason):
            return "Audio Unit instantiation failed. \(reason)"
        case .componentIdentityMismatch:
            return "Instantiated Audio Unit identity does not match the requested component."
        case .missingInputBus:
            return "Audio Unit has no input bus for effect processing."
        case .missingOutputBus:
            return "Audio Unit has no output bus for effect processing."
        case .formatConfigurationFailed(let reason):
            return "Audio Unit format configuration failed. \(reason)"
        case .stateDecodeFailed:
            return "Saved Audio Unit state is not a valid property-list dictionary."
        case .stateRestoreFailed:
            return "Audio Unit state could not be restored safely."
        case .stateCaptureFailed:
            return "Audio Unit full state could not be serialized safely."
        case .stateTooLarge(let bytes):
            return "Audio Unit captured state is too large (\(bytes) bytes)."
        case .renderResourceAllocationFailed(let reason):
            return "Audio Unit render-resource allocation failed. \(reason)"
        case .renderBlockUnavailable:
            return "Audio Unit did not expose a usable internal render block."
        case .renderFailed(let status):
            return "Audio Unit offline render failed with OSStatus \(status)."
        case .invalidOfflineRender:
            return "Audio Unit offline render did not satisfy the prepared format contract."
        case .nonFiniteOutput:
            return "Audio Unit offline render produced a non-finite sample."
        case .latencyChangedAcrossReset:
            return "Audio Unit latency changed after reset during offline validation."
        case .tailChangedAcrossReset:
            return "Audio Unit tail time changed after reset during offline validation."
        case .renderResourcesNotReleased:
            return "Audio Unit render resources remained allocated after offline validation."
        }
    }
}

/// Real macOS Audio Unit preparation backend.
///
/// Every operation here belongs to the control plane. The instantiated unit is
/// fully torn down before this function returns. No AVAudioUnit or AUAudioUnit
/// object escapes into the production realtime graph in PR80.
struct SystemAudioUnitOfflinePreparationBackend: AudioUnitOfflinePreparing {
    var renderPassCount = 4

    func prepare(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        restoringState: Data?
    ) async throws -> AudioUnitOfflinePreparationReport {
        try format.validate()

        let compatibility = component.compatibility(for: format)
        guard compatibility.compatible else {
            throw AudioUnitOfflinePreparationError.incompatibleComponent(
                compatibility.reasons.joined(separator: " ")
            )
        }

        let unit = try await instantiate(component.identity)
        return try unit.withAUAudioUnit { au in

        guard Self.identity(of: unit.audioComponentDescription)
                == component.identity else {
            throw AudioUnitOfflinePreparationError.componentIdentityMismatch
        }
        guard au.inputBusses.count > 0 else {
            throw AudioUnitOfflinePreparationError.missingInputBus
        }
        guard au.outputBusses.count > 0 else {
            throw AudioUnitOfflinePreparationError.missingOutputBus
        }
        guard let avFormat = AVAudioFormat(
            standardFormatWithSampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount)
        ) else {
            throw AudioUnitOfflinePreparationError.formatConfigurationFailed(
                "AVAudioFormat creation failed."
            )
        }

        do {
            try au.inputBusses[0].setFormat(avFormat)
            try au.outputBusses[0].setFormat(avFormat)

            // AUv3 hosts must explicitly connect/enable effect inputs before
            // asking the unit to render. This bridges to the AUv2 connection /
            // render-callback properties and prevents kAudioUnitErr_NoConnection.
            au.inputBusses[0].isEnabled = true

            au.maximumFramesToRender = AUAudioFrameCount(
                format.maximumFramesPerSlice
            )
        } catch {
            throw AudioUnitOfflinePreparationError.formatConfigurationFailed(
                error.localizedDescription
            )
        }

        var restored = false
        if let restoringState {
            try Self.restoreState(restoringState, to: au)
            restored = true
        }

        do {
            try au.allocateRenderResources()
        } catch {
            throw AudioUnitOfflinePreparationError.renderResourceAllocationFailed(
                error.localizedDescription
            )
        }

        var resourcesReleased = false
        defer {
            if au.renderResourcesAllocated {
                au.deallocateRenderResources()
            }
            resourcesReleased = !au.renderResourcesAllocated
        }

        let latencyAfterAllocation = au.latency
        let tailAfterAllocation = au.tailTime

        let initial = try Self.renderDeterministically(
            au: au,
            format: avFormat,
            maximumFrames: format.maximumFramesPerSlice,
            passCount: max(1, renderPassCount)
        )

        let captured = try Self.captureState(from: au)
        if let captured,
           captured.count > AudioUnitRackSlotState.maximumOpaqueStateBytes {
            throw AudioUnitOfflinePreparationError.stateTooLarge(captured.count)
        }

        au.reset()

        let latencyAfterReset = au.latency
        let tailAfterReset = au.tailTime

        let afterReset = try Self.renderDeterministically(
            au: au,
            format: avFormat,
            maximumFrames: format.maximumFramesPerSlice,
            passCount: 2
        )

        guard initial.allSamplesFinite,
              afterReset.allSamplesFinite else {
            throw AudioUnitOfflinePreparationError.nonFiniteOutput
        }

        let probe = AudioUnitProbeResult(
            component: component.identity,
            sampleRate: format.sampleRate,
            inputChannelCount: Int(au.inputBusses[0].format.channelCount),
            outputChannelCount: Int(au.outputBusses[0].format.channelCount),
            maximumFramesToRender: Int(au.maximumFramesToRender),
            latencySeconds: latencyAfterAllocation,
            tailTimeSeconds: tailAfterAllocation,
            supportsFullState: captured != nil,
            supportsHostBypass: true
        )
        try probe.validate(for: format)

        let latencyStable =
            Self.nearlyEqual(latencyAfterAllocation, latencyAfterReset)
        let tailStable =
            Self.nearlyEqual(tailAfterAllocation, tailAfterReset)

        if au.renderResourcesAllocated {
            au.deallocateRenderResources()
        }
        resourcesReleased = !au.renderResourcesAllocated

        let report = AudioUnitOfflinePreparationReport(
            component: component.identity,
            format: format,
            probe: probe,
            capturedFullState: captured,
            stateRestored: restored,
            stateRecaptured: captured != nil,
            initialRender: initial,
            postResetRender: afterReset,
            latencyStableAcrossReset: latencyStable,
            tailStableAcrossReset: tailStable,
            renderResourcesReleased: resourcesReleased
        )
        try report.validate()
        return report
        }
    }

    private func instantiate(
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
                    continuation.resume(
                        throwing: AudioUnitOfflinePreparationError
                            .instantiationFailed(error.localizedDescription)
                    )
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

    private static func identity(
        of description: AudioComponentDescription
    ) -> AudioUnitComponentIdentity {
        AudioUnitComponentIdentity(
            componentType: description.componentType,
            componentSubType: description.componentSubType,
            componentManufacturer: description.componentManufacturer
        )
    }

    private static func restoreState(
        _ data: Data,
        to au: AUAudioUnit
    ) throws {
        guard data.count <= AudioUnitRackSlotState.maximumOpaqueStateBytes else {
            throw AudioUnitOfflinePreparationError.stateTooLarge(data.count)
        }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        } catch {
            throw AudioUnitOfflinePreparationError.stateDecodeFailed
        }
        guard let state = object as? [String: Any] else {
            throw AudioUnitOfflinePreparationError.stateDecodeFailed
        }
        au.fullState = state
        guard au.fullState != nil else {
            throw AudioUnitOfflinePreparationError.stateRestoreFailed
        }
    }

    private static func captureState(
        from au: AUAudioUnit
    ) throws -> Data? {
        guard let state = au.fullState else { return nil }
        guard PropertyListSerialization.propertyList(
            state,
            isValidFor: .binary
        ) else {
            throw AudioUnitOfflinePreparationError.stateCaptureFailed
        }
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: state,
                format: .binary,
                options: 0
            )
        } catch {
            throw AudioUnitOfflinePreparationError.stateCaptureFailed
        }
    }

    private static func renderDeterministically(
        au: AUAudioUnit,
        format: AVAudioFormat,
        maximumFrames: Int,
        passCount: Int
    ) throws -> AudioUnitOfflineRenderMetrics {
        let frameCount = min(maximumFrames, 512)
        guard frameCount > 0,
              let output = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            throw AudioUnitOfflinePreparationError.invalidOfflineRender
        }

        let channelCount = Int(format.channelCount)
        var sumSquares = [Double](repeating: 0, count: channelCount)
        var maximumAbsolute = 0.0
        var allFinite = true
        var renderedFrames = 0

        let renderBlock = au.renderBlock

        for pass in 0..<passCount {
            output.frameLength = AVAudioFrameCount(frameCount)
            if let channels = output.floatChannelData {
                for channel in 0..<channelCount {
                    channels[channel].initialize(
                        repeating: 0,
                        count: frameCount
                    )
                }
            }

            let baseFrame = pass * frameCount
            let pullInput: AURenderPullInputBlock = {
                _, _, requestedFrameCount, _, inputData in
                let requested = Int(requestedFrameCount)
                let buffers = UnsafeMutableAudioBufferListPointer(inputData)
                guard buffers.count == channelCount else {
                    return kAudio_ParamError
                }

                for channel in 0..<channelCount {
                    guard let raw = buffers[channel].mData else {
                        return kAudio_ParamError
                    }
                    let samples = raw.assumingMemoryBound(to: Float.self)
                    let frequency = 79.0 + Double(channel * 23)
                    for frame in 0..<requested {
                        let absoluteFrame = baseFrame + frame
                        let phase =
                            2.0 * Double.pi * frequency
                            * Double(absoluteFrame)
                            / format.sampleRate
                        let impulse: Double =
                            absoluteFrame == channel ? 0.125 : 0
                        samples[frame] = Float(
                            0.05 * sin(phase) + impulse
                        )
                    }
                    buffers[channel].mDataByteSize = UInt32(
                        requested * MemoryLayout<Float>.size
                    )
                }
                return noErr
            }

            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(baseFrame)
            timestamp.mFlags = .sampleTimeValid

            let status = renderBlock(
                &flags,
                &timestamp,
                AVAudioFrameCount(frameCount),
                0,
                output.mutableAudioBufferList,
                pullInput
            )
            guard status == noErr else {
                throw AudioUnitOfflinePreparationError.renderFailed(status)
            }

            guard let channels = output.floatChannelData else {
                throw AudioUnitOfflinePreparationError.invalidOfflineRender
            }
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    let sample = Double(channels[channel][frame])
                    guard sample.isFinite else {
                        allFinite = false
                        throw AudioUnitOfflinePreparationError.nonFiniteOutput
                    }
                    maximumAbsolute = max(maximumAbsolute, abs(sample))
                    sumSquares[channel] += sample * sample
                }
            }
            renderedFrames += frameCount
        }

        let denominator = Double(max(renderedFrames, 1))
        let rms = sumSquares.map { sqrt($0 / denominator) }
        return AudioUnitOfflineRenderMetrics(
            renderedFrames: renderedFrames,
            renderPassCount: passCount,
            channelCount: channelCount,
            maximumAbsoluteSample: maximumAbsolute,
            rmsByChannel: rms,
            allSamplesFinite: allFinite
        )
    }

    private static func nearlyEqual(
        _ lhs: TimeInterval,
        _ rhs: TimeInterval
    ) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        return abs(lhs - rhs) <= 1.0e-9
    }
}
