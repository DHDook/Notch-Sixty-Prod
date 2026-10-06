#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "N60MIMOTreatmentTransition.h"

static N60MIMOFIRProgram *make_gain_program(
    uint32_t channels,
    uint32_t tapCount,
    uint32_t delay,
    float diagonalGain,
    float crossGain
) {
    const size_t count = (size_t)channels * channels * tapCount;
    float *taps = (float *)calloc(count, sizeof(float));
    assert(taps != NULL);
    for (uint32_t output = 0u; output < channels; ++output) {
        for (uint32_t input = 0u; input < channels; ++input) {
            taps[N60MIMOFIRTapOffset(
                channels,
                tapCount,
                output,
                input,
                delay
            )] = output == input ? diagonalGain : crossGain;
        }
    }
    N60MIMOFIRProgram *program = N60MIMOFIRProgramCreate(
        channels,
        taps,
        tapCount,
        delay
    );
    free(taps);
    return program;
}

static void warm_constant(
    N60MIMOTreatmentTransitionRuntime *runtime,
    uint32_t channels,
    uint32_t frames,
    float value,
    float *output
) {
    float input[N60_MIMO_FIR_MAX_CHANNELS] = {0};
    for (uint32_t channel = 0u; channel < channels; ++channel) {
        input[channel] = value;
    }
    for (uint32_t frame = 0u; frame < frames; ++frame) {
        assert(N60MIMOTreatmentTransitionProcessFrame(
            runtime,
            input,
            output
        ));
    }
}

static void test_authorized_arm_bypass_and_fault_fades(void) {
    N60MIMOFIRProgram *program =
        make_gain_program(1u, 512u, 256u, 0.5f, 0.0f);
    assert(program != NULL);

    N60MIMOTreatmentTransitionRuntime *runtime =
        N60MIMOTreatmentTransitionRuntimeCreate(program, 4u, 2u);
    assert(runtime != NULL);
    assert(N60MIMOTreatmentTransitionAtomicsAreLockFree(runtime));

    N60MIMOTreatmentTransitionSnapshot snapshot =
        N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.state == N60MIMOTreatmentStateBypassed);
    assert(snapshot.fault == N60MIMOTreatmentFaultNone);
    assert(snapshot.totalLatencyFrames == 512u);
    assert(snapshot.treatmentMix == 0.0f);
    assert(!N60MIMOTreatmentTransitionRequestArm(runtime));

    float output[1] = {0};
    warm_constant(runtime, 1u, 700u, 1.0f, output);
    assert(fabsf(output[0] - 1.0f) < 1.0e-4f);

    N60MIMOTreatmentTransitionSetAuthorized(runtime, true);
    assert(N60MIMOTreatmentTransitionRequestArm(runtime));

    float input[1] = {1.0f};
    const float expectedArm[4] = {
        0.921875f,
        0.75f,
        0.578125f,
        0.5f,
    };
    for (uint32_t index = 0u; index < 4u; ++index) {
        assert(N60MIMOTreatmentTransitionProcessFrame(
            runtime,
            input,
            output
        ));
        assert(fabsf(output[0] - expectedArm[index]) < 1.0e-4f);
    }
    snapshot = N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.state == N60MIMOTreatmentStateActive);
    assert(fabsf(snapshot.treatmentMix - 1.0f) < 1.0e-6f);

    N60MIMOTreatmentTransitionRequestBypass(runtime);
    const float expectedBypass[4] = {
        0.578125f,
        0.75f,
        0.921875f,
        1.0f,
    };
    for (uint32_t index = 0u; index < 4u; ++index) {
        assert(N60MIMOTreatmentTransitionProcessFrame(
            runtime,
            input,
            output
        ));
        assert(fabsf(output[0] - expectedBypass[index]) < 1.0e-4f);
    }
    snapshot = N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.state == N60MIMOTreatmentStateBypassed);
    assert(fabsf(snapshot.treatmentMix) < 1.0e-6f);

    assert(N60MIMOTreatmentTransitionRequestArm(runtime));
    for (uint32_t index = 0u; index < 4u; ++index) {
        assert(N60MIMOTreatmentTransitionProcessFrame(
            runtime,
            input,
            output
        ));
    }
    assert(N60MIMOTreatmentTransitionLatchFault(
        runtime,
        N60MIMOTreatmentFaultProtection
    ));
    assert(N60MIMOTreatmentTransitionProcessFrame(runtime, input, output));
    assert(fabsf(output[0] - 0.75f) < 1.0e-4f);
    assert(N60MIMOTreatmentTransitionProcessFrame(runtime, input, output));
    assert(fabsf(output[0] - 1.0f) < 1.0e-4f);
    snapshot = N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.state == N60MIMOTreatmentStateFaulted);
    assert(snapshot.fault == N60MIMOTreatmentFaultProtection);
    assert(fabsf(snapshot.treatmentMix) < 1.0e-6f);

    N60MIMOTreatmentTransitionRequestBypass(runtime);
    N60MIMOTreatmentTransitionRequestFaultClear(runtime);
    assert(N60MIMOTreatmentTransitionProcessFrame(runtime, input, output));
    snapshot = N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.state == N60MIMOTreatmentStateBypassed);
    assert(snapshot.fault == N60MIMOTreatmentFaultNone);

    N60MIMOTreatmentTransitionRuntimeDestroy(runtime);
    N60MIMOFIRProgramDestroy(program);
}

