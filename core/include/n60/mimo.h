/*
 * libn60core MIMO room treatment design interface (E19 S2, design notes 1-4 and 6).
 *
 * Offline design only: every function here may allocate, runs on a control or worker thread and must
 * never be called from an audio callback. Nothing here touches the realtime graph, so this header has
 * its own version and does not bump the graph ABI (n60/graph.h). Results are deterministic (fixed
 * summation order, no threads).
 *
 * The problem. N sources (physical speakers or subs) play N program feeds x_t. Treatment adds a delta:
 *     y_s = x_s z^-tau + sum over t of E_st * x_t        (C = E + I z^-tau is the full filter matrix)
 * so arming changes only the delta mix. E is designed at the low rate fs/D, with D = 16, 32, 64, 128 for
 * the 44.1/48, 88.2/96, 176.4/192 and 352.8/384 kHz families, and applied in a multirate stage (S4).
 *
 * The target. For feed t at seat m the target is the feed's own program plant P_tm shifted by tau and
 * multiplied after its direct arrival by exp(-6.91 t / T_target), so the target decays with the room's
 * modal tail pulled down towards T_target; its in-band level is matched to the untreated level at the
 * seat. The solver finds, per frequency, the E that moves the response through the injection plants Q
 * (equal to P unrouted; the in-band ways only when routed) onto the target (per-bin Tikhonov least
 * squares, Kirkeby and Nelson, "Digital filter design for inversion problems in sound reproduction",
 * J. Audio Eng. Soc. 47(7/8), 1999; decay cancellation after Celestinos and Nielsen, "Controlled
 * acoustic bass system (CABS)", J. Audio Eng. Soc. 56(11), 2008). The grid is in Hz (0.5 Hz spacing), so
 * designs depend on the rate only through the plants' sampling.
 *
 * Support and exclusion. Each source has a support range [low, high] Hz. Outside it the regularisation
 * weight rises 24 dB per octave and the row of E is tapered to 46 dB down at one octave outside (then
 * 24 dB per octave further); an excluded source's row and column of E are exactly zero (it plays its
 * own program only). Per-source effort is capped (excursion corner: 12 dB per octave below the corner).
 */
#ifndef N60_MIMO_H
#define N60_MIMO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MIMO_ABI_VERSION 2

#define N60_MIMO_OK 0
#define N60_MIMO_ERR_ARGUMENT (-1)
#define N60_MIMO_ERR_CAPACITY (-2)
#define N60_MIMO_ERR_ALLOC (-3)
#define N60_MIMO_ERR_RATE (-4)          /* rate outside 44.1 .. 384 kHz */
#define N60_MIMO_ERR_TAU (-5)           /* tau outside 0 .. 20 ms (D1) */
#define N60_MIMO_ERR_MISSING_PLANT (-6) /* info.bad_source / bad_seat name the missing measurement */
#define N60_MIMO_ERR_SUPPORT (-7)       /* support range invalid or no active source */
#define N60_MIMO_ERR_UNUSABLE (-8)      /* plants carry no energy in the support band */
#define N60_MIMO_ERR_HEADROOM (-9)      /* source bad_source cannot meet its gain limit */
#define N60_MIMO_ERR_THERMAL (-10)      /* source bad_source cannot meet the thermal budget */
#define N60_MIMO_ERR_CAUSALITY (-11)    /* too much of the solution lies before t = 0: raise tau */

/* Core designer limit; deliberately not N60_MIMO_MAX_SOURCES, which the app header defines as 32 (E1 S7, G3). */
#define N60_MIMO_CORE_MAX_SOURCES 8
#define N60_MIMO_MAX_SEATS 8
#define N60_MIMO_MAX_TAPS 4096u
#define N60_MIMO_MAX_TAU_SECONDS 0.020
#define N60_MIMO_GRID_STEP_HZ 0.5
#define N60_MIMO_DENSE_STEP_HZ 0.25 /* post-realisation check grid */

typedef struct n60_mimo_source {
    uint32_t excluded;            /* 1: plays its own program only; delta row and column exactly zero */
    double support_low_hz;        /* 10 .. support_high_hz */
    double support_high_hz;       /* up to 400 Hz */
    double excursion_corner_hz;   /* effort falls 12 dB/octave below it; 0: use support_low_hz */
    double effort_limit_db;       /* cap on the row effort sqrt(sum_t |E_st|^2) at and above the corner (dB re 1) */
    double gain_limit_db;         /* headroom budget: peak of sum_t |C_st| must stay at or under it (dB re 1) */
} n60_mimo_source;

