from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# 1. Live-transport eligibility remains stricter than the persistent C1 model.
route_path = Path("NotchSixty/Audio/Routing/AudioRouteConfiguration.swift")
route = route_path.read_text()
route = replace_once(
    route,
    '''    case sameDeviceTransportRequiresSingleDevice([String])\n''',
    '''    case sameDeviceTransportRequiresSingleDevice([String])\n    case liveTransportOutputMismatch(selected: String, routed: String)\n    case liveTransportBusUnavailable(SpeakerOutputBus)\n    case routingChangeRequiresIdle\n''',
    "C2b routing error cases",
)
route = replace_once(
    route,
    '''        case .sameDeviceTransportRequiresSingleDevice(let uids):\n            return "Same-device transport requires every enabled route to target one physical device; found: \\(uids.joined(separator: ", "))."\n''',
    '''        case .sameDeviceTransportRequiresSingleDevice(let uids):\n            return "Same-device transport requires every enabled route to target one physical device; found: \\(uids.joined(separator: ", "))."\n        case .liveTransportOutputMismatch(let selected, let routed):\n            return "The selected physical output \\(selected) does not match the routed same-device output \\(routed)."\n        case .liveTransportBusUnavailable(let bus):\n            return "\\(bus.displayName) is not live-routable yet. C2b only routes the final post-DSP Left/Right Full Range buses."\n        case .routingChangeRequiresIdle:\n            return "Stop processing before changing physical output routing."\n''',
    "C2b routing error descriptions",
)
append = r'''

extension SpeakerOutputBus {
    var realtimeCType: N60SpeakerOutputBus {
        switch self {
        case .leftFullRange: return N60SpeakerOutputBusLeftFullRange
        case .rightFullRange: return N60SpeakerOutputBusRightFullRange
        case .leftLow: return N60SpeakerOutputBusLeftLow
        case .rightLow: return N60SpeakerOutputBusRightLow
        case .leftMid: return N60SpeakerOutputBusLeftMid
        case .rightMid: return N60SpeakerOutputBusRightMid
        case .leftHigh: return N60SpeakerOutputBusLeftHigh
        case .rightHigh: return N60SpeakerOutputBusRightHigh
        case .subMono: return N60SpeakerOutputBusSubMono
        }
    }

    var isC2bLiveFullRangeBus: Bool {
        self == .leftFullRange || self == .rightFullRange
    }
}

extension SameDeviceOutputRoutePlan {
    func validateForC2bLiveTransport(selectedOutputUID: String) throws {
        guard deviceUID == selectedOutputUID else {
            throw MultiOutputRoutingError.liveTransportOutputMismatch(
                selected: selectedOutputUID,
                routed: deviceUID
            )
        }
        for route in routes where !route.bus.isC2bLiveFullRangeBus {
            throw MultiOutputRoutingError.liveTransportBusUnavailable(route.bus)
        }
    }
}
'''
if "validateForC2bLiveTransport" in route:
    raise SystemExit("C2b live route validation already present")
route = route.rstrip() + append + "\n"
route_path.write_text(route)


# 2. Realtime bridge owns one immutable same-device map for the session.
header_path = Path("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h")
header = header_path.read_text()
header = replace_once(
    header,
    '''bool N60SameDeviceOutputMapValueForChannel(\n''',
    '''// Session setup operation. Configure only while physical output callbacks\n// are stopped; the realtime callback reads the copied fixed-size map directly.\nbool N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(\n    N60RealtimeAudioBridge * _Nonnull bridge,\n    N60SameDeviceOutputMap map\n);\n\nbool N60SameDeviceOutputMapValueForChannel(\n''',
    "bridge map configuration API",
)
header_path.write_text(header)

impl_path = Path("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c")
impl = impl_path.read_text()
impl = replace_once(
    impl,
    '''    N60RenderKernel *renderKernel;\n\n    _Atomic uint64_t writeIndex;\n''',
    '''    N60RenderKernel *renderKernel;\n    N60SameDeviceOutputMap sameDeviceOutputMap;\n\n    _Atomic uint64_t writeIndex;\n''',
    "bridge map storage",
)
map_api_anchor = '''bool N60SameDeviceOutputMapValueForChannel(\n'''
map_api = r'''bool N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(
    N60RealtimeAudioBridge *bridge,
    N60SameDeviceOutputMap map
) {
    if (bridge == NULL || !map.valid || map.routeCount < 2u
        || map.routeCount > N60_SPEAKER_OUTPUT_MAX_ROUTES
        || map.physicalChannelCount == 0) {
        return false;
    }
    bridge->sameDeviceOutputMap = map;
    return true;
}

'''
impl = replace_once(impl, map_api_anchor, map_api + map_api_anchor, "bridge map configuration implementation")