static void test_authorization_revocation_fails_to_identity(void) {
    N60MIMOFIRProgram *program =
        make_gain_program(1u, 512u, 256u, 0.4f, 0.0f);
    assert(program != NULL);
    N60MIMOTreatmentTransitionRuntime *runtime =
        N60MIMOTreatmentTransitionRuntimeCreate(program, 4u, 2u);
    assert(runtime != NULL);

    float output[1] = {0};
    warm_constant(runtime, 1u, 700u, 1.0f, output);
    N60MIMOTreatmentTransitionSetAuthorized(runtime, true);
    assert(N60MIMOTreatmentTransitionRequestArm(runtime));

    float input[1] = {1.0f};
    for (uint32_t index = 0u; index < 4u; ++index) {
        assert(N60MIMOTreatmentTransitionProcessFrame(
            runtime,
            input,
            output
        ));
    }
    N60MIMOTreatmentTransitionSetAuthorized(runtime, false);
    assert(N60MIMOTreatmentTransitionProcessFrame(runtime, input, output));
    N60MIMOTreatmentTransitionSnapshot snapshot =
        N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.state == N60MIMOTreatmentStateFaultFading);
    assert(snapshot.fault == N60MIMOTreatmentFaultAuthorizationRevoked);
    assert(snapshot.treatmentMix > 0.0f && snapshot.treatmentMix < 1.0f);

    assert(N60MIMOTreatmentTransitionProcessFrame(runtime, input, output));
    snapshot = N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.state == N60MIMOTreatmentStateFaulted);
    assert(fabsf(snapshot.treatmentMix) < 1.0e-6f);
    assert(fabsf(output[0] - 1.0f) < 1.0e-4f);

    N60MIMOTreatmentTransitionRuntimeDestroy(runtime);
    N60MIMOFIRProgramDestroy(program);
}

static void test_fault_while_bypassed_never_adds_treatment(void) {
    N60MIMOFIRProgram *program =
        make_gain_program(2u, 512u, 256u, 0.6f, 0.1f);
    assert(program != NULL);
    N60MIMOTreatmentTransitionRuntime *runtime =
        N60MIMOTreatmentTransitionRuntimeCreate(program, 64u, 16u);
    assert(runtime != NULL);

    assert(N60MIMOTreatmentTransitionLatchFault(
        runtime,
        N60MIMOTreatmentFaultMeasurementInvalid
    ));
    float input[2] = {0.5f, -0.25f};
    float output[2] = {0};
    for (uint32_t frame = 0u; frame < 800u; ++frame) {
        assert(N60MIMOTreatmentTransitionProcessFrame(
            runtime,
            input,
            output
        ));
    }
    N60MIMOTreatmentTransitionSnapshot snapshot =
        N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.state == N60MIMOTreatmentStateFaulted);
    assert(snapshot.fault == N60MIMOTreatmentFaultMeasurementInvalid);
    assert(fabsf(snapshot.treatmentMix) < 1.0e-6f);
    assert(fabsf(output[0] - input[0]) < 1.0e-4f);
    assert(fabsf(output[1] - input[1]) < 1.0e-4f);

    N60MIMOTreatmentTransitionRuntimeDestroy(runtime);
    N60MIMOFIRProgramDestroy(program);
}

