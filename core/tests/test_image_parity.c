/* E6 S12b, E23 T2: the core IMAGE (stereo mode, widener) and DEESS (de-harsh, de-esser) stages at the eight standard
 * rates, for six configurations plus a live mid-stream parameter change, against a frozen corpus
 * (e23_corpus_image.inc, see e23_corpus.h; each case: the de-esser gain-reduction readback, then the left and right
 * summaries). A -DN60_E23_WRITE_CORPUS build also runs the original kernel comparison (N60Dynamics.c core frame;
 * Apple-only) with its bounds (see the comments at the checks) and writes the corpus from the graph output. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"
#include "e23_corpus.h"
#ifdef N60_E23_WRITE_CORPUS
#include "../../NotchSixty/Audio/Realtime/N60Dynamics.h"
#else
#include "e23_corpus_image.inc"
#endif

#define N 400384
#define SWITCH_AT 200192
static float inL[N], inR[N], kL[N], kR[N], cL[N], cR[N];
#define STRIDE (1 + 2 * E23_CH_VALUES)

typedef struct {
    int mode, wide, monoLow;
    float lowMid, midHigh, lowW, midW, highW;
    int harsh;
    float harshHz, harshDb;
    int ess;
    float essHz, thr, ratio, range, q, atk, rel;
    int dyn;
} Cfg;

#ifdef N60_E23_WRITE_CORPUS
static bool apply(N60DynamicsSnapshot *s, double rate, const Cfg *c) {
    bool ok = N60DynamicsSnapshotSetStereoMode(s, (N60StereoMode)c->mode);
    ok = ok && N60DynamicsSnapshotSetStereoWidener(s, rate, c->wide, c->monoLow, c->lowMid, c->midHigh, c->lowW, c->midW, c->highW);
    ok = ok && N60DynamicsSnapshotSetDeHarsh(s, rate, c->harsh, c->harshDb, c->harshHz);
    ok = ok && N60DynamicsSnapshotSetDeEsserAdvanced(s, rate, c->ess, c->essHz, c->thr, c->ratio, c->range, c->q, c->atk, c->rel, c->dyn);
    return ok;
}

#endif

static void img(const Cfg *c, float *p) {
    p[0] = (float)c->mode; p[1] = (float)c->wide; p[2] = (float)c->monoLow; p[3] = c->lowMid; p[4] = c->midHigh;
    p[5] = c->lowW; p[6] = c->midW; p[7] = c->highW;
}
static void dee(const Cfg *c, float *p) {
    p[0] = (float)c->harsh; p[1] = c->harshHz; p[2] = c->harshDb; p[3] = (float)c->ess; p[4] = c->essHz; p[5] = c->thr;
    p[6] = c->ratio; p[7] = c->range; p[8] = c->q; p[9] = c->atk; p[10] = c->rel; p[11] = (float)c->dyn;
}

static n60_graph *build(double rate, const Cfg *c, n60_stage_desc *st, float *pi, float *pd) {
    memset(st, 0, 2 * sizeof *st);
    img(c, pi);
    dee(c, pd);
    for (int k = 0; k < 2; k++) {
        st[k].structSize = sizeof st[k];
        st[k].kind = k == 0 ? N60_STAGE_IMAGE : N60_STAGE_DEESS;
        st[k].stageId = 1 + k;
        st[k].laneA = 0;
        st[k].laneB = 1;
        st[k].params = k == 0 ? pi : pd;
        st[k].paramCount = k == 0 ? 8 : 12;
    }
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 2;
    d.stages = st;
    d.stageCount = 2;
    n60_graph *g = NULL;
    return n60_graph_build(&d, &g) == N60_STATUS_OK ? g : NULL;
}

static void post(n60_graph *g, const Cfg *c) {
    float pi[8], pd[12];
    img(c, pi);
    dee(c, pd);
    n60_param_record rec[20];
    int n = 0;
    for (uint32_t i = 0; i < 8; i++) { rec[n].stageId = 1; rec[n].paramIndex = i; rec[n].value = pi[i]; rec[n].reserved = 0; n++; }
    if (n60_graph_post_params(g, rec, (uint32_t)n) != N60_STATUS_OK) { fprintf(stderr, "post image failed\n"); exit(1); }
    n = 0;
    for (uint32_t i = 0; i < 12; i++) { rec[n].stageId = 2; rec[n].paramIndex = i; rec[n].value = pd[i]; rec[n].reserved = 0; n++; }
    if (n60_graph_post_params(g, rec, (uint32_t)n) != N60_STATUS_OK) { fprintf(stderr, "post deess failed\n"); exit(1); }
}

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const Cfg off = {0, 0, 0, 200, 4000, 1, 1, 1, 0, 3500, -1.5f, 0, 6500, -24, 4, -24, 2, 1, 50, 1};
    const Cfg cfgs[6] = {
        {1, 0, 0, 200, 4000, 1, 1, 1, 0, 3500, -1.5f, 0, 6500, -24, 4, -24, 2, 1, 50, 1},           /* wide mono */
        {2, 0, 0, 200, 4000, 1, 1, 1, 0, 3500, -1.5f, 0, 6500, -24, 4, -24, 2, 1, 50, 1},           /* true mono */
        {0, 1, 1, 180, 3000, 0.5f, 1.6f, 1.3f, 0, 3500, -1.5f, 0, 6500, -24, 4, -24, 2, 1, 50, 1},  /* widener */
        {0, 0, 0, 200, 4000, 1, 1, 1, 1, 4200, -4.5f, 0, 6500, -24, 4, -24, 2, 1, 50, 1},           /* de-harsh */
        {0, 0, 0, 200, 4000, 1, 1, 1, 0, 3500, -1.5f, 1, 6500, -36, 6, -18, 3, 2, 80, 1},           /* de-esser, dynamic EQ */
        {1, 1, 0, 150, 5000, 0.8f, 1.4f, 1.7f, 1, 5000, -3.0f, 1, 7500, -30, 8, -12, 1.5f, 0.5f, 30, 0},  /* everything, wideband */
    };
    int failures = 0;
