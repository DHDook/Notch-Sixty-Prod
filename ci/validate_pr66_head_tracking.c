
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include "N60HeadTrackedBinauralRuntime.h"

static void close_double(double actual, double expected, double tolerance) {
    assert(fabs(actual - expected) <= tolerance);
}

int main(void) {
    N60ProgramChannelLayout stereo =
        N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60BinauralProfileDescriptor descriptor = N60BinauralProfileDescriptorMake(
        48000.0, stereo, N60BinauralProfileKindHRTF, 1u
    );
    float leftIR[2] = {1.0f, 0.2f};
    float rightIR[2] = {0.2f, 1.0f};
    N60HeadTrackedBinauralRuntime *runtime = N60HeadTrackedBinauralRuntimeCreate(
        descriptor, leftIR, rightIR
    );
    assert(runtime != NULL);
    assert(N60HeadTrackedBinauralRuntimePoseIsLockFree(runtime));
    assert(N60HeadTrackedBinauralRuntimeCanPrepareGeneration(runtime));

    float input[2] = {0.5f, -0.25f};
    float left = 0.0f, right = 0.0f;
    assert(N60HeadTrackedBinauralRuntimeProcessFrame(
        runtime, input, 2u, &left, &right
    ));

    N60HeadPose pose = {
        .yawDegrees = 30.0,
        .pitchDegrees = -5.0,
        .rollDegrees = 2.0,
    };
    float nextLeftIR[2] = {0.8f, 0.3f};
    float nextRightIR[2] = {0.3f, 0.8f};
    assert(N60HeadTrackedBinauralRuntimePrepareGeneration(
        runtime,
        descriptor,
        nextLeftIR,
        nextRightIR,
        pose,
        2u,
        4u
    ));
    assert(!N60HeadTrackedBinauralRuntimeCanPrepareGeneration(runtime));
    assert(!N60HeadTrackedBinauralRuntimePrepareGeneration(
        runtime,
        descriptor,
        nextLeftIR,
        nextRightIR,
        pose,
        0u,
        4u
    ));

    N60HeadTrackedBinauralRuntimeBeginBuffer(runtime);
    for (uint32_t frame = 0; frame < 8u; ++frame) {
        assert(N60HeadTrackedBinauralRuntimeProcessFrame(
            runtime, input, 2u, &left, &right
        ));
    }
    N60HeadTrackedBinauralSnapshot snapshot =
        N60HeadTrackedBinauralRuntimeGetSnapshot(runtime);
    assert(snapshot.acceptedGenerations == 1u);
    assert(snapshot.completedTransitions == 1u);
    assert(snapshot.rejectedGenerations >= 1u);
    assert(!snapshot.transitionBusy);
    assert(snapshot.activeRendererIndex == 1u);
    close_double(snapshot.currentPose.yawDegrees, 30.0, 0.0011);
    close_double(snapshot.currentPose.pitchDegrees, -5.0, 0.0011);
    close_double(snapshot.currentPose.rollDegrees, 2.0, 0.0011);

    N60BinauralProfileDescriptor incompatible = descriptor;
    incompatible.sampleRate = 44100.0;
    assert(!N60HeadTrackedBinauralRuntimePrepareGeneration(
        runtime,
        incompatible,
        nextLeftIR,
        nextRightIR,
        pose,
        0u,
        4u
    ));

    N60HeadTrackedBinauralRuntimeDestroy(runtime);
    return 0;
}
