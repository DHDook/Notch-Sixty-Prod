/*
 * Speaker optimiser maths (E21 S9a and S9b, domain version N60_SPEAKER_ABI_VERSION; v2 adds sections 4 to 7). Numbers-to-numbers only: the bounded speaker
 * correction PEQ designer of the multichannel calibration (the legacy N60SpeakerCorrectionDesigner.h), the response
 * interpolation onto the calibration grid, the Speaker Optimizer's PEQ and FIR candidate searches, the mains/sub crossover
 * feasibility search, the cross-domain deviation classifier, the early-window magnitude and the design-engine preview scoring. Evidence selection,
 * seat means, mask building, preview and value types stay in Swift.
 *
 * Offline only: control or worker thread, allocates (never throws across this boundary), deterministic (fixed order, no
 * threads). Never called from an audio callback. No Apple framework.
 */
#ifndef N60_SPEAKER_H
#define N60_SPEAKER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_SPEAKER_ABI_VERSION 2u

#define N60_SPEAKER_OK 0
#define N60_SPEAKER_ERR_ARGUMENT (-1)
#define N60_SPEAKER_ERR_SIZE (-2)
#define N60_SPEAKER_ERR_NONFINITE (-3)
#define N60_SPEAKER_ERR_ALLOC (-4)
#define N60_SPEAKER_ERR_TOO_LONG (-5)   /* FIR longer than the single-band cap */
#define N60_SPEAKER_ERR_GRID (-6)       /* FIR: a grid frequency lies outside the transform */
#define N60_SPEAKER_ERR_PEAK (-7)       /* PEQ: the final peak-gain audit is non-finite or over the headroom limit */

#define N60_SPEAKER_ERR_SETTINGS (-8)   /* options or settings outside their limits */
#define N60_SPEAKER_ERR_ARRIVAL (-9)    /* early window: direct arrival outside the impulse */
#define N60_SPEAKER_ERR_SHORT (-10)     /* early window: too little impulse after the arrival */
#define N60_SPEAKER_ERR_BAND (-11)      /* early window: no reliable frequency band */

#define N60_SPEAKER_MAX_BANDS 8u

uint32_t n60_speaker_abi_version(void);

/* ---- 1. Response interpolation onto the grid (the calibration designer's `interpolate` and `targetGainDB`) ---- */

/* Linear interpolation in log frequency of values over frequency_hz (ascending, count >= 2), held flat beyond both ends.
 * N60_SPEAKER_ERR_ARGUMENT for a null pointer, count < 2, or a non-finite or non-positive frequency. */
int32_t n60_speaker_interpolate_log(const double *frequency_hz, const double *values, uint32_t count, double at_hz,
                                    double *out);

/* The target curve's gain at at_hz: 0 for fewer than 2 points, otherwise as n60_speaker_interpolate_log. */
double n60_speaker_target_gain_db(const double *frequency_hz, const double *gain_db, uint32_t count, double at_hz);

/* ---- 2. Speaker correction PEQ designer (multichannel calibration) ---- */

typedef struct n60_speaker_correction_settings {
    uint32_t maximum_band_count;        /* 1 .. N60_SPEAKER_MAX_BANDS */
    float maximum_boost_db;
    float maximum_cut_db;
    float minimum_correction_hz;
    float maximum_correction_hz;
    float minimum_useful_error_db;
    float correction_damping;
    float default_q;
    float minimum_band_spacing_octaves;
} n60_speaker_correction_settings;

/* The legacy defaults: 6 bands, +3 / -10 dB, 20 Hz .. 20 kHz, 0.75 dB useful error, damping 0.72, Q 1.15, spacing 0.28. */
void n60_speaker_correction_defaults(n60_speaker_correction_settings *settings);

/* 1 when the settings are inside the legacy limits for this rate, else 0. */
int32_t n60_speaker_correction_settings_valid(const n60_speaker_correction_settings *settings, double sample_rate);

typedef struct n60_speaker_band {
    double frequency_hz;
    double gain_db;
    double q;
    float b0, b1, b2, a1, a2;           /* normalised peaking biquad, single precision like the legacy designer */
} n60_speaker_band;

