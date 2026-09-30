import Foundation

struct AudioRouteConfiguration: Equatable, Sendable {
    var selectedOutputUID: String?

    init(selectedOutputUID: String? = nil) {
        self.selectedOutputUID = selectedOutputUID
    }
}

enum AudioRouteSelectionError: Error, Equatable, Sendable, LocalizedError {
    case outputDeviceUnavailable(uid: String)

    var errorDescription: String? {
        switch self {
        case .outputDeviceUnavailable(let uid):
            return "The selected output device is not currently available: \(uid)"
        }
    }
}

// MARK: - PR41 Multi-output speaker routing

/// A logical speaker/crossover signal. The program remains stereo; these buses
/// describe how that stereo program is derived for physical speaker outputs.
enum SpeakerOutputBus: String, CaseIterable, Identifiable, Codable, Sendable {
    case leftFullRange
    case rightFullRange
    case leftLow
    case rightLow
    case leftMid
    case rightMid
    case leftHigh
    case rightHigh
    case subMono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftFullRange: return "Left Full Range"
        case .rightFullRange: return "Right Full Range"
        case .leftLow: return "Left Low"
        case .rightLow: return "Right Low"
        case .leftMid: return "Left Mid"
        case .rightMid: return "Right Mid"
        case .leftHigh: return "Left High"
        case .rightHigh: return "Right High"
        case .subMono: return "Sub Mono"
        }
    }
}

struct PhysicalOutputEndpoint: Codable, Equatable, Hashable, Sendable {
    /// Stable Core Audio device UID. Device IDs are intentionally not persisted.
    var deviceUID: String
    /// Zero-based physical output channel index on the target device.
    var channelIndex: UInt32
}

struct SpeakerOutputRoute: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var bus: SpeakerOutputBus
    var destination: PhysicalOutputEndpoint
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        bus: SpeakerOutputBus,
        destination: PhysicalOutputEndpoint,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.bus = bus
        self.destination = destination
        self.enabled = enabled
    }
}

enum MultiOutputSynchronizationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case aggregateDevice
    case softwarePLL

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .aggregateDevice: return "Aggregate Device"
        case .softwarePLL: return "Software PLL"
        }
    }
}

enum MultiOutputRoutingError: Error, Equatable, LocalizedError {
    case tooManyRoutes(Int)
    case insufficientEnabledRoutes(Int)
    case duplicateRouteID(UUID)
    case emptyDeviceUID(routeID: UUID)
    case duplicateDestination(deviceUID: String, channelIndex: UInt32)
    case referenceDeviceNotRouted(String)
    case outputDeviceUnavailable(String)
    case outputChannelUnavailable(deviceUID: String, channelIndex: UInt32, channelCount: UInt32)
    case invalidSampleRate(Double)
    case sampleRateUnsupported(deviceUID: String, sampleRate: Double)
    case sameDeviceTransportRequiresEnabledRouting
    case sameDeviceTransportRequiresSingleDevice([String])

    var errorDescription: String? {
        switch self {
        case .tooManyRoutes(let count):
            return "Multi-output routing supports at most 8 physical output routes; configuration contains \(count)."
        case .insufficientEnabledRoutes(let count):
            return "Enable at least 2 physical output routes before activating multi-output routing; \(count) are enabled."
        case .duplicateRouteID(let id):
            return "Multi-output routing contains duplicate route identifier \(id.uuidString)."
        case .emptyDeviceUID(let routeID):
            return "Output route \(routeID.uuidString) does not identify a physical output device."
        case .duplicateDestination(let deviceUID, let channelIndex):
            return "Physical output \(deviceUID) channel \(channelIndex + 1) is assigned more than once."
        case .referenceDeviceNotRouted(let uid):
            return "Synchronization reference device \(uid) is not used by an enabled output route."
        case .outputDeviceUnavailable(let uid):
            return "A routed output device is not currently available: \(uid)."
        case .outputChannelUnavailable(let uid, let channelIndex, let channelCount):
            return "Output device \(uid) has \(channelCount) channels; channel \(channelIndex + 1) cannot be routed."
        case .invalidSampleRate(let sampleRate):
            return "Multi-output routing sample rate \(sampleRate) Hz is invalid."
        case .sampleRateUnsupported(let uid, let sampleRate):
            return "Output device \(uid) does not support \(sampleRate) Hz natively."
        case .sameDeviceTransportRequiresEnabledRouting:
            return "Enable multi-output routing before compiling a same-device output plan."
        case .sameDeviceTransportRequiresSingleDevice(let uids):
            return "Same-device transport requires every enabled route to target one physical device; found: \(uids.joined(separator: ", "))."
        }
    }
}

/// Persistent routing intent owned by a Playback System. This is a control-plane
/// contract only: a configuration is not considered live until the transport
/// layer has successfully realized every enabled route.
struct MultiOutputRoutingConfiguration: Codable, Equatable, Sendable {
    static let maximumRouteCount = 8
    static let minimumEnabledRouteCount = 2

    var enabled: Bool
    var routes: [SpeakerOutputRoute]
    var synchronizationMode: MultiOutputSynchronizationMode
    /// Stable device UID used as clock/reference leader when the chosen transport
    /// strategy requires one. Nil lets the transport choose the first enabled
    /// route's device deterministically.
    var referenceDeviceUID: String?

