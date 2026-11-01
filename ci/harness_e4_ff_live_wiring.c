/*
 * E4 S25b: behavioural harness for the live feed-forward wiring in the render kernel. At the eight
 * standard rates, with silent programme audio and a 60 Hz reference:
 *  - unattached, and attached but never armed, the output is bit-identical (the wiring is dark);
 *  - Arm is refused on a short lead and with no weights, and nothing plays;
 *  - armed, the anti-noise follows the reference through the weights (gain within 5 per cent,
 *    residual under 5 per cent of the reference) and the second drive signal equals the output;
 *  - the output index advances by exactly the frames rendered (the ring stays on the output clock);
 *  - a reference that stops fades the output to exact silence within 10 ms plus two callbacks and
 *    trips (reason reference-lost), and stays silent; late reference frames are dropped, gaps zeroed;
 *  - the dead-man lease silences the feed-forward as it does the tonal canceller.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60RenderKernel.h"

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

#define BLOCK 128u
#define MAX_FRAMES 700000u
#define GAIN 0.1f

typedef struct {
    N60RenderKernel *k;
    double rate;
    float *out;      /* left output */
    float *drive;    /* left feed-forward drive frame */
    float *ref;      /* the reference as pushed */
    uint64_t frames;
    uint64_t pushed; /* next output index to push */
    bool feed;       /* the pump pushes reference */
    uint64_t ahead;  /* frames the pump stays ahead of the callback */
} Rig;

static float refSample(double rate, uint64_t i) {
    return 0.5f * sinf((float)(2.0 * M_PI * 60.0 * (double)i / rate));
}

static void rigInit(Rig *r, double rate) {
    memset(r, 0, sizeof(*r));
    r->rate = rate;
    r->k = N60RenderKernelCreate();
    r->out = calloc(MAX_FRAMES, sizeof(float));
    r->drive = calloc(MAX_FRAMES, sizeof(float));
    r->ref = calloc(MAX_FRAMES + 4 * BLOCK, sizeof(float));
    r->ahead = 4u * BLOCK;
    N60DSPGraphSnapshot snapshot = N60DSPGraphSnapshotMakeUnity(rate);
    if (r->k == NULL || !N60RenderKernelPublishSnapshot(r->k, snapshot)) {
        fprintf(stderr, "kernel setup failed\n");
        exit(2);
    }
}

static void rigFree(Rig *r) {
    N60RenderKernelDestroy(r->k);
    free(r->out); free(r->drive); free(r->ref);
}

static void pump(Rig *r) {
    if (!r->feed) return;
    const uint64_t want = N60RenderKernelFeedForwardLiveOutputIndex(r->k) + r->ahead + BLOCK;
    while (r->pushed < want) {
        float chunk[BLOCK];
        for (uint32_t i = 0; i < BLOCK; ++i) {
            chunk[i] = refSample(r->rate, r->pushed + i);
            r->ref[r->pushed + i] = chunk[i];
        }
        r->pushed = N60RenderKernelFeedForwardLivePushReference(r->k, r->pushed, chunk, BLOCK);
    }
}

static void render(Rig *r, uint64_t frames) {
    uint64_t done = 0;
    while (done < frames && r->frames + BLOCK <= MAX_FRAMES) {
        const uint32_t n = (uint32_t)(frames - done < BLOCK ? frames - done : BLOCK);
        pump(r);
        N60RenderKernelRenderContext ctx = N60RenderKernelBeginRender(r->k);
        N60RenderKernelPrepareFeedForward(r->k, n);
        for (uint32_t i = 0; i < n; ++i) {
            float l = 0.0f, rr = 0.0f, dl = 0.0f, dr = 0.0f;
            N60RenderKernelProcessStereoFrameInContext(r->k, &ctx, 0.0f, 0.0f, &l, &rr);
            N60RenderKernelGetFeedForwardDriveFrame(r->k, &dl, &dr);
            r->out[r->frames + i] = l;
            r->drive[r->frames + i] = dl;
        }
        N60RenderKernelEndRender(r->k, &ctx, n);
        r->frames += n;
        done += n;
    }
}

static double peakRange(const float *x, uint64_t from, uint64_t to) {
    double p = 0.0;
    for (uint64_t i = from; i < to; ++i) if (fabs(x[i]) > p) p = fabs(x[i]);
    return p;
}

