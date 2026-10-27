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
 * Allocation: none. Latency does not apply.
 *
 * Realtime use (ABI 2, E8 S2). n60_xover_design is offline: a Bessel prototype takes a root solve
 * that is far too long for an audio callback. The design splits in two so the graph stages can edit
 * a corner live: n60_xover_prototype_design (offline; family and order only) and n60_xover_realise
 * (a few tan and divide operations per section; no allocation, no loops of unbounded length, safe on
 * a realtime thread). n60_xover_design is exactly the two calls in sequence, so a stage that realises
 * a stored prototype produces the same coefficients bit for bit as the offline prediction.
 */
#ifndef N60_XOVER_H
#define N60_XOVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_XOVER_ABI_VERSION 4

#define N60_XOVER_OK 0
#define N60_XOVER_ERR_ARGUMENT (-1)
#define N60_XOVER_ERR_ORDER (-2)
#define N60_XOVER_ERR_CORNER (-3)
#define N60_XOVER_ERR_SYNTH (-4) /* the FIR synthesiser refused (size, capacity or non-finite) */

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

/* Analogue low-pass prototype of a family and order (-3.01 dB at 1 rad/s): second-order sections
 * s^2 + b s + c and first-order sections s + c. Linkwitz-Riley carries one Butterworth half-order
 * list used twice (copies == 2). Independent of corner and sample rate. */
typedef struct n60_xover_proto_section {
    uint32_t second; /* 1: s^2 + b s + c, 0: s + c (b unused) */
    double b, c;
} n60_xover_proto_section;

typedef struct n60_xover_prototype {
    uint32_t count;  /* sections in one copy, at most N60_XOVER_MAX_SECTIONS */
    uint32_t copies; /* 1, or 2 for Linkwitz-Riley */
    n60_xover_proto_section sections[N60_XOVER_MAX_SECTIONS];
} n60_xover_prototype;

uint32_t n60_xover_abi_version(void);

/* Offline. Returns N60_XOVER_OK, N60_XOVER_ERR_ORDER or N60_XOVER_ERR_ARGUMENT. */
int n60_xover_prototype_design(uint32_t family, uint32_t order, n60_xover_prototype *out);

/* Realtime-safe. Bilinear transform with the prewarp on corner_hz; high-pass is the s -> 1/s image. */
int n60_xover_realise(const n60_xover_prototype *proto, int highpass, double corner_hz, double fs, n60_xover_cascade *out);

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

/*
 * Linear-phase FIR realisation (ABI v3, E8 S7). The way's response is the magnitude of the IIR cascade(s) of its
 * high-pass and low-pass specs (either may be NULL, not both), zero phase, delayed by exactly group_delay_frames and
 * Blackman-windowed over twice that (see n60_correct_synthesize_linear_phase). Linkwitz-Riley pairs of any order sum to a
 * pure delay of exactly the group delay; asymmetric or Butterworth / Bessel pairs sum as their IIR magnitudes do.
 *
 * group_delay_frames 0 chooses it: five periods of the lowest corner, 32 .. 2^18 frames. The taps suit N60_STAGE_DRIVER_FIR
 * (report.two_band == 0, full taps only) or, when 2 * group delay + 1 exceeds 32768, N60_STAGE_DRIVER_FIR_TWO_BAND
 * (parameters [D, N, M, E] then the taps). Buffers hold up to 32768 floats each when two-band and 2 * L + 1 otherwise;
 * n60_xover_fir_plan returns the sizes so a caller can allocate first. Offline: allocates, never call from a callback.
 */
typedef struct n60_xover_fir_params {
    uint32_t struct_size;                /* sizeof(n60_xover_fir_params) */
    double sample_rate;
    const n60_xover_spec *highpass;      /* NULL: none */
    const n60_xover_spec *lowpass;       /* NULL: none */
    uint32_t group_delay_frames;         /* 0: automatic */
} n60_xover_fir_params;

typedef struct n60_xover_fir_report {
    uint32_t two_band;                   /* 1: use N60_STAGE_DRIVER_FIR_TWO_BAND */
    uint32_t decimation;                 /* D; 1 when single band */
    uint32_t extra_delay_frames;         /* E (two-band header word), 0 when single band */
    uint32_t full_tap_count;             /* N */
    uint32_t low_tap_count;              /* M, 0 when single band */
    uint32_t group_delay_frames;         /* L: the stage's capacityFrames */
    uint32_t latency_frames;             /* what the stage adds to the graph latency, L included */
} n60_xover_fir_report;

/* Sizes and latency for the params without synthesising. */
int n60_xover_fir_plan(const n60_xover_fir_params *params, n60_xover_fir_report *report);

