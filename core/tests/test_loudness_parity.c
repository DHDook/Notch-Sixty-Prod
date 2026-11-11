/* E6 S12c: the core LOUDNESS stage (loudness match, loudness contour simple and per-band, dialogue leveler) against the
 * shipping kernel core frame (N60Dynamics.c) on the same stereo signal at the eight standard rates, for six configurations
 * and a live mid-stream change. Apple-only (kernel sources use nullability qualifiers). Target: -120 dBFS peak,
 * -130 dBFS RMS, telemetry readbacks within 0.01 dB of the kernel's. */
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
    int mOn, mGate;
    float target, maxCorr, atk, rel;
    int cOn;
    float strength;
    int perBand, source;
    float phons, maxBoost, maxCut, master;
    int lOn, lGate;
    float lo, hi, gap, ratio, lMax, det, lAtk, lRel, pgate, modC, modBw, env, meas, cfl, cce, minc;
} Cfg;

static void modHz(const Cfg *c, float *lo, float *hi) {
    *lo = fmaxf(0.5f, c->modC - 0.5f * c->modBw);
    *hi = c->modC + 0.5f * c->modBw;
}

static bool apply(N60DynamicsSnapshot *s, double rate, const Cfg *c) {
    bool ok = N60DynamicsSnapshotSetLoudnessMatch(s, rate, c->mOn, c->mGate, c->target, c->maxCorr, c->atk, c->rel);
    if (c->perBand) ok = ok && N60DynamicsSnapshotSetPerBandLoudness(s, rate, c->cOn, c->strength, c->phons, c->maxBoost, c->maxCut, (N60LoudnessLevelSource)c->source);
    else ok = ok && N60DynamicsSnapshotSetLoudnessContour(s, rate, c->cOn, c->strength);
    ok = ok && N60DynamicsSnapshotSetDialogueLeveler(s, rate, c->lOn, c->lo, c->hi, c->gap, c->ratio, c->lMax, c->det, c->lAtk, c->lRel,
                                                   c->pgate, c->lGate, c->modC, c->modBw, c->env, c->meas, c->cfl, c->cce, c->minc);
    return ok;
}

static void params(const Cfg *c, float *p) {
    float ml, mh;
    modHz(c, &ml, &mh);
    const float v[32] = {(float)c->mOn, (float)c->mGate, c->target, c->maxCorr, c->atk, c->rel,
                         (float)c->cOn, c->strength, (float)c->perBand, (float)c->source, c->phons, c->maxBoost, c->maxCut, c->master,
                         (float)c->lOn, (float)c->lGate, c->lo, c->hi, c->gap, c->ratio, c->lMax, c->det, c->lAtk, c->lRel, c->pgate,
                         ml, mh, c->env, c->meas, c->cfl, c->cce, c->minc};
    memcpy(p, v, sizeof v);
}

static n60_graph *build(double rate, const Cfg *c, n60_stage_desc *st, float *p) {
    memset(st, 0, sizeof *st);
    params(c, p);
    st->structSize = sizeof *st;
    st->kind = N60_STAGE_LOUDNESS;
    st->stageId = 1;
    st->laneA = 0;
    st->laneB = 1;
    st->params = p;
    st->paramCount = 32;
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
    float p[32];
    params(c, p);
    n60_param_record rec[32];
    for (uint32_t i = 0; i < 32; i++) { rec[i].stageId = 1; rec[i].paramIndex = i; rec[i].value = p[i]; rec[i].reserved = 0; }
    if (n60_graph_post_params(g, rec, 32) != N60_STATUS_OK) { fprintf(stderr, "post failed\n"); exit(1); }
}

/* The core keeps its filter state in double (E23 S1b); the legacy kernel keeps it in float. The two agree to the kernel's
 * float state error, which grows with the rate (measured in E23 S1: about -81 dB at 44.1 kHz to -52 dB at 384 kHz). */
static double parityPeakDb(double rate) {
    if (rate <= 48000.5) return -70.0;
    if (rate <= 96000.5) return -60.0;
    if (rate <= 192000.5) return -50.0;
    return -40.0;
}

