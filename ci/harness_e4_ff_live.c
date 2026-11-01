/*
 * E4 S25a: behavioural harness for the live feed-forward filter (N60FeedForwardLive.h) at the
 * eight standard rates. This is also the S25r prototype: it measures the head/tail seam accuracy
 * (the live response against the ideal response of the fd weights), the added delay and the
 * cancellation on a simulated plant, so the design note's figures come from here.
 *
 * Plant: reference microphone x (tones 31.5 to 150 Hz), primary path P = gain 0.8 and a delay,
 * secondary path S = gain 0.5 and 3 fd samples of delay. The ideal weights are the fractional
 * delay of (P delay - S delay) times -0.8 / 0.5, designed at fd with a Blackman sinc. Cases put
 * that delay in the head (1.7 ms), across the seam (2.0 ms) and in the tail (5.2 ms).
 */
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

static N60FeedForwardLive *make(double fs, double peak) {
    N60FeedForwardLiveConfig config = {fs, MAX_BLOCK, 0, 0, peak};
    N60FeedForwardLive *live = N60FeedForwardLiveCreate(&config);
    if (!live) { fprintf(stderr, "FAIL create at %g\n", fs); failures++; exit(1); }
    return live;
}

/* Blackman-windowed fractional delay at fd: delay in fd samples, +-half taps. */
static uint32_t fractional_delay(float *w, double delay, uint32_t half, double gain) {
    const uint32_t count = 2 * half + 1 + (uint32_t)floor(delay);
    memset(w, 0, 512 * sizeof(float));
    const int centre = (int)floor(delay);
    for (int k = -(int)half; k <= (int)half; ++k) {
        const int i = centre + k;
        if (i < 0 || i >= 512) continue;
        const double t = i - delay;
        if (fabs(t) > half + 0.5) continue;
        const double x = acos(-1.0) * t;
        const double sinc = fabs(t) < 1e-12 ? 1.0 : sin(x) / x;
        const double u = (t + half + 0.5) / (2.0 * half + 1.0);
        const double win = 0.42 - 0.5 * cos(TWO_PI * u) + 0.08 * cos(2 * TWO_PI * u);
        w[i] = (float)(gain * sinc * win);
    }
    return count < 512 ? count : 512;
}

typedef struct { double f, phase; } Tone;
static const Tone kTones[] = {{31.5, 0.3}, {63.0, 1.7}, {125.0, 4.1}, {47.0, 2.2}, {90.0, 5.3}, {150.0, 0.9}};
#define TONES (sizeof kTones / sizeof kTones[0])

static double reference_at(uint64_t n, double fs) {
    double v = 0;
    for (size_t k = 0; k < TONES; ++k) v += 0.02 * sin(TWO_PI * kTones[k].f * (double)n / fs + kTones[k].phase);
    return v;
}

/* Hann-windowed single-bin projection power of a signal at f over [from, to). */
static double band_power(const double *x, uint64_t from, uint64_t to, double fs, double f) {
    double re = 0, im = 0, norm = 0;
    const uint64_t length = to - from;
    for (uint64_t n = from; n < to; ++n) {
        const double win = 0.5 - 0.5 * cos(TWO_PI * (double)(n - from) / (double)length);
        const double a = TWO_PI * f * (double)n / fs;
        re += win * x[n] * cos(a);
        im -= win * x[n] * sin(a);
        norm += win;
    }
    re /= norm; im /= norm;
    return re * re + im * im;
}

