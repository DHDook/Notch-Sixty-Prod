from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# 1. Channel-aware output-device metadata.
device_path = Path("NotchSixty/Audio/Devices/AudioOutputDevice.swift")
device = device_path.read_text()
device = replace_once(
    device,
    '''struct AudioOutputDevice: Identifiable, Equatable, Sendable {\n    typealias ID = String\n\n    let deviceID: AudioDeviceID\n    let uid: String\n    let name: String\n    let nominalSampleRate: Double\n    let availableSampleRateRanges: [AudioSampleRateRange]\n\n    var id: String { uid }\n''',
    '''struct AudioOutputDevice: Identifiable, Equatable, Sendable {\n    typealias ID = String\n\n    let deviceID: AudioDeviceID\n    let uid: String\n    let name: String\n    let nominalSampleRate: Double\n    let availableSampleRateRanges: [AudioSampleRateRange]\n    let outputChannelCount: UInt32\n\n    init(\n        deviceID: AudioDeviceID,\n        uid: String,\n        name: String,\n        nominalSampleRate: Double,\n        availableSampleRateRanges: [AudioSampleRateRange],\n        outputChannelCount: UInt32 = 2\n    ) {\n        self.deviceID = deviceID\n        self.uid = uid\n        self.name = name\n        self.nominalSampleRate = nominalSampleRate\n        self.availableSampleRateRanges = availableSampleRateRanges\n        self.outputChannelCount = outputChannelCount\n    }\n\n    var id: String { uid }\n''',
    "AudioOutputDevice channel metadata",
)
device_path.write_text(device)


# 2. Core Audio catalog discovers physical output-channel capacity.
core_path = Path("NotchSixty/Audio/CoreAudio/CoreAudioError.swift")
core = core_path.read_text()
core = replace_once(
    core,
    '''    case readOutputStreams\n    case readDeviceUID\n''',
    '''    case readOutputStreams\n    case readOutputChannelCount\n    case readDeviceUID\n''',
    "CoreAudioOperation channel-count case",
)
core_path.write_text(core)

catalog_path = Path("NotchSixty/Audio/Devices/OutputDeviceCatalog.swift")
catalog = catalog_path.read_text()
catalog = replace_once(
    catalog,
    '''            nominalSampleRate: try readNominalSampleRate(deviceID: deviceID),\n            availableSampleRateRanges: try readAvailableSampleRateRanges(deviceID: deviceID)\n        )\n''',
    '''            nominalSampleRate: try readNominalSampleRate(deviceID: deviceID),\n            availableSampleRateRanges: try readAvailableSampleRateRanges(deviceID: deviceID),\n            outputChannelCount: try readOutputChannelCount(deviceID: deviceID)\n        )\n''',
    "Output device channel count construction",
)
insert_before = '''    static func readNominalSampleRate(deviceID: AudioDeviceID) throws -> Double {\n'''
channel_reader = '''    static func readOutputChannelCount(deviceID: AudioDeviceID) throws -> UInt32 {\n        var address = AudioObjectPropertyAddress(\n            mSelector: kAudioDevicePropertyStreamConfiguration,\n            mScope: kAudioObjectPropertyScopeOutput,\n            mElement: kAudioObjectPropertyElementMain\n        )\n        var dataSize: UInt32 = 0\n        try check(\n            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),\n            operation: .readOutputChannelCount,\n            objectID: deviceID\n        )\n        guard dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }\n\n        let storage = UnsafeMutableRawPointer.allocate(\n            byteCount: Int(dataSize),\n            alignment: MemoryLayout<AudioBufferList>.alignment\n        )\n        defer { storage.deallocate() }\n        try check(\n            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, storage),\n            operation: .readOutputChannelCount,\n            objectID: deviceID\n        )\n        let list = storage.assumingMemoryBound(to: AudioBufferList.self)\n        return UnsafeMutableAudioBufferListPointer(list).reduce(UInt32(0)) { partial, buffer in\n            partial + buffer.mNumberChannels\n        }\n    }\n\n'''
catalog = replace_once(catalog, insert_before, channel_reader + insert_before, "Output channel-count reader")
catalog_path.write_text(catalog)


# 3. Proprietary logical-bus -> physical-endpoint routing contract.
route_path = Path("NotchSixty/Audio/Routing/AudioRouteConfiguration.swift")
route_path.write_text(r'''import Foundation

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
''')


