/*
 * E4 S4 reference-lab probe: drives the production ANC guard with fixed
 * synthetic signals and prints what it did. e4_anc_guard_reference.py
 * predicts the same numbers from the written rules alone.
 *
 * GROWTH <rate> <onset> <tripFrame>   60 Hz tone, steady -50 dBFS for 200 ms,
 *                                     then +0.5 dB/ms; reference absent
 * RAMP <rate> <tripFrame> <k> <value> DC 0.1 anti-noise, error sine in band 6
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60AncGuard.h"

static const double kRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
};

static void growth(double rate) {
    const size_t onset = (size_t)(0.2 * rate);
    const size_t frames = (size_t)(0.4 * rate);
    float *anti = malloc(frames * sizeof(float));
    if (!anti) exit(2);
    const double tau = 2.0 * acos(-1.0);
    for (size_t i = 0; i < frames; ++i) {
        const double t = (double)i / rate;
        const double db = -50.0 + (i < onset ? 0.0 : 500.0 * (t - 0.2));
        anti[i] = (float)(pow(10.0, fmin(db, -10.0) / 20.0) * sin(tau * 60.0 * t));
    }
    N60AncGuardConfig config = N60AncGuardConfigDefault(rate);
    N60AncGuard *guard = N60AncGuardCreate(&config);
    if (!guard) exit(2);
    for (size_t i = 0; i < frames; i += 256) {
        const uint32_t n = (uint32_t)((frames - i) < 256 ? (frames - i) : 256);
        N60AncGuardProcess(guard, anti + i, NULL, NULL, n);
    }
    const N60AncGuardStatus st = N60AncGuardReadStatus(guard);
    printf("GROWTH %.0f %zu %llu %d\n", rate, onset,
           (unsigned long long)st.tripFrame, (int)st.trip);
    N60AncGuardDestroy(guard);
    free(anti);
}

static void ramp(double rate) {
    const size_t block = (size_t)lround(rate * N60_ANC_GUARD_BLOCK_SECONDS);
    const size_t frames = 5 * block;
    float *anti = malloc(frames * sizeof(float));
    float *err = malloc(frames * sizeof(float));
    if (!anti || !err) exit(2);
    const double tau = 2.0 * acos(-1.0);
    const double band = N60AncGuardBandCentreHz(6);
    for (size_t i = 0; i < frames; ++i) {
        anti[i] = 0.1f;
        err[i] = (float)(0.3 * sin(tau * band * (double)i / rate));
    }
    N60AncGuardConfig config = N60AncGuardConfigDefault(rate);
    config.hasErrorBaseline = true;
    for (uint32_t k = 0; k < N60_ANC_GUARD_BAND_COUNT; ++k) config.errorBaselineDB[k] = -40.0f;
    N60AncGuard *guard = N60AncGuardCreate(&config);
    if (!guard) exit(2);
    N60AncGuardProcess(guard, anti, NULL, err, (uint32_t)frames);
    const N60AncGuardStatus st = N60AncGuardReadStatus(guard);
    const size_t start = (size_t)st.tripFrame;
    const size_t samples[] = {0, 1, 2, 10, 100};
    for (size_t j = 0; j < sizeof samples / sizeof samples[0]; ++j) {
        printf("RAMP %.0f %zu %zu %.9g\n", rate, start, samples[j], anti[start + samples[j]]);
    }
    const size_t length = (size_t)lround(rate * 0.010);
    printf("RAMP %.0f %zu %zu %.9g\n", rate, start, length - 1, anti[start + length - 1]);
    printf("RAMP %.0f %zu %zu %.9g\n", rate, start, length, anti[start + length]);
    N60AncGuardDestroy(guard);
    free(anti);
    free(err);
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        growth(kRates[r]);
        ramp(kRates[r]);
    }
    return 0;
}
