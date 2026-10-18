/*
 * E4 S5 reference-lab probe: drives the production adaptive ANC core with the
 * shared simulated plant (ci/e4_fxlms_plant.h) and prints what it did.
 * e4_fxlms_reference.py predicts the same numbers from the written rules.
 *
 * DEC <rate> <hz> <re> <im>        decimated cosine, demodulated at (n - G)
 * FIXED <rate> <k> <re> <im>       converged weight, path seed 0.8x at +30 deg
 * PATH <rate> <re> <im>            path estimate at 60 Hz after 3 s of probe
 * PROBE <rate> <rms>               probe RMS over 2 s
 */
#include <complex.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60Fxlms.h"
#include "e4_fxlms_plant.h"

#define BUFFER 256u
static const double kRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
};

static void fail(const char *what) {
    fprintf(stderr, "probe: %s\n", what);
    exit(2);
}

/* Feeds cos and sin separately and combines them, so the projection sees only
 * the positive-frequency response (no leakage from the image at -f). */
static void decimator(double fs) {
    const double tones[] = {150.0, 500.0};
    const uint32_t d = N60AncDecimationFactor(fs), g = N60AncDecimatorDelayFrames(fs);
    const uint32_t frames = (uint32_t)fs;
    float *in = malloc(frames * sizeof(float));
    float *re = malloc((frames / d) * sizeof(float)), *im = malloc((frames / d) * sizeof(float));
    if (!in || !re || !im) fail("memory");
    for (int t = 0; t < 2; ++t) {
        uint32_t m = 0;
        for (int q = 0; q < 2; ++q) {
            N60AncDecimator *dec = N60AncDecimatorCreate(fs);
            if (!dec) fail("decimator");
            for (uint32_t n = 0; n < frames; ++n) {
                const double ph = plant_tau() * tones[t] * n / fs;
                in[n] = (float)(q == 0 ? cos(ph) : sin(ph));
            }
            m = N60AncDecimatorProcess(dec, in, frames, q == 0 ? re : im, frames / d);
            N60AncDecimatorDestroy(dec);
        }
        double complex acc = 0;
        uint32_t used = 0;
        for (uint32_t i = m / 2; i < m; ++i, ++used) {
            const double n = (double)((i + 1) * d - 1) - g;
            acc += (re[i] + I * im[i]) * cexp(-I * plant_tau() * tones[t] * n / fs);
        }
        acc /= used;
        printf("DEC %.0f %.0f %.9f %.9f\n", fs, tones[t], creal(acc), cimag(acc));
    }
    free(in);
    free(re);
    free(im);
}

/* Runs the closed loop for the given time; the mic hears each buffer one
 * buffer later. */
static void loop(N60AdaptiveTonal *core, Plant *p, double seconds) {
    float played[BUFFER] = {0}, out[BUFFER], err[BUFFER];
    const uint64_t buffers = (uint64_t)ceil(seconds * p->fs / BUFFER);
    for (uint64_t b = 0; b < buffers; ++b) {
        for (uint32_t n = 0; n < BUFFER; ++n) err[n] = (float)plant_step(p, played[n]);
        N60AdaptiveTonalProcess(core, err, out, BUFFER);
        N60AdaptiveTonalService(core);
        for (uint32_t n = 0; n < BUFFER; ++n) played[n] = out[n];
    }
}

static void fixed_point(double fs) {
    Plant p = plant_make(fs, 0.001, 800.0, 0.5, 0.0, 1);
    plant_add_tone(&p, 60.0, 0.02, 0.7);
    plant_add_tone(&p, 120.0, 0.015, -1.9);
    N60AdaptiveTonalConfig c = N60AdaptiveTonalConfigDefault(fs);
    c.toneCount = 2;
    c.toneHz[0] = 60.0f;
    c.toneHz[1] = 120.0f;
    c.leakagePerSecond = 0.5;  /* large enough to move the fixed point visibly */
    for (int k = 0; k < 2; ++k) {
        double re, im;
        plant_response(&p, c.toneHz[k], BUFFER, &re, &im);
        const double complex seed = (re + I * im) * 0.8 * cexp(I * acos(-1.0) / 6.0);
        c.toneSeed[k].re = (float)creal(seed);
        c.toneSeed[k].im = (float)cimag(seed);
    }
    N60AdaptiveTonal *core = N60AdaptiveTonalCreate(&c);
    if (!core) fail("core");
    loop(core, &p, 4.0);
    const N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(core);
    for (int k = 0; k < 2; ++k) {
        printf("FIXED %.0f %d %.9g %.9g\n", fs, k, st.weight[k].re, st.weight[k].im);
    }
    N60AdaptiveTonalDestroy(core);
    plant_free(&p);
}

static void path(double fs) {
    Plant p = plant_make(fs, 0.001, 800.0, 0.5, 3e-4, 23);
    plant_add_tone(&p, 60.0, 0.02, 0.3);
    N60AdaptiveTonalConfig c = N60AdaptiveTonalConfigDefault(fs);
    c.toneCount = 1;
    c.toneHz[0] = 60.0f;
    c.probeEnabled = true;
    N60AdaptiveTonal *core = N60AdaptiveTonalCreate(&c);
    if (!core) fail("core");
    loop(core, &p, 3.0);
    const N60AdaptiveTonalStatus st = N60AdaptiveTonalReadStatus(core);
    printf("PATH %.0f %.9g %.9g\n", fs, st.path[0].re, st.path[0].im);
    N60AdaptiveTonalDestroy(core);
    plant_free(&p);
}

static void probe_level(double fs) {
    N60AdaptiveTonalConfig c = N60AdaptiveTonalConfigDefault(fs);
    c.probeEnabled = true;
    N60AdaptiveTonal *core = N60AdaptiveTonalCreate(&c);
    if (!core) fail("core");
    float err[BUFFER] = {0}, out[BUFFER];
    const uint64_t buffers = (uint64_t)(2.0 * fs / BUFFER);
    double sum = 0;
    for (uint64_t b = 0; b < buffers; ++b) {
        N60AdaptiveTonalProcess(core, err, out, BUFFER);
        N60AdaptiveTonalService(core);
        for (uint32_t n = 0; n < BUFFER; ++n) sum += (double)out[n] * out[n];
    }
    printf("PROBE %.0f %.9g\n", fs, sqrt(sum / (double)(buffers * BUFFER)));
    N60AdaptiveTonalDestroy(core);
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        decimator(kRates[r]);
        fixed_point(kRates[r]);
        path(kRates[r]);
        probe_level(kRates[r]);
    }
    return 0;
}