#ifdef N60_E23_WRITE_CORPUS
    e23_open("kCorpus");
#else
    (void)kL; (void)kR;
#endif
    for (unsigned r = 0; r < 8; r++) {
        const double rate = rates[r];
        for (unsigned m = 0; m < 7; m++) {
            /* m 6 is a live change: starts as config 5, switches to `off` and back is covered by config 0 at SWITCH_AT. */
            const Cfg *c = m < 6 ? &cfgs[m] : &cfgs[0];
            const Cfg *c2 = m == 6 ? &cfgs[4] : c;
            unsigned seed = 7 + m;
            for (int i = 0; i < N; i++) {
                seed = seed * 1664525u + 1013904223u;
                float noise = 0.05f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                float burst = ((i / 20000) % 2) ? 1.0f : 0.25f;
                inL[i] = 0.3f * (float)sin(2.0 * M_PI * 440.0 * i / rate) + burst * 0.25f * (float)sin(2.0 * M_PI * 6800.0 * i / rate) + noise;
                inR[i] = 0.2f * (float)sin(2.0 * M_PI * 440.0 * i / rate + 1.0) + burst * 0.2f * (float)sin(2.0 * M_PI * 7000.0 * i / rate) - noise;
            }
#ifdef N60_E23_WRITE_CORPUS
            N60DynamicsSnapshot s1 = N60DynamicsSnapshotMakeBypassed(rate), s2 = N60DynamicsSnapshotMakeBypassed(rate);
            if (!apply(&s1, rate, c) || !apply(&s2, rate, c2)) { fprintf(stderr, "kernel setup failed %.0f %u\n", rate, m); return 1; }
            N60DynamicsRuntime *rt = calloc(1, sizeof(N60DynamicsRuntime));
            N60DynamicsRuntimeReset(rt);
            memcpy(kL, inL, sizeof inL);
            memcpy(kR, inR, sizeof inR);
            for (int i = 0; i < N; i++) N60DynamicsProcessCoreStereoFrame(rt, i < SWITCH_AT ? &s1 : &s2, &kL[i], &kR[i]);
            const N60DynamicsTelemetry tel = N60DynamicsRuntimeTelemetry(rt);
            free(rt);

#endif
            n60_stage_desc st[2];
            float pi[8], pd[12];
            n60_graph *g = build(rate, c, st, pi, pd);
            if (!g) { fprintf(stderr, "core build failed\n"); return 1; }
            for (int off2 = 0; off2 < N; off2 += 512) {
                if (off2 == SWITCH_AT && c2 != c) post(g, c2);
                const float *ip[2] = {inL + off2, inR + off2};
                float *op[2] = {cL + off2, cR + off2};
                n60_graph_process(g, ip, op, 512 > N - off2 ? (uint32_t)(N - off2) : 512u);
            }
            double moved = 0;
            for (int i = 0; i < N; i++) { const double e = fabs((double)cL[i] - inL[i]); if (e > moved) moved = e; }
            if (!(moved > 1e-3)) { fprintf(stderr, "FAIL stage did not change the signal\n"); failures++; }
            n60_dynamics_readback rb;
            memset(&rb, 0, sizeof rb);
            rb.structSize = sizeof rb;
            if (n60_graph_read_dynamics(g, 2, 0, &rb) != N60_STATUS_OK) { fprintf(stderr, "read_dynamics failed\n"); failures++; }
            const int latency = (int)n60_graph_latency_frames(g);
            double rec[STRIDE];
            rec[0] = rb.grNowDb;
            e23_summarise(cL, N, latency, rec + 1);
            e23_summarise(cR, N, latency, rec + 1 + E23_CH_VALUES);
#ifdef N60_E23_WRITE_CORPUS
            {
                double peak = 0, ss = 0;
                for (int i = 0; i < N; i++) {
                    double e = fabs((double)cL[i] - kL[i]);
                    if (e > peak) peak = e;
                    ss += e * e;
                    e = fabs((double)cR[i] - kR[i]);
                    if (e > peak) peak = e;
                    ss += e * e;
                }
                const double rms = sqrt(ss / (2.0 * N));
                const double grDiff = fabs((double)rb.grNowDb - tel.deEsserGainReductionDB);
                printf("rate %.0f cfg %u: peak %.1f dBFS rms %.1f dBFS gr %.3f (kernel %.3f)\n", rate, m,
                       20 * log10(peak + 1e-30), 20 * log10(rms + 1e-30), rb.grNowDb, tel.deEsserGainReductionDB);
            /* E6 S12h (G36): the core widener's crossover biquads are double; the kernel's are float and drift from the
             * exact response at the low corners (measured -35 dB relative error at 352.8 kHz, 80 Hz). With the widener on
             * the difference to the kernel is the kernel's own float error, so the bound is looser (peak -85, rms -95). */
            /* E20 S10 part 5 (G45): the de-harsh and de-esser shelves are float biquads run through the single-rounded fma
             * pair kernels, so they differ from the kernel's own float rounding by up to about -107 dBFS peak at 384 kHz
             * (measured; the response is identical). Bound -100 peak, -115 rms for those configs.
             * E7 S4: the core de-esser release pole and gain state are double now, the kernel's are still float, so at 352.8 kHz
             * (1 s release pole within 2.3 percent of float spacing) the difference is the kernel's own float error: measured
             * -95.3 dBFS peak (config 4 and the live-change config 6), rms -116.0 / -119.5, gain reduction within 0.001 dB.
             * Peak bound for those configs is -93 (was -100); every other rate stays under -100 (384 kHz -103.5). */
            const int shelf = c->harsh || c->ess || c2->harsh || c2->ess;
            const double peakBound = c->wide ? -85.0 : (shelf ? -93.0 : -120.0), rmsBound = c->wide ? -95.0 : (shelf ? -115.0 : -130.0);
            if (!(20 * log10(peak + 1e-30) < peakBound)) { fprintf(stderr, "FAIL peak rate %.0f m %u: %.1f dBFS (bound %.0f)\n", rate, m, 20 * log10(peak + 1e-30), peakBound); failures++; }
            if (!(20 * log10(rms + 1e-30) < rmsBound)) { fprintf(stderr, "FAIL rms rate %.0f m %u: %.1f dBFS (bound %.0f)\n", rate, m, 20 * log10(rms + 1e-30), rmsBound); failures++; }
            if (!(grDiff < 0.01)) { fprintf(stderr, "FAIL gain reduction\n"); failures++; }
            }
            e23_put(rec, STRIDE);
#else
            {
                const double *frozen = kCorpus + (size_t)(r * 7 + m) * STRIDE;
                char label[64];
                snprintf(label, sizeof label, "rate %.0f cfg %u L", rate, m);
                failures += e23_compare(rec + 1, frozen + 1, label);
                snprintf(label, sizeof label, "rate %.0f cfg %u R", rate, m);
                failures += e23_compare(rec + 1 + E23_CH_VALUES, frozen + 1 + E23_CH_VALUES, label);
                if (!(fabs(rec[0] - frozen[0]) < 0.01)) { fprintf(stderr, "FAIL gain reduction %.4f vs frozen %.4f at %.0f cfg %u\n", rec[0], frozen[0], rate, m); failures++; }
            }
#endif
            n60_graph_retire(g);
        }
    }
    (void)off;
#ifdef N60_E23_WRITE_CORPUS
    e23_close();
#endif
    if (failures) return 1;
    puts("n60core parity: IMAGE and DEESS match the frozen corpus");
    return 0;
}
