#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60AdaptiveSampleRate.h"

#define PI 3.14159265358979323846

static int failures = 0;

static void check(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        failures += 1;
    }
}

static void fill_sine(
    float *buffer,
    uint32_t frames,
    double sampleRate,
    double frequency,
    uint64_t startFrame
) {
    for (uint32_t frame = 0; frame < frames; ++frame) {
        double phase = 2.0 * PI * frequency * (double)(startFrame + frame) / sampleRate;
        float value = (float)(0.35 * sin(phase));
        buffer[(size_t)frame * 2u] = value;
        buffer[(size_t)frame * 2u + 1u] = -value;
    }
}

static void accumulate_output(
    const float *buffer,
    uint32_t frames,
    double *squareSum,
    uint64_t *sampleCount,
    uint64_t *positiveCrossings,
    float *previous
) {
    for (uint32_t frame = 0; frame < frames; ++frame) {
        float value = buffer[(size_t)frame * 2u];
        *squareSum += (double)value * (double)value;
        *sampleCount += 1u;
        if (*previous <= 0.0f && value > 0.0f) *positiveCrossings += 1u;
        *previous = value;
    }
}

static N60AdaptiveSRC *make_src(uint32_t target) {
    N60AdaptiveSRCConfiguration configuration = N60AdaptiveSRCConfigurationMakeDefault(
        44100.0, 48000.0, 2u, 8192u, target
    );
    return N60AdaptiveSRCCreate(configuration);
}

static void test_nominal_callback_cadence(void) {
    const uint32_t captureFrames = 441u;
    const uint32_t outputFrames = 480u;
    const uint32_t target = 1100u;
    N60AdaptiveSRC *src = make_src(target);
    check(src != NULL, "create nominal stereo transport");
    if (src == NULL) return;

    float *capture = calloc((size_t)captureFrames * 2u, sizeof(float));
    float *output = calloc((size_t)outputFrames * 2u, sizeof(float));
    check(capture != NULL && output != NULL, "allocate nominal callback buffers");
    if (capture == NULL || output == NULL) {
        free(capture);
        free(output);
        N60AdaptiveSRCDestroy(src);
        return;
    }

    uint64_t inputFrame = 0u;
    double squareSum = 0.0;
    uint64_t sampleCount = 0u;
    uint64_t positiveCrossings = 0u;
    float previous = 0.0f;
    int gateOpen = 0;

    for (uint32_t callback = 0u; callback < 3000u; ++callback) {
        fill_sine(capture, captureFrames, 44100.0, 997.0, inputFrame);
        inputFrame += captureFrames;
        uint32_t accepted = N60AdaptiveSRCPushInterleaved(src, capture, captureFrames);
        check(accepted == captureFrames, "nominal capture callback has no drop");

        N60AdaptiveSRCSnapshot before = N60AdaptiveSRCGetSnapshot(src);
        if (callback == 0u) {
            check(before.bufferedFrames == captureFrames,
                  "producer publishes startup fill before first consumer pull");
        }
        if (!gateOpen && before.bufferedFrames >= target + 96u) gateOpen = 1;
        if (!gateOpen) continue;

        uint32_t produced = N60AdaptiveSRCPullInterleaved(src, output, outputFrames);
        check(produced == outputFrames, "nominal output callback remains fully supplied");
        if (callback > 250u && produced == outputFrames) {
            accumulate_output(
                output, produced, &squareSum, &sampleCount, &positiveCrossings, &previous
            );
        }
    }

    N60AdaptiveSRCSnapshot snapshot = N60AdaptiveSRCGetSnapshot(src);
    check(snapshot.droppedInputFrames == 0u, "nominal transport reports zero dropped input frames");
    check(snapshot.starvedOutputFrames == 0u, "nominal transport reports zero starved output frames");
    check(snapshot.bufferedFrames > 300u && snapshot.bufferedFrames < 2500u,
          "nominal controller keeps bounded transport fill");

    if (sampleCount > 0u) {
        double rms = sqrt(squareSum / (double)sampleCount);
        double duration = (double)sampleCount / 48000.0;
        double estimatedFrequency = duration > 0.0 ? (double)positiveCrossings / duration : 0.0;
        check(fabs(rms - (0.35 / sqrt(2.0))) < 0.012, "callback simulation preserves level");
        check(fabs(estimatedFrequency - 997.0) < 2.0, "callback simulation preserves frequency");
    } else {
        check(0, "nominal callback simulation produced analysis samples");
    }

    free(capture);
    free(output);
    N60AdaptiveSRCDestroy(src);
}

