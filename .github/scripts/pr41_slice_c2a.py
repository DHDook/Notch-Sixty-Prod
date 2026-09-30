from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# 1. Swift control-plane plan for a single hardware clock domain.
route_path = Path("NotchSixty/Audio/Routing/AudioRouteConfiguration.swift")
route = route_path.read_text()
route = replace_once(
    route,
    '''    case sampleRateUnsupported(deviceUID: String, sampleRate: Double)\n''',
    '''    case sampleRateUnsupported(deviceUID: String, sampleRate: Double)\n    case sameDeviceTransportRequiresEnabledRouting\n    case sameDeviceTransportRequiresSingleDevice([String])\n''',
    "same-device routing error cases",
)
route = replace_once(
    route,
    '''        case .sampleRateUnsupported(let uid, let sampleRate):\n            return "Output device \\(uid) does not support \\(sampleRate) Hz natively."\n''',
    '''        case .sampleRateUnsupported(let uid, let sampleRate):\n            return "Output device \\(uid) does not support \\(sampleRate) Hz natively."\n        case .sameDeviceTransportRequiresEnabledRouting:\n            return "Enable multi-output routing before compiling a same-device output plan."\n        case .sameDeviceTransportRequiresSingleDevice(let uids):\n            return "Same-device transport requires every enabled route to target one physical device; found: \\(uids.joined(separator: ", "))."\n''',
    "same-device routing error descriptions",
)
append = r'''

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
'''
if append.strip() in route:
    raise SystemExit("same-device route plan already present")
route = route.rstrip() + append + "\n"
route_path.write_text(route)


# 2. Fixed-size realtime route map + speaker-bus frame API.
header_path = Path("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h")
header = header_path.read_text()
header = replace_once(
    header,
    '#define N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES 65536u\n',
    r'''#define N60_ANALYSIS_CAPTURE_CAPACITY_FRAMES 65536u

// PR41 Slice C2a: immutable same-device speaker-output routing. The control
// plane compiles at most eight logical-bus routes; the realtime writer only
// reads this fixed-size map and writes preallocated Core Audio buffers.
#define N60_SPEAKER_OUTPUT_MAX_ROUTES 8u

typedef enum {
    N60SpeakerOutputBusLeftFullRange = 0,
    N60SpeakerOutputBusRightFullRange = 1,
    N60SpeakerOutputBusLeftLow = 2,
    N60SpeakerOutputBusRightLow = 3,
    N60SpeakerOutputBusLeftMid = 4,
    N60SpeakerOutputBusRightMid = 5,
    N60SpeakerOutputBusLeftHigh = 6,
    N60SpeakerOutputBusRightHigh = 7,
    N60SpeakerOutputBusSubMono = 8,
    N60SpeakerOutputBusCount = 9,
} N60SpeakerOutputBus;

typedef struct {
    float values[N60SpeakerOutputBusCount];
} N60SpeakerBusFrame;

typedef struct {
    N60SpeakerOutputBus bus;
    uint32_t physicalChannelIndex;
} N60SpeakerOutputRouteDescriptor;

typedef struct {
    bool valid;
    uint32_t physicalChannelCount;
    uint32_t routeCount;
    N60SpeakerOutputRouteDescriptor routes[N60_SPEAKER_OUTPUT_MAX_ROUTES];
} N60SameDeviceOutputMap;
''',
    "realtime route map types",
)
api_anchor = '''OSStatus N60CaptureIOProc(\n'''
api = r'''N60SpeakerBusFrame N60SpeakerBusFrameMakeSilence(void);
bool N60SpeakerBusFrameSet(
    N60SpeakerBusFrame * _Nonnull frame,
    N60SpeakerOutputBus bus,
    float value
);
float N60SpeakerBusFrameGet(
    const N60SpeakerBusFrame * _Nonnull frame,
    N60SpeakerOutputBus bus
);
bool N60SameDeviceOutputMapCompile(
    uint32_t physicalChannelCount,
    const N60SpeakerOutputRouteDescriptor * _Nonnull routes,
    uint32_t routeCount,
    N60SameDeviceOutputMap * _Nonnull mapOut
);
bool N60SameDeviceOutputMapValueForChannel(
    const N60SameDeviceOutputMap * _Nonnull map,
    const N60SpeakerBusFrame * _Nonnull frame,
    uint32_t physicalChannelIndex,
    float * _Nonnull valueOut
);
// Writes one frame to an arbitrary Core Audio output buffer layout. Every
// physical channel represented by the AudioBufferList is zeroed first; mapped
// channels then receive their logical-bus value. No allocation or locking.
bool N60SameDeviceOutputMapWriteFrame(
    const N60SameDeviceOutputMap * _Nonnull map,
    const N60SpeakerBusFrame * _Nonnull frame,
    AudioBufferList * _Nonnull outputData,
    uint32_t frameIndex
);

'''
header = replace_once(header, api_anchor, api + api_anchor, "realtime route map API")
header_path.write_text(header)


