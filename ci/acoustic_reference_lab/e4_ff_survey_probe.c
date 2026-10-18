/*
 * E4 S9b1 reference-lab probe: drives the production feed-forward survey
 * (N60FeedForwardSurvey in N60Fxlms.h) with the shared simulated plant
 * (ci/e4_fxlms_plant.h) between the two microphones and prints what it
 * measured. e4_ff_survey_reference.py predicts the same numbers from the
 * written rules and the plant formula.
 *
 * H <rate> <hz> <re> <im>          noiseless transfer per band
 * G <rate> <hz> <g2>               coherence per band with microphone noise
 * SEG <rate> <segments>            segments in the noisy run
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60Fxlms.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#include "e4_fxlms_plant.h"
#pragma clang diagnostic pop

#define BUFFER 512u
#define BANDS 16u
#define NOISE 0.02
static const double kRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
};

static void fail(const char *what) {
    fprintf(stderr, "probe: %s\n", what);
    exit(2);
}

static void run(double fs, double noise, double seconds, int coherence) {
    N60FeedForwardSurveyConfig c = N60FeedForwardSurveyConfigDefault(fs);
    c.bandCount = BANDS;
    for (uint32_t k = 0; k < BANDS; ++k) c.bandHz[k] = (float)(25.0 * pow(2.0, k / 6.0));
    N60FeedForwardSurvey *s = N60FeedForwardSurveyCreate(&c);
    if (!s) fail("create");
    /* Gain 0.5, 1 ms, 800 Hz one-pole, as the S5 reference lab. */
    Plant p = plant_make(fs, 0.001, 800.0, 0.5, noise, 31);
    uint64_t rng = 17;
    float x[BUFFER], e[BUFFER];
    const uint64_t buffers = (uint64_t)(seconds * fs / BUFFER);
    for (uint64_t b = 0; b < buffers; ++b) {
        for (uint32_t i = 0; i < BUFFER; ++i) {
            const double xn = 0.1 * plant_gaussian(&rng);
            x[i] = (float)xn;
            e[i] = (float)plant_step(&p, xn);
        }
        N60FeedForwardSurveyProcess(s, x, e, BUFFER);
    }
    const N60FeedForwardSurveyResult r = N60FeedForwardSurveyRead(s);
    for (uint32_t k = 0; k < BANDS; ++k) {
        if (coherence) {
            printf("G %.0f %.6f %.6f\n", fs, c.bandHz[k], r.coherence[k]);
        } else {
            printf("H %.0f %.6f %.9f %.9f\n", fs, c.bandHz[k], r.transfer[k].re, r.transfer[k].im);
        }
    }
    if (coherence) printf("SEG %.0f %llu\n", fs, (unsigned long long)r.segments);
    plant_free(&p);
    N60FeedForwardSurveyDestroy(s);
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        run(kRates[r], 0.0, 20.0, 0);
        run(kRates[r], NOISE, 60.0, 1);
    }
    return 0;
}
