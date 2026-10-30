/*
 * E4 S22b1: behavioural harness for the feed-forward echo stage (echo functions of
 * N60FeedForwardShadow in N60Fxlms.h) at the eight standard rates, plus a 44.1 kHz drive with
 * 48 kHz microphones and 100 ppm drift.
 *
 * The speakers play white noise (the drive). The reference microphone hears it through a
 * sparse 127 ms leakage built on the decimated-rate grid and shifted by an unknown fixed
 * latency; the error microphone hears it through the shadow's own secondary paths. The shadow
 * is given the exact leakage model and must find the latency itself.
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60Fxlms.h"

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

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
#define RATE_COUNT (sizeof kRates / sizeof kRates[0])
#define BUFFER 480u
#define TAPS 64u
#define ECHO_TAPS 400u
#define SPARSE 24u
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
#define PRIMARY_DELAY 20u

typedef struct {
    double fs, fo;
    double ratio;        /* drive frames per mic frame (the clock fit) */
    double shift;        /* mic frames: echo later than the model when positive */
    double driveRMS;     /* 0 = programme off */
    double xRMS;         /* primary noise at the reference microphone */
    double noiseRMS;     /* microphone noise */
    bool mismatched;     /* the real leakage is unrelated to the drive the model sees */
    bool echo;           /* set the echo model */
    bool errorProgramme; /* drive reaches the error microphone through the paths */
    bool setPaths;
    bool seedWeights;
    float seed[2][TAPS];
} Scn;

typedef struct {
    Scn scn;
    N60FeedForwardShadow *shadow;
    uint32_t factor;
    float *drive[2];
    uint64_t driveCount, drivePushed, micPos;
    float *noise;
    uint32_t noiseLen, noisePos;
    uint64_t rng, rngDrive;
    uint32_t pos[2][SPARSE];
    float amp[2][SPARSE];
} Sim;

static double drive_at(const Sim *s, uint32_t c, double index) {
    if (index < 0) return 0.0;
    const uint64_t i = (uint64_t)index;
    if (i + 1 >= s->driveCount) return 0.0;
    const double t = index - (double)i;
    return (1.0 - t) * s->drive[c][i] + t * s->drive[c][i + 1];
}

static Sim *sim_make(Scn scn, double maxSeconds) {
    Sim *s = calloc(1, sizeof *s);
    s->scn = scn;
    s->factor = N60AncDecimationFactor(scn.fs);
    N60FeedForwardShadowConfig config = N60FeedForwardShadowConfigDefault(scn.fs);
    config.taps = TAPS;
    config.step = 0.05f;
    config.blockFrames = 8;
    config.leakagePerSecond = 0.001;
    config.peakGainLimit = 16.0f;
    config.driveSampleRate = scn.fo;
    s->shadow = N60FeedForwardShadowCreate(&config);
    if (!s->shadow) { fprintf(stderr, "create failed at %.0f\n", scn.fs); exit(2); }
    s->driveCount = (uint64_t)(maxSeconds * scn.fo * 1.2) + 40000u;
    s->rng = 7;
    s->rngDrive = 99;
    uint64_t lay = 12345;
    float taps[2][ECHO_TAPS];
    memset(taps, 0, sizeof taps);
    for (uint32_t c = 0; c < 2; ++c) {
        s->drive[c] = calloc(s->driveCount, sizeof(float));
        for (uint64_t i = 0; i < s->driveCount; ++i)
            s->drive[c][i] = (float)(scn.driveRMS * gaussian(&s->rngDrive));
        for (uint32_t k = 0; k < SPARSE; ++k) {
            s->pos[c][k] = (uint32_t)(next_random(&lay) % ECHO_TAPS);
            const double decay = pow(10.0, -30.0 / 20.0 * (double)s->pos[c][k] / ECHO_TAPS);
            s->amp[c][k] = (float)(0.35 * decay * gaussian(&lay));
            taps[c][s->pos[c][k]] += s->amp[c][k];
        }
    }
    if (scn.setPaths) {
        N60FeedForwardShadowSetPath(s->shadow, 0, LEFT_DELAY, kLeftPath, 3);
        N60FeedForwardShadowSetPath(s->shadow, 1, RIGHT_DELAY, kRightPath, 3);
    }
    if (scn.seedWeights) N60FeedForwardShadowSetSeed(s->shadow, scn.seed[0], scn.seed[1], TAPS);
    if (scn.echo)
        for (uint32_t c = 0; c < 2; ++c) N60FeedForwardShadowSetEcho(s->shadow, c, 0, taps[c], ECHO_TAPS);
    N60FeedForwardShadowSetDriveTiming(s->shadow, 0, 0.0, scn.ratio);
    s->noiseLen = PRIMARY_DELAY * s->factor + 1;
    s->noise = calloc(s->noiseLen, sizeof(float));
    return s;
}