static void test_independent_clock_drift(void) {
    const uint32_t outputFrames = 480u;
    const uint32_t target = 1200u;
    const double driftPPM = 220.0;
    const double effectiveInputRate = 44100.0 * (1.0 + driftPPM * 1.0e-6);
    N60AdaptiveSRC *src = make_src(target);
    check(src != NULL, "create drift stereo transport");
    if (src == NULL) return;

    float *capture = calloc(444u * 2u, sizeof(float));
    float *output = calloc((size_t)outputFrames * 2u, sizeof(float));
    if (capture == NULL || output == NULL) {
        check(0, "allocate drift callback buffers");
        free(capture);
        free(output);
        N60AdaptiveSRCDestroy(src);
        return;
    }

    uint64_t inputFrame = 0u;
    double fractionalInputFrames = 0.0;
    int gateOpen = 0;
    for (uint32_t callback = 0u; callback < 6000u; ++callback) {
        fractionalInputFrames += effectiveInputRate * 0.010;
        uint32_t captureFrames = (uint32_t)floor(fractionalInputFrames);
        fractionalInputFrames -= (double)captureFrames;
        if (captureFrames > 444u) captureFrames = 444u;

        fill_sine(capture, captureFrames, effectiveInputRate, 1000.0, inputFrame);
        inputFrame += captureFrames;
        check(
            N60AdaptiveSRCPushInterleaved(src, capture, captureFrames) == captureFrames,
            "drifting capture clock does not overrun"
        );

        N60AdaptiveSRCSnapshot before = N60AdaptiveSRCGetSnapshot(src);
        if (!gateOpen && before.bufferedFrames >= target + 96u) gateOpen = 1;
        if (!gateOpen) continue;
        uint32_t produced = N60AdaptiveSRCPullInterleaved(src, output, outputFrames);
        check(produced == outputFrames, "adaptive controller supplies drifting output clock");
    }

    N60AdaptiveSRCSnapshot snapshot = N60AdaptiveSRCGetSnapshot(src);
    check(snapshot.droppedInputFrames == 0u, "drift simulation has no input drops");
    check(snapshot.starvedOutputFrames == 0u, "drift simulation has no output starvation");
    check(snapshot.correctionPPM > 80.0 && snapshot.correctionPPM < 400.0,
          "controller moves in the expected direction for faster source clock");
    check(snapshot.bufferedFrames > 400u && snapshot.bufferedFrames < 2600u,
          "drift controller keeps fill bounded around target");

    free(capture);
    free(output);
    N60AdaptiveSRCDestroy(src);
}

