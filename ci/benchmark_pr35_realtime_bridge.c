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

static bool run_case(const char *name, bool outputVUEnabled) {
    N60RealtimeAudioBridgeSetOutputVUMeterDemand(outputVUEnabled);
    N60RealtimeAudioBridge *bridge = N60RealtimeAudioBridgeCreate(BRIDGE_CAPACITY);
    if (bridge == NULL) {
        fprintf(stderr, "%s: unable to create realtime bridge\n", name);
        return false;
    }

    N60DSPGraphSnapshot snapshot = N60DSPGraphSnapshotMakeUnity(SAMPLE_RATE);
    if (!N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot)) {
        fprintf(stderr, "%s: unable to publish unity graph\n", name);
        N60RealtimeAudioBridgeDestroy(bridge);
        return false;
    }
    N60RealtimeAudioBridgeConfigureOutputGate(bridge, 0u, 0u);

    float *inputSamples = calloc(BUFFER_FRAMES * 2u, sizeof(float));
    float *outputSamples = calloc(BUFFER_FRAMES * 2u, sizeof(float));
    if (inputSamples == NULL || outputSamples == NULL) {
        fprintf(stderr, "%s: unable to allocate benchmark buffers\n", name);
        free(inputSamples);
        free(outputSamples);
        N60RealtimeAudioBridgeDestroy(bridge);
        return false;
    }

    double sink = 0.0;
    if (!process_buffers(bridge, WARMUP_BUFFERS, inputSamples, outputSamples, &sink)) {
        fprintf(stderr, "%s: bridge warmup failed\n", name);
        free(inputSamples);
        free(outputSamples);
        N60RealtimeAudioBridgeDestroy(bridge);
        return false;
    }

    double start = monotonic_seconds();
    if (start <= 0.0
        || !process_buffers(bridge, MEASURE_BUFFERS, inputSamples, outputSamples, &sink)) {
        fprintf(stderr, "%s: bridge measurement failed\n", name);
        free(inputSamples);
        free(outputSamples);
        N60RealtimeAudioBridgeDestroy(bridge);
        return false;
    }
    double finish = monotonic_seconds();

    N60RealtimeAudioBridgeSnapshot counters = N60RealtimeAudioBridgeGetSnapshot(bridge);
    N60OutputVUMeterSnapshot vu = N60RealtimeAudioBridgeGetOutputVUMeterSnapshot(bridge);
    free(inputSamples);
    free(outputSamples);
    N60RealtimeAudioBridgeDestroy(bridge);

    if (finish <= start) {
        fprintf(stderr, "%s: invalid timer result\n", name);
        return false;
    }
    if (vu.enabled != outputVUEnabled) {
        fprintf(stderr, "%s: VU demand state mismatch\n", name);
        return false;
    }
    if (outputVUEnabled && (vu.rmsLeft <= 0.0f || vu.rmsRight <= 0.0f
        || vu.peakLeft <= 0.0f || vu.peakRight <= 0.0f)) {
        fprintf(stderr, "%s: output VU failed to publish readings\n", name);
        return false;
    }

    const double frames = (double)BUFFER_FRAMES * (double)MEASURE_BUFFERS;
    const double seconds = finish - start;
    const double nsPerFrame = seconds * 1000000000.0 / frames;
    const double oneCorePercentAt96k = nsPerFrame * 0.0096;
    benchmark_sink += sink;

    printf(
        "%s: %.2f ns/frame, theoretical %.2f%% of one core at 96 kHz "
        "(%.3f s / %.0f frames; capture callbacks=%llu output callbacks=%llu; vu-rms=%.5f/%.5f)\n",
        name,
        nsPerFrame,
        oneCorePercentAt96k,
        seconds,
        frames,
        (unsigned long long)counters.captureCallbacks,
        (unsigned long long)counters.outputCallbacks,
        vu.rmsLeft,
        vu.rmsRight
    );
    return true;
}

int main(void) {
    if (!run_case("bridge-unity-512", false)) return EXIT_FAILURE;
    if (!run_case("bridge-output-vu-512", true)) return EXIT_FAILURE;
    N60RealtimeAudioBridgeSetOutputVUMeterDemand(false);
    if (benchmark_sink == 123456789.0) puts("unreachable");
    return EXIT_SUCCESS;
}
