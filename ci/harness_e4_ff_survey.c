/*
 * E4 S9b1: behavioural harness for the feed-forward survey
 * (N60FeedForwardSurvey in N60Fxlms.h) at the eight standard rates.
 *
 * Plant at the native rate: the reference microphone hears white noise x; the
 * error microphone hears g x delayed by 5 ms (rounded to native frames, so
 * not a whole number of decimated samples) plus independent white noise n.
 * Expected per band: H = g exp(-j 2 pi f d / fs) and, since x and n are white
 * through the same decimator, coherence g2 = g^2 sx^2 / (g^2 sx^2 + sn^2).
 */
#include <complex.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60Fxlms.h"

static const double kRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
};
#define RATE_COUNT (sizeof kRates / sizeof kRates[0])
#define BUFFER 512u
#define BANDS 16u
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

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

/* 1/6-octave grid from 25 Hz (the S9b plan's 16 bands). */
static N60FeedForwardSurveyConfig survey_config(double fs) {
    N60FeedForwardSurveyConfig c = N60FeedForwardSurveyConfigDefault(fs);
    c.bandCount = BANDS;
    for (uint32_t k = 0; k < BANDS; ++k) c.bandHz[k] = (float)(25.0 * pow(2.0, k / 6.0));
    return c;
}

typedef struct {
    N60FeedForwardSurvey *survey;
    double gain, sx, sn;
    uint32_t delay;
    double *line;
    uint32_t position;
    uint64_t rng;
} Sim;

static Sim sim_make(double fs, double gain, double sx, double sn) {
    Sim s = {0};
    const N60FeedForwardSurveyConfig c = survey_config(fs);
    s.survey = N60FeedForwardSurveyCreate(&c);
    if (!s.survey) {
        fprintf(stderr, "survey create failed at %.0f Hz\n", fs);
        exit(2);
    }
    s.gain = gain;
    s.sx = sx;
    s.sn = sn;
    s.delay = (uint32_t)lround(0.005 * fs);
    s.line = calloc(s.delay + 1, sizeof(double));
    if (!s.line) exit(2);
    s.rng = 5;
    return s;
}

static void sim_run(Sim *s, double fs, double seconds) {
    float x[BUFFER], e[BUFFER];
    const uint64_t buffers = (uint64_t)(seconds * fs / BUFFER);
    for (uint64_t b = 0; b < buffers; ++b) {
        for (uint32_t i = 0; i < BUFFER; ++i) {
            const double xn = s->sx * gaussian(&s->rng);
            s->line[s->position] = xn;
            s->position = (s->position + 1) % (s->delay + 1);
            const double noise = s->sn > 0 ? s->sn * gaussian(&s->rng) : 0.0;
            x[i] = (float)xn;
            e[i] = (float)(s->gain * s->line[s->position] + noise);
        }
        N60FeedForwardSurveyProcess(s->survey, x, e, BUFFER);
    }
}

static void sim_free(Sim *s) {
    N60FeedForwardSurveyDestroy(s->survey);
    free(s->line);
}

static double complex expected_transfer(const Sim *s, double fs, double hz) {
    return s->gain * cexp(-I * 2.0 * acos(-1.0) * hz * s->delay / fs);
}

