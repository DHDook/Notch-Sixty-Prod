/* E6 S7: the libn60core binaural stage matches the legacy N60BinauralRenderer (stereo and 5.1,
 * equal-ear LFE, 128-frame latency) at the eight standard rates. Apple-only harness. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "n60/graph.h"
#include "N60BinauralRenderer.h"

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static uint32_t rs = 5;
static float frand(void) { rs = rs * 1664525u + 1013904223u; return (float)((double)(rs >> 8) / 8388608.0 - 1.0); }

static void one(double rate, N60ProgramLayoutIdentifier lid, uint32_t coreLayout, uint32_t N, uint32_t taps) {
    float *L = malloc(sizeof(float) * N * taps), *R = malloc(sizeof(float) * N * taps);
    float *ir = malloc(sizeof(float) * N * 2 * taps);
    for (uint32_t k = 0; k < N; k++)
        for (uint32_t t = 0; t < taps; t++) {
            const float a = 0.3f * frand() * expf(-(float)t / 80.0f), b = 0.3f * frand() * expf(-(float)t / 80.0f);
            L[k * taps + t] = a;
            R[k * taps + t] = b;
            ir[((size_t)k * 2) * taps + t] = a;
            ir[((size_t)k * 2 + 1) * taps + t] = b;
        }
    N60ProgramChannelLayout pl = N60ProgramChannelLayoutMakeStandard(lid);
    N60BinauralProfileDescriptor d = N60BinauralProfileDescriptorMake(rate, pl, N60BinauralProfileKindHRTF, taps);
    N60BinauralRenderer *ren = N60BinauralRendererCreate();
    CHECK(ren && N60BinauralRendererPrepareProfile(ren, d, L, R), "legacy prepare");
    if (!ren) return;

    n60_layout lay;
    n60_layout_standard(coreLayout, &lay);
    n60_binaural_profile p;
    memset(&p, 0, sizeof p);
    p.structSize = sizeof p;
    p.taps = taps;
    p.orientations = 1;
    p.equalEarChannel = N == 6 ? 3 : -1;
    p.responses = ir;
    n60_layout_options o;
    memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.sampleRate = rate;
    o.maxBlockFrames = 512;
    o.graphChannels = N < 2 ? 2 : N;
    o.layout = &lay;
    o.mode = N60_MODE_BINAURAL;
    o.binaural = &p;
    n60_layout_graph *lg = NULL;
    n60_graph *g = NULL;
    CHECK(n60_layout_graph_build(&o, &lg) == N60_STATUS_OK, "layout build");
    CHECK(n60_graph_build(n60_layout_graph_desc(lg), &g) == N60_STATUS_OK, "graph build");
    CHECK(N60BinauralRendererLatencyFrames(ren) == 128 && n60_graph_latency_frames(g) == 128, "latency");

    enum { TOTAL = 1800, B = 150 };
    double worst = 0, peak = 0;
    static float in[8][B], out[8][B];
    for (int pos = 0; pos < TOTAL; pos += B) {
        const float *ip[8];
        float *op[8];
        for (uint32_t c = 0; c < 8; c++) { ip[c] = in[c]; op[c] = out[c]; for (int i = 0; i < B; i++) in[c][i] = c < N ? 0.4f * frand() : 0.0f; }
        n60_graph_process(g, ip, op, B);
        for (int i = 0; i < B; i++) {
            float frame[8], l, r;
            for (uint32_t c = 0; c < N; c++) frame[c] = in[c][i];
            N60BinauralRendererProcessFrame(ren, frame, N, &l, &r);
            worst = fmax(worst, fmax(fabs(l - out[0][i]), fabs(r - out[1][i])));
            peak = fmax(peak, fmax(fabs(l), fabs(r)));
        }
    }
    CHECK(peak > 0.1 && worst < 1e-4, "rate %.0f layout %u: parity error %g (peak %g)", rate, coreLayout, worst, peak);
    n60_graph_retire(g);
    n60_layout_graph_free(lg);
    N60BinauralRendererDestroy(ren);
    free(L); free(R); free(ir);
}

int main(void) {
    static const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (int i = 0; i < 8; i++) {
        one(rates[i], N60ProgramLayoutStereo, N60_LAYOUT_STEREO, 2, 300);
        one(rates[i], N60ProgramLayoutFiveOne, N60_LAYOUT_5_1, 6, 700);
    }
    if (failures) return 1;
    puts("binaural stage matches the legacy renderer");
    return 0;
}
