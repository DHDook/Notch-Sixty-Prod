#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "N60MIMOFIRRuntime.h"

static void set_tap(
    float *taps,
    uint32_t channels,
    uint32_t tapCount,
    uint32_t output,
    uint32_t input,
    uint32_t tap,
    float value
) {
    taps[N60MIMOFIRTapOffset(
        channels, tapCount, output, input, tap
    )] = value;
}

static void test_exact_matrix_impulse(void) {
    const uint32_t channels = 2u;
    const uint32_t tapCount = 3u;
    float taps[2u * 2u * 3u] = {0};

    set_tap(taps, channels, tapCount, 0u, 0u, 0u, 1.0f);
    set_tap(taps, channels, tapCount, 0u, 1u, 1u, 0.5f);
    set_tap(taps, channels, tapCount, 1u, 0u, 2u, -0.25f);
    set_tap(taps, channels, tapCount, 1u, 1u, 0u, 1.0f);

    N60MIMOFIRProgram *program =
        N60MIMOFIRProgramCreate(channels, taps, tapCount, 0u);
    assert(program != NULL);
    N60MIMOFIRProgramInfo info = N60MIMOFIRProgramGetInfo(program);
    assert(info.prepared);
    assert(info.channelCount == 2u);
    assert(info.tapCount == 3u);
    assert(info.partitionCount == 1u);
    assert(info.engineLatencyFrames == 256u);

    N60MIMOFIRRuntime *runtime = N60MIMOFIRRuntimeCreate(program);
    assert(runtime != NULL);

    float input[2] = {0};
    float output[2] = {0};
    for (uint32_t frame = 0u; frame < 262u; ++frame) {
        input[0] = frame == 0u ? 1.0f : 0.0f;
        input[1] = 0.0f;
        assert(N60MIMOFIRRuntimeProcessFrame(runtime, input, output));
        if (frame < 256u) {
            assert(fabsf(output[0]) < 1.0e-5f);
            assert(fabsf(output[1]) < 1.0e-5f);
        } else if (frame == 256u) {
            assert(fabsf(output[0] - 1.0f) < 1.0e-5f);
            assert(fabsf(output[1]) < 1.0e-5f);
        } else if (frame == 258u) {
            assert(fabsf(output[0]) < 1.0e-5f);
            assert(fabsf(output[1] + 0.25f) < 1.0e-5f);
        }
    }

    N60MIMOFIRRuntimeReset(runtime);
    for (uint32_t frame = 0u; frame < 260u; ++frame) {
        input[0] = 0.0f;
        input[1] = frame == 0u ? 1.0f : 0.0f;
        assert(N60MIMOFIRRuntimeProcessFrame(runtime, input, output));
        if (frame == 256u) {
            assert(fabsf(output[0]) < 1.0e-5f);
            assert(fabsf(output[1] - 1.0f) < 1.0e-5f);
        } else if (frame == 257u) {
            assert(fabsf(output[0] - 0.5f) < 1.0e-5f);
            assert(fabsf(output[1]) < 1.0e-5f);
        }
    }

    N60MIMOFIRRuntimeDestroy(runtime);
    N60MIMOFIRProgramDestroy(program);
}

static void test_nonfinite_input_is_sanitized(void) {
    float taps[1] = {1.0f};
    N60MIMOFIRProgram *program =
        N60MIMOFIRProgramCreate(1u, taps, 1u, 0u);
    assert(program != NULL);
    N60MIMOFIRRuntime *runtime = N60MIMOFIRRuntimeCreate(program);
    assert(runtime != NULL);

    float input[1] = {NAN};
    float output[1] = {123.0f};
    for (uint32_t frame = 0u; frame < 300u; ++frame) {
        assert(N60MIMOFIRRuntimeProcessFrame(runtime, input, output));
        assert(isfinite(output[0]));
        assert(fabsf(output[0]) < 1.0e-6f);
    }

    N60MIMOFIRRuntimeDestroy(runtime);
    N60MIMOFIRProgramDestroy(program);
}