# General multichannel frame-count validation used only when the immutable map is live.
output_view_anchor = '''static bool make_output_buffer_view(\n'''
multichannel_helper = r'''static bool make_same_device_output_frame_count(
    const AudioBufferList *bufferList,
    uint32_t requiredPhysicalChannels,
    UInt32 *frameCountOut
) {
    if (bufferList == NULL || frameCountOut == NULL || bufferList->mNumberBuffers == 0
        || requiredPhysicalChannels == 0) return false;
    uint64_t flattenedChannels = 0;
    UInt32 frameCount = UINT32_MAX;
    for (UInt32 index = 0; index < bufferList->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &bufferList->mBuffers[index];
        if (buffer->mData == NULL || buffer->mNumberChannels == 0) return false;
        UInt32 bytesPerFrame = (UInt32)(sizeof(float) * buffer->mNumberChannels);
        if (bytesPerFrame == 0 || (buffer->mDataByteSize % bytesPerFrame) != 0) return false;
        UInt32 bufferFrames = buffer->mDataByteSize / bytesPerFrame;
        if (bufferFrames < frameCount) frameCount = bufferFrames;
        flattenedChannels += buffer->mNumberChannels;
    }
    if (flattenedChannels < requiredPhysicalChannels || frameCount == UINT32_MAX) return false;
    *frameCountOut = frameCount;
    return true;
}

'''
impl = replace_once(impl, output_view_anchor, multichannel_helper + output_view_anchor, "multichannel output frame-count helper")

# Replace only the buffer-layout acquisition and output-pointer setup/writes in the IOProc.
old_layout = '''    N60OutputBufferView outputView = {0};\n    if (!make_output_buffer_view(outOutputData, &outputView)) {\n        zero_output(outOutputData);\n        atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);\n        return noErr;\n    }\n    UInt32 frameCount = outputView.frameCount;\n'''
new_layout = '''    bool sameDeviceMultiOutput = bridge->sameDeviceOutputMap.valid;\n    N60OutputBufferView outputView = {0};\n    UInt32 frameCount = 0;\n    if (sameDeviceMultiOutput) {\n        if (!make_same_device_output_frame_count(\n            outOutputData,\n            bridge->sameDeviceOutputMap.physicalChannelCount,\n            &frameCount\n        )) {\n            zero_output(outOutputData);\n            atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);\n            return noErr;\n        }\n    } else {\n        if (!make_output_buffer_view(outOutputData, &outputView)) {\n            zero_output(outOutputData);\n            atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);\n            return noErr;\n        }\n        frameCount = outputView.frameCount;\n    }\n'''
impl = replace_once(impl, old_layout, new_layout, "output IOProc layout selection")

old_ptrs = '''    float *outputLeft = outputView.left;\n    float *outputRight = outputView.right;\n'''
new_ptrs = '''    float *outputLeft = outputView.left;\n    float *outputRight = outputView.right;\n'''
# Deliberately keep pointer declaration identical; in multi-output mode it remains NULL and is never dereferenced.
if impl.count(old_ptrs) != 1:
    raise SystemExit(f"output pointer block: expected one match, found {impl.count(old_ptrs)}")

old_write = '''        *outputLeft = finalLeft;\n        *outputRight = finalRight;\n'''
new_write = '''        if (sameDeviceMultiOutput) {\n            N60SpeakerBusFrame busFrame = N60SpeakerBusFrameMakeSilence();\n            (void)N60SpeakerBusFrameSet(&busFrame, N60SpeakerOutputBusLeftFullRange, finalLeft);\n            (void)N60SpeakerBusFrameSet(&busFrame, N60SpeakerOutputBusRightFullRange, finalRight);\n            if (!N60SameDeviceOutputMapWriteFrame(\n                &bridge->sameDeviceOutputMap, &busFrame, outOutputData, frameIndex\n            )) {\n                zero_output(outOutputData);\n                atomic_fetch_add_explicit(&bridge->unsupportedBufferLayouts, 1, memory_order_relaxed);\n                N60RenderKernelEndRender(bridge->renderKernel, &renderContext, renderedFrames);\n                return noErr;\n            }\n        } else {\n            *outputLeft = finalLeft;\n            *outputRight = finalRight;\n        }\n'''
impl = replace_once(impl, old_write, new_write, "output IOProc routed frame write")

