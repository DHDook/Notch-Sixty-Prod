/*
 * E4 S18a reference-lab probe: drives the production remote tonal worker core
 * (N60RemoteTonal in N60RemoteTonal.h) on a static one-tone plant and prints
 * the weight it converges to. e4_remote_tonal_reference.py predicts the same
 * numbers from the written rule.
 *
 * FIXED <rate> <leak> <re> <im>   weight after 60 s of 250 ms microphone blocks
 *                                 (tau 0.5 s, no dither, no slew, path = truth,
 *                                 D = 0.01 exp(j 0.7), S = 0.8 exp(-j 0.4),
 *                                 tone 60 Hz, left share 1)
 */
#include <complex.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60RemoteTonal.h"

static const double kRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
};
static const double kTicks = 1e9;
static const uint64_t kBase = 1000000000000ull;
#define HZ 60.0

static void run(double rate, double leak) {
    const double complex D = 0.01 * cexp(I * 0.7);
    const double complex S = 0.8 * cexp(-I * 0.4);
    N60RemoteTonalConfig cfg = N60RemoteTonalConfigDefault(rate, kTicks);
    cfg.toneCount = 1;
    cfg.toneHz[0] = (float)HZ;
    cfg.leftShare[0] = (N60AncComplex){1.0f, 0.0f};
    cfg.rightShare[0] = (N60AncComplex){0.0f, 0.0f};
    cfg.pathSeed[0] = (N60AncComplex){(float)creal(S), (float)cimag(S)};
    cfg.weightSeed[0] = (N60AncComplex){0.0f, 0.0f};
    cfg.convergenceSeconds = 0.5;
    cfg.leakagePerSecond = leak;
    cfg.ditherDB = 0.0f;
    cfg.ditherDegrees = 0.0f;
    cfg.slewDB = 0.0f;
    cfg.slewDegrees = 0.0f;
    cfg.toneCapDBFS = 0.0f;
    cfg.aggregateCapDBFS = 0.0f;
    N60RemoteTonal *core = N60RemoteTonalCreate(&cfg);
    if (core == NULL) { fprintf(stderr, "probe: create failed\n"); exit(2); }

    const uint64_t block = (uint64_t)(0.25 * rate);
    const uint64_t tele = (uint64_t)(0.005 * rate);
    float *samples = malloc(block * sizeof(float));
    double complex gain = 0.0;
    uint64_t frame = 0;
    for (int b = 0; b < 240; ++b) {
        const uint64_t first = frame;
        for (uint64_t i = 0; i < block; ++i, ++frame) {
            if (frame % tele == 0) {
                N60ActiveQuietZoneTelemetryRecord r;
                memset(&r, 0, sizeof r);
                r.hostTime = kBase + (uint64_t)((double)frame / rate * kTicks);
                r.renderedFrame = frame;
                r.toneCount = 1;
                const double ph = 2.0 * M_PI * fmod((double)frame * HZ, rate) / rate;
                r.frequencyHz[0] = HZ;
                r.phasorCosine[0] = cos(ph);
                r.phasorSine[0] = sin(ph);
                r.gain[0][0] = (float)creal(gain);
                r.gain[0][1] = (float)cimag(gain);
                N60RemoteTonalPushTelemetry(core, &r);
            }
            const double ph = 2.0 * M_PI * fmod((double)frame * HZ, rate) / rate;
            samples[i] = (float)creal((D + S * gain) * cexp(I * ph));
        }
        N60RemoteTonalProcessMic(core, samples, (uint32_t)block,
                                 kBase + (uint64_t)((double)first / rate * kTicks));
        N60ActiveQuietZoneGainRecord rec;
        if (N60RemoteTonalNextRecord(core, 1, 0.0f, &rec)) {
            gain = (double)rec.gain[0][0] + I * (double)rec.gain[0][1];
        }
    }
    const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(core);
    printf("FIXED %.0f %.6f %.9f %.9f\n", rate, leak, (double)st.weight[0].re, (double)st.weight[0].im);
    free(samples);
    N60RemoteTonalDestroy(core);
}

int main(void) {
    for (size_t i = 0; i < sizeof kRates / sizeof kRates[0]; ++i) {
        run(kRates[i], 0.0);
        run(kRates[i], 0.05);
    }
    return 0;
}
