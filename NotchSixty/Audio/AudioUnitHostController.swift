import AudioToolbox
import AVFAudio
import Combine
import Foundation

protocol AudioUnitComponentCataloging {
    func discoverEffects() -> [AudioUnitComponentDescriptor]
}

struct SystemAudioUnitComponentCatalog: AudioUnitComponentCataloging {
    func discoverEffects() -> [AudioUnitComponentDescriptor] {
        let manager = AVAudioUnitComponentManager.shared()
        let descriptions = [
            AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            ),
            AudioComponentDescription(
                componentType: kAudioUnitType_MusicEffect,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            ),
        ]

        var byIdentity: [
            AudioUnitComponentIdentity: AudioUnitComponentDescriptor
        ] = [:]

        for description in descriptions {
            for component in manager.components(matching: description) {
                let raw = component.audioComponentDescription
                let identity = AudioUnitComponentIdentity(
                    componentType: raw.componentType,
                    componentSubType: raw.componentSubType,
                    componentManufacturer: raw.componentManufacturer
                )
                let kind: AudioUnitEffectKind
                switch raw.componentType {
                case kAudioUnitType_Effect:
                    kind = .effect
                case kAudioUnitType_MusicEffect:
                    kind = .musicEffect
                default:
                    kind = .unsupported
                }

                var supported: [Int] = []
                supported.reserveCapacity(
                    AudioUnitRackProcessingFormat.maximumChannelCount
                )
                for channels in 1...AudioUnitRackProcessingFormat.maximumChannelCount
                where component.supportsNumberInputChannels(
                    channels,
                    outputChannels: channels
                ) {
                    supported.append(channels)
                }

                byIdentity[identity] = AudioUnitComponentDescriptor(
                    identity: identity,
                    kind: kind,
                    name: component.name,
                    manufacturerName: component.manufacturerName,
                    typeName: component.typeName,
                    version: component.version,
                    versionString: component.versionString,
                    hasCustomView: component.hasCustomView,
                    hasMIDIInput: component.hasMIDIInput,
                    hasMIDIOutput: component.hasMIDIOutput,
                    passesAUVal: component.passesAUVal,
                    sandboxSafe: component.isSandboxSafe,
                    supportedSymmetricChannelCounts: supported
                )
            }
        }

        return byIdentity.values.sorted {
            let manufacturerOrder = $0.manufacturerName.localizedCaseInsensitiveCompare(
                $1.manufacturerName
            )
            if manufacturerOrder != .orderedSame {
                return manufacturerOrder == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }
}

enum AudioUnitComponentLifecycleState: String, Codable, Sendable {
    case discovered
    case probing
    case prepared
    case quarantined
}

protocol AudioUnitHostProbeBackend {
    func probe(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat
    ) async throws -> AudioUnitProbeResult
}

/// Control-plane owner for Audio Unit discovery, persisted rack state,
/// compatibility/probe results, and quarantine.
///
/// PR79 deliberately does not expose a realtime render API. A later activation
/// PR must consume only a validated AudioUnitRackExecutionPlan.
@MainActor
final class AudioUnitHostController: ObservableObject {
    @Published private(set) var rackConfiguration: AudioUnitRackConfiguration
    @Published private(set) var discoveredComponents: [AudioUnitComponentDescriptor] = []
    @Published private(set) var lifecycleByComponent: [
        AudioUnitComponentIdentity: AudioUnitComponentLifecycleState
    ] = [:]
    @Published private(set) var quarantine = AudioUnitQuarantineRegistry()
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var lastErrorDescription: String?

    private let catalog: any AudioUnitComponentCataloging
    private var probesByComponent: [
        AudioUnitComponentIdentity: AudioUnitProbeResult
    ] = [:]
    private var probesBySlotID: [
        UUID: AudioUnitProbeResult
    ] = [:]
    private var offlineReportsBySlotID: [
        UUID: AudioUnitOfflinePreparationReport
    ] = [:]