/* Noiseless: the transfer is exact and the coherence is 1. */
static void test_transfer(double fs) {
    Sim s = sim_make(fs, 0.5, 0.1, 0.0);
    sim_run(&s, fs, 20.0);
    const N60FeedForwardSurveyResult r = N60FeedForwardSurveyRead(s.survey);
    const N60FeedForwardSurveyConfig c = survey_config(fs);
    double worstDB = 0, worstDeg = 0, lowest = 1;
    for (uint32_t k = 0; k < BANDS; ++k) {
        const double complex h = r.transfer[k].re + I * r.transfer[k].im;
        const double complex want = expected_transfer(&s, fs, c.bandHz[k]);
        worstDB = fmax(worstDB, fabs(20.0 * log10(cabs(h) / cabs(want))));
        worstDeg = fmax(worstDeg, fabs(carg(h / want)) * 180.0 / acos(-1.0));
        lowest = fmin(lowest, r.coherence[k]);
    }
    CHECK(worstDB < 0.06 && worstDeg < 0.5 && lowest > 0.999 && r.gaps == 0,
          "%.0f Hz: transfer off by %.3f dB / %.2f deg, coherence %.4f, gaps %llu", fs,
          worstDB, worstDeg, lowest, (unsigned long long)r.gaps);
    /* 20 s of 1 s segments at hop 0.5 s, less the decimator warm-up. */
    CHECK(r.segments >= 37 && r.segments <= 39, "%.0f Hz: %llu segments", fs,
          (unsigned long long)r.segments);
    printf("  transfer %6.0f Hz: within %.3f dB / %.2f deg, coherence >= %.5f\n",
           fs, worstDB, worstDeg, lowest);
    sim_free(&s);
}

/* Output noise: coherence follows S / (S + N) and H1 stays unbiased. Each
 * band must sit within four normalised random errors (Bendat and Piersol,
 * Random Data, table 9.6) with nd = segments / 2 independent averages for
 * the 50 % overlap: e[g2] = sqrt 2 (1 - g2) / (|g| sqrt nd) and
 * e[|H|] = sqrt(1 - g2) / (|g| sqrt(2 nd)), both relative. The mean
 * coherence over the 16 bands must be within three standard errors of the
 * mean (no bias). */
static void test_coherence(double fs) {
    const double levels[] = {0.05, 0.01};
    for (int i = 0; i < 2; ++i) {
        Sim s = sim_make(fs, 0.5, 0.1, levels[i]);
        sim_run(&s, fs, 60.0);
        const N60FeedForwardSurveyResult r = N60FeedForwardSurveyRead(s.survey);
        const double signal = 0.25 * 0.01;
        const double want = signal / (signal + levels[i] * levels[i]);
        const double nd = r.segments / 2.0;
        const double coherenceError = want * sqrt(2.0) * (1.0 - want) / (sqrt(want) * sqrt(nd));
        const double coherenceTolerance = 4.0 * coherenceError;
        const double magnitudeTolerance = 4.0 * sqrt(1.0 - want) / (sqrt(want) * sqrt(2.0 * nd));
        const N60FeedForwardSurveyConfig c = survey_config(fs);
        double worstCoherence = 0, worstMagnitude = 0, mean = 0;
        for (uint32_t k = 0; k < BANDS; ++k) {
            worstCoherence = fmax(worstCoherence, fabs(r.coherence[k] - want) / coherenceTolerance);
            const double complex h = r.transfer[k].re + I * r.transfer[k].im;
            const double complex expected = expected_transfer(&s, fs, c.bandHz[k]);
            worstMagnitude = fmax(worstMagnitude, cabs(h - expected) / cabs(expected) / magnitudeTolerance);
            mean += r.coherence[k] / BANDS;
        }
        CHECK(worstCoherence < 1.0 && worstMagnitude < 1.0
                  && fabs(mean - want) < 3.0 * coherenceError / sqrt(BANDS),
              "%.0f Hz, noise %.2f: coherence %.2fx, transfer %.2fx of 4 random errors; "
              "mean coherence %.3f (want %.3f)", fs, levels[i], worstCoherence, worstMagnitude,
              mean, want);
        if (i == 0) {
            printf("  coherence %5.0f Hz: mean %.3f (want %.3f), worst band at %.2f of the bound\n",
                   fs, mean, want, fmax(worstCoherence, worstMagnitude));
        }
        sim_free(&s);
    }
}

