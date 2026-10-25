/* E6 S10: unified-graph parity suite (portable; no kernel needed). The graph-versus-kernel parity of
 * each stage lives in the other n60core parity harnesses; this suite pins the whole graph over a fixed
 * signal corpus (noise, sweep, impulse, clipping edges) and a fixed config corpus at the eight standard
 * rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384 kHz):
 *
 *  - front-pair equivalence: lanes 0 and 1 of every standard layout equal the stereo graph for each
 *    config (every stage on, and each stage alone);
 *  - fresh build equals live edit: a graph built with a setting equals a graph edited to it through the
 *    parameter mailbox, once the ramp has settled;
 *  - golden hashes: N-channel and binaural renders have no kernel reference, so a per-layout, per-rate
 *    hash of the lane-block energies (0.05 dB steps) is stored below. A mismatch means the render
 *    changed: regenerate only by an explicit, reviewed change (run with N60_PARITY_PRINT=1 and paste);
 *  - acoustic reference-lab case: the steady-state gain of a 1 kHz tone through a +6 dB peaking filter
 *    at 1 kHz is 6 dB at every rate, and the stereo graph is transparent with every stage off.
 *
 * N60_PARITY_FULL=1 runs the full corpus at all eight rates and prints render timings (macos-full);
 * otherwise the short corpus runs at 48, 192 and 384 kHz (pr.yml). Apple-only: the binaural stage uses
 * the platform FFT, so the goldens are pinned to the macOS arm64 toolchain. */
#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "n60/graph.h"

#define BLOCK 256u
#define MAXC 16u
#define NBLOCKS 28
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;
static int gFull = 0;

static uint32_t rngState = 1;
static float frand(void) {
    rngState = rngState * 1664525u + 1013904223u;
    return (float)((double)(rngState >> 8) / 8388608.0 - 1.0);
}

/* ---------- corpus ---------- */
/* Block index selects the segment: noise, a sweep, an impulse train, clipping edges, silence. */
static void corpusBlock(double rate, int blk, uint32_t lane, float *x, uint32_t n, uint32_t *sweepPos) {
    for (uint32_t i = 0; i < n; i++) {
        float v;
        if (blk < 10) {
            v = 0.5f * frand();
        } else if (blk < 16) {
            const double t = (double)(*sweepPos + i) / rate;
            v = 0.5f * (float)sin(2.0 * kPi * (50.0 * t + 0.5 * 40000.0 * t * t * (rate / 48000.0)) * 0.1 + 0.37 * lane);
        } else if (blk < 20) {
            v = (i == 5 + lane || i == 130) ? 0.9f : 0.0f;
        } else if (blk < 24) {
            v = (i & 32u) ? 1.4f : -1.4f;
            v *= (lane & 1u) ? 0.8f : 1.0f;
        } else {
            v = 0.0f;
        }
        x[i] = v;
    }
    if (blk >= 10 && blk < 16 && lane == 0) *sweepPos += n;
}

typedef struct { float in[MAXC][BLOCK], out[MAXC][BLOCK]; uint32_t ch; } IO;

static void run(n60_graph *g, IO *io, uint32_t frames) {
    const float *ip[MAXC];
    float *op[MAXC];
    for (uint32_t c = 0; c < io->ch; c++) { ip[c] = io->in[c]; op[c] = io->out[c]; }
    n60_status s = n60_graph_process(g, ip, op, frames);
    CHECK(s == N60_STATUS_OK, "process status %d", s);
}

static void post(n60_graph *g, uint32_t stageId, uint32_t idx, float v) {
    n60_param_record r = {stageId, idx, v, 0};
    n60_status s = n60_graph_post_params(g, &r, 1);
    CHECK(s == N60_STATUS_OK, "post %u/%u = %g gave %d", stageId, idx, v, s);
}

/* ---------- configs ---------- */
enum { CFG_ALL, CFG_INPUT_GAIN, CFG_MS, CFG_PEQ, CFG_DYN, CFG_CROSSFEED, CFG_OUT_GAIN, CFG_PROT, CFG_OFF, CFG_COUNT };
static const char *kCfgName[] = {"all", "input-gain", "mid-side", "peq", "dynamics", "crossfeed", "output-gain",
                                 "protection", "off"};