    init(
        catalog: any AudioUnitComponentCataloging = SystemAudioUnitComponentCatalog(),
        rackConfiguration: AudioUnitRackConfiguration = AudioUnitRackConfiguration()
    ) {
        self.catalog = catalog
        self.rackConfiguration = rackConfiguration
    }

    var preparedComponentCount: Int {
        lifecycleByComponent.values.lazy.filter { $0 == .prepared }.count
    }

    var quarantinedComponentCount: Int {
        quarantine.entries.count
    }

    func scan(
        format: AudioUnitRackProcessingFormat? = nil
    ) {
        let components = catalog.discoverEffects()
        discoveredComponents = components

        var nextLifecycle: [
            AudioUnitComponentIdentity: AudioUnitComponentLifecycleState
        ] = [:]
        for descriptor in components {
            if quarantine.isQuarantined(descriptor.identity) {
                nextLifecycle[descriptor.identity] = .quarantined
            } else if probesByComponent[descriptor.identity] != nil {
                nextLifecycle[descriptor.identity] = .prepared
            } else {
                nextLifecycle[descriptor.identity] = .discovered
            }
        }
        lifecycleByComponent = nextLifecycle
        lastScanDate = Date()

        if let format {
            do {
                try format.validate()
                lastErrorDescription = nil
            } catch {
                lastErrorDescription = error.localizedDescription
            }
        } else {
            lastErrorDescription = nil
        }
    }

    func descriptor(
        for identity: AudioUnitComponentIdentity
    ) -> AudioUnitComponentDescriptor? {
        discoveredComponents.first { $0.identity == identity }
    }

    func compatibility(
        of descriptor: AudioUnitComponentDescriptor,
        for format: AudioUnitRackProcessingFormat
    ) -> AudioUnitComponentCompatibility {
        descriptor.compatibility(for: format)
    }

    func replaceRackConfiguration(
        _ configuration: AudioUnitRackConfiguration
    ) throws {
        try configuration.validate()
        rackConfiguration = configuration
        lastErrorDescription = nil
    }

    func installComponent(
        _ identity: AudioUnitComponentIdentity,
        inSlot index: Int
    ) throws {
        guard rackConfiguration.slots.indices.contains(index) else {
            throw AudioUnitRackError.slotIndexOutOfRange(index)
        }
        guard let descriptor = descriptor(for: identity) else {
            throw AudioUnitRackError.componentNotDiscovered(identity)
        }

        var updated = rackConfiguration
        let existingID = updated.slots[index].id
        probesBySlotID.removeValue(forKey: existingID)
        offlineReportsBySlotID.removeValue(forKey: existingID)
        updated.slots[index] = AudioUnitRackSlotState(
            id: existingID,
            component: identity,
            displayName: descriptor.name,
            manufacturerName: descriptor.manufacturerName,
            bypassed: true,
            wetDryMix: 1
        )
        try replaceRackConfiguration(updated)
    }

    func removeComponent(
        fromSlot index: Int
    ) throws {
        guard rackConfiguration.slots.indices.contains(index) else {
            throw AudioUnitRackError.slotIndexOutOfRange(index)
        }
        var updated = rackConfiguration
        let existingID = updated.slots[index].id
        let removedComponent = updated.slots[index].component
        probesBySlotID.removeValue(forKey: existingID)
        offlineReportsBySlotID.removeValue(forKey: existingID)
        updated.slots[index] = AudioUnitRackSlotState(id: existingID)
        try replaceRackConfiguration(updated)
        if let removedComponent {
            refreshLifecycle(for: removedComponent)
        }
    }

    func setBypassed(
        _ bypassed: Bool,
        slot index: Int
    ) throws {
        guard rackConfiguration.slots.indices.contains(index) else {
            throw AudioUnitRackError.slotIndexOutOfRange(index)
        }
        var updated = rackConfiguration
        if !bypassed,
           let component = updated.slots[index].component {
            let slotID = updated.slots[index].id
            guard probesBySlotID[slotID] != nil,
                  !quarantine.isQuarantined(component) else {
                throw AudioUnitRackError.componentNotPrepared(component)
            }
        }
        updated.slots[index].bypassed = bypassed
        try replaceRackConfiguration(updated)
    }