typedef struct n60_speaker_correction_problem {
    uint32_t struct_size;
    uint32_t source_count;              /* program speakers only, in matrix order */
    uint32_t seat_count;
    uint32_t bin_count;
    double sample_rate;
    const float *frequency_hz;          /* bin_count */
    const float *target_db;             /* bin_count */
    const float *seat_weight;           /* seat_count; 0 excludes a seat */
    const float *magnitude_db;          /* [source][seat][bin] */
    const uint8_t *response_valid;      /* [source][seat]; non-zero when the measurement is valid */
    const float *source_trim_db;        /* source_count, from n60_correct_calib_align; NULL = 0 */
    const uint32_t *source_delay_frames;/* source_count; NULL = 0 */
    const uint8_t *source_polarity_inverted; /* source_count; NULL = 0 */
    n60_speaker_correction_settings settings;
} n60_speaker_correction_problem;

typedef struct n60_speaker_correction_source {
    uint32_t valid;
    float trim_db;
    uint32_t delay_frames;
    uint32_t polarity_inverted;
    uint32_t band_count;
    n60_speaker_band bands[N60_SPEAKER_MAX_BANDS];
    float pre_rms_error_db;
    float post_rms_error_db;
    float seat_variance_db2;
} n60_speaker_correction_source;

/* Greedy bounded PEQ per source: never averages seat phase, keeps a band only when the full-band RMS error improves.
 * sources is caller-owned with source_count entries. Fails (nothing usable written) for invalid settings, a non-finite
 * target, no positive seat weight, or an invalid response at an included seat. */
int32_t n60_speaker_correction_design(const n60_speaker_correction_problem *problem, n60_speaker_correction_source *sources);

/* ---- 3. Speaker Optimizer candidates (PEQ and FIR) ---- */

/* The measured evidence both candidate searches read. position_db is the per-position mean magnitude on the grid. */
typedef struct n60_speaker_candidate_problem {
    uint32_t struct_size;
    uint32_t bin_count;                 /* >= 16 */
    uint32_t position_count;
    double sample_rate;
    const double *frequency_hz;         /* bin_count, ascending, below 0.49 fs */
    const double *target_db;            /* bin_count */
    const double *desired_db;           /* bin_count; the correction after the authorisation mask */
    const uint8_t *authorized;          /* bin_count; NULL = every bin */
    const double *position_db;          /* [position][bin] */
    const double *position_weight;      /* position_count, sums to 1 */
    double maximum_boost_db;
    double maximum_cut_db;
    double maximum_seat_degradation_db;
    double protected_leakage_db;        /* < 0: no classification mask; otherwise the leakage limit */
} n60_speaker_candidate_problem;

typedef struct n60_speaker_peq_constraints {
    uint32_t maximum_bands;             /* 1 .. N60_SPEAKER_MAX_BANDS */
    double minimum_q;
    double maximum_q;
    double maximum_band_gain_db;
    double maximum_headroom_db;
    double maximum_out_of_band_db;
    double minimum_improvement_db;
} n60_speaker_peq_constraints;

typedef struct n60_speaker_peq_result {
    uint32_t band_count;
    uint32_t audit_removals;            /* bands removed by the dense safety audit */
    n60_speaker_band bands[N60_SPEAKER_MAX_BANDS];
    double *correction_db;              /* caller-owned, bin_count: the modelled filter magnitude */
    double rmse_before_db;
    double rmse_after_db;
    double worst_seat_regression_db;
    double maximum_positive_gain_db;
    double recommended_headroom_db;
} n60_speaker_peq_result;

/* Greedy constrained peaking-EQ search with the exact digital biquad response (Q values 0.55 .. 6 inside the limits).
 * N60_SPEAKER_ERR_PEAK when the final peak-gain audit fails. */
int32_t n60_speaker_peq_design(const n60_speaker_candidate_problem *problem, const n60_speaker_peq_constraints *constraints,
                               n60_speaker_peq_result *result);

typedef struct n60_speaker_fir_constraints {
    uint32_t tap_count;                 /* odd */
    uint32_t maximum_taps;              /* longest FIR the active scheme supports (transform bound) */
    uint32_t single_band_cap;           /* N60_CORRECT_STAGE_TAPS or _LONG */
    double maximum_headroom_db;
    double maximum_out_of_band_db;
    double maximum_seat_degradation_db;
    double minimum_improvement_db;
    double maximum_truncation_overshoot_db;
} n60_speaker_fir_constraints;

#define N60_SPEAKER_FIR_BLOCK_NONFINITE 1u      /* non-finite FIR spectrum */
#define N60_SPEAKER_FIR_BLOCK_OVERSHOOT 2u      /* exceeds the aggregate cut/boost limits after truncation */
#define N60_SPEAKER_FIR_BLOCK_OUT_OF_BAND 4u    /* gain deviation outside the measured band */
#define N60_SPEAKER_FIR_BLOCK_HEADROOM 8u       /* headroom over budget */
#define N60_SPEAKER_FIR_BLOCK_LEAKAGE 16u       /* leaks into a classification-protected region */
#define N60_SPEAKER_FIR_BLOCK_NO_GAIN 32u       /* no meaningful modelled improvement */
#define N60_SPEAKER_FIR_BLOCK_SEAT 64u          /* degrades a position beyond its limit */

