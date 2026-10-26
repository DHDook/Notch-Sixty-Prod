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
 * Extension (E10 S6, joint bass optimiser, section 5): the problem description already holds every
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

#define N60_CORRECT_ABI_VERSION 3

#define N60_CORRECT_OK 0
#define N60_CORRECT_ERR_ARGUMENT (-1)
#define N60_CORRECT_ERR_SIZE (-2)
#define N60_CORRECT_ERR_CAPACITY (-3)
#define N60_CORRECT_ERR_ALLOC (-4)
#define N60_CORRECT_ERR_NONFINITE (-5)
#define N60_CORRECT_ERR_PRERINGING (-6) /* the design is blocked: see the report for the band */
#define N60_CORRECT_ERR_TIMING (-7)     /* the problem has no inter-channel timing (E11 tier 3): blocked */

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

/*
 * Two-band synthesis (ABI v2, E10 S8): the same design as n60_correct_synthesize, realised for N60_STAGE_ROOM_FIR_TWO_BAND
 * so a long filter fits the 32768-tap stage limit at every rate. params->tap_count is the whole span in full-rate frames
 * (latency plus tail, up to N60_CORRECT_MAX_TAPS) and params->latency_seconds the budget L. D is the stage's decimation
 * (1, 2, 4, 8, 16, 32: fs / D is 11.025 or 12 kHz), chosen with n60_correct_two_band_decimation.
 * The low band (0 to 0.18 fs / D, raised-cosine hand-over from 0.10 fs / D) is carried by the low taps at fs / D, divided by
 * the resampler's own in-band response; the full-rate taps carry the rest, after a pure delay of extra_delay_frames
 * (= L - ramp). declared_latency_frames is L, exactly; the stage reports it as capacityFrames.
 * Writes full_tap_count taps (<= 32768) and low_tap_count taps (<= 32768). D == 1 is refused (use n60_correct_synthesize).
 */
typedef struct n60_correct_two_band_report {
    uint32_t decimation;
    uint32_t extra_delay_frames;       /* E */
    uint32_t full_tap_count;           /* N */
    uint32_t low_tap_count;            /* M */
    uint32_t declared_latency_frames;  /* L */
    double peak_gain_db;               /* of the combined response, for headroom */
} n60_correct_two_band_report;

/* The decimation that makes fs / D 11.025 or 12 kHz (1 below 16 kHz). */
uint32_t n60_correct_two_band_decimation(double sample_rate);

int32_t n60_correct_synthesize_two_band(const n60_correct_synth_params *params, const n60_correct_design_grid *grid,
                                        float *full_taps, uint64_t full_capacity, float *low_taps, uint64_t low_capacity,
                                        n60_correct_two_band_report *report);

/*
 * Linear-phase (zero-phase, delayed) synthesis of an amplitude given as a function (ABI v3, E8 S7): the crossover designer's
 * route to N60_STAGE_DRIVER_FIR. amplitude(hz, user) is the real, non-negative zero-phase gain; the result is that gain
 * delayed by exactly group_delay_frames L, windowed with a Blackman window over 2 L + 1 frames (the Speaker Optimizer's
 * linear-phase window). Unlike the grid designs it needs no 20 Hz to 20 kHz grid, so a high-pass or low-pass may fall
 * anywhere. Two windowed designs of complementary amplitudes (a * a + b * b = 1 pairs such as Linkwitz-Riley) still sum to
 * a delay of exactly L, because windowing is linear and the window is 1 at its centre.
 *
 * Single band (decimation 1) when 2 L + 1 <= 32768: full_tap_count = 2 L + 1, low_tap_count = 0, extra_delay_frames 0,
 * for N60_STAGE_DRIVER_FIR. Otherwise two-band for N60_STAGE_DRIVER_FIR_TWO_BAND with the decimation of
 * n60_correct_two_band_decimation: the full-rate taps cover the centre +-K (K = 10 ms, at most L) after a pure delay of
 * E = L - K frames and carry the response above the hand-over (0.10 to 0.18 of fs / D); the low taps carry the rest. The
 * report holds the stage parameters. Writes no more than the capacities. L is 1 .. 2^18 and the sample rate 8 to 768 kHz.
 */
