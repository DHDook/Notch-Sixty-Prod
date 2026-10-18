/*
 * E4 S9a: behavioural harness for the feed-forward shadow canceller
 * (N60FeedForwardShadow in N60Fxlms.h) at the eight standard rates.
 *
 * Simulated plant at the native rate: a reference microphone hears white
 * noise x; the error microphone hears d = g x delayed by 20 D native frames
 * (exactly 20 decimated samples, 5 ms), plus independent microphone noise.
 * Nothing is played (shadow), so the two speakers enter only through the path
 * estimates given to the shadow, at fd.
 */
#include <complex.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60Fxlms.h"

/* Seeded xorshift Gaussian, as in ci/e4_fxlms_plant.h. */
static uint64_t next_random(uint64_t *s) {
    *s ^= *s >> 12;
    *s ^= *s << 25;
    *s ^= *s >> 27;
    return *s * 2685821657736338717ull;
}

static double gaussian(uint64_t *s) {
    const double u = ((double)(next_random(s) >> 11) + 0.5) / 9007199254740992.0;
    const double v = ((double)(next_random(s) >> 11) + 0.5) / 9007199254740992.0;
    return sqrt(-2.0 * log(u)) * cos(2.0 * acos(-1.0) * v);
}

static const double kRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
};
#define RATE_COUNT (sizeof kRates / sizeof kRates[0])
#define BUFFER 512u
#define PRIMARY_DELAY 20u /* decimated samples */
#define TAPS 64u
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

static double db(double ratio) { return 10.0 * log10(ratio); }

static const float kLeftPath[] = {0.5f, 0.25f, 0.1f};
static const float kRightPath[] = {0.3f, -0.1f, 0.05f};
#define LEFT_DELAY 8u
#define RIGHT_DELAY 6u

typedef struct {
    N60FeedForwardShadow *shadow;
    double gain, xRMS, noiseRMS;
    uint64_t rng;
    double *line;
    uint32_t length, position;
} Sim;

static Sim sim_make(double fs, const N60FeedForwardShadowConfig *config, double gain,
                    double xRMS, double noiseRMS) {
    Sim s = {0};
    s.shadow = N60FeedForwardShadowCreate(config);
    if (!s.shadow) {
        fprintf(stderr, "shadow create failed at %.0f Hz\n", fs);
        exit(2);
    }
    s.gain = gain;
    s.xRMS = xRMS;
    s.noiseRMS = noiseRMS;
    s.rng = 7;
    s.length = PRIMARY_DELAY * N60AncDecimationFactor(fs) + 1;
    s.line = calloc(s.length, sizeof(double));
    if (!s.line) exit(2);
    return s;
}

static void sim_paths(Sim *s, bool symmetric) {
    if (symmetric) {
        const float half = 0.5f;
        N60FeedForwardShadowSetPath(s->shadow, 0, LEFT_DELAY, &half, 1);
        N60FeedForwardShadowSetPath(s->shadow, 1, LEFT_DELAY, &half, 1);
    } else {
        N60FeedForwardShadowSetPath(s->shadow, 0, LEFT_DELAY, kLeftPath, 3);
        N60FeedForwardShadowSetPath(s->shadow, 1, RIGHT_DELAY, kRightPath, 3);
    }
}

static void sim_free(Sim *s) {
    N60FeedForwardShadowDestroy(s->shadow);
    free(s->line);
}

static void sim_run(Sim *s, double fs, double seconds) {
    float x[BUFFER], e[BUFFER];
    const uint64_t buffers = (uint64_t)(seconds * fs / BUFFER);
    for (uint64_t b = 0; b < buffers; ++b) {
        for (uint32_t i = 0; i < BUFFER; ++i) {
            const double xn = s->xRMS > 0 ? s->xRMS * gaussian(&s->rng) : 0.0;
            /* line holds the last `length` reference samples; the oldest is
             * exactly the primary delay ago. */
            s->line[s->position] = xn;
            s->position = (s->position + 1) % s->length;
            const double delayed = s->line[s->position];
            const double noise = s->noiseRMS > 0 ? s->noiseRMS * gaussian(&s->rng) : 0.0;
            x[i] = (float)xn;
            e[i] = (float)(s->gain * delayed + noise);
        }
        N60FeedForwardShadowProcess(s->shadow, x, e, BUFFER);
    }
}

