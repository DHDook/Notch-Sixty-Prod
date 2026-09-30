from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# 1. Routing contract: compile multiple physical devices into one deterministic
# aggregate-device channel domain. The HAL owns clock synchronization/drift.
route_path = Path("NotchSixty/Audio/Routing/AudioRouteConfiguration.swift")
route = route_path.read_text()
route = replace_once(
    route,
    '''    case routingChangeRequiresIdle\n''',
    '''    case routingChangeRequiresIdle\n    case aggregateTransportRequiresMultipleDevices([String])\n    case aggregateReferenceOutputMismatch(selected: String, reference: String)\n    case aggregateChannelCountOverflow\n    case softwarePLLSuperseded\n''',
    "C3 routing error cases",
)
route = replace_once(
    route,
    '''        case .routingChangeRequiresIdle:\n            return "Stop processing before changing physical output routing."\n''',
    '''        case .routingChangeRequiresIdle:\n            return "Stop processing before changing physical output routing."\n        case .aggregateTransportRequiresMultipleDevices(let uids):\n            return "Aggregate-device transport requires at least two physical output devices; found: \\(uids.joined(separator: ", "))."\n        case .aggregateReferenceOutputMismatch(let selected, let reference):\n            return "The selected physical output \\(selected) must match the aggregate synchronization reference \\(reference)."\n        case .aggregateChannelCountOverflow:\n            return "Aggregate output channel count exceeds the supported Core Audio channel-index range."\n        case .softwarePLLSuperseded:\n            return "Software PLL mode is superseded by the Core Audio Aggregate Device clock domain with HAL drift compensation. Use Automatic or Aggregate Device synchronization."\n''',
    "C3 routing error descriptions",
)
append = r'''

struct AggregateMappedSpeakerOutputRoute: Equatable, Sendable {
    let route: SpeakerOutputRoute
    let aggregateChannelIndex: UInt32
}

/// Immutable control-plane plan for multiple hardware devices synchronized by a
/// private Core Audio Aggregate Device. Device order is significant because the
/// HAL concatenates aggregate streams in subdevice order.
struct AggregateDeviceOutputRoutePlan: Equatable, Sendable {
    let referenceDeviceUID: String
    let orderedDeviceUIDs: [String]
    let devices: [AudioOutputDevice]
    let physicalChannelCount: UInt32
    let mappedRoutes: [AggregateMappedSpeakerOutputRoute]

    var routes: [SpeakerOutputRoute] { mappedRoutes.map(\.route) }
}

extension MultiOutputRoutingConfiguration {
    func makeAggregateDevicePlan(
        availableDevices: [AudioOutputDevice],
        sampleRate: Double
    ) throws -> AggregateDeviceOutputRoutePlan {
        guard enabled else {
            throw MultiOutputRoutingError.sameDeviceTransportRequiresEnabledRouting
        }
        try validate(availableDevices: availableDevices, sampleRate: sampleRate)
        guard synchronizationMode != .softwarePLL else {
            throw MultiOutputRoutingError.softwarePLLSuperseded
        }

        var orderedDeviceUIDs: [String] = []
        let reference = resolvedReferenceDeviceUID ?? ""
        if !reference.isEmpty {
            orderedDeviceUIDs.append(reference)
        }
        for route in enabledRoutes {
            let uid = route.destination.deviceUID
            if !orderedDeviceUIDs.contains(uid) {
                orderedDeviceUIDs.append(uid)
            }
        }
        guard orderedDeviceUIDs.count > 1 else {
            throw MultiOutputRoutingError.aggregateTransportRequiresMultipleDevices(orderedDeviceUIDs)
        }

        let byUID = Dictionary(uniqueKeysWithValues: availableDevices.map { ($0.uid, $0) })
        var devices: [AudioOutputDevice] = []
        var offsets: [String: UInt32] = [:]
        var total: UInt64 = 0
        for uid in orderedDeviceUIDs {
            guard let device = byUID[uid] else {
                throw MultiOutputRoutingError.outputDeviceUnavailable(uid)
            }
            guard total <= UInt64(UInt32.max) else {
                throw MultiOutputRoutingError.aggregateChannelCountOverflow
            }
            offsets[uid] = UInt32(total)
            total += UInt64(device.outputChannelCount)
            guard total <= UInt64(UInt32.max) else {
                throw MultiOutputRoutingError.aggregateChannelCountOverflow
            }
            devices.append(device)
        }

        var mapped: [AggregateMappedSpeakerOutputRoute] = []
        mapped.reserveCapacity(enabledRoutes.count)
        for route in enabledRoutes {
            guard let offset = offsets[route.destination.deviceUID] else {
                throw MultiOutputRoutingError.outputDeviceUnavailable(route.destination.deviceUID)
            }
            let aggregateIndex64 = UInt64(offset) + UInt64(route.destination.channelIndex)
            guard aggregateIndex64 <= UInt64(UInt32.max) else {
                throw MultiOutputRoutingError.aggregateChannelCountOverflow
            }
            mapped.append(
                AggregateMappedSpeakerOutputRoute(
                    route: route,
                    aggregateChannelIndex: UInt32(aggregateIndex64)
                )
            )
        }

        return AggregateDeviceOutputRoutePlan(
            referenceDeviceUID: reference,
            orderedDeviceUIDs: orderedDeviceUIDs,
            devices: devices,
            physicalChannelCount: UInt32(total),
            mappedRoutes: mapped
        )
    }
}

extension AggregateDeviceOutputRoutePlan {
    func validateForC3LiveTransport(selectedOutputUID: String) throws {
        guard selectedOutputUID == referenceDeviceUID else {
            throw MultiOutputRoutingError.aggregateReferenceOutputMismatch(
                selected: selectedOutputUID,
                reference: referenceDeviceUID
            )
        }
        for mapped in mappedRoutes where !mapped.route.bus.isC2bLiveFullRangeBus {
            throw MultiOutputRoutingError.liveTransportBusUnavailable(mapped.route.bus)
        }
    }
}
'''
if "AggregateDeviceOutputRoutePlan" in route:
    raise SystemExit("C3 aggregate route plan already present")