static void configOptions(n60_layout_options *o, int cfg, double rate, const float *peq) {
    const int all = cfg == CFG_ALL;
    o->inputGain = all || cfg == CFG_INPUT_GAIN ? 0.5f : 0.0f;
    o->midSide = all || cfg == CFG_MS;
    o->peq = all || cfg == CFG_PEQ ? peq : NULL;
    o->peqParamCount = o->peq ? 8 : 0;
    o->linkedDynamics = all || cfg == CFG_DYN;
    o->headphoneCrossfeed = all || cfg == CFG_CROSSFEED ? 0.3f : 0.0f;
    o->outputGain = all || cfg == CFG_OUT_GAIN ? 0.8f : 0.0f;
    o->protection = all || cfg == CFG_PROT;
    (void)rate;
}

static void peqFor(double rate, float *peq) {
    const float p[8] = {0, (float)(1000 * rate / 48000), 3, 1, 2, (float)(6000 * rate / 48000), -2, 0.7f};
    memcpy(peq, p, sizeof p);
}

static n60_graph *build(const n60_layout_options *o, n60_layout_graph **lgOut) {
    n60_layout_graph *lg = NULL;
    n60_graph *g = NULL;
    n60_status s = n60_layout_graph_build(o, &lg);
    CHECK(s == N60_STATUS_OK && lg, "layout graph build status %d", s);
    if (!lg) return NULL;
    s = n60_graph_build(n60_layout_graph_desc(lg), &g);
    CHECK(s == N60_STATUS_OK && g, "graph build status %d", s);
    *lgOut = lg;
    return g;
}

/* ---------- front-pair equivalence ---------- */
static void testFrontPair(double rate, int cfg) {
    float peq[8];
    peqFor(rate, peq);
    n60_layout st;
    n60_layout_standard(N60_LAYOUT_STEREO, &st);
    n60_layout_options os;
    memset(&os, 0, sizeof os);
    os.structSize = sizeof os;
    os.sampleRate = rate;
    os.maxBlockFrames = BLOCK;
    os.layout = &st;
    os.graphChannels = 2;
    configOptions(&os, cfg, rate, peq);
    static const uint32_t ids[] = {N60_LAYOUT_5_1, N60_LAYOUT_7_1, N60_LAYOUT_5_1_2, N60_LAYOUT_5_1_4,
                                   N60_LAYOUT_7_1_4, N60_LAYOUT_9_1_6};
    for (size_t k = 0; k < sizeof ids / sizeof ids[0]; k++) {
        n60_layout lay;
        n60_layout_standard(ids[k], &lay);
        n60_layout_options o = os;
        o.layout = &lay;
        o.graphChannels = lay.channelCount;
        n60_layout_graph *lg = NULL;
        n60_graph *g = build(&o, &lg);
        if (!g) continue;
        n60_layout_graph *lgS = NULL;
        n60_graph *gS = build(&os, &lgS);
        if (!gS) { n60_graph_retire(g); n60_layout_graph_free(lg); continue; }
        IO a, b;
        a.ch = 2;
        b.ch = lay.channelCount;
        rngState = 11;
        uint32_t sweepA = 0;
        double worst = 0, peak = 0;
        for (int blk = 0; blk < NBLOCKS; blk++) {
            for (uint32_t c = 0; c < 2; c++) {
                corpusBlock(rate, blk, c, a.in[c], BLOCK, c == 0 ? &sweepA : &(uint32_t){sweepA});
                memcpy(b.in[c], a.in[c], sizeof(float) * BLOCK);
            }
            for (uint32_t c = 2; c < lay.channelCount; c++) memset(b.in[c], 0, sizeof(float) * BLOCK);
            run(gS, &a, BLOCK);
            run(g, &b, BLOCK);
            for (uint32_t c = 0; c < 2; c++)
                for (uint32_t i = 0; i < BLOCK; i++) {
                    worst = fmax(worst, fabs((double)a.out[c][i] - b.out[c][i]));
                    peak = fmax(peak, fabs(a.out[c][i]));
                }
        }
        CHECK(worst < 1e-6, "rate %.0f cfg %s layout %u: front pair differs from stereo by %g (peak %g)", rate,
              kCfgName[cfg], ids[k], worst, peak);
        n60_graph_retire(g);
        n60_layout_graph_free(lg);
        n60_graph_retire(gS);
        n60_layout_graph_free(lgS);
    }
}