typedef struct n60_speaker_fir_result {
    uint32_t blockers;                  /* bit set of N60_SPEAKER_FIR_BLOCK_*; 0 = accepted */
    float *taps;                        /* caller-owned, tap_count; always written */
    double *response_db;                /* caller-owned, bin_count: modelled magnitude of the taps */
    double rmse_before_db;
    double rmse_after_db;
    double worst_seat_regression_db;
    double maximum_positive_gain_db;
    double recommended_headroom_db;
} n60_speaker_fir_result;

/* Linear-phase synthesis of desired_db (exact group delay, Blackman, one-third-octave band edge taper), a forward
 * transform of the float taps and the acceptance audit. N60_SPEAKER_ERR_TOO_LONG, _GRID or _NONFINITE when no taps result. */
int32_t n60_speaker_fir_design(const n60_speaker_candidate_problem *problem, const n60_speaker_fir_constraints *constraints,
                               n60_speaker_fir_result *result);

/* ---- 4. Crossover feasibility (mains plus subwoofer timing and polarity hypothesis; preview only) ---- */

typedef struct n60_speaker_crossover_options {
    double center_hz;                   /* 35 .. 250 */
    double band_width_octaves;          /* 0.5 .. 1.5 */
    uint32_t frequency_point_count;     /* 16 .. 64 */
    double maximum_additional_delay_ms; /* 0 .. 12 */
    double delay_step_ms;               /* 0.125 .. 1 */
    double maximum_arrival_gap_ms;      /* 0 .. 40 (checked by the caller, which owns the arrivals) */
    double maximum_seat_regression_db;  /* 0 .. 2 */
    double minimum_aggregate_improvement_db; /* 0 .. 2 */
    double maximum_modeled_sum_above_strongest_db; /* 0 .. 6.5 */
} n60_speaker_crossover_options;

/* 80 Hz, one octave, 32 points, 8 ms in 0.25 ms steps, 25 ms arrival gap, 1 dB regression, 0.25 dB gain, 6.5 dB sum. */
void n60_speaker_crossover_defaults(n60_speaker_crossover_options *options);

/* 1 when the options are inside their limits and the upper band edge is below 0.48 fs. */
int32_t n60_speaker_crossover_options_valid(const n60_speaker_crossover_options *options, double sample_rate);

/* The log-spaced analysis grid (frequency_point_count values from centre / 2^(w/2) to centre * 2^(w/2)). */
int32_t n60_speaker_crossover_frequencies(const n60_speaker_crossover_options *options, double *out_hz, uint32_t capacity);

/* One source's complex response at frequency_hz: the mean over captures of the log-frequency interpolated magnitude and
 * circular phase, rotated by -2 pi f arrival_seconds. magnitude_db and phase_rad are [capture][grid]. */
int32_t n60_speaker_crossover_response(const double *grid_hz, uint32_t grid_count, uint32_t capture_count,
                                       const double *magnitude_db, const double *phase_rad, double arrival_seconds,
                                       const double *frequency_hz, uint32_t count, double *real, double *imag);

typedef struct n60_speaker_crossover_problem {
    uint32_t struct_size;
    uint32_t seat_count;
    uint32_t point_count;
    double sample_rate;
    const double *frequency_hz;         /* point_count */
    const double *main_real;            /* [seat][point] */
    const double *main_imag;
    const double *sub_real;
    const double *sub_imag;
    const double *seat_weight;          /* seat_count, sums to 1 */
    n60_speaker_crossover_options options;
} n60_speaker_crossover_problem;

typedef struct n60_speaker_crossover_result {
    uint32_t accepted;
    uint32_t invert_sub_polarity;
    double delay_ms;                    /* positive: delay the mains; negative: delay the sub */
    double aggregate_improvement_db;
    double maximum_sum_above_strongest_db;
    double *baseline_level_db;          /* caller-owned, seat_count */
    double *selected_level_db;          /* caller-owned, seat_count: baseline when not accepted */
    double *selected_peak_above_db;     /* caller-owned, seat_count */
} n60_speaker_crossover_result;

/* Exhaustive search over delay (+-maximum_additional_delay_ms) and polarity, keeping the best aggregate improvement that
 * respects the per-seat regression and summed-energy guards (ties go to the smaller delay). */