route = route.rstrip() + append + "\n"
route_path.write_text(route)


# 2. CoreAudioTransportSession: one private Aggregate Device may now own both the
# system-audio tap and all physical output subdevices. HAL drift-compensates all
# non-reference subdevices. Existing no-routing/same-device behavior is unchanged.
core_path = Path("NotchSixty/Audio/CoreAudio/CoreAudioError.swift")
core = core_path.read_text()
core = replace_once(
    core,
    '''    case sameDeviceOutputMapCompilationFailed\n''',
    '''    case sameDeviceOutputMapCompilationFailed\n    case aggregateDeviceNotReady\n''',
    "C3 transport error case",
)
core = replace_once(
    core,
    '''        case .sameDeviceOutputMapCompilationFailed:\n            return "Unable to compile the validated same-device physical output map."\n''',
    '''        case .sameDeviceOutputMapCompilationFailed:\n            return "Unable to compile the validated physical output map."\n        case .aggregateDeviceNotReady:\n            return "Core Audio created the private multi-output aggregate device but it did not become ready for IO."\n''',
    "C3 transport error description",
)
core = replace_once(
    core,
    '''    let sameDeviceOutputPlan: SameDeviceOutputRoutePlan?\n''',
    '''    let sameDeviceOutputPlan: SameDeviceOutputRoutePlan?\n    let aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan?\n''',
    "C3 aggregate plan property",
)
core = replace_once(
    core,
    '''    private var outputIOProcID: AudioDeviceIOProcID?\n''',
    '''    private var outputIOProcID: AudioDeviceIOProcID?\n    private var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)\n''',
    "C3 output device ID storage",
)
core = replace_once(
    core,
    '''        selectedOutput: AudioOutputDevice,\n        sameDeviceOutputPlan: SameDeviceOutputRoutePlan? = nil\n    ) throws {\n        self.selectedOutput = selectedOutput\n        self.sameDeviceOutputPlan = sameDeviceOutputPlan\n''',
    '''        selectedOutput: AudioOutputDevice,\n        sameDeviceOutputPlan: SameDeviceOutputRoutePlan? = nil,\n        aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan? = nil\n    ) throws {\n        precondition(sameDeviceOutputPlan == nil || aggregateDeviceOutputPlan == nil)\n        self.selectedOutput = selectedOutput\n        self.sameDeviceOutputPlan = sameDeviceOutputPlan\n        self.aggregateDeviceOutputPlan = aggregateDeviceOutputPlan\n''',
    "C3 transport initializer signature",
)
core = replace_once(
    core,
    '''            if sameDeviceOutputPlan == nil {\n                guard outputFormat.isSupportedStereoTransportFormat else {\n                    throw CoreAudioTransportError.unsupportedFormat(role: "output", format: outputFormat)\n                }\n            } else {\n                guard outputFormat.isSupportedFloat32TransportFormat else {\n                    throw CoreAudioTransportError.unsupportedFormat(role: "multichannel output", format: outputFormat)\n                }\n            }\n''',
    '''            if sameDeviceOutputPlan == nil && aggregateDeviceOutputPlan == nil {\n                guard outputFormat.isSupportedStereoTransportFormat else {\n                    throw CoreAudioTransportError.unsupportedFormat(role: "output", format: outputFormat)\n                }\n            } else {\n                guard outputFormat.isSupportedFloat32TransportFormat else {\n                    throw CoreAudioTransportError.unsupportedFormat(role: "multichannel output reference", format: outputFormat)\n                }\n            }\n''',
    "C3 output format validation",
)
# Extend output map compilation to aggregate-flattened routes.
old_map = '''            if let sameDeviceOutputPlan {\n                try sameDeviceOutputPlan.validateForC2bLiveTransport(selectedOutputUID: selectedOutput.uid)\n                var descriptors = sameDeviceOutputPlan.routes.map { route -> N60SpeakerOutputRouteDescriptor in\n                    var descriptor = N60SpeakerOutputRouteDescriptor()\n                    descriptor.bus = route.bus.realtimeCType\n                    descriptor.physicalChannelIndex = route.destination.channelIndex\n                    return descriptor\n                }\n                var outputMap = N60SameDeviceOutputMap()\n                let compiled = descriptors.withUnsafeBufferPointer { buffer in\n                    N60SameDeviceOutputMapCompile(\n                        sameDeviceOutputPlan.physicalChannelCount,\n                        buffer.baseAddress!,\n                        UInt32(buffer.count),\n                        &outputMap\n                    )\n                }\n                guard compiled,\n                      N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(newBridge, outputMap) else {\n                    throw CoreAudioTransportError.sameDeviceOutputMapCompilationFailed\n                }\n            }\n'''
new_map = '''            if let sameDeviceOutputPlan {\n                try sameDeviceOutputPlan.validateForC2bLiveTransport(selectedOutputUID: selectedOutput.uid)\n                let descriptors = sameDeviceOutputPlan.routes.map { route -> N60SpeakerOutputRouteDescriptor in\n                    var descriptor = N60SpeakerOutputRouteDescriptor()\n                    descriptor.bus = route.bus.realtimeCType\n                    descriptor.physicalChannelIndex = route.destination.channelIndex\n                    return descriptor\n                }\n                try Self.configureOutputMap(\n                    bridge: newBridge,\n                    physicalChannelCount: sameDeviceOutputPlan.physicalChannelCount,\n                    descriptors: descriptors\n                )\n            } else if let aggregateDeviceOutputPlan {\n                try aggregateDeviceOutputPlan.validateForC3LiveTransport(selectedOutputUID: selectedOutput.uid)\n                let descriptors = aggregateDeviceOutputPlan.mappedRoutes.map { mapped -> N60SpeakerOutputRouteDescriptor in\n                    var descriptor = N60SpeakerOutputRouteDescriptor()\n                    descriptor.bus = mapped.route.bus.realtimeCType\n                    descriptor.physicalChannelIndex = mapped.aggregateChannelIndex\n                    return descriptor\n                }\n                try Self.configureOutputMap(\n                    bridge: newBridge,\n                    physicalChannelCount: aggregateDeviceOutputPlan.physicalChannelCount,\n                    descriptors: descriptors\n                )\n            }\n'''
core = replace_once(core, old_map, new_map, "C3 output map compiler")

