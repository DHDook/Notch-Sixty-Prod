/*
 * libn60core room-correction design interface (E10 S1). Offline design maths only: every
 * function here may allocate, runs on a control or worker thread, and must never be called
 * from an audio callback. Failures return a negative N60_CORRECT_ERR_* code; the library is built
 * without exceptions, so an allocation failure ends the process rather than unwinding into the
 * caller. Results are deterministic (fixed summation order, no threads, no randomness) and
 * bit-identical across runs on the same build; they use the platform libm, so compare across
 * platforms with tolerances, not bit for bit.
 *
 * The interface has four layers, from the bottom up:
 *   1. Minimum-phase synthesis of a magnitude curve (the port of the Swift designer).
 *   2. The correction grid: a fixed 1/48-octave log grid from 20 Hz that stores a design
 *      independent of sample rate (design note 6).
 *   3. Multi-seat design: frequency-dependent windowing, excess phase, coherence and the
 *      magnitude correction, producing a grid design (design notes 2 and 3).
 *   4. Rate-specific synthesis of that design into taps with a declared latency, and the
 *      pre-ringing audit of the predicted result (design note 4).
 *
 * Extension plan (E10 S7, joint bass optimiser): the problem description already holds every
 * channel and every seat (n60_correct_problem), so the joint optimiser is added as further
 * functions that take the same problem struct and return per-channel delay, gain, polarity
 * and a low-frequency grid design in the same n60_correct_design_grid form. Adding functions
 * does not change existing layouts. Every parameter struct starts with struct_size so a field
 * can be appended without breaking older callers; a caller sets it to sizeof(its struct).
 * New fields are only ever appended, and a smaller struct_size means "use the default".
 *
 * The version is separate from the graph ABI (n60/graph.h) and the measurement ABI
 * (n60/measure.h) so design changes never bump the realtime interface.
 */
#ifndef N60_CORRECT_H
#define N60_CORRECT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_CORRECT_ABI_VERSION 1

#define N60_CORRECT_OK 0
#define N60_CORRECT_ERR_ARGUMENT (-1)
#define N60_CORRECT_ERR_SIZE (-2)
#define N60_CORRECT_ERR_CAPACITY (-3)
#define N60_CORRECT_ERR_ALLOC (-4)
#define N60_CORRECT_ERR_NONFINITE (-5)
#define N60_CORRECT_ERR_PRERINGING (-6) /* the design is blocked: see the report for the band */

/* Longest FIR the designer returns; equal to the legacy convolver limit. */
#define N60_CORRECT_MAX_TAPS 262144u
/* Points on the correction grid: 20 Hz * 2^(i/48), i = 0 .. 478 (19.93 kHz). */
#define N60_CORRECT_GRID_POINTS 479u
#define N60_CORRECT_GRID_START_HZ 20.0
#define N60_CORRECT_GRID_PER_OCTAVE 48u
/* Third-octave audit bands from 20 Hz to 20 kHz. */
#define N60_CORRECT_MAX_BANDS 32u

#define N60_CORRECT_MODE_MIN_PHASE 0u   /* magnitude only; low latency / video mode */
#define N60_CORRECT_MODE_MIXED_PHASE 1u /* excess phase corrected where seats agree; music mode */

uint32_t n60_correct_abi_version(void);

/* ---- 1. Minimum-phase synthesis (parity with RoomCorrectionFIRDesigner) ---- */

typedef struct n60_correct_minphase_params {
    uint32_t struct_size;
    double sample_rate;
    uint32_t tap_count;           /* 1 .. N60_CORRECT_MAX_TAPS */
    double low_hz;                /* the curve applies strictly between low_hz and high_hz, 0 dB outside */
    double high_hz;
    double tail_taper_fraction;   /* half-Hann fade over the last fraction of the taps; 0.10 */
} n60_correct_minphase_params;

void n60_correct_minphase_defaults(double sample_rate, uint32_t tap_count, n60_correct_minphase_params *params);

/*
 * Real-cepstrum minimum-phase FIR for a desired correction given as (frequency, dB) points,
 * interpolated linearly in log frequency, with the curve taken as 0 dB outside the points and
 * outside (low_hz, high_hz). Same algorithm as the Swift designer, evaluated in double.
 */
int32_t n60_correct_minphase_synthesize(const n60_correct_minphase_params *params,
                                        const double *frequencies_hz, const double *gain_db, uint32_t points,
                                        float *taps, uint64_t capacity);

/* ---- 2. The correction grid ---- */

uint32_t n60_correct_grid_size(void);
/* Writes N60_CORRECT_GRID_POINTS frequencies. */
int32_t n60_correct_grid_frequencies(double *frequencies_hz, uint32_t capacity);

