#include <CoreAudio/CoreAudio.h>
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

static int validate_live_output_ioproc(void) {
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

int main(void) {
    int result = validate_interleaved();
    if (result != 0) return result;
    result = validate_planar_and_silence();
    if (result != 0) return result;
    result = validate_rejections();
    if (result != 0) return result;
    result = validate_live_output_ioproc();
    if (result != 0) return result;
    puts("PR41 same-device output map and live IOProc validation passed");
    return 0;
}
