/* E6 S5: the core PROTECTION stage against the shipping kernel limiter and true-peak guard
 * (N60Protection.c) on the same stereo signal, at the eight standard rates, for the three
 * oversampling factors. Apple-only (the kernel sources use nullability qualifiers); the
 * Linux job runs the other core tests. Compares output sample by sample and the latency. */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "n60/graph.h"
#include "../../NotchSixty/Audio/Realtime/N60Protection.h"

#define N 9600
static float inL[N], inR[N], kL[N], kR[N], cL[N], cR[N];

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const struct { int limiter, tp, os; } modes[] = {{1, 1, 4}, {1, 0, 2}, {1, 0, 1}};
    int failures = 0;
    for (unsigned r = 0; r < 8; r++) {
        const double rate = rates[r];
        for (unsigned m = 0; m < 3; m++) {
            unsigned seed = 4242;
            for (int i = 0; i < N; i++) {
                seed = seed * 1664525u + 1013904223u;
                float burst = (i / 1200) % 2 ? 1.6f : 0.3f;
                inL[i] = burst * (float)sin(2.0 * 3.14159265358979 * 997.0 * i / rate) + 0.05f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                inR[i] = 0.7f * burst * (float)sin(2.0 * 3.14159265358979 * 1500.0 * i / rate);
            }
            N60ProtectionSnapshot snap = N60ProtectionSnapshotMakeBypassed(rate);
            if (!N60ProtectionSnapshotSetOversamplingFactor(&snap, (N60OversamplingFactor)modes[m].os) ||
                !N60ProtectionSnapshotSetLimiterAdvanced(&snap, true, -6.0f, 1.0f, 50.0f, 10.0f, modes[m].tp != 0)) {
                fprintf(stderr, "kernel snapshot setup failed at %.0f\n", rate);
                return 1;
            }
            N60ProtectionRuntime *rt = N60ProtectionRuntimeCreate();
            memcpy(kL, inL, sizeof inL);
            memcpy(kR, inR, sizeof inR);
            N60ProtectionRuntimeBeginBuffer(rt);
            for (int i = 0; i < N; i++) N60ProtectionProcessStereoFrame(rt, &snap, &kL[i], &kR[i]);
            N60ProtectionRuntimeDestroy(rt);

            const float p[7] = {1.0f, -6.0f, 1.0f, 50.0f, 10.0f, (float)modes[m].tp, (float)modes[m].os};
            n60_stage_desc st;
            memset(&st, 0, sizeof st);
            st.structSize = sizeof st;
            st.kind = N60_STAGE_PROTECTION;
            st.stageId = 1;
            st.laneA = N60_LANE_ALL;
            st.params = p;
            st.paramCount = 7;
            n60_graph_desc d;
            memset(&d, 0, sizeof d);
            d.structSize = sizeof d;
            d.abiVersion = N60_GRAPH_ABI_VERSION;
            d.sampleRate = rate;
            d.maxBlockFrames = N;
            d.inputChannels = d.outputChannels = 2;
            d.stages = &st;
            d.stageCount = 1;
            n60_graph *g = NULL;
            if (n60_graph_build(&d, &g) != N60_STATUS_OK) { fprintf(stderr, "core build failed\n"); return 1; }
            const float *ip[2] = {inL, inR};
            float *op[2] = {cL, cR};
            n60_graph_process(g, ip, op, N);
            const uint32_t lat = n60_graph_latency_frames(g);
            const uint32_t klat = N60ProtectionSnapshotLatencyFrames(&snap);
            double worst = 0;
            for (int i = 0; i < N; i++) {
                double e = fabs((double)cL[i] - kL[i]);
                if (e > worst) worst = e;
                e = fabs((double)cR[i] - kR[i]);
                if (e > worst) worst = e;
            }
            printf("rate %.0f os %d tp %d: worst deviation %.3g, latency core %u kernel %u\n", rate, modes[m].os, modes[m].tp, worst, lat, klat);
            if (lat != klat) { fprintf(stderr, "FAIL latency\n"); failures++; }
            if (!(worst < 2e-3)) { fprintf(stderr, "FAIL deviation\n"); failures++; }
            n60_graph_retire(g);
        }
    }
    if (failures) return 1;
    puts("n60core parity: PROTECTION matches the kernel limiter and true-peak guard");
    return 0;
}