/* ---- 3. Multi-seat design ---- */

typedef struct n60_correct_seat_ir {
    const float *ir;           /* impulse response of one channel at one seat (E11 deconvolution output) */
    uint64_t frames;
    double arrival_frames;     /* direct arrival, the centre of the frequency-dependent window */
    double weight;             /* seat weight; 0 excludes the seat */
} n60_correct_seat_ir;

/* Every channel at every seat. The same sample rate for all. */
typedef struct n60_correct_problem {
    uint32_t struct_size;
    double sample_rate;
    uint32_t channel_count;
    uint32_t seat_count;
    uint32_t main_seat;               /* the seat the pre-ringing audit is evaluated at */
    const n60_correct_seat_ir *irs;   /* channel_count * seat_count entries, channel-major */
} n60_correct_problem;

typedef struct n60_correct_design_params {
    uint32_t struct_size;
    uint32_t mode;                    /* N60_CORRECT_MODE_* */
    double correction_low_hz;         /* 20 */
    double correction_high_hz;        /* 20000 */
    double smoothing_octaves;         /* power-domain smoothing of the measured magnitude; 1/6 */
    double max_boost_db;              /* 6 */
    double max_cut_db;                /* 12 */
    double fdw_cycles_low;            /* window width in cycles at and below fdw_knee_hz; 15 */
    double fdw_cycles_high;           /* cycles at 20 kHz; 5 */
    double fdw_knee_hz;               /* 200 */
    double spread_threshold_db;       /* seat-to-seat spread above which the boost limit is reduced; 6 */
    double phase_limit_hz;            /* excess phase is corrected only below this; 500 (100 .. 2000) */
    double coherence_low;             /* coherence below which no phase is corrected; 0.6 */
    double coherence_high;            /* coherence at which phase is fully corrected; 0.8 */
    const double *target_frequencies_hz; /* target curve (log-frequency interpolation); NULL: flat */
    const double *target_gain_db;
    uint32_t target_points;
} n60_correct_design_params;

void n60_correct_design_defaults(uint32_t mode, n60_correct_design_params *params);

/* A design on the correction grid: independent of sample rate. All arrays hold GRID_POINTS values. */
typedef struct n60_correct_design_grid {
    double *correction_db;            /* magnitude of the correction */
    double *correction_phase_rad;     /* extra (excess-phase) correction phase; 0 in minimum-phase mode */
    double *coherence;                /* R(f), the weighted seat phase coherence */
    double *measured_db;              /* smoothed weighted power-average response used for the design */
    double *seat_spread_db;           /* max - min seat level */
    double *boost_limit_db;           /* the boost limit actually applied */
} n60_correct_design_grid;

/* Frequency-dependent-window response of one seat (real and imaginary), the intermediate of the design. */
int32_t n60_correct_fdw_response(const n60_correct_problem *problem, uint32_t channel, uint32_t seat,
                                 const n60_correct_design_params *params, double *real, double *imag,
                                 uint32_t capacity);

/*
 * Excess phase of one seat on the grid in radians: the windowed phase less the minimum phase of
 * its magnitude, after the residual pure delay and constant phase are removed by a linear fit
 * from 100 Hz to 1 kHz.
 */
int32_t n60_correct_seat_excess_phase(const n60_correct_problem *problem, uint32_t channel, uint32_t seat,
                                      const n60_correct_design_params *params, double *phase_rad,
                                      uint32_t capacity);

int32_t n60_correct_design_channel(const n60_correct_problem *problem, uint32_t channel,
                                   const n60_correct_design_params *params, n60_correct_design_grid *grid);

/*
 * Default seat weights (design note 3): 1 for every seat, 2 for the main seat. Writes seat_count
 * values; main_seat >= seat_count gives all ones.
 */
int32_t n60_correct_default_seat_weights(uint32_t seat_count, uint32_t main_seat, double *weights, uint32_t capacity);

/*
 * Each seat's contribution to the multi-seat phase coherence of one channel, for the UI: the
 * weight-free mean of cos(angle between the seat's excess-phase phasor and the weighted mean
 * phasor), taken over the grid points below the phase limit where the coherence ramp g(R) is
 * above 0 and weighted by g(R). 1 means the seat agrees with the correction, 0 or below means it
 * disagrees. Writes seat_count values; a seat with zero weight, or a channel with no coherent
 * points, gives 0.
 */
int32_t n60_correct_seat_coherence_contribution(const n60_correct_problem *problem, uint32_t channel,
                                                const n60_correct_design_params *params, double *contribution,
                                                uint32_t capacity);