static void run_plant(double fs, double delay_fd, const char *label) {
    const uint32_t D = factor_for(fs);
    const double fd = fs / D;
    const uint32_t s_delay = 3 * D;
    const uint32_t p_delay = s_delay + (uint32_t)llround(delay_fd * D);
    const double delay_eff = (double)(p_delay - s_delay) / D;
    float w[512];
    const uint32_t count = fractional_delay(w, delay_eff, 6, -0.8 / 0.5);
    N60FeedForwardLive *live = make(fs, 1.0);
    CHECK(N60FeedForwardLiveSetWeights(live, w, w, count), "weights");
    CHECK(N60FeedForwardLiveArm(live, 0.02, 0.01) == N60FeedForwardLiveArmOK, "arm");
    const uint64_t total = (uint64_t)(0.7 * fs);
    double *before = calloc(total, sizeof(double)), *after = calloc(total, sizeof(double));
    float *x = calloc(total, sizeof(float)), *yl = calloc(total, sizeof(float)), *yr = calloc(total, sizeof(float));
    for (uint64_t n = 0; n < total; ++n) x[n] = (float)reference_at(n, fs);
    for (uint64_t n = 0; n < total;) {
        const uint32_t block = (uint32_t)((total - n) < 480 ? (total - n) : 480);
        N60FeedForwardLiveProcess(live, x + n, yl + n, yr + n, block);
        n += block;
    }
    for (uint64_t n = 0; n < total; ++n) {
        const double d = n >= p_delay ? 0.8 * reference_at(n - p_delay, fs) : 0;
        const double anti = n >= s_delay ? 0.5 * 0.5 * ((double)yl[n - s_delay] + (double)yr[n - s_delay]) : 0;
        before[n] = d;
        after[n] = d + anti;
    }
    /* The two speakers each carry half so that the sum of both is the full anti-noise. */
    const uint64_t from = (uint64_t)(0.4 * fs);
    double worst = 1e9;
    for (size_t k = 0; k < 3; ++k) {
        const double f = kTones[k].f;
        const double reduction = 10.0 * log10(band_power(before, from, total, fs, f)
                                               / (band_power(after, from, total, fs, f) + 1e-30));
        if (reduction < worst) worst = reduction;
        CHECK(reduction >= 6.0, "%s %.0f Hz: %.1f dB below the 6 dB requirement", label, f, reduction);
    }
    CHECK(worst >= 40.0, "%s at %g Hz: worst in-band reduction %.1f dB below 40 dB", label, fs, worst);
    printf("  %-6s %8.1f Hz  D=%3u fd=%7.1f  delay %.2f fd  worst reduction %.1f dB\n", label, fs, D, fd,
           delay_eff, worst);
    free(before); free(after); free(x); free(yl); free(yr);
    N60FeedForwardLiveDestroy(live);
}

/* Blackman-windowed sinc, 2 half D + 1 taps, cutoff 0.5 fd, unity DC gain (spec in the header). */
static double *make_kernel(uint32_t D, uint32_t half, double dc_gain, uint32_t *length_out) {
    const uint32_t length = 2 * half * D + 1;
    double *k = malloc(length * sizeof(double));
    const double fc = 0.5 / D, centre = 0.5 * (length - 1), span = length - 1;
    double sum = 0;
    for (uint32_t i = 0; i < length; ++i) {
        const double t = i - centre, x = TWO_PI * fc * t;
        const double sinc = t == 0 ? 1.0 : sin(x) / x;
        const double win = 0.42 - 0.5 * cos(TWO_PI * i / span) + 0.08 * cos(2.0 * TWO_PI * i / span);
        k[i] = 2.0 * fc * sinc * win;
        sum += k[i];
    }
    for (uint32_t i = 0; i < length; ++i) k[i] *= dc_gain / sum;
    *length_out = length;
    return k;
}

/* Seam: the live output of fd weights against direct convolution with the ideal causal response
   h[n] = sum_i w[i] c(n - i D) / D, c = decimator * interpolator centred at 2 half D. */
static double ideal_error_db(double fs, const float *w, uint32_t count, const double *tones, size_t tone_count) {
    const uint32_t D = factor_for(fs), half = 4;
    uint32_t L;
    double *dec = make_kernel(D, half, 1.0, &L);
    double *itp = make_kernel(D, half, D, &L);
    const uint32_t cl = 2 * L - 1, centre = 2 * half * D;
    double *c = calloc(cl, sizeof(double));
    for (uint32_t i = 0; i < L; ++i)
        for (uint32_t j = 0; j < L; ++j) c[i + j] += dec[i] * itp[j];
    const uint32_t hl = count * D + centre + 1;
    double *h = calloc(hl, sizeof(double));
    for (uint32_t i = 0; i < count; ++i)
        for (uint32_t n = 0; n < hl; ++n) {
            const long idx = (long)n - (long)i * D + (long)centre;
            if (idx >= 0 && idx < (long)cl) h[n] += w[i] * c[idx] / D;
        }
    const uint64_t total = (uint64_t)hl + 6000 + (uint64_t)(0.08 * fs);  /* past the 50 ms arm ramp */
    float *x = malloc(total * sizeof(float)), *yl = malloc(total * sizeof(float)), *yr = malloc(total * sizeof(float));
    for (uint64_t n = 0; n < total; ++n) {
        double v = 0;
        for (size_t t = 0; t < tone_count; ++t) v += 0.03 * sin(TWO_PI * tones[t] * (double)n / fs + 0.7 * t);
        x[n] = (float)v;
    }
    N60FeedForwardLive *live = make(fs, 1.0);
    N60FeedForwardLiveSetWeights(live, w, w, count);
    N60FeedForwardLiveArm(live, 1, 0);
    for (uint64_t n = 0; n < total; n += 480) {
        const uint32_t b = (uint32_t)((total - n) < 480 ? (total - n) : 480);
        N60FeedForwardLiveProcess(live, x + n, yl + n, yr + n, b);
    }
    double err = 0, sig = 0;
    for (uint64_t n = total - 3000; n < total; ++n) {
        double ideal = 0;
        for (uint32_t k = 0; k < hl && k <= n; ++k) ideal += h[k] * x[n - k];
        const double d = (double)yl[n] - ideal;
        err += d * d; sig += ideal * ideal;
    }
    N60FeedForwardLiveDestroy(live);
    free(dec); free(itp); free(c); free(h); free(x); free(yl); free(yr);
    return 10.0 * log10((err + 1e-30) / (sig + 1e-30));
}