# 4. Playback System persistence. Optional storage preserves schema-v1 archives
# that predate PR41 routing; nil means legacy single-output routing.
profiles_path = Path("NotchSixty/State/ProductProfiles.swift")
profiles = profiles_path.read_text()
profiles = replace_once(
    profiles,
    '''    var roomCorrectionCalibration: RoomCorrectionCalibrationSummary?\n    var speakerIR: SpeakerIRConfiguration\n''',
    '''    var roomCorrectionCalibration: RoomCorrectionCalibrationSummary?\n    var outputRouting: MultiOutputRoutingConfiguration?\n    var speakerIR: SpeakerIRConfiguration\n''',
    "PlaybackSystemState routing field",
)
profiles = replace_once(
    profiles,
    '''        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration(),\n        roomCorrectionCalibration: RoomCorrectionCalibrationSummary? = nil,\n        speakerIR: SpeakerIRConfiguration = SpeakerIRConfiguration()\n''',
    '''        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration(),\n        roomCorrectionCalibration: RoomCorrectionCalibrationSummary? = nil,\n        outputRouting: MultiOutputRoutingConfiguration? = nil,\n        speakerIR: SpeakerIRConfiguration = SpeakerIRConfiguration()\n''',
    "PlaybackSystemState routing init parameter",
)
profiles = replace_once(
    profiles,
    '''        self.roomCorrection = roomCorrection\n        self.roomCorrectionCalibration = roomCorrectionCalibration\n        self.speakerIR = speakerIR\n''',
    '''        self.roomCorrection = roomCorrection\n        self.roomCorrectionCalibration = roomCorrectionCalibration\n        self.outputRouting = outputRouting\n        self.speakerIR = speakerIR\n''',
    "PlaybackSystemState routing assignment",
)
profiles = replace_once(
    profiles,
    '''    var selectedSystemProfileName: String { selectedSystemProfile?.name ?? "System" }\n    var canOverwriteSelectedContentPreset: Bool { selectedContentPreset?.origin == .user }\n''',
    '''    var selectedSystemProfileName: String { selectedSystemProfile?.name ?? "System" }\n    var selectedSystemOutputRouting: MultiOutputRoutingConfiguration {\n        selectedSystemProfile?.state.outputRouting ?? MultiOutputRoutingConfiguration()\n    }\n    var canOverwriteSelectedContentPreset: Bool { selectedContentPreset?.origin == .user }\n''',
    "Selected-system routing accessor",
)
anchor = '''    func replaceSelectedSystemBassManagement(\n        _ configuration: BassManagementConfiguration\n    ) throws {\n'''
routing_method = '''    func replaceSelectedSystemOutputRouting(\n        _ configuration: MultiOutputRoutingConfiguration?\n    ) throws {\n        guard let selectedSystemProfileID,\n              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {\n            throw ProductProfileError.selectedSystemProfileRequired\n        }\n        if let configuration {\n            try configuration.validateStructure()\n        }\n\n        let previousState = systemProfiles[index].state\n        do {\n            systemProfiles[index].state.outputRouting = configuration\n            try persistThrowing()\n            lastErrorDescription = nil\n        } catch {\n            systemProfiles[index].state = previousState\n            lastErrorDescription = error.localizedDescription\n            throw error\n        }\n    }\n\n'''
profiles = replace_once(profiles, anchor, routing_method + anchor, "Playback-system routing transaction")
profiles = replace_once(
    profiles,
    '''            roomCorrection: engine.roomCorrectionConfiguration,\n            roomCorrectionCalibration: selectedSystemProfile?.state.roomCorrectionCalibration,\n            speakerIR: engine.speakerIRConfiguration\n''',
    '''            roomCorrection: engine.roomCorrectionConfiguration,\n            roomCorrectionCalibration: selectedSystemProfile?.state.roomCorrectionCalibration,\n            outputRouting: selectedSystemProfile?.state.outputRouting,\n            speakerIR: engine.speakerIRConfiguration\n''',
    "captureSystemState routing preservation",
)
profiles_path.write_text(profiles)


# 5. Deterministic model/profile tests live in an existing test source so this
# slice does not touch the Xcode project file.
tests_path = Path("NotchSixtyTests/RoomCorrectionProjectControllerTests.swift")
tests = tests_path.read_text()
if not tests.endswith("\n}\n"):
    raise SystemExit("Unexpected RoomCorrectionProjectControllerTests.swift ending")