static void sim_free(Sim *s) {
    N60FeedForwardShadowDestroy(s->shadow);
    free(s->drive[0]); free(s->drive[1]); free(s->noise); free(s);
}

static void sim_run(Sim *s, double seconds) {
    const Scn *c = &s->scn;
    float x[BUFFER], e[BUFFER], l[BUFFER], r[BUFFER];
    const uint64_t buffers = (uint64_t)(seconds * c->fs / BUFFER);
    const double mismatchOffset = c->mismatched ? 20000.0 : 0.0;
    for (uint64_t b = 0; b < buffers; ++b) {
        /* The drive runs ahead of the microphones, as the output does. */
        const uint64_t want = (uint64_t)(c->ratio * ((double)(s->micPos + BUFFER) + 0.05 * c->fs)) + 8u;
        const uint64_t until = want < s->driveCount ? want : s->driveCount;
        while (s->drivePushed < until) {
            uint32_t n = (uint32_t)(until - s->drivePushed);
            if (n > BUFFER) n = BUFFER;
            for (uint32_t i = 0; i < n; ++i) {
                l[i] = s->drive[0][s->drivePushed + i];
                r[i] = s->drive[1][s->drivePushed + i];
            }
            N60FeedForwardShadowPushDrive(s->shadow, l, r, n);
            s->drivePushed += n;
        }
        for (uint32_t i = 0; i < BUFFER; ++i) {
            const double m = (double)(s->micPos + i);
            const double xn = c->xRMS > 0 ? c->xRMS * gaussian(&s->rng) : 0.0;
            s->noise[s->noisePos] = (float)xn;
            s->noisePos = (s->noisePos + 1) % s->noiseLen;
            const double delayed = s->noise[s->noisePos];
            double xm = xn, em = 0.5 * delayed;
            if (c->noiseRMS > 0) {
                xm += c->noiseRMS * gaussian(&s->rng);
                em += c->noiseRMS * gaussian(&s->rng);
            }
            if (c->driveRMS > 0) {
                for (uint32_t ch = 0; ch < 2; ++ch) {
                    for (uint32_t k = 0; k < SPARSE; ++k) {
                        const double t = c->ratio * (m - c->shift - (double)s->pos[ch][k] * s->factor);
                        xm += s->amp[ch][k] * drive_at(s, ch, t + mismatchOffset);
                    }
                    if (c->errorProgramme) {
                        const float *path = ch == 0 ? kLeftPath : kRightPath;
                        const uint32_t dly = ch == 0 ? LEFT_DELAY : RIGHT_DELAY;
                        for (uint32_t j = 0; j < 3; ++j) {
                            const double t = c->ratio * (m - c->shift - (double)(dly + j) * s->factor);
                            em += path[j] * drive_at(s, ch, t);
                        }
                    }
                }
            }
            x[i] = (float)xm;
            e[i] = (float)em;
        }
        N60FeedForwardShadowProcess(s->shadow, x, e, BUFFER);
        s->micPos += BUFFER;
    }
}