# Replace tap-only aggregate composition with optional physical subdevices.
old_aggregate = '''            let tapEntry: [String: Any] = [\n                kAudioSubTapUIDKey: description.uuid.uuidString,\n                kAudioSubTapDriftCompensationKey: false,\n            ]\n            let aggregateDescription: [String: Any] = [\n                kAudioAggregateDeviceNameKey: "Notch Sixty Private Tap",\n                kAudioAggregateDeviceUIDKey: "com.dhdook.NotchSixty.tap.\\(UUID().uuidString)",\n                kAudioAggregateDeviceTapListKey: [tapEntry],\n                // The session owns capture lifecycle explicitly through its IOProc.\n                // Do not let the aggregate run the tap independently.\n                kAudioAggregateDeviceTapAutoStartKey: false,\n                kAudioAggregateDeviceIsPrivateKey: true,\n            ]\n            try Self.check(\n                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),\n                operation: "create private aggregate device"\n            )\n\n            // A tap-only aggregate otherwise chooses its own IO quantum. Pin it to\n'''
new_aggregate = '''            let tapEntry: [String: Any] = [\n                kAudioSubTapUIDKey: description.uuid.uuidString,\n                kAudioSubTapDriftCompensationKey: false,\n            ]\n            var aggregateDescription: [String: Any] = [\n                kAudioAggregateDeviceNameKey: aggregateDeviceOutputPlan == nil\n                    ? "Notch Sixty Private Tap"\n                    : "Notch Sixty Private Multi-Output",\n                kAudioAggregateDeviceUIDKey: "com.dhdook.NotchSixty.aggregate.\\(UUID().uuidString)",\n                kAudioAggregateDeviceTapListKey: [tapEntry],\n                // The session owns capture lifecycle explicitly through its IOProc.\n                // Do not let the aggregate run the tap independently.\n                kAudioAggregateDeviceTapAutoStartKey: false,\n                kAudioAggregateDeviceIsPrivateKey: true,\n            ]\n            if let aggregateDeviceOutputPlan {\n                let subdevices: [[String: Any]] = aggregateDeviceOutputPlan.orderedDeviceUIDs.map { uid in\n                    [\n                        kAudioSubDeviceUIDKey: uid,\n                        kAudioSubDeviceDriftCompensationKey: uid != aggregateDeviceOutputPlan.referenceDeviceUID,\n                    ]\n                }\n                aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = subdevices\n                aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = aggregateDeviceOutputPlan.referenceDeviceUID\n            }\n            try Self.check(\n                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),\n                operation: aggregateDeviceOutputPlan == nil\n                    ? "create private tap aggregate device"\n                    : "create private multi-output aggregate device"\n            )\n            if aggregateDeviceOutputPlan != nil {\n                try Self.waitForDeviceAlive(aggregateDeviceID)\n            }\n\n            // Pin the aggregate to the physical reference output's clock rate and\n'''
core = replace_once(core, old_aggregate, new_aggregate, "C3 aggregate composition")

