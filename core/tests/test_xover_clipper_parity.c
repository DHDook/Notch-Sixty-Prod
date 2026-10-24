/* E6 S8d group 4: the core STEREO_CROSSOVER stage and the PROTECTION soft clipper and gain rider against the
 * shipping kernel (N60Crossover.h, N60Protection.c) on the same stereo signal, at the eight standard rates.
 * Apple-only (the kernel sources use nullability qualifiers). Compares output sample by sample and the latency. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"
#include "../../NotchSixty/Audio/Realtime/N60Crossover.h"
#include "../../NotchSixty/Audio/Realtime/N60Protection.h"

#define N 9600
#define NLONG 800000
static float inL[NLONG], inR[NLONG], kL[NLONG], kR[NLONG], cL[NLONG], cR[NLONG];

static n60_graph *build(double rate, uint32_t frames, uint32_t kind, const float *p, uint32_t pc) {
    n60_stage_desc st;
    memset(&st, 0, sizeof st);
    st.structSize = sizeof st;
    st.kind = kind;
    st.stageId = 1;
    st.laneA = kind == N60_STAGE_STEREO_CROSSOVER ? 0 : N60_LANE_ALL;
    st.laneB = kind == N60_STAGE_STEREO_CROSSOVER ? 1 : 0;
    st.params = p;
    st.paramCount = pc;
    n60_graph_desc d;
    memset(&d, 0, sizeof d);
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = frames;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *g = NULL;
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) return NULL;
    return g;
}

static void makeSignal(double rate, int frames, float level) {
    unsigned seed = 4242;
    for (int i = 0; i < frames; i++) {
        seed = seed * 1664525u + 1013904223u;
        float burst = (i / 1200) % 2 ? 1.6f * level : 0.3f * level;
        inL[i] = burst * (float)sin(2.0 * 3.14159265358979 * 997.0 * i / rate) +
                 0.4f * (float)sin(2.0 * 3.14159265358979 * 55.0 * i / rate) +
                 0.05f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
        inR[i] = 0.7f * burst * (float)sin(2.0 * 3.14159265358979 * 1500.0 * i / rate) +
                 0.3f * (float)sin(2.0 * 3.14159265358979 * 40.0 * i / rate);
    }
}

static double worstDeviation(int frames) {
    double worst = 0;
    for (int i = 0; i < frames; i++) {
        double e = fabs((double)cL[i] - kL[i]);
        if (e > worst) worst = e;
        e = fabs((double)cR[i] - kR[i]);
        if (e > worst) worst = e;
    }
    return worst;
}

static int crossoverCase(double rate, int lr48, int mode, int align, int invert, float gain, double hz) {
    N60CrossoverSnapshot snap;
    if (!N60CrossoverSnapshotMake(rate, hz, lr48 ? N60CrossoverTopologyLinkwitzRiley48 : N60CrossoverTopologyLinkwitzRiley24,
                                  (N60CrossoverMonitorMode)mode, gain, invert != 0, true, &snap) ||
        !N60CrossoverSnapshotSetSubPhaseAlignment(rate, 63.0, 0.9, align != 0, &snap)) {
        fprintf(stderr, "kernel crossover setup failed at %.0f\n", rate);
        return 1;
    }
    makeSignal(rate, N, 1.0f);
    N60CrossoverPreciseState mL[4] = {{0}}, mR[4] = {{0}}, sub[4] = {{0}}, ap = {0, 0};
    for (int i = 0; i < N; i++) {
        float l = inL[i], r = inR[i], s = (inL[i] + inR[i]) * 0.5f;
        for (uint32_t k = 0; k < snap.sectionCount; k++) {
            l = N60CrossoverPreciseProcessSample(snap.mainsHighPass[k], &mL[k], l);
            r = N60CrossoverPreciseProcessSample(snap.mainsHighPass[k], &mR[k], r);
            s = N60CrossoverPreciseProcessSample(snap.subLowPass[k], &sub[k], s);
        }
        if (snap.subPhaseAlignmentEnabled) s = N60CrossoverPreciseProcessSample(snap.subPhaseAlignmentAllPass, &ap, s);
        s *= snap.subGainLinear;
        if (snap.subPolarityInverted) s = -s;
        if (mode == 1) { kL[i] = l; kR[i] = r; }
        else if (mode == 2) { kL[i] = s; kR[i] = s; }
        else { kL[i] = l + s; kR[i] = r + s; }
    }
    const float p[8] = {(float)hz, (float)lr48, (float)mode, gain, (float)invert, (float)align, 63.0f, 0.9f};
    n60_graph *g = build(rate, N, N60_STAGE_STEREO_CROSSOVER, p, 8);
    if (!g) { fprintf(stderr, "core crossover build failed at %.0f\n", rate); return 1; }
    const float *ip[2] = {inL, inR};
    float *op[2] = {cL, cR};
    n60_graph_process(g, ip, op, N);
    const double worst = worstDeviation(N);
    const uint32_t lat = n60_graph_latency_frames(g);
    n60_graph_retire(g);
    printf("crossover rate %.0f lr48 %d mode %d align %d inv %d: worst %.3g\n", rate, lr48, mode, align, invert, worst);
    if (lat != 0 || !(worst < 1e-5)) { fprintf(stderr, "FAIL crossover (latency %u)\n", lat); return 1; }
    return 0;
}

typedef struct {
    int limiter, tp, os, clipper, curve, comp, rider, speed;
    float drive, thr, knee, trim, target, maxRed, level;
    int frames;
    double tol;
} ProtCase;

static int protCase(double rate, const ProtCase *c) {
    N60ProtectionSnapshot snap = N60ProtectionSnapshotMakeBypassed(rate);
    if (!N60ProtectionSnapshotSetOversamplingFactor(&snap, (N60OversamplingFactor)c->os) ||
        !N60ProtectionSnapshotSetSoftClipperAdvanced(&snap, c->clipper != 0, c->drive, c->thr, c->knee,
                                                     (N60ClipperCurveType)c->curve, c->comp != 0, c->trim) ||
        !N60ProtectionSnapshotSetLimiterAdvanced(&snap, c->limiter != 0, -6.0f, 1.0f, 50.0f, 10.0f, c->tp != 0) ||
        !N60ProtectionSnapshotSetGainRider(&snap, c->rider != 0, c->target, c->maxRed, (N60GainRiderSpeed)c->speed)) {
        fprintf(stderr, "kernel protection setup failed at %.0f\n", rate);
        return 1;
    }
    makeSignal(rate, c->frames, c->level);
    memcpy(kL, inL, sizeof(float) * (size_t)c->frames);
    memcpy(kR, inR, sizeof(float) * (size_t)c->frames);
    N60ProtectionRuntime *rt = N60ProtectionRuntimeCreate();
    N60ProtectionRuntimeBeginBuffer(rt);
    for (int i = 0; i < c->frames; i++) N60ProtectionProcessStereoFrame(rt, &snap, &kL[i], &kR[i]);
    const float atten = N60ProtectionRuntimeTelemetry(rt).gainRiderAttenuationDB;
    N60ProtectionRuntimeDestroy(rt);

    const float p[18] = {(float)c->limiter, -6.0f, 1.0f, 50.0f, 10.0f, (float)c->tp, (float)c->os,
                         (float)c->clipper, c->drive, c->thr, c->knee, (float)c->curve, (float)c->comp, c->trim,
                         (float)c->rider, c->target, c->maxRed, (float)c->speed};
    n60_graph *g = build(rate, (uint32_t)c->frames, N60_STAGE_PROTECTION, p, 18);
    if (!g) { fprintf(stderr, "core protection build failed at %.0f\n", rate); return 1; }
    const float *ip[2] = {inL, inR};
    float *op[2] = {cL, cR};
    n60_graph_process(g, ip, op, (uint32_t)c->frames);
    const uint32_t lat = n60_graph_latency_frames(g);
    const uint32_t klat = N60ProtectionSnapshotLatencyFrames(&snap);
    const double worst = worstDeviation(c->frames);
    n60_graph_retire(g);
    printf("protection rate %.0f lim %d tp %d os %d clip %d curve %d rider %d: worst %.3g, latency core %u kernel %u, kernel rider %.2f dB\n",
           rate, c->limiter, c->tp, c->os, c->clipper, c->curve, c->rider, worst, lat, klat, atten);
    int bad = 0;
    if (lat != klat) { fprintf(stderr, "FAIL latency\n"); bad = 1; }
    if (!(worst < c->tol)) { fprintf(stderr, "FAIL deviation\n"); bad = 1; }
    if (c->rider && !(atten > 0.2f)) { fprintf(stderr, "FAIL rider never engaged: the case proves nothing\n"); bad = 1; }
    return bad;
}

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    int failures = 0;
    for (unsigned r = 0; r < 8; r++) {
        const double rate = rates[r];
        failures += crossoverCase(rate, 0, 0, 0, 0, 1.0f, 80.0);
        failures += crossoverCase(rate, 1, 0, 1, 1, 0.7f, 120.0);
        failures += crossoverCase(rate, 0, 1, 0, 0, 1.0f, 63.5);
        failures += crossoverCase(rate, 1, 2, 1, 0, 1.4f, 200.0);
        /* Clipper alone (limiter off) at each curve, then with the limiter; asymmetric trim and no compensation. */
        for (int curve = 0; curve < 4; curve++) {
            ProtCase c = {0, 0, curve % 3 == 0 ? 1 : (curve == 1 ? 2 : 4), 1, curve, curve != 2, 0, 0,
                          9.0f, -3.0f, 0.8f, curve == 3 ? 1.5f : 0.0f, 3.0f, 6.0f, 1.0f, N, 2e-3};
            failures += protCase(rate, &c);
        }
        ProtCase both = {1, 1, 4, 1, 2, 1, 0, 0, 6.0f, -2.0f, 1.0f, 0.5f, 3.0f, 6.0f, 1.0f, N, 2e-3};
        failures += protCase(rate, &both);
        /* Rider: a hot signal held for about 2.5 s so the 1 s sustained measure settles and the fast (3 s) rider moves. */
        const int frames = (int)(rate * 2.5) < NLONG ? (int)(rate * 2.5) : NLONG;
        ProtCase rider = {1, 0, 2, 0, 0, 0, 1, 0, 0.0f, 0.0f, 1.0f, 0.0f, 0.5f, 6.0f, 2.2f, frames, 3e-2};
        failures += protCase(rate, &rider);
        ProtCase both2 = {1, 1, 4, 1, 1, 1, 1, 0, 3.0f, -1.0f, 0.6f, 0.0f, 0.5f, 6.0f, 2.2f, frames < 400000 ? frames : 400000, 3e-2};
        failures += protCase(rate, &both2);
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    puts("n60core parity: STEREO_CROSSOVER, soft clipper and gain rider match the kernel");
    return 0;
}