    func setWetDryMix(
        _ mix: Double,
        slot index: Int
    ) throws {
        guard rackConfiguration.slots.indices.contains(index) else {
            throw AudioUnitRackError.slotIndexOutOfRange(index)
        }
        var updated = rackConfiguration
        updated.slots[index].wetDryMix = mix
        try replaceRackConfiguration(updated)
    }

    func setOpaqueFullState(
        _ state: Data?,
        slot index: Int
    ) throws {
        guard rackConfiguration.slots.indices.contains(index) else {
            throw AudioUnitRackError.slotIndexOutOfRange(index)
        }
        var updated = rackConfiguration
        let slotID = updated.slots[index].id
        let component = updated.slots[index].component
        updated.slots[index].opaqueFullState = state
        updated.slots[index].bypassed = true
        probesBySlotID.removeValue(forKey: slotID)
        offlineReportsBySlotID.removeValue(forKey: slotID)
        try replaceRackConfiguration(updated)
        if let component {
            refreshLifecycle(for: component)
        }
    }

    func probe(
        component identity: AudioUnitComponentIdentity,
        format: AudioUnitRackProcessingFormat,
        using backend: any AudioUnitHostProbeBackend
    ) async {
        guard let descriptor = descriptor(for: identity) else {
            lastErrorDescription =
                AudioUnitRackError.componentNotDiscovered(identity)
                    .localizedDescription
            return
        }

        let compatibility = descriptor.compatibility(for: format)
        guard compatibility.compatible else {
            let reason: AudioUnitQuarantineReason
            if !descriptor.sandboxSafe {
                reason = .sandboxUnsafe
            } else if !descriptor.supports(channelCount: format.channelCount) {
                reason = .unsupportedChannelLayout
            } else {
                reason = .validationFailed
            }
            let description = compatibility.reasons.joined(separator: " ")
            quarantineComponent(
                identity,
                reason: reason,
                description: description
            )
            return
        }

        lifecycleByComponent[identity] = .probing
        do {
            let result = try await backend.probe(
                component: descriptor,
                format: format
            )
            guard result.component == identity else {
                throw AudioUnitRackError.probeFormatMismatch(identity)
            }
            try result.validate(for: format)
            probesByComponent[identity] = result

            var updated = rackConfiguration
            for index in updated.slots.indices
            where updated.slots[index].component == identity {
                updated.slots[index].recordProbe(result)
                probesBySlotID[updated.slots[index].id] = result
            }
            try updated.validate()
            rackConfiguration = updated
            quarantine.clear(component: identity)
            lifecycleByComponent[identity] = .prepared
            lastErrorDescription = nil
        } catch {
            let reason = Self.quarantineReason(for: error)
            quarantineComponent(
                identity,
                reason: reason,
                description: error.localizedDescription
            )
        }
    }