int32_t n60_speaker_crossover_search(const n60_speaker_crossover_problem *problem, n60_speaker_crossover_result *result);

/* One hypothesis: per-seat summed level and the peak of the sum over the stronger source, with an extra unknown sub
 * clock offset. Arrays caller-owned, seat_count each. */
int32_t n60_speaker_crossover_evaluate(const n60_speaker_crossover_problem *problem, double delay_ms, int32_t invert,
                                       double unknown_sub_clock_offset_ms, double *level_db, double *peak_above_db);

typedef struct n60_speaker_sensitivity_options {
    double maximum_clock_offset_ms;     /* 0.125 .. 8 */
    uint32_t sample_count;              /* odd, 3 .. 33 */
    double minimum_worst_improvement_db;/* 0 .. 2 */
    double maximum_worst_seat_regression_db; /* 0 .. 2 */
    double maximum_sum_above_strongest_db;   /* 0 .. 6.5 */
} n60_speaker_sensitivity_options;

void n60_speaker_sensitivity_defaults(n60_speaker_sensitivity_options *options);
int32_t n60_speaker_sensitivity_options_valid(const n60_speaker_sensitivity_options *options);

#define N60_SPEAKER_SENSITIVITY_ERASED 1u       /* the worst improvement is below its minimum */
#define N60_SPEAKER_SENSITIVITY_SEAT 2u         /* a seat regresses beyond its limit */
#define N60_SPEAKER_SENSITIVITY_SUM 4u          /* the summed-energy guard is exceeded */

typedef struct n60_speaker_sensitivity_sample {
    double clock_offset_ms;
    double improvement_db;
    double seat_regression_db;
    double sum_above_strongest_db;
} n60_speaker_sensitivity_sample;

typedef struct n60_speaker_sensitivity_summary {
    uint32_t reasons;                   /* bit set of N60_SPEAKER_SENSITIVITY_* */
    double worst_improvement_db;
    double worst_seat_regression_db;
    double worst_sum_above_strongest_db;
} n60_speaker_sensitivity_summary;

/* Re-runs the hypothesis (delay_ms, invert) against bypass at each assumed sub clock offset. samples is caller-owned with
 * options->sample_count entries. N60_SPEAKER_ERR_NONFINITE when any sample is not finite. */
int32_t n60_speaker_crossover_sensitivity(const n60_speaker_crossover_problem *problem, double delay_ms, int32_t invert,
                                          const n60_speaker_sensitivity_options *options,
                                          n60_speaker_sensitivity_sample *samples, n60_speaker_sensitivity_summary *summary);

/* ---- 5. Cross-domain deviation classifier (early-window shape against the listening seats) ---- */

#define N60_SPEAKER_CLASS_PERSISTENT 0u
#define N60_SPEAKER_CLASS_ROOM_SEAT 1u
#define N60_SPEAKER_CLASS_AMBIGUOUS 2u
#define N60_SPEAKER_CLASS_NO_DEVIATION 3u

typedef struct n60_speaker_classify_options {
    double smoothing_octaves;           /* 0.15 .. 1 */
    double significant_deviation_db;    /* 0.5 .. 6 */
    double near_speaker_flat_tolerance_db; /* 0 .. significant */
    double speaker_agreement_tolerance_db; /* 0.25 .. 3 */
    double maximum_persistent_seat_spread_db; /* 0.25 .. 3 */
    double room_seat_spread_threshold_db; /* 0.5 .. 6 */
    uint32_t minimum_point_count;       /* >= 8 */
} n60_speaker_classify_options;

/* 1/3 octave, 1.5 dB, 0.75 dB, 1 dB, 1 dB, 1.5 dB, 16 points. */
void n60_speaker_classify_defaults(n60_speaker_classify_options *options);
int32_t n60_speaker_classify_options_valid(const n60_speaker_classify_options *options);

/* Per-capture mean of the log-frequency interpolated magnitude at each at_hz. magnitude_db is [capture][grid_count].
 * N60_SPEAKER_ERR_ARGUMENT for a grid that is not finite, positive and strictly ascending, a non-finite magnitude, or an
 * at_hz outside the grid. */
int32_t n60_speaker_mean_interpolated(const double *grid_hz, uint32_t grid_count, const double *magnitude_db,
                                      uint32_t capture_count, const double *at_hz, uint32_t count, double *out);

/* Local shape residual: magnitude minus its Gaussian log-frequency smoothing. */
int32_t n60_speaker_local_residual(const double *frequency_hz, const double *magnitude_db, uint32_t count,
                                   double smoothing_octaves, double *out);