# IOProc output target is either the selected physical device or the private aggregate.
old_ioprocs = '''            let clientData = UnsafeMutableRawPointer(newBridge)\n            try Self.check(\n                AudioDeviceCreateIOProcID(aggregateDeviceID, N60CaptureIOProc, clientData, &captureIOProcID),\n                operation: "create capture IOProc"\n            )\n            try Self.check(\n                AudioDeviceCreateIOProcID(selectedOutput.deviceID, N60OutputIOProc, clientData, &outputIOProcID),\n                operation: "create output IOProc"\n            )\n'''
new_ioprocs = '''            outputDeviceID = aggregateDeviceOutputPlan == nil ? selectedOutput.deviceID : aggregateDeviceID\n            let clientData = UnsafeMutableRawPointer(newBridge)\n            try Self.check(\n                AudioDeviceCreateIOProcID(aggregateDeviceID, N60CaptureIOProc, clientData, &captureIOProcID),\n                operation: "create capture IOProc"\n            )\n            try Self.check(\n                AudioDeviceCreateIOProcID(outputDeviceID, N60OutputIOProc, clientData, &outputIOProcID),\n                operation: "create output IOProc"\n            )\n'''
core = replace_once(core, old_ioprocs, new_ioprocs, "C3 IOProc output target")

# Stop/start/destroy must use the realized output object.
core = core.replace("AudioDeviceStop(selectedOutput.deviceID, outputIOProcID)", "AudioDeviceStop(outputDeviceID, outputIOProcID)")
core = core.replace("AudioDeviceDestroyIOProcID(selectedOutput.deviceID, outputIOProcID)", "AudioDeviceDestroyIOProcID(outputDeviceID, outputIOProcID)")
core = core.replace("AudioDeviceStart(selectedOutput.deviceID, outputIOProcID)", "AudioDeviceStart(outputDeviceID, outputIOProcID)")
if "AudioDeviceStart(selectedOutput.deviceID, outputIOProcID)" in core or "AudioDeviceStop(selectedOutput.deviceID, outputIOProcID)" in core:
    raise SystemExit("C3 output device lifecycle replacement incomplete")