static void test_reset_revokes_authorization(void) {
    N60MIMOFIRProgram *program =
        make_gain_program(1u, 512u, 256u, 0.8f, 0.0f);
    assert(program != NULL);
    N60MIMOTreatmentTransitionRuntime *runtime =
        N60MIMOTreatmentTransitionRuntimeCreate(program, 32u, 8u);
    assert(runtime != NULL);
    N60MIMOTreatmentTransitionSetAuthorized(runtime, true);
    assert(N60MIMOTreatmentTransitionRequestArm(runtime));
    N60MIMOTreatmentTransitionRuntimeReset(runtime);

    const N60MIMOTreatmentTransitionSnapshot snapshot =
        N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.state == N60MIMOTreatmentStateBypassed);
    assert(!snapshot.authorized);
    assert(!snapshot.armRequested);
    assert(snapshot.fault == N60MIMOTreatmentFaultNone);
    assert(!N60MIMOTreatmentTransitionRequestArm(runtime));

    N60MIMOTreatmentTransitionRuntimeDestroy(runtime);
    N60MIMOFIRProgramDestroy(program);
}

static void test_dual_runtime_four_by_four_regression(void) {
    const uint32_t channels = 4u;
    const uint32_t tapCount = 4096u;
    const uint32_t delay = 2048u;
    const size_t count = (size_t)channels * channels * tapCount;
    float *taps = (float *)calloc(count, sizeof(float));
    assert(taps != NULL);

    for (uint32_t output = 0u; output < channels; ++output) {
        for (uint32_t input = 0u; input < channels; ++input) {
            taps[N60MIMOFIRTapOffset(
                channels,
                tapCount,
                output,
                input,
                delay
            )] = output == input ? 0.82f : 0.04f;
        }
    }

    N60MIMOFIRProgram *program = N60MIMOFIRProgramCreate(
        channels,
        taps,
        tapCount,
        delay
    );
    free(taps);
    assert(program != NULL);

    N60MIMOTreatmentTransitionRuntime *runtime =
        N60MIMOTreatmentTransitionRuntimeCreate(
            program,
            2048u,
            512u
        );
    assert(runtime != NULL);
    N60MIMOTreatmentTransitionSetAuthorized(runtime, true);
    assert(N60MIMOTreatmentTransitionRequestArm(runtime));

    float input[4] = {0};
    float output[4] = {0};
    const uint32_t frames = 8192u;
    const clock_t start = clock();
    for (uint32_t frame = 0u; frame < frames; ++frame) {
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            input[channel] = (float)(
                0.04 * sin(
                    2.0 * 3.14159265358979323846
                    * (55.0 + 19.0 * channel)
                    * (double)frame
                    / 48000.0
                )
            );
        }
        assert(N60MIMOTreatmentTransitionProcessFrame(
            runtime,
            input,
            output
        ));
        for (uint32_t channel = 0u; channel < channels; ++channel) {
            assert(isfinite(output[channel]));
        }
    }
    const clock_t end = clock();
    const double elapsed =
        (double)(end - start) / (double)CLOCKS_PER_SEC;
    const double audioDuration = (double)frames / 48000.0;
    printf(
        "PR76 dual 4x4/4096 transition: %.6f s CPU for %.6f s audio\n",
        elapsed,
        audioDuration
    );
    // Deliberately generous regression ceiling, not a hardware acceptance claim.
    assert(elapsed < audioDuration * 24.0);

    const N60MIMOTreatmentTransitionSnapshot snapshot =
        N60MIMOTreatmentTransitionGetSnapshot(runtime);
    assert(snapshot.hardRuntimeFailures == 0u);
    assert(snapshot.processedFrames == frames);
    assert(snapshot.totalLatencyFrames == 2304u);

    N60MIMOTreatmentTransitionRuntimeDestroy(runtime);
    N60MIMOFIRProgramDestroy(program);
}

int main(void) {
    test_authorized_arm_bypass_and_fault_fades();
    test_authorization_revocation_fails_to_identity();
    test_fault_while_bypassed_never_adds_treatment();
    test_reset_revokes_authorization();
    test_dual_runtime_four_by_four_regression();
    printf("PR76 treatment transition validation passed\n");
    return 0;
}