    init(
        enabled: Bool = false,
        routes: [SpeakerOutputRoute] = [],
        synchronizationMode: MultiOutputSynchronizationMode = .automatic,
        referenceDeviceUID: String? = nil
    ) {
        self.enabled = enabled
        self.routes = routes
        self.synchronizationMode = synchronizationMode
        self.referenceDeviceUID = referenceDeviceUID
    }

    var enabledRoutes: [SpeakerOutputRoute] { routes.filter(\.enabled) }

    var requiredDeviceUIDs: Set<String> {
        Set(enabledRoutes.map { $0.destination.deviceUID })
    }

    var usesMultiplePhysicalDevices: Bool { requiredDeviceUIDs.count > 1 }

    var resolvedReferenceDeviceUID: String? {
        if let referenceDeviceUID { return referenceDeviceUID }
        return enabledRoutes.first?.destination.deviceUID
    }

    func validateStructure() throws {
        guard routes.count <= Self.maximumRouteCount else {
            throw MultiOutputRoutingError.tooManyRoutes(routes.count)
        }

        var routeIDs = Set<UUID>()
        var destinations = Set<PhysicalOutputEndpoint>()
        for route in routes {
            guard routeIDs.insert(route.id).inserted else {
                throw MultiOutputRoutingError.duplicateRouteID(route.id)
            }
            guard !route.destination.deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MultiOutputRoutingError.emptyDeviceUID(routeID: route.id)
            }
            guard destinations.insert(route.destination).inserted else {
                throw MultiOutputRoutingError.duplicateDestination(
                    deviceUID: route.destination.deviceUID,
                    channelIndex: route.destination.channelIndex
                )
            }
        }

        let active = enabledRoutes
        if enabled, active.count < Self.minimumEnabledRouteCount {
            throw MultiOutputRoutingError.insufficientEnabledRoutes(active.count)
        }
        if let referenceDeviceUID,
           enabled,
           !Set(active.map { $0.destination.deviceUID }).contains(referenceDeviceUID) {
            throw MultiOutputRoutingError.referenceDeviceNotRouted(referenceDeviceUID)
        }
    }

    /// Runtime-capability validation. Persisted systems may remain saved while a
    /// device is disconnected; this stricter validation is for activation only.
    func validate(
        availableDevices: [AudioOutputDevice],
        sampleRate: Double? = nil
    ) throws {
        try validateStructure()
        guard enabled else { return }
        if let sampleRate {
            guard sampleRate.isFinite, sampleRate > 0 else {
                throw MultiOutputRoutingError.invalidSampleRate(sampleRate)
            }
        }

        for route in enabledRoutes {
            guard let device = availableDevices.first(where: { $0.uid == route.destination.deviceUID }) else {
                throw MultiOutputRoutingError.outputDeviceUnavailable(route.destination.deviceUID)
            }
            guard route.destination.channelIndex < device.outputChannelCount else {
                throw MultiOutputRoutingError.outputChannelUnavailable(
                    deviceUID: device.uid,
                    channelIndex: route.destination.channelIndex,
                    channelCount: device.outputChannelCount
                )
            }
            if let sampleRate, !device.supports(sampleRate: sampleRate) {
                throw MultiOutputRoutingError.sampleRateUnsupported(
                    deviceUID: device.uid,
                    sampleRate: sampleRate
                )
            }
        }
    }
}

/// Immutable control-plane result for Slice C2. Every route targets one Core
/// Audio device, so all physical channels share one hardware clock and no SRC or
/// PLL is required. This does not activate the device; CoreAudioTransportSession
/// owns activation in the following transport slice.
struct SameDeviceOutputRoutePlan: Equatable, Sendable {
    let deviceUID: String
    let physicalChannelCount: UInt32
    let routes: [SpeakerOutputRoute]

    var requiredPhysicalChannelCount: UInt32 {
        guard let highest = routes.map(\.destination.channelIndex).max() else { return 0 }
        return highest + 1
    }
}

extension MultiOutputRoutingConfiguration {
    func makeSameDevicePlan(
        availableDevices: [AudioOutputDevice],
        sampleRate: Double
    ) throws -> SameDeviceOutputRoutePlan {
        guard enabled else {
            throw MultiOutputRoutingError.sameDeviceTransportRequiresEnabledRouting
        }
        try validate(availableDevices: availableDevices, sampleRate: sampleRate)

        let deviceUIDs = requiredDeviceUIDs.sorted()
        guard deviceUIDs.count == 1, let deviceUID = deviceUIDs.first else {
            throw MultiOutputRoutingError.sameDeviceTransportRequiresSingleDevice(deviceUIDs)
        }
        guard let device = availableDevices.first(where: { $0.uid == deviceUID }) else {
            throw MultiOutputRoutingError.outputDeviceUnavailable(deviceUID)
        }

        return SameDeviceOutputRoutePlan(
            deviceUID: deviceUID,
            physicalChannelCount: device.outputChannelCount,
            routes: enabledRoutes
        )
    }
}

