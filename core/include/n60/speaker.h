/*
 * Speaker optimiser maths (E21 S9a, domain version N60_SPEAKER_ABI_VERSION). Numbers-to-numbers only: the bounded speaker
 * correction PEQ designer of the multichannel calibration (the legacy N60SpeakerCorrectionDesigner.h), the response
 * interpolation onto the calibration grid, and the Speaker Optimizer's PEQ and FIR candidate searches. Evidence selection,
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

#define N60_SPEAKER_ABI_VERSION 1u

#define N60_SPEAKER_OK 0
#define N60_SPEAKER_ERR_ARGUMENT (-1)
#define N60_SPEAKER_ERR_SIZE (-2)
#define N60_SPEAKER_ERR_NONFINITE (-3)
#define N60_SPEAKER_ERR_ALLOC (-4)
#define N60_SPEAKER_ERR_TOO_LONG (-5)   /* FIR longer than the single-band cap */
#define N60_SPEAKER_ERR_GRID (-6)       /* FIR: a grid frequency lies outside the transform */
#define N60_SPEAKER_ERR_PEAK (-7)       /* PEQ: the final peak-gain audit is non-finite or over the headroom limit */

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

#ifdef __cplusplus
}
#endif

#endif
