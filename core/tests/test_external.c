/* E6 S8e: the core EXTERNAL stage (host callback, ABI v13) at the eight standard rates: pass-through,
 * gain, declared latency, bypass and live toggle, failure, validation, and the rebuild fade (the host is
 * called once per block, the incoming snapshot adds the processor's effect instead of calling twice). */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "n60/graph.h"

#define N 256
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

typedef struct {
    float gain;
    int fail;
    unsigned delay;            /* frames of delay per channel (0 = none) */
    float ring[2][512];
    unsigned wp;
    int calls;
    unsigned lastFrames;
} Proc;

static int procFn(void *ctx, const float *const *in, float *const *out, uint32_t ch, uint32_t frames) {
    Proc *p = (Proc *)ctx;
    p->calls++;
    p->lastFrames = frames;
    if (p->fail) return 0;
    for (uint32_t c = 0; c < ch; c++) {
        for (uint32_t i = 0; i < frames; i++) {
            const float x = in[c][i];
            float y = x;
            if (p->delay != 0) {
                unsigned w = (p->wp + i) & 511u;
                p->ring[c][w] = x;
                y = p->ring[c][(w + 512u - p->delay) & 511u];
            }
            out[c][i] = y * p->gain;
        }
    }
    p->wp = (p->wp + frames) & 511u;
    return 1;
}

static n60_stage_desc stg(uint32_t kind, uint32_t id, uint64_t mask, const float *p, uint32_t np, uint32_t cap) {
    n60_stage_desc s;
    memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneMask = mask;
    if (mask == 0) s.laneA = N60_LANE_ALL;
    s.capacityFrames = cap;
    s.params = p;
    s.paramCount = np;
    return s;
}

static void desc(n60_graph_desc *d, double rate, const n60_stage_desc *st, uint32_t n) {
    memset(d, 0, sizeof *d);
    d->structSize = sizeof *d;
    d->abiVersion = N60_GRAPH_ABI_VERSION;
    d->sampleRate = rate;
    d->maxBlockFrames = N;
    d->inputChannels = d->outputChannels = 2;
    d->stages = st;
    d->stageCount = n;
}

static void signal(float *l, float *r, int total, double rate) {
    for (int i = 0; i < total; i++) {
        l[i] = 0.5f * (float)sin(2.0 * 3.14159265358979 * 997.0 * i / rate) + 0.01f * (float)(i % 7);
        r[i] = 0.4f * (float)sin(2.0 * 3.14159265358979 * 3100.0 * i / rate) - 0.01f * (float)(i % 5);
    }
}

#define TOTAL (N * 8)
static float inL[TOTAL], inR[TOTAL], outL[TOTAL], outR[TOTAL];

static void run(n60_graph *g, int blocks, int firstBlock) {
    for (int b = firstBlock; b < firstBlock + blocks; b++) {
        const float *ip[2] = {inL + b * N, inR + b * N};
        float *op[2] = {outL + b * N, outR + b * N};
        n60_graph_process(g, ip, op, N);
    }
}

static double maxDiff(const float *a, const float *b, int n) {
    double w = 0;
    for (int i = 0; i < n; i++) {
        double e = fabs((double)a[i] - b[i]);
        if (e > w) w = e;
    }
    return w;
}

