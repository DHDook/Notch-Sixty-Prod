#include "N60FeedForwardOutputTiming.h"
#include <stdio.h>
#include <math.h>

#define ASSERT(b, message) do { if (!(b)) { fprintf(stderr, "%s\n", message); return 1; } } while (0)

int main(void) {
    N60FeedForwardOutputTiming witness = {0};
    N60FeedForwardOutputTimingSnapshot empty =
        N60FeedForwardOutputTimingRead(&witness);
    ASSERT(!empty.valid, "unobserved time must be invalid");

    AudioTimeStamp output = {0};
    output.mHostTime = 91234567;
    output.mSampleTime = 49152.5;
    output.mFlags = kAudioTimeStampHostTimeValid
        | kAudioTimeStampSampleTimeValid;
    N60FeedForwardOutputTimingObserve(&witness, &output, 128);
    N60FeedForwardOutputTimingSnapshot snap =
        N60FeedForwardOutputTimingRead(&witness);
    ASSERT(snap.valid, "timestamp snapshot should be valid");
    ASSERT(snap.firstFrameHostTime == 91234567, "host timestamp mismatch");
    ASSERT(fabs(snap.firstFrameSampleTime - 49152.5) < 1.0e-9,
           "sample timestamp mismatch");
    ASSERT(snap.renderedFrames == 128, "output frame quantum mismatch");

    output.mFlags = 0;
    N60FeedForwardOutputTimingObserve(&witness, &output, 128);
    snap = N60FeedForwardOutputTimingRead(&witness);
    ASSERT(snap.callbackCount == 2, "callback count should advance");
    ASSERT(snap.invalidCount == 1, "invalid timestamp must be counted");
    ASSERT(snap.valid && snap.firstFrameHostTime == 91234567,
           "invalid timestamp must not overwrite latest valid clock");
    printf("PR96 passive output timestamp smoke passed\n");
    return 0;
}