static double complex response(const float *w, uint32_t taps, double hz, double fd) {
    double complex acc = 0;
    for (uint32_t k = 0; k < taps; ++k) acc += w[k] * cexp(-I * 2.0 * acos(-1.0) * hz * k / fd);
    return acc;
}

static N60FeedForwardShadowConfig config_for(double fs) {
    N60FeedForwardShadowConfig c = N60FeedForwardShadowConfigDefault(fs);
    c.taps = TAPS;
    c.step = 0.2f;
    c.blockFrames = 8;
    c.leakagePerSecond = 0.001;
    c.peakGainLimit = 16.0f;
    return c;
}

/* Converges to the Wiener solution. With microphone noise 14 dB below the
 * disturbance, the predicted residual settles within 1 dB of the band-limited
 * noise floor (the irreducible error: an exact causal solution exists), at a
 * small step so the misadjustment (about 0.2 dB at 0.05, 1 dB at 0.2) stays
 * inside that margin. The floor run has the same noise samples (same seed,
 * no disturbance). A noiseless run at the larger step shows the depth reached
 * in 20 s. Then a gap keeps the weights and a reset restores the seed. */
static void test_wiener_gap_reset(double fs) {
    N60FeedForwardShadowConfig c = config_for(fs);
    Sim quiet = sim_make(fs, &c, 0.5, 0.1, 0.0);
    sim_paths(&quiet, false);
    sim_run(&quiet, fs, 20.0);
    const N60FeedForwardShadowStatus deep = N60FeedForwardShadowReadStatus(quiet.shadow);
    const double depth = db(deep.measuredPower / deep.predictedPower);
    CHECK(depth > 30.0, "%.0f Hz: noiseless reduction only %.1f dB", fs, depth);
    sim_free(&quiet);

    c.step = 0.05f;
    Sim floor = sim_make(fs, &c, 0.0, 0.1, 1e-2);
    sim_paths(&floor, false);
    sim_run(&floor, fs, 40.0);
    const double noiseFloor = N60FeedForwardShadowReadStatus(floor.shadow).measuredPower;
    sim_free(&floor);

    Sim s = sim_make(fs, &c, 0.5, 0.1, 1e-2);
    sim_paths(&s, false);
    sim_run(&s, fs, 40.0);
    N60FeedForwardShadowStatus st = N60FeedForwardShadowReadStatus(s.shadow);
    const double excess = db(st.predictedPower / noiseFloor);
    const double reduction = db(st.measuredPower / st.predictedPower);
    CHECK(fabs(excess) < 1.0 && reduction > 12.0,
          "%.0f Hz: residual %.2f dB from the floor, reduction %.1f dB", fs, excess, reduction);
    CHECK(st.gaps == 0 && st.modelResets == 0 && st.gainLimited == 0,
          "%.0f Hz: gaps %llu resets %llu limited %llu", fs, (unsigned long long)st.gaps,
          (unsigned long long)st.modelResets, (unsigned long long)st.gainLimited);
    CHECK(fabs(st.decimatedRate - fs / N60AncDecimationFactor(fs)) < 1e-9,
          "%.0f Hz: decimated rate %.3f", fs, st.decimatedRate);

    float before[2][TAPS], after[2][TAPS];
    for (uint32_t ch = 0; ch < 2; ++ch) N60FeedForwardShadowCopyWeights(s.shadow, ch, before[ch], TAPS);
    N60FeedForwardShadowMarkDiscontinuity(s.shadow);
    st = N60FeedForwardShadowReadStatus(s.shadow);
    for (uint32_t ch = 0; ch < 2; ++ch) N60FeedForwardShadowCopyWeights(s.shadow, ch, after[ch], TAPS);
    CHECK(st.gaps == 1 && st.samplesSinceRestart == 0 && !memcmp(before, after, sizeof before),
          "%.0f Hz: a gap must keep the weights and restart the filters", fs);

    N60FeedForwardShadowReset(s.shadow);
    for (uint32_t ch = 0; ch < 2; ++ch) N60FeedForwardShadowCopyWeights(s.shadow, ch, after[ch], TAPS);
    bool zero = true;
    for (uint32_t ch = 0; ch < 2; ++ch)
        for (uint32_t k = 0; k < TAPS; ++k) zero = zero && after[ch][k] == 0.0f;
    CHECK(zero, "%.0f Hz: reset must restore the (zero) seed", fs);
    sim_free(&s);
    printf("  wiener   %6.0f Hz: reduction %5.1f dB, residual %+.2f dB from the floor, "
           "noiseless %.1f dB\n", fs, reduction, excess, depth);
}

