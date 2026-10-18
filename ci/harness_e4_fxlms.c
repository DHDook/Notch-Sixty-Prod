/*
 * E4 S5: behavioural harness for the adaptive speaker-ANC core (N60Fxlms.h)
 * on a simulated plant (ci/e4_fxlms_plant.h), at the eight standard rates.
 *
 * The microphone hears each output buffer one buffer later, as on real
 * hardware, so the secondary path the core must learn includes that delay.
 */
#include <complex.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60Fxlms.h"
#include "e4_fxlms_plant.h"

static const double kRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
};
#define RATE_COUNT (sizeof kRates / sizeof kRates[0])
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
static double deg(double rad) { return rad * 180.0 / acos(-1.0); }
static double wrap(double rad) { return remainder(rad, 2.0 * acos(-1.0)); }

typedef struct {
    N60AdaptiveTonal *core;
    Plant plant;
    uint32_t buffer;
    float *out, *played, *err;
    bool service;
    bool silent;  /* shadow: the output is computed but never reaches the plant */
    /* Measurement window. */
    bool measuring;
    double residual, noise;
    uint64_t count;
    int demodTones;
    double demodHz[4];
    double complex demod[4];
    float peak;
    bool capsHeld;
    double toneCap, aggregateCap;
} Sim;

static Sim sim_make(double fs, uint32_t buffer, const N60AdaptiveTonalConfig *config, Plant plant) {
    Sim s = {0};
    s.core = N60AdaptiveTonalCreate(config);
    s.plant = plant;
    s.buffer = buffer;
    s.out = calloc(buffer, sizeof(float));
    s.played = calloc(buffer, sizeof(float));
    s.err = calloc(buffer, sizeof(float));
    s.service = true;
    s.capsHeld = true;
    s.toneCap = pow(10.0, config->toneCapDBFS / 20.0);
    s.aggregateCap = pow(10.0, config->aggregateCapDBFS / 20.0);
    if (!s.core || !s.out || !s.played || !s.err) {
        fprintf(stderr, "setup failed at %.0f Hz\n", fs);
        exit(2);
    }
    return s;
}

static void sim_free(Sim *s) {
    N60AdaptiveTonalDestroy(s->core);
    plant_free(&s->plant);
    free(s->out);
    free(s->played);
    free(s->err);
}

static void sim_measure(Sim *s, int tones, const double *hz) {
    s->measuring = true;
    s->residual = s->noise = 0;
    s->count = 0;
    s->demodTones = tones;
    for (int k = 0; k < tones; ++k) {
        s->demodHz[k] = hz[k];
        s->demod[k] = 0;
    }
}

static void sim_check_caps(Sim *s) {
    const N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(s->core);
    double sum = 0;
    for (int k = 0; k < 4; ++k) {
        const double m = hypot(st.weight[k].re, st.weight[k].im);
        if (!isfinite(m) || m > s->toneCap * (1 + 1e-5)) s->capsHeld = false;
        sum += m;
    }
    if (sum > s->aggregateCap * (1 + 1e-5)) s->capsHeld = false;
}

static void sim_run(Sim *s, double seconds) {
    const uint64_t buffers = (uint64_t)ceil(seconds * s->plant.fs / s->buffer);
    for (uint64_t b = 0; b < buffers; ++b) {
        for (uint32_t n = 0; n < s->buffer; ++n) {
            const uint64_t frame = s->plant.frame;
            const double e = plant_step(&s->plant, s->played[n]);
            s->err[n] = (float)e;
            if (s->measuring) {
                s->residual += e * e;
                s->noise += s->plant.lastNoise * s->plant.lastNoise;
                for (int k = 0; k < s->demodTones; ++k) {
                    const double ph = 2.0 * acos(-1.0)
                                      * fmod(s->demodHz[k] * (double)frame / s->plant.fs, 1.0);
                    s->demod[k] += e * cexp(-I * ph);
                }
                s->count++;
            }
        }
        N60AdaptiveTonalProcess(s->core, s->err, s->out, s->buffer);
        if (s->service) N60AdaptiveTonalService(s->core);
        for (uint32_t n = 0; n < s->buffer; ++n) {
            const float a = fabsf(s->out[n]);
            if (a > s->peak) s->peak = a;
        }
        if (s->silent) {
            memset(s->out, 0, s->buffer * sizeof(float));
        }
        float *t = s->played;
        s->played = s->out;
        s->out = t;
        sim_check_caps(s);
    }
}

