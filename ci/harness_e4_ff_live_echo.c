/*
 * E4 S22b3: behavioural harness for the echo stage of the live feed-forward filter (the speaker-to-
 * reference leakage neutralisation in N60FeedForwardLive.h) at the eight standard rates.
 *
 * Plant: two speakers driven by independent programme noise. Each leaks to the reference microphone
 * through a bulk delay plus a decaying impulse response of four resonant modes between 38 and 120 Hz
 * (time constants 20 to 25 ms, so the response is about 128 ms long), after a pump/plant delay of
 * 25 ms plus an offset (+4 ms and -6 ms). The leakage is built from exact two-pole resonators at the
 * native rate; the model handed to the stage is that impulse response sampled at fd (D h(kD)), the
 * way the shadow's mean taps describe it. Reference noise is 40 dB below the leakage.
 *
 * The harness plays the part of the render kernel and the bridge: each callback pushes the previous
 * callback's final output pair (programme plus anti-noise) as the drive, generates the reference for
 * this callback from drive that is already rendered, and calls Process.
 *
 * Cases (all at the eight rates):
 *   1  lock within 6 s of programme, lag within a quarter of an fd sample, at least 20 dB removal in
 *      31.5-125 Hz (measured on the output of an armed unity filter against an oracle that sees no
 *      leakage), and a model/timing published while armed waits for an idle filter;
 *   2  a discontinuity while idle drops the lock; the filter arms only when locked; zero-filled and
 *      underrun spans stay zero; a discontinuity while armed trips EchoAlignmentLost within a block
 *      and the output is silent after the 10 ms fade; the trip latches;
 *   3  feedback neutralisation: anti-noise leaking into the reference with loop gain 1.5. Without
 *      removal the output grows (the control); with removal it is within 0.5 dB of the run with no
 *      leakage. A forced wrong lag then trips EchoDiverged inside 400 ms (250 ms window plus the plant response) and fades in 10 ms;
 *   4  a reference unrelated to the drive never locks and no output is produced;
 *   5  block sizes 32 to 512 and a variable pattern lock to the same lag;
 *   6  a lag shorter than the block plus the chain cannot lock;
 *   7  with no echo model set the output is bit-identical to the filter never told about an echo.
 */
#include <complex.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60FeedForwardLive.h"

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
#define RATE_COUNT (sizeof kRates / sizeof kRates[0])
#define TWO_PI 6.283185307179586
#define MAX_BLOCK 4096u
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

static uint32_t factor_for(double fs) { return (uint32_t)(fs / 4000.0); }

static N60FeedForwardLive *make(double fs) {
    N60FeedForwardLiveConfig config = {fs, MAX_BLOCK, 0, 0, 1.0, 0.05};
    N60FeedForwardLive *live = N60FeedForwardLiveCreate(&config);
    if (!live) { fprintf(stderr, "FAIL create at %g\n", fs); failures++; exit(1); }
    return live;
}

/* ---- random numbers ------------------------------------------------------------------------ */

static double urand(uint64_t *s) {
    *s ^= *s >> 12; *s ^= *s << 25; *s ^= *s >> 27;
    const uint64_t v = *s * 2685821657736338717ull;
    return ((double)(v >> 11) / 9007199254740992.0) * 2.0 - 1.0;
}
static double grand(uint64_t *s) {   /* unit variance */
    return (urand(s) + urand(s) + urand(s) + urand(s)) * 0.8660254037844386;
}

/* ---- the plant ----------------------------------------------------------------------------- */

#define MODES 4
typedef struct { double f, tau, w; } Mode;
static const Mode kModes[2][MODES] = {
    {{38, 0.025, 1.0}, {55, 0.025, 0.8}, {83, 0.022, 0.6}, {110, 0.020, 0.5}},
    {{45, 0.025, 0.7}, {63, 0.025, 1.0}, {97, 0.022, 0.5}, {120, 0.020, 0.6}},
};

typedef struct {
    double fs, scale, sumsq;           /* sumsq: sum of h^2 of both speakers (white-programme power gain) */
    uint32_t D, bulk[2], lagExtra;     /* bulk at fd, lagExtra at the native rate */
    double c1[2][MODES], c2[2][MODES], b1[2][MODES], y1[2][MODES], y2[2][MODES], u1[2];
} Plant;

static double complex mode_response(const Mode *m, double fs, double omega) {
    const double r = exp(-1.0 / (m->tau * fs)), w = TWO_PI * m->f / fs;
    return m->w * (1.0 / (1.0 - r * cexp(I * (w - omega))) - 1.0 / (1.0 - r * cexp(-I * (w + omega)))) / (2.0 * I);
}