old_increment = '''        outputLeft += outputView.leftStride;\n        outputRight += outputView.rightStride;\n        renderedFrames += 1;\n'''
new_increment = '''        if (!sameDeviceMultiOutput) {\n            outputLeft += outputView.leftStride;\n            outputRight += outputView.rightStride;\n        }\n        renderedFrames += 1;\n'''
impl = replace_once(impl, old_increment, new_increment, "output pointer increment")

old_underflow = '''    for (UInt32 frameIndex = framesToRead; frameIndex < frameCount; ++frameIndex) {\n        (void)next_transition_gain(&transitionRamp);\n        *outputLeft = 0.0f;\n        *outputRight = 0.0f;\n        outputLeft += outputView.leftStride;\n        outputRight += outputView.rightStride;\n    }\n'''
new_underflow = '''    for (UInt32 frameIndex = framesToRead; frameIndex < frameCount; ++frameIndex) {\n        (void)next_transition_gain(&transitionRamp);\n        if (sameDeviceMultiOutput) {\n            N60SpeakerBusFrame silence = N60SpeakerBusFrameMakeSilence();\n            (void)N60SameDeviceOutputMapWriteFrame(\n                &bridge->sameDeviceOutputMap, &silence, outOutputData, frameIndex\n            );\n        } else {\n            *outputLeft = 0.0f;\n            *outputRight = 0.0f;\n            outputLeft += outputView.leftStride;\n            outputRight += outputView.rightStride;\n        }\n    }\n'''
impl = replace_once(impl, old_underflow, new_underflow, "output IOProc underflow silence")
impl_path.write_text(impl)


# 3. CoreAudioTransportSession configures the map before IOProc start and admits
# float32 multichannel device output while keeping the capture tap stereo.
core_path = Path("NotchSixty/Audio/CoreAudio/CoreAudioError.swift")
core = core_path.read_text()
core = replace_once(
    core,
    '''    var isSupportedStereoTransportFormat: Bool {\n        isFloatPCM && channelCount == 2 && bitsPerChannel == 32\n    }\n''',
    '''    var isSupportedFloat32TransportFormat: Bool {\n        isFloatPCM && bitsPerChannel == 32 && channelCount > 0\n    }\n\n    var isSupportedStereoTransportFormat: Bool {\n        isSupportedFloat32TransportFormat && channelCount == 2\n    }\n''',
    "float32 transport format predicate",
)
core = replace_once(
    core,
    '''    case captureBufferSizeMismatch(capture: UInt32, output: UInt32)\n''',
    '''    case captureBufferSizeMismatch(capture: UInt32, output: UInt32)\n    case sameDeviceOutputMapCompilationFailed\n''',
    "CoreAudioTransport C2b error case",
)
core = replace_once(
    core,
    '''        case .captureBufferSizeMismatch(let capture, let output):\n            return "Capture buffer size \\(capture) frames does not match output buffer size \\(output) frames."\n''',
    '''        case .captureBufferSizeMismatch(let capture, let output):\n            return "Capture buffer size \\(capture) frames does not match output buffer size \\(output) frames."\n        case .sameDeviceOutputMapCompilationFailed:\n            return "Unable to compile the validated same-device physical output map."\n''',
    "CoreAudioTransport C2b error description",
)
core = replace_once(
    core,
    '''    let selectedOutput: AudioOutputDevice\n''',
    '''    let selectedOutput: AudioOutputDevice\n    let sameDeviceOutputPlan: SameDeviceOutputRoutePlan?\n''',
    "transport session plan property",
)
core = replace_once(
    core,
    '''    init(selectedOutput: AudioOutputDevice) throws {\n        self.selectedOutput = selectedOutput\n''',
    '''    init(\n        selectedOutput: AudioOutputDevice,\n        sameDeviceOutputPlan: SameDeviceOutputRoutePlan? = nil\n    ) throws {\n        self.selectedOutput = selectedOutput\n        self.sameDeviceOutputPlan = sameDeviceOutputPlan\n''',
    "transport session C2b initializer",
)
core = replace_once(
    core,
    '''            guard outputFormat.isSupportedStereoTransportFormat else {\n                throw CoreAudioTransportError.unsupportedFormat(role: "output", format: outputFormat)\n            }\n''',
    '''            if sameDeviceOutputPlan == nil {\n                guard outputFormat.isSupportedStereoTransportFormat else {\n                    throw CoreAudioTransportError.unsupportedFormat(role: "output", format: outputFormat)\n                }\n            } else {\n                guard outputFormat.isSupportedFloat32TransportFormat else {\n                    throw CoreAudioTransportError.unsupportedFormat(role: "multichannel output", format: outputFormat)\n                }\n            }\n''',
    "transport output format validation",
)
config_anchor = '''            let unityGraph = N60DSPGraphSnapshotMakeUnity(outputFormat.sampleRate)\n'''
config_code = r'''            if let sameDeviceOutputPlan {
                try sameDeviceOutputPlan.validateForC2bLiveTransport(selectedOutputUID: selectedOutput.uid)
                var descriptors = sameDeviceOutputPlan.routes.map { route -> N60SpeakerOutputRouteDescriptor in
                    var descriptor = N60SpeakerOutputRouteDescriptor()
                    descriptor.bus = route.bus.realtimeCType
                    descriptor.physicalChannelIndex = route.destination.channelIndex
                    return descriptor
                }
                var outputMap = N60SameDeviceOutputMap()
                let compiled = descriptors.withUnsafeBufferPointer { buffer in
                    N60SameDeviceOutputMapCompile(
                        sameDeviceOutputPlan.physicalChannelCount,
                        buffer.baseAddress!,
                        UInt32(buffer.count),
                        &outputMap
                    )
                }
                guard compiled,
                      N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(newBridge, outputMap) else {
                    throw CoreAudioTransportError.sameDeviceOutputMapCompilationFailed
                }
            }

'''
core = replace_once(core, config_anchor, config_code + config_anchor, "transport output map configuration")
core_path.write_text(core)