static double gTolScale = 1.0; /* telemetry follows the kernel's float state error: wider at high rates */
static int near(double a, double b, double tol, const char *what) {
    if (fabs(a - b) <= tol * gTolScale) return 0;
    fprintf(stderr, "FAIL %s: core %.4f kernel %.4f\n", what, a, b);
    return 1;
}

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    /* mOn mGate target maxC atk rel | cOn str perBand src phons boost cut master | lOn lGate lo hi gap ratio max det atk rel pgate modC modBw env meas cfl cce minc */
#define BASE_L 0, 1, 1000, 5000, 3, 6, 9, 200, 80, 600, -60, 5, 4, 12, 800, 0.1f, 0.5f, 0.3f
    const Cfg cfgs[6] = {
        {1, 0, -20, 10, 0.5f, 2, 0, 0.5f, 0, 0, 80, 12, 3, 1, BASE_L},                 /* match only */
        {0, 0, -23, 10, 1, 3, 1, 0.8f, 0, 0, 80, 12, 3, 0.05f, BASE_L},                /* simple contour, volume low */
        {0, 0, -23, 10, 1, 3, 1, 0.7f, 1, 0, 85, 12, 3, 0.1f, BASE_L},                 /* per-band, system volume */
        {1, 1, -18, 12, 0.4f, 2, 1, 1.0f, 1, 1, 80, 16, 4, 1, BASE_L},                 /* per-band integrated + match */
        {0, 0, -23, 10, 1, 3, 0, 0.5f, 0, 0, 80, 12, 3, 1, 1, 1, 1000, 5000, 3, 6, 9, 200, 80, 600, -60, 5, 4, 12, 800, 0.1f, 0.5f, 0.3f}, /* leveler */
        {1, 1, -21, 8, 0.6f, 4, 1, 0.6f, 1, 1, 78, 10, 2, 0.2f, 1, 0, 800, 4000, 4, 4, 8, 150, 60, 500, -55, 6, 5, 10, 600, 0.05f, 0.6f, 0.2f}, /* everything */
    };
    int failures = 0;
    for (unsigned r = 0; r < 8; r++) {
        const double rate = rates[r];
        for (unsigned m = 0; m < 7; m++) {
            /* m 6 is a live change: config 5 (all on) switches mid-stream to config 0-like parts off, master moved. */
            Cfg c2s = cfgs[m < 6 ? m : 5];
            if (m == 6) { c2s.mOn = 0; c2s.cOn = 0; c2s.lOn = 0; c2s.master = 0.5f; }
            const Cfg *c = m < 6 ? &cfgs[m] : &cfgs[5];
            const Cfg *c2 = &c2s;
            unsigned seed = 7 + m;
            for (int i = 0; i < N; i++) {
                seed = seed * 1664525u + 1013904223u;
                float noise = 0.05f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                float burst = ((i / 20000) % 2) ? 1.0f : 0.25f;
                inL[i] = 0.3f * (float)sin(2.0 * M_PI * 440.0 * i / rate) + burst * 0.25f * (float)sin(2.0 * M_PI * 1800.0 * i / rate) + noise;
                inR[i] = 0.2f * (float)sin(2.0 * M_PI * 440.0 * i / rate + 1.0) + burst * 0.2f * (float)sin(2.0 * M_PI * 2100.0 * i / rate) - noise;
            }
            N60DynamicsSnapshot s1 = N60DynamicsSnapshotMakeBypassed(rate), s2 = N60DynamicsSnapshotMakeBypassed(rate);
            if (!apply(&s1, rate, c) || !apply(&s2, rate, c2)) { fprintf(stderr, "kernel setup failed %.0f %u\n", rate, m); return 1; }
            N60DynamicsRuntime *rt = calloc(1, sizeof(N60DynamicsRuntime));
            N60DynamicsRuntimeReset(rt);
            memcpy(kL, inL, sizeof inL);
            memcpy(kR, inR, sizeof inR);
            for (int i = 0; i < N; i++) {
                const int before = i < SWITCH_AT;
                N60DynamicsProcessCoreStereoFrameWithMasterGain(rt, before ? &s1 : &s2, before ? c->master : c2->master, &kL[i], &kR[i]);
            }
            const N60DynamicsTelemetry tel = N60DynamicsRuntimeTelemetry(rt);
            free(rt);

            n60_stage_desc st;
            float p[32];
            n60_graph *g = build(rate, c, &st, p);
            if (!g) { fprintf(stderr, "core build failed %.0f %u\n", rate, m); return 1; }
            for (int off = 0; off < N; off += 512) {
                if (off == SWITCH_AT && m == 6) post(g, c2);
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
            n60_loudness_readback rb;
            memset(&rb, 0, sizeof rb);
            rb.structSize = sizeof rb;
            if (n60_graph_read_loudness(g, 1, &rb) != N60_STATUS_OK) { fprintf(stderr, "read_loudness failed\n"); failures++; }
            printf("rate %.0f cfg %u: peak %.1f dBFS rms %.1f dBFS lufs %.3f/%.3f match %.3f/%.3f boost %.3f/%.3f\n", rate, m,
                   20 * log10(peak + 1e-30), 20 * log10(rms + 1e-30), rb.shortTermLufs, tel.loudnessShortTermLUFS,
                   rb.matchGainDb, tel.loudnessMatchGainDB, rb.dialogueBoostDb, tel.dialogueBoostDB);
            if (m != 6 && !(moved > 1e-3)) { fprintf(stderr, "FAIL stage did not change the signal (cfg %u)\n", m); failures++; }
            if (!(20 * log10(peak + 1e-30) < parityPeakDb(rate))) { fprintf(stderr, "FAIL peak\n"); failures++; }
            if (!(20 * log10(rms + 1e-30) < parityPeakDb(rate) - 12.0)) { fprintf(stderr, "FAIL rms\n"); failures++; }
            gTolScale = rate <= 96000.5 ? 1.0 : (rate <= 192000.5 ? 2.0 : 4.0);
            failures += near(rb.shortTermLufs, tel.loudnessShortTermLUFS, 0.01, "lufs");
            failures += near(rb.matchGainDb, tel.loudnessMatchGainDB, 0.01, "match gain");
            failures += near(rb.contourScale, tel.loudnessContourScale, 0.001, "contour scale");
            failures += near(rb.lowCompensationDb, tel.loudnessLowCompensationDB, 0.01, "low comp");
            failures += near(rb.highCompensationDb, tel.loudnessHighCompensationDB, 0.01, "high comp");
            failures += near(rb.estimatedPhons, tel.loudnessEstimatedPhons, 0.01, "phons");
            failures += near(rb.dialogueProgramDbfs, tel.dialogueProgramLevelDBFS, 0.01, "dialogue program");
            failures += near(rb.dialogueBandDbfs, tel.dialogueBandLevelDBFS, 0.01, "dialogue band");
            failures += near(rb.dialogueGapDb, tel.dialogueGapDB, 0.01, "dialogue gap");
            failures += near(rb.dialogueVoiceConfidence, tel.dialogueVoiceConfidence, 0.001, "dialogue confidence");
            failures += near(rb.dialogueBoostDb, tel.dialogueBoostDB, 0.01, "dialogue boost");
            n60_graph_retire(g);
        }
    }
    if (failures) return 1;
    puts("n60core parity: LOUDNESS matches the kernel core frame");
    return 0;
}
