import Foundation

struct AudioUnitComponentIdentity: Codable, Hashable, Sendable, Identifiable {
    let componentType: UInt32
    let componentSubType: UInt32
    let componentManufacturer: UInt32

    var id: String {
        "\(componentType)-\(componentSubType)-\(componentManufacturer)"
    }

    var fourCCSummary: String {
        [
            Self.fourCC(componentType),
            Self.fourCC(componentSubType),
            Self.fourCC(componentManufacturer),
        ].joined(separator: "/")
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 <= 126 }
        return printable
            ? String(bytes: bytes, encoding: .ascii) ?? String(format: "%08X", value)
            : String(format: "%08X", value)
    }
}

enum AudioUnitEffectKind: String, Codable, Sendable {
    case effect
    case musicEffect
    case unsupported
}

struct AudioUnitComponentDescriptor: Codable, Equatable, Hashable, Sendable, Identifiable {
    let identity: AudioUnitComponentIdentity
    let kind: AudioUnitEffectKind
    let name: String
    let manufacturerName: String
    let typeName: String
    let version: Int
    let versionString: String
    let hasCustomView: Bool
    let hasMIDIInput: Bool
    let hasMIDIOutput: Bool
    let passesAUVal: Bool
    let sandboxSafe: Bool
    let supportedSymmetricChannelCounts: [Int]

    var id: String { identity.id }

    func supports(channelCount: Int) -> Bool {
        supportedSymmetricChannelCounts.contains(channelCount)
    }

    func compatibility(
        for format: AudioUnitRackProcessingFormat,
        separateProcess: Bool = AudioUnitLoadingPolicy.separateProcessEnabled
    ) -> AudioUnitComponentCompatibility {
        var reasons: [String] = []
        if kind == .unsupported {
            reasons.append("Only Audio Unit effects and music effects are supported.")
        }
        if !passesAUVal {
            reasons.append("The component does not report a passing AU validation result.")
        }
        if !sandboxSafe, !separateProcess {
            reasons.append("The component is not reported as safe in the current sandboxed process.")
        }
        if !supports(channelCount: format.channelCount),
           !format.runsAsStereoPairs(on: self) {
            reasons.append(
                "The component does not report symmetric \(format.channelCount)-in / \(format.channelCount)-out support."
            )
        }
        return AudioUnitComponentCompatibility(
            compatible: reasons.isEmpty,
            reasons: reasons
        )
    }
}

struct AudioUnitComponentCompatibility: Codable, Equatable, Sendable {
    let compatible: Bool
    let reasons: [String]
}

struct AudioUnitRackProcessingFormat: Codable, Equatable, Sendable {
    static let maximumChannelCount = 32
    static let maximumSampleRate = 384_000.0

    let sampleRate: Double
    let channelCount: Int
    let maximumFramesPerSlice: Int
    /// E33 S25: the program role of each lane, when known (wide sessions). nil pairs lanes 0 and 1 only.
    let channelRoles: [OutputProgramRole]?
    /// E33 S25: Swift sets this from `e33.page-enhancements`; off, a stereo-only plug-in stays incompatible on a wide session.
    let allowsStereoPairs: Bool

    init(
        sampleRate: Double,
        channelCount: Int,
        maximumFramesPerSlice: Int = 4_096,
        channelRoles: [OutputProgramRole]? = nil,
        allowsStereoPairs: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.maximumFramesPerSlice = maximumFramesPerSlice
        self.channelRoles = channelRoles
        self.allowsStereoPairs = allowsStereoPairs
    }

    /// E33 S25: true when `descriptor` cannot run on every lane but does run as a stereo plug-in, so the rack runs
    /// it on left/right pairs of lanes (decision 29).
    func runsAsStereoPairs(on descriptor: AudioUnitComponentDescriptor) -> Bool {
        allowsStereoPairs
            && channelCount > 2
            && !descriptor.supports(channelCount: channelCount)
            && descriptor.supports(channelCount: 2)
    }