/* ---- Latency modes (design note 4) ---- */

#define N60_CORRECT_LATENCY_VIDEO 0u      /* minimum phase, low latency */
#define N60_CORRECT_LATENCY_MUSIC_20MS 1u /* mixed phase, budget 20 ms */
#define N60_CORRECT_LATENCY_MUSIC_50MS 2u /* mixed phase, budget 50 ms (default music mode) */
#define N60_CORRECT_LATENCY_MUSIC_100MS 3u
/* Upper bound on the latency video mode adds at any rate. */
#define N60_CORRECT_VIDEO_MAX_LATENCY_SECONDS 0.005

/*
 * Resolves a latency mode to the design mode (N60_CORRECT_MODE_*) and the budget L in seconds
 * (0 in video mode). Either output may be NULL. Unknown modes return ERR_ARGUMENT.
 */
int32_t n60_correct_latency_mode(uint32_t latency_mode, uint32_t *design_mode, double *budget_seconds);

/*
 * Tap count that holds the budget at a rate: the budget plus the response tail (120 ms in music
 * modes, 40 ms in video mode), rounded up to a multiple of 64 and capped at N60_CORRECT_MAX_TAPS.
 */
uint32_t n60_correct_latency_mode_tap_count(uint32_t latency_mode, double sample_rate);

/* ---- 4. Synthesis, declared latency and the pre-ringing audit ---- */

typedef struct n60_correct_synth_params {
    uint32_t struct_size;
    uint32_t mode;
    double sample_rate;
    uint32_t tap_count;             /* 1 .. N60_CORRECT_MAX_TAPS; must exceed the latency */
    double latency_seconds;         /* the budget L; rounded to whole frames; 0 in minimum-phase mode */
    double tail_taper_fraction;     /* 0.10 */
} n60_correct_synth_params;

void n60_correct_synth_defaults(uint32_t mode, double sample_rate, uint32_t tap_count, double latency_seconds,
                                n60_correct_synth_params *params);

typedef struct n60_correct_synth_report {
    uint32_t declared_latency_frames;  /* exactly round(latency_seconds * sample_rate) */
    double peak_gain_db;               /* largest positive gain of the taps, for headroom */
    uint32_t effective_latency_frames; /* mixed phase: the declared latency; minimum phase: the tap peak position */
} n60_correct_synth_report;

/* Synthesises a design into taps at any sample rate. Correction above the grid is unity. */
int32_t n60_correct_synthesize(const n60_correct_synth_params *params, const n60_correct_design_grid *grid,
                               float *taps, uint64_t capacity, n60_correct_synth_report *report);

typedef struct n60_correct_prering_band {
    double centre_hz;
    double level_db;                   /* worst pre-peak envelope relative to the band peak */
    double margin_db;                  /* worst level above the allowed level; > 0 fails */
    double window_seconds;             /* exempt interval before the peak: max(2 ms, 2 / f) */
    uint32_t failed;
} n60_correct_prering_band;

typedef struct n60_correct_prering_report {
    uint32_t band_count;
    uint32_t failed_count;
    int32_t first_failed_band;         /* index into bands, -1 when all pass */
    double limit_db;                   /* -30 */
    n60_correct_prering_band bands[N60_CORRECT_MAX_BANDS];
} n60_correct_prering_report;

/*
 * Predicted corrected response at one seat (the seat IR convolved with the taps), analysed per
 * third-octave band between low_hz and high_hz. A band fails when its envelope before
 * t_peak - max(2 ms, 2 / f) rises above 30 dB below the band peak (allowing for the analysis
 * filter's own spread). Returns OK with the report filled; the caller decides what to block.
 */
int32_t n60_correct_audit_prering(const n60_correct_seat_ir *seat, double sample_rate, const float *taps,
                                  uint32_t tap_count, double low_hz, double high_hz,
                                  n60_correct_prering_report *report);

typedef struct n60_correct_channel_report {
    n60_correct_synth_report synth;
    n60_correct_prering_report prering;
} n60_correct_channel_report;

/*
 * One call: design the channel on the grid, synthesise at the problem's rate, audit at the main
 * seat. Returns N60_CORRECT_ERR_PRERINGING (taps written but not to be deployed) when a band
 * fails; minimum-phase mode skips the audit.
 */
int32_t n60_correct_design_channel_taps(const n60_correct_problem *problem, uint32_t channel,
                                        const n60_correct_design_params *design,
                                        const n60_correct_synth_params *synth, float *taps, uint64_t capacity,
                                        n60_correct_channel_report *report);

#ifdef __cplusplus
}
#endif

#endif