static void plant_init(Plant *p, double fs, uint32_t bulk0, uint32_t bulk1, uint32_t lag_extra, double peak) {
    memset(p, 0, sizeof *p);
    p->fs = fs; p->D = factor_for(fs); p->bulk[0] = bulk0; p->bulk[1] = bulk1; p->lagExtra = lag_extra;
    double best = 0;
    for (double f = 20; f <= 160; f += 0.25) {
        const double omega = TWO_PI * f / fs;
        double complex total = 0;
        for (int c = 0; c < 2; ++c) {
            double complex h = 0;
            for (int i = 0; i < MODES; ++i) h += mode_response(&kModes[c][i], fs, omega);
            total += cexp(-I * omega * ((double)p->bulk[c] * p->D + lag_extra)) * h;
        }
        if (cabs(total) > best) best = cabs(total);
    }
    p->scale = peak / best;
    for (int c = 0; c < 2; ++c)
        for (int i = 0; i < MODES; ++i) {
            const Mode *m = &kModes[c][i];
            const double r = exp(-1.0 / (m->tau * fs)), w = TWO_PI * m->f / fs;
            p->c1[c][i] = 2.0 * r * cos(w);
            p->c2[c][i] = -r * r;
            p->b1[c][i] = p->scale * m->w * r * sin(w);
        }
    const uint32_t span = (uint32_t)(0.4 * fs);
    for (int c = 0; c < 2; ++c)
        for (uint32_t j = 1; j < span; ++j) {
            double h = 0;
            for (int i = 0; i < MODES; ++i) {
                const Mode *m = &kModes[c][i];
                h += m->w * exp(-(double)j / (m->tau * fs)) * sin(TWO_PI * m->f * (double)j / fs);
            }
            p->sumsq += p->scale * p->scale * h * h;
        }
}

/* The model at fd: tap k = D h(kD), bulk delay in the model struct. */
static uint32_t plant_taps(const Plant *p, int c, float *taps) {
    const double fd = p->fs / p->D;
    uint32_t count = (uint32_t)llround(0.128 * fd);
    if (count > 512) count = 512;
    for (uint32_t k = 0; k < count; ++k) {
        double h = 0;
        for (int i = 0; i < MODES; ++i) {
            const Mode *m = &kModes[c][i];
            const double j = (double)k * p->D;
            h += m->w * exp(-j / (m->tau * p->fs)) * sin(TWO_PI * m->f * j / p->fs);
        }
        taps[k] = (float)(p->D * p->scale * h);
    }
    return count;
}

static double plant_step(Plant *p, int c, double u) {
    double sum = 0;
    for (int i = 0; i < MODES; ++i) {
        const double y = p->c1[c][i] * p->y1[c][i] + p->c2[c][i] * p->y2[c][i] + p->b1[c][i] * p->u1[c];
        p->y2[c][i] = p->y1[c][i]; p->y1[c][i] = y;
        sum += y;
    }
    p->u1[c] = u;
    return sum;
}

typedef struct {
    float taps[2][512];
    N60FeedForwardLiveEcho echo;
} Model;

static void model_build(Model *m, const Plant *p) {
    memset(m, 0, sizeof *m);
    for (int c = 0; c < 2; ++c) {
        m->echo.tapCount[c] = plant_taps(p, c, m->taps[c]);
        m->echo.bulkDelay[c] = p->bulk[c];
        m->echo.taps[c] = m->taps[c];
    }
}

/* ---- measurement --------------------------------------------------------------------------- */

typedef struct { double b0, b1, b2, a1, a2, z1, z2; } Bq;
static void bq_design(Bq *q, bool high, double fc, double fs) {
    const double w0 = TWO_PI * fc / fs, c = cos(w0), alpha = sin(w0) / (2.0 * 0.70710678118654752);
    const double a0 = 1.0 + alpha;
    q->b0 = (high ? 1.0 + c : 1.0 - c) / 2.0 / a0;
    q->b1 = (high ? -(1.0 + c) : 1.0 - c) / a0;
    q->b2 = q->b0;
    q->a1 = -2.0 * c / a0; q->a2 = (1.0 - alpha) / a0; q->z1 = q->z2 = 0;
}
static double bq_run(Bq *q, double x) {
    const double y = q->b0 * x + q->z1;
    q->z1 = q->b1 * x - q->a1 * y + q->z2;
    q->z2 = q->b2 * x - q->a2 * y;
    return y;
}
/* Mean square of (a - b) between 31.5 and 125 Hz over [from, to). */
static double band_ms(const float *a, const float *b, uint64_t from, uint64_t to, double fs) {
    Bq hp, lp;
    bq_design(&hp, true, 31.5, fs); bq_design(&lp, false, 125.0, fs);
    const uint64_t warm = from > (uint64_t)(0.3 * fs) ? from - (uint64_t)(0.3 * fs) : 0;
    double sum = 0; uint64_t count = 0;
    for (uint64_t n = warm; n < to; ++n) {
        const double y = bq_run(&lp, bq_run(&hp, (double)a[n] - (b ? (double)b[n] : 0.0)));
        if (n >= from) { sum += y * y; ++count; }
    }
    return count ? sum / (double)count : 0.0;
}
static double db(double ratio) { return 10.0 * log10(ratio + 1e-300); }
static float max_abs(const float *x, uint64_t from, uint64_t to) {
    float m = 0;
    for (uint64_t n = from; n < to; ++n) if (fabsf(x[n]) > m) m = fabsf(x[n]);
    return m;
}