    /// The format one instance of the plug-in runs at: this format, or its stereo pair form (two lanes, no roles).
    func slotFormat(for descriptor: AudioUnitComponentDescriptor?) -> AudioUnitRackProcessingFormat {
        guard let descriptor, runsAsStereoPairs(on: descriptor) else { return self }
        return AudioUnitRackProcessingFormat(
            sampleRate: sampleRate,
            channelCount: 2,
            maximumFramesPerSlice: maximumFramesPerSlice
        )
    }

    /// Slice budget scaled with sample rate so high-rate devices, whose HAL
    /// buffers are proportionally larger, are not rejected by a fixed 4096:
    /// 4096 through 48 kHz, 8192 at 88.2/96, 16384 at 176.4/192, 32768 at
    /// 352.8/384 kHz.
    static func recommendedMaximumFramesPerSlice(sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 4_096 }
        let multiple = Int(ceil(sampleRate / 48_000.0 - 1.0e-9))
        var frames = 4_096
        while frames < 4_096 * multiple, frames < 32_768 { frames <<= 1 }
        return frames
    }

    func validate() throws {
        guard sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= Self.maximumSampleRate else {
            throw AudioUnitRackError.invalidSampleRate(sampleRate)
        }
        guard (1...Self.maximumChannelCount).contains(channelCount) else {
            throw AudioUnitRackError.invalidChannelCount(channelCount)
        }
        guard maximumFramesPerSlice >= 16,
              maximumFramesPerSlice <= 65_536 else {
            throw AudioUnitRackError.invalidMaximumFramesPerSlice(
                maximumFramesPerSlice
            )
        }
    }
}

/// E33 S25 (G48, decision 29): which lanes a stereo-only plug-in runs on in a session wider than stereo.
enum AudioUnitSlotChannelMode: String, Codable, CaseIterable, Sendable {
    case frontLeftRight
    case everyPair

    var displayName: String {
        switch self {
        case .frontLeftRight: return "Front left and right"
        case .everyPair: return "Every pair"
        }
    }

    /// The lane pairs (left, right) one instance each runs on. Roles pair by side (front, side, rear, wide, top
    /// front, top middle, top rear); the centre and LFE belong to no pair. Without roles only lanes 0 and 1 pair.
    func lanePairs(
        channelCount: Int,
        roles: [OutputProgramRole]?
    ) -> [(left: Int, right: Int)] {
        guard channelCount >= 2 else { return [] }
        guard let roles, roles.count == channelCount else { return [(0, 1)] }
        let sides: [(OutputProgramRole, OutputProgramRole)] = [
            (.frontLeft, .frontRight), (.sideLeft, .sideRight), (.rearLeft, .rearRight),
            (.wideLeft, .wideRight), (.topFrontLeft, .topFrontRight),
            (.topMiddleLeft, .topMiddleRight), (.topRearLeft, .topRearRight),
        ]
        var pairs: [(left: Int, right: Int)] = []
        for (left, right) in sides {
            guard let l = roles.firstIndex(of: left), let r = roles.firstIndex(of: right) else { continue }
            pairs.append((l, r))
            if self == .frontLeftRight { break }
        }
        return pairs.isEmpty ? [(0, 1)] : pairs
    }
}

struct AudioUnitRackSlotState: Codable, Equatable, Sendable, Identifiable {
    static let maximumOpaqueStateBytes = 8 * 1_024 * 1_024

    var id: UUID
    var component: AudioUnitComponentIdentity?
    var displayName: String?
    var manufacturerName: String?
    var bypassed: Bool
    var wetDryMix: Double
    var opaqueFullState: Data?
    var lastKnownLatencyFrames: Int?
    var lastKnownTailFrames: Int?
    /// E33 S25: nil in presets saved before the Channels choice existed; reads as `.frontLeftRight`.
    var channelMode: AudioUnitSlotChannelMode?

    var channels: AudioUnitSlotChannelMode { channelMode ?? .frontLeftRight }

