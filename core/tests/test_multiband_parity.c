/* E6 S12d: the core MULTIBAND stage against the shipping kernel core frame (N60Dynamics.c) on the same stereo signal at
 * the eight standard rates, for LR4 and LR8 splits, sidechain high-pass, make-up, soft and hard knee, and a live
 * mid-stream change (retune, then disable so the stage ramps and parks). Apple-only. Target: -120 dBFS peak, -130 dBFS
 * RMS, and the per-band gain-reduction readback within 0.01 dB of the kernel telemetry (auto release off). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"
#include "../../NotchSixty/Audio/Realtime/N60Dynamics.h"

#define N 400384
#define SWITCH_AT 200192
static float inL[N], inR[N], kL[N], kR[N], cL[N], cR[N];

typedef struct {
    int on;
    float lowMid, midHigh;
    int lowSlope, highSlope; /* 0 LR4, 1 LR8 */
    float thr[3], ratio[3], atk[3], rel[3], knee[3], hpf[3], mk[3];
} Cfg;

static bool apply(N60DynamicsSnapshot *s, double rate, const Cfg *c) {
    return N60DynamicsSnapshotSetMultibandCompressorAdvanced(
        s, rate, c->on != 0, c->lowMid, c->midHigh,
        c->lowSlope ? N60CrossoverTopologyLinkwitzRiley48 : N60CrossoverTopologyLinkwitzRiley24,
        c->highSlope ? N60CrossoverTopologyLinkwitzRiley48 : N60CrossoverTopologyLinkwitzRiley24,
        c->thr[0], c->thr[1], c->thr[2], c->ratio[0], c->ratio[1], c->ratio[2], c->atk[0], c->atk[1], c->atk[2],
        c->rel[0], c->rel[1], c->rel[2], c->knee[0], c->knee[1], c->knee[2], c->hpf[0], c->hpf[1], c->hpf[2],
        c->mk[0], c->mk[1], c->mk[2]);
}

static void pack(const Cfg *c, float *p) {
    p[0] = (float)c->on; p[1] = c->lowMid; p[2] = c->midHigh; p[3] = (float)c->lowSlope; p[4] = (float)c->highSlope;
    for (int b = 0; b < 3; b++) {
        p[5 + b] = c->thr[b]; p[8 + b] = c->ratio[b]; p[11 + b] = c->atk[b]; p[14 + b] = c->rel[b];
        p[17 + b] = c->knee[b]; p[20 + b] = c->hpf[b]; p[23 + b] = c->mk[b]; p[26 + b] = 0.0f;
    }
}

static n60_graph *build(double rate, const Cfg *c, n60_stage_desc *st, float *p) {
    memset(st, 0, sizeof *st);
    pack(c, p);
    st->structSize = sizeof *st;
    st->kind = N60_STAGE_MULTIBAND;
    st->stageId = 7;
    st->laneA = 0;
    st->laneB = 1;
    st->params = p;
    st->paramCount = 29;
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = 2;
    d.stages = st;
    d.stageCount = 1;
    n60_graph *g = NULL;
    return n60_graph_build(&d, &g) == N60_STATUS_OK ? g : NULL;
}