/* Amplitude of tone k in the error over the measurement window. */
static double sim_tone_amplitude(const Sim *s, int k) {
    return 2.0 * cabs(s->demod[k]) / (double)s->count;
}

static double complex path_eff(const Plant *p, double hz, uint32_t buffer) {
    double re, im;
    plant_response(p, hz, buffer, &re, &im);
    return re + I * im;
}

static double complex weight(const N60AdaptiveTonalStatus *st, int k) {
    return st->weight[k].re + I * st->weight[k].im;
}

static double complex path_estimate(const N60AdaptiveTonalStatus *st, int k) {
    return st->path[k].re + I * st->path[k].im;
}

/* The standard test plant: 1 ms delay, 800 Hz low-pass, gain 0.5. */
static Plant standard_plant(double fs, double noise, uint64_t seed) {
    return plant_make(fs, 0.001, 800.0, 0.5, noise, seed);
}

/* Decimator ----------------------------------------------------------------- */

static void test_decimator(double fs) {
    const uint32_t d = N60AncDecimationFactor(fs);
    const uint32_t g = N60AncDecimatorDelayFrames(fs);
    CHECK(d == (uint32_t)(fs / 4000.0) && g == 8 * d, "%.0f Hz: factor %u delay %u", fs, d, g);
    const double fd = fs / d;
    const double probes[] = {0.0, 150.0, 0.6 * fd};
    for (int t = 0; t < 3; ++t) {
        N60AncDecimator *dec = N60AncDecimatorCreate(fs);
        CHECK(dec != NULL, "%.0f Hz: decimator", fs);
        if (!dec) return;
        const uint32_t frames = (uint32_t)(0.5 * fs);
        float *in = malloc(frames * sizeof(float));
        float *out = malloc((frames / d + 1) * sizeof(float));
        for (uint32_t n = 0; n < frames; ++n) {
            in[n] = (float)cos(plant_tau() * probes[t] * n / fs);
        }
        const uint32_t m = N60AncDecimatorProcess(dec, in, frames, out, frames / d + 1);
        CHECK(m == frames / d, "%.0f Hz: %u outputs", fs, m);
        /* Project the settled half onto the expected delayed tone. */
        double complex acc = 0;
        double power = 0;
        uint32_t used = 0;
        for (uint32_t i = m / 2; i < m; ++i) {
            const double n = (double)((i + 1) * d - 1) - g;
            acc += out[i] * cexp(-I * plant_tau() * probes[t] * n / fs);
            power += (double)out[i] * out[i];
            used++;
        }
        if (t == 0) {
            CHECK(fabs(creal(acc) / used - 1.0) < 1e-6, "%.0f Hz: DC gain %.9f", fs, creal(acc) / used);
        } else if (t == 1) {
            const double gain = 2.0 * cabs(acc) / used;
            CHECK(fabs(db(gain * gain)) < 0.01, "%.0f Hz: 150 Hz gain %.4f dB", fs, db(gain * gain));
            CHECK(fabs(carg(acc)) < 1e-3, "%.0f Hz: 150 Hz phase %.2e rad after delay", fs, carg(acc));
        } else {
            CHECK(db(2.0 * power / used) < -70.0, "%.0f Hz: alias at 0.6 fd only %.1f dB down", fs,
                  db(2.0 * power / used));
        }
        free(in);
        free(out);
        N60AncDecimatorDestroy(dec);
    }
}

/* Narrowband FxLMS ------------------------------------------------------------ */

static N60AdaptiveTonalConfig tonal_config(double fs, int tones, const double *hz) {
    N60AdaptiveTonalConfig c = N60AdaptiveTonalConfigDefault(fs);
    c.toneCount = (uint32_t)tones;
    for (int k = 0; k < tones; ++k) c.toneHz[k] = (float)hz[k];
    return c;
}

static void seed_exact(N60AdaptiveTonalConfig *c, const Plant *p, uint32_t buffer,
                       double scale, double rotateRad) {
    for (uint32_t k = 0; k < c->toneCount; ++k) {
        const double complex s = path_eff(p, c->toneHz[k], buffer) * scale * cexp(I * rotateRad);
        c->toneSeed[k].re = (float)creal(s);
        c->toneSeed[k].im = (float)cimag(s);
    }
}

/* Converges to within 1 dB of the Wiener residual (the noise floor, since the
 * tones are fully cancellable) and to the documented fixed point. */
