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
    const uint32_t blockFrames = 480u;
    const double inputRate = 44100.0;
    const double outputRate = 48000.0;
    const uint32_t lookahead = N60_ADAPTIVE_SRC_DEFAULT_TAPS / 2u;
    const uint32_t inputFramesPerOutputBuffer =
        (uint32_t)ceil((double)blockFrames * inputRate / outputRate);
    const uint32_t target =
        inputFramesPerOutputBuffer * 3u + lookahead * 2u;
    const uint32_t activation =
        target + inputFramesPerOutputBuffer + lookahead;
    const double driftPPM = 180.0;
    const double physicalInputRate = inputRate * (1.0 + driftPPM * 1.0e-6);

    N60AdaptiveSRC *src = make_src(inputRate, outputRate, channels, 8192u, target);
    check(src != NULL, "create 32-channel drift SRC");
    if (src == NULL) return;

    float *capture = calloc((size_t)blockFrames * channels, sizeof(float));
    float *output = calloc((size_t)blockFrames * channels, sizeof(float));
    if (capture == NULL || output == NULL) {
        check(0, "allocate 32-channel drift buffers");
        free(capture);
        free(output);
        N60AdaptiveSRCDestroy(src);
        return;
    }

    const double capturePeriod = (double)blockFrames / physicalInputRate;
    const double outputPeriod = (double)blockFrames / outputRate;
    double nextCapture = 0.0;
    double nextOutput = 0.0;
    const double endTime = 60.0;
    uint64_t sourceFrame = 0u;
    uint64_t suppliedOutputCallbacks = 0u;
    int gateOpen = 0;

    while (nextCapture < endTime || nextOutput < endTime) {
        if (nextCapture <= nextOutput && nextCapture < endTime) {
            for (uint32_t frame = 0u; frame < blockFrames; ++frame) {
                const float base = (float)(0.15 * sin(
                    2.0 * PI * 800.0 * (double)(sourceFrame + frame) / physicalInputRate
                ));
                for (uint32_t channel = 0u; channel < channels; ++channel) {
                    capture[(size_t)frame * channels + channel] =
                        base * (float)(channel + 1u) / (float)channels;
                }
            }
            sourceFrame += blockFrames;
            check(
                N60AdaptiveSRCPushInterleaved(src, capture, blockFrames) == blockFrames,
                "32-channel independent capture callback does not overrun"
            );
            if (!gateOpen) {
                const N60AdaptiveSRCSnapshot snapshot = N60AdaptiveSRCGetSnapshot(src);
                if (snapshot.bufferedFrames >= activation) gateOpen = 1;
            }
            nextCapture += capturePeriod;
        } else if (nextOutput < endTime) {
            if (gateOpen) {
                const uint32_t produced =
                    N60AdaptiveSRCPullInterleaved(src, output, blockFrames);
                check(produced == blockFrames,
                      "32-channel independent output callback remains fully supplied");
                if (produced == blockFrames) suppliedOutputCallbacks += 1u;
            }
            nextOutput += outputPeriod;
        } else {
            break;
        }
    }

    const N60AdaptiveSRCSnapshot snapshot = N60AdaptiveSRCGetSnapshot(src);
    printf(
        "32-channel drift: correction %.2f ppm, fill %u/%u, output callbacks %llu\n",
        snapshot.correctionPPM,
        snapshot.bufferedFrames,
        snapshot.targetBufferedFrames,
        (unsigned long long)suppliedOutputCallbacks
    );
    check(snapshot.droppedInputFrames == 0u, "32-channel drift has zero input drops");
    check(snapshot.starvedOutputFrames == 0u, "32-channel drift has zero starvation");
    check(snapshot.correctionPPM > 50.0 && snapshot.correctionPPM < 400.0,
          "32-channel drift correction converges toward faster source clock");
    check(snapshot.bufferedFrames > 300u && snapshot.bufferedFrames < 2600u,
          "32-channel drift keeps buffer fill bounded");
    check(suppliedOutputCallbacks > 5900u,
          "32-channel independent schedule sustains expected output callbacks");

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