    init(
        id: UUID = UUID(),
        component: AudioUnitComponentIdentity? = nil,
        displayName: String? = nil,
        manufacturerName: String? = nil,
        bypassed: Bool = true,
        wetDryMix: Double = 1.0,
        opaqueFullState: Data? = nil,
        lastKnownLatencyFrames: Int? = nil,
        lastKnownTailFrames: Int? = nil,
        channelMode: AudioUnitSlotChannelMode? = nil
    ) {
        self.id = id
        self.component = component
        self.displayName = displayName
        self.manufacturerName = manufacturerName
        self.bypassed = bypassed
        self.wetDryMix = wetDryMix
        self.opaqueFullState = opaqueFullState
        self.lastKnownLatencyFrames = lastKnownLatencyFrames
        self.lastKnownTailFrames = lastKnownTailFrames
        self.channelMode = channelMode
    }

    var isEmpty: Bool { component == nil }

    mutating func recordProbe(_ probe: AudioUnitProbeResult) {
        guard probe.component == component else { return }
        lastKnownLatencyFrames = probe.latencyFrames
        lastKnownTailFrames = probe.tailFrames
    }

    func validate() throws {
        guard wetDryMix.isFinite,
              (0.0...1.0).contains(wetDryMix) else {
            throw AudioUnitRackError.invalidWetDryMix(
                slotID: id,
                value: wetDryMix
            )
        }
        if component == nil {
            guard opaqueFullState == nil,
                  lastKnownLatencyFrames == nil,
                  lastKnownTailFrames == nil else {
                throw AudioUnitRackError.orphanedSlotState(id)
            }
        }
        if let opaqueFullState,
           opaqueFullState.count > Self.maximumOpaqueStateBytes {
            throw AudioUnitRackError.slotStateTooLarge(
                slotID: id,
                bytes: opaqueFullState.count
            )
        }
        if let latency = lastKnownLatencyFrames, latency < 0 {
            throw AudioUnitRackError.invalidStoredLatency(
                slotID: id,
                frames: latency
            )
        }
        if let tail = lastKnownTailFrames, tail < 0 {
            throw AudioUnitRackError.invalidStoredTail(
                slotID: id,
                frames: tail
            )
        }
    }
}

struct AudioUnitRackConfiguration: Codable, Equatable, Sendable {
    static let defaultSlotCount = 4
    static let maximumSlotCount = 8
    static let maximumTotalOpaqueStateBytes = 32 * 1_024 * 1_024

    var slots: [AudioUnitRackSlotState]

    init(
        slots: [AudioUnitRackSlotState] = (0..<defaultSlotCount).map { _ in
            AudioUnitRackSlotState()
        }
    ) {
        self.slots = slots
    }

    var occupiedSlotCount: Int {
        slots.lazy.filter { !$0.isEmpty }.count
    }

    func validate() throws {
        guard (1...Self.maximumSlotCount).contains(slots.count) else {
            throw AudioUnitRackError.invalidSlotCount(slots.count)
        }
        guard Set(slots.map(\.id)).count == slots.count else {
            throw AudioUnitRackError.duplicateSlotIdentifier
        }
        var totalStateBytes = 0
        for slot in slots {
            try slot.validate()
            totalStateBytes += slot.opaqueFullState?.count ?? 0
        }
        guard totalStateBytes <= Self.maximumTotalOpaqueStateBytes else {
            throw AudioUnitRackError.rackStateTooLarge(totalStateBytes)
        }
    }
}

enum AudioUnitQuarantineReason: String, Codable, Sendable {
    case validationFailed
    case sandboxUnsafe
    case unsupportedChannelLayout
    case instantiationFailed
    case renderResourceFailure
    case invalidLatency
    case invalidTail
    case stateRestoreFailure
    case runtimeFailure
    /// E33 S22: the plug-in's separate process stopped (the render call failed).
    case processStopped
    case manual
}

struct AudioUnitQuarantineEntry: Codable, Equatable, Sendable, Identifiable {
    let component: AudioUnitComponentIdentity
    var reason: AudioUnitQuarantineReason
    var failureCount: Int
    var lastFailureDescription: String
    var lastFailureAt: Date

    var id: String { component.id }
}

struct AudioUnitQuarantineRegistry: Codable, Equatable, Sendable {
    private(set) var entries: [AudioUnitQuarantineEntry] = []

