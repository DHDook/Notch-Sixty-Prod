/* E11 S2: the targeted measurement bridge plays a second output program (the timing-reference
 * chirp) on its own output channel in the same pass, captures one or two inputs on the same
 * timeline, and never allocates or frees in the realtime process call. Host-only: it includes the
 * bridge header's portable part (the Core Audio IOProc is Apple-only). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int armed = 0;
static long allocations = 0;
static void *counted_malloc(size_t n) { if (armed) allocations++; return malloc(n); }
static void *counted_calloc(size_t c, size_t n) { if (armed) allocations++; return calloc(c, n); }
static void counted_free(void *p) { if (armed && p) allocations++; free(p); }
#define malloc counted_malloc
#define calloc counted_calloc
#define free counted_free
#include "N60TargetedRoomMeasurementBridge.h"
#undef malloc
#undef calloc
#undef free

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

enum { kSweep = 600, kLead = 400, kTail = 300, kChirp = 150, kChirpStart = 20, kFrames = kLead + kSweep + kTail };

int main(void) {
    float sweep[kSweep], chirp[kChirp];
    for (int i = 0; i < kSweep; ++i) sweep[i] = 0.001f * (float)(i + 1);
    for (int i = 0; i < kChirp; ++i) chirp[i] = -0.002f * (float)(i + 1);

    /* Attach rules. */
    N60TargetedRoomMeasurementBridge *b =
        N60TargetedRoomMeasurementBridgeCreateDualInput(sweep, kSweep, kLead, kTail, 1u, 3u, 0u);
    CHECK(b != NULL, "create");
    CHECK(!N60TargetedRoomMeasurementBridgeAttachReferenceProgram(b, chirp, kChirp, kChirpStart, 0u), "same channel rejected");
    CHECK(!N60TargetedRoomMeasurementBridgeAttachReferenceProgram(b, chirp, kChirp, kFrames - 10u, 2u), "overrun rejected");
    CHECK(!N60TargetedRoomMeasurementBridgeAttachReferenceProgram(b, NULL, kChirp, 0u, 2u), "null rejected");
    CHECK(!b->hasReferenceProgram, "rejected attaches leave the bridge unchanged");
    CHECK(N60TargetedRoomMeasurementBridgeAttachReferenceProgram(b, chirp, kChirp, kChirpStart, 2u), "attach");

    /* Four input channels interleaved (mic = 1, loopback = 3), four output channels (sweep 0, chirp 2). */
    enum { kIn = 4, kOut = 4 };
    static float input[kFrames * kIn];
    static float output[kFrames * kOut];
    for (int i = 0; i < kFrames; ++i) {
        input[i * kIn + 1] = 0.5f + 0.0001f * (float)i;
        input[i * kIn + 3] = -0.25f - 0.0001f * (float)i;
    }
    memset(output, 0x55, sizeof output);
    armed = 1;
    allocations = 0;
    uint32_t done = 0;
    const uint32_t blocks[] = {37, 64, 1, 128, 7};
    int blockIndex = 0;
    while (done < kFrames) {
        uint32_t n = blocks[blockIndex++ % 5];
        if (n > kFrames - done) n = kFrames - done;
        uint32_t consumed = N60TargetedRoomMeasurementProcessProgramStrided(
            b, input + done * kIn + 1, kIn, input + done * kIn + 3, kIn,
            output + done * kOut + 0, kOut, output + done * kOut + 2, kOut, n);
        CHECK(consumed == n, "consumed %u of %u", consumed, n);
        done += n;
    }
    /* One more block past the end plays silence and consumes nothing. */
    static float tailOut[8 * kOut];
    memset(tailOut, 0x55, sizeof tailOut);
    CHECK(N60TargetedRoomMeasurementProcessProgramStrided(b, input + 1, kIn, input + 3, kIn, tailOut, kOut,
                                                          tailOut + 2, kOut, 8u) == 0u, "past the end consumes nothing");
    armed = 0;
    CHECK(allocations == 0, "process allocated or freed %ld time(s)", allocations);
    for (int i = 0; i < 8; ++i) CHECK(tailOut[i * kOut] == 0.0f && tailOut[i * kOut + 2] == 0.0f, "silence past the end");

    int bad = 0;
    for (int i = 0; i < kFrames; ++i) {
        float expectSweep = (i >= kLead && i < kLead + kSweep) ? sweep[i - kLead] : 0.0f;
        float expectChirp = (i >= kChirpStart && i < kChirpStart + kChirp) ? chirp[i - kChirpStart] : 0.0f;
        if (output[i * kOut + 0] != expectSweep || output[i * kOut + 2] != expectChirp) bad++;
    }
    CHECK(bad == 0, "%d output frame(s) wrong", bad);
    N60TargetedRoomMeasurementBridgeSnapshot snap = N60TargetedRoomMeasurementBridgeGetSnapshot(b);
    CHECK(snap.complete && snap.capturedFrames == kFrames && snap.referenceCapturedFrames == kFrames, "capture complete");
    static float cap[kFrames], ref[kFrames];
    CHECK(N60TargetedRoomMeasurementBridgeCopyCapture(b, cap, kFrames) == kFrames, "copy capture");
    CHECK(N60TargetedRoomMeasurementBridgeCopyReferenceCapture(b, ref, kFrames) == kFrames, "copy reference");
    CHECK(cap[10] == input[10 * kIn + 1] && ref[kFrames - 1] == input[(kFrames - 1) * kIn + 3], "inputs on one timeline");
    N60TargetedRoomMeasurementBridgeDestroy(b);

    /* Without a program the bridge behaves exactly as before. */
    b = N60TargetedRoomMeasurementBridgeCreate(sweep, kSweep, kLead, kTail, 1u, 0u);
    done = 0;
    while (done < kFrames) {
        uint32_t n = kFrames - done < 100 ? kFrames - done : 100;
        N60TargetedRoomMeasurementProcessStrided(b, input + done * kIn + 1, kIn, output + done * kOut, kOut, n);
        done += n;
    }
    CHECK(output[(kLead + 5) * kOut] == sweep[5] && N60TargetedRoomMeasurementBridgeGetSnapshot(b).complete, "plain path");
    N60TargetedRoomMeasurementBridgeDestroy(b);

    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    puts("targeted bridge OK");
    return 0;
}