static void test_wiener(double fs) {
    const double hz[] = {60.0, 120.0};
    const uint32_t buffer = 256;
    Plant p = standard_plant(fs, 3e-4, 11);
    plant_add_tone(&p, hz[0], 0.02, 0.7);
    plant_add_tone(&p, hz[1], 0.015, -1.9);
    N60AdaptiveTonalConfig c = tonal_config(fs, 2, hz);
    seed_exact(&c, &p, buffer, 1.0, 0.0);
    Sim s = sim_make(fs, buffer, &c, p);
    sim_run(&s, 2.0);
    sim_measure(&s, 2, hz);
    sim_run(&s, 1.0);
    const double excess = db(s.residual / s.noise);
    CHECK(excess < 1.0, "%.0f Hz: residual %.2f dB above Wiener", fs, excess);
    const N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(s.core);
    const double lt = c.leakagePerSecond * c.convergenceSeconds;
    for (int k = 0; k < 2; ++k) {
        const double complex dk = s.plant.dRe[k] + I * s.plant.dIm[k];
        const double complex wiener = -dk / path_eff(&s.plant, hz[k], buffer);
        const double complex fixed = wiener / (1.0 + lt);
        const double complex w = weight(&st, k);
        CHECK(fabs(db(cabs(w) * cabs(w) / (cabs(wiener) * cabs(wiener)))) < 1.0,
              "%.0f Hz tone %d: weight %.2f dB from Wiener", fs, k,
              db(cabs(w) * cabs(w) / (cabs(wiener) * cabs(wiener))));
        CHECK(cabs(w - fixed) / cabs(fixed) < 0.01, "%.0f Hz tone %d: %.4f from fixed point", fs,
              k, cabs(w - fixed) / cabs(fixed));
        CHECK(st.adapting[k], "%.0f Hz tone %d not adapting", fs, k);
    }
    printf("  wiener %6.0f Hz: residual +%.2f dB over noise, tones -%.1f/-%.1f dB\n", fs, excess,
           -db(pow(sim_tone_amplitude(&s, 0) / 0.02, 2)),
           -db(pow(sim_tone_amplitude(&s, 1) / 0.015, 2)));
    sim_free(&s);
}

/* With rate-scaled buffers and no noise, the weight trajectory is the same at
 * every rate: adaptation runs in seconds, not samples. */
static void test_rate_identity(void) {
    const double hz[] = {60.0, 120.0};
    double complex at[RATE_COUNT][2][2];
    for (size_t r = 0; r < RATE_COUNT; ++r) {
        const double fs = kRates[r];
        const uint32_t buffer = (uint32_t)lround(0.004 * fs);
        Plant p = standard_plant(fs, 0.0, 1);
        plant_add_tone(&p, hz[0], 0.02, 0.7);
        plant_add_tone(&p, hz[1], 0.015, -1.9);
        N60AdaptiveTonalConfig c = tonal_config(fs, 2, hz);
        seed_exact(&c, &p, buffer, 1.0, 0.0);
        Sim s = sim_make(fs, buffer, &c, p);
        /* Normalised by this rate's own Wiener weight, so whole-frame rounding
         * of the plant and buffer delays does not count against the core. */
        double complex wiener[2];
        for (int k = 0; k < 2; ++k) {
            wiener[k] = -(s.plant.dRe[k] + I * s.plant.dIm[k]) / path_eff(&s.plant, hz[k], buffer);
        }
        sim_run(&s, 0.3);
        N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(s.core);
        for (int k = 0; k < 2; ++k) at[r][0][k] = weight(&st, k) / wiener[k];
        sim_run(&s, 1.2);
        st = N60AdaptiveTonalReadStatus(s.core);
        for (int k = 0; k < 2; ++k) at[r][1][k] = weight(&st, k) / wiener[k];
        sim_free(&s);
    }
    double worstDB = 0, worstDeg = 0;
    for (size_t r = 0; r < RATE_COUNT; ++r) {
        for (int t = 0; t < 2; ++t) {
            for (int k = 0; k < 2; ++k) {
                const double complex ref = at[1][t][k];
                const double ddb = fabs(20.0 * log10(cabs(at[r][t][k]) / cabs(ref)));
                const double dph = fabs(deg(carg(at[r][t][k] / ref)));
                if (ddb > worstDB) worstDB = ddb;
                if (dph > worstDeg) worstDeg = dph;
                CHECK(ddb < 0.1 && dph < 0.5, "%.0f Hz t%d tone %d: %.3f dB, %.2f deg from 48 kHz",
                      kRates[r], t, k, ddb, dph);
            }
        }
    }
    printf("  rate identity: worst %.3f dB, %.3f deg across 8 rates\n", worstDB, worstDeg);
}