    func entry(
        for component: AudioUnitComponentIdentity
    ) -> AudioUnitQuarantineEntry? {
        entries.first { $0.component == component }
    }

    func isQuarantined(
        _ component: AudioUnitComponentIdentity
    ) -> Bool {
        entry(for: component) != nil
    }

    mutating func recordFailure(
        component: AudioUnitComponentIdentity,
        reason: AudioUnitQuarantineReason,
        description: String,
        at date: Date = Date()
    ) {
        if let index = entries.firstIndex(where: {
            $0.component == component
        }) {
            entries[index].reason = reason
            entries[index].failureCount += 1
            entries[index].lastFailureDescription = description
            entries[index].lastFailureAt = date
        } else {
            entries.append(AudioUnitQuarantineEntry(
                component: component,
                reason: reason,
                failureCount: 1,
                lastFailureDescription: description,
                lastFailureAt: date
            ))
        }
    }

    mutating func clear(
        component: AudioUnitComponentIdentity
    ) {
        entries.removeAll { $0.component == component }
    }
}

struct AudioUnitProbeResult: Codable, Equatable, Sendable {
    static let maximumLatencySeconds = 10.0
    static let maximumTailSeconds = 120.0

    let component: AudioUnitComponentIdentity
    let sampleRate: Double
    let inputChannelCount: Int
    let outputChannelCount: Int
    let maximumFramesToRender: Int
    let latencySeconds: Double
    let tailTimeSeconds: Double
    let supportsFullState: Bool
    let supportsHostBypass: Bool

    static func conservativeFrameCount(
        seconds: Double,
        sampleRate: Double
    ) -> Int {
        guard sampleRate.isFinite,
              sampleRate > 0,
              seconds.isFinite else {
            return 0
        }

        let frames = max(0, seconds) * sampleRate
        guard frames.isFinite,
              frames <= Double(Int.max) else {
            return 0
        }

        let nearest = frames.rounded()
        let tolerance = max(1.0e-9, abs(frames) * 1.0e-12)
        if abs(frames - nearest) <= tolerance {
            return Int(nearest)
        }
        return Int(ceil(frames))
    }

    var latencyFrames: Int {
        Self.conservativeFrameCount(
            seconds: latencySeconds,
            sampleRate: sampleRate
        )
    }

    var tailFrames: Int {
        Self.conservativeFrameCount(
            seconds: tailTimeSeconds,
            sampleRate: sampleRate
        )
    }

    func validate(
        for format: AudioUnitRackProcessingFormat
    ) throws {
        try format.validate()
        guard sampleRate.isFinite,
              abs(sampleRate - format.sampleRate) < 0.5,
              inputChannelCount == format.channelCount,
              outputChannelCount == format.channelCount else {
            throw AudioUnitRackError.probeFormatMismatch(component)
        }
        guard maximumFramesToRender >= format.maximumFramesPerSlice else {
            throw AudioUnitRackError.insufficientMaximumFrames(
                component: component,
                available: maximumFramesToRender,
                required: format.maximumFramesPerSlice
            )
        }
        guard latencySeconds.isFinite,
              latencySeconds >= 0,
              latencySeconds <= Self.maximumLatencySeconds else {
            throw AudioUnitRackError.invalidProbeLatency(
                component: component,
                seconds: latencySeconds
            )
        }
        guard tailTimeSeconds.isFinite,
              tailTimeSeconds >= 0,
              tailTimeSeconds <= Self.maximumTailSeconds else {
            throw AudioUnitRackError.invalidProbeTail(
                component: component,
                seconds: tailTimeSeconds
            )
        }
    }
}

/// E7 S3 (`e7.rate-adapt`): text for a plug-in that refuses the device rate.
enum AudioUnitRateRefusal {
    static func message(rate: Double) -> String {
        let khz = rate / 1_000
        let text = khz == khz.rounded()
            ? String(Int(khz))
            : String(format: "%.1f", khz)
        return "Not available at \(text) kHz"
    }

    static func contains(_ rates: Set<Double>?, _ rate: Double) -> Bool {
        rates?.contains { abs($0 - rate) < 0.5 } ?? false
    }
}