# 4. Engine owns desired routing state, validates changes only while idle, and
# builds a live full-range same-device plan at transport creation.
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
engine = replace_once(
    engine,
    '''    @Published private(set) var bassManagementConfiguration = BassManagementConfiguration()\n''',
    '''    @Published private(set) var bassManagementConfiguration = BassManagementConfiguration()\n    @Published private(set) var multiOutputRoutingConfiguration: MultiOutputRoutingConfiguration?\n''',
    "engine routing state",
)
method_anchor = '''    func replaceBassManagementConfiguration(_ configuration: BassManagementConfiguration) throws {\n'''
method_code = '''    func replaceMultiOutputRoutingConfiguration(\n        _ configuration: MultiOutputRoutingConfiguration?\n    ) throws {\n        if let configuration {\n            try configuration.validateStructure()\n        }\n        guard lifecycle.state == .idle || configuration == multiOutputRoutingConfiguration else {\n            throw MultiOutputRoutingError.routingChangeRequiresIdle\n        }\n        multiOutputRoutingConfiguration = configuration\n        lastErrorDescription = nil\n    }\n\n'''
engine = replace_once(engine, method_anchor, method_code + method_anchor, "engine routing replacement API")
engine = replace_once(
    engine,
    '''    private func buildTransport(output: AudioOutputDevice) throws {\n        let session = try CoreAudioTransportSession(selectedOutput: output)\n''',
    '''    private func buildTransport(output: AudioOutputDevice) throws {\n        let sameDeviceOutputPlan: SameDeviceOutputRoutePlan?\n        if let routing = multiOutputRoutingConfiguration, routing.enabled {\n            let plan = try routing.makeSameDevicePlan(\n                availableDevices: outputDevices,\n                sampleRate: output.nominalSampleRate\n            )\n            try plan.validateForC2bLiveTransport(selectedOutputUID: output.uid)\n            sameDeviceOutputPlan = plan\n        } else {\n            sameDeviceOutputPlan = nil\n        }\n        let session = try CoreAudioTransportSession(\n            selectedOutput: output,\n            sameDeviceOutputPlan: sameDeviceOutputPlan\n        )\n''',
    "engine C2b transport creation",
)
engine_path.write_text(engine)


