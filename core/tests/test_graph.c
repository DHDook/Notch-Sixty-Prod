/*
 * E6 S2: behavioural harness for the libn60core graph skeleton through its C ABI:
 * pass-through at the eight standard rates, ABI mismatch rejection, argument
 * validation, 1-frame and maximum block sizes, in-place and channel-count mismatch.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

static n60_graph_desc makeDesc(double rate, uint32_t maxBlock, uint32_t in, uint32_t out) {
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = maxBlock;
    d.inputChannels = in;
    d.outputChannels = out;
    return d;
}

static void fillSignal(float *buf, uint32_t frames, uint32_t channel, double rate) {
    for (uint32_t i = 0; i < frames; i++) {
        buf[i] = (float)(0.5 * sin(2.0 * M_PI * (440.0 + 100.0 * channel) * i / rate) + 1e-3 * channel);
    }
}

/* Renders `frames` through a graph of `in` x `out` channels and checks the result. */
static void runPassThrough(double rate, uint32_t maxBlock, uint32_t frames, uint32_t in, uint32_t out, int inPlace) {
    n60_graph_desc d = makeDesc(rate, maxBlock, in, out);
    n60_graph *g = NULL;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK && g, "build %.0f", rate);
    if (!g) return;
    CHECK(n60_graph_latency_frames(g) == 0, "latency");
    uint32_t chans = in > out ? in : out;
    float **inBuf = calloc(chans, sizeof *inBuf), **outBuf = calloc(chans, sizeof *outBuf);
    float **ref = calloc(chans, sizeof *ref);
    for (uint32_t c = 0; c < chans; c++) {
        inBuf[c] = calloc(frames, sizeof(float));
        ref[c] = calloc(frames, sizeof(float));
        outBuf[c] = inPlace ? inBuf[c] : malloc(frames * sizeof(float));
        if (!inPlace) memset(outBuf[c], 0x7f, frames * sizeof(float));
        if (c < in) fillSignal(inBuf[c], frames, c, rate);
        memcpy(ref[c], inBuf[c], frames * sizeof(float));
    }
    n60_status st = n60_graph_process(g, (const float *const *)inBuf, outBuf, frames);
    CHECK(st == N60_STATUS_OK, "process status %d", st);
    for (uint32_t c = 0; c < out; c++) {
        for (uint32_t i = 0; i < frames; i++) {
            float want = c < in ? ref[c][i] : 0.0f;
            if (outBuf[c][i] != want) {
                CHECK(0, "rate %.0f frames %u ch %u sample %u: %g != %g", rate, frames, c, i, outBuf[c][i], want);
                break;
            }
        }
    }
    for (uint32_t c = 0; c < chans; c++) {
        if (!inPlace) free(outBuf[c]);
        free(inBuf[c]);
        free(ref[c]);
    }
    free(inBuf); free(outBuf); free(ref);
    n60_graph_retire(g);
}

int main(void) {
    CHECK(n60_graph_abi_version() == N60_GRAPH_ABI_VERSION, "abi version");

    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; r++) {
        runPassThrough(kRates[r], 4096, 4096, 2, 2, 0); /* maximum block */
        runPassThrough(kRates[r], 4096, 1, 2, 2, 0);    /* single frame */
        runPassThrough(kRates[r], 4096, 333, 2, 2, 1);  /* odd size, in place */
        runPassThrough(kRates[r], 1024, 1024, 6, 6, 0); /* 5.1 */
        runPassThrough(kRates[r], 1024, 500, 8, 2, 0);  /* fewer outputs */
        runPassThrough(kRates[r], 1024, 500, 2, 8, 0);  /* extra outputs are silent */
    }
    runPassThrough(48000, N60_GRAPH_MAX_BLOCK_FRAMES, N60_GRAPH_MAX_BLOCK_FRAMES, 2, 2, 0);

    /* ABI mismatch is rejected and leaves no graph behind. */
    {
        n60_graph *g = (n60_graph *)(void *)1;
        n60_graph_desc d = makeDesc(48000, 512, 2, 2);
        d.abiVersion = N60_GRAPH_ABI_VERSION + 1;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_ABI_MISMATCH && g == NULL, "abi mismatch");
        d = makeDesc(48000, 512, 2, 2);
        d.abiVersion = 0;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_ABI_MISMATCH, "abi zero");
        d = makeDesc(48000, 512, 2, 2);
        d.structSize = sizeof d - 4;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_ABI_MISMATCH, "struct size");
        d.structSize = sizeof d + 8;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_ABI_MISMATCH, "struct size larger");
    }

    /* Argument validation. */
    {
        n60_graph *g = NULL;
        n60_graph_desc d = makeDesc(48000, 512, 2, 2);
        CHECK(n60_graph_build(NULL, &g) == N60_STATUS_BAD_ARGUMENT, "null desc");
        CHECK(n60_graph_build(&d, NULL) == N60_STATUS_BAD_ARGUMENT, "null out");
        d = makeDesc(0.0, 512, 2, 2);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "zero rate");
        d = makeDesc(NAN, 512, 2, 2);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "nan rate");
        d = makeDesc(48000, 0, 2, 2);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "zero block");
        d = makeDesc(48000, N60_GRAPH_MAX_BLOCK_FRAMES + 1, 2, 2);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "huge block");
        d = makeDesc(48000, 512, 0, 2);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "zero in channels");
        d = makeDesc(48000, 512, 2, N60_GRAPH_MAX_CHANNELS + 1);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "too many out channels");
        CHECK(g == NULL, "no graph on failure");

        d = makeDesc(48000, 64, 2, 2);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build");
        float a[128] = {0}, b[128] = {0};
        const float *in[2] = {a, b};
        float *out[2] = {a, b};
        CHECK(n60_graph_process(g, in, out, 65) == N60_STATUS_BAD_ARGUMENT, "frames over max");
        CHECK(n60_graph_process(g, in, out, 0) == N60_STATUS_OK, "zero frames");
        CHECK(n60_graph_process(NULL, in, out, 8) == N60_STATUS_BAD_ARGUMENT, "null graph");
        CHECK(n60_graph_process(g, NULL, out, 8) == N60_STATUS_BAD_ARGUMENT, "null in");
        float *nullOut[2] = {a, NULL};
        CHECK(n60_graph_process(g, in, nullOut, 8) == N60_STATUS_BAD_ARGUMENT, "null out channel");

        n60_param_record rec = {0, 0, 1.0f, 0};
        CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_UNSUPPORTED, "params unsupported");
        CHECK(n60_graph_post_params(g, NULL, 0) == N60_STATUS_OK, "empty params");
        CHECK(n60_graph_post_params(g, NULL, 1) == N60_STATUS_BAD_ARGUMENT, "null records");
        n60_graph_retire(g);
        n60_graph_retire(NULL);
    }

    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("n60core graph skeleton: all checks passed");
    return 0;
}