enum AudioUnitSlotExecutionMode: String, Codable, Sendable {
    case empty
    case process
    case latencyMatchedBypass
}

struct AudioUnitRackSlotExecutionPlan: Codable, Equatable, Sendable, Identifiable {
    let slotID: UUID
    let component: AudioUnitComponentIdentity?
    let mode: AudioUnitSlotExecutionMode
    let latencyFrames: Int
    let tailFrames: Int
    let wetDryMix: Double
    let dryCompensationFrames: Int
    let reason: String?

    var id: UUID { slotID }
}

struct AudioUnitRackExecutionPlan: Codable, Equatable, Sendable {
    let format: AudioUnitRackProcessingFormat
    let slots: [AudioUnitRackSlotExecutionPlan]
    let totalLatencyFrames: Int
    let totalTailFrames: Int
    let requiresLatencyMatchedBypass: Bool
}

struct AudioUnitRackPreparationPlanner: Sendable {
    func prepare(
        configuration: AudioUnitRackConfiguration,
        descriptors: [AudioUnitComponentDescriptor],
        probes: [AudioUnitProbeResult],
        slotProbes: [UUID: AudioUnitProbeResult] = [:],
        quarantine: AudioUnitQuarantineRegistry,
        format: AudioUnitRackProcessingFormat,
        rateRefusals: [AudioUnitComponentIdentity: Set<Double>] = [:]
    ) throws -> AudioUnitRackExecutionPlan {
        try configuration.validate()
        try format.validate()

        var descriptorsByID: [
            AudioUnitComponentIdentity: AudioUnitComponentDescriptor
        ] = [:]
        for descriptor in descriptors {
            descriptorsByID[descriptor.identity] = descriptor
        }
        var probesByID: [
            AudioUnitComponentIdentity: AudioUnitProbeResult
        ] = [:]
        for probe in probes {
            probesByID[probe.component] = probe
        }

        var plans: [AudioUnitRackSlotExecutionPlan] = []
        plans.reserveCapacity(configuration.slots.count)
        var totalLatency = 0
        var totalTail = 0
        var requiresBypass = false

        for slot in configuration.slots {
            guard let component = slot.component else {
                plans.append(AudioUnitRackSlotExecutionPlan(
                    slotID: slot.id,
                    component: nil,
                    mode: .empty,
                    latencyFrames: 0,
                    tailFrames: 0,
                    wetDryMix: 1,
                    dryCompensationFrames: 0,
                    reason: nil
                ))
                continue
            }

            let probe = slotProbes[slot.id] ?? probesByID[component]
            let descriptor = descriptorsByID[component]
            let slotFormat = format.slotFormat(for: descriptor)

            if let quarantineEntry = quarantine.entry(for: component) {
                let latency = try bypassLatency(
                    slot: slot,
                    probe: probe,
                    format: slotFormat,
                    reason: "Component is quarantined: \(quarantineEntry.lastFailureDescription)"
                )
                plans.append(bypassPlan(
                    slot: slot,
                    component: component,
                    latency: latency,
                    reason: "Quarantined: \(quarantineEntry.reason.rawValue)"
                ))
                totalLatency = try addFrames(
                    totalLatency,
                    latency,
                    limit: Int(format.sampleRate * AudioUnitProbeResult.maximumLatencySeconds)
                )
                requiresBypass = true
                continue
            }

            guard let descriptor else {
                let latency = try bypassLatency(
                    slot: slot,
                    probe: probe,
                    format: slotFormat,
                    reason: "Component is no longer installed."
                )
                plans.append(bypassPlan(
                    slot: slot,
                    component: component,
                    latency: latency,
                    reason: "Component missing"
                ))
                totalLatency = try addFrames(
                    totalLatency,
                    latency,
                    limit: Int(format.sampleRate * AudioUnitProbeResult.maximumLatencySeconds)
                )
                requiresBypass = true
                continue
            }

            let compatibility = descriptor.compatibility(for: format)
            if !compatibility.compatible {
                let latency = try bypassLatency(
                    slot: slot,
                    probe: probe,
                    format: slotFormat,
                    reason: compatibility.reasons.joined(separator: " ")
                )
                plans.append(bypassPlan(
                    slot: slot,
                    component: component,
                    latency: latency,
                    reason: compatibility.reasons.joined(separator: " ")
                ))
                totalLatency = try addFrames(
                    totalLatency,
                    latency,
                    limit: Int(format.sampleRate * AudioUnitProbeResult.maximumLatencySeconds)
                )
                requiresBypass = true
                continue
            }

            if AudioUnitRateRefusal.contains(
                rateRefusals[component],
                format.sampleRate
            ) {
                // The unit never ran at this rate, so its latency is the
                // last probe's seconds at this rate (0 if never probed).
                let latency = probe.map {
                    AudioUnitProbeResult.conservativeFrameCount(
                        seconds: $0.latencySeconds,
                        sampleRate: format.sampleRate
                    )
                } ?? 0
                let reason = AudioUnitRateRefusal.message(
                    rate: format.sampleRate
                )
                plans.append(bypassPlan(
                    slot: slot,
                    component: component,
                    latency: latency,
                    reason: reason
                ))
                totalLatency = try addFrames(
                    totalLatency,
                    latency,
                    limit: Int(format.sampleRate * AudioUnitProbeResult.maximumLatencySeconds)
                )
                requiresBypass = true
                continue
            }

            if slot.bypassed {
                let latency: Int
                if let probe {
                    try probe.validate(for: slotFormat)
                    latency = probe.latencyFrames
                } else {
                    latency = slot.lastKnownLatencyFrames ?? 0
                }
                plans.append(bypassPlan(
                    slot: slot,
                    component: component,
                    latency: latency,
                    reason: "User bypass"
                ))
                totalLatency = try addFrames(
                    totalLatency,
                    latency,
                    limit: Int(format.sampleRate * AudioUnitProbeResult.maximumLatencySeconds)
                )
                requiresBypass = true
                continue
            }

            guard let probe else {
                throw AudioUnitRackError.probeRequired(
                    slotID: slot.id,
                    component: component
                )
            }
            try probe.validate(for: slotFormat)
            let latency = probe.latencyFrames
            let tail = probe.tailFrames
            totalLatency = try addFrames(
                totalLatency,
                latency,
                limit: Int(format.sampleRate * AudioUnitProbeResult.maximumLatencySeconds)
            )
            totalTail = try addFrames(
                totalTail,
                tail,
                limit: Int(format.sampleRate * AudioUnitProbeResult.maximumTailSeconds)
            )
            plans.append(AudioUnitRackSlotExecutionPlan(
                slotID: slot.id,
                component: component,
                mode: .process,
                latencyFrames: latency,
                tailFrames: tail,
                wetDryMix: slot.wetDryMix,
                dryCompensationFrames: slot.wetDryMix < 1.0 ? latency : 0,
                reason: nil
            ))
        }

        return AudioUnitRackExecutionPlan(
            format: format,
            slots: plans,
            totalLatencyFrames: totalLatency,
            totalTailFrames: totalTail,
            requiresLatencyMatchedBypass: requiresBypass
        )
    }