/* ---------- fresh build equals live edit ---------- */
static void testLiveEdit(double rate, uint32_t layoutId) {
    n60_layout lay;
    n60_layout_standard(layoutId, &lay);
    float peqA[8], peqB[8];
    peqFor(rate, peqA);
    memcpy(peqB, peqA, sizeof peqA);
    peqB[2] = -4.0f;
    n60_layout_options o;
    memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.sampleRate = rate;
    o.maxBlockFrames = BLOCK;
    o.layout = &lay;
    o.graphChannels = lay.channelCount;
    o.inputGain = 0.5f;
    o.outputGain = 0.8f;
    o.peq = peqA;
    o.peqParamCount = 8;
    n60_layout_graph *lgA = NULL, *lgB = NULL;
    n60_graph *edited = build(&o, &lgA);
    o.inputGain = 0.35f;
    o.outputGain = 0.6f;
    o.peq = peqB;
    n60_graph *fresh = build(&o, &lgB);
    if (!edited || !fresh) return;
    IO a, b;
    a.ch = b.ch = lay.channelCount;
    rngState = 21;
    /* Warm the edited graph on the old settings, then edit through the mailbox. */
    for (int blk = 0; blk < 4; blk++) {
        for (uint32_t c = 0; c < lay.channelCount; c++) for (uint32_t i = 0; i < BLOCK; i++) a.in[c][i] = 0.3f * frand();
        run(edited, &a, BLOCK);
    }
    post(edited, N60_LSTAGE_INPUT_GAIN, 0, 0.35f);
    post(edited, N60_LSTAGE_PEQ, 2, -4.0f);
    for (uint32_t c = 0; c < lay.channelCount; c++) post(edited, N60_LSTAGE_OUTPUT_GAIN + c, 0, 0.6f);
    double worst = 0;
    const int settle = (int)(rate * 0.25 / BLOCK) + 8; /* 250 ms covers the longest ramp */
    for (int blk = 0; blk < settle + 6; blk++) {
        for (uint32_t c = 0; c < lay.channelCount; c++)
            for (uint32_t i = 0; i < BLOCK; i++) { a.in[c][i] = b.in[c][i] = 0.3f * frand(); }
        run(edited, &a, BLOCK);
        run(fresh, &b, BLOCK);
        if (blk >= settle)
            for (uint32_t c = 0; c < lay.channelCount; c++)
                for (uint32_t i = 0; i < BLOCK; i++) worst = fmax(worst, fabs((double)a.out[c][i] - b.out[c][i]));
    }
    CHECK(worst < 2e-4, "rate %.0f layout %u: live edit differs from fresh build by %g", rate, layoutId, worst);
    n60_graph_retire(edited);
    n60_graph_retire(fresh);
    n60_layout_graph_free(lgA);
    n60_layout_graph_free(lgB);
}

/* ---------- goldens ---------- */
static uint64_t fnv(uint64_t h, int64_t v) {
    for (int i = 0; i < 8; i++) { h ^= (uint64_t)(v >> (8 * i)) & 0xffu; h *= 1099511628211ull; }
    return h;
}

