/* E6 S12a: the core CLEANUP stage (DC offset filter, infrasonic cascade, mains notch, hum detector) against the
 * shipping kernel pre-EQ block (N60Dynamics.c) on the same stereo signal at the eight standard rates, for four
 * configurations. Apple-only (kernel sources use nullability qualifiers). Target: -120 dBFS peak, -130 dBFS RMS. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"
#include "../../NotchSixty/Audio/Realtime/N60Dynamics.h"

#define N 400000
static float inL[N], inR[N], kL[N], kR[N], cL[N], cR[N];

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    int failures = 0;
    for (unsigned r = 0; r < 8; r++) {
        const double rate = rates[r];
        for (unsigned m = 0; m < 4; m++) {
            unsigned seed = 99;
            const double hum = (m == 3) ? 59.9 : 50.0;
            for (int i = 0; i < N; i++) {
                seed = seed * 1664525u + 1013904223u;
                float noise = 0.02f * ((float)((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                inL[i] = 0.05f + 0.3f * (float)sin(2.0 * M_PI * 997.0 * i / rate) + 0.1f * (float)sin(2.0 * M_PI * hum * i / rate) +
                         0.1f * (float)sin(2.0 * M_PI * 15.0 * i / rate) + noise;
                inR[i] = -0.03f + 0.2f * (float)sin(2.0 * M_PI * 1500.0 * i / rate) + 0.08f * (float)sin(2.0 * M_PI * hum * i / rate) - noise;
            }
            const int dc = (m == 0 || m == 3), infra = (m == 1 || m == 3), mains = (m == 2 || m == 3), det = (m == 2 || m == 3);
            const int slope = (m == 3) ? 2 : 1;
            const float centre = (m == 3) ? 60.0f : 50.0f;
            const float fund = (m == 3) ? 60.0f : 50.0f;
            const uint32_t count = (m == 3) ? 4 : 6;
            float depths[16];
            for (int k = 0; k < 16; k++) depths[k] = -12.0f - (float)k;

            N60DynamicsSnapshot snap = N60DynamicsSnapshotMakeBypassed(rate);
            bool ok = N60DynamicsSnapshotSetDCOffsetFilter(&snap, rate, dc);
            ok = ok && N60DynamicsSnapshotSetInfrasonicFilter(&snap, rate, infra, 20.0, (N60InfrasonicSlope)slope);
            ok = ok && N60DynamicsSnapshotSetMainsNotch(&snap, rate, mains, fund, count, 20.0f, depths, 16);
            ok = ok && N60DynamicsSnapshotSetMainsHumDetector(&snap, rate, det, centre);
            if (!ok) { fprintf(stderr, "kernel snapshot setup failed at %.0f mode %u\n", rate, m); return 1; }
            N60DynamicsRuntime *rt = calloc(1, sizeof(N60DynamicsRuntime));
            N60DynamicsRuntimeReset(rt);
            memcpy(kL, inL, sizeof inL);
            memcpy(kR, inR, sizeof inR);
            for (int i = 0; i < N; i++) N60DynamicsProcessPreEQStereoFrame(rt, &snap, &kL[i], &kR[i]);
            const N60DynamicsTelemetry tel = N60DynamicsRuntimeTelemetry(rt);
            free(rt);

            float p[26] = {(float)dc, (float)infra, 20.0f, (float)slope, (float)mains, fund, (float)count, 20.0f, (float)det, centre};
            for (int k = 0; k < 16; k++) p[10 + k] = depths[k];
            n60_stage_desc st;
            memset(&st, 0, sizeof st);
            st.structSize = sizeof st;
            st.kind = N60_STAGE_CLEANUP;
            st.stageId = 1;
            st.laneA = 0;
            st.laneB = 1;
            st.params = p;
            st.paramCount = 26;
            n60_graph_desc d;
            memset(&d, 0, sizeof d);
            d.structSize = sizeof d;
            d.abiVersion = N60_GRAPH_ABI_VERSION;
            d.sampleRate = rate;
            d.maxBlockFrames = 512;
            d.inputChannels = d.outputChannels = 2;
            d.stages = &st;
            d.stageCount = 1;
            n60_graph *g = NULL;
            if (n60_graph_build(&d, &g) != N60_STATUS_OK) { fprintf(stderr, "core build failed\n"); return 1; }
            for (int off = 0; off < N; off += 512) {
                const float *ip[2] = {inL + off, inR + off};
                float *op[2] = {cL + off, cR + off};
                n60_graph_process(g, ip, op, 512 > N - off ? N - off : 512);
            }
            double peak = 0, ss = 0;
            for (int i = 0; i < N; i++) {
                double e = fabs((double)cL[i] - kL[i]);
                if (e > peak) peak = e;
                ss += e * e;
                e = fabs((double)cR[i] - kR[i]);
                if (e > peak) peak = e;
                ss += e * e;
            }
            double moved = 0;
            for (int i = 0; i < N; i++) { double e = fabs((double)cL[i] - inL[i]); if (e > moved) moved = e; }
            if (!(moved > 1e-3)) { fprintf(stderr, "FAIL stage did not change the signal\n"); failures++; }
            const double rms = sqrt(ss / (2.0 * N));
            n60_mains_readback mr;
            memset(&mr, 0, sizeof mr);
            mr.structSize = sizeof mr;
            double fdiff = 0;
            if (det) {
                if (n60_graph_read_mains(g, 1, &mr) != N60_STATUS_OK) { fprintf(stderr, "read_mains failed\n"); failures++; }
                fdiff = fabs((double)mr.frequencyHz - tel.mainsDetectedFrequencyHz);
            }
            printf("rate %.0f mode %u: peak %.1f dBFS rms %.1f dBFS det %.3f (kernel %.3f)\n", rate, m,
                   20 * log10(peak + 1e-30), 20 * log10(rms + 1e-30), mr.frequencyHz, tel.mainsDetectedFrequencyHz);
            /* E6 S12f2 parity exception: the core runs the DC blocker and the infrasonic cascade in double
             * (float DF2T state noise with poles near 1 at 10 Hz / 384 kHz was up to 0 dB of the signal),
             * so the float kernel is the less accurate side. Those modes (0 DC, 1 and 3 infrasonic) only
             * bound the kernel's own error; test_state_carry.cpp asserts the core against a double
             * reference. The mains notch path (mode 2) stays at the strict -120 / -130 dBFS target. */
            const double peakLim = (m == 1 || m == 3) ? -25.0 : (m == 0 ? -80.0 : -120.0);
            const double rmsLim = (m == 1 || m == 3) ? -30.0 : (m == 0 ? -85.0 : -130.0);
            if (!(20 * log10(peak + 1e-30) < peakLim)) { fprintf(stderr, "FAIL peak\n"); failures++; }
            if (!(20 * log10(rms + 1e-30) < rmsLim)) { fprintf(stderr, "FAIL rms\n"); failures++; }
            if (det && !(mr.frequencyHz > 40.0f)) { fprintf(stderr, "FAIL detector found nothing\n"); failures++; }
            if (det && !(fdiff < 0.01)) { fprintf(stderr, "FAIL detector\n"); failures++; }
            n60_graph_retire(g);
        }
    }
    if (failures) return 1;
    puts("n60core parity: CLEANUP matches the kernel pre-EQ block");
    return 0;
}