/* A run of non-finite samples is one gap; the estimate survives it. */
static void test_gap_and_reset(double fs) {
    Sim s = sim_make(fs, 0.5, 0.1, 0.0);
    sim_run(&s, fs, 5.0);
    float bad[BUFFER];
    for (uint32_t i = 0; i < BUFFER; ++i) bad[i] = (i & 1) ? NAN : INFINITY;
    N60FeedForwardSurveyProcess(s.survey, bad, bad, BUFFER);
    sim_run(&s, fs, 5.0);
    N60FeedForwardSurveyResult r = N60FeedForwardSurveyRead(s.survey);
    const N60FeedForwardSurveyConfig c = survey_config(fs);
    const double complex h = r.transfer[4].re + I * r.transfer[4].im;
    CHECK(r.gaps == 1 && cabs(h - expected_transfer(&s, fs, c.bandHz[4])) < 0.01,
          "%.0f Hz: gaps %llu, transfer %.4f%+.4fi", fs, (unsigned long long)r.gaps,
          creal(h), cimag(h));
    N60FeedForwardSurveyReset(s.survey);
    r = N60FeedForwardSurveyRead(s.survey);
    CHECK(r.segments == 0 && r.gaps == 0 && r.transfer[4].re == 0 && r.coherence[4] == 0,
          "%.0f Hz: reset left state behind", fs);
    sim_free(&s);
}

static void test_config(void) {
    N60FeedForwardSurveyConfig c = survey_config(48000);
    CHECK(N60FeedForwardSurveyConfigIsValid(&c), "survey config rejected");
    N60FeedForwardSurveyConfig bad = c;
    bad.bandCount = 0;
    CHECK(!N60FeedForwardSurveyConfigIsValid(&bad), "zero bands accepted");
    bad = c;
    bad.bandCount = N60_FF_SURVEY_MAX_BANDS + 1;
    CHECK(!N60FeedForwardSurveyConfigIsValid(&bad), "65 bands accepted");
    bad = c;
    bad.bandHz[3] = 1500.0f;
    CHECK(!N60FeedForwardSurveyConfigIsValid(&bad), "band above fd / 4 accepted");
    bad = c;
    bad.bandHz[0] = 5.0f;
    CHECK(!N60FeedForwardSurveyConfigIsValid(&bad), "5 Hz band accepted");
    bad = c;
    bad.segmentSeconds = 8.0;
    CHECK(!N60FeedForwardSurveyConfigIsValid(&bad), "8 s segment accepted");
    bad = c;
    bad.sampleRate = 7999;
    CHECK(N60FeedForwardSurveyCreate(&bad) == NULL, "7999 Hz native rate accepted");
    bad.sampleRate = 768001;
    CHECK(N60FeedForwardSurveyCreate(&bad) == NULL, "768001 Hz native rate accepted");
    bad = c;
    bad.bandHz[3] = 700.0f;
    CHECK(!N60FeedForwardSurveyConfigIsValid(&bad), "band above 0.15 fd accepted");
    N60FeedForwardSurvey *s = N60FeedForwardSurveyCreate(&c);
    const N60FeedForwardSurveyResult r = N60FeedForwardSurveyRead(s);
    CHECK(s && r.segments == 0 && r.transfer[0].re == 0 && r.decimatedRate == 4000.0,
          "fresh survey not empty");
    N60FeedForwardSurveyDestroy(s);
}

int main(void) {
    test_config();
    /* The ends of the supported range: D = 2 (fd 4 kHz) and D = 192. */
    test_transfer(8000);
    test_transfer(768000);
    for (size_t r = 0; r < RATE_COUNT; ++r) {
        const double fs = kRates[r];
        test_transfer(fs);
        test_coherence(fs);
        test_gap_and_reset(fs);
    }
    if (failures) {
        fprintf(stderr, "E4 feed-forward survey harness: %d failure(s)\n", failures);
        return 1;
    }
    printf("E4 feed-forward survey harness: PASS at %zu rates\n", RATE_COUNT);
    return 0;
}