addition = r'''
    func testMultiOutputRoutingSeparatesLogicalBusFromPhysicalDestination() throws {
        let sharedSubBus = SpeakerOutputBus.subMono
        let routes = [
            SpeakerOutputRoute(
                name: "Left Main",
                bus: .leftFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: "dac-a", channelIndex: 0)
            ),
            SpeakerOutputRoute(
                name: "Right Main",
                bus: .rightFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: "dac-a", channelIndex: 1)
            ),
            SpeakerOutputRoute(
                name: "Sub A",
                bus: sharedSubBus,
                destination: PhysicalOutputEndpoint(deviceUID: "dac-b", channelIndex: 0)
            ),
            SpeakerOutputRoute(
                name: "Sub B",
                bus: sharedSubBus,
                destination: PhysicalOutputEndpoint(deviceUID: "dac-b", channelIndex: 1)
            ),
        ]
        let configuration = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: routes,
            synchronizationMode: .automatic,
            referenceDeviceUID: "dac-a"
        )

        XCTAssertNoThrow(try configuration.validateStructure())
        XCTAssertTrue(configuration.usesMultiplePhysicalDevices)
        XCTAssertEqual(configuration.requiredDeviceUIDs, Set(["dac-a", "dac-b"]))
        XCTAssertEqual(configuration.resolvedReferenceDeviceUID, "dac-a")
        XCTAssertEqual(configuration.enabledRoutes.filter { $0.bus == .subMono }.count, 2,
                       "One logical bus may intentionally feed multiple physical destinations")

        var duplicate = configuration
        duplicate.routes[3].destination = duplicate.routes[2].destination
        XCTAssertThrowsError(try duplicate.validateStructure()) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .duplicateDestination(deviceUID: "dac-b", channelIndex: 0)
            )
        }
    }

    func testMultiOutputRoutingValidatesPhysicalCapacityAndNativeRate() throws {
        let deviceA = AudioOutputDevice(
            deviceID: 101,
            uid: "dac-a",
            name: "Four Channel DAC",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 192_000)],
            outputChannelCount: 4
        )
        let deviceB = AudioOutputDevice(
            deviceID: 202,
            uid: "dac-b",
            name: "Stereo DAC",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 2
        )
        var configuration = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac-a", channelIndex: 2)
                ),
                SpeakerOutputRoute(
                    name: "Right",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac-a", channelIndex: 3)
                ),
                SpeakerOutputRoute(
                    name: "Sub",
                    bus: .subMono,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac-b", channelIndex: 0)
                ),
            ],
            synchronizationMode: .aggregateDevice,
            referenceDeviceUID: "dac-a"
        )

        XCTAssertNoThrow(try configuration.validate(availableDevices: [deviceA, deviceB], sampleRate: 96_000))

        configuration.routes[2].destination.channelIndex = 2
        XCTAssertThrowsError(try configuration.validate(availableDevices: [deviceA, deviceB], sampleRate: 96_000)) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .outputChannelUnavailable(deviceUID: "dac-b", channelIndex: 2, channelCount: 2)
            )
        }

        configuration.routes[2].destination.channelIndex = 0
        XCTAssertThrowsError(try configuration.validate(availableDevices: [deviceA, deviceB], sampleRate: 192_000)) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .sampleRateUnsupported(deviceUID: "dac-b", sampleRate: 192_000)
            )
        }
    }

    func testPlaybackSystemPersistsMultiOutputRoutingWithoutMutatingDSPOrLegacySelectedOutput() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profiles = fixture.profiles
        let beforeContent = profiles.captureContentState()
        let beforeBass = profiles.engine.bassManagementConfiguration
        let beforeRoom = profiles.engine.roomCorrectionConfiguration
        let beforeSelectedOutput = profiles.engine.routeConfiguration.selectedOutputUID

        let routing = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left Main",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "main-dac", channelIndex: 0)
                ),
                SpeakerOutputRoute(
                    name: "Right Main",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "main-dac", channelIndex: 1)
                ),
                SpeakerOutputRoute(
                    name: "Subwoofer",
                    bus: .subMono,
                    destination: PhysicalOutputEndpoint(deviceUID: "sub-dac", channelIndex: 0)
                ),
            ],
            synchronizationMode: .softwarePLL,
            referenceDeviceUID: "main-dac"
        )

        try profiles.replaceSelectedSystemOutputRouting(routing)
        XCTAssertEqual(profiles.selectedSystemProfile?.state.outputRouting, routing)
        XCTAssertEqual(profiles.selectedSystemOutputRouting, routing)
        XCTAssertEqual(profiles.engine.routeConfiguration.selectedOutputUID, beforeSelectedOutput,
                       "C1 stores routing intent only; transport activation comes in the next slice")
        XCTAssertEqual(profiles.engine.bassManagementConfiguration, beforeBass)
        XCTAssertEqual(profiles.engine.roomCorrectionConfiguration, beforeRoom)
        XCTAssertEqual(profiles.captureContentState(), beforeContent)

        let restoredEngine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let restoredProfiles = ProductProfileController(
            engine: restoredEngine,
            storageURL: fixture.root.appendingPathComponent("profiles-v1.json")
        )
        XCTAssertEqual(restoredProfiles.selectedSystemProfile?.state.outputRouting, routing)
        XCTAssertEqual(restoredProfiles.selectedSystemOutputRouting, routing)
    }

    func testPlaybackSystemRoutingPersistenceFailureRollsBackProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-PR41-Routing-Rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageDirectory = root.appendingPathComponent("profiles", isDirectory: true)
        let storageURL = storageDirectory.appendingPathComponent("profiles-v1.json")
        let engine = AudioIOEngine(deviceCatalog: OutputCatalogFixture())
        let profiles = ProductProfileController(engine: engine, storageURL: storageURL)
        let beforeProfile = try XCTUnwrap(profiles.selectedSystemProfile).state

        try FileManager.default.removeItem(at: storageDirectory)
        try Data("not-a-directory".utf8).write(to: storageDirectory)

        let routing = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 0)
                ),
                SpeakerOutputRoute(
                    name: "Right",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 1)
                ),
            ]
        )

        XCTAssertThrowsError(try profiles.replaceSelectedSystemOutputRouting(routing))
        XCTAssertEqual(profiles.selectedSystemProfile?.state, beforeProfile)
    }
'''
tests = tests[:-3] + "\n" + addition + "}\n"
tests_path.write_text(tests)

print("PR41 Slice C1 multi-output routing model applied")