typedef struct n60_speaker_cross_domain_problem {
    uint32_t struct_size;
    uint32_t point_count;
    uint32_t seat_count;
    const double *frequency_hz;         /* point_count, ascending */
    const double *characterization_db;  /* point_count: mean early-window magnitude */
    const double *seat_db;              /* [seat][point]: per-seat mean listening magnitude */
    n60_speaker_classify_options options;
} n60_speaker_cross_domain_problem;

typedef struct n60_speaker_cross_domain_point {
    double characterization_residual_db;
    double listening_mean_residual_db;
    double listening_seat_spread_db;
    uint32_t classification;            /* N60_SPEAKER_CLASS_* */
} n60_speaker_cross_domain_point;

/* Residuals of both domains, the seat mean and population spread, and the label per point. points is caller-owned. */
int32_t n60_speaker_cross_domain_classify(const n60_speaker_cross_domain_problem *problem, n60_speaker_cross_domain_point *points);

/* ---- 6. Early-window characterisation ---- */

typedef struct n60_speaker_early_window_settings {
    double pre_arrival_ms;              /* 0 .. 2 */
    double post_arrival_ms;             /* 3 .. 12 */
    double fade_out_ms;                 /* >= 0.25 and <= half the post-arrival window */
    double minimum_cycles;              /* 1 .. 4 */
} n60_speaker_early_window_settings;

/* 0.75 ms before, 6 ms after, 1.5 ms fade, 2 cycles. */
void n60_speaker_early_window_defaults(n60_speaker_early_window_settings *settings);
int32_t n60_speaker_early_window_settings_valid(const n60_speaker_early_window_settings *settings);

typedef struct n60_speaker_early_window_result {
    uint32_t first_index;               /* first transfer-function frequency kept */
    uint32_t count;                     /* frequencies kept (>= 8) */
    double retained_pre_arrival_ms;
    double retained_post_arrival_ms;
} n60_speaker_early_window_result;

/* Raised-cosine gated direct-sum DFT magnitude of the impulse around its direct arrival, at the transfer-function
 * frequencies inside the gate-limited, usable and 0.49 fs band. usable_low_hz and usable_high_hz are the caller's resolved
 * limits. magnitude_db is caller-owned with tf_count entries; result->count of them from first_index are written.
 * Microphone calibration is added by the caller. */
int32_t n60_speaker_early_window(const float *impulse, uint32_t impulse_count, double sample_rate, double arrival_seconds,
                                 double usable_low_hz, double usable_high_hz, const double *tf_frequency_hz,
                                 uint32_t tf_count, const n60_speaker_early_window_settings *settings,
                                 double *magnitude_db, n60_speaker_early_window_result *result);

/* ---- 7. Design-engine preview scoring (bounded magnitude envelope, never filters) ---- */

typedef struct n60_speaker_preview_options {
    double maximum_cut_db;              /* 0 .. 12 */
    double maximum_boost_db;            /* 0 .. 3 */
    double smoothing_octaves;           /* 0.15 .. 1 */
    double target_tilt_db_per_octave;   /* -3 .. 3 */
    double maximum_seat_degradation_db; /* 0 .. 1 */
} n60_speaker_preview_options;

/* 6 dB cut, no boost, 1/3 octave, no tilt, 0.25 dB. */
void n60_speaker_preview_defaults(n60_speaker_preview_options *options);
int32_t n60_speaker_preview_options_valid(const n60_speaker_preview_options *options);

typedef struct n60_speaker_preview_problem {
    uint32_t struct_size;
    uint32_t bin_count;                 /* >= 1 */
    uint32_t seat_count;
    const double *frequency_hz;         /* bin_count, positive */
    const double *seat_db;              /* [seat][bin]: per-seat mean magnitude */
    const double *seat_weight;          /* seat_count, sums to 1 */
    n60_speaker_preview_options options;
} n60_speaker_preview_problem;

typedef struct n60_speaker_preview_result {
    uint32_t reverted;                  /* 1 when the candidate worsened the aggregate or a seat and unity was kept */
    double *target_db;                  /* caller-owned, bin_count */
    double *correction_db;              /* caller-owned, bin_count */
    double rmse_before_db;
    double rmse_after_db;
} n60_speaker_preview_result;

/* Median-referenced target with tilt, smoothed-shape correction bounded by the cut and boost limits, weighted RMSE before
 * and after, and the revert rule for an aggregate or per-seat regression. */
int32_t n60_speaker_design_preview(const n60_speaker_preview_problem *problem, n60_speaker_preview_result *result);

#ifdef __cplusplus
}
#endif

#endif
