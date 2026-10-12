#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#include "../NotchSixty/Audio/Realtime/N60ProgramFIRRuntime.h"

static void assert_near(float actual, float expected, float tolerance) {
    assert(isfinite(actual));
    assert(fabsf(actual - expected) <= tolerance);
}

static void test_sparse_single_channel_impulse_and_passthrough(void) {
    const uint32_t channels = 2u;
    const uint32_t activeMask = 1u << 0u;
    const uint32_t tapsCount = 3u;
    const float taps[] = {0.0f, 1.0f, 0.0f};

    N60ProgramFIRProgram *program =
        N60ProgramFIRProgramCreate(
            channels,
            activeMask,
            taps,
            tapsCount,
            1u
        );
    assert(program != NULL);

    const N60ProgramFIRProgramInfo info =
        N60ProgramFIRProgramGetInfo(program);
    assert(info.prepared);
    assert(info.channelCount == 2u);
    assert(info.activeChannelCount == 1u);
    assert(info.activeChannelMask == activeMask);
    assert(info.engineLatencyFrames
        == N60_CONVOLUTION_PARTITION_FRAMES);
    assert(info.declaredLatencyFrames == 1u);

    N60ProgramFIRRuntime *runtime =
        N60ProgramFIRRuntimeCreate(program);
    assert(runtime != NULL);

    float output[2] = {0};
    const uint32_t expectedImpulseFrame =
        N60_CONVOLUTION_PARTITION_FRAMES + 1u;

    for (uint32_t frame = 0u;
         frame <= expectedImpulseFrame + 2u;
         ++frame) {
        const float input[2] = {
            frame == 0u ? 1.0f : 0.0f,
            frame == 0u ? 0.25f : 0.0f,
        };
        assert(
            N60ProgramFIRRuntimeProcessFrame(
                runtime, input, output
            )
        );

        if (frame == 0u) {
            assert_near(output[1], 0.25f, 1.0e-6f);
        } else {
            assert_near(output[1], 0.0f, 1.0e-6f);
        }

        if (frame == expectedImpulseFrame) {
            assert_near(output[0], 1.0f, 1.0e-5f);
        } else {
            assert_near(output[0], 0.0f, 1.0e-5f);
        }
    }

    N60ProgramFIRRuntimeDestroy(runtime);
    N60ProgramFIRProgramDestroy(program);
}

static void test_multiple_sparse_channels_use_independent_kernels(void) {
    const uint32_t channels = 4u;
    const uint32_t activeMask = (1u << 0u) | (1u << 3u);
    const uint32_t tapCount = 3u;
    // Ascending active-channel order: channel 0 then channel 3.
    const float taps[] = {
        0.0f, 1.0f, 0.0f,
        0.0f, 0.5f, 0.0f,
    };

    N60ProgramFIRProgram *program =
        N60ProgramFIRProgramCreate(
            channels, activeMask, taps, tapCount, 1u
        );
    assert(program != NULL);
    assert(program->activeOrdinalForChannel[0] == 0u);
    assert(program->activeOrdinalForChannel[1]
        == N60_PROGRAM_FIR_INACTIVE_ORDINAL);
    assert(program->activeOrdinalForChannel[2]
        == N60_PROGRAM_FIR_INACTIVE_ORDINAL);
    assert(program->activeOrdinalForChannel[3] == 1u);

    N60ProgramFIRRuntime *runtime =
        N60ProgramFIRRuntimeCreate(program);
    assert(runtime != NULL);

    const uint32_t impulseFrame =
        N60_CONVOLUTION_PARTITION_FRAMES + 1u;
    float output[4] = {0};

    for (uint32_t frame = 0u;
         frame <= impulseFrame;
         ++frame) {
        const float input[4] = {
            frame == 0u ? 1.0f : 0.0f,
            frame == 0u ? 0.1f : 0.0f,
            frame == 0u ? -0.2f : 0.0f,
            frame == 0u ? 1.0f : 0.0f,
        };
        assert(
            N60ProgramFIRRuntimeProcessFrame(
                runtime, input, output
            )
        );
        if (frame == 0u) {
            assert_near(output[1], 0.1f, 1.0e-6f);
            assert_near(output[2], -0.2f, 1.0e-6f);
        }
        if (frame == impulseFrame) {
            assert_near(output[0], 1.0f, 1.0e-5f);
            assert_near(output[3], 0.5f, 1.0e-5f);
        }
    }

    N60ProgramFIRRuntimeDestroy(runtime);
    N60ProgramFIRProgramDestroy(program);
}