/* With an exact seed and no noise or leakage the seed is the fixed point:
 * the in-band response stays put and the virtual error is ~0. */
static void test_fixed_point(double fs) {
    N60FeedForwardShadowConfig c = config_for(fs);
    c.leakagePerSecond = 0.0;
    const double g = 0.5;
    Sim s = sim_make(fs, &c, g, 0.1, 0.0);
    sim_paths(&s, true);
    float seed[TAPS] = {0};
    seed[PRIMARY_DELAY - LEFT_DELAY] = (float)-g;  /* 0.5 W_L + 0.5 W_R = -g z^-12 */
    CHECK(N60FeedForwardShadowSetSeed(s.shadow, seed, seed, TAPS), "seed rejected");
    sim_run(&s, fs, 5.0);
    const N60FeedForwardShadowStatus st = N60FeedForwardShadowReadStatus(s.shadow);
    const double fd = st.decimatedRate;
    float w[TAPS];
    double worst = 0;
    for (uint32_t ch = 0; ch < 2; ++ch) {
        N60FeedForwardShadowCopyWeights(s.shadow, ch, w, TAPS);
        const double hz[] = {40.0, 60.0, 100.0};
        for (int i = 0; i < 3; ++i) {
            const double err = cabs(response(w, TAPS, hz[i], fd) - response(seed, TAPS, hz[i], fd));
            if (err > worst) worst = err;
        }
    }
    const double depth = db(st.measuredPower / fmax(st.predictedPower, 1e-30));
    /* The start-up transient (band filters filling) nudges the weights; the
     * in-band response must stay within 0.2% of the seed. */
    CHECK(worst < 2e-3 * g && depth > 50.0,
          "%.0f Hz: seed drifted %.2e, virtual error only %.1f dB down", fs, worst, depth);
    sim_free(&s);
}

static void test_gain_limit(double fs) {
    N60FeedForwardShadowConfig c = config_for(fs);
    c.peakGainLimit = 0.05f;
    Sim s = sim_make(fs, &c, 0.5, 0.1, 1e-3);
    sim_paths(&s, false);
    sim_run(&s, fs, 5.0);
    const N60FeedForwardShadowStatus st = N60FeedForwardShadowReadStatus(s.shadow);
    CHECK(st.gainLimited > 0 && st.weightGain[0] <= 0.05f * 1.0001f
              && st.weightGain[1] <= 0.05f * 1.0001f,
          "%.0f Hz: gain %.4f / %.4f, limited %llu", fs, st.weightGain[0], st.weightGain[1],
          (unsigned long long)st.gainLimited);
    sim_free(&s);
}