# Static helpers before currentProcessObjectID.
helper_anchor = '''    private static func currentProcessObjectID() throws -> AudioObjectID {\n'''
helpers = r'''    private static func configureOutputMap(
        bridge: OpaquePointer,
        physicalChannelCount: UInt32,
        descriptors: [N60SpeakerOutputRouteDescriptor]
    ) throws {
        var outputMap = N60SameDeviceOutputMap()
        let compiled = descriptors.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return N60SameDeviceOutputMapCompile(
                physicalChannelCount,
                baseAddress,
                UInt32(buffer.count),
                &outputMap
            )
        }
        guard compiled,
              N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(bridge, outputMap) else {
            throw CoreAudioTransportError.sameDeviceOutputMapCompilationFailed
        }
    }

    private static func waitForDeviceAlive(_ deviceID: AudioDeviceID) throws {
        for _ in 0..<300 {
            let alive = try readUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceIsAlive,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read aggregate device readiness"
            )
            if alive != 0 { return }
            usleep(10_000)
        }
        throw CoreAudioTransportError.aggregateDeviceNotReady
    }

'''
core = replace_once(core, helper_anchor, helpers + helper_anchor, "C3 transport helpers")
core_path.write_text(core)


# 3. Engine chooses same-device vs aggregate-device realization while the source
# selected output remains the synchronization reference / volume-monitor device.
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
old_build = '''    private func buildTransport(output: AudioOutputDevice) throws {\n        let sameDeviceOutputPlan: SameDeviceOutputRoutePlan?\n        if let routing = multiOutputRoutingConfiguration, routing.enabled {\n            let plan = try routing.makeSameDevicePlan(\n                availableDevices: outputDevices,\n                sampleRate: output.nominalSampleRate\n            )\n            try plan.validateForC2bLiveTransport(selectedOutputUID: output.uid)\n            sameDeviceOutputPlan = plan\n        } else {\n            sameDeviceOutputPlan = nil\n        }\n        let session = try CoreAudioTransportSession(\n            selectedOutput: output,\n            sameDeviceOutputPlan: sameDeviceOutputPlan\n        )\n'''
new_build = '''    private func buildTransport(output: AudioOutputDevice) throws {\n        let sameDeviceOutputPlan: SameDeviceOutputRoutePlan?\n        let aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan?\n        if let routing = multiOutputRoutingConfiguration, routing.enabled {\n            if routing.usesMultiplePhysicalDevices {\n                let plan = try routing.makeAggregateDevicePlan(\n                    availableDevices: outputDevices,\n                    sampleRate: output.nominalSampleRate\n                )\n                try plan.validateForC3LiveTransport(selectedOutputUID: output.uid)\n                aggregateDeviceOutputPlan = plan\n                sameDeviceOutputPlan = nil\n            } else {\n                let plan = try routing.makeSameDevicePlan(\n                    availableDevices: outputDevices,\n                    sampleRate: output.nominalSampleRate\n                )\n                try plan.validateForC2bLiveTransport(selectedOutputUID: output.uid)\n                sameDeviceOutputPlan = plan\n                aggregateDeviceOutputPlan = nil\n            }\n        } else {\n            sameDeviceOutputPlan = nil\n            aggregateDeviceOutputPlan = nil\n        }\n        let session = try CoreAudioTransportSession(\n            selectedOutput: output,\n            sameDeviceOutputPlan: sameDeviceOutputPlan,\n            aggregateDeviceOutputPlan: aggregateDeviceOutputPlan\n        )\n'''
engine = replace_once(engine, old_build, new_build, "C3 engine transport selection")
engine_path.write_text(engine)


# 4. Focused deterministic tests: device ordering, flattened channel indices,
# sample-rate validation, software-PLL supersession and selected-reference guard.
tests_path = Path("NotchSixtyTests/RoomCorrectionProjectControllerTests.swift")
tests = tests_path.read_text()
if not tests.endswith("\n}\n"):
    raise SystemExit("Unexpected RoomCorrectionProjectControllerTests.swift ending")