# 3. Realtime-safe C implementation. Dormant until C2b wires it into the IOProc.
impl_path = Path("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c")
impl = impl_path.read_text()
impl_anchor = '''OSStatus N60CaptureIOProc(\n'''
impl_code = r'''static bool speaker_bus_is_valid(N60SpeakerOutputBus bus) {
    return bus >= N60SpeakerOutputBusLeftFullRange && bus < N60SpeakerOutputBusCount;
}

N60SpeakerBusFrame N60SpeakerBusFrameMakeSilence(void) {
    N60SpeakerBusFrame frame = {0};
    return frame;
}

bool N60SpeakerBusFrameSet(
    N60SpeakerBusFrame *frame,
    N60SpeakerOutputBus bus,
    float value
) {
    if (frame == NULL || !speaker_bus_is_valid(bus) || !isfinite(value)) return false;
    frame->values[(uint32_t)bus] = value;
    return true;
}

float N60SpeakerBusFrameGet(
    const N60SpeakerBusFrame *frame,
    N60SpeakerOutputBus bus
) {
    if (frame == NULL || !speaker_bus_is_valid(bus)) return 0.0f;
    return frame->values[(uint32_t)bus];
}

bool N60SameDeviceOutputMapCompile(
    uint32_t physicalChannelCount,
    const N60SpeakerOutputRouteDescriptor *routes,
    uint32_t routeCount,
    N60SameDeviceOutputMap *mapOut
) {
    if (mapOut == NULL) return false;
    memset(mapOut, 0, sizeof(*mapOut));
    if (physicalChannelCount == 0
        || routes == NULL
        || routeCount < 2u
        || routeCount > N60_SPEAKER_OUTPUT_MAX_ROUTES) {
        return false;
    }

    for (uint32_t index = 0; index < routeCount; ++index) {
        N60SpeakerOutputRouteDescriptor route = routes[index];
        if (!speaker_bus_is_valid(route.bus)
            || route.physicalChannelIndex >= physicalChannelCount) {
            return false;
        }
        for (uint32_t previous = 0; previous < index; ++previous) {
            if (routes[previous].physicalChannelIndex == route.physicalChannelIndex) {
                return false;
            }
        }
        mapOut->routes[index] = route;
    }
    mapOut->physicalChannelCount = physicalChannelCount;
    mapOut->routeCount = routeCount;
    mapOut->valid = true;
    return true;
}

bool N60SameDeviceOutputMapValueForChannel(
    const N60SameDeviceOutputMap *map,
    const N60SpeakerBusFrame *frame,
    uint32_t physicalChannelIndex,
    float *valueOut
) {
    if (valueOut == NULL) return false;
    *valueOut = 0.0f;
    if (map == NULL || frame == NULL || !map->valid
        || physicalChannelIndex >= map->physicalChannelCount) {
        return false;
    }
    for (uint32_t index = 0; index < map->routeCount; ++index) {
        if (map->routes[index].physicalChannelIndex == physicalChannelIndex) {
            *valueOut = N60SpeakerBusFrameGet(frame, map->routes[index].bus);
            return true;
        }
    }
    return true;
}

static bool output_buffer_frame_is_addressable(
    const AudioBuffer *buffer,
    uint32_t frameIndex
) {
    if (buffer == NULL || buffer->mData == NULL || buffer->mNumberChannels == 0) return false;
    uint64_t bytesPerFrame = (uint64_t)sizeof(float) * buffer->mNumberChannels;
    uint64_t requiredBytes = ((uint64_t)frameIndex + 1u) * bytesPerFrame;
    return requiredBytes <= buffer->mDataByteSize;
}

bool N60SameDeviceOutputMapWriteFrame(
    const N60SameDeviceOutputMap *map,
    const N60SpeakerBusFrame *frame,
    AudioBufferList *outputData,
    uint32_t frameIndex
) {
    if (map == NULL || frame == NULL || outputData == NULL || !map->valid
        || outputData->mNumberBuffers == 0) {
        return false;
    }

    uint64_t flattenedChannelCount = 0;
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        if (!output_buffer_frame_is_addressable(buffer, frameIndex)) return false;
        flattenedChannelCount += buffer->mNumberChannels;
    }
    if (flattenedChannelCount < map->physicalChannelCount) return false;

    // Silence every channel represented by this callback frame before routing.
    // This prevents stale samples on unassigned hardware channels.
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
        float *samples = (float *)buffer->mData;
        uint64_t base = (uint64_t)frameIndex * buffer->mNumberChannels;
        for (UInt32 localChannel = 0; localChannel < buffer->mNumberChannels; ++localChannel) {
            samples[base + localChannel] = 0.0f;
        }
    }

    for (uint32_t routeIndex = 0; routeIndex < map->routeCount; ++routeIndex) {
        N60SpeakerOutputRouteDescriptor route = map->routes[routeIndex];
        uint32_t remainingChannel = route.physicalChannelIndex;
        for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
            AudioBuffer *buffer = &outputData->mBuffers[bufferIndex];
            if (remainingChannel < buffer->mNumberChannels) {
                float *samples = (float *)buffer->mData;
                uint64_t sampleIndex = (uint64_t)frameIndex * buffer->mNumberChannels + remainingChannel;
                samples[sampleIndex] = N60SpeakerBusFrameGet(frame, route.bus);
                break;
            }
            remainingChannel -= buffer->mNumberChannels;
        }
    }
    return true;
}

'''
impl = replace_once(impl, impl_anchor, impl_code + impl_anchor, "realtime route map implementation")
impl_path.write_text(impl)


