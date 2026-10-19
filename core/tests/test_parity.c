/* E6 S3: parity harness skeleton. Compares the libn60core PEQ stage with the shipping
 * kernel biquad (N60Biquad.h, float state) on the same designs and signal, at the eight
 * standard rates. Apple-only (the kernel header uses nullability qualifiers); the Linux
 * job runs the other core tests. The core filters in double precision, so the kernel
 * float result is the one expected to deviate; the tolerance records how far. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"
#include "../../NotchSixty/Audio/Realtime/N60Biquad.h"

#define N 4096
#define TOL 5e-4 /* absolute, signal peak 0.5 */

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const struct { int type; double hz48, db, q; } sec[] = {
        {N60BiquadFilterTypePeaking, 1000, 6, 1.0},
        {N60BiquadFilterTypeLowShelf, 200, -4, 0.7},
        {N60BiquadFilterTypeHighPass, 60, 0, 0.707},
    };
    int failures = 0;
    for (unsigned r = 0; r < 8; r++) {
        double rate = rates[r];
        float params[12];
        N60BiquadCoefficients c[3];
        for (int s = 0; s < 3; s++) {
            double hz = sec[s].hz48 * rate / 48000.0;
            params[4 * s] = (float)sec[s].type;
            params[4 * s + 1] = (float)hz;
            params[4 * s + 2] = (float)sec[s].db;
            params[4 * s + 3] = (float)sec[s].q;
            if (!N60BiquadDesign(sec[s].type, rate, hz, sec[s].db, sec[s].q, &c[s])) { fprintf(stderr, "design failed\n"); return 1; }
        }
        n60_stage_desc st;
        memset(&st, 0, sizeof st);
        st.structSize = sizeof st;
        st.kind = N60_STAGE_PEQ;
        st.stageId = 1;
        st.laneA = N60_LANE_ALL;
        st.params = params;
        st.paramCount = 12;
        n60_graph_desc d;
        memset(&d, 0, sizeof d);
        d.structSize = sizeof d;
        d.abiVersion = N60_GRAPH_ABI_VERSION;
        d.sampleRate = rate;
        d.maxBlockFrames = N;
        d.inputChannels = d.outputChannels = 1;
        d.stages = &st;
        d.stageCount = 1;
        n60_graph *g = NULL;
        if (n60_graph_build(&d, &g) != N60_STATUS_OK) { fprintf(stderr, "build failed\n"); return 1; }

        static float in[N], out[N];
        unsigned seed = 12345;
        for (int i = 0; i < N; i++) {
            seed = seed * 1664525u + 1013904223u;
            in[i] = ((float)(seed >> 8) / 16777216.0f - 0.5f);
        }
        const float *ip[1] = {in};
        float *op[1] = {out};
        n60_graph_process(g, ip, op, N);

        N60BiquadState state[3];
        memset(state, 0, sizeof state);
        double worst = 0;
        for (int i = 0; i < N; i++) {
            float x = in[i];
            for (int s = 0; s < 3; s++) x = N60BiquadProcessSample(c[s], &state[s], x);
            double e = fabs((double)x - (double)out[i]);
            if (e > worst) worst = e;
        }
        printf("rate %.0f: worst deviation from kernel biquad %.3g\n", rate, worst);
        if (!(worst < TOL)) { fprintf(stderr, "FAIL rate %.0f exceeds %g\n", rate, TOL); failures++; }
        n60_graph_retire(g);
    }
    if (failures) return 1;
    puts("n60core parity: PEQ matches the kernel biquad within tolerance");
    return 0;
}