int main(void) {
    for (size_t ri = 0; ri < sizeof(kRates) / sizeof(kRates[0]); ++ri) {
        const double rate = kRates[ri];
        const uint64_t half = (uint64_t)(rate * 0.5);
        const uint64_t tenMs = (uint64_t)(rate * 0.010);
        const uint32_t D = (uint32_t)(rate / 4000.0);
        (void)D;

        /* 1. Dark: unattached and attached-idle outputs are bit-identical. */
        Rig a; rigInit(&a, rate);
        render(&a, half);
        Rig b; rigInit(&b, rate);
        CHECK(N60RenderKernelAttachFeedForwardLive(b.k, rate, 1.0), "attach failed at %.0f", rate);
        b.feed = true;
        render(&b, half);
        CHECK(memcmp(a.out, b.out, half * sizeof(float)) == 0, "attached-idle output differs at %.0f", rate);
        CHECK(peakRange(b.drive, 0, half) == 0.0, "idle drive not silent at %.0f", rate);
        const N60RenderKernelFeedForwardLiveStatus idle = N60RenderKernelFeedForwardLiveGetStatus(b.k);
        CHECK(idle.attached && idle.filter.state == N60FeedForwardLiveIdle, "idle state at %.0f", rate);
        CHECK(idle.outputIndex == (uint64_t)((half + BLOCK - 1) / BLOCK) * BLOCK
              || idle.outputIndex == half, "output index %llu after %llu frames at %.0f",
              (unsigned long long)idle.outputIndex, (unsigned long long)half, rate);

        /* 2. Gate: no weights, then a short lead, both refused. */
        CHECK(N60RenderKernelFeedForwardLiveArm(b.k, 0.010, 0.005) == N60FeedForwardLiveArmNoWeights,
              "arm without weights not refused at %.0f", rate);
        float w[512] = {0}, z[512] = {0};
        w[0] = -GAIN;
        CHECK(N60RenderKernelFeedForwardLiveSetWeights(b.k, w, z, 1u), "set weights failed at %.0f", rate);
        CHECK(N60RenderKernelFeedForwardLiveArm(b.k, 0.001, 0.005) == N60FeedForwardLiveArmShortLead,
              "short lead not refused at %.0f", rate);
        uint64_t mark = b.frames;
        render(&b, half / 2);
        CHECK(peakRange(b.out, mark, b.frames) == 0.0, "output after refused arm at %.0f", rate);

        /* 3. Armed: out follows the reference through the weight, drive equals the output. */
        CHECK(N60RenderKernelFeedForwardLiveArm(b.k, 0.010, 0.005) == N60FeedForwardLiveArmOK,
              "arm refused at %.0f", rate);
        mark = b.frames;
        render(&b, half);
        const uint64_t from = mark + (uint64_t)(rate * 0.2), to = b.frames;
        double num = 0.0, den = 0.0;
        for (uint64_t i = from; i < to; ++i) { num += (double)b.out[i] * b.ref[i]; den += (double)b.ref[i] * b.ref[i]; }
        const double gain = num / den;
        /* The expected gain is whatever the standalone filter gives the same weights and reference. */
        N60FeedForwardLiveConfig cfg = {0};
        cfg.sampleRate = rate; cfg.maxBlockFrames = 8192u; cfg.peakLimit = 1.0;
        N60FeedForwardLive *solo = N60FeedForwardLiveCreate(&cfg);
        CHECK(solo != NULL && N60FeedForwardLiveSetWeights(solo, w, z, 1u), "standalone setup at %.0f", rate);
        CHECK(N60FeedForwardLiveArm(solo, 0.010, 0.005) == N60FeedForwardLiveArmOK, "standalone arm");
        const uint64_t soloFrames = (uint64_t)(rate * 0.6);
        float *soloL = calloc(soloFrames, sizeof(float)), *soloR = calloc(soloFrames, sizeof(float));
        for (uint64_t i = 0; i + BLOCK <= soloFrames; i += BLOCK)
            N60FeedForwardLiveProcess(solo, b.ref + mark - mark + i, soloL + i, soloR + i, BLOCK);
        double sn = 0.0, sd = 0.0;
        for (uint64_t i = (uint64_t)(rate * 0.2); i + BLOCK <= soloFrames; ++i) { sn += (double)soloL[i] * b.ref[i]; sd += (double)b.ref[i] * b.ref[i]; }
        const double expected = sn / sd;
        free(soloL); free(soloR); N60FeedForwardLiveDestroy(solo);
        double res = 0.0;
        for (uint64_t i = from; i < to; ++i) { const double e = b.out[i] - gain * b.ref[i]; res += e * e; }
        CHECK(fabs(expected) > 0.01 && fabs(gain - expected) < 0.05 * fabs(expected),
              "armed gain %.4f, standalone %.4f at %.0f", gain, expected, rate);
        CHECK(sqrt(res / den) < 0.05, "armed residual %.4f at %.0f", sqrt(res / den), rate);
        double driveErr = 0.0;
        for (uint64_t i = from; i < to; ++i) driveErr = fmax(driveErr, fabs(b.drive[i] - b.out[i]));
        CHECK(driveErr < 1e-6, "drive differs from output by %g at %.0f", driveErr, rate);
        CHECK(N60RenderKernelFeedForwardLiveGetStatus(b.k).referenceUnderruns == 0u, "underruns while fed at %.0f", rate);

        /* 4. Reference stops: silence within 10 ms plus two callbacks, tripped, stays silent. */
        b.feed = false;
        const uint64_t stopAt = N60RenderKernelFeedForwardLiveOutputIndex(b.k) + b.ahead + BLOCK;
        /* Play out what was pushed, then starve. */
        render(&b, stopAt - N60RenderKernelFeedForwardLiveOutputIndex(b.k) + 2u * BLOCK);
        mark = b.frames;
        render(&b, tenMs + 2u * BLOCK);
        const uint64_t quietFrom = b.frames;
        render(&b, half / 4);
        CHECK(peakRange(b.out, quietFrom, b.frames) == 0.0, "output not silent after reference loss at %.0f", rate);
        const N60RenderKernelFeedForwardLiveStatus lost = N60RenderKernelFeedForwardLiveGetStatus(b.k);
        CHECK(lost.filter.state == N60FeedForwardLiveTripped
              && lost.filter.tripReason == N60FeedForwardLiveTripReferenceLost,
              "state %u reason %u after loss at %.0f", lost.filter.state, lost.filter.tripReason, rate);
        CHECK(lost.referenceUnderruns >= 2u, "underruns %llu at %.0f", (unsigned long long)lost.referenceUnderruns, rate);
        (void)mark;
        CHECK(N60RenderKernelFeedForwardLiveArm(b.k, 0.010, 0.005) == N60FeedForwardLiveArmTripped,
              "tripped filter re-armed without reset at %.0f", rate);

        /* 5. Late frames are dropped, a gap is zero-filled (control-plane check on a fresh rig). */
        Rig c; rigInit(&c, rate);
        CHECK(N60RenderKernelAttachFeedForwardLive(c.k, rate, 1.0), "attach c failed");
        render(&c, 4u * BLOCK);
        float ones[BLOCK];
        for (uint32_t i = 0; i < BLOCK; ++i) ones[i] = 1.0f;
        const uint64_t idx = N60RenderKernelFeedForwardLiveOutputIndex(c.k);
        CHECK(idx == 4u * BLOCK, "output index %llu, expected %u", (unsigned long long)idx, 4u * BLOCK);
        CHECK(N60RenderKernelFeedForwardLivePushReference(c.k, idx - BLOCK, ones, BLOCK) == idx,
              "late push return value");
        CHECK(N60RenderKernelFeedForwardLiveGetStatus(c.k).referenceAheadFrames == 0u, "late frames were kept");
        CHECK(N60RenderKernelFeedForwardLivePushReference(c.k, idx + BLOCK, ones, BLOCK) == idx + 2u * BLOCK,
              "gap push return value");
        CHECK(N60RenderKernelFeedForwardLiveGetStatus(c.k).referenceAheadFrames == 2u * BLOCK, "gap push not recorded");

        /* 6. Lease: a lapsed dead-man lease silences the feed-forward too. */
        Rig d; rigInit(&d, rate);
        CHECK(N60RenderKernelAttachFeedForwardLive(d.k, rate, 1.0), "attach d failed");
        d.feed = true;
        CHECK(N60RenderKernelFeedForwardLiveSetWeights(d.k, w, z, 1u), "weights d");
        CHECK(N60RenderKernelFeedForwardLiveArm(d.k, 0.010, 0.005) == N60FeedForwardLiveArmOK, "arm d");
        N60RenderKernelRenewActiveQuietZoneLease(d.k, (uint64_t)(rate * 0.4));
        render(&d, (uint64_t)(rate * 0.3));
        CHECK(peakRange(d.out, (uint64_t)(rate * 0.2), d.frames) > 0.5 * GAIN * 0.5, "no output before lease lapse at %.0f", rate);
        render(&d, (uint64_t)(rate * 0.3));
        const uint64_t after = d.frames;
        render(&d, tenMs);
        CHECK(peakRange(d.out, after - 1, d.frames) == 0.0 || peakRange(d.out, after, d.frames) < 1e-6,
              "lease lapse did not silence feed-forward at %.0f", rate);

        rigFree(&a); rigFree(&b); rigFree(&c); rigFree(&d);
    }
    if (failures == 0) printf("e4_ff_live_wiring: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
