/* E6 S8d group 3, E23 T2: the core FRAC_DELAY stage (Thiran all-pass) at the eight standard rates and several signed
 * delays, including both fractional and exact-integer cases, against a frozen corpus (e23_corpus_fracdelay.inc, see
 * e23_corpus.h; each case: the reported latency, then the left and right summaries). A -DN60_E23_WRITE_CORPUS build also
 * runs the original kernel comparison (N60FractionalDelay.h inter-channel delay, deviation under 1e-4) and writes the corpus. */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "n60/graph.h"
#include "e23_corpus.h"
#ifdef N60_E23_WRITE_CORPUS
#include "../../NotchSixty/Audio/Realtime/N60FractionalDelay.h"
#else
#include "e23_corpus_fracdelay.inc"
#endif

#define N 9600
static float inL[N], inR[N], kL[N], kR[N], cL[N], cR[N];
#define STRIDE (1 + 2 * E23_CH_VALUES)
#ifdef N60_E23_WRITE_CORPUS
static N60InterChannelDelayRuntime rt;
#endif

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
#ifdef N60_E23_WRITE_CORPUS
    e23_open("kCorpus");
#else
    (void)kL; (void)kR;
#endif
    for (unsigned r = 0; r < 8; r++) {
        const double rate = rates[r];
        for (unsigned m = 0; m < 5; m++) {
            unsigned seed = 99;
            for (int i = 0; i < N; i++) {
                seed = seed * 1664525u + 1013904223u;
                inL[i] = 0.5f * (float)sin(2.0 * 3.14159265358979 * 997.0 * i / rate) + 0.1f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                inR[i] = 0.4f * (float)sin(2.0 * 3.14159265358979 * 3100.0 * i / rate);
            }
#ifdef N60_E23_WRITE_CORPUS
            N60InterChannelDelaySnapshot snap;
            if (!N60InterChannelDelaySnapshotMake(rate, delays[m], &snap)) { fprintf(stderr, "kernel snapshot failed\n"); return 1; }
            N60InterChannelDelayRuntimeReset(&rt, snap);
            for (int i = 0; i < N; i++) N60InterChannelDelayRuntimeProcess(&rt, inL[i], inR[i], &kL[i], &kR[i]);

#endif
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
            const uint32_t lat = n60_graph_latency_frames(g);
            const uint32_t want = (uint32_t)floor(delays[m] > 0.0 ? totR : totL);
            if (lat != want) { fprintf(stderr, "FAIL latency %u != %u\n", lat, want); failures++; }
            double rec[STRIDE];
            rec[0] = lat;
            e23_summarise(cL, N, (int)lat, rec + 1);
            e23_summarise(cR, N, (int)lat, rec + 1 + E23_CH_VALUES);
#ifdef N60_E23_WRITE_CORPUS
            double worst = 0;
            for (int i = 0; i < N; i++) {
                double e = fabs((double)cL[i] - kL[i]);
                if (e > worst) worst = e;
                e = fabs((double)cR[i] - kR[i]);
                if (e > worst) worst = e;
            }
            printf("rate %.0f delay %.3f ms: worst deviation %.3g latency %u\n", rate, delays[m], worst, lat);
            if (!(worst < 1e-4)) { fprintf(stderr, "FAIL deviation\n"); failures++; }
            e23_put(rec, STRIDE);
#else
            {
                const double *frozen = kCorpus + (size_t)(r * 5 + m) * STRIDE;
                char label[64];
                snprintf(label, sizeof label, "rate %.0f delay %.3f L", rate, delays[m]);
                failures += e23_compare(rec + 1, frozen + 1, label);
                snprintf(label, sizeof label, "rate %.0f delay %.3f R", rate, delays[m]);
                failures += e23_compare(rec + 1 + E23_CH_VALUES, frozen + 1 + E23_CH_VALUES, label);
                if (rec[0] != frozen[0]) { fprintf(stderr, "FAIL latency %.0f vs frozen %.0f\n", rec[0], frozen[0]); failures++; }
            }
#endif
            n60_graph_retire(g);
        }
    }
#ifdef N60_E23_WRITE_CORPUS
    e23_close();
#endif
    if (failures) return 1;
    printf("PASS\n");
    return 0;
}