typedef struct n60_mimo_seat {
    uint32_t included;
    double weight;                /* > 0; relative importance in the least squares */
} n60_mimo_seat;

typedef struct n60_mimo_problem {
    uint32_t struct_size;
    double sample_rate;           /* rate of the plants: 44.1 .. 384 kHz */
    uint32_t source_count;        /* 1 .. MAX_SOURCES */
    uint32_t seat_count;          /* 1 .. MAX_SEATS */
    uint32_t primary_seat;        /* must be included */
    double tau_seconds;           /* bass time target re the untreated arrival: 0 .. 20 ms */
    double decay_seconds;         /* T_target (T60): 0.05 .. 2 s */
    uint32_t taps;                /* low-rate FIR length, 64 .. MAX_TAPS */
    double regularisation;        /* relative to the mean in-band plant power; 1e-3 */
    double thermal_limit_db;      /* delta RMS re program RMS over the support range; -6 (D5) */
    double causality_limit_db;    /* energy before t = 0 re total; -12 (a causal projection pulls the solve towards t >= 0) */
    n60_mimo_source sources[N60_MIMO_CORE_MAX_SOURCES];
    n60_mimo_seat seats[N60_MIMO_MAX_SEATS];
    /* Raw per-output IRs at the plant rate (already through the known downstream chain), one per active
     * source and included seat. program_* is what the feed plays untreated; injection_* is the control path
     * (NULL: same as program). program_arrival_seconds < 0 detects the arrival as the largest sample. */
    const float *program_plant[N60_MIMO_CORE_MAX_SOURCES][N60_MIMO_MAX_SEATS];
    uint64_t program_count[N60_MIMO_CORE_MAX_SOURCES][N60_MIMO_MAX_SEATS];
    const float *injection_plant[N60_MIMO_CORE_MAX_SOURCES][N60_MIMO_MAX_SEATS];
    uint64_t injection_count[N60_MIMO_CORE_MAX_SOURCES][N60_MIMO_MAX_SEATS];
    double program_arrival_seconds[N60_MIMO_CORE_MAX_SOURCES][N60_MIMO_MAX_SEATS];
} n60_mimo_problem;

typedef struct n60_mimo_info {
    uint32_t decimation;          /* D */
    double low_rate_hz;           /* fs / D */
    uint32_t taps;
    double tau_seconds;
    double grid_low_hz;           /* solved band */
    double grid_high_hz;
    uint32_t grid_bins;
    double regularisation_used;
    uint32_t regularisation_steps; /* 0 .. 4 re-solves with 4x more regularisation */
    uint32_t capped_bins;         /* bins where the effort cap acted */
    double peak_gain_db[N60_MIMO_CORE_MAX_SOURCES];    /* max over frequency of sum_t |C_st| */
    double effort_peak_db[N60_MIMO_CORE_MAX_SOURCES];  /* max over frequency of sqrt(sum_t |E_st|^2); -400 for an excluded source */
    double thermal_db[N60_MIMO_CORE_MAX_SOURCES];      /* delta RMS re program RMS over the support range */
    double pre_energy_db;         /* energy before t = 0 re total, over all of E */
    int32_t bad_source;           /* source named by a MISSING_PLANT, HEADROOM or THERMAL error, else -1 */
    int32_t bad_seat;
} n60_mimo_info;

uint32_t n60_mimo_abi_version(void);

/* Fills deterministic defaults: tau 15 ms, T_target 0.3 s, 4096 taps, every seat included at weight 1, every
 * source active with support 25 .. 150 Hz, effort limit +9 dB, gain limit +9 dB. */
void n60_mimo_defaults(double sample_rate, uint32_t source_count, uint32_t seat_count, n60_mimo_problem *problem);

/* Setters for hosts that cannot index the fixed pointer tables (Swift). Bounds are checked; the plant pointers must
 * stay valid until n60_mimo_design returns. `injection` may be NULL (same as program); a negative arrival detects it. */
int32_t n60_mimo_problem_set_plant(n60_mimo_problem *problem, uint32_t source, uint32_t seat, const float *program,
                                   uint64_t program_count, const float *injection, uint64_t injection_count,
                                   double program_arrival_seconds);
