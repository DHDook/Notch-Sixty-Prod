/*
 * E4 S5: simulated speaker-ANC plant shared by ci/harness_e4_fxlms.c and the
 * reference-lab probe. Deterministic and seeded.
 *
 * Secondary path (speaker to error microphone), the same physical path at
 * every rate: gain g, a pure delay rounded to whole native frames, and a
 * one-pole low-pass (impulse-invariant, a = exp(-2 pi fc / fs), b = 1 - a):
 *     S(f) = g b exp(-j w d) / (1 - a exp(-j w)),  w = 2 pi f / fs.
 * Disturbance at the microphone: sum_k Re(D_k exp(j 2 pi f_k n / fs)) plus
 * white Gaussian noise.
 */
#ifndef E4_FXLMS_PLANT_H
#define E4_FXLMS_PLANT_H

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define PLANT_MAX_TONES 4
#define PLANT_MAX_DELAY_SECONDS 0.02

typedef struct {
    double fs, gain, a, b, z;
    uint32_t delay;
    float *line;
    uint32_t lineLength, position;
    int toneCount;
    double toneHz[PLANT_MAX_TONES], dRe[PLANT_MAX_TONES], dIm[PLANT_MAX_TONES];
    double pr[PLANT_MAX_TONES], pi[PLANT_MAX_TONES];
    double sr[PLANT_MAX_TONES], si[PLANT_MAX_TONES];
    double noiseRMS;
    uint64_t rng;
    uint64_t frame;
    double lastNoise;
} Plant;

static double plant_tau(void) { return 2.0 * acos(-1.0); }

static uint64_t plant_next(uint64_t *s) {
    *s ^= *s >> 12;
    *s ^= *s << 25;
    *s ^= *s >> 27;
    return *s * 2685821657736338717ull;
}

static double plant_uniform(uint64_t *s) {
    return ((double)(plant_next(s) >> 11) + 0.5) / 9007199254740992.0;
}

static double plant_gaussian(uint64_t *s) {
    const double u = plant_uniform(s), v = plant_uniform(s);
    return sqrt(-2.0 * log(u)) * cos(plant_tau() * v);
}

static void plant_set_delay(Plant *p, double seconds) {
    p->delay = (uint32_t)lround(seconds * p->fs);
}

static Plant plant_make(double fs, double delaySeconds, double cutoffHz, double gain,
                        double noiseRMS, uint64_t seed) {
    Plant p = {0};
    p.fs = fs;
    p.gain = gain;
    p.a = exp(-plant_tau() * cutoffHz / fs);
    p.b = 1.0 - p.a;
    p.lineLength = (uint32_t)ceil(PLANT_MAX_DELAY_SECONDS * fs) + 2;
    p.line = calloc(p.lineLength, sizeof(float));
    if (!p.line) {
        fprintf(stderr, "out of memory\n");
        exit(2);
    }
    p.noiseRMS = noiseRMS;
    p.rng = seed ? seed : 1;
    plant_set_delay(&p, delaySeconds);
    return p;
}

static void plant_add_tone(Plant *p, double hz, double amplitude, double phase) {
    const int k = p->toneCount++;
    p->toneHz[k] = hz;
    p->dRe[k] = amplitude * cos(phase);
    p->dIm[k] = amplitude * sin(phase);
    p->pr[k] = 1.0;
    p->pi[k] = 0.0;
    p->sr[k] = cos(plant_tau() * hz / p->fs);
    p->si[k] = sin(plant_tau() * hz / p->fs);
}

static void plant_free(Plant *p) { free(p->line); }

/* Secondary-path response at hz, plus extra whole frames of I/O delay. */
static void plant_response(const Plant *p, double hz, uint32_t extraFrames,
                           double *re, double *im) {
    const double w = plant_tau() * hz / p->fs;
    const double d = (double)(p->delay + extraFrames);
    const double nr = p->gain * p->b * cos(-w * d), ni = p->gain * p->b * sin(-w * d);
    const double dr = 1.0 - p->a * cos(w), di = p->a * sin(w);
    const double m = dr * dr + di * di;
    *re = (nr * dr + ni * di) / m;
    *im = (ni * dr - nr * di) / m;
}

/* One microphone sample while the speaker plays y. */
static double plant_step(Plant *p, double y) {
    p->line[p->position] = (float)y;
    const uint32_t read = (p->position + p->lineLength - p->delay) % p->lineLength;
    p->position = (p->position + 1) % p->lineLength;
    p->z = p->a * p->z + p->b * p->line[read];
    double mic = p->gain * p->z;
    for (int k = 0; k < p->toneCount; ++k) {
        mic += p->dRe[k] * p->pr[k] - p->dIm[k] * p->pi[k];
        const double nr = p->pr[k] * p->sr[k] - p->pi[k] * p->si[k];
        p->pi[k] = p->pr[k] * p->si[k] + p->pi[k] * p->sr[k];
        p->pr[k] = nr;
    }
    if ((++p->frame & 4095u) == 0) {
        for (int k = 0; k < p->toneCount; ++k) {
            const double ph = plant_tau() * fmod(p->toneHz[k] * (double)p->frame / p->fs, 1.0);
            p->pr[k] = cos(ph);
            p->pi[k] = sin(ph);
        }
    }
    p->lastNoise = p->noiseRMS > 0 ? p->noiseRMS * plant_gaussian(&p->rng) : 0.0;
    return mic + p->lastNoise;
}

#endif
