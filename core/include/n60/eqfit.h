/*
 * libn60core EQ "fit bands to a curve" maths (E33 S21, owns G40). Offline design maths: nothing here runs on an audio
 * callback. Allocation: scratch vectors on the calling (control or worker) thread. Realtime: not for an audio callback.
 * Latency: not applicable. Sample rate: any rate 8 kHz..768 kHz; bands stop at 0.45 fs. Channels: one curve per call.
 * Deterministic: fixed grid, fixed summation order, first-index tie breaks, no threads, no randomness; results use
 * the platform libm. No exceptions are thrown across the C boundary.
 *
 * Method (original; textbook ingredients only). The correction the bands must supply is e(f) = target(f) - measured(f)
 * on a 1/24-octave log grid between the requested range and 0.45 fs, lightly smoothed (5 points) and with its mean
 * removed (a level offset is the preamp's job, not a band's). Bands are chosen greedily, cut first: each round
 * proposes (a) a peaking band at the largest weighted error with Q read from the half-depth width of that error (three
 * Q values around the estimate), and (b) low and high shelves at half-octave corners; for each candidate the gain is
 * the weighted least-squares gain, clamped to [-max_cut, +max_boost]; the candidate that lowers the weighted squared
 * error most is kept and subtracted (exactly, through the RBJ cookbook biquad response, the same filters the EQ page
 * builds). Errors where a cut is needed weigh 1.0, where a boost is needed 0.5, so cuts win ties and narrow dips are
 * not chased. Boosting peaks are limited to Q <= 4. The loop stops at max_bands, when the best candidate gains under
 * 2 percent of the error, or when its gain is under 0.3 dB. Reference: R. Bristow-Johnson, "Audio EQ Cookbook"
 * (biquad forms); the greedy residual-subtraction loop is matching pursuit (Mallat and Zhang, 1993) on that dictionary.
 */
#ifndef N60_EQFIT_H
#define N60_EQFIT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_EQFIT_ABI_VERSION 1

#define N60_EQFIT_OK 0
#define N60_EQFIT_ERR_ARGUMENT (-1) /* null pointer, bad struct size, bad rate, count or limit */
#define N60_EQFIT_ERR_DATA (-2)     /* non-finite value, frequencies not rising, or too few points in the range */

#define N60_EQFIT_MAX_BANDS 32u
#define N60_EQFIT_MIN_POINTS 8u
#define N60_EQFIT_MAX_POINTS 65536u
#define N60_EQFIT_MAX_GAIN_DB 24.0
#define N60_EQFIT_GRID_STEPS_PER_OCTAVE 24u
#define N60_EQFIT_MAX_FRACTION 0.45 /* of the sample rate */

#define N60_EQFIT_BAND_PEAKING 0u    /* the same numbers as the graph's PEQ types */
#define N60_EQFIT_BAND_LOW_SHELF 1u
#define N60_EQFIT_BAND_HIGH_SHELF 2u

typedef struct n60_eqfit_band {
    uint32_t type;        /* N60_EQFIT_BAND_* */
    double frequency_hz;
    double gain_db;
    double q;
} n60_eqfit_band;

typedef struct n60_eqfit_problem {
    uint32_t struct_size;            /* sizeof(n60_eqfit_problem) */
    double sample_rate;              /* 8000..768000 */
    uint32_t point_count;            /* 8..65536 */
    const double *frequencies_hz;    /* point_count, strictly rising, > 0 */
    const double *measured_db;       /* point_count, the curve to correct (dB, any level) */
    const double *target_db;         /* point_count, the wanted curve at the same frequencies (dB) */
    double low_hz;                   /* fit range; clamped to the data and to 0.45 fs */
    double high_hz;
    uint32_t max_bands;              /* 1..32 */
    double max_boost_db;             /* 0..24: no band may boost more than this */
    double max_cut_db;               /* > 0..24 */
} n60_eqfit_problem;

typedef struct n60_eqfit_result {
    uint32_t struct_size;            /* sizeof(n60_eqfit_result); set by the caller */
    uint32_t band_count;             /* written */
    n60_eqfit_band *bands;           /* caller array with room for problem.max_bands; written in rising frequency */
    double *predicted_db;            /* optional, point_count: measured plus every band's response (all points) */
    double rms_before_db;            /* rms of (target - measured), mean removed, over the fit grid */
    double rms_after_db;             /* the same after the bands */
    double low_hz;                   /* the range actually fitted */
    double high_hz;
} n60_eqfit_result;

uint32_t n60_eqfit_abi_version(void);

/* Control or worker thread only. Zero bands is a valid answer (the curve already meets the target). */
int n60_eqfit_fit(const n60_eqfit_problem *problem, n60_eqfit_result *result);

#ifdef __cplusplus
}
#endif

#endif