static void post(n60_graph *g, const Cfg *c) {
    float p[29];
    pack(c, p);
    n60_param_record rec[29];
    int n = 0;
    for (uint32_t i = 0; i < 29; i++) {
        if (i == 3 || i == 4) continue; /* slopes are topology, not live */
        rec[n].stageId = 7; rec[n].paramIndex = i; rec[n].value = p[i]; rec[n].reserved = 0; n++;
    }
    if (n60_graph_post_params(g, rec, (uint32_t)n) != N60_STATUS_OK) { fprintf(stderr, "post failed\n"); exit(1); }
}

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const Cfg cfgs[5] = {
        {1, 120, 2500, 0, 0, {-30, -24, -28}, {4, 3, 6}, {10, 5, 2}, {120, 80, 60}, {6, 4, 0}, {0, 0, 0}, {0, 0, 0}},
        {1, 90, 4000, 1, 1, {-36, -30, -33}, {8, 5, 10}, {20, 8, 3}, {250, 120, 90}, {10, 6, 2}, {0, 0, 0}, {2, 0, -1}},
        {1, 180, 3000, 1, 0, {-26, -20, -24}, {3, 2.5f, 5}, {5, 5, 5}, {100, 100, 100}, {3, 3, 3}, {60, 40, 120}, {0, 1, 0}},
        {1, 250, 8000, 0, 1, {-40, -32, -22}, {20, 10, 2}, {1, 1, 1}, {10, 10, 10}, {0, 20, 8}, {0, 300, 0}, {-3, 3, 0}},
        {1, 60, 1000, 0, 0, {-18, -18, -18}, {2, 2, 2}, {200, 200, 200}, {1000, 1000, 1000}, {20, 20, 20}, {0, 0, 0}, {0, 0, 0}},
    };
    int failures = 0;
    for (unsigned r = 0; r < 8; r++) {
        const double rate = rates[r];
        for (unsigned m = 0; m < 7; m++) {
            /* m 5: retune live at SWITCH_AT; m 6: disable live at SWITCH_AT (ramp to neutral and park). */
            const Cfg *c = &cfgs[m < 5 ? m : 0];
            Cfg alt = cfgs[2];
            alt.lowSlope = c->lowSlope; alt.highSlope = c->highSlope;
            Cfg offc = *c;
            offc.on = 0;
            const Cfg *c2 = m == 5 ? &alt : (m == 6 ? &offc : c);
            unsigned seed = 11 + m;
            for (int i = 0; i < N; i++) {
                seed = seed * 1664525u + 1013904223u;
                float noise = 0.08f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                float burst = ((i / 20000) % 2) ? 1.0f : 0.25f;
                inL[i] = burst * (0.25f * (float)sin(2.0 * M_PI * 70.0 * i / rate) + 0.2f * (float)sin(2.0 * M_PI * 800.0 * i / rate) + 0.15f * (float)sin(2.0 * M_PI * 6800.0 * i / rate)) + noise;
                inR[i] = burst * (0.2f * (float)sin(2.0 * M_PI * 90.0 * i / rate + 1.0) + 0.25f * (float)sin(2.0 * M_PI * 1200.0 * i / rate) + 0.1f * (float)sin(2.0 * M_PI * 7200.0 * i / rate)) - noise;
            }
            N60DynamicsSnapshot s1 = N60DynamicsSnapshotMakeBypassed(rate), s2 = N60DynamicsSnapshotMakeBypassed(rate);
            if (!apply(&s1, rate, c) || !apply(&s2, rate, c2)) { fprintf(stderr, "kernel setup failed %.0f %u\n", rate, m); return 1; }
            N60DynamicsRuntime *rt = calloc(1, sizeof(N60DynamicsRuntime));
            N60DynamicsRuntimeReset(rt);
            memcpy(kL, inL, sizeof inL);
            memcpy(kR, inR, sizeof inR);
            for (int i = 0; i < N; i++) N60DynamicsProcessCoreStereoFrame(rt, i < SWITCH_AT ? &s1 : &s2, &kL[i], &kR[i]);
            const N60DynamicsTelemetry tel = N60DynamicsRuntimeTelemetry(rt);
            free(rt);

            n60_stage_desc st;
            float p[29];
            n60_graph *g = build(rate, c, &st, p);
            if (!g) { fprintf(stderr, "core build failed\n"); return 1; }
            for (int off = 0; off < N; off += 512) {
                if (off == SWITCH_AT && c2 != c) post(g, c2);
                const float *ip[2] = {inL + off, inR + off};
                float *op[2] = {cL + off, cR + off};
                n60_graph_process(g, ip, op, 512 > N - off ? (uint32_t)(N - off) : 512u);
            }
            double peak = 0, ss = 0, moved = 0;
            for (int i = 0; i < N; i++) {
                double e = fabs((double)cL[i] - kL[i]);
                if (e > peak) peak = e;
                ss += e * e;
                e = fabs((double)cR[i] - kR[i]);
                if (e > peak) peak = e;
                ss += e * e;
                e = fabs((double)cL[i] - inL[i]);
                if (e > moved) moved = e;
            }
            const double rms = sqrt(ss / (2.0 * N));
            n60_multiband_readback rb;
            memset(&rb, 0, sizeof rb);
            rb.structSize = sizeof rb;
            double grDiff = 0;
            if (n60_graph_read_multiband(g, 7, &rb) != N60_STATUS_OK) { fprintf(stderr, "read_multiband failed\n"); failures++; }
            else {
                grDiff = fmax(fabs((double)rb.grNowDb[0] - tel.multibandLowGainReductionDB),
                         fmax(fabs((double)rb.grNowDb[1] - tel.multibandMidGainReductionDB),
                              fabs((double)rb.grNowDb[2] - tel.multibandHighGainReductionDB)));
            }
            printf("rate %.0f cfg %u: peak %.1f dBFS rms %.1f dBFS gr %.3f/%.3f/%.3f (kernel %.3f/%.3f/%.3f)\n", rate, m,
                   20 * log10(peak + 1e-30), 20 * log10(rms + 1e-30), rb.grNowDb[0], rb.grNowDb[1], rb.grNowDb[2],
                   tel.multibandLowGainReductionDB, tel.multibandMidGainReductionDB, tel.multibandHighGainReductionDB);
            if (!(moved > 1e-3)) { fprintf(stderr, "FAIL stage did not change the signal\n"); failures++; }
            if (!(20 * log10(peak + 1e-30) < -120.0)) { fprintf(stderr, "FAIL peak\n"); failures++; }
            if (!(20 * log10(rms + 1e-30) < -130.0)) { fprintf(stderr, "FAIL rms\n"); failures++; }
            if (!(grDiff < 0.01)) { fprintf(stderr, "FAIL gain reduction\n"); failures++; }
            n60_graph_retire(g);
        }
    }
    if (failures) return 1;
    puts("n60core parity: MULTIBAND matches the kernel core frame");
    return 0;
}