# 5. Playback System transaction now updates engine routing intent too, with rollback.
profiles_path = Path("NotchSixty/State/ProductProfiles.swift")
profiles = profiles_path.read_text()
old_transaction = '''        if let configuration {\n            try configuration.validateStructure()\n        }\n\n        let previousState = systemProfiles[index].state\n        do {\n            systemProfiles[index].state.outputRouting = configuration\n            try persistThrowing()\n            lastErrorDescription = nil\n        } catch {\n            systemProfiles[index].state = previousState\n            lastErrorDescription = error.localizedDescription\n            throw error\n        }\n'''
new_transaction = '''        if let configuration {\n            try configuration.validateStructure()\n        }\n\n        let previousEngineConfiguration = engine.multiOutputRoutingConfiguration\n        let previousState = systemProfiles[index].state\n        do {\n            try engine.replaceMultiOutputRoutingConfiguration(configuration)\n            systemProfiles[index].state.outputRouting = configuration\n            try persistThrowing()\n            lastErrorDescription = nil\n        } catch {\n            systemProfiles[index].state = previousState\n            try? engine.replaceMultiOutputRoutingConfiguration(previousEngineConfiguration)\n            lastErrorDescription = error.localizedDescription\n            throw error\n        }\n'''
profiles = replace_once(profiles, old_transaction, new_transaction, "profile routing transaction upgrade")
profiles = replace_once(
    profiles,
    '''            outputRouting: selectedSystemProfile?.state.outputRouting,\n''',
    '''            outputRouting: engine.multiOutputRoutingConfiguration,\n''',
    "capture live routing intent",
)
profiles = replace_once(
    profiles,
    '''            let playback = state.playback.applying(to: engine.playbackControlConfiguration)\n            let gain = state.composingGain(over: engine.gainConfiguration)\n            try engine.replacePlaybackControlConfiguration(playback)\n''',
    '''            let playback = state.playback.applying(to: engine.playbackControlConfiguration)\n            let gain = state.composingGain(over: engine.gainConfiguration)\n            try engine.replaceMultiOutputRoutingConfiguration(state.outputRouting)\n            try engine.replacePlaybackControlConfiguration(playback)\n''',
    "apply system routing intent",
)
profiles = replace_once(
    profiles,
    '''            let playback = previous.playback.applying(to: engine.playbackControlConfiguration)\n            let gain = previous.composingGain(over: engine.gainConfiguration)\n            try? engine.replacePlaybackControlConfiguration(playback)\n''',
    '''            let playback = previous.playback.applying(to: engine.playbackControlConfiguration)\n            let gain = previous.composingGain(over: engine.gainConfiguration)\n            try? engine.replaceMultiOutputRoutingConfiguration(previous.outputRouting)\n            try? engine.replacePlaybackControlConfiguration(playback)\n''',
    "rollback system routing intent",
)
profiles_path.write_text(profiles)


