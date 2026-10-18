
#include <assert.h>
#include <math.h>
#include <string.h>
#include "N60ProgramTransport.h"

static AudioChannelDescription description(AudioChannelLabel label) {
    AudioChannelDescription d = {0};
    d.mChannelLabel = label;
    return d;
}

static void closef(float actual, float expected) {
    assert(fabsf(actual - expected) <= 1.0e-7f);
}

int main(void) {
    N60ProgramChannelLayout fiveOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    assert(N60ProgramChannelLayoutIsValid(&fiveOne));

    // External stream order: R, L, C, LFE, RS, LS. Canonical order must be L,R,C,LFE,LS,RS.
    AudioChannelDescription inputDescriptions[6] = {
        description(kAudioChannelLabel_Right),
        description(kAudioChannelLabel_Left),
        description(kAudioChannelLabel_Center),
        description(kAudioChannelLabel_LFEScreen),
        description(kAudioChannelLabel_RightSurround),
        description(kAudioChannelLabel_LeftSurround),
    };
    N60ProgramInputMap inputMap = {0};
    assert(N60ProgramInputMapCompile(inputDescriptions, 6u, fiveOne, &inputMap));
    assert(!N60ChannelRoutingMatrixIsIdentity(&inputMap.streamToCanonical));

    float interleavedInput[12] = {
        20, 10, 30, 40, 60, 50,
        21, 11, 31, 41, 61, 51,
    };
    AudioBufferList inputABL = {0};
    inputABL.mNumberBuffers = 1u;
    inputABL.mBuffers[0].mNumberChannels = 6u;
    inputABL.mBuffers[0].mDataByteSize = sizeof(interleavedInput);
    inputABL.mBuffers[0].mData = interleavedInput;

    N60ProgramTransportFrame canonical = {0};
    assert(N60ProgramInputMapReadFrame(&inputMap, &inputABL, 0u, &canonical));
    closef(canonical.channels[0], 10.0f);
    closef(canonical.channels[1], 20.0f);
    closef(canonical.channels[2], 30.0f);
    closef(canonical.channels[3], 40.0f);
    closef(canonical.channels[4], 50.0f);
    closef(canonical.channels[5], 60.0f);

    // Physical device order: C,R,L,Unknown,LFE,RS,LS. Unknown aux channel must be silenced.
    AudioChannelDescription outputDescriptions[7] = {
        description(kAudioChannelLabel_Center),
        description(kAudioChannelLabel_Right),
        description(kAudioChannelLabel_Left),
        description(kAudioChannelLabel_Unknown),
        description(kAudioChannelLabel_LFEScreen),
        description(kAudioChannelLabel_RightSurround),
        description(kAudioChannelLabel_LeftSurround),
    };
    N60ProgramOutputMap outputMap = {0};
    assert(N60ProgramOutputMapCompile(outputDescriptions, 7u, fiveOne, &outputMap));
    float interleavedOutput[7] = {9,9,9,9,9,9,9};
    AudioBufferList outputABL = {0};
    outputABL.mNumberBuffers = 1u;
    outputABL.mBuffers[0].mNumberChannels = 7u;
    outputABL.mBuffers[0].mDataByteSize = sizeof(interleavedOutput);
    outputABL.mBuffers[0].mData = interleavedOutput;
    assert(N60ProgramOutputMapWriteFrame(&outputMap, &canonical, &outputABL, 0u));
    closef(interleavedOutput[0], 30.0f);
    closef(interleavedOutput[1], 20.0f);
    closef(interleavedOutput[2], 10.0f);
    closef(interleavedOutput[3], 0.0f);
    closef(interleavedOutput[4], 40.0f);
    closef(interleavedOutput[5], 60.0f);
    closef(interleavedOutput[6], 50.0f);

    AudioChannelDescription missing[6];
    memcpy(missing, inputDescriptions, sizeof(missing));
    missing[5] = description(kAudioChannelLabel_Unknown);
    assert(!N60ProgramOutputMapCompile(missing, 6u, fiveOne, &outputMap));

    AudioChannelDescription duplicate[6];
    memcpy(duplicate, inputDescriptions, sizeof(duplicate));
    duplicate[5] = description(kAudioChannelLabel_RightSurround);
    assert(!N60ProgramOutputMapCompile(duplicate, 6u, fiveOne, &outputMap));

    // Capture callback adapter publishes a canonical semantic ring.
    N60ProgramTransport *transport = N60ProgramTransportCreate(4u, fiveOne);
    assert(transport != NULL);
    assert(N60ProgramTransportCaptureBuffer(transport, &inputMap, &inputABL) == 2u);
    N60ProgramTransportFrame first = {0}, second = {0};
    assert(N60ProgramTransportDequeueFrame(transport, &first));
    assert(N60ProgramTransportDequeueFrame(transport, &second));
    closef(first.channels[0], 10.0f);
    closef(first.channels[5], 60.0f);
    closef(second.channels[0], 11.0f);
    closef(second.channels[5], 61.0f);
    N60ProgramTransportSnapshot snapshot = N60ProgramTransportGetSnapshot(transport);
    assert(snapshot.capturedFrames == 2u && snapshot.consumedFrames == 2u);
    assert(snapshot.unsupportedBufferLayouts == 0u);
    N60ProgramTransportDestroy(transport);

    return 0;
}