/* ---- the rig: render kernel and bridge in miniature ---------------------------------------- */

#define CYCLE 7
static const uint32_t kCycle[CYCLE] = {37, 480, 111, 256, 64, 512, 200};

typedef struct {
    Plant plant;
    double fs;
    bool leak, closed;
    uint64_t total, pos;
    uint32_t prevB, fixedB, cycle, dropFrames, zeroNext;
    double lockedAt;
    float *progL, *progR, *drvL, *drvR, *prim, *noise, *leakOnly, *refMain, *refPure, *outL0, *outR0, *outL1;
    N60FeedForwardLive *a, *b;   /* a: the stage under test; b: optional oracle (reference without leakage) */
} Rig;

static float *buf(uint64_t n) {
    float *p = calloc(n, sizeof(float));
    if (!p) { fprintf(stderr, "out of memory\n"); exit(1); }
    return p;
}

static Rig *rig_new(double fs, double seconds, bool leak, bool closed, double peak, uint32_t lag_extra,
                    uint32_t bulk0, uint32_t bulk1, double primary_rel, uint64_t seed) {
    Rig *r = calloc(1, sizeof *r);
    r->fs = fs; r->leak = leak; r->closed = closed; r->total = (uint64_t)(seconds * fs); r->lockedAt = -1;
    plant_init(&r->plant, fs, bulk0, bulk1, lag_extra, peak);
    const uint64_t n = r->total;
    r->progL = buf(n); r->progR = buf(n); r->drvL = buf(n); r->drvR = buf(n); r->prim = buf(n); r->noise = buf(n);
    r->leakOnly = buf(n); r->refMain = buf(n); r->refPure = buf(n); r->outL0 = buf(n); r->outR0 = buf(n); r->outL1 = buf(n);
    const double sigma = 0.3, leak_rms = sigma * sqrt(r->plant.sumsq);
    uint64_t s0 = seed * 7919 + 13, s1 = seed * 104729 + 17, s2 = seed * 1299709 + 19;
    static const double kTonesHz[] = {31.5, 47.0, 63.0, 90.0, 125.0};
    const double tone_amp = primary_rel * leak_rms / sqrt(2.5);
    for (uint64_t i = 0; i < n; ++i) {
        r->progL[i] = (float)(sigma * grand(&s0));
        r->progR[i] = (float)(sigma * grand(&s1));
        r->noise[i] = (float)(0.01 * leak_rms * grand(&s2));
        double v = 0;
        if (primary_rel > 0)
            for (int k = 0; k < 5; ++k) v += tone_amp * sin(TWO_PI * kTonesHz[k] * (double)i / fs + 0.7 * k);
        r->prim[i] = (float)v;
    }
    return r;
}

static void rig_free(Rig *r) {
    free(r->progL); free(r->progR); free(r->drvL); free(r->drvR); free(r->prim); free(r->noise);
    free(r->leakOnly); free(r->refMain); free(r->refPure); free(r->outL0); free(r->outR0); free(r->outL1);
    free(r);
}

static void rig_advance(Rig *r, uint64_t until) {
    static float tl[MAX_BLOCK], tr[MAX_BLOCK], ol[MAX_BLOCK], orr[MAX_BLOCK];
    const uint32_t D = r->plant.D;
    if (until > r->total) until = r->total;
    while (r->pos < until) {
        uint32_t B = r->fixedB ? r->fixedB : kCycle[r->cycle++ % CYCLE];
        if (r->pos + B > r->total) B = (uint32_t)(r->total - r->pos);
        const uint64_t n = r->pos;
        if (r->prevB > 0) {
            const uint32_t pushed = r->prevB > r->dropFrames ? r->prevB - r->dropFrames : 0;
            N60FeedForwardLivePushDrive(r->a, r->drvL + n - r->prevB, r->drvR + n - r->prevB, pushed);
            r->dropFrames = 0;
        }
        const uint32_t zeroN = r->zeroNext < B ? r->zeroNext : B;
        for (uint32_t i = 0; i < B; ++i) {
            const uint64_t g = n + i;
            double leak = 0;
            if (r->leak) {
                for (int c = 0; c < 2; ++c) {
                    const uint64_t delay = (uint64_t)r->plant.bulk[c] * D + r->plant.lagExtra;
                    const float *drive = c == 0 ? r->drvL : r->drvR;
                    leak += plant_step(&r->plant, c, g >= delay ? (double)drive[g - delay] : 0.0);
                }
            }
            const double s = (double)r->prim[g] + (double)r->noise[g];
            r->leakOnly[g] = (float)leak;
            r->refPure[g] = (float)s;
            r->refMain[g] = i < zeroN ? 0.0f : (float)(s + leak);
        }
        if (zeroN > 0) N60FeedForwardLiveNoteReferenceGaps(r->a, zeroN, 0);
        r->zeroNext = 0;
        N60FeedForwardLiveProcess(r->a, r->refMain + n, tl, tr, B);
        if (r->b) N60FeedForwardLiveProcess(r->b, r->refPure + n, ol, orr, B);
        for (uint32_t i = 0; i < B; ++i) {
            const uint64_t g = n + i;
            r->outL0[g] = tl[i]; r->outR0[g] = tr[i];
            if (r->b) r->outL1[g] = ol[i];
            r->drvL[g] = r->progL[g] + (r->closed ? tl[i] : 0.0f);
            r->drvR[g] = r->progR[g] + (r->closed ? tr[i] : 0.0f);
        }
        r->prevB = B;
        r->pos = n + B;
        if (r->lockedAt < 0 && N60FeedForwardLiveGetEchoStatus(r->a).state == N60FeedForwardLiveEchoLocked)
            r->lockedAt = (double)r->pos / r->fs;
    }
}