# 6. Extend the permanent C validator through the actual output IOProc path.
validator_path = Path("ci/validate_pr41_same_device_output_map.c")
validator = validator_path.read_text()
main_anchor = '''int main(void) {\n'''
io_test = r'''static int validate_live_output_ioproc(void) {
    N60RealtimeAudioBridge *bridge = N60RealtimeAudioBridgeCreate(64);
    if (bridge == NULL) return 30;

    N60SpeakerOutputRouteDescriptor routes[4] = {
        {N60SpeakerOutputBusLeftFullRange, 0},
        {N60SpeakerOutputBusLeftFullRange, 1},
        {N60SpeakerOutputBusRightFullRange, 2},
        {N60SpeakerOutputBusRightFullRange, 3},
    };
    N60SameDeviceOutputMap map = {0};
    if (!N60SameDeviceOutputMapCompile(4, routes, 4, &map)
        || !N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(bridge, map)) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return 31;
    }
    N60DSPGraphSnapshot graph = N60DSPGraphSnapshotMakeUnity(48000.0);
    if (!N60RealtimeAudioBridgePublishDSPGraph(bridge, graph)) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return 32;
    }

    float inputSamples[8] = {0.1f, -0.2f, 0.3f, -0.4f, -0.5f, 0.6f, 0.7f, -0.8f};
    AudioBufferList input = {0};
    input.mNumberBuffers = 1;
    input.mBuffers[0].mNumberChannels = 2;
    input.mBuffers[0].mDataByteSize = sizeof(inputSamples);
    input.mBuffers[0].mData = inputSamples;
    AudioTimeStamp timestamp = {0};
    if (N60CaptureIOProc(0, &timestamp, &input, &timestamp, &input, &timestamp, bridge) != noErr) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return 33;
    }

    float outputSamples[16];
    for (uint32_t i = 0; i < 16; ++i) outputSamples[i] = 9.0f;
    AudioBufferList output = {0};
    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = 4;
    output.mBuffers[0].mDataByteSize = sizeof(outputSamples);
    output.mBuffers[0].mData = outputSamples;
    if (N60OutputIOProc(0, &timestamp, &input, &timestamp, &output, &timestamp, bridge) != noErr) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return 34;
    }

    for (uint32_t frame = 0; frame < 4; ++frame) {
        float left = inputSamples[frame * 2];
        float right = inputSamples[frame * 2 + 1];
        uint32_t base = frame * 4;
        if (!close_enough(outputSamples[base], left)
            || !close_enough(outputSamples[base + 1], left)
            || !close_enough(outputSamples[base + 2], right)
            || !close_enough(outputSamples[base + 3], right)) {
            N60RealtimeAudioBridgeDestroy(bridge);
            return 35;
        }
    }
    N60RealtimeAudioBridgeSnapshot snapshot = N60RealtimeAudioBridgeGetSnapshot(bridge);
    if (snapshot.deliveredFrames != 4 || snapshot.unsupportedBufferLayouts != 0) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return 36;
    }
    N60RealtimeAudioBridgeDestroy(bridge);
    return 0;
}

'''
validator = replace_once(validator, main_anchor, io_test + main_anchor, "live IOProc validator")
validator = replace_once(
    validator,
    '''    result = validate_rejections();\n    if (result != 0) return result;\n    puts("PR41 same-device output map validation passed");\n''',
    '''    result = validate_rejections();\n    if (result != 0) return result;\n    result = validate_live_output_ioproc();\n    if (result != 0) return result;\n    puts("PR41 same-device output map and live IOProc validation passed");\n''',
    "live IOProc validator invocation",
)
validator_path.write_text(validator)


# 7. Focused Swift tests: C2b bus rejection and engine/profile ownership.
tests_path = Path("NotchSixtyTests/RoomCorrectionProjectControllerTests.swift")
tests = tests_path.read_text()
if not tests.endswith("\n}\n"):
    raise SystemExit("Unexpected RoomCorrectionProjectControllerTests.swift ending")
tests_add = r'''
    func testC2bLiveTransportAcceptsOnlyPostDSPFullRangeBuses() throws {
        let fullRangePlan = SameDeviceOutputRoutePlan(
            deviceUID: "dac",
            physicalChannelCount: 4,
            routes: [
                SpeakerOutputRoute(
                    name: "Left A",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 0)
                ),
                SpeakerOutputRoute(
                    name: "Right A",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 1)
                ),
            ]
        )
        XCTAssertNoThrow(try fullRangePlan.validateForC2bLiveTransport(selectedOutputUID: "dac"))
        XCTAssertThrowsError(try fullRangePlan.validateForC2bLiveTransport(selectedOutputUID: "other")) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .liveTransportOutputMismatch(selected: "other", routed: "dac")
            )
        }

        var subPlan = fullRangePlan
        subPlan = SameDeviceOutputRoutePlan(
            deviceUID: subPlan.deviceUID,
            physicalChannelCount: subPlan.physicalChannelCount,
            routes: [
                subPlan.routes[0],
                SpeakerOutputRoute(
                    name: "Sub",
                    bus: .subMono,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 2)
                ),
            ]
        )
        XCTAssertThrowsError(try subPlan.validateForC2bLiveTransport(selectedOutputUID: "dac")) { error in
            XCTAssertEqual(error as? MultiOutputRoutingError, .liveTransportBusUnavailable(.subMono))
        }
    }

    func testPlaybackSystemRoutingTransactionUpdatesEngineIntentAndRollsBackTogether() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
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
        try fixture.profiles.replaceSelectedSystemOutputRouting(routing)
        XCTAssertEqual(fixture.profiles.engine.multiOutputRoutingConfiguration, routing)
        XCTAssertEqual(fixture.profiles.selectedSystemProfile?.state.outputRouting, routing)
        XCTAssertEqual(fixture.profiles.captureSystemState().outputRouting, routing)
    }
'''
tests = tests[:-3] + "\n" + tests_add + "}\n"
tests_path.write_text(tests)

print("PR41 Slice C2b live same-device transport applied")