static void test_independent_callback_schedule(void) {
    const uint32_t blockFrames = 512u;
    const double inputRate = 44100.0;
    const double outputRate = 48000.0;
    const uint32_t lookahead = N60_ADAPTIVE_SRC_DEFAULT_TAPS / 2u;
    const uint32_t inputFramesPerOutputBuffer =
        (uint32_t)ceil((double)blockFrames * inputRate / outputRate);
    const uint32_t target =
        inputFramesPerOutputBuffer * 2u + lookahead * 2u;
    const uint32_t activation =
        target + inputFramesPerOutputBuffer + lookahead;
    const double sourceDriftPPM = 180.0;
    const double physicalInputRate = inputRate * (1.0 + sourceDriftPPM * 1.0e-6);

    N60AdaptiveSRCConfiguration configuration = N60AdaptiveSRCConfigurationMakeDefault(
        inputRate, outputRate, 2u, 16384u, target
    );
    N60AdaptiveSRC *src = N60AdaptiveSRCCreate(configuration);
    check(src != NULL, "create independently scheduled callback transport");
    if (src == NULL) return;

    float *capture = calloc((size_t)blockFrames * 2u, sizeof(float));
    float *output = calloc((size_t)blockFrames * 2u, sizeof(float));
    if (capture == NULL || output == NULL) {
        check(0, "allocate independently scheduled callback buffers");
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
    uint64_t inputFrame = 0u;
    uint64_t suppliedOutputCallbacks = 0u;
    int gateOpen = 0;

    while (nextCapture < endTime || nextOutput < endTime) {
        if (nextCapture <= nextOutput && nextCapture < endTime) {
            fill_sine(capture, blockFrames, physicalInputRate, 733.0, inputFrame);
            inputFrame += blockFrames;
            check(
                N60AdaptiveSRCPushInterleaved(src, capture, blockFrames) == blockFrames,
                "independent capture callback does not overrun"
            );
            if (!gateOpen) {
                N60AdaptiveSRCSnapshot snapshot = N60AdaptiveSRCGetSnapshot(src);
                if (snapshot.bufferedFrames >= activation) gateOpen = 1;
            }
            nextCapture += capturePeriod;
        } else if (nextOutput < endTime) {
            if (gateOpen) {
                uint32_t produced = N60AdaptiveSRCPullInterleaved(src, output, blockFrames);
                check(produced == blockFrames,
                      "independently scheduled output callback remains fully supplied");
                if (produced == blockFrames) suppliedOutputCallbacks += 1u;
            }
            nextOutput += outputPeriod;
        } else {
            break;
        }
    }

    N60AdaptiveSRCSnapshot snapshot = N60AdaptiveSRCGetSnapshot(src);
    check(suppliedOutputCallbacks > 5000u,
          "independent callback simulation sustains long-run output");
    check(snapshot.droppedInputFrames == 0u,
          "independent callback simulation has no input drops");
    check(snapshot.starvedOutputFrames == 0u,
          "independent callback simulation has no output starvation");
    check(snapshot.correctionPPM > 50.0 && snapshot.correctionPPM < 350.0,
          "independent callback controller tracks faster source clock");
    check(snapshot.bufferedFrames > lookahead * 2u
              && snapshot.bufferedFrames < target * 3u,
          "independent callback fill remains bounded");

    free(capture);
    free(output);
    N60AdaptiveSRCDestroy(src);
}

static void test_starvation_reset_and_reprime(void) {
    const uint32_t target = 900u;
    N60AdaptiveSRC *src = make_src(target);
    check(src != NULL, "create recovery stereo transport");
    if (src == NULL) return;

    float *capture = calloc(1600u * 2u, sizeof(float));
    float *output = calloc(480u * 2u, sizeof(float));
    fill_sine(capture, 1600u, 44100.0, 500.0, 0u);
    check(N60AdaptiveSRCPushInterleaved(src, capture, 1600u) == 1600u, "prime recovery transport");

    for (uint32_t index = 0u; index < 8u; ++index) {
        (void)N60AdaptiveSRCPullInterleaved(src, output, 480u);
    }
    N60AdaptiveSRCSnapshot starved = N60AdaptiveSRCGetSnapshot(src);
    check(starved.starvedOutputFrames > 0u, "starvation is observable before relock");

    N60AdaptiveSRCReset(src);
    N60AdaptiveSRCSnapshot reset = N60AdaptiveSRCGetSnapshot(src);
    check(reset.starvedOutputFrames == 0u, "control-plane reset clears starvation telemetry");
    check(fabs(reset.correctionPPM) < 1.0e-9, "control-plane reset clears clock correction");
    check(reset.bufferedFrames == 0u, "control-plane reset clears buffered frames");

    fill_sine(capture, 1600u, 44100.0, 500.0, 1600u);
    check(N60AdaptiveSRCPushInterleaved(src, capture, 1600u) == 1600u, "re-prime after reset");
    uint32_t produced = N60AdaptiveSRCPullInterleaved(src, output, 480u);
    check(produced == 480u, "transport resumes after reset and re-prime");

    free(capture);
    free(output);
    N60AdaptiveSRCDestroy(src);
}

int main(void) {
    test_nominal_callback_cadence();
    test_independent_clock_drift();
    test_independent_callback_schedule();
    test_starvation_reset_and_reprime();
    if (failures != 0) {
        fprintf(stderr, "%d PR70 stereo transport simulation failure(s)\n", failures);
        return 1;
    }
    printf("PR70 stereo adaptive-SRC transport simulation passed\n");
    return 0;
}