int main(void) {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (unsigned r = 0; r < 8; r++) {
        const double rate = rates[r];
        signal(inL, inR, TOTAL, rate);
        const float active = 1.0f;
        n60_stage_desc st[1] = {stg(N60_STAGE_EXTERNAL, 1, 3, &active, 1, 0)};
        n60_graph_desc d;
        desc(&d, rate, st, 1);
        n60_graph *g = NULL;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build");

        /* No callback registered: the stage passes audio through. */
        run(g, 2, 0);
        CHECK(maxDiff(outL, inL, 2 * N) == 0.0, "rate %.0f: unregistered passes through", rate);

        Proc p;
        memset(&p, 0, sizeof p);
        p.gain = 1.0f;
        CHECK(n60_graph_set_external_processor(g, procFn, &p, 3) == N60_STATUS_BAD_ARGUMENT, "channels beyond the graph refused");
        CHECK(n60_graph_set_external_processor(g, procFn, &p, 2) == N60_STATUS_OK, "register");
        run(g, 2, 0);
        CHECK(maxDiff(outL, inL, 2 * N) == 0.0 && maxDiff(outR, inR, 2 * N) == 0.0, "rate %.0f: pass-through callback is bit-exact", rate);
        CHECK(p.calls == 2 && p.lastFrames == N, "one call per block (%d)", p.calls);

        /* Gain processor. */
        p.gain = 0.5f;
        p.calls = 0;
        run(g, 2, 0);
        double worst = 0;
        for (int i = 0; i < 2 * N; i++) worst = fmax(worst, fabs((double)outL[i] - 0.5 * inL[i]));
        CHECK(worst < 1e-7, "rate %.0f: gain processor (%.3g)", rate, worst);

        /* Live bypass: the callback is not called and audio passes unchanged; switching back on resumes. */
        n60_param_record rec = {0};
        rec.stageId = 1; rec.paramIndex = 0; rec.value = 0.0f;
        CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "post bypass");
        p.calls = 0;
        run(g, 2, 0);
        CHECK(p.calls == 0 && maxDiff(outL, inL, 2 * N) == 0.0, "rate %.0f: bypass skips the host", rate);
        rec.value = 1.0f;
        CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "post active");
        run(g, 1, 0);
        CHECK(p.calls == 1 && fabs((double)outL[10] - 0.5 * inL[10]) < 1e-7, "rate %.0f: active again", rate);

        /* Failure: the stage outputs silence and counts a fault. */
        p.fail = 1;
        run(g, 1, 0);
        uint64_t calls = 0, faults = 0;
        n60_graph_external_stats(g, &calls, &faults);
        CHECK(faults == 1 && maxDiff(outL, inL, N) > 0.1 && fabs(outL[10]) == 0.0 && fabs(outR[200]) == 0.0, "rate %.0f: failure silences the block", rate);
        p.fail = 0;
        CHECK(n60_graph_set_external_processor(g, NULL, NULL, 0) == N60_STATUS_OK, "clear");
        n60_graph_retire(g);

        /* Declared latency and a processor that really delays by that much. */
        n60_stage_desc ls[1] = {stg(N60_STAGE_EXTERNAL, 1, 3, &active, 1, 64)};
        desc(&d, rate, ls, 1);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build latency");
        CHECK(n60_graph_latency_frames(g) == 64, "rate %.0f: declared latency %u", rate, n60_graph_latency_frames(g));
        memset(&p, 0, sizeof p);
        p.gain = 1.0f;
        p.delay = 64;
        CHECK(n60_graph_set_external_processor(g, procFn, &p, 2) == N60_STATUS_OK, "register delay");
        run(g, 3, 0);
        worst = 0;
        for (int i = 64; i < 3 * N; i++) worst = fmax(worst, fabs((double)outL[i] - inL[i - 64]));
        CHECK(worst == 0.0, "rate %.0f: delayed processor lines up with the declared latency", rate);
        n60_graph_retire(g);

        /* Validation: two EXTERNAL stages, a bad active value, an excessive latency. */
        n60_stage_desc two[2] = {stg(N60_STAGE_EXTERNAL, 1, 1, &active, 1, 0), stg(N60_STAGE_EXTERNAL, 2, 2, &active, 1, 0)};
        desc(&d, rate, two, 2);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "two external stages refused");
        const float bad = 0.5f;
        n60_stage_desc bs[1] = {stg(N60_STAGE_EXTERNAL, 1, 3, &bad, 1, 0)};
        desc(&d, rate, bs, 1);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "bad active value refused");
        n60_stage_desc big[1] = {stg(N60_STAGE_EXTERNAL, 1, 3, &active, 1, N60_GRAPH_MAX_DELAY_FRAMES + 1)};
        desc(&d, rate, big, 1);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_BAD_ARGUMENT, "oversize latency refused");

        /* Rebuild fade: graph A = GAIN 1 then EXTERNAL (gain 0.5); B = GAIN 2 then the same. The host is
         * called exactly once per block throughout, and the settled output is 0.5 * 2 * input. */
        const float one = 1.0f, two_ = 2.0f;
        n60_stage_desc a[2] = {stg(N60_STAGE_GAIN, 1, 0, &one, 1, 0), stg(N60_STAGE_EXTERNAL, 2, 3, &active, 1, 0)};
        n60_stage_desc b[2] = {a[0], a[1]};
        b[0].params = &two_;
        desc(&d, rate, a, 2);
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build rebuild graph");
        memset(&p, 0, sizeof p);
        p.gain = 0.5f;
        CHECK(n60_graph_set_external_processor(g, procFn, &p, 2) == N60_STATUS_OK, "register for rebuild");
        n60_rebuild_options o = {sizeof o, 5.0f, 0.0f, 0};
        CHECK(n60_graph_set_rebuild_options(g, &o) == N60_STATUS_OK, "fade 5 ms");
        run(g, 1, 0);
        desc(&d, rate, b, 2);
        CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish");
        int blocks = 1;
        p.calls = 0;
        n60_rebuild_status rs;
        memset(&rs, 0, sizeof rs);
        rs.structSize = sizeof rs;
        int guard = 0;
        do {
            run(g, 1, blocks % 8);
            blocks++;
            n60_graph_get_rebuild_status(g, &rs);
        } while (rs.state != 0 && ++guard < 400);
        run(g, 1, 0);
        blocks++;
        CHECK(guard < 400 && rs.state == 0, "rebuild finished");
        CHECK(p.calls == blocks - 1, "rate %.0f: host called once per block through the rebuild (%d calls, %d blocks)", rate, p.calls, blocks - 1);
        worst = 0;
        for (int i = 0; i < N; i++) worst = fmax(worst, fabs((double)outL[i] - 1.0 * inL[i]));
        CHECK(worst < 1e-6, "rate %.0f: settled output is gain 2 x processor 0.5 (%.3g)", rate, worst);
        n60_graph_set_external_processor(g, NULL, NULL, 0);
        n60_graph_retire(g);
    }
    if (failures) return 1;
    printf("PASS\n");
    return 0;
}
