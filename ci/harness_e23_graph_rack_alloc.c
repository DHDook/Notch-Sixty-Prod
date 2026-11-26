/* E23 K1c: behavioural harness for the graph's Audio Unit rack adapter. Runs 10,000 blocks of varied sizes through
 * N60GraphAudioUnitRackProcess (the realtime entry) and asserts: no heap allocation or free on that path (malloc logger),
 * the planar lanes come back through the interleaved rack with its gain, slices never exceed maximumFramesPerSlice,
 * the host sample time advances by slice start, and a failing rack returns 0 once and the adapter recovers. */
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "UnifiedGraph/N60GraphAudioUnitRack.h"

typedef void(malloc_logger_t)(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);
extern malloc_logger_t *malloc_logger;

static atomic_uint_fast64_t gHeapEvents;
static void countHeap(uint32_t t, uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t r, uint32_t s) {
    (void)t; (void)a; (void)b; (void)c; (void)r; (void)s;
    atomic_fetch_add(&gHeapEvents, 1);
}

#define CH 6u
#define MAXSLICE 256u
#define MAXBLOCK 2048u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

typedef struct { uint32_t largest; uint64_t calls; double lastTime; uint64_t failAt; } Fake;

static bool fakeProcess(void *ctx, const float *in, float *out, uint32_t frames, uint32_t channels, double t) {
    Fake *f = ctx;
    f->calls++;
    if (frames > f->largest) f->largest = frames;
    f->lastTime = t;
    if (f->calls == f->failAt) return false;
    for (uint32_t i = 0; i < frames * channels; ++i) out[i] = in[i] * 0.5f;
    return true;
}

int main(void) {
    static float lanes[CH][MAXBLOCK];
    float *planes[CH];
    for (uint32_t c = 0; c < CH; ++c) planes[c] = lanes[c];
    Fake fake = {0, 0, 0, 0};
    N60AudioUnitLiveRackProcessor processor = {0};
    processor.context = &fake;
    processor.process = fakeProcess;
    processor.channelCount = CH;
    processor.maximumFramesPerSlice = MAXSLICE;
    processor.latencyFrames = 96;
    N60GraphAudioUnitRack *rack = N60GraphAudioUnitRackCreate(&processor);
    CHECK(rack != NULL, "create");
    if (rack == NULL) return 1;
    CHECK(N60GraphAudioUnitRackChannelCount(rack) == CH, "channels");
    CHECK(N60GraphAudioUnitRackLatencyFrames(rack) == 96u, "latency");
    CHECK(N60GraphAudioUnitRackMaximumFramesPerSlice(rack) == MAXSLICE, "slice");

    uint32_t seed = 12345u;
    atomic_store(&gHeapEvents, 0);
    malloc_logger = countHeap;
    for (uint32_t block = 0; block < 10000u; ++block) {
        seed = seed * 1664525u + 1013904223u;
        uint32_t frames = 16u + (seed >> 8) % (MAXBLOCK - 16u);
        for (uint32_t c = 0; c < CH; ++c)
            for (uint32_t i = 0; i < frames; ++i) lanes[c][i] = 0.01f * (float)(c + 1u) * (float)((int)(i % 7u) - 3);
        N60GraphAudioUnitRackSetBlockSampleTime(rack, 1000.0 * block);
        const int ok = N60GraphAudioUnitRackProcess(rack, (const float *const *)planes, planes, CH, frames);
        if (!ok) { CHECK(0, "rack failed at block %u", block); break; }
        if (block % 997u == 0u) {
            for (uint32_t c = 0; c < CH; ++c)
                for (uint32_t i = 0; i < frames; ++i) {
                    const float want = 0.5f * 0.01f * (float)(c + 1u) * (float)((int)(i % 7u) - 3);
                    if (fabsf(lanes[c][i] - want) > 1e-7f) { CHECK(0, "lane %u frame %u", c, i); c = CH; break; }
                }
        }
    }
    malloc_logger = NULL;
    CHECK(atomic_load(&gHeapEvents) == 0, "heap events on the realtime path: %llu", (unsigned long long)atomic_load(&gHeapEvents));
    CHECK(fake.largest <= MAXSLICE, "slice %u over the maximum", fake.largest);

    /* A failing rack: one block returns 0, the next is processed again. */
    fake.failAt = fake.calls + 1;
    N60GraphAudioUnitRackSetBlockSampleTime(rack, 5.0);
    CHECK(N60GraphAudioUnitRackProcess(rack, (const float *const *)planes, planes, CH, 64) == 0, "failure returns 0");
    CHECK(N60GraphAudioUnitRackProcess(rack, (const float *const *)planes, planes, CH, 64) != 0, "recovers");
    /* Wrong channel count is refused, not processed. */
    CHECK(N60GraphAudioUnitRackProcess(rack, (const float *const *)planes, planes, CH - 1u, 64) == 0, "channel mismatch refused");

    N60GraphAudioUnitRackDestroy(rack);
    if (failures == 0) printf("PASS e23_graph_rack_alloc\n");
    return failures == 0 ? 0 : 1;
}