static N60FeedForwardShadowStatus status(Sim *s) { return N60FeedForwardShadowReadStatus(s->shadow); }

/* At least 20 dB of a 127 ms leakage removed, on an offset of exactly 8 ms rounded to whole
 * decimated samples (so no fractional-delay error remains in the sparse model). */
static void test_removal(double fs) {
    const uint32_t D = N60AncDecimationFactor(fs);
    const uint32_t lag = (uint32_t)lround(0.008 * fs / D);
    Scn c = {.fs = fs, .fo = fs, .ratio = 1.0, .shift = (double)lag * D, .driveRMS = 0.1,
             .noiseRMS = 1e-3, .echo = true};
    Sim *s = sim_make(c, 9.0);
    sim_run(s, 8.5);
    const N60FeedForwardShadowStatus st = status(s);
    const double removal = db(st.referencePowerBefore / st.referencePowerAfter);
    CHECK(st.echoState == N60_FF_ECHO_LOCKED, "%.0f Hz: state %u peak %.2f", fs, st.echoState, st.searchPeak);
    CHECK(st.echoOffset == (int32_t)lag, "%.0f Hz: offset %d expected %u", fs, st.echoOffset, lag);
    CHECK(removal >= 20.0, "%.0f Hz: removal only %.1f dB", fs, removal);
    printf("  removal  %6.0f Hz: %.1f dB, offset %d, peak %.3f, starved %llu\n", fs, removal,
           st.echoOffset, st.searchPeak, (unsigned long long)st.driveStarved);
    sim_free(s);
}

/* An offset of +/-8 ms that is not a whole number of decimated samples is found within one. */
static void test_offsets(double fs) {
    const uint32_t D = N60AncDecimationFactor(fs);
    for (int sign = -1; sign <= 1; sign += 2) {
        const double shift = sign * (0.008 * fs + 0.37 * D);
        Scn c = {.fs = fs, .fo = fs, .ratio = 1.0, .shift = shift, .driveRMS = 0.1, .noiseRMS = 1e-3,
                 .echo = true};
        Sim *s = sim_make(c, 6.5);
        sim_run(s, 6.0);
        const N60FeedForwardShadowStatus st = status(s);
        CHECK(st.echoState == N60_FF_ECHO_LOCKED, "%.0f Hz shift %+.0f: state %u", fs, shift, st.echoState);
        CHECK(fabs((double)st.echoOffset - shift / D) <= 1.0, "%.0f Hz: offset %d expected %.2f", fs,
              st.echoOffset, shift / D);
        sim_free(s);
    }
}

/* 44.1 kHz drive, 48 kHz microphones, 100 ppm between the clocks. */
static void test_mixed_rate(void) {
    const uint32_t D = N60AncDecimationFactor(48000);
    Scn c = {.fs = 48000, .fo = 44100, .ratio = 44100.0 / 48000.0 * (1.0 + 100e-6),
             .shift = 32.0 * D, .driveRMS = 0.1, .noiseRMS = 1e-3, .echo = true};
    Sim *s = sim_make(c, 9.0);
    sim_run(s, 8.5);
    const N60FeedForwardShadowStatus st = status(s);
    const double removal = db(st.referencePowerBefore / st.referencePowerAfter);
    CHECK(st.echoState == N60_FF_ECHO_LOCKED && removal >= 20.0, "mixed rate: state %u removal %.1f dB",
          st.echoState, removal);
    printf("  mixed    44100->48000 +100 ppm: %.1f dB\n", removal);
    sim_free(s);
}