tests_add = r'''
    func testAggregateDevicePlanFlattensPhysicalChannelsReferenceFirst() throws {
        let main = AudioOutputDevice(
            deviceID: 701,
            uid: "main-dac",
            name: "Main Four Channel",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 192_000)],
            outputChannelCount: 4
        )
        let aux = AudioOutputDevice(
            deviceID: 702,
            uid: "aux-dac",
            name: "Aux Stereo",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 2
        )
        let third = AudioOutputDevice(
            deviceID: 703,
            uid: "third-dac",
            name: "Third Stereo",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 2
        )
        let configuration = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Aux Left",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: aux.uid, channelIndex: 1)
                ),
                SpeakerOutputRoute(
                    name: "Main Left",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: main.uid, channelIndex: 2)
                ),
                SpeakerOutputRoute(
                    name: "Third Right",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: third.uid, channelIndex: 0)
                ),
                SpeakerOutputRoute(
                    name: "Main Right",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: main.uid, channelIndex: 3)
                ),
            ],
            synchronizationMode: .aggregateDevice,
            referenceDeviceUID: main.uid
        )

        let plan = try configuration.makeAggregateDevicePlan(
            availableDevices: [aux, third, main],
            sampleRate: 96_000
        )
        XCTAssertEqual(plan.referenceDeviceUID, main.uid)
        XCTAssertEqual(plan.orderedDeviceUIDs, [main.uid, aux.uid, third.uid])
        XCTAssertEqual(plan.devices.map(\.uid), [main.uid, aux.uid, third.uid])
        XCTAssertEqual(plan.physicalChannelCount, 8)
        XCTAssertEqual(plan.mappedRoutes.map(\.aggregateChannelIndex), [5, 2, 6, 3])
        XCTAssertNoThrow(try plan.validateForC3LiveTransport(selectedOutputUID: main.uid))
        XCTAssertThrowsError(try plan.validateForC3LiveTransport(selectedOutputUID: aux.uid)) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .aggregateReferenceOutputMismatch(selected: aux.uid, reference: main.uid)
            )
        }
    }

    func testAggregateDevicePlanUsesFirstEnabledDeviceWhenReferenceIsAutomatic() throws {
        let first = AudioOutputDevice(
            deviceID: 711,
            uid: "first",
            name: "First",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 2
        )
        let second = AudioOutputDevice(
            deviceID: 712,
            uid: "second",
            name: "Second",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 2
        )
        let configuration = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Right Secondary",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: second.uid, channelIndex: 0)
                ),
                SpeakerOutputRoute(
                    name: "Left Primary",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: first.uid, channelIndex: 0)
                ),
            ],
            synchronizationMode: .automatic
        )
        let plan = try configuration.makeAggregateDevicePlan(
            availableDevices: [first, second],
            sampleRate: 48_000
        )
        XCTAssertEqual(plan.referenceDeviceUID, second.uid)
        XCTAssertEqual(plan.orderedDeviceUIDs, [second.uid, first.uid])
        XCTAssertEqual(plan.mappedRoutes.map(\.aggregateChannelIndex), [0, 2])
    }

    func testAggregateDevicePlanRejectsSoftwarePLLAndNonFullRangeLiveBus() throws {
        let first = AudioOutputDevice(
            deviceID: 721,
            uid: "first",
            name: "First",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 2
        )
        let second = AudioOutputDevice(
            deviceID: 722,
            uid: "second",
            name: "Second",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 2
        )
        let routes = [
            SpeakerOutputRoute(
                name: "Left",
                bus: .leftFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: first.uid, channelIndex: 0)
            ),
            SpeakerOutputRoute(
                name: "Sub",
                bus: .subMono,
                destination: PhysicalOutputEndpoint(deviceUID: second.uid, channelIndex: 0)
            ),
        ]
        let pll = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: routes,
            synchronizationMode: .softwarePLL,
            referenceDeviceUID: first.uid
        )
        XCTAssertThrowsError(
            try pll.makeAggregateDevicePlan(availableDevices: [first, second], sampleRate: 48_000)
        ) { error in
            XCTAssertEqual(error as? MultiOutputRoutingError, .softwarePLLSuperseded)
        }

        let aggregate = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: routes,
            synchronizationMode: .aggregateDevice,
            referenceDeviceUID: first.uid
        )
        let plan = try aggregate.makeAggregateDevicePlan(
            availableDevices: [first, second],
            sampleRate: 48_000
        )
        XCTAssertThrowsError(try plan.validateForC3LiveTransport(selectedOutputUID: first.uid)) { error in
            XCTAssertEqual(error as? MultiOutputRoutingError, .liveTransportBusUnavailable(.subMono))
        }
    }
'''
tests = tests[:-3] + "\n" + tests_add + "}\n"
tests_path.write_text(tests)

print("PR41 Slice C3 aggregate transport patch applied")