/* Probe on, path learned from nothing, then a 30 degree phase step at 60 Hz:
 * the estimate follows within 2 s and cancellation recovers. */
static void test_path_tracking(double fs) {
    const double hz[] = {60.0};
    const uint32_t buffer = 256;
    Plant p = standard_plant(fs, 3e-4, 23);
    plant_add_tone(&p, hz[0], 0.02, 0.3);
    N60AdaptiveTonalConfig c = tonal_config(fs, 1, hz);
    c.probeEnabled = true;
    Sim s = sim_make(fs, buffer, &c, p);
    /* Cold start: no tone adapts until the path model has had 3 T. */
    sim_run(&s, 0.9 * 3.0 * c.pathConvergenceSeconds);
    N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(s.core);
    CHECK(!st.adapting[0] && st.weight[0].re == 0 && st.weight[0].im == 0,
          "%.0f Hz: tone adapted before the path model settled", fs);
    sim_run(&s, 3.0 - 0.9 * 3.0 * c.pathConvergenceSeconds);
    st = N60AdaptiveTonalReadStatus(s.core);
    CHECK(st.adapting[0] && s.capsHeld && st.modelResets == 0, "%.0f Hz: cold start", fs);
    double complex truth = path_eff(&s.plant, hz[0], buffer);
    double complex est = path_estimate(&st, 0);
    CHECK(fabs(20 * log10(cabs(est) / cabs(truth))) < 0.5 && fabs(deg(carg(est / truth))) < 3.0,
          "%.0f Hz: initial path %.2f dB %.2f deg", fs, 20 * log10(cabs(est) / cabs(truth)),
          deg(carg(est / truth)));

    const double before = carg(truth);
    plant_set_delay(&s.plant, 0.001 + 30.0 / 360.0 / hz[0]);
    truth = path_eff(&s.plant, hz[0], buffer);
    const double stepDeg = fabs(deg(wrap(carg(truth) - before)));
    CHECK(fabs(stepDeg - 30.0) < 0.5, "%.0f Hz: plant step %.2f deg", fs, stepDeg);
    sim_run(&s, 2.0);
    st = N60AdaptiveTonalReadStatus(s.core);
    est = path_estimate(&st, 0);
    const double errDB = 20 * log10(cabs(est) / cabs(truth));
    const double errDeg = deg(carg(est / truth));
    CHECK(fabs(errDB) < 0.5 && fabs(errDeg) < 3.0, "%.0f Hz: 2 s after step path %.2f dB %.2f deg",
          fs, errDB, errDeg);
    sim_measure(&s, 1, hz);
    sim_run(&s, 0.5);
    const double cancel = -20 * log10(sim_tone_amplitude(&s, 0) / 0.02);
    CHECK(cancel > 30.0, "%.0f Hz: only %.1f dB cancellation after the step", fs, cancel);
    printf("  tracking %6.0f Hz: 2 s after 30 deg step path %.2f dB %.2f deg, tone -%.1f dB\n",
           fs, errDB, errDeg, cancel);
    sim_free(&s);
}

/* Fastest documented step (tau 0.1 s), the largest buffer, and a path estimate
 * 60 degrees and 3 dB wrong: bounded, within the caps, and still converging. */
static void test_max_step(double fs) {
    const double hz[] = {60.0, 120.0};
    const uint32_t buffer = 511;
    Plant p = standard_plant(fs, 3e-4, 37);
    plant_add_tone(&p, hz[0], 0.02, 0.7);
    plant_add_tone(&p, hz[1], 0.015, -1.9);
    N60AdaptiveTonalConfig c = tonal_config(fs, 2, hz);
    c.convergenceSeconds = N60_FXLMS_MIN_CONVERGENCE_SECONDS;
    seed_exact(&c, &p, buffer, 0.7, acos(-1.0) / 3.0);
    Sim s = sim_make(fs, buffer, &c, p);
    sim_run(&s, 5.0);
    sim_measure(&s, 2, hz);
    sim_run(&s, 1.0);
    const double excess = db(s.residual / s.noise);
    CHECK(s.capsHeld, "%.0f Hz: weights left the caps or went non-finite", fs);
    CHECK(excess < 1.0, "%.0f Hz: max step residual %.2f dB above noise", fs, excess);
    printf("  max step %6.0f Hz: residual +%.2f dB over noise\n", fs, excess);
    sim_free(&s);
}