/* Leakage the model does not match gives no lock, no subtraction. */
static void test_no_lock(void) {
    Scn c = {.fs = 48000, .fo = 48000, .ratio = 1.0, .driveRMS = 0.1, .noiseRMS = 1e-3, .echo = true,
             .mismatched = true};
    Sim *s = sim_make(c, 12.5);
    sim_run(s, 12.0);
    const N60FeedForwardShadowStatus st = status(s);
    CHECK(st.echoState != N60_FF_ECHO_LOCKED, "mismatched leakage must not lock (peak %.2f)", st.searchPeak);
    CHECK(st.searchPeak < 0.7f && st.searchRestarts >= 1, "peak %.2f restarts %llu", st.searchPeak,
          (unsigned long long)st.searchRestarts);
    CHECK(st.referencePowerAfter == st.referencePowerBefore, "reference changed while unlocked: %g vs %g",
          st.referencePowerBefore, st.referencePowerAfter);
    printf("  no lock  peak %.2f after %llu failed searches\n", st.searchPeak,
           (unsigned long long)st.searchRestarts);
    sim_free(s);
}

/* A gap in either stream restarts the search; it locks again afterwards. */
static void test_gap(void) {
    Scn c = {.fs = 48000, .fo = 48000, .ratio = 1.0, .driveRMS = 0.1, .noiseRMS = 1e-3, .echo = true};
    Sim *s = sim_make(c, 20.0);
    sim_run(s, 6.5);
    CHECK(status(s).echoState == N60_FF_ECHO_LOCKED, "locks before the gap");
    N60FeedForwardShadowMarkDiscontinuity(s->shadow);
    N60FeedForwardShadowStatus st = status(s);
    CHECK(st.echoState != N60_FF_ECHO_LOCKED, "a gap must drop the lock (state %u)", st.echoState);
    sim_run(s, 2.0);
    CHECK(status(s).echoState != N60_FF_ECHO_LOCKED, "no lock 2 s after the gap");
    sim_run(s, 6.0);
    CHECK(status(s).echoState == N60_FF_ECHO_LOCKED, "locks again after the gap");
    N60FeedForwardShadowRestartDrive(s->shadow, s->drivePushed);
    st = status(s);
    CHECK(st.echoState != N60_FF_ECHO_LOCKED, "a drive restart must drop the lock");
    sim_free(s);
    printf("  gap      restart and re-lock ok\n");
}

/* Programme at the seat must not move the predicted reduction: same seeded weights, same noise,
 * with and without programme. */
static void test_programme_bias(double fs) {
    Scn base = {.fs = fs, .fo = fs, .ratio = 1.0, .xRMS = 0.1, .noiseRMS = 1e-2, .setPaths = true};
    Sim *a = sim_make(base, 21.0);
    sim_run(a, 20.0);
    Scn withSeed = base;
    withSeed.seedWeights = true;
    for (uint32_t ch = 0; ch < 2; ++ch) N60FeedForwardShadowCopyWeights(a->shadow, ch, withSeed.seed[ch], TAPS);
    sim_free(a);

    Sim *quiet = sim_make(withSeed, 15.0);
    sim_run(quiet, 14.0);
    const N60FeedForwardShadowStatus q = status(quiet);
    sim_free(quiet);

    Scn music = withSeed;
    music.driveRMS = 0.1;
    music.echo = true;
    music.errorProgramme = true;
    music.shift = 4.0 * N60AncDecimationFactor(fs);
    Sim *m = sim_make(music, 15.0);
    sim_run(m, 14.0);
    const N60FeedForwardShadowStatus p = status(m);
    sim_free(m);

    const double quietReduction = db(q.measuredPower / q.predictedPower);
    const double musicReduction = db(p.measuredPower / p.predictedPower);
    CHECK(p.echoState == N60_FF_ECHO_LOCKED, "%.0f Hz: programme run state %u", fs, p.echoState);
    CHECK(fabs(quietReduction - musicReduction) < 0.5, "%.0f Hz: predicted reduction %.2f dB without programme, %.2f with",
          fs, quietReduction, musicReduction);
    printf("  bias     %6.0f Hz: %.2f dB quiet, %.2f dB with programme\n", fs, quietReduction, musicReduction);
}