static void seam_accuracy(double fs) {
    static const double tones[] = {31.5, 63, 125, 250, 500};
    float w[512];
    uint64_t seed = 88172645463325252ull;
    const uint32_t count = 40;
    for (uint32_t i = 0; i < count; ++i) {
        seed ^= seed >> 12; seed ^= seed << 25; seed ^= seed >> 27;
        const double r = (double)((seed * 2685821657736338717ull) >> 11) / 9007199254740992.0 - 0.5;
        w[i] = (float)(r * exp(-(double)i / 20.0));
    }
    const double random_db = ideal_error_db(fs, w, count, tones, 5);
    CHECK(random_db <= -60.0, "random weights: live vs ideal %.1f dB at %g Hz (need -60 or lower)", random_db, fs);
    /* A weight exactly on the seam (fd index 8 is the first tail tap) and one just inside the head. */
    memset(w, 0, sizeof w);
    w[7] = 0.6f; w[8] = -0.4f;
    const double seam_db = ideal_error_db(fs, w, 12, tones, 5);
    CHECK(seam_db <= -60.0, "seam weights: live vs ideal %.1f dB at %g Hz", seam_db, fs);
    printf("  seam   %8.1f Hz  live vs ideal: random %.1f dB, seam taps %.1f dB\n", fs, random_db, seam_db);
}

static void zero_delay(double fs) {
    /* The first tap acts on the current sample: an fd delta well inside the head has the native
       response c(n - i D), so the output starts without any added latency. */
    const uint32_t D = factor_for(fs);
    float w[16] = {0};
    w[3] = 1.0f;
    N60FeedForwardLive *live = make(fs, 1.0);
    N60FeedForwardLiveSetWeights(live, w, w, 4);
    N60FeedForwardLiveArm(live, 1, 0);
    const uint64_t total = (uint64_t)(0.4 * fs);
    float *x = calloc(total, sizeof(float)), *yl = malloc(total * sizeof(float)), *yr = malloc(total * sizeof(float));
    /* Warm up the gain ramp, then an impulse. */
    N60FeedForwardLiveProcess(live, x, yl, yr, (uint32_t)(0.2 * fs));
    x[0] = 1.0f;
    N60FeedForwardLiveProcess(live, x, yl, yr, (uint32_t)(0.2 * fs));
    /* The peak of the response of an impulse through a delta at fd lag 3 sits at 3 D native frames. */
    uint32_t peak_at = 0;
    float peak = 0;
    for (uint32_t n = 0; n < (uint32_t)(0.1 * fs); ++n) if (fabsf(yl[n]) > peak) { peak = fabsf(yl[n]); peak_at = n; }
    CHECK(abs((int)peak_at - (int)(3 * D)) <= 1, "impulse peak at %u, expected %u (D=%u, %g Hz)", peak_at, 3 * D, D, fs);
    CHECK(N60FeedForwardLiveGetStatus(live).addedDelayFrames == 0, "added delay frames reported");
    free(x); free(yl); free(yr);
    N60FeedForwardLiveDestroy(live);
}

