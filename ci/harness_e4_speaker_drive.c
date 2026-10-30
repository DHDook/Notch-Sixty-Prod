/* E4 S22b1: behavioural harness for the bridge's speaker-drive ring and anchor ring.
 * Demand off records nothing; demand on records every callback whole with a contiguous
 * absolute frame index; a full ring drops whole callbacks and counts them; toggling demand
 * never moves the frame index; the recorded samples are the ones written to the output. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60RealtimeAudioBridge.h"

#define BUF 256u
#define CAP 262144u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static float inBuf[BUF * 2u], outBuf[BUF * 2u];
static AudioBufferList inList, outList;
static uint64_t pos;

static void block(N60RealtimeAudioBridge *b, uint64_t hostTime) {
    for (uint32_t i = 0; i < BUF; ++i) {
        const float v = 0.3f * sinf((float)(2.0 * M_PI * 440.0 * (double)(pos + i) / 48000.0));
        inBuf[i * 2u] = v;
        inBuf[i * 2u + 1u] = -v;
    }
    pos += BUF;
    AudioTimeStamp ts = {0};
    AudioTimeStamp out = {0};
    out.mHostTime = hostTime;
    out.mFlags = kAudioTimeStampHostTimeValid;
    N60CaptureIOProc(0, &ts, &inList, &ts, &outList, &out, b);
    N60OutputIOProc(0, &ts, &inList, &ts, &outList, &out, b);
}

int main(void) {
    memset(&inList, 0, sizeof inList);
    inList.mNumberBuffers = 1;
    inList.mBuffers[0].mNumberChannels = 2;
    inList.mBuffers[0].mDataByteSize = sizeof inBuf;
    inList.mBuffers[0].mData = inBuf;
    outList = inList;
    outList.mBuffers[0].mData = outBuf;

    N60RealtimeAudioBridge *b = N60RealtimeAudioBridgeCreate(CAP);
    CHECK(b != NULL, "bridge");
    if (!b) return EXIT_FAILURE;

    /* Demand off: nothing is recorded. */
    for (int i = 0; i < 40; ++i) block(b, 1000u + (uint64_t)i);
    N60SpeakerDriveSnapshot s = N60RealtimeAudioBridgeGetSpeakerDriveSnapshot(b);
    CHECK(!s.enabled && s.capturedFrames == 0 && s.availableFrames == 0 && s.availableAnchors == 0
              && s.droppedFrames == 0, "demand off must record nothing (%llu)", (unsigned long long)s.capturedFrames);

    /* Demand on: whole callbacks, anchors in order, indices contiguous. */
    N60RealtimeAudioBridgeSetSpeakerDriveDemand(b, true);
    CHECK(N60RealtimeAudioBridgeSpeakerDriveDemand(b), "demand readback");
    enum { N = 20 };
    for (int i = 0; i < N; ++i) block(b, 5000u + 10u * (uint64_t)i);
    s = N60RealtimeAudioBridgeGetSpeakerDriveSnapshot(b);
    CHECK(s.enabled && s.capturedFrames == (uint64_t)N * BUF && s.availableFrames == (uint32_t)(N * BUF)
              && s.availableAnchors == N && s.droppedFrames == 0 && s.droppedAnchors == 0,
          "captured %llu avail %u anchors %u dropped %llu", (unsigned long long)s.capturedFrames,
          s.availableFrames, s.availableAnchors, (unsigned long long)s.droppedFrames);
    static N60SpeakerDriveAnchor anchors[N];
    const uint32_t gotA = N60RealtimeAudioBridgeReadSpeakerDriveAnchors(b, anchors, N);
    CHECK(gotA == N, "anchors read %u", gotA);
    uint64_t expect = anchors[0].firstFrameIndex;
    for (uint32_t i = 0; i < gotA; ++i) {
        CHECK(anchors[i].frames == BUF && anchors[i].firstFrameIndex == expect
                  && anchors[i].outputHostTime == 5000u + 10u * i,
              "anchor %u: first %llu frames %u host %llu", i, (unsigned long long)anchors[i].firstFrameIndex,
              anchors[i].frames, (unsigned long long)anchors[i].outputHostTime);
        expect += anchors[i].frames;
    }
    static N60AmbientPlaybackReferenceFrame frames[N * BUF];
    const uint32_t gotF = N60RealtimeAudioBridgeReadSpeakerDriveFrames(b, frames, N * BUF);
    CHECK(gotF == N * BUF, "frames read %u", gotF);
    /* The last callback's output equals the last recorded frames (the drive is the output). */
    float worst = 0.0f;
    for (uint32_t i = 0; i < BUF; ++i) {
        const N60AmbientPlaybackReferenceFrame f = frames[(N - 1) * BUF + i];
        worst = fmaxf(worst, fabsf(f.left - outBuf[i * 2u]));
        worst = fmaxf(worst, fabsf(f.right - outBuf[i * 2u + 1u]));
    }
    CHECK(worst < 1e-6f, "recorded drive differs from the output by %g", worst);
    s = N60RealtimeAudioBridgeGetSpeakerDriveSnapshot(b);
    CHECK(s.availableFrames == 0 && s.availableAnchors == 0, "reads consume");

    /* Toggling demand never moves the absolute index. */
    const uint64_t before = anchors[N - 1].firstFrameIndex + BUF;
    N60RealtimeAudioBridgeSetSpeakerDriveDemand(b, false);
    for (int i = 0; i < 5; ++i) block(b, 9000u);
    N60RealtimeAudioBridgeSetSpeakerDriveDemand(b, true);
    block(b, 9100u);
    N60SpeakerDriveAnchor one;
    CHECK(N60RealtimeAudioBridgeReadSpeakerDriveAnchors(b, &one, 1) == 1, "anchor after toggle");
    CHECK(one.firstFrameIndex == before, "index after toggle %llu expected %llu",
          (unsigned long long)one.firstFrameIndex, (unsigned long long)before);

    /* A reader that never reads: the anchor ring (1024) fills first; callbacks drop whole. */
    for (int i = 0; i < 1200; ++i) block(b, 20000u + (uint64_t)i);
    s = N60RealtimeAudioBridgeGetSpeakerDriveSnapshot(b);
    CHECK(s.droppedFrames > 0 && s.droppedAnchors > 0, "full ring must count drops");
    CHECK(s.droppedFrames % BUF == 0, "drops are whole callbacks (%llu)", (unsigned long long)s.droppedFrames);
    CHECK(s.availableAnchors <= N60_SPEAKER_DRIVE_ANCHOR_CAPACITY && s.availableFrames % BUF == 0,
          "anchors %u frames %u", s.availableAnchors, s.availableFrames);

    N60RealtimeAudioBridgeDestroy(b);
    if (failures) { fprintf(stderr, "E4 speaker drive: %d failures\n", failures); return EXIT_FAILURE; }
    puts("E4 speaker drive: PASS");
    return EXIT_SUCCESS;
}
