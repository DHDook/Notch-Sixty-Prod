#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "N60AdaptiveSampleRate.h"

#define PI 3.14159265358979323846

static int failures = 0;

static void check(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        failures += 1;
    }
}

static N60AdaptiveSRC *make_src(
    double inputRate,
    double outputRate,
    uint32_t channels,
    uint32_t capacity,
    uint32_t target
) {
    N60AdaptiveSRCConfiguration configuration = N60AdaptiveSRCConfigurationMakeDefault(
        inputRate, outputRate, channels, capacity, target
    );
    return N60AdaptiveSRCCreate(configuration);
}

static void test_channel_isolation(uint32_t channels) {
    const uint32_t inputFrames = 12000u;
    const uint32_t outputFrames = 12000u;
    N60AdaptiveSRC *src = make_src(44100.0, 48000.0, channels, 16384u, 1800u);
    check(src != NULL, "create multichannel isolation SRC");
    if (src == NULL) return;

    float *input = calloc((size_t)inputFrames * channels, sizeof(float));
    float *output = calloc((size_t)outputFrames * channels, sizeof(float));
    check(input != NULL && output != NULL, "allocate multichannel isolation buffers");
    if (input == NULL || output == NULL) {
        free(input);
        free(output);
        N60AdaptiveSRCDestroy(src);
        return;
    }

    const uint32_t active = channels > 7u ? 7u : channels - 1u;
    for (uint32_t frame = 0u; frame < inputFrames; ++frame) {
        input[(size_t)frame * channels + active] =
            (float)(0.4 * sin(2.0 * PI * 997.0 * (double)frame / 44100.0));
    }

    check(
        N60AdaptiveSRCPushInterleaved(src, input, inputFrames) == inputFrames,
        "push isolation input"
    );
    const uint32_t produced = N60AdaptiveSRCPullInterleaved(src, output, outputFrames);
    check(produced > 10000u, "multichannel isolation conversion produces expected frames");

    double activeEnergy = 0.0;
    double otherEnergy = 0.0;
    for (uint32_t frame = 1000u; frame < produced; ++frame) {
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            const double value = output[(size_t)frame * channels + channel];
            if (channel == active) activeEnergy += value * value;
            else otherEnergy += value * value;
        }
    }
    check(activeEnergy > 1.0, "active semantic channel carries signal");
    check(otherEnergy < 1.0e-14, "ASRC introduces no inter-channel crosstalk");

    free(input);
    free(output);
    N60AdaptiveSRCDestroy(src);
}

static void test_level_identity(uint32_t channels) {
    const uint32_t inputFrames = 16000u;
    N60AdaptiveSRC *src = make_src(48000.0, 44100.0, channels, 20000u, 2200u);
    check(src != NULL, "create multichannel level SRC");
    if (src == NULL) return;

    float *input = calloc((size_t)inputFrames * channels, sizeof(float));
    const uint32_t outputCapacity = 15000u;
    float *output = calloc((size_t)outputCapacity * channels, sizeof(float));
    if (input == NULL || output == NULL) {
        check(0, "allocate multichannel level buffers");
        free(input);
        free(output);
        N60AdaptiveSRCDestroy(src);
        return;
    }

    for (uint32_t frame = 0u; frame < inputFrames; ++frame) {
        const double base = sin(2.0 * PI * 1200.0 * (double)frame / 48000.0);
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            const double gain = 0.05 + 0.4 * (double)(channel + 1u) / (double)channels;
            input[(size_t)frame * channels + channel] = (float)(gain * base);
        }
    }

    check(
        N60AdaptiveSRCPushInterleaved(src, input, inputFrames) == inputFrames,
        "push multichannel level input"
    );
    const uint32_t produced = N60AdaptiveSRCPullInterleaved(src, output, outputCapacity);
    check(produced > 13000u, "multichannel downsample produces expected frames");

    for (uint32_t channel = 0u; channel < channels; ++channel) {
        double square = 0.0;
        uint32_t count = 0u;
        for (uint32_t frame = 1000u; frame < produced; ++frame) {
            const double value = output[(size_t)frame * channels + channel];
            square += value * value;
            count += 1u;
        }
        const double rms = count > 0u ? sqrt(square / (double)count) : 0.0;
        const double gain = 0.05 + 0.4 * (double)(channel + 1u) / (double)channels;
        const double expected = gain / sqrt(2.0);
        check(fabs(rms - expected) < 0.008, "per-channel level identity is preserved");
    }

    free(input);
    free(output);
    N60AdaptiveSRCDestroy(src);
}