/* Shadow mode: the output is never played, so the core adapts on the virtual
 * error. It reaches the same fixed point it would live, the microphone keeps
 * hearing the full disturbance, and the predicted residual is the cancelled
 * one. */
static void test_shadow(double fs) {
    const double hz[] = {60.0, 120.0};
    const uint32_t buffer = 256;
    Plant p = standard_plant(fs, 3e-4, 41);
    plant_add_tone(&p, hz[0], 0.02, 0.7);
    plant_add_tone(&p, hz[1], 0.015, -1.9);
    N60AdaptiveTonalConfig c = tonal_config(fs, 2, hz);
    c.shadow = true;
    seed_exact(&c, &p, buffer, 1.0, 0.0);
    Sim s = sim_make(fs, buffer, &c, p);
    s.silent = true;
    sim_run(&s, 3.0);
    const N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(s.core);
    const double lt = c.leakagePerSecond * c.convergenceSeconds;
    const double amps[] = {0.02, 0.015};
    for (int k = 0; k < 2; ++k) {
        const double complex dk = s.plant.dRe[k] + I * s.plant.dIm[k];
        const double complex fixed = -dk / path_eff(&s.plant, hz[k], buffer) / (1.0 + lt);
        const double complex w = weight(&st, k);
        CHECK(cabs(w - fixed) / cabs(fixed) < 0.01, "%.0f Hz shadow tone %d: %.4f from fixed point",
              fs, k, cabs(w - fixed) / cabs(fixed));
        const double measured = hypot(st.measuredTone[k].re, st.measuredTone[k].im);
        const double predicted = hypot(st.predictedTone[k].re, st.predictedTone[k].im);
        CHECK(fabs(20 * log10(measured / amps[k])) < 0.5, "%.0f Hz shadow tone %d: measured %.2f dB",
              fs, k, 20 * log10(measured / amps[k]));
        CHECK(predicted < amps[k] * pow(10, -30.0 / 20), "%.0f Hz shadow tone %d: predicted only %.1f dB down",
              fs, k, 20 * log10(predicted / amps[k]));
    }
    sim_free(&s);
}

/* A disturbance too loud to cancel within the caps: weights and output stay
 * inside them. */
static void test_caps(double fs) {
    const double hz[] = {40.0, 60.0, 90.0, 140.0};
    const uint32_t buffer = 256;
    Plant p = standard_plant(fs, 0.0, 5);
    for (int k = 0; k < 4; ++k) plant_add_tone(&p, hz[k], 0.1, 0.5 * k);
    N60AdaptiveTonalConfig c = tonal_config(fs, 4, hz);
    seed_exact(&c, &p, buffer, 1.0, 0.0);
    Sim s = sim_make(fs, buffer, &c, p);
    sim_run(&s, 2.0);
    const N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(s.core);
    double sum = 0;
    for (int k = 0; k < 4; ++k) sum += cabs(weight(&st, k));
    CHECK(s.capsHeld, "%.0f Hz: caps broken", fs);
    CHECK(sum > 0.99 * s.aggregateCap, "%.0f Hz: aggregate %.4f not at the cap", fs, sum);
    CHECK(s.peak <= s.aggregateCap * (1 + 1e-5), "%.0f Hz: output peak %.5f over %.5f", fs,
          s.peak, s.aggregateCap);
    sim_free(&s);
}

/* Ring overflow (worker stalled) drops whole chunks; the worker counts a gap,
 * restarts its filters and reconverges. Reset zeroes weights and output. */
