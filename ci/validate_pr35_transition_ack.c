#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60RealtimeAudioBridge.h"

#define TEST_FRAMES 8u

static int fail(const char *message) {
    fprintf(stderr, "PR35 transition acknowledgement validation: FAIL: %s\n", message);
    return EXIT_FAILURE;
}

static int run_silent_output_callback(N60RealtimeAudioBridge *bridge) {
    float output[TEST_FRAMES * 2u] = {0};
    AudioBufferList outputList = {0};
    outputList.mNumberBuffers = 1;
    outputList.mBuffers[0].mNumberChannels = 2;
    outputList.mBuffers[0].mDataByteSize = (UInt32)sizeof(output);
    outputList.mBuffers[0].mData = output;

    AudioBufferList ignoredInput = {0};
    AudioTimeStamp timestamp = {0};
    OSStatus status = N60OutputIOProc(
        0,
        &timestamp,
        &ignoredInput,
        &timestamp,
        &outputList,
        &timestamp,
        bridge
    );
    if (status != noErr) return fail("silent output callback returned an error");
    for (size_t index = 0; index < TEST_FRAMES * 2u; ++index) {
        if (output[index] != 0.0f) return fail("silent callback did not remain silent");
    }
    return EXIT_SUCCESS;
}

int main(void) {
    N60RealtimeAudioBridge *bridge = N60RealtimeAudioBridgeCreate(1024u);
    if (bridge == NULL) return fail("unable to create bridge");

    N60RealtimeAudioBridgeRampTransitionGain(bridge, 0.0f, 4u);
    N60RealtimeAudioBridgeSnapshot before = N60RealtimeAudioBridgeGetSnapshot(bridge);
    if (before.transitionFramesRemaining != 4u) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return fail("fade-down command was not published");
    }

    if (run_silent_output_callback(bridge) != EXIT_SUCCESS) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return EXIT_FAILURE;
    }
    N60RealtimeAudioBridgeSnapshot fadedDown = N60RealtimeAudioBridgeGetSnapshot(bridge);
    if (fadedDown.transitionFramesRemaining != 0u || fabsf(fadedDown.transitionGain) > 1.0e-6f) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return fail("silent output frames did not acknowledge fade-down completion");
    }

    N60RealtimeAudioBridgeRampTransitionGain(bridge, 1.0f, 4u);
    if (run_silent_output_callback(bridge) != EXIT_SUCCESS) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return EXIT_FAILURE;
    }
    N60RealtimeAudioBridgeSnapshot fadedUp = N60RealtimeAudioBridgeGetSnapshot(bridge);
    if (fadedUp.transitionFramesRemaining != 0u || fabsf(fadedUp.transitionGain - 1.0f) > 1.0e-6f) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return fail("silent output frames did not acknowledge fade-up completion");
    }

    N60RealtimeAudioBridgeDestroy(bridge);
    puts("PR35 rendered transition acknowledgement: PASS");
    return EXIT_SUCCESS;
}
