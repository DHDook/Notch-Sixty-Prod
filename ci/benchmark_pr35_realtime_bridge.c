#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "N60RealtimeAudioBridge.h"

#define SAMPLE_RATE 96000.0
#define BUFFER_FRAMES 512u
#define BRIDGE_CAPACITY 65536u
#define WARMUP_BUFFERS 128u
#define MEASURE_BUFFERS 4096u

static volatile double benchmark_sink = 0.0;

static double monotonic_seconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static bool process_buffers(
    N60RealtimeAudioBridge *bridge,
    uint32_t bufferCount,
    float *inputSamples,
    float *outputSamples,
    double *sink
) {
    if (bridge == NULL || inputSamples == NULL || outputSamples == NULL || sink == NULL) return false;

    AudioTimeStamp timestamp = {0};
    AudioBufferList input = {0};
    input.mNumberBuffers = 1;
    input.mBuffers[0].mNumberChannels = 2;
    input.mBuffers[0].mDataByteSize = BUFFER_FRAMES * 2u * (UInt32)sizeof(float);
    input.mBuffers[0].mData = inputSamples;

    AudioBufferList output = {0};
    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = 2;
    output.mBuffers[0].mDataByteSize = BUFFER_FRAMES * 2u * (UInt32)sizeof(float);
    output.mBuffers[0].mData = outputSamples;

    double accumulator = *sink;
    for (uint32_t bufferIndex = 0; bufferIndex < bufferCount; ++bufferIndex) {
        for (uint32_t frameIndex = 0; frameIndex < BUFFER_FRAMES; ++frameIndex) {
            uint32_t pattern = bufferIndex * BUFFER_FRAMES + frameIndex;
            inputSamples[frameIndex * 2u] = (pattern & 1u) == 0u ? 0.18f : -0.17f;
            inputSamples[frameIndex * 2u + 1u] = (pattern & 2u) == 0u ? -0.13f : 0.14f;
        }

        if (N60CaptureIOProc(
                0,
                &timestamp,
                &input,
                &timestamp,
                &output,
                &timestamp,
                bridge
            ) != noErr) {
            return false;
        }
        if (N60OutputIOProc(
                0,
                &timestamp,
                &input,
                &timestamp,
                &output,
                &timestamp,
                bridge
            ) != noErr) {
            return false;
        }

        accumulator += (double)outputSamples[0] * 1.0e-9;
        accumulator += (double)outputSamples[BUFFER_FRAMES * 2u - 1u] * 1.0e-9;
    }
    *sink = accumulator;
    return true;
}

int main(void) {
    N60RealtimeAudioBridge *bridge = N60RealtimeAudioBridgeCreate(BRIDGE_CAPACITY);
    if (bridge == NULL) {
        fputs("unable to create realtime bridge\n", stderr);
        return EXIT_FAILURE;
    }

    N60DSPGraphSnapshot snapshot = N60DSPGraphSnapshotMakeUnity(SAMPLE_RATE);
    if (!N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot)) {
        fputs("unable to publish unity graph\n", stderr);
        N60RealtimeAudioBridgeDestroy(bridge);
        return EXIT_FAILURE;
    }
    N60RealtimeAudioBridgeConfigureOutputGate(bridge, 0u, 0u);

    float *inputSamples = calloc(BUFFER_FRAMES * 2u, sizeof(float));
    float *outputSamples = calloc(BUFFER_FRAMES * 2u, sizeof(float));
    if (inputSamples == NULL || outputSamples == NULL) {
        fputs("unable to allocate benchmark buffers\n", stderr);
        free(inputSamples);
        free(outputSamples);
        N60RealtimeAudioBridgeDestroy(bridge);
        return EXIT_FAILURE;
    }

    double sink = 0.0;
    if (!process_buffers(bridge, WARMUP_BUFFERS, inputSamples, outputSamples, &sink)) {
        fputs("bridge warmup failed\n", stderr);
        free(inputSamples);
        free(outputSamples);
        N60RealtimeAudioBridgeDestroy(bridge);
        return EXIT_FAILURE;
    }

    double start = monotonic_seconds();
    if (start <= 0.0
        || !process_buffers(bridge, MEASURE_BUFFERS, inputSamples, outputSamples, &sink)) {
        fputs("bridge measurement failed\n", stderr);
        free(inputSamples);
        free(outputSamples);
        N60RealtimeAudioBridgeDestroy(bridge);
        return EXIT_FAILURE;
    }
    double finish = monotonic_seconds();

    N60RealtimeAudioBridgeSnapshot counters = N60RealtimeAudioBridgeGetSnapshot(bridge);
    free(inputSamples);
    free(outputSamples);
    N60RealtimeAudioBridgeDestroy(bridge);

    if (finish <= start) {
        fputs("invalid timer result\n", stderr);
        return EXIT_FAILURE;
    }

    const double frames = (double)BUFFER_FRAMES * (double)MEASURE_BUFFERS;
    const double seconds = finish - start;
    const double nsPerFrame = seconds * 1000000000.0 / frames;
    const double oneCorePercentAt96k = nsPerFrame * 0.0096;
    benchmark_sink += sink;

    printf(
        "bridge-unity-512: %.2f ns/frame, theoretical %.2f%% of one core at 96 kHz "
        "(%.3f s / %.0f frames; capture callbacks=%llu output callbacks=%llu)\n",
        nsPerFrame,
        oneCorePercentAt96k,
        seconds,
        frames,
        (unsigned long long)counters.captureCallbacks,
        (unsigned long long)counters.outputCallbacks
    );

    if (benchmark_sink == 123456789.0) puts("unreachable");
    return EXIT_SUCCESS;
}