static void test_gap_and_reset(double fs) {
    const double hz[] = {60.0};
    const uint32_t buffer = 256;
    Plant p = standard_plant(fs, 0.0, 3);
    plant_add_tone(&p, hz[0], 0.02, 0.3);
    N60AdaptiveTonalConfig c = tonal_config(fs, 1, hz);
    c.ringSeconds = 0.05;
    seed_exact(&c, &p, buffer, 1.0, 0.0);
    Sim s = sim_make(fs, buffer, &c, p);
    sim_run(&s, 0.5);
    s.service = false;
    sim_run(&s, 0.3);
    s.service = true;
    sim_run(&s, 2.0);
    N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(s.core);
    CHECK(st.droppedFrames > 0 && st.gaps >= 1, "%.0f Hz: dropped %llu gaps %llu", fs,
          (unsigned long long)st.droppedFrames, (unsigned long long)st.gaps);
    sim_measure(&s, 1, hz);
    sim_run(&s, 0.5);
    const double cancel = -20 * log10(sim_tone_amplitude(&s, 0) / 0.02);
    CHECK(cancel > 30.0, "%.0f Hz: %.1f dB after gap", fs, cancel);

    /* A marked discontinuity is seen as a gap. */
    const uint64_t gapsBefore = st.gaps;
    N60AdaptiveTonalMarkDiscontinuity(s.core);
    sim_run(&s, 0.1);
    st = N60AdaptiveTonalReadStatus(s.core);
    CHECK(st.gaps == gapsBefore + 1, "%.0f Hz: discontinuity gaps %llu -> %llu", fs,
          (unsigned long long)gapsBefore, (unsigned long long)st.gaps);

    N60AdaptiveTonalRequestReset(s.core);
    N60AdaptiveTonalService(s.core);
    st = N60AdaptiveTonalReadStatus(s.core);
    CHECK(st.weight[0].re == 0 && st.weight[0].im == 0, "%.0f Hz: reset left weights", fs);
    float *zeros = calloc(buffer, sizeof(float));
    float *out = calloc(buffer, sizeof(float));
    N60AdaptiveTonalProcess(s.core, zeros, out, buffer);
    N60AdaptiveTonalProcess(s.core, zeros, out, buffer);
    bool silent = true;
    for (uint32_t n = 0; n < buffer; ++n) silent = silent && out[n] == 0.0f;
    CHECK(silent, "%.0f Hz: output not silent after reset", fs);
    free(zeros);
    free(out);
    sim_free(&s);
}

/* Non-finite error samples are queued as zero and never reach the weights. */
static void test_non_finite(double fs) {
    const double hz[] = {60.0};
    N60AdaptiveTonalConfig c = tonal_config(fs, 1, hz);
    c.toneSeed[0].re = 0.5f;
    c.probeEnabled = true;
    N60AdaptiveTonal *core = N60AdaptiveTonalCreate(&c);
    const uint32_t frames = (uint32_t)(0.2 * fs);
    float *err = malloc(frames * sizeof(float));
    float *out = malloc(frames * sizeof(float));
    for (uint32_t n = 0; n < frames; ++n) err[n] = (n % 3) ? NAN : INFINITY;
    for (uint32_t i = 0; i < frames; i += 512) {
        const uint32_t m = frames - i < 512 ? frames - i : 512;
        N60AdaptiveTonalProcess(core, err + i, out + i, m);
        N60AdaptiveTonalService(core);
    }
    const N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(core);
    CHECK(isfinite(st.weight[0].re) && isfinite(st.weight[0].im) && isfinite(st.path[0].re),
          "%.0f Hz: non-finite reached the model", fs);
    bool finiteOut = true;
    for (uint32_t n = 0; n < frames; ++n) finiteOut = finiteOut && isfinite(out[n]);
    CHECK(finiteOut, "%.0f Hz: non-finite output", fs);
    free(err);
    free(out);
    N60AdaptiveTonalDestroy(core);
}

/* Block FxLMS (decimated domain) --------------------------------------------- */

#define BLOCK_TAPS 32u
#define BLOCK_FRAMES 16u
static const float kPath[] = {0, 0, 0, 0.5f, 0.25f, 0.1f};
#define PATH_TAPS (sizeof kPath / sizeof kPath[0])

static void target_weights(float *w0) {
    for (uint32_t k = 0; k < BLOCK_TAPS; ++k) {
        w0[k] = (float)(0.8 * exp(-0.15 * k) * cos(0.9 * k));
    }
}

typedef struct {
    double residual, noise;
    float weights[BLOCK_TAPS];
    bool finiteAll;
} BlockResult;

/* Feed-forward loop at rate fd: d = -(S * W0) * x + noise, e = d + S * (W * x).
 * The controller applies its current weights; the plant uses the true path. */