int n60_xover_fir_synthesize(const n60_xover_fir_params *params, float *full_taps, uint64_t full_capacity, float *low_taps,
                             uint64_t low_capacity, n60_xover_fir_report *report);

/*
 * Near-field driver linearisation (ABI v4, E8 S8). Designs an inverse of a driver's measured magnitude within its way's
 * passband, for N60_STAGE_DRIVER_FIR. Offline: allocates, never call from a callback.
 *
 * Input: the near-field capture as (frequency Hz, dB) points, ascending, and optionally a gated far-field capture used above
 * merge_hz (level-matched to the near field over the octave-and-a-half below the merge, blended over a third of an octave).
 * Both are smoothed at smoothing_octaves (0: 1/6 octave) before use. The target is the mean smoothed level between the
 * way's corners (the high-pass corner, or the grid start when there is none; the low-pass corner, or the grid end). The
 * correction is target - measured on a 1/24-octave grid from 20 Hz to min(20 kHz, 0.45 fs), applied across band_octaves
 * (0: 1) beyond each corner with a third-octave fade at the outer edges, with these fixed limits (E8 owner decision 6):
 *   - the boost never exceeds max_boost_db (0: 6; values above 6 are refused);
 *   - the correction is never positive below the high-pass corner;
 *   - cuts are limited to -24 dB.
 * A resonant high-pass roll-off below the way's own corner is therefore left alone. The grid, the correction and the
 * predicted driver response (smoothed measurement + correction) are written to the arrays (capacity at least
 * N60_XOVER_LIN_MAX_POINTS). Deterministic.
 */
#define N60_XOVER_LIN_MAX_POINTS 512u

typedef struct n60_xover_lin_params {
    uint32_t struct_size;            /* sizeof(n60_xover_lin_params) */
    double sample_rate;
    const n60_xover_spec *highpass;  /* NULL: none (not both NULL) */
    const n60_xover_spec *lowpass;   /* NULL: none */
    uint32_t linear_phase;           /* 1: linear-phase (the way is FIR); 0: minimum phase */
    double merge_hz;                 /* 0: near field only */
    double max_boost_db;             /* 0: 6; at most 6 */
    double smoothing_octaves;        /* 0: 1/6 */
    double band_octaves;             /* 0: 1 */
} n60_xover_lin_params;

typedef struct n60_xover_lin_report {
    uint32_t point_count;
    double passband_low_hz, passband_high_hz; /* the way's corners (or grid ends) */
    double reference_db;                      /* the target level of the smoothed measurement */
    double ripple_before_db, ripple_after_db; /* peak-to-peak of the smoothed driver between the corners */
    double max_boost_db, max_cut_db;          /* extremes of the correction (cut as a negative number) */
    uint32_t boost_capped;                    /* 1 when the +6 dB (or requested) cap, or the high-pass rule, limited a point */
} n60_xover_lin_report;

int n60_xover_linearise_design(const n60_xover_lin_params *params, const double *near_hz, const double *near_db,
                               uint32_t near_count, const double *far_hz, const double *far_db, uint32_t far_count,
                               double *grid_hz, double *correction_db, double *predicted_db, uint32_t capacity,
                               n60_xover_lin_report *report);

/*
 * The DRIVER_FIR content for a designed correction, merged with the way's crossover: linear-phase puts the way's
 * high-pass and low-pass magnitudes and the correction into one zero-phase design (as n60_xover_fir_synthesize, so the
 * IIR crossover is dropped from the way); minimum phase gives the correction alone (the crossover stays IIR), with
 * group_delay_frames the tap peak position. group_delay_frames_in 0 chooses it (linear phase: five periods of half the
 * lowest corner). Buffers and the report are as n60_xover_fir_synthesize (n60_xover_fir_plan sizes the linear-phase
 * case; a minimum-phase design is at most 32768 taps in full_taps and never uses low_taps).
 */
int n60_xover_linearise_synthesize(const n60_xover_lin_params *params, const double *grid_hz, const double *correction_db,
                                   uint32_t point_count, uint32_t group_delay_frames_in, float *full_taps,
                                   uint64_t full_capacity, float *low_taps, uint64_t low_capacity,
                                   n60_xover_fir_report *report);

/* Magnitude in dB of designed DRIVER_FIR content (either kind) at the frequencies, the declared delay removed. */
int n60_xover_fir_magnitude_db(double sample_rate, const n60_xover_fir_report *report, const float *full_taps,
                               const float *low_taps, const double *frequencies_hz, uint32_t count, double *magnitude_db);

#ifdef __cplusplus
}
#endif

#endif