static void test_four_channel_4096_tap_regression(void) {
    const uint32_t channels = 4u;
    const uint32_t tapCount = 4096u;
    const size_t sampleCount =
        (size_t)channels * channels * tapCount;
    float *taps = (float *)calloc(sampleCount, sizeof(float));
    assert(taps != NULL);

    // Dense but bounded four-actuator matrix. Keeping non-zero off-diagonal
    // paths ensures the reference runtime exercises its complete matrix loops.
    for (uint32_t output = 0u; output < channels; ++output) {
        for (uint32_t input = 0u; input < channels; ++input) {
            const float scale = output == input ? 0.86f : 0.08f;
            for (uint32_t tap = 0u; tap < tapCount; ++tap) {
                const double distance =
                    fabs((double)tap - 2048.0);
                const double envelope = exp(-distance / 420.0);
                const double oscillation =
                    cos((double)tap * (0.0025 + 0.0003 * (output + input)));
                set_tap(
                    taps,
                    channels,
                    tapCount,
                    output,
                    input,
                    tap,
                    (float)(scale * envelope * oscillation * 0.001)
                );
            }
            taps[N60MIMOFIRTapOffset(
                channels,
                tapCount,
                output,
                input,
                2048u
            )] += output == input ? 0.75f : 0.03f;
        }
    }

    N60MIMOFIRProgram *program =
        N60MIMOFIRProgramCreate(
            channels,
            taps,
            tapCount,
            2048u
        );
    assert(program != NULL);
    N60MIMOFIRProgramInfo info = N60MIMOFIRProgramGetInfo(program);
    assert(info.partitionCount == 16u);
    assert(info.kernelBytes > 0u);
    assert(info.runtimeHistoryBytes > 0u);

    N60MIMOFIRRuntime *runtime = N60MIMOFIRRuntimeCreate(program);
    assert(runtime != NULL);

    float input[4] = {0};
    float output[4] = {0};
    const uint32_t frames = 8192u;
    const clock_t start = clock();
    for (uint32_t frame = 0u; frame < frames; ++frame) {
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            input[channel] = (float)(
                0.05 * sin(
                    2.0 * 3.14159265358979323846
                    * (80.0 + 17.0 * channel)
                    * (double)frame
                    / 48000.0
                )
            );
        }
        assert(N60MIMOFIRRuntimeProcessFrame(runtime, input, output));
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            assert(isfinite(output[channel]));
        }
    }
    const clock_t end = clock();
    const double elapsed =
        (double)(end - start) / (double)CLOCKS_PER_SEC;
    const double audioDuration = (double)frames / 48000.0;
    printf(
        "PR74 4x4/4096 matrix FIR: %.6f s CPU for %.6f s audio\n",
        elapsed,
        audioDuration
    );
    // Generous CI regression ceiling only. This is not a production CPU claim.
    assert(elapsed < audioDuration * 12.0);

    N60MIMOFIRRuntimeDestroy(runtime);
    N60MIMOFIRProgramDestroy(program);
    free(taps);
}

static void test_invalid_programs_fail_closed(void) {
    float taps[1] = {1.0f};
    assert(N60MIMOFIRProgramCreate(0u, taps, 1u, 0u) == NULL);
    assert(N60MIMOFIRProgramCreate(5u, taps, 1u, 0u) == NULL);
    assert(N60MIMOFIRProgramCreate(1u, taps, 0u, 0u) == NULL);
    assert(N60MIMOFIRProgramCreate(
        1u, taps, N60_MIMO_FIR_MAX_TAPS + 1u, 0u
    ) == NULL);
    assert(N60MIMOFIRProgramCreate(1u, taps, 1u, 1u) == NULL);
}

int main(void) {
    test_exact_matrix_impulse();
    test_nonfinite_input_is_sanitized();
    test_four_channel_4096_tap_regression();
    test_invalid_programs_fail_closed();
    printf("PR74 MIMO matrix FIR runtime validation passed\n");
    return 0;
}