static BlockResult run_block(double fd, float step, double leakage, float pathScale,
                             double seconds, double xRMS, double noiseRMS,
                             const float *seedWeights) {
    N60BlockFxlmsConfig c = N60BlockFxlmsConfigDefault(fd);
    c.taps = BLOCK_TAPS;
    c.blockFrames = BLOCK_FRAMES;
    c.step = step;
    c.leakagePerSecond = leakage;
    N60BlockFxlms *fx = N60BlockFxlmsCreate(&c);
    float shat[PATH_TAPS];
    for (size_t k = 0; k < PATH_TAPS; ++k) shat[k] = kPath[k] * pathScale;
    N60BlockFxlmsSetPath(fx, shat, PATH_TAPS);
    if (seedWeights) N60BlockFxlmsSetWeights(fx, seedWeights, BLOCK_TAPS);
    float w0[BLOCK_TAPS];
    target_weights(w0);

    enum { H = 64 };
    double xh[H] = {0}, yh[H] = {0}, ph[H] = {0};  /* newest at [0] */
    uint64_t rng = 99;
    const uint64_t blocks = (uint64_t)(seconds * fd / BLOCK_FRAMES);
    const uint64_t measureFrom = blocks - (uint64_t)(1.0 * fd / BLOCK_FRAMES);
    BlockResult r = {.finiteAll = true};
    float w[BLOCK_TAPS], xb[BLOCK_FRAMES], eb[BLOCK_FRAMES];
    for (uint64_t b = 0; b < blocks; ++b) {
        N60BlockFxlmsCopyWeights(fx, w, BLOCK_TAPS);
        for (uint32_t i = 0; i < BLOCK_FRAMES; ++i) {
            memmove(xh + 1, xh, (H - 1) * sizeof(double));
            memmove(yh + 1, yh, (H - 1) * sizeof(double));
            memmove(ph + 1, ph, (H - 1) * sizeof(double));
            xh[0] = xRMS * plant_gaussian(&rng);
            double y = 0, primary = 0;
            for (uint32_t k = 0; k < BLOCK_TAPS; ++k) {
                y += w[k] * xh[k];
                primary += w0[k] * xh[k];
            }
            yh[0] = y;
            ph[0] = primary;
            double sy = 0, sp = 0;
            for (size_t k = 0; k < PATH_TAPS; ++k) {
                sy += kPath[k] * yh[k];
                sp += kPath[k] * ph[k];
            }
            const double noise = noiseRMS * plant_gaussian(&rng);
            const double e = -sp + sy + noise;
            xb[i] = (float)xh[0];
            eb[i] = (float)e;
            if (b >= measureFrom) {
                r.residual += e * e;
                r.noise += noise * noise;
            }
        }
        N60BlockFxlmsUpdate(fx, xb, eb, BLOCK_FRAMES);
    }
    N60BlockFxlmsCopyWeights(fx, r.weights, BLOCK_TAPS);
    for (uint32_t k = 0; k < BLOCK_TAPS; ++k) r.finiteAll = r.finiteAll && isfinite(r.weights[k]);
    N60BlockFxlmsDestroy(fx);
    return r;
}

static double weight_error(const float *w) {
    float w0[BLOCK_TAPS];
    target_weights(w0);
    double num = 0, den = 0;
    for (uint32_t k = 0; k < BLOCK_TAPS; ++k) {
        num += (w[k] - w0[k]) * (w[k] - w0[k]);
        den += w0[k] * w0[k];
    }
    return sqrt(num / den);
}