static void test_drift_32_channels(void) {
    const uint32_t channels = 32u;
    const uint32_t outputFrames = 480u;
    const uint32_t target = 1700u;
    const double sourceRate = 44100.0 * (1.0 + 180.0e-6);
    N60AdaptiveSRC *src = make_src(44100.0, 48000.0, channels, 8192u, target);
    check(src != NULL, "create 32-channel drift SRC");
    if (src == NULL) return;

    float *capture = calloc((size_t)444u * channels, sizeof(float));
    float *output = calloc((size_t)outputFrames * channels, sizeof(float));
    if (capture == NULL || output == NULL) {
        check(0, "allocate 32-channel drift buffers");
        free(capture);
        free(output);
        N60AdaptiveSRCDestroy(src);
        return;
    }

    double fractional = 0.0;
    uint64_t sourceFrame = 0u;
    int gateOpen = 0;
    for (uint32_t callback = 0u; callback < 3000u; ++callback) {
        fractional += sourceRate * 0.010;
        uint32_t captureFrames = (uint32_t)floor(fractional);
        fractional -= (double)captureFrames;
        if (captureFrames > 444u) captureFrames = 444u;

        for (uint32_t frame = 0u; frame < captureFrames; ++frame) {
            const float base = (float)(0.15 * sin(
                2.0 * PI * 800.0 * (double)(sourceFrame + frame) / sourceRate
            ));
            for (uint32_t channel = 0u; channel < channels; ++channel) {
                capture[(size_t)frame * channels + channel] =
                    base * (float)(channel + 1u) / (float)channels;
            }
        }
        sourceFrame += captureFrames;
        check(
            N60AdaptiveSRCPushInterleaved(src, capture, captureFrames) == captureFrames,
            "32-channel drift capture does not drop"
        );

        N60AdaptiveSRCSnapshot before = N60AdaptiveSRCGetSnapshot(src);
        if (!gateOpen && before.bufferedFrames >= target + 96u) gateOpen = 1;
        if (!gateOpen) continue;
        check(
            N60AdaptiveSRCPullInterleaved(src, output, outputFrames) == outputFrames,
            "32-channel drift output remains supplied"
        );
    }

    const N60AdaptiveSRCSnapshot snapshot = N60AdaptiveSRCGetSnapshot(src);
    check(snapshot.droppedInputFrames == 0u, "32-channel drift has zero input drops");
    check(snapshot.starvedOutputFrames == 0u, "32-channel drift has zero starvation");
    check(snapshot.correctionPPM > 50.0 && snapshot.correctionPPM < 350.0,
          "32-channel drift correction moves toward source drift");

    free(capture);
    free(output);
    N60AdaptiveSRCDestroy(src);
}

static void test_32_channel_performance_regression(void) {
    const uint32_t channels = 32u;
    const uint32_t inputFrames = 12000u;
    const uint32_t outputFrames = 12000u;
    N60AdaptiveSRC *src = make_src(48000.0, 48000.0 + 1.0, channels, 16384u, 1600u);
    check(src != NULL, "create 32-channel benchmark SRC");
    if (src == NULL) return;

    float *input = calloc((size_t)inputFrames * channels, sizeof(float));
    float *output = calloc((size_t)outputFrames * channels, sizeof(float));
    if (input == NULL || output == NULL) {
        check(0, "allocate benchmark buffers");
        free(input);
        free(output);
        N60AdaptiveSRCDestroy(src);
        return;
    }
    for (uint32_t frame = 0u; frame < inputFrames; ++frame) {
        const float value = (float)(0.1 * sin(2.0 * PI * 1000.0 * (double)frame / 48000.0));
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            input[(size_t)frame * channels + channel] = value;
        }
    }
    check(N60AdaptiveSRCPushInterleaved(src, input, inputFrames) == inputFrames,
          "push benchmark input");
    const clock_t start = clock();
    const uint32_t produced = N60AdaptiveSRCPullInterleaved(src, output, outputFrames);
    const clock_t end = clock();
    const double elapsed = (double)(end - start) / (double)CLOCKS_PER_SEC;
    const double audioDuration = (double)produced / 48001.0;
    printf("32-channel ASRC benchmark: %.6f s CPU for %.6f s audio\n", elapsed, audioDuration);
    check(produced > 11000u, "benchmark produces expected output");
    // Deliberately generous CI regression ceiling. This is not a hardware
    // acceptance claim; it catches accidental order-of-magnitude regressions.
    check(elapsed < audioDuration * 4.0, "32-channel ASRC avoids >4x realtime CPU regression");

    free(input);
    free(output);
    N60AdaptiveSRCDestroy(src);
}

int main(void) {
    test_channel_isolation(6u);
    test_channel_isolation(12u);
    test_channel_isolation(16u);
    test_channel_isolation(32u);
    test_level_identity(12u);
    test_level_identity(32u);
    test_drift_32_channels();
    test_32_channel_performance_regression();

    if (failures != 0) {
        fprintf(stderr, "%d PR71 N-channel ASRC validation failure(s)\n", failures);
        return 1;
    }
    printf("PR71 semantic N-channel ASRC validation passed\n");
    return 0;
}