static uint64_t renderHash(double rate, uint32_t layoutId, int binaural, double *msPerSec) {
    n60_layout lay;
    n60_layout_standard(layoutId, &lay);
    float peq[8];
    peqFor(rate, peq);
    enum { TAPS = 24 };
    static float ir[MAXC * 2 * TAPS];
    n60_binaural_profile p;
    memset(&p, 0, sizeof p);
    if (binaural) {
        uint32_t s = 99;
        for (uint32_t i = 0; i < lay.channelCount * 2 * TAPS; i++) {
            s = s * 1664525u + 1013904223u;
            ir[i] = 0.2f * ((float)(s >> 8) / 8388608.0f - 1.0f) * expf(-(float)(i % TAPS) / 6.0f);
        }
        p.structSize = sizeof p;
        p.taps = TAPS;
        p.orientations = 1;
        p.equalEarChannel = layoutId == N60_LAYOUT_5_1 ? 3 : -1;
        p.responses = ir;
    }
    n60_layout_options o;
    memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.sampleRate = rate;
    o.maxBlockFrames = BLOCK;
    o.layout = &lay;
    o.graphChannels = lay.channelCount;
    configOptions(&o, CFG_ALL, rate, peq);
    if (binaural) { o.mode = N60_MODE_BINAURAL; o.binaural = &p; }
    n60_layout_graph *lg = NULL;
    n60_graph *g = build(&o, &lg);
    if (!g) return 0;
    IO io;
    io.ch = lay.channelCount;
    rngState = 31;
    uint32_t sweep = 0;
    uint64_t h = 1469598103934665603ull;
    struct timespec t0, t1;
    double busy = 0;
    for (int blk = 0; blk < NBLOCKS; blk++) {
        for (uint32_t c = 0; c < lay.channelCount; c++) corpusBlock(rate, blk, c, io.in[c], BLOCK, c == 0 ? &sweep : &(uint32_t){sweep});
        clock_gettime(CLOCK_MONOTONIC, &t0);
        run(g, &io, BLOCK);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        busy += (double)(t1.tv_sec - t0.tv_sec) + 1e-9 * (double)(t1.tv_nsec - t0.tv_nsec);
        for (uint32_t c = 0; c < lay.channelCount; c++) {
            double e = 0;
            for (uint32_t i = 0; i < BLOCK; i++) { CHECK(isfinite(io.out[c][i]), "non-finite output"); e += (double)io.out[c][i] * io.out[c][i]; }
            double db = 10.0 * log10(e / BLOCK + 1e-14);
            h = fnv(h, (int64_t)floor(db / 0.05 + 0.5));
        }
    }
    *msPerSec = 1000.0 * busy / ((double)NBLOCKS * BLOCK / rate);
    n60_graph_retire(g);
    n60_layout_graph_free(lg);
    return h;
}

typedef struct { uint32_t layout; int binaural; double rate; uint64_t hash; } Golden;
#include "test_parity_suite_goldens.inc"

static void testGoldens(int print) {
    size_t seen = 0;
    static const uint32_t layouts[] = {N60_LAYOUT_STEREO, N60_LAYOUT_5_1, N60_LAYOUT_7_1, N60_LAYOUT_5_1_2,
                                       N60_LAYOUT_5_1_4, N60_LAYOUT_7_1_4, N60_LAYOUT_9_1_6};
    for (int bin = 0; bin < 2; bin++) {
        for (size_t l = 0; l < sizeof layouts / sizeof layouts[0]; l++) {
            if (bin && layouts[l] != N60_LAYOUT_STEREO && layouts[l] != N60_LAYOUT_5_1 && layouts[l] != N60_LAYOUT_7_1) continue;
            for (size_t r = 0; r < 8; r++) {
                const double rate = kRates[r];
                const int shortSet = rate == 48000 || rate == 192000 || rate == 384000;
                if (!gFull && !shortSet && !print) continue;
                double ms = 0;
                const uint64_t h = renderHash(rate, layouts[l], bin, &ms);
                if (print) { printf("    {%u, %d, %.0f, 0x%016llxull},\n", layouts[l], bin, rate, (unsigned long long)h); continue; }
                if (gFull) printf("timing layout %u%s rate %.0f: %.2f ms per second of audio\n", layouts[l], bin ? " binaural" : "", rate, ms);
                int found = 0;
                for (size_t k = 0; k < sizeof kGoldens / sizeof kGoldens[0]; k++) {
                    if (kGoldens[k].layout == layouts[l] && kGoldens[k].binaural == bin && kGoldens[k].rate == rate) {
                        found = 1;
                        seen++;
                        CHECK(kGoldens[k].hash == h, "golden mismatch layout %u%s rate %.0f: got 0x%016llx want 0x%016llx",
                              layouts[l], bin ? " binaural" : "", rate, (unsigned long long)h, (unsigned long long)kGoldens[k].hash);
                    }
                }
                CHECK(found, "no golden for layout %u%s rate %.0f", layouts[l], bin ? " binaural" : "", rate);
            }
        }
    }
    (void)seen;
}