static void rig_seconds(Rig *r, double t) { rig_advance(r, (uint64_t)(t * r->fs)); }

static void set_unity_weights(N60FeedForwardLive *live, float k) {
    float w[1] = {k};
    CHECK(N60FeedForwardLiveSetWeights(live, w, w, 1), "weights");
}

static uint32_t bulk_for(double fs, double ms) { return (uint32_t)llround(ms * 0.001 * fs / factor_for(fs)); }

static void publish(Rig *r, N60FeedForwardLive *live, Model *m, double base_ms) {
    model_build(m, &r->plant);
    CHECK(N60FeedForwardLiveSetEcho(live, &m->echo), "set echo");
    CHECK(N60FeedForwardLiveSetEchoTiming(live, (uint32_t)llround(base_ms * 0.001 * r->fs)), "set timing");
}

static double lag_error_fd(const Rig *r, uint32_t lag) {
    return fabs((double)lag - (double)r->plant.lagExtra) / (double)r->plant.D;
}

/* ---- cases --------------------------------------------------------------------------------- */

static double worst_lag_fd = 0, worst_removal_db = 1e9, worst_meter_db = 1e9, worst_lock_s = 0;

/* 1: lock, lag, removal, and a model published while armed. */
static void case_lock_and_removal(double fs) {
    const uint32_t D = factor_for(fs);
    Rig *r = rig_new(fs, 7.9, true, false, 0.5, (uint32_t)llround(0.029 * fs), bulk_for(fs, 3), bulk_for(fs, 4), 0, 1);
    r->a = make(fs); r->b = make(fs); r->fixedB = 480;
    set_unity_weights(r->a, 1.0f); set_unity_weights(r->b, 1.0f);
    Model m; publish(r, r->a, &m, 25);
    CHECK(N60FeedForwardLiveArm(r->a, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm a");
    CHECK(N60FeedForwardLiveArm(r->b, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm b");
    rig_seconds(r, 3.0);
    N60FeedForwardLiveStatus st = N60FeedForwardLiveGetStatus(r->a);
    N60FeedForwardLiveEchoStatus es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.state == N60FeedForwardLiveEchoSearching, "%g: searching at 3 s, state %u", fs, es.state);
    CHECK(st.state == N60FeedForwardLiveIdle, "%g: arm waits for the lock, state %u", fs, st.state);
    CHECK(es.baseLagFrames == (uint32_t)llround(0.025 * fs), "%g: timing applied %u", fs, es.baseLagFrames);
    rig_seconds(r, 7.9);
    es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(r->lockedAt > 0 && r->lockedAt <= 6.1, "%g: locked at %.2f s", fs, r->lockedAt);
    CHECK(es.state == N60FeedForwardLiveEchoLocked, "%g: state %u", fs, es.state);
    const double lag_err = lag_error_fd(r, es.lagFrames);
    CHECK(lag_err <= 0.25, "%g: lag %u vs %u (%.3f fd samples)", fs, es.lagFrames, r->plant.lagExtra, lag_err);
    if (lag_err > worst_lag_fd) worst_lag_fd = lag_err;
    if (r->lockedAt > worst_lock_s) worst_lock_s = r->lockedAt;
    CHECK(es.peak >= 0.7f, "%g: peak %.3f", fs, es.peak);
    st = N60FeedForwardLiveGetStatus(r->a);
    CHECK(st.state == N60FeedForwardLiveArmed && st.gain >= 0.999f, "%g: armed after lock, state %u gain %.3f", fs, st.state, st.gain);
    const uint64_t from = (uint64_t)(6.9 * fs), to = r->total;
    const double leak_power = band_ms(r->leakOnly, NULL, from, to, fs);
    const double residual = band_ms(r->outL0, r->outL1, from, to, fs);
    const double removal = db(leak_power / residual);
    CHECK(leak_power > 0, "%g: leakage power", fs);
    CHECK(removal >= 20.0, "%g: removal %.1f dB below 20 dB", fs, removal);
    if (removal < worst_removal_db) worst_removal_db = removal;
    const double meter = db(es.bandBeforePower / (es.bandAfterPower + 1e-300));
    CHECK(meter >= 20.0, "%g: meter %.1f dB below 20 dB", fs, meter);
    if (meter < worst_meter_db) worst_meter_db = meter;
    CHECK(es.programmeSeconds > 0.5, "%g: programme seconds since lock %.2f", fs, es.programmeSeconds);
    CHECK(es.driveDiscontinuities == 0, "%g: discontinuities %u", fs, es.driveDiscontinuities);

    /* A model and timing published while armed wait: nothing changes until the filter is idle. */
    const uint32_t lag_before = es.lagFrames;
    const uint64_t restarts_before = es.searchRestarts;
    Model m2; model_build(&m2, &r->plant);
    m2.echo.bulkDelay[0] += 2;
    CHECK(N60FeedForwardLiveSetEcho(r->a, &m2.echo), "second model");
    CHECK(N60FeedForwardLiveSetEchoTiming(r->a, (uint32_t)llround(0.030 * fs)), "second timing");
    r->total += 0;   /* the rig was sized for 7.9 s; the rest runs inside it */
    es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.baseLagFrames == (uint32_t)llround(0.025 * fs), "%g: timing waits while armed", fs);
    CHECK(es.state == N60FeedForwardLiveEchoLocked && es.lagFrames == lag_before && es.searchRestarts == restarts_before,
          "%g: model waits while armed", fs);
    N60FeedForwardLiveDisarm(r->a);
    printf("  %8.1f Hz D=%3u  lock %.2f s  lag err %.3f fd  removal %.1f dB (meter %.1f dB)\n", fs, D, r->lockedAt, lag_err, removal, meter);
    N60FeedForwardLiveDestroy(r->a); N60FeedForwardLiveDestroy(r->b);
    rig_free(r);
}

/* 1b: after Disarm the pending model and timing apply and the search restarts. */
static void case_pending_applies(double fs) {
    Rig *r = rig_new(fs, 6.2, true, false, 0.5, (uint32_t)llround(0.029 * fs), bulk_for(fs, 3), bulk_for(fs, 4), 0, 2);
    r->a = make(fs); r->fixedB = 480;
    set_unity_weights(r->a, 1.0f);
    Model m; publish(r, r->a, &m, 25);
    CHECK(N60FeedForwardLiveArm(r->a, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm");
    rig_seconds(r, 5.8);
    N60FeedForwardLiveEchoStatus es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.state == N60FeedForwardLiveEchoLocked, "%g: locked %u", fs, es.state);
    CHECK(N60FeedForwardLiveGetStatus(r->a).state == N60FeedForwardLiveArmed, "%g: armed", fs);
    const uint64_t restarts = es.searchRestarts;
    CHECK(N60FeedForwardLiveSetEchoTiming(r->a, (uint32_t)llround(0.030 * fs)), "timing");
    rig_seconds(r, 6.0);
    es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.state == N60FeedForwardLiveEchoLocked && es.searchRestarts == restarts, "%g: timing waits while armed", fs);
    CHECK(es.baseLagFrames == (uint32_t)llround(0.025 * fs), "%g: base lag unchanged while armed", fs);
    N60FeedForwardLiveDisarm(r->a);
    rig_seconds(r, 6.2);
    es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.baseLagFrames == (uint32_t)llround(0.030 * fs), "%g: timing applied once idle (%u)", fs, es.baseLagFrames);
    CHECK(es.state == N60FeedForwardLiveEchoSearching && es.searchRestarts == restarts + 1,
          "%g: search restarted once idle (state %u, restarts %llu vs %llu)", fs, es.state,
          (unsigned long long)es.searchRestarts, (unsigned long long)restarts);
    N60FeedForwardLiveDestroy(r->a);
    rig_free(r);
}

/* 2: idle discontinuity, arm only when locked, zero spans, alignment trip. */
static void case_faults(double fs) {
    Rig *r = rig_new(fs, 9.4, true, false, 0.5, (uint32_t)llround(0.019 * fs), bulk_for(fs, 3), bulk_for(fs, 4), 0, 3);
    r->a = make(fs); r->fixedB = 480;
    set_unity_weights(r->a, 1.0f);
    Model m; publish(r, r->a, &m, 25);
    CHECK(N60FeedForwardLiveArm(r->a, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm");
    rig_seconds(r, 2.0);
    r->dropFrames = 1;
    rig_seconds(r, 2.05);
    N60FeedForwardLiveEchoStatus es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.driveDiscontinuities == 1, "%g: idle discontinuity counted (%u)", fs, es.driveDiscontinuities);
    CHECK(es.searchRestarts >= 2, "%g: idle discontinuity restarts the search (%llu)", fs, (unsigned long long)es.searchRestarts);
    rig_seconds(r, 5.8);
    es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.state == N60FeedForwardLiveEchoSearching, "%g: search restarted, no early lock (state %u)", fs, es.state);
    CHECK(N60FeedForwardLiveGetStatus(r->a).state == N60FeedForwardLiveIdle, "%g: not armed while unlocked", fs);
    CHECK(max_abs(r->outL0, 0, r->pos) == 0.0f, "%g: no output before lock", fs);
    rig_seconds(r, 8.0);
    es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(r->lockedAt >= 7.0 && r->lockedAt <= 8.1, "%g: relocked at %.2f s", fs, r->lockedAt);
    const double lag_err = lag_error_fd(r, es.lagFrames);
    CHECK(es.state == N60FeedForwardLiveEchoLocked && lag_err <= 0.25, "%g: relock lag %u vs %u", fs, es.lagFrames, r->plant.lagExtra);
    if (lag_err > worst_lag_fd) worst_lag_fd = lag_err;
    rig_seconds(r, 8.3);
    CHECK(N60FeedForwardLiveGetStatus(r->a).state == N60FeedForwardLiveArmed, "%g: armed once locked", fs);

    /* Zero-filled and underrun spans: no subtraction, no metering, so a zero reference stays zero. */
    const double seconds_before = N60FeedForwardLiveGetEchoStatus(r->a).programmeSeconds;
    for (int k = 0; k < 6; ++k) { r->zeroNext = 480; rig_advance(r, r->pos + 1); }
    const uint64_t span_end = r->pos;
    CHECK(max_abs(r->outL0, span_end - 480, span_end) < 1e-6f, "%g: zero-filled span stays zero (%g)", fs,
          max_abs(r->outL0, span_end - 480, span_end));
    CHECK(N60FeedForwardLiveGetEchoStatus(r->a).programmeSeconds == seconds_before, "%g: gap not metered", fs);
    r->zeroNext = 200; rig_advance(r, r->pos + 1);   /* an underrun: part of the block is zero */
    CHECK(N60FeedForwardLiveGetStatus(r->a).state == N60FeedForwardLiveArmed, "%g: gaps are not faults", fs);
    rig_seconds(r, 8.6);
    CHECK(N60FeedForwardLiveGetEchoStatus(r->a).state == N60FeedForwardLiveEchoLocked, "%g: still locked after the gaps", fs);

    /* A drive discontinuity while armed trips within the callback and the output fades in 10 ms. */
    const uint64_t at = r->pos;
    r->dropFrames = 1;
    rig_advance(r, r->pos + 1);
    N60FeedForwardLiveStatus st = N60FeedForwardLiveGetStatus(r->a);
    CHECK(st.state == N60FeedForwardLiveTripped && st.tripReason == N60FeedForwardLiveTripEchoAlignmentLost,
          "%g: alignment trip (state %u reason %u)", fs, st.state, st.tripReason);
    rig_seconds(r, 8.9);
    const uint64_t silent_from = at + (uint64_t)(0.012 * fs);
    CHECK(max_abs(r->outL0, silent_from, r->pos) == 0.0f, "%g: silent 12 ms after the trip (%g)", fs,
          max_abs(r->outL0, silent_from, r->pos));
    CHECK(max_abs(r->outL0, at, at + (uint64_t)(0.012 * fs)) > 0.0f, "%g: the output was playing before the trip", fs);
    rig_seconds(r, 9.4);
    st = N60FeedForwardLiveGetStatus(r->a);
    CHECK(st.state == N60FeedForwardLiveTripped, "%g: the trip latches", fs);
    N60FeedForwardLiveDestroy(r->a);
    rig_free(r);
}

/* 3: feedback neutralisation and the divergence trip. */
static double output_power(const Rig *r, double from_s, double to_s) {
    return band_ms(r->outL0, NULL, (uint64_t)(from_s * r->fs), (uint64_t)(to_s * r->fs), r->fs);
}

static void case_feedback(double fs) {
    const uint32_t bulk0 = bulk_for(fs, 3), bulk1 = bulk_for(fs, 4), lag = (uint32_t)llround(0.029 * fs);
    /* Reference: no leakage. */
    Rig *clean = rig_new(fs, 6.6, false, true, 1.0, lag, bulk0, bulk1, 0.5, 4);
    clean->a = make(fs); clean->fixedB = 480;
    set_unity_weights(clean->a, 1.5f);
    rig_seconds(clean, 5.2);
    CHECK(N60FeedForwardLiveArm(clean->a, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm clean");
    rig_seconds(clean, 6.6);
    const double reference_power = output_power(clean, 6.0, 6.6);
    CHECK(reference_power > 0, "%g: no-leak output power", fs);

    /* Control: loop gain 1.5 without removal. One sign of the gain has the phase to oscillate. */
    float sign = 1.0f;
    double control_power = 0;
    for (int attempt = 0; attempt < 2; ++attempt) {
        Rig *c = rig_new(fs, 3.0, true, true, 1.0, lag, bulk0, bulk1, 0.5, 4);
        c->a = make(fs); c->fixedB = 480;
        set_unity_weights(c->a, 1.5f * sign);
        CHECK(N60FeedForwardLiveArm(c->a, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm control");
        rig_seconds(c, 3.0);
        control_power = output_power(c, 2.5, 3.0);
        N60FeedForwardLiveDestroy(c->a);
        rig_free(c);
        if (control_power > 4.0 * reference_power) break;
        sign = -sign;
    }
    CHECK(control_power > 4.0 * reference_power, "%g: control grows without removal (%.1f dB over the no-leak run)", fs,
          db(control_power / reference_power));

    /* With removal. */
    Rig *r = rig_new(fs, 7.4, true, true, 1.0, lag, bulk0, bulk1, 0.5, 4);
    r->a = make(fs); r->fixedB = 480;
    set_unity_weights(r->a, 1.5f * sign);
    Model m; publish(r, r->a, &m, 25);
    CHECK(N60FeedForwardLiveArm(r->a, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm");
    rig_seconds(r, 6.6);
    N60FeedForwardLiveEchoStatus es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.state == N60FeedForwardLiveEchoLocked, "%g: locked in the closed loop (state %u)", fs, es.state);
    CHECK(N60FeedForwardLiveGetStatus(r->a).state == N60FeedForwardLiveArmed, "%g: armed in the closed loop", fs);
    const double with_removal = output_power(r, 6.0, 6.6);
    const double delta = db(with_removal / reference_power);
    CHECK(fabs(delta) <= 0.5, "%g: output %.2f dB from the no-leak run", fs, delta);
    printf("  %8.1f Hz  loop gain 1.5: control +%.1f dB, with removal %+.2f dB\n", fs, db(control_power / reference_power), delta);

    /* A forced wrong lag: the plant delay moves 6.5 ms. */
    r->plant.lagExtra += (uint32_t)llround(0.0065 * fs);
    const uint64_t moved = r->pos;
    double tripped_after = -1;
    while (r->pos < r->total) {
        rig_advance(r, r->pos + 1);
        if (N60FeedForwardLiveGetStatus(r->a).state == N60FeedForwardLiveTripped) { tripped_after = (double)(r->pos - moved) / fs; break; }
    }
    const N60FeedForwardLiveStatus st = N60FeedForwardLiveGetStatus(r->a);
    CHECK(tripped_after > 0 && tripped_after <= 0.4, "%g: diverged trip after %.0f ms", fs, tripped_after * 1000.0);
    CHECK(st.tripReason == N60FeedForwardLiveTripEchoDiverged, "%g: trip reason %u", fs, st.tripReason);
    if (tripped_after > 0) {
        const uint64_t at = r->pos - 480;
        rig_seconds(r, (double)(r->pos + (uint64_t)(0.03 * fs)) / fs);
        const uint64_t quiet = at + 480 + (uint64_t)(0.012 * fs);
        CHECK(max_abs(r->outL0, quiet, r->pos) == 0.0f, "%g: silent 12 ms after the divergence trip", fs);
    }
    N60FeedForwardLiveDestroy(r->a); N60FeedForwardLiveDestroy(clean->a);
    rig_free(r); rig_free(clean);
}

/* 4: an unrelated reference never locks and plays nothing. */
static void case_unrelated(double fs) {
    Rig *r = rig_new(fs, 7.0, false, false, 0.5, (uint32_t)llround(0.029 * fs), bulk_for(fs, 3), bulk_for(fs, 4), 1.0, 5);
    r->a = make(fs); r->fixedB = 480;
    set_unity_weights(r->a, 1.0f);
    Model m; publish(r, r->a, &m, 25);
    CHECK(N60FeedForwardLiveArm(r->a, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm");
    rig_seconds(r, 7.0);
    const N60FeedForwardLiveEchoStatus es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.state != N60FeedForwardLiveEchoLocked && r->lockedAt < 0, "%g: unrelated reference locked (peak %.2f)", fs, es.peak);
    CHECK(es.peak < 0.7f, "%g: unrelated peak %.2f", fs, es.peak);
    CHECK(N60FeedForwardLiveGetStatus(r->a).state == N60FeedForwardLiveIdle, "%g: not armed without a lock", fs);
    CHECK(max_abs(r->outL0, 0, r->pos) == 0.0f, "%g: no output without a lock", fs);
    N60FeedForwardLiveDestroy(r->a);
    rig_free(r);
}

/* 5: the lock does not depend on the callback size. */
static void case_block_sizes(double fs) {
    static const uint32_t sizes[] = {32, 160, 512, 0};   /* 0: the variable pattern */
    uint32_t reference_lag = 0;
    for (size_t k = 0; k < sizeof sizes / sizeof sizes[0]; ++k) {
        Rig *r = rig_new(fs, 5.9, true, false, 0.5, (uint32_t)llround(0.029 * fs), bulk_for(fs, 3), bulk_for(fs, 4), 0, 6);
        r->a = make(fs); r->fixedB = sizes[k];
        Model m; publish(r, r->a, &m, 25);
        rig_seconds(r, 5.9);
        const N60FeedForwardLiveEchoStatus es = N60FeedForwardLiveGetEchoStatus(r->a);
        CHECK(es.state == N60FeedForwardLiveEchoLocked, "%g: block %u state %u (peak %.2f, %.2f s)", fs, sizes[k], es.state, es.peak, es.programmeSeconds);
        CHECK(lag_error_fd(r, es.lagFrames) <= 0.25, "%g: block %u lag %u vs %u", fs, sizes[k], es.lagFrames, r->plant.lagExtra);
        if (k == 0) reference_lag = es.lagFrames;
        CHECK(es.lagFrames + 1 >= reference_lag && es.lagFrames <= reference_lag + 1, "%g: block %u lag %u vs %u", fs, sizes[k], es.lagFrames, reference_lag);
        N60FeedForwardLiveDestroy(r->a);
        rig_free(r);
    }
}

/* 6: a lag the drive cannot yet supply cannot lock. */
static void case_short_lag(double fs) {
    const uint32_t B = 256;
    Rig *r = rig_new(fs, 7.0, true, false, 0.5, B + 8, 0, 0, 0, 7);
    r->a = make(fs); r->fixedB = B;
    set_unity_weights(r->a, 1.0f);
    Model m; publish(r, r->a, &m, 1000.0 * (B + 8) / fs);
    CHECK(N60FeedForwardLiveArm(r->a, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm");
    rig_seconds(r, 7.0);
    const N60FeedForwardLiveEchoStatus es = N60FeedForwardLiveGetEchoStatus(r->a);
    CHECK(es.state != N60FeedForwardLiveEchoLocked && r->lockedAt < 0, "%g: a lag below the block plus chain locked (state %u lag %u)", fs, es.state, es.lagFrames);
    CHECK(max_abs(r->outL0, 0, r->pos) == 0.0f, "%g: short lag plays nothing", fs);
    N60FeedForwardLiveDestroy(r->a);
    rig_free(r);
}

/* 7: no echo set: bit-identical to a filter that is never told about an echo. */
static void case_bit_identical(double fs) {
    N60FeedForwardLive *x = make(fs), *y = make(fs);
    float w[40];
    uint64_t s = 99;
    for (int i = 0; i < 40; ++i) w[i] = (float)(0.1 * urand(&s));
    CHECK(N60FeedForwardLiveSetWeights(x, w, w, 40) && N60FeedForwardLiveSetWeights(y, w, w, 40), "weights");
    CHECK(N60FeedForwardLiveArm(x, 1.0, 0.01) == N60FeedForwardLiveArmOK && N60FeedForwardLiveArm(y, 1.0, 0.01) == N60FeedForwardLiveArmOK, "arm");
    CHECK(N60FeedForwardLiveSetEcho(y, NULL), "clear echo");
    CHECK(N60FeedForwardLiveSetEchoTiming(y, 1000), "timing alone");
    const uint32_t B = 300;
    float ref[300], dl[300], dr[300], xl[300], xr[300], yl[300], yr[300];
    bool same = true;
    for (int block = 0; block < (int)(fs * 0.6 / B); ++block) {
        for (uint32_t i = 0; i < B; ++i) { ref[i] = (float)(0.2 * urand(&s)); dl[i] = (float)(0.2 * urand(&s)); dr[i] = (float)(0.2 * urand(&s)); }
        N60FeedForwardLivePushDrive(y, dl, dr, B);
        N60FeedForwardLiveNoteReferenceGaps(y, 0, 0);
        N60FeedForwardLiveProcess(x, ref, xl, xr, B);
        N60FeedForwardLiveProcess(y, ref, yl, yr, B);
        if (memcmp(xl, yl, sizeof xl) || memcmp(xr, yr, sizeof xr)) same = false;
    }
    CHECK(same, "%g: output differs with no echo model set", fs);
    CHECK(N60FeedForwardLiveGetEchoStatus(y).state == N60FeedForwardLiveEchoOff, "%g: echo state off", fs);
    N60FeedForwardLiveDestroy(x); N60FeedForwardLiveDestroy(y);
}

/* A model with bad numbers or sizes is refused. */
static void case_validation(void) {
    N60FeedForwardLive *live = make(48000);
    float taps[600];
    for (int i = 0; i < 600; ++i) taps[i] = 0.01f;
    N60FeedForwardLiveEcho e = {{0, 0}, {64, 64}, {taps, taps}};
    CHECK(N60FeedForwardLiveSetEcho(live, &e), "valid model");
    e.tapCount[0] = 513;
    CHECK(!N60FeedForwardLiveSetEcho(live, &e), "513 taps refused");
    e.tapCount[0] = 64; e.bulkDelay[1] = 513;
    CHECK(!N60FeedForwardLiveSetEcho(live, &e), "bulk over 512 refused");
    e.bulkDelay[1] = 0; taps[3] = NAN;
    CHECK(!N60FeedForwardLiveSetEcho(live, &e), "NaN tap refused");
    CHECK(!N60FeedForwardLiveSetEchoTiming(live, 10000), "timing over 100 ms refused");
    CHECK(N60FeedForwardLiveSetEchoTiming(live, 1200), "timing accepted");
    N60FeedForwardLiveDestroy(live);
}

int main(void) {
    printf("harness_e4_ff_live_echo\n");
    case_validation();
    for (size_t k = 0; k < RATE_COUNT; ++k) {
        const double fs = kRates[k];
        case_lock_and_removal(fs);
        case_pending_applies(fs);
        case_faults(fs);
        case_feedback(fs);
        case_unrelated(fs);
        case_block_sizes(fs);
        case_short_lag(fs);
        case_bit_identical(fs);
        fflush(stdout);
    }
    printf("worst: lock %.2f s, lag error %.3f fd samples, removal %.1f dB (meter %.1f dB)\n", worst_lock_s, worst_lag_fd,
           worst_removal_db, worst_meter_db);
    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("PASS\n");
    return 0;
}