# 4. Swift deterministic plan tests. Insert into existing test target, avoiding
# project-file surgery.
tests_path = Path("NotchSixtyTests/RoomCorrectionProjectControllerTests.swift")
tests = tests_path.read_text()
if not tests.endswith("\n}\n"):
    raise SystemExit("Unexpected RoomCorrectionProjectControllerTests.swift ending")
swift_tests = r'''
    func testSameDeviceRoutePlanUsesOneClockDomainAndPreservesEnabledRouteOrder() throws {
        let device = AudioOutputDevice(
            deviceID: 303,
            uid: "eight-channel-dac",
            name: "Eight Channel DAC",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 192_000)],
            outputChannelCount: 8
        )
        let disabled = SpeakerOutputRoute(
            name: "Unused",
            bus: .leftHigh,
            destination: PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: 7),
            enabled: false
        )
        let enabledRoutes = [
            SpeakerOutputRoute(
                name: "Left Main",
                bus: .leftFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: 2)
            ),
            SpeakerOutputRoute(
                name: "Right Main",
                bus: .rightFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: 3)
            ),
            SpeakerOutputRoute(
                name: "Sub",
                bus: .subMono,
                destination: PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: 6)
            ),
        ]
        let configuration = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [enabledRoutes[0], disabled, enabledRoutes[1], enabledRoutes[2]],
            synchronizationMode: .softwarePLL,
            referenceDeviceUID: device.uid
        )

        let plan = try configuration.makeSameDevicePlan(
            availableDevices: [device],
            sampleRate: 96_000
        )
        XCTAssertEqual(plan.deviceUID, device.uid)
        XCTAssertEqual(plan.physicalChannelCount, 8)
        XCTAssertEqual(plan.routes, enabledRoutes)
        XCTAssertEqual(plan.requiredPhysicalChannelCount, 7)
    }

    func testSameDeviceRoutePlanRejectsDisabledAndMultiDeviceConfigurations() throws {
        let first = AudioOutputDevice(
            deviceID: 401,
            uid: "dac-a",
            name: "DAC A",
            nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 48_000, maximum: 96_000)],
            outputChannelCount: 4
        )
        let second = AudioOutputDevice(
            deviceID: 402,
            uid: "dac-b",
            name: "DAC B",
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
                name: "Right",
                bus: .rightFullRange,
                destination: PhysicalOutputEndpoint(deviceUID: second.uid, channelIndex: 0)
            ),
        ]

        let disabled = MultiOutputRoutingConfiguration(enabled: false, routes: routes)
        XCTAssertThrowsError(
            try disabled.makeSameDevicePlan(availableDevices: [first, second], sampleRate: 48_000)
        ) { error in
            XCTAssertEqual(error as? MultiOutputRoutingError, .sameDeviceTransportRequiresEnabledRouting)
        }

        let multiple = MultiOutputRoutingConfiguration(enabled: true, routes: routes)
        XCTAssertThrowsError(
            try multiple.makeSameDevicePlan(availableDevices: [first, second], sampleRate: 48_000)
        ) { error in
            XCTAssertEqual(
                error as? MultiOutputRoutingError,
                .sameDeviceTransportRequiresSingleDevice(["dac-a", "dac-b"])
            )
        }
    }
'''
tests = tests[:-3] + "\n" + swift_tests + "}\n"
tests_path.write_text(tests)