static void test_non_finite(double fs) {
    const N60FeedForwardShadowConfig c = config_for(fs);
    Sim s = sim_make(fs, &c, 0.5, 0.1, 1e-3);
    sim_paths(&s, false);
    sim_run(&s, fs, 1.0);
    float x[BUFFER], e[BUFFER];
    for (uint32_t i = 0; i < BUFFER; ++i) {
        x[i] = (i & 1) ? NAN : INFINITY;
        e[i] = (i & 1) ? -INFINITY : NAN;
    }
    N60FeedForwardShadowProcess(s.shadow, x, e, BUFFER);
    for (uint32_t i = 0; i < BUFFER; ++i) {  /* finite but huge: must not overflow the filters */
        x[i] = (i & 1) ? 3e38f : -3e38f;
        e[i] = (i & 1) ? -3e38f : 3e38f;
    }
    N60FeedForwardShadowProcess(s.shadow, x, e, BUFFER);
    sim_run(&s, fs, 1.0);
    const N60FeedForwardShadowStatus st = N60FeedForwardShadowReadStatus(s.shadow);
    float w[TAPS];
    bool ok = isfinite(st.predictedPower) && isfinite(st.measuredPower);
    for (uint32_t ch = 0; ch < 2; ++ch) {
        N60FeedForwardShadowCopyWeights(s.shadow, ch, w, TAPS);
        for (uint32_t k = 0; k < TAPS; ++k) ok = ok && isfinite(w[k]);
    }
    CHECK(ok && st.modelResets == 0 && st.predictedPower < 1.0f,
          "%.0f Hz: non-finite or huge input leaked into the state", fs);
    sim_free(&s);
}

static void test_config(void) {
    N60FeedForwardShadowConfig c = N60FeedForwardShadowConfigDefault(48000);
    CHECK(N60FeedForwardShadowConfigIsValid(&c), "default shadow config rejected");
    CHECK(fabsf(c.peakGainLimit - 0.0630957f) < 1e-6f, "default peak gain is not -24 dB");
    N60FeedForwardShadowConfig bad = c;
    bad.sampleRate = 4000;
    CHECK(N60FeedForwardShadowCreate(&bad) == NULL, "4 kHz native rate accepted");
    bad = c;
    bad.sampleRate = 1e6;
    CHECK(!N60FeedForwardShadowConfigIsValid(&bad), "1 MHz accepted");
    bad = c;
    bad.step = 0.3f;
    CHECK(!N60FeedForwardShadowConfigIsValid(&bad), "per-channel step 0.3 accepted");
    bad = c;
    bad.bandHighHz = 1500.0f;
    CHECK(!N60FeedForwardShadowConfigIsValid(&bad), "band edge above fd / 4 accepted");
    bad = c;
    bad.bandLowHz = 120.0f;
    CHECK(!N60FeedForwardShadowConfigIsValid(&bad), "high-pass at 120 Hz accepted");
    bad = c;
    bad.peakGainLimit = 0.0f;
    CHECK(!N60FeedForwardShadowConfigIsValid(&bad), "zero peak gain accepted");
    bad = c;
    bad.taps = 513;
    CHECK(!N60FeedForwardShadowConfigIsValid(&bad), "513 taps accepted");

    N60FeedForwardShadow *s = N60FeedForwardShadowCreate(&c);
    float taps[129] = {1};
    CHECK(s && !N60FeedForwardShadowSetPath(s, 2, 0, taps, 1), "channel 2 accepted");
    CHECK(!N60FeedForwardShadowSetPath(s, 0, 0, taps, 129), "129 path taps accepted");
    CHECK(!N60FeedForwardShadowSetPath(s, 0, N60_FF_SHADOW_MAX_BULK_DELAY + 1, taps, 1),
          "bulk delay above 512 accepted");
    CHECK(N60FeedForwardShadowSetPath(s, 1, N60_FF_SHADOW_MAX_BULK_DELAY, taps, 128),
          "longest path rejected");
    taps[3] = NAN;
    CHECK(!N60FeedForwardShadowSetPath(s, 0, 0, taps, 8), "non-finite path accepted");
    CHECK(!N60FeedForwardShadowSetSeed(s, taps, taps, 8), "non-finite seed accepted");
    N60FeedForwardShadowDestroy(s);
}

int main(void) {
    test_config();
    for (size_t r = 0; r < RATE_COUNT; ++r) {
        const double fs = kRates[r];
        test_wiener_gap_reset(fs);
        test_fixed_point(fs);
        test_gain_limit(fs);
        test_non_finite(fs);
    }
    if (failures) {
        fprintf(stderr, "E4 feed-forward shadow harness: %d failure(s)\n", failures);
        return 1;
    }
    printf("E4 feed-forward shadow harness: PASS at %zu rates\n", RATE_COUNT);
    return 0;
}