/* With no drive rate the echo functions do nothing; with a drive but no echo model the core
 * is bit-identical to that. */
static void test_default_identical(void) {
    const double fs = 48000;
    N60FeedForwardShadowConfig off = N60FeedForwardShadowConfigDefault(fs);
    CHECK(off.driveSampleRate == 0, "the default has no drive");
    N60FeedForwardShadowConfig on = off;
    on.driveSampleRate = fs;
    off.taps = on.taps = TAPS;
    N60FeedForwardShadow *a = N60FeedForwardShadowCreate(&off);
    N60FeedForwardShadow *b = N60FeedForwardShadowCreate(&on);
    float tap = 0.1f, x[BUFFER], e[BUFFER], d[BUFFER];
    CHECK(!N60FeedForwardShadowSetEcho(a, 0, 0, &tap, 1), "no echo without a drive rate");
    CHECK(!N60FeedForwardShadowSetEcho(b, 2, 0, &tap, 1) && !N60FeedForwardShadowSetEcho(b, 0, 513, &tap, 1),
          "echo bounds");
    float bad = NAN;
    CHECK(!N60FeedForwardShadowSetEcho(b, 0, 0, &bad, 1), "non-finite echo tap");
    CHECK(!N60FeedForwardShadowSetDriveTiming(b, 0, 0.0, 0.0) && !N60FeedForwardShadowSetDriveTiming(b, 0, NAN, 1.0),
          "timing bounds");
    uint64_t rng = 5;
    for (int blk = 0; blk < 400; ++blk) {
        for (uint32_t i = 0; i < BUFFER; ++i) {
            x[i] = (float)(0.1 * gaussian(&rng));
            e[i] = 0.5f * x[i] + (float)(0.01 * gaussian(&rng));
            d[i] = (float)(0.1 * gaussian(&rng));
        }
        N60FeedForwardShadowPushDrive(a, d, d, BUFFER);
        N60FeedForwardShadowPushDrive(b, d, d, BUFFER);
        N60FeedForwardShadowProcess(a, x, e, BUFFER);
        N60FeedForwardShadowProcess(b, x, e, BUFFER);
    }
    float wa[TAPS], wb[TAPS];
    N60FeedForwardShadowCopyWeights(a, 0, wa, TAPS);
    N60FeedForwardShadowCopyWeights(b, 0, wb, TAPS);
    const N60FeedForwardShadowStatus sa = N60FeedForwardShadowReadStatus(a);
    const N60FeedForwardShadowStatus sb = N60FeedForwardShadowReadStatus(b);
    CHECK(!memcmp(wa, wb, sizeof wa) && sa.measuredPower == sb.measuredPower
              && sa.predictedPower == sb.predictedPower && sa.decimatedSamples == sb.decimatedSamples,
          "the echo stage must be inert without an echo model");
    CHECK(sa.echoState == N60_FF_ECHO_OFF && sb.echoState == N60_FF_ECHO_OFF, "state off");
    N60FeedForwardShadowConfig bigRate = off;
    bigRate.driveSampleRate = 1e6;
    CHECK(!N60FeedForwardShadowConfigIsValid(&bigRate), "a drive rate over 768 kHz is invalid");
    N60FeedForwardShadowDestroy(a);
    N60FeedForwardShadowDestroy(b);
    printf("  default  identical to S9c\n");
}

int main(void) {
    test_default_identical();
    for (size_t i = 0; i < RATE_COUNT; ++i) {
        test_removal(kRates[i]);
        test_offsets(kRates[i]);
    }
    test_mixed_rate();
    test_no_lock();
    test_gap();
    test_programme_bias(48000);
    test_programme_bias(192000);
    if (failures) {
        fprintf(stderr, "e4_ff_echo: %d failure(s)\n", failures);
        return 1;
    }
    puts("e4_ff_echo: ok");
    return 0;
}