    func prepareSlotOffline(
        _ index: Int,
        format: AudioUnitRackProcessingFormat,
        using backend: any AudioUnitOfflinePreparing
    ) async {
        guard rackConfiguration.slots.indices.contains(index) else {
            lastErrorDescription =
                AudioUnitRackError.slotIndexOutOfRange(index)
                    .localizedDescription
            return
        }
        let slot = rackConfiguration.slots[index]
        guard let identity = slot.component,
              let descriptor = descriptor(for: identity) else {
            lastErrorDescription = slot.component.map {
                AudioUnitRackError.componentNotDiscovered($0)
                    .localizedDescription
            } ?? AudioUnitRackError.slotIndexOutOfRange(index)
                .localizedDescription
            return
        }

        let compatibility = descriptor.compatibility(for: format)
        guard compatibility.compatible else {
            let reason: AudioUnitQuarantineReason
            if !descriptor.sandboxSafe {
                reason = .sandboxUnsafe
            } else if !descriptor.supports(channelCount: format.channelCount) {
                reason = .unsupportedChannelLayout
            } else {
                reason = .validationFailed
            }
            quarantineComponent(
                identity,
                reason: reason,
                description: compatibility.reasons.joined(separator: " ")
            )
            return
        }

        lifecycleByComponent[identity] = .probing
        do {
            let report = try await backend.prepare(
                component: descriptor,
                format: format,
                restoringState: slot.opaqueFullState
            )
            try report.validate()
            guard report.component == identity else {
                throw AudioUnitOfflinePreparationError
                    .componentIdentityMismatch
            }

            var updated = rackConfiguration
            let current = updated.slots[index]
            guard current.id == slot.id,
                  current.component == identity else {
                throw AudioUnitOfflinePreparationError
                    .componentIdentityMismatch
            }
            updated.slots[index].recordProbe(report.probe)
            if let state = report.capturedFullState {
                updated.slots[index].opaqueFullState = state
            }
            updated.slots[index].bypassed = true
            try updated.validate()

            rackConfiguration = updated
            probesByComponent[identity] = report.probe
            probesBySlotID[slot.id] = report.probe
            offlineReportsBySlotID[slot.id] = report
            quarantine.clear(component: identity)
            lifecycleByComponent[identity] = .prepared
            lastErrorDescription = nil
        } catch {
            quarantineComponent(
                identity,
                reason: Self.quarantineReason(for: error),
                description: error.localizedDescription
            )
        }
    }

    func offlinePreparationReport(
        forSlot index: Int
    ) -> AudioUnitOfflinePreparationReport? {
        guard rackConfiguration.slots.indices.contains(index) else {
            return nil
        }
        return offlineReportsBySlotID[
            rackConfiguration.slots[index].id
        ]
    }

    func quarantineComponent(
        _ identity: AudioUnitComponentIdentity,
        reason: AudioUnitQuarantineReason,
        description: String,
        at date: Date = Date()
    ) {
        probesByComponent.removeValue(forKey: identity)
        let affectedSlotIDs = rackConfiguration.slots.compactMap {
            $0.component == identity ? $0.id : nil
        }
        for slotID in affectedSlotIDs {
            probesBySlotID.removeValue(forKey: slotID)
            offlineReportsBySlotID.removeValue(forKey: slotID)
        }
        quarantine.recordFailure(
            component: identity,
            reason: reason,
            description: description,
            at: date
        )

        var updated = rackConfiguration
        for index in updated.slots.indices
        where updated.slots[index].component == identity {
            updated.slots[index].bypassed = true
        }
        rackConfiguration = updated
        lifecycleByComponent[identity] = .quarantined
        lastErrorDescription = description
    }

    func clearQuarantine(
        _ identity: AudioUnitComponentIdentity
    ) {
        quarantine.clear(component: identity)
        if descriptor(for: identity) != nil {
            // Quarantine invalidates any prior preparation. Clearing it only
            // returns the component to discovery; a fresh probe is mandatory.
            lifecycleByComponent[identity] = .discovered
        } else {
            lifecycleByComponent.removeValue(forKey: identity)
        }
        lastErrorDescription = nil
    }

    func prepareActiveSlotsForLive(
        format: AudioUnitRackProcessingFormat,
        using backend: any AudioUnitOfflinePreparing =
            SystemAudioUnitOfflinePreparationBackend()
    ) async {
        scan(format: format)
        for index in rackConfiguration.slots.indices {
            let slot = rackConfiguration.slots[index]
            guard let component = slot.component,
                  !slot.bypassed,
                  !quarantine.isQuarantined(component) else {
                continue
            }

            if let report = offlineReportsBySlotID[slot.id],
               report.format == format,
               report.component == component,
               report.capturedFullState == slot.opaqueFullState {
                continue
            }

            await prepareSlotOffline(
                index,
                format: format,
                using: backend
            )
        }
    }