# 5. Long-lived C validator for interleaved + planar Core Audio layouts.
validator_path = Path("ci/validate_pr41_same_device_output_map.c")
validator_path.write_text(r'''#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60RealtimeAudioBridge.h"

static int close_enough(float lhs, float rhs) {
    return fabsf(lhs - rhs) < 1.0e-6f;
}

static int validate_interleaved(void) {
    N60SpeakerOutputRouteDescriptor routes[4] = {
        {N60SpeakerOutputBusSubMono, 0},
        {N60SpeakerOutputBusSubMono, 1},
        {N60SpeakerOutputBusLeftFullRange, 2},
        {N60SpeakerOutputBusRightFullRange, 3},
    };
    N60SameDeviceOutputMap map = {0};
    if (!N60SameDeviceOutputMapCompile(4, routes, 4, &map)) return 1;

    N60SpeakerBusFrame frame = N60SpeakerBusFrameMakeSilence();
    if (!N60SpeakerBusFrameSet(&frame, N60SpeakerOutputBusSubMono, 0.75f)) return 2;
    if (!N60SpeakerBusFrameSet(&frame, N60SpeakerOutputBusLeftFullRange, 0.25f)) return 3;
    if (!N60SpeakerBusFrameSet(&frame, N60SpeakerOutputBusRightFullRange, -0.5f)) return 4;

    float samples[8] = {9, 9, 9, 9, 9, 9, 9, 9};
    AudioBufferList list = {0};
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 4;
    list.mBuffers[0].mDataByteSize = sizeof(samples);
    list.mBuffers[0].mData = samples;
    if (!N60SameDeviceOutputMapWriteFrame(&map, &frame, &list, 0)) return 5;
    if (!close_enough(samples[0], 0.75f)
        || !close_enough(samples[1], 0.75f)
        || !close_enough(samples[2], 0.25f)
        || !close_enough(samples[3], -0.5f)) return 6;
    if (!close_enough(samples[4], 9.0f)) return 7;

    float value = 99.0f;
    if (!N60SameDeviceOutputMapValueForChannel(&map, &frame, 3, &value)
        || !close_enough(value, -0.5f)) return 8;
    return 0;
}

static int validate_planar_and_silence(void) {
    N60SpeakerOutputRouteDescriptor routes[2] = {
        {N60SpeakerOutputBusLeftFullRange, 0},
        {N60SpeakerOutputBusRightFullRange, 3},
    };
    N60SameDeviceOutputMap map = {0};
    if (!N60SameDeviceOutputMapCompile(4, routes, 2, &map)) return 10;

    N60SpeakerBusFrame frame = N60SpeakerBusFrameMakeSilence();
    N60SpeakerBusFrameSet(&frame, N60SpeakerOutputBusLeftFullRange, 0.1f);
    N60SpeakerBusFrameSet(&frame, N60SpeakerOutputBusRightFullRange, -0.2f);

    size_t listSize = offsetof(AudioBufferList, mBuffers) + 4 * sizeof(AudioBuffer);
    AudioBufferList *list = calloc(1, listSize);
    if (list == NULL) return 11;
    float channels[4][2] = {{5, 5}, {5, 5}, {5, 5}, {5, 5}};
    list->mNumberBuffers = 4;
    for (uint32_t index = 0; index < 4; ++index) {
        list->mBuffers[index].mNumberChannels = 1;
        list->mBuffers[index].mDataByteSize = sizeof(channels[index]);
        list->mBuffers[index].mData = channels[index];
    }
    int result = 0;
    if (!N60SameDeviceOutputMapWriteFrame(&map, &frame, list, 1)) result = 12;
    if (!close_enough(channels[0][1], 0.1f)
        || !close_enough(channels[1][1], 0.0f)
        || !close_enough(channels[2][1], 0.0f)
        || !close_enough(channels[3][1], -0.2f)) result = 13;
    if (!close_enough(channels[0][0], 5.0f)) result = 14;
    free(list);
    return result;
}

static int validate_rejections(void) {
    N60SameDeviceOutputMap map = {0};
    N60SpeakerOutputRouteDescriptor duplicate[2] = {
        {N60SpeakerOutputBusLeftFullRange, 0},
        {N60SpeakerOutputBusRightFullRange, 0},
    };
    if (N60SameDeviceOutputMapCompile(2, duplicate, 2, &map)) return 20;

    N60SpeakerOutputRouteDescriptor outOfRange[2] = {
        {N60SpeakerOutputBusLeftFullRange, 0},
        {N60SpeakerOutputBusRightFullRange, 2},
    };
    if (N60SameDeviceOutputMapCompile(2, outOfRange, 2, &map)) return 21;

    N60SpeakerOutputRouteDescriptor invalidBus[2] = {
        {(N60SpeakerOutputBus)99, 0},
        {N60SpeakerOutputBusRightFullRange, 1},
    };
    if (N60SameDeviceOutputMapCompile(2, invalidBus, 2, &map)) return 22;
    return 0;
}

int main(void) {
    int result = validate_interleaved();
    if (result != 0) return result;
    result = validate_planar_and_silence();
    if (result != 0) return result;
    result = validate_rejections();
    if (result != 0) return result;
    puts("PR41 same-device output map validation passed");
    return 0;
}
''')


# 6. Retain C2a validator in the normal macOS exact-head lane.
workflow_path = Path(".github/workflows/macos.yml")
workflow = workflow_path.read_text()
workflow_anchor = '''      - name: Benchmark PR35 Render Kernel O0 vs O3\n'''
workflow_step = r'''      - name: Validate PR41 Same-device Output Map
        run: |
          REALTIME_SOURCES=$(find NotchSixty/Audio/Realtime -name '*.c' -print)
          clang -std=c11 -O2 -Wall -Wextra -Werror \
            -include stddef.h \
            -INotchSixty/Audio/Realtime \
            ci/validate_pr41_same_device_output_map.c \
            $REALTIME_SOURCES \
            -framework Accelerate \
            -framework CoreAudio \
            -o /tmp/validate-pr41-same-device-output-map
          /tmp/validate-pr41-same-device-output-map

'''
workflow = replace_once(workflow, workflow_anchor, workflow_step + workflow_anchor, "PR41 macOS validator step")
workflow_path.write_text(workflow)

print("PR41 Slice C2a same-device fan-out primitive applied")