static void gate_and_trips(double fs) {
    float w[512];
    fractional_delay(w, 20.4, 6, -1.0);
    N60FeedForwardLive *live = make(fs, 1.0);
    CHECK(N60FeedForwardLiveArm(live, 1, 0) == N60FeedForwardLiveArmNoWeights, "arm without weights");
    N60FeedForwardLiveSetWeights(live, w, w, 40);
    CHECK(N60FeedForwardLiveArm(live, 0.002, 0.005) == N60FeedForwardLiveArmShortLead, "short lead refused");
    CHECK(N60FeedForwardLiveGetStatus(live).state == N60FeedForwardLiveIdle, "still idle after refusal");
    CHECK(N60FeedForwardLiveArm(live, 0.010, 0.005) == N60FeedForwardLiveArmOK, "good lead accepted");

    const uint32_t block = 480;
    float x[480], yl[480], yr[480];
    uint64_t n0 = 0;
    for (int b = 0; b < (int)(0.3 * fs / block); ++b) {
        for (uint32_t i = 0; i < block; ++i) x[i] = (float)reference_at(n0 + i, fs);
        N60FeedForwardLiveProcess(live, x, yl, yr, block);
        n0 += block;
    }
    CHECK(N60FeedForwardLiveGetStatus(live).state == N60FeedForwardLiveArmed, "armed");
    CHECK(N60FeedForwardLiveGetStatus(live).gain > 0.99f, "ramp complete");
    float peak = 0;
    for (uint32_t i = 0; i < block; ++i) peak = fmaxf(peak, fabsf(yl[i]));
    CHECK(peak > 0.005f, "armed filter produces output (peak %g)", peak);

    N60FeedForwardLiveMarkReferenceLost(live);
    const int silent_blocks = (int)ceil(0.03 * fs / block) + 1;
    for (int b = 0; b < silent_blocks; ++b) {
        for (uint32_t i = 0; i < block; ++i) x[i] = (float)reference_at(n0 + i, fs);
        N60FeedForwardLiveProcess(live, x, yl, yr, block);
        n0 += block;
    }
    bool silent = true;
    for (uint32_t i = 0; i < block; ++i) if (yl[i] != 0 || yr[i] != 0) silent = false;
    CHECK(silent, "output is silent after the reference is lost");
    const N60FeedForwardLiveStatus st = N60FeedForwardLiveGetStatus(live);
    CHECK(st.state == N60FeedForwardLiveTripped && st.tripReason == N60FeedForwardLiveTripReferenceLost,
          "tripped for reference loss");
    CHECK(N60FeedForwardLiveArm(live, 1, 0) == N60FeedForwardLiveArmTripped, "no re-arm while tripped");
    N60FeedForwardLiveReset(live);
    CHECK(N60FeedForwardLiveArm(live, 1, 0) == N60FeedForwardLiveArmOK, "re-arm after reset");

    /* Non-finite input trips and stays silent. */
    for (uint32_t i = 0; i < block; ++i) x[i] = NAN;
    N60FeedForwardLiveProcess(live, x, yl, yr, block);
    CHECK(N60FeedForwardLiveGetStatus(live).tripReason == N60FeedForwardLiveTripNonFinite, "non-finite trips");
    for (uint32_t i = 0; i < block; ++i) CHECK(isfinite(yl[i]) && isfinite(yr[i]), "finite output after NaN");
    N60FeedForwardLiveDestroy(live);
}

