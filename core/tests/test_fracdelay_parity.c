/* E6 S8d group 3: the core FRAC_DELAY stage (Thiran all-pass) against the shipping kernel
 * inter-channel delay (N60FractionalDelay.h) on the same stereo signal, at the eight standard
 * rates and several signed delays, including both fractional and exact-integer cases. */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "n60/graph.h"
#include "../../NotchSixty/Audio/Realtime/N60FractionalDelay.h"

#define N 9600
static float inL[N], inR[N], kL[N], kR[N], cL[N], cR[N];
static N60InterChannelDelayRuntime rt;

static void stage(n60_stage_desc *st, uint32_t id, uint32_t lane, float *p, double total) {
    memset(st, 0, sizeof *st);
    p[0] = (float)floor(total);
    p[1] = (float)(total - floor(total));
    st->structSize = sizeof *st;
    st->kind = N60_STAGE_FRAC_DELAY;
    st->stageId = id;
    st->laneA = lane;
    st->params = p;
    st->paramCount = 2;
}

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const double delays[] = {0.2, -0.37, 1.0, -4.123, 12.5};
    int failures = 0;
    for (unsigned r = 0; r < 8; r++) {
        const double rate = rates[r];
        for (unsigned m = 0; m < 5; m++) {
            unsigned seed = 99;
            for (int i = 0; i < N; i++) {
                seed = seed * 1664525u + 1013904223u;
                inL[i] = 0.5f * (float)sin(2.0 * 3.14159265358979 * 997.0 * i / rate) + 0.1f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                inR[i] = 0.4f * (float)sin(2.0 * 3.14159265358979 * 3100.0 * i / rate);
            }
            N60InterChannelDelaySnapshot snap;
            if (!N60InterChannelDelaySnapshotMake(rate, delays[m], &snap)) { fprintf(stderr, "kernel snapshot failed\n"); return 1; }
            N60InterChannelDelayRuntimeReset(&rt, snap);
            for (int i = 0; i < N; i++) N60InterChannelDelayRuntimeProcess(&rt, inL[i], inR[i], &kL[i], &kR[i]);

            const double rel = fabs(delays[m]) * rate / 1000.0;
            const double totL = delays[m] > 0.0 ? 2.0 : 2.0 + rel;
            const double totR = delays[m] > 0.0 ? 2.0 + rel : 2.0;
            float pl[2], pr[2];
            n60_stage_desc st[2];
            stage(&st[0], 1, 0, pl, totL);
            stage(&st[1], 2, 1, pr, totR);
            n60_graph_desc d;
            memset(&d, 0, sizeof d);
            d.structSize = sizeof d;
            d.abiVersion = N60_GRAPH_ABI_VERSION;
            d.sampleRate = rate;
            d.maxBlockFrames = N;
            d.inputChannels = d.outputChannels = 2;
            d.stages = st;
            d.stageCount = 2;
            n60_graph *g = NULL;
            if (n60_graph_build(&d, &g) != N60_STATUS_OK) { fprintf(stderr, "core build failed\n"); return 1; }
            const float *ip[2] = {inL, inR};
            float *op[2] = {cL, cR};
            n60_graph_process(g, ip, op, N);
            double worst = 0;
            for (int i = 0; i < N; i++) {
                double e = fabs((double)cL[i] - kL[i]);
                if (e > worst) worst = e;
                e = fabs((double)cR[i] - kR[i]);
                if (e > worst) worst = e;
            }
            const uint32_t lat = n60_graph_latency_frames(g);
            const uint32_t want = (uint32_t)floor(delays[m] > 0.0 ? totR : totL);
            printf("rate %.0f delay %.3f ms: worst deviation %.3g latency %u\n", rate, delays[m], worst, lat);
            if (lat != want) { fprintf(stderr, "FAIL latency %u != %u\n", lat, want); failures++; }
            if (!(worst < 1e-4)) { fprintf(stderr, "FAIL deviation\n"); failures++; }
            n60_graph_retire(g);
        }
    }
    if (failures) return 1;
    printf("PASS\n");
    return 0;
}