    func makeLiveRackRuntime(
        format: AudioUnitRackProcessingFormat
    ) async throws -> AudioUnitLiveRackRuntime? {
        let plan = try executionPlan(for: format)
        var buildSlots: [AudioUnitLiveRackBuildSlot] = []
        buildSlots.reserveCapacity(rackConfiguration.slots.count)

        for (index, slot) in rackConfiguration.slots.enumerated() {
            let execution = plan.slots[index]
            let descriptor = slot.component.flatMap {
                descriptor(for: $0)
            }
            let report = offlineReportsBySlotID[slot.id]
            if execution.mode == .process {
                guard report != nil else {
                    throw AudioUnitLiveRackBuildError
                        .missingPreparedSlot(index)
                }
            }
            buildSlots.append(AudioUnitLiveRackBuildSlot(
                slotIndex: index,
                slot: slot,
                execution: execution,
                descriptor: descriptor,
                offlineReport: report
            ))
        }

        let runtime = try await AudioUnitLiveRackRuntime.build(
            format: format,
            plan: plan,
            slots: buildSlots
        )
        runtime?.startFaultMonitoring { [weak self] fault in
            guard let component = fault.component else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.quarantineComponent(
                    component,
                    reason: .runtimeFailure,
                    description: fault.description
                )
            }
        }
        return runtime
    }

    func executionPlan(
        for format: AudioUnitRackProcessingFormat
    ) throws -> AudioUnitRackExecutionPlan {
        try AudioUnitRackPreparationPlanner().prepare(
            configuration: rackConfiguration,
            descriptors: discoveredComponents,
            probes: Array(probesByComponent.values),
            slotProbes: probesBySlotID,
            quarantine: quarantine,
            format: format
        )
    }

    func probeResult(
        for identity: AudioUnitComponentIdentity
    ) -> AudioUnitProbeResult? {
        probesByComponent[identity]
    }

    func probeResult(
        forSlot index: Int
    ) -> AudioUnitProbeResult? {
        guard rackConfiguration.slots.indices.contains(index) else {
            return nil
        }
        return probesBySlotID[rackConfiguration.slots[index].id]
    }

    private func refreshLifecycle(
        for identity: AudioUnitComponentIdentity
    ) {
        if quarantine.isQuarantined(identity) {
            lifecycleByComponent[identity] = .quarantined
            return
        }
        let prepared = rackConfiguration.slots.contains {
            $0.component == identity
                && probesBySlotID[$0.id] != nil
        }
        lifecycleByComponent[identity] = prepared
            ? .prepared
            : .discovered
        if !prepared {
            probesByComponent.removeValue(forKey: identity)
        }
    }

    private static func quarantineReason(
        for error: Error
    ) -> AudioUnitQuarantineReason {
        if let offlineError =
            error as? AudioUnitOfflinePreparationError {
            switch offlineError {
            case .stateDecodeFailed,
                 .stateRestoreFailed,
                 .stateCaptureFailed,
                 .stateTooLarge:
                return .stateRestoreFailure
            case .latencyChangedAcrossReset:
                return .invalidLatency
            case .tailChangedAcrossReset:
                return .invalidTail
            case .renderResourceAllocationFailed,
                 .renderBlockUnavailable,
                 .renderResourcesNotReleased:
                return .renderResourceFailure
            case .renderFailed,
                 .invalidOfflineRender,
                 .nonFiniteOutput:
                return .runtimeFailure
            case .incompatibleComponent:
                return .unsupportedChannelLayout
            case .instantiationFailed,
                 .componentIdentityMismatch,
                 .missingInputBus,
                 .missingOutputBus,
                 .formatConfigurationFailed:
                return .instantiationFailed
            }
        }

        guard let rackError = error as? AudioUnitRackError else {
            return .instantiationFailed
        }
        switch rackError {
        case .invalidProbeLatency:
            return .invalidLatency
        case .invalidProbeTail:
            return .invalidTail
        case .probeFormatMismatch, .insufficientMaximumFrames:
            return .renderResourceFailure
        default:
            return .instantiationFailed
        }
    }
}