static void swap_and_clamp(double fs) {
    float a[512], b[512];
    fractional_delay(a, 14.3, 6, -1.0);
    fractional_delay(b, 9.6, 6, -0.7);
    N60FeedForwardLive *live = make(fs, 1.0);
    N60FeedForwardLiveSetWeights(live, a, a, 40);
    N60FeedForwardLiveArm(live, 1, 0);
    const uint64_t total = (uint64_t)(0.9 * fs);
    float *x = malloc(total * sizeof(float)), *yl = malloc(total * sizeof(float)), *yr = malloc(total * sizeof(float));
    for (uint64_t n = 0; n < total; ++n) x[n] = (float)(0.1 * sin(TWO_PI * 80.0 * (double)n / fs));
    const uint64_t swapAt = (uint64_t)(0.5 * fs);
    N60FeedForwardLiveProcess(live, x, yl, yr, (uint32_t)swapAt);
    N60FeedForwardLiveSetWeights(live, b, b, 40);
    N60FeedForwardLiveProcess(live, x + swapAt, yl + swapAt, yr + swapAt, (uint32_t)(total - swapAt));
    double steady = 0, jump = 0;
    for (uint64_t n = (uint64_t)(0.3 * fs); n < swapAt; ++n) steady = fmax(steady, fabs((double)yl[n] - yl[n - 1]));
    for (uint64_t n = swapAt; n < total; ++n) jump = fmax(jump, fabs((double)yl[n] - yl[n - 1]));
    CHECK(jump <= 1.5 * steady, "swap discontinuity %g vs steady slope %g at %g Hz", jump, steady, fs);
    CHECK(N60FeedForwardLiveGetStatus(live).setsApplied == 2, "two sets applied");
    N60FeedForwardLiveDestroy(live);

    /* Peak clamp. */
    float big[512];
    fractional_delay(big, 10.0, 6, -8.0);
    live = make(fs, 0.1);
    N60FeedForwardLiveSetWeights(live, big, big, 40);
    N60FeedForwardLiveArm(live, 1, 0);
    N60FeedForwardLiveProcess(live, x, yl, yr, (uint32_t)(0.4 * fs));
    float peak = 0;
    for (uint64_t n = 0; n < (uint64_t)(0.4 * fs); ++n) peak = fmaxf(peak, fmaxf(fabsf(yl[n]), fabsf(yr[n])));
    CHECK(peak <= 0.1f + 1e-6f, "clamp holds: peak %g", peak);
    CHECK(N60FeedForwardLiveGetStatus(live).clampedSamples > 0, "clamp counted");
    N60FeedForwardLiveDestroy(live);
    free(x); free(yl); free(yr);
}

static void block_independence(double fs) {
    float w[512];
    fractional_delay(w, 30.2, 6, -1.0);
    const uint64_t total = (uint64_t)(0.25 * fs);
    float *x = malloc(total * sizeof(float));
    float *o1 = malloc(total * sizeof(float)), *o2 = malloc(total * sizeof(float)), *junk = malloc(total * sizeof(float));
    for (uint64_t n = 0; n < total; ++n) x[n] = (float)reference_at(n, fs);
    const uint32_t sizes[2] = {7, 1000};
    float *outs[2] = {o1, o2};
    for (int run = 0; run < 2; ++run) {
        N60FeedForwardLive *live = make(fs, 1.0);
        N60FeedForwardLiveSetWeights(live, w, w, 60);
        N60FeedForwardLiveArm(live, 1, 0);
        for (uint64_t n = 0; n < total;) {
            const uint32_t b = (uint32_t)((total - n) < sizes[run] ? (total - n) : sizes[run]);
            N60FeedForwardLiveProcess(live, x + n, outs[run] + n, junk + n, b);
            n += b;
        }
        N60FeedForwardLiveDestroy(live);
    }
    CHECK(memcmp(o1, o2, total * sizeof(float)) == 0, "block size changes the output at %g Hz", fs);
    free(x); free(o1); free(o2); free(junk);
}

int main(void) {
    N60FeedForwardLiveConfig bad = {0, MAX_BLOCK, 0, 0, 1.0};
    CHECK(!N60FeedForwardLiveConfigIsValid(&bad), "rate 0 rejected");
    bad = (N60FeedForwardLiveConfig){48000, 8, 0, 0, 1.0};
    CHECK(!N60FeedForwardLiveConfigIsValid(&bad), "block 8 rejected");
    bad = (N60FeedForwardLiveConfig){48000, MAX_BLOCK, 2, 0, 1.0};
    CHECK(!N60FeedForwardLiveConfigIsValid(&bad), "kernelHalf 2 rejected");
    bad.kernelHalf = 5;
    CHECK(!N60FeedForwardLiveConfigIsValid(&bad), "kernelHalf 5 rejected");
    CHECK(!N60FeedForwardLiveConfigIsValid(NULL), "null rejected");
    for (size_t r = 0; r < RATE_COUNT; ++r) {
        const double fs = kRates[r];
        printf("rate %g\n", fs);
        seam_accuracy(fs);
        zero_delay(fs);
        run_plant(fs, 1.7e-3 * (fs / factor_for(fs)), "head");
        run_plant(fs, 2.0e-3 * (fs / factor_for(fs)), "seam");
        run_plant(fs, 5.2e-3 * (fs / factor_for(fs)), "tail");
        gate_and_trips(fs);
        swap_and_clamp(fs);
        block_independence(fs);
    }
    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    puts("e4_ff_live: OK");
    return 0;
}
