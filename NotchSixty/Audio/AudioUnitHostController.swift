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
        updated.slots[index] = AudioUnitRackSlotState(id: existingID)
        try replaceRackConfiguration(updated)
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
           let component = updated.slots[index].component,
           lifecycleByComponent[component] != .prepared {
            throw AudioUnitRackError.componentNotPrepared(component)
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
        updated.slots[index].opaqueFullState = state
        try replaceRackConfiguration(updated)
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
            quarantine.recordFailure(
                component: identity,
                reason: reason,
                description: description
            )
            lifecycleByComponent[identity] = .quarantined
            lastErrorDescription = description
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
            }
            try updated.validate()
            rackConfiguration = updated
            quarantine.clear(component: identity)
            lifecycleByComponent[identity] = .prepared
            lastErrorDescription = nil
        } catch {
            let reason = Self.quarantineReason(for: error)
            quarantine.recordFailure(
                component: identity,
                reason: reason,
                description: error.localizedDescription
            )
            lifecycleByComponent[identity] = .quarantined
            lastErrorDescription = error.localizedDescription
        }
    }

    func clearQuarantine(
        _ identity: AudioUnitComponentIdentity
    ) {
        quarantine.clear(component: identity)
        if descriptor(for: identity) != nil {
            lifecycleByComponent[identity] =
                probesByComponent[identity] == nil ? .discovered : .prepared
        } else {
            lifecycleByComponent.removeValue(forKey: identity)
        }
        lastErrorDescription = nil
    }

    func executionPlan(
        for format: AudioUnitRackProcessingFormat
    ) throws -> AudioUnitRackExecutionPlan {
        try AudioUnitRackPreparationPlanner().prepare(
            configuration: rackConfiguration,
            descriptors: discoveredComponents,
            probes: Array(probesByComponent.values),
            quarantine: quarantine,
            format: format
        )
    }

    func probeResult(
        for identity: AudioUnitComponentIdentity
    ) -> AudioUnitProbeResult? {
        probesByComponent[identity]
    }

    private static func quarantineReason(
        for error: Error
    ) -> AudioUnitQuarantineReason {
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