int32_t n60_mimo_problem_set_source(n60_mimo_problem *problem, uint32_t source, const n60_mimo_source *value);
int32_t n60_mimo_problem_set_seat(n60_mimo_problem *problem, uint32_t seat, const n60_mimo_seat *value);

/* Decimation factor and low rate for a plant rate (D = 16, 32, 64, 128 by family). */
int32_t n60_mimo_low_rate(double sample_rate, uint32_t *decimation_out, double *low_rate_out);

/* Low-pass (Kaiser sinc, flat to 0.4 fs/D) and keep every D-th sample, no delay: out[j] = x[j D]. The output
 * has ceil(count / D) samples. */
int32_t n60_mimo_decimate(double sample_rate, const float *in, uint64_t count, float *out, uint64_t capacity,
                          uint64_t *count_out);

/* The inverse of n60_mimo_decimate: zero-stuff by D and low-pass with the same kernel (gain D), no delay, so
 * out[j D] = in[j] for a signal inside the pass band. The output has count * D samples. Used to bring a
 * low-rate filter or predicted IR back to the device rate. */
int32_t n60_mimo_interpolate(double sample_rate, const float *in, uint64_t count, float *out, uint64_t capacity,
                             uint64_t *count_out);

/* Complex response of a tap array at `hz` for a rate (DTFT, double). */
void n60_mimo_tap_response(const float *taps, uint32_t count, double sample_rate, double hz, double *re_out,
                           double *im_out);

/*
 * Designs E. `delta_out` holds source_count * source_count * taps floats at the low rate, E_st at
 * ((s * source_count + t) * taps), with t = 0 the plant time origin (E is the delta on top of the tau delay).
 * Errors name the source or seat in info (bad_source, bad_seat), which is filled on every return.
 */
int32_t n60_mimo_design(const n60_mimo_problem *problem, float *delta_out, uint64_t capacity, n60_mimo_info *info);

/*
 * Same as n60_mimo_design, and also writes the solved per-bin response E_st(f_k) before it is synthesised into
 * taps: `solved_out` holds source_count * source_count * grid_bins complex values as interleaved floats (re, im),
 * E_st bin k at ((s * source_count + t) * grid_bins + k) * 2, on the grid f_k = grid_low_hz + k * 0.5 Hz.
 * Needs source_count^2 * grid_bins * 2 floats (grid_bins is at most 1,700; there is no size query:
 * allocate source_count^2 * 1700 * 2 and pass that capacity).
 */
int32_t n60_mimo_design_solved(const n60_mimo_problem *problem, float *delta_out, uint64_t capacity, float *solved_out,
                               uint64_t solved_capacity, n60_mimo_info *info);

/* E19 S3 post-realisation check of the taps against the solved response (design note 3, the existing overshoot
 * limits). Dense (0.25 Hz) over the solved band. Deviation is judged inside each active source's support range
 * (its support range less a third of an octave at each end, where the design's own roll-off is steep): 20 log10(1 + |E_realised - E_solved| / sum_t |C_st|) with the row error taken
 * over all t, so 0.25 dB is a 2.9 percent row error. */
typedef struct n60_mimo_realisation {
    double max_deviation_db;                              /* worst in-band deviation over active sources */
    double max_deviation_hz;                              /* where it occurs */
    double edge_energy_fraction;                          /* worst filter: energy in the last eighth of the taps */
    double gain_peak_db[N60_MIMO_CORE_MAX_SOURCES];            /* dense max over frequency of sum_t |C_st| */
    double effort_peak_db[N60_MIMO_CORE_MAX_SOURCES];          /* dense max of sqrt(sum_t |E_st|^2) */
    double gain_overshoot_db[N60_MIMO_CORE_MAX_SOURCES];       /* gain peak re the source's gain limit; -400 if excluded */
    double effort_overshoot_db[N60_MIMO_CORE_MAX_SOURCES];     /* effort peak re the source's effort limit; -400 if excluded */
} n60_mimo_realisation;

int32_t n60_mimo_realise_check(const n60_mimo_problem *problem, const float *delta, uint64_t delta_count,
                               const float *solved, uint64_t solved_count, const n60_mimo_info *info,
                               n60_mimo_realisation *out);

#ifdef __cplusplus
}
#endif

#endif
