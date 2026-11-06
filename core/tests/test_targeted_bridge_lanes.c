/* E26 S6a: the targeted measurement bridge plays further output programs (the splitter-rendered mains and the sub
 * lane) on their own hardware output channels in one pass, on the same timeline as the primary sweep, and the
 * realtime path never allocates or frees. Host-only: the bridge header's portable part. Lengths scale with the
 * eight standard rates so the timeline arithmetic is exercised at each. */
#include <math.h>
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

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
enum { kOut = 6, kIn = 2 };

static float program(int lane, uint32_t i) { return (float)(lane + 1) * 0.01f + 1.0e-6f * (float)(i % 5000); }

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        const double rate = kRates[r];
        const uint32_t sweepN = (uint32_t)(0.05 * rate), lead = (uint32_t)(0.01 * rate), tail = (uint32_t)(0.02 * rate);
        const uint32_t total = lead + sweepN + tail;
        float *sweep = (float *)calloc(sweepN, sizeof(float));
        float *lanes[3];
        for (int k = 0; k < 3; ++k) lanes[k] = (float *)calloc(sweepN, sizeof(float));
        for (uint32_t i = 0; i < sweepN; ++i) {
            sweep[i] = program(0, i);
            for (int k = 0; k < 3; ++k) lanes[k][i] = program(k + 1, i);
        }
        N60TargetedRoomMeasurementBridge *b = N60TargetedRoomMeasurementBridgeCreate(sweep, sweepN, lead, tail, 0u, 0u);
        CHECK(b != NULL, "rate %.0f: create", rate);
        if (b == NULL) return 1;

        /* Attach rules. */
        CHECK(!N60TargetedRoomMeasurementBridgeAttachLaneProgram(b, lanes[0], sweepN, lead, 0u), "rate %.0f: primary channel clash", rate);
        CHECK(!N60TargetedRoomMeasurementBridgeAttachLaneProgram(b, lanes[0], sweepN, total - 5u, 1u), "rate %.0f: overrun", rate);
        CHECK(!N60TargetedRoomMeasurementBridgeAttachLaneProgram(b, NULL, sweepN, lead, 1u), "rate %.0f: null", rate);
        float bad[4] = {0.1f, NAN, 0.1f, 0.1f};
        CHECK(!N60TargetedRoomMeasurementBridgeAttachLaneProgram(b, bad, 4u, lead, 1u), "rate %.0f: NaN sample", rate);
        CHECK(b->laneProgramCount == 0u, "rate %.0f: rejected attaches leave the bridge unchanged", rate);
        CHECK(N60TargetedRoomMeasurementBridgeAttachLaneProgram(b, lanes[0], sweepN, lead, 2u), "rate %.0f: attach 1", rate);
        CHECK(!N60TargetedRoomMeasurementBridgeAttachLaneProgram(b, lanes[1], sweepN, lead, 2u), "rate %.0f: lane clash", rate);
        CHECK(N60TargetedRoomMeasurementBridgeAttachLaneProgram(b, lanes[1], sweepN, lead, 3u), "rate %.0f: attach 2", rate);
        CHECK(N60TargetedRoomMeasurementBridgeAttachLaneProgram(b, lanes[2], sweepN, lead, 5u), "rate %.0f: attach 3", rate);
        CHECK(b->laneProgramCount == 3u, "rate %.0f: three lanes", rate);

        /* One pass in uneven blocks: the primary on channel 0, the lanes on 2, 3 and 5; 1 and 4 stay silent. */
        float *output = (float *)malloc(sizeof(float) * (size_t)(total + 16u) * kOut);
        float *input = (float *)calloc((size_t)(total + 16u) * kIn, sizeof(float));
        memset(output, 0x55, sizeof(float) * (size_t)(total + 16u) * kOut);
        const uint32_t blocks[] = {37, 64, 1, 128, 7, 480};
        const uint32_t laneChannel[3] = {2, 3, 5};
        uint32_t done = 0;
        int bi = 0;
        armed = 1;
        allocations = 0;
        while (done < total + 16u) {
            uint32_t n = blocks[bi++ % 6];
            if (n > total + 16u - done) n = total + 16u - done;
            float *outs[3];
            uint32_t strides[3];
            for (int k = 0; k < 3; ++k) { outs[k] = output + (size_t)done * kOut + laneChannel[k]; strides[k] = kOut; }
            /* The IOProc zeroes the buffer first, then writes the lanes, then the process call. */
            for (uint32_t f = 0; f < n; ++f) for (int c = 0; c < kOut; ++c) output[(size_t)(done + f) * kOut + c] = 0.0f;
            N60TargetedRoomMeasurementWriteLanePrograms(b, outs, strides, n);
            N60TargetedRoomMeasurementProcessStrided(b, input + (size_t)done * kIn, kIn, output + (size_t)done * kOut, kOut, n);
            done += n;
        }
        armed = 0;
        CHECK(allocations == 0, "rate %.0f: realtime path allocated or freed %ld time(s)", rate, allocations);
        uint32_t wrong = 0;
        for (uint32_t i = 0; i < total + 16u; ++i) {
            const int inside = i >= lead && i < lead + sweepN;
            const float want0 = inside ? program(0, i - lead) : 0.0f;
            if (output[(size_t)i * kOut + 0] != want0) wrong++;
            for (int k = 0; k < 3; ++k) {
                const float want = inside ? program(k + 1, i - lead) : 0.0f;
                if (output[(size_t)i * kOut + laneChannel[k]] != want) wrong++;
            }
            if (output[(size_t)i * kOut + 1] != 0.0f || output[(size_t)i * kOut + 4] != 0.0f) wrong++;
        }
        CHECK(wrong == 0, "rate %.0f: %u wrong output samples", rate, wrong);

        /* Reset keeps the programs, so a second pass repeats exactly. */
        N60TargetedRoomMeasurementBridgeReset(b);
        CHECK(b->laneProgramCount == 3u, "rate %.0f: reset keeps lane programs", rate);
        float one[kOut] = {0};
        float *outs[3] = {one + 2, one + 3, one + 5};
        uint32_t strides[3] = {kOut, kOut, kOut};
        N60TargetedRoomMeasurementWriteLanePrograms(b, outs, strides, 1u);
        CHECK(one[2] == 0.0f && one[3] == 0.0f && one[5] == 0.0f, "rate %.0f: lead-in is silent after reset", rate);

        N60TargetedRoomMeasurementBridgeDestroy(b);
        free(output); free(input); free(sweep);
        for (int k = 0; k < 3; ++k) free(lanes[k]);
    }
    if (failures != 0) { fprintf(stderr, "%d check(s) failed\n", failures); return 1; }
    puts("targeted bridge lanes: all checks passed");
    return 0;
}
