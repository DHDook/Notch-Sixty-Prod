/*
 * libn60core crossover filter library (E8 S1). Offline design maths only: nothing here runs on
 * an audio callback. Every function is deterministic (fixed iteration counts, fixed summation
 * order, no threads, no randomness, no allocation) and bit-identical across runs on the same
 * build; results use the platform libm, so compare across platforms with tolerances.
 *
 * A filter is a FilterSpec: family (Butterworth, Bessel, Linkwitz-Riley), order and corner. The
 * design returns a cascade of biquads (double precision) by the bilinear transform with the
 * prewarp placed on the corner, so the corner lands exactly where requested at every sample
 * rate. High-pass and low-pass are independent, so slopes may be asymmetric. The response
 * functions evaluate the same coefficients the graph stages will run, so prediction equals render.
 *
 * Corner conventions: Butterworth and Bessel are -3.01 dB at the corner (Bessel is normalised
 * for that, not for flat group delay at DC); Linkwitz-Riley is -6.02 dB. A Linkwitz-Riley pair
 * sums to unity magnitude; orders 2 and 6 need the high-pass inverted (see
 * n60_xover_lr_inverts_hp) for the sum to be an allpass.
 *
 * Sample-rate assumption: any rate; corners up to 0.49 * fs. Channel count: not applicable.
 * Allocation: none. Not for audio callbacks (offline design only); latency does not apply.
 */
#ifndef N60_XOVER_H
#define N60_XOVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_XOVER_ABI_VERSION 1

#define N60_XOVER_OK 0
#define N60_XOVER_ERR_ARGUMENT (-1)
#define N60_XOVER_ERR_ORDER (-2)
#define N60_XOVER_ERR_CORNER (-3)

#define N60_XOVER_FAMILY_BUTTERWORTH 0u
#define N60_XOVER_FAMILY_BESSEL 1u
#define N60_XOVER_FAMILY_LINKWITZ_RILEY 2u

/* Butterworth and Bessel orders 1..8; Linkwitz-Riley orders 2, 4, 6, 8 (6 to 48 dB/oct). */
#define N60_XOVER_MAX_ORDER 8u
/* Longest cascade a spec designs into (order 8 = four biquads; LR8 = two BW4 = four). */
#define N60_XOVER_MAX_SECTIONS 4u

typedef struct n60_xover_spec {
    uint32_t struct_size; /* sizeof(n60_xover_spec) */
    uint32_t family;      /* N60_XOVER_FAMILY_* */
    uint32_t order;
    double corner_hz;
} n60_xover_spec;

/* y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2 (a0 normalised to 1). First-order sections have b2 = a2 = 0. */
typedef struct n60_xover_biquad {
    double b0, b1, b2, a1, a2;
} n60_xover_biquad;

typedef struct n60_xover_cascade {
    uint32_t count;
    n60_xover_biquad sections[N60_XOVER_MAX_SECTIONS];
} n60_xover_cascade;

uint32_t n60_xover_abi_version(void);

/* Designs a low-pass (highpass == 0) or high-pass cascade at sample rate fs. */
int n60_xover_design(const n60_xover_spec *spec, int highpass, double fs, n60_xover_cascade *out);

/* Linkwitz transform: moves a closed-box response (f0, q0) to (fp, qp). One biquad; H(s) = (s^2 + w0/q0 s + w0^2) / (s^2 + wp/qp s + wp^2). */
int n60_xover_linkwitz(double f0_hz, double q0, double fp_hz, double qp, double fs, n60_xover_cascade *out);

/* Complex response of a cascade at hz. */
int n60_xover_response(const n60_xover_cascade *cascade, double fs, double hz, double *re, double *im);

/* Magnitude in dB of a cascade at hz. */
int n60_xover_magnitude_db(const n60_xover_cascade *cascade, double fs, double hz, double *db);

/* 1 when a Linkwitz-Riley pair of this order needs the high-pass inverted to sum flat (orders 2, 6). */
int n60_xover_lr_inverts_hp(uint32_t order);

/*
 * Summed response of a low-pass and a high-pass spec (the high-pass negated when invert_hp), as a
 * peak-to-peak ripple in dB over a 1/48-octave grid from 20 Hz to min(20 kHz, 0.45 fs). Zero (to
 * rounding) for a matched Linkwitz-Riley pair; the asymmetric result is the number the UI shows.
 */
int n60_xover_sum_ripple_db(const n60_xover_spec *lp, const n60_xover_spec *hp, int invert_hp, double fs,
                            double *ripple_db);

/* Largest pole radius in the cascade (stable when below 1). */
double n60_xover_max_pole_radius(const n60_xover_cascade *cascade);

#ifdef __cplusplus
}
#endif

#endif