/* ---------- acoustic reference lab ---------- */
static double toneRms(n60_graph *g, double rate, double hz, uint32_t seconds10ms) {
    IO io;
    io.ch = 2;
    double e = 0;
    uint64_t pos = 0;
    uint32_t count = 0;
    const uint32_t blocks = (uint32_t)(rate * 0.01 * seconds10ms / BLOCK);
    for (uint32_t b = 0; b < blocks; b++) {
        for (uint32_t i = 0; i < BLOCK; i++, pos++) {
            const float v = 0.25f * (float)sin(2.0 * kPi * hz * (double)pos / rate);
            io.in[0][i] = io.in[1][i] = v;
        }
        run(g, &io, BLOCK);
        if (b >= blocks / 2)
            for (uint32_t i = 0; i < BLOCK; i++) { e += (double)io.out[0][i] * io.out[0][i]; count++; }
    }
    return sqrt(e / count);
}

static void testReferenceLab(double rate) {
    n60_layout st;
    n60_layout_standard(N60_LAYOUT_STEREO, &st);
    n60_layout_options o;
    memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.sampleRate = rate;
    o.maxBlockFrames = BLOCK;
    o.layout = &st;
    o.graphChannels = 2;
    n60_layout_graph *lg = NULL;
    n60_graph *flat = build(&o, &lg);
    const float peq[4] = {0, (float)(1000.0 * rate / 48000.0), 6.0f, 1.0f};
    o.peq = peq;
    o.peqParamCount = 4;
    n60_layout_graph *lgP = NULL;
    n60_graph *peaked = build(&o, &lgP);
    if (!flat || !peaked) return;
    const double hz = 1000.0 * rate / 48000.0;
    const double ref = 0.25 / sqrt(2.0);
    const double flatDb = 20.0 * log10(toneRms(flat, rate, hz, 60) / ref);
    const double peakDb = 20.0 * log10(toneRms(peaked, rate, hz, 60) / ref);
    CHECK(fabs(flatDb) < 0.01, "rate %.0f: graph with every stage off is not transparent (%g dB)", rate, flatDb);
    CHECK(fabs(peakDb - 6.0) < 0.05, "rate %.0f: +6 dB peaking filter measures %g dB", rate, peakDb);
    n60_graph_retire(flat);
    n60_graph_retire(peaked);
    n60_layout_graph_free(lg);
    n60_layout_graph_free(lgP);
}

int main(void) {
    const char *full = getenv("N60_PARITY_FULL");
    gFull = full && full[0] == '1';
    const char *print = getenv("N60_PARITY_PRINT");
    if (print && print[0] == '1') { testGoldens(1); return 0; }
    for (size_t r = 0; r < 8; r++) {
        const double rate = kRates[r];
        const int shortSet = rate == 48000 || rate == 192000 || rate == 384000;
        if (!gFull && !shortSet) continue;
        for (int cfg = 0; cfg < CFG_COUNT; cfg++) {
            if (!gFull && cfg != CFG_ALL && cfg != CFG_DYN && cfg != CFG_MS) continue;
            testFrontPair(rate, cfg);
        }
        testLiveEdit(rate, N60_LAYOUT_STEREO);
        testLiveEdit(rate, N60_LAYOUT_5_1);
        testReferenceLab(rate);
    }
    testGoldens(0);
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts(gFull ? "n60core parity suite (full corpus): all checks passed" : "n60core parity suite (short corpus): all checks passed");
    return 0;
}
