/* E6 EQ linear-phase hardening: a convolver slot that the render thread is still reading (the outgoing side of a graph
 * fade) must not be rewritten by a re-prepare. Includes the implementation to reach the in-use handshake.
 *  1. Deterministic: with a slot marked in use, PrepareProgram blocks (generation unchanged) until it is released.
 *  2. Stress: a render thread processes slots 0 and 1 per sample while the control thread re-prepares them rapidly at
 *     every standard tap-count class; no output may be non-finite and every sample is either a matched program or a
 *     clean refusal.
 *  3. A refusal of the active slot and a retired slot are both still honest: ProgramMatches follows the generation. */
#include "N60Convolution.c"

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static N60PartitionedConvolver *convolver;
static _Atomic bool stop;
static _Atomic uint64_t slotGeneration[2];
static _Atomic uint64_t matched, refused, bad;

typedef struct { uint32_t slot; uint32_t taps; float *data; _Atomic bool done; } PrepareJob;

static void *prepareThread(void *arg) {
    PrepareJob *job = arg;
    uint64_t generation = 0;
    job->done = N60PartitionedConvolverPrepareProgram(convolver, job->slot, job->data, NULL, job->taps, 0, &generation);
    return NULL;
}

static void *renderThread(void *arg) {
    (void)arg;
    uint64_t n = 0;
    while (!atomic_load(&stop)) {
        for (uint32_t slot = 0; slot < 2u; ++slot) {
            float l = 0, r = 0;
            const float in = sinf((float)n * 0.05f);
            const uint64_t gen = atomic_load(&slotGeneration[slot]);
            if (N60PartitionedConvolverProcessSample(convolver, slot, gen, in, in, &l, &r)) {
                atomic_fetch_add(&matched, 1);
                if (!isfinite(l) || !isfinite(r) || fabsf(l) > 64.0f) atomic_fetch_add(&bad, 1);
            } else {
                atomic_fetch_add(&refused, 1);
            }
        }
        ++n;
    }
    return NULL;
}

static void makeTaps(float *taps, uint32_t count, float gain) {
    for (uint32_t i = 0; i < count; ++i) taps[i] = 0.0f;
    taps[count / 2u] = gain;
}

int main(void) {
    convolver = N60PartitionedConvolverCreate();
    if (convolver == NULL) { fprintf(stderr, "FAIL create\n"); return 1; }
    static float taps[16385];
    makeTaps(taps, 4097, 0.5f);
    uint64_t gen = 0;
    CHECK(N60PartitionedConvolverPrepareProgram(convolver, 1, taps, NULL, 4097, 0, &gen), "initial prepare");
    const uint64_t before = convolver->programs[1].generation;

    /* 1. A slot in use blocks the re-prepare until released. */
    atomic_store(&convolver->slotInUse[1], 1u);
    PrepareJob job = {.slot = 1, .taps = 4097, .data = taps, .done = false};
    pthread_t t;
    pthread_create(&t, NULL, prepareThread, &job);
    usleep(80000);
    CHECK(!job.done, "re-prepare of an in-use slot must wait");
    CHECK(convolver->programs[1].generation == before, "in-use slot must not be rewritten");
    CHECK(!N60PartitionedConvolverProgramMatches(convolver, 1, before), "retired slot must not match while waiting");
    atomic_store(&convolver->slotInUse[1], 0u);
    pthread_join(t, NULL);
    CHECK(job.done, "re-prepare completes once the slot is released");
    CHECK(convolver->programs[1].generation != before, "generation advances after the re-prepare");

    /* 2. Stress at the standard-rate tap counts. */
    static const uint32_t tapCounts[] = {1025, 2049, 4097, 8193, 16385};
    atomic_store(&slotGeneration[0], 0);
    pthread_t render;
    pthread_create(&render, NULL, renderThread, NULL);
    for (uint32_t i = 0; i < 400; ++i) {
        const uint32_t slot = i & 1u;
        const uint32_t count = tapCounts[i % 5u];
        makeTaps(taps, count, 0.25f + 0.001f * (float)i);
        uint64_t g = 0;
        if (N60PartitionedConvolverPrepareProgram(convolver, slot, taps, NULL, count, 0, &g)) {
            atomic_store(&slotGeneration[slot], g);
        }
    }
    atomic_store(&stop, true);
    pthread_join(render, NULL);
    CHECK(atomic_load(&bad) == 0, "%llu non-finite or runaway samples", (unsigned long long)atomic_load(&bad));
    CHECK(atomic_load(&matched) > 0, "render must have processed matched samples");

    N60PartitionedConvolverDestroy(convolver);
    if (failures == 0) printf("harness_e6_convolution_slot_reuse: OK (matched=%llu refused=%llu)\n",
                              (unsigned long long)matched, (unsigned long long)refused);
    return failures == 0 ? 0 : 1;
}