typedef double (*n60_correct_amplitude_fn)(double hz, void *user);

int32_t n60_correct_synthesize_linear_phase(double sample_rate, uint32_t group_delay_frames, n60_correct_amplitude_fn amplitude,
                                            void *user, float *full_taps, uint64_t full_capacity, float *low_taps,
                                            uint64_t low_capacity, n60_correct_two_band_report *report);

/*
 * The magnitude (dB) and the delay-removed phase of the stage's combined response for given taps, evaluated analytically
 * (full path, low path through the resampler's in-band response). frequencies_hz in, magnitude_db and phase_rad out;
 * the phase has the declared latency L removed. Used to verify a published design against its prediction.
 */
int32_t n60_correct_two_band_response(double sample_rate, uint32_t decimation, uint32_t extra_delay_frames,
                                      uint32_t declared_latency_frames, const float *full_taps, uint32_t full_tap_count,
                                      const float *low_taps, uint32_t low_tap_count, const double *frequencies_hz,
                                      uint32_t count, double *magnitude_db, double *phase_rad);

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

/* ---- 5. Joint bass optimiser (E10 S6, design note 7) ----
 *
 * Offline, deterministic (fixed summation order, fixed starts, no threads or randomness, so bit-identical across
 * runs on one build). The problem is the same n60_correct_problem: every channel (mains and subwoofers) measured at
 * every seat in one time reference, so the inter-channel delay is in the data. The model of the system at seat k is
 *
 *     Y_k(f) = sum_n A_n(f) X_n(f) H_kn(f),   A_n(f) = C_n(f) 10^(g_n/20) (+1 or -1) e^(-j 2 pi f d_n)
 *
 * where C_n is the analytic BASS_MGMT crossover response (Linkwitz-Riley 4: high-pass for a main, low-pass for a sub,
 * for one mono bass signal of unit level; the bass-sum normalisation of the sub lane is applied by the caller that
 * publishes the gains), d_n the channel delay, g_n its gain, and X_n the channel's low-frequency correction on the
 * correction grid (unity outside the correction band). Two steps:
 *   (i)  delay, gain and polarity of every channel with a free degree of freedom: a grid search by coordinate descent
 *        from fixed starts, then Levenberg-Marquardt polish of the continuous delays and gains, on the log-magnitude
 *        spread of the seat responses across the fit band;
 *   (ii) per bin, the weighted regularised least squares  min sum_k w_k |sum_n B_kn X_n - T_k|^2 + lambda sum_n
 *        |X_n - 1|^2  (regularised towards unity, so a channel that cannot help keeps its response), with |X_n| capped
 *        at the boost limit (active set, fixed order). T_k is the target level (the shared target curve at the fitted
 *        mean level) with each seat's own phase, refined by reweighting the seats by 1/|Y_k|^2 so the error follows the
 *        log magnitude; a regularisation ladder is tried and a candidate is kept only if it beats unity. The solved
 *        filters are smoothed over +-3 bins (a sixteenth of an octave) so they fit a latency budget, then given a
 *        third-octave raised-cosine transition to unity at the edges of the correction band.
 * The result corrects magnitude and cancellation between channels, not an invented phase.
 * The output is static: filters (as correction-grid designs for n60_correct_synthesize), delays, gains and
 * polarities. It is not active decay cancellation.
 */
#define N60_CORRECT_MAX_BASS_CHANNELS 16u
#define N60_CORRECT_BASS_ROLE_MAIN 0u
#define N60_CORRECT_BASS_ROLE_SUB 1u
/* Timing tiers recorded by E11 (same values as N60_MEASURE_TIMING_*). Tier 3 blocks the design. */
#define N60_CORRECT_TIMING_LOOPBACK 1u
#define N60_CORRECT_TIMING_ACOUSTIC 2u
#define N60_CORRECT_TIMING_NONE 3u

typedef struct n60_correct_bass_channel {
    uint32_t role;           /* N60_CORRECT_BASS_ROLE_* */
    uint32_t free_delay;     /* 1: the optimiser may set the delay */
    uint32_t free_gain;      /* 1: it may set the gain */
    uint32_t free_polarity;  /* 1: it may invert the polarity */
    double min_gain_db;      /* gain range when free */
    double max_gain_db;
} n60_correct_bass_channel;

