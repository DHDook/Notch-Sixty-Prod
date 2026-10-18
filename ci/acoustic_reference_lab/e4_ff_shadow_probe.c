/*
 * E4 S9a reference-lab probe: drives the production feed-forward shadow
 * (N60FeedForwardShadow in N60Fxlms.h) and prints what it did.
 * e4_ff_shadow_reference.py predicts the same numbers from the written rules.
 *
 * BAND <rate> <hz> <gain_db>         error-meter gain for a cosine on the error
 *                                    microphone (decimator and band filters)
 * FIXED <rate> <ch> <re> <im>        converged weights' response at 60 Hz; both
 *                                    paths 0.5 z^-8, disturbance 0.5 x delayed
 *                                    by 20 decimated samples, zero seed
 */
#include <complex.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60Fxlms.h"

#define BUFFER 512u
#define TAPS 64u
static const double kRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
};

static void fail(const char *what) {
    fprintf(stderr, "probe: %s\n", what);
    exit(2);
}

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

static N60FeedForwardShadow *make(double fs) {
    N60FeedForwardShadowConfig c = N60FeedForwardShadowConfigDefault(fs);
    c.taps = TAPS;
    c.step = 0.2f;
    c.leakagePerSecond = 0.0;
    c.peakGainLimit = 16.0f;
    N60FeedForwardShadow *s = N60FeedForwardShadowCreate(&c);
    if (!s) fail("create");
    const float half = 0.5f;
    if (!N60FeedForwardShadowSetPath(s, 0, 8, &half, 1)
        || !N60FeedForwardShadowSetPath(s, 1, 8, &half, 1)) fail("path");
    return s;
}

static void band(double fs) {
    const double tones[] = {15.0, 60.0, 300.0};
    const double amplitude = 0.1;
    float x[BUFFER] = {0}, e[BUFFER];
    for (int t = 0; t < 3; ++t) {
        N60FeedForwardShadow *s = make(fs);
        const uint64_t buffers = (uint64_t)(6.0 * fs / BUFFER);
        uint64_t n = 0;
        for (uint64_t b = 0; b < buffers; ++b) {
            for (uint32_t i = 0; i < BUFFER; ++i, ++n) {
                e[i] = (float)(amplitude * cos(2.0 * acos(-1.0) * fmod(tones[t] * n / fs, 1.0)));
            }
            N60FeedForwardShadowProcess(s, x, e, BUFFER);
        }
        const N60FeedForwardShadowStatus st = N60FeedForwardShadowReadStatus(s);
        printf("BAND %.0f %.0f %.6f\n", fs, tones[t],
               10.0 * log10(st.measuredPower / (0.5 * amplitude * amplitude)));
        N60FeedForwardShadowDestroy(s);
    }
}

static void fixed(double fs) {
    N60FeedForwardShadow *s = make(fs);
    const uint32_t length = 20u * N60AncDecimationFactor(fs) + 1;
    double *line = calloc(length, sizeof(double));
    if (!line) fail("memory");
    uint32_t position = 0;
    uint64_t rng = 11;
    float x[BUFFER], e[BUFFER];
    const uint64_t buffers = (uint64_t)(20.0 * fs / BUFFER);
    for (uint64_t b = 0; b < buffers; ++b) {
        for (uint32_t i = 0; i < BUFFER; ++i) {
            const double xn = 0.1 * gaussian(&rng);
            line[position] = xn;
            position = (position + 1) % length;
            x[i] = (float)xn;
            e[i] = (float)(0.5 * line[position]);
        }
        N60FeedForwardShadowProcess(s, x, e, BUFFER);
    }
    const double fd = N60FeedForwardShadowReadStatus(s).decimatedRate;
    for (uint32_t ch = 0; ch < 2; ++ch) {
        float w[TAPS];
        N60FeedForwardShadowCopyWeights(s, ch, w, TAPS);
        double complex r = 0;
        for (uint32_t k = 0; k < TAPS; ++k) r += w[k] * cexp(-I * 2.0 * acos(-1.0) * 60.0 * k / fd);
        printf("FIXED %.0f %u %.9f %.9f\n", fs, ch, creal(r), cimag(r));
    }
    free(line);
    N60FeedForwardShadowDestroy(s);
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        band(kRates[r]);
        fixed(kRates[r]);
    }
    return 0;
}