    private func bypassLatency(
        slot: AudioUnitRackSlotState,
        probe: AudioUnitProbeResult?,
        format: AudioUnitRackProcessingFormat,
        reason: String
    ) throws -> Int {
        if let probe {
            try probe.validate(for: format)
            return probe.latencyFrames
        }
        if let latency = slot.lastKnownLatencyFrames {
            return latency
        }
        throw AudioUnitRackError.missingBypassLatency(
            slotID: slot.id,
            reason: reason
        )
    }

    private func bypassPlan(
        slot: AudioUnitRackSlotState,
        component: AudioUnitComponentIdentity,
        latency: Int,
        reason: String
    ) -> AudioUnitRackSlotExecutionPlan {
        AudioUnitRackSlotExecutionPlan(
            slotID: slot.id,
            component: component,
            mode: .latencyMatchedBypass,
            latencyFrames: latency,
            tailFrames: 0,
            wetDryMix: 0,
            dryCompensationFrames: latency,
            reason: reason
        )
    }

    private func addFrames(
        _ lhs: Int,
        _ rhs: Int,
        limit: Int
    ) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum <= limit else {
            throw AudioUnitRackError.aggregateLatencyOrTailTooLarge
        }
        return sum
    }
}

enum AudioUnitRackError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case invalidChannelCount(Int)
    case invalidMaximumFramesPerSlice(Int)
    case invalidSlotCount(Int)
    case duplicateSlotIdentifier
    case invalidWetDryMix(slotID: UUID, value: Double)
    case orphanedSlotState(UUID)
    case slotStateTooLarge(slotID: UUID, bytes: Int)
    case rackStateTooLarge(Int)
    case invalidStoredLatency(slotID: UUID, frames: Int)
    case invalidStoredTail(slotID: UUID, frames: Int)
    case probeFormatMismatch(AudioUnitComponentIdentity)
    case insufficientMaximumFrames(
        component: AudioUnitComponentIdentity,
        available: Int,
        required: Int
    )
    case invalidProbeLatency(
        component: AudioUnitComponentIdentity,
        seconds: Double
    )
    case invalidProbeTail(
        component: AudioUnitComponentIdentity,
        seconds: Double
    )
    case probeRequired(
        slotID: UUID,
        component: AudioUnitComponentIdentity
    )
    case missingBypassLatency(slotID: UUID, reason: String)
    case aggregateLatencyOrTailTooLarge
    case slotIndexOutOfRange(Int)
    case componentNotDiscovered(AudioUnitComponentIdentity)
    case componentNotPrepared(AudioUnitComponentIdentity)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let value):
            return "Audio Unit rack sample rate \(value) Hz is invalid."
        case .invalidChannelCount(let count):
            return "Audio Unit rack channel count \(count) is unsupported."
        case .invalidMaximumFramesPerSlice(let frames):
            return "Audio Unit maximum frame request \(frames) is invalid."
        case .invalidSlotCount(let count):
            return "Audio Unit rack requires 1–\(AudioUnitRackConfiguration.maximumSlotCount) slots; found \(count)."
        case .duplicateSlotIdentifier:
            return "Audio Unit rack contains duplicate slot identifiers."
        case .invalidWetDryMix(_, let value):
            return "Audio Unit wet/dry value \(value) is outside 0…1."
        case .orphanedSlotState:
            return "An empty Audio Unit slot contains plug-in state."
        case .slotStateTooLarge(_, let bytes):
            return "Audio Unit state blob is too large (\(bytes) bytes)."
        case .rackStateTooLarge(let bytes):
            return "Audio Unit rack state is too large (\(bytes) bytes)."
        case .invalidStoredLatency(_, let frames):
            return "Audio Unit stored latency \(frames) frames is invalid."
        case .invalidStoredTail(_, let frames):
            return "Audio Unit stored tail \(frames) frames is invalid."
        case .probeFormatMismatch(let component):
            return "Audio Unit \(component.fourCCSummary) probe format does not match the rack."
        case .insufficientMaximumFrames(_, let available, let required):
            return "Audio Unit can render at most \(available) frames, below the required \(required)."
        case .invalidProbeLatency(_, let seconds):
            return "Audio Unit reported invalid latency \(seconds) seconds."
        case .invalidProbeTail(_, let seconds):
            return "Audio Unit reported invalid tail time \(seconds) seconds."
        case .probeRequired:
            return "Audio Unit must pass an off-realtime probe before it can enter a live rack plan."
        case .missingBypassLatency(_, let reason):
            return "Audio Unit cannot fail safely because no latency-matched bypass value is known. \(reason)"
        case .aggregateLatencyOrTailTooLarge:
            return "Audio Unit rack aggregate latency or tail exceeds the bounded host policy."
        case .slotIndexOutOfRange(let index):
            return "Audio Unit rack slot index \(index) is out of range."
        case .componentNotDiscovered(let component):
            return "Audio Unit \(component.fourCCSummary) is not in the current component catalog."
        case .componentNotPrepared(let component):
            return "Audio Unit \(component.fourCCSummary) has not passed the off-realtime preparation probe."
        }
    }
}