/* A sub: all three free, gain -12 .. +6 dB. A main: delay free; gain and polarity fixed at 0 dB and normal. */
void n60_correct_bass_channel_defaults(uint32_t role, n60_correct_bass_channel *channel);

typedef struct n60_correct_bass_params {
    uint32_t struct_size;
    uint32_t timing_tier;          /* N60_CORRECT_TIMING_*; NONE returns N60_CORRECT_ERR_TIMING */
    const n60_correct_bass_channel *channels; /* channel_count entries; required */
    double crossover_hz;           /* the BASS_MGMT crossover; 80 */
    double fit_low_hz;             /* 20 */
    double fit_high_hz;            /* the step (i) fit band and the report band end; 0: 1.5 * crossover_hz */
    double fir_high_hz;            /* the correction (filter) band end; 0: 2 * crossover_hz (crossover + 1 octave) */
    double max_delay_seconds;      /* 0.02 */
    double max_boost_db;           /* 6: cap on |X_n| */
    double regularisation;         /* lambda relative to the mean channel power; 0.01 */
    double ir_seconds;             /* use only this much of every IR (half-Hann fade over the last quarter); 0: all */
    const double *target_frequencies_hz; /* shared target (dB, log-frequency interpolation); NULL: flat */
    const double *target_gain_db;
    uint32_t target_points;
} n60_correct_bass_params;

void n60_correct_bass_defaults(const n60_correct_bass_channel *channels, n60_correct_bass_params *params);

typedef struct n60_correct_bass_channel_result {
    double delay_seconds;     /* the delay actually deployed: delay_frames / sample_rate; the earliest channel is 0 */
    uint32_t delay_frames;
    double gain_db;
    uint32_t polarity_invert; /* 0 normal, 1 inverted */
    double peak_boost_db;     /* largest boost of the low-frequency filter X_n (<= max_boost_db) */
    double peak_gain_db;      /* largest of the channel's gain plus the filter's boost, per grid point */
    double headroom_db;       /* max(0, peak_gain_db): attenuation needed so this channel cannot clip */
} n60_correct_bass_channel_result;

typedef struct n60_correct_bass_report {
    uint32_t channel_count;
    uint32_t seat_count;
    /* Seat-to-seat standard deviation of the level in dB, averaged over the grid points of the fit band: the
     * uncorrected system (no delay, gain 0 dB, normal polarity, X = 1), after step (i), and after step (ii). */
    double seat_std_before_db;
    double seat_std_aligned_db;
    double seat_std_after_db;
    /* RMS deviation of the seat levels from the target (mean level removed), same three stages. */
    double target_rms_before_db;
    double target_rms_after_db;
    double reference_level_db;     /* the fitted mean level the target is placed at */
    double headroom_db;            /* the largest channel headroom */
    uint32_t boost_limited_bins;   /* grid points where the boost cap was active on any channel */
    n60_correct_bass_channel_result channels[N60_CORRECT_MAX_BASS_CHANNELS];
} n60_correct_bass_report;

/*
 * Optimises the bass of every channel jointly. `grids` holds channel_count designs whose correction_db and
 * correction_phase_rad arrays (GRID_POINTS values) are written (the phase is the extra phase of
 * n60_correct_synthesize: the filter's phase less the minimum phase of its magnitude, unwrapped); the other
 * arrays may be NULL and are set to 0 (boost_limit_db: the cap). `before_db` / `after_db` are
 * optional (seat_count * GRID_POINTS values, seat-major, absolute level in dB) predicted seat responses of the
 * uncorrected and the optimised system. Errors: ERR_TIMING (tier NONE), ERR_ARGUMENT, ERR_NONFINITE, ERR_ALLOC.
 * main_seat is not used: seats are weighted only by their weights.
 */
int32_t n60_correct_bass_optimise(const n60_correct_problem *problem, const n60_correct_bass_params *params,
                                  n60_correct_design_grid *grids, n60_correct_bass_report *report,
                                  double *before_db, double *after_db);

#ifdef __cplusplus
}
#endif

#endif