static void test_block(double fs) {
    const double fd = fs / N60AncDecimationFactor(fs);
    BlockResult r = run_block(fd, 0.1f, 0.001, 1.0f, 20.0, 0.1, 1e-3, NULL);
    CHECK(db(r.residual / r.noise) < 1.0 && weight_error(r.weights) < 0.05,
          "%.0f Hz: block Wiener residual +%.2f dB, weight error %.3f", fs,
          db(r.residual / r.noise), weight_error(r.weights));
    const double wienerDB = db(r.residual / r.noise);

    r = run_block(fd, N60_FXLMS_MAX_BLOCK_STEP, 0.01, 0.7f, 20.0, 0.1, 1e-3, NULL);
    CHECK(r.finiteAll && db(r.residual / r.noise) < 1.0 && weight_error(r.weights) < 0.1,
          "%.0f Hz: block max step residual +%.2f dB, weight error %.3f", fs,
          db(r.residual / r.noise), weight_error(r.weights));
    const double maxDB = db(r.residual / r.noise);

    /* No reference: only leakage acts, an exact exponential decay. */
    float w0[BLOCK_TAPS];
    target_weights(w0);
    r = run_block(fd, 0.1f, 0.2, 1.0f, 10.0, 0.0, 0.01, w0);
    const uint64_t blocks = (uint64_t)(10.0 * fd / BLOCK_FRAMES);
    const double decay = pow(1.0 - 0.2 * BLOCK_FRAMES / fd, (double)blocks);
    double worst = 0;
    for (uint32_t k = 0; k < BLOCK_TAPS; ++k) {
        const double e = fabs(r.weights[k] - w0[k] * decay);
        if (e > worst) worst = e;
    }
    CHECK(worst < 1e-5, "%.0f Hz: leakage decay off by %.2e", fs, worst);

    /* A near-silent reference (-120 dBFS) with a noisy error: without the
     * -80 dBFS power floor each block would move the weights by about 60; with
     * it and the leakage they stay bounded. */
    r = run_block(fd, N60_FXLMS_MAX_BLOCK_STEP, 0.01, 1.0f, 60.0, 1e-6, 0.01, NULL);
    double largest = 0;
    for (uint32_t k = 0; k < BLOCK_TAPS; ++k) {
        if (fabs(r.weights[k]) > largest) largest = fabs(r.weights[k]);
    }
    CHECK(r.finiteAll && largest < 1.0, "%.0f Hz: weak-reference weight %.3f", fs, largest);
    printf("  block    %6.0f Hz (fd %.1f): Wiener +%.2f dB, max step +%.2f dB, weak ref %.4f\n",
           fs, fd, wienerDB, maxDB, largest);
}

/* Configuration --------------------------------------------------------------- */

static void test_config(void) {
    const double hz[] = {60.0};
    N60AdaptiveTonalConfig c = tonal_config(48000, 1, hz);
    CHECK(N60AdaptiveTonalConfigIsValid(&c), "default tonal config rejected");
    N60AdaptiveTonalConfig bad = c;
    bad.toneHz[0] = 10.0f;
    CHECK(!N60AdaptiveTonalConfigIsValid(&bad), "10 Hz tone accepted");
    bad = c;
    bad.convergenceSeconds = 0.05;
    CHECK(!N60AdaptiveTonalConfigIsValid(&bad), "step above the maximum accepted");
    bad = c;
    bad.probeLevelDBFS = -30.0f;
    CHECK(!N60AdaptiveTonalConfigIsValid(&bad), "loud probe accepted");
    bad = c;
    bad.pathTaps = 128;
    bad.pathConvergenceSeconds = 0.05;
    CHECK(!N60AdaptiveTonalConfigIsValid(&bad), "path step above 0.5 accepted");
    bad = c;
    bad.sampleRate = 1e6;
    CHECK(N60AdaptiveTonalCreate(&bad) == NULL, "1 MHz accepted");
    bad = c;
    bad.shadow = true;
    bad.probeEnabled = true;
    CHECK(!N60AdaptiveTonalConfigIsValid(&bad), "shadow with the probe accepted");
    bad = c;
    bad.toneCount = 5;
    CHECK(!N60AdaptiveTonalConfigIsValid(&bad), "five tones accepted");

    N60BlockFxlmsConfig b = N60BlockFxlmsConfigDefault(4000);
    CHECK(N60BlockFxlmsConfigIsValid(&b), "default block config rejected");
    N60BlockFxlmsConfig badb = b;
    badb.step = 0.6f;
    CHECK(!N60BlockFxlmsConfigIsValid(&badb), "block step 0.6 accepted");
    badb = b;
    badb.taps = 0;
    CHECK(N60BlockFxlmsCreate(&badb) == NULL, "zero taps accepted");
    N60BlockFxlms *fx = N60BlockFxlmsCreate(&b);
    float taps[129] = {1};
    CHECK(fx && !N60BlockFxlmsSetPath(fx, taps, 129) && N60BlockFxlmsSetPath(fx, taps, 128),
          "path length limits");
    N60BlockFxlmsDestroy(fx);
}

int main(void) {
    test_config();
    for (size_t r = 0; r < RATE_COUNT; ++r) {
        const double fs = kRates[r];
        test_decimator(fs);
        test_wiener(fs);
        test_path_tracking(fs);
        test_max_step(fs);
        test_shadow(fs);
        test_caps(fs);
        test_gap_and_reset(fs);
        test_non_finite(fs);
        test_block(fs);
    }
    test_rate_identity();
    if (failures) {
        fprintf(stderr, "E4 FxLMS harness: %d failure(s)\n", failures);
        return 1;
    }
    printf("E4 FxLMS harness: PASS at %zu rates\n", RATE_COUNT);
    return 0;
}
