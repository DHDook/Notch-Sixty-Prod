
#include <assert.h>
#include <math.h>
#include "N60ProgramTransportCore.h"

int main(void) {
    N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutSevenOneFour);
    assert(N60ProgramChannelLayoutIsValid(&layout));
    N60ProgramTransport *transport = N60ProgramTransportCreate(3u, layout);
    assert(transport != NULL);
    assert(N60ProgramTransportLayoutMatches(transport, &layout));

    for (uint32_t frameIndex = 0; frameIndex < 3u; ++frameIndex) {
        N60ProgramTransportFrame frame = {0};
        for (uint32_t channel = 0; channel < layout.channelCount; ++channel) {
            frame.channels[channel] = (float)(100u * frameIndex + channel);
        }
        assert(N60ProgramTransportEnqueueFrame(transport, &frame));
    }
    N60ProgramTransportFrame overflow = {0};
    assert(!N60ProgramTransportEnqueueFrame(transport, &overflow));
    N60ProgramTransportSnapshot snapshot = N60ProgramTransportGetSnapshot(transport);
    assert(snapshot.capturedFrames == 3u);
    assert(snapshot.overrunFrames == 1u);
    assert(snapshot.bufferedFrames == 3u);

    for (uint32_t frameIndex = 0; frameIndex < 3u; ++frameIndex) {
        N60ProgramTransportFrame frame = {0};
        assert(N60ProgramTransportDequeueFrame(transport, &frame));
        for (uint32_t channel = 0; channel < layout.channelCount; ++channel) {
            assert(frame.channels[channel] == (float)(100u * frameIndex + channel));
        }
    }
    N60ProgramTransportFrame underflow;
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        underflow.channels[channel] = 9.0f;
    }
    assert(!N60ProgramTransportDequeueFrame(transport, &underflow));
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        assert(underflow.channels[channel] == 0.0f);
    }
    snapshot = N60ProgramTransportGetSnapshot(transport);
    assert(snapshot.consumedFrames == 3u);
    assert(snapshot.underrunFrames == 1u);
    assert(snapshot.bufferedFrames == 0u);

    N60ProgramTransportReset(transport);
    snapshot = N60ProgramTransportGetSnapshot(transport);
    assert(snapshot.capturedFrames == 0u && snapshot.consumedFrames == 0u);
    N60ProgramTransportDestroy(transport);
    return 0;
}