static void test_reset_clears_active_history(void) {
    const float taps[] = {1.0f};
    N60ProgramFIRProgram *program =
        N60ProgramFIRProgramCreate(
            2u, 1u, taps, 1u, 0u
        );
    assert(program != NULL);

    N60ProgramFIRRuntime *runtime =
        N60ProgramFIRRuntimeCreate(program);
    assert(runtime != NULL);

    float output[2] = {0};
    for (uint32_t frame = 0u;
         frame < N60_CONVOLUTION_PARTITION_FRAMES;
         ++frame) {
        const float input[2] = {
            frame == 0u ? 1.0f : 0.0f,
            0.0f,
        };
        assert(
            N60ProgramFIRRuntimeProcessFrame(
                runtime, input, output
            )
        );
    }

    N60ProgramFIRRuntimeReset(runtime);
    for (uint32_t frame = 0u;
         frame < N60_CONVOLUTION_PARTITION_FRAMES + 4u;
         ++frame) {
        const float input[2] = {0.0f, 0.0f};
        assert(
            N60ProgramFIRRuntimeProcessFrame(
                runtime, input, output
            )
        );
        assert_near(output[0], 0.0f, 1.0e-6f);
    }

    N60ProgramFIRRuntimeDestroy(runtime);
    N60ProgramFIRProgramDestroy(program);
}

static void test_nonfinite_input_is_sanitized(void) {
    const float taps[] = {1.0f};
    N60ProgramFIRProgram *program =
        N60ProgramFIRProgramCreate(
            2u, 1u, taps, 1u, 0u
        );
    assert(program != NULL);
    N60ProgramFIRRuntime *runtime =
        N60ProgramFIRRuntimeCreate(program);
    assert(runtime != NULL);

    const float input[2] = {NAN, INFINITY};
    float output[2] = {1.0f, 1.0f};
    assert(
        N60ProgramFIRRuntimeProcessFrame(
            runtime, input, output
        )
    );
    assert_near(output[0], 0.0f, 1.0e-6f);
    assert_near(output[1], 0.0f, 1.0e-6f);

    N60ProgramFIRRuntimeDestroy(runtime);
    N60ProgramFIRProgramDestroy(program);
}

static void test_invalid_programs_fail_closed(void) {
    const float tap = 1.0f;

    assert(
        N60ProgramFIRProgramCreate(
            0u, 1u, &tap, 1u, 0u
        ) == NULL
    );
    assert(
        N60ProgramFIRProgramCreate(
            2u, 0u, &tap, 1u, 0u
        ) == NULL
    );
    assert(
        N60ProgramFIRProgramCreate(
            2u, 1u << 2u, &tap, 1u, 0u
        ) == NULL
    );
    assert(
        N60ProgramFIRProgramCreate(
            2u, 1u, &tap, 1u, 1u
        ) == NULL
    );

    const float invalid = NAN;
    assert(
        N60ProgramFIRProgramCreate(
            2u, 1u, &invalid, 1u, 0u
        ) == NULL
    );
}

static void test_memory_scales_with_active_channels_not_layout_width(void) {
    const uint32_t tapCount = 2049u;
    float *taps =
        (float *)calloc(tapCount, sizeof(float));
    assert(taps != NULL);
    taps[(tapCount - 1u) / 2u] = 1.0f;

    N60ProgramFIRProgram *program =
        N60ProgramFIRProgramCreate(
            N60_MAX_PROGRAM_CHANNELS,
            1u << 0u,
            taps,
            tapCount,
            (tapCount - 1u) / 2u
        );
    assert(program != NULL);
    const N60ProgramFIRProgramInfo info =
        N60ProgramFIRProgramGetInfo(program);
    assert(info.activeChannelCount == 1u);
    assert(info.channelCount
        == N60_MAX_PROGRAM_CHANNELS);

    const uint64_t expected =
        (uint64_t)info.partitionCount
        * N60_CONVOLUTION_FFT_SIZE
        * sizeof(N60ProgramFIRComplex);
    assert(info.kernelBytes == expected);
    assert(info.runtimeHistoryBytes == expected);

    N60ProgramFIRProgramDestroy(program);
    free(taps);
}

int main(void) {
    test_sparse_single_channel_impulse_and_passthrough();
    test_multiple_sparse_channels_use_independent_kernels();
    test_reset_clears_active_history();
    test_nonfinite_input_is_sanitized();
    test_invalid_programs_fail_closed();
    test_memory_scales_with_active_channels_not_layout_width();
    puts("PR107 sparse program FIR runtime validation passed");
    return 0;
}
