/*
 * PR117B FIR reference probe.
 * Production partitioned FIR runtime versus offline Python direct convolution.
 * No audio devices, no realtime allocations during ProcessFrame, no datasets.
 */
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60ProgramFIRRuntime.h"

int main(void) {
    const float fir[5] = {0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f};
    N60ProgramFIRProgram *program =
        N60ProgramFIRProgramCreate(2u, 1u, fir, 5u, 2u);
    assert(program != NULL);
    N60ProgramFIRProgramInfo info = N60ProgramFIRProgramGetInfo(program);
    assert(info.prepared && info.channelCount == 2u);
    assert(info.activeChannelCount == 1u && info.activeChannelMask == 1u);
    assert(info.engineLatencyFrames == N60_CONVOLUTION_PARTITION_FRAMES);
    assert(info.declaredLatencyFrames == 2u);
    printf("FIRINFO %u %u %u %u\n", info.engineLatencyFrames,
           info.declaredLatencyFrames, info.tapCount,
           info.activeChannelCount);
    N60ProgramFIRRuntime *runtime = N60ProgramFIRRuntimeCreate(program);
    assert(runtime != NULL);
    for (int n = 0; n < 264; ++n) {
        float input[2] = {
            n == 0 ? 0.5f : 0.0f,
            n == 0 ? 0.25f : 0.0f
        };
        float output[2] = {0};
        assert(N60ProgramFIRRuntimeProcessFrame(runtime, input, output));
        assert(isfinite(output[0]) && isfinite(output[1]));
        printf("FIR %d %.9g %.9g\n", n, (double)output[0],
               (double)output[1]);
    }
    N60ProgramFIRRuntimeDestroy(runtime);
    N60ProgramFIRProgramDestroy(program);
    puts("END");
    return 0;
}
