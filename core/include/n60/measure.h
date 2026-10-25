/*
 * libn60core measurement interface (E11 S1). Offline analysis only: every function here
 * may allocate, runs on a control or worker thread, and must never be called from an
 * audio callback. No function throws across this boundary; failures return a negative
 * N60_MEASURE_ERR_* code. Results are deterministic (fixed summation order, no threads,
 * seeded noise).
 *
 * The version is separate from the graph ABI (n60/graph.h) so analysis changes never
 * bump the realtime interface.
 */
#ifndef N60_MEASURE_H
#define N60_MEASURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MEASURE_ABI_VERSION 1

#define N60_MEASURE_OK 0
#define N60_MEASURE_ERR_ARGUMENT (-1)
#define N60_MEASURE_ERR_SIZE (-2)
#define N60_MEASURE_ERR_CAPACITY (-3)
#define N60_MEASURE_ERR_UNUSABLE_EXCITATION (-4)
#define N60_MEASURE_ERR_ALLOC (-5)
#define N60_MEASURE_ERR_TIMING_REFERENCE (-6)   /* reference correlation peak too weak (E11 S2) */
#define N60_MEASURE_ERR_NO_ACCEPTED_REPEATS (-7)

/* Largest offline transform: 2^24 points (a 30 s sweep plus tail at 384 kHz). */
#define N60_MEASURE_MAX_TRANSFORM 16777216u

uint32_t n60_measure_abi_version(void);

/* Smallest power of two >= required_frames (and >= 2). Fails with ERR_SIZE above the maximum. */
int32_t n60_measure_transform_size(uint64_t required_frames, uint64_t *size_out);

/* ---- Exponential sine sweep ---- */

typedef struct n60_measure_ess_params {
    double sample_rate;
    double start_hz;
    double end_hz;
    double duration_seconds;   /* requested; a synchronised sweep rounds it (see info) */
    double level_dbfs;         /* peak, <= 0 */
    double fade_seconds;       /* half-Hann rise and fall, <= duration / 2 */
    uint32_t synchronised;     /* 1: Novak et al. 2015 synchronised ESS; 0: plain Farina ESS */
} n60_measure_ess_params;

typedef struct n60_measure_ess_info {
    uint64_t frame_count;
    double sweep_rate_seconds; /* L: instantaneous frequency is start_hz * exp(t / L) */
    double duration_seconds;   /* actual: L * ln(end / start) */
} n60_measure_ess_info;

int32_t n60_measure_ess_describe(const n60_measure_ess_params *params, n60_measure_ess_info *info_out);

/* Writes info.frame_count samples; fails with ERR_CAPACITY when capacity is smaller. */
int32_t n60_measure_ess_generate(const n60_measure_ess_params *params, float *out, uint64_t capacity,
                                 n60_measure_ess_info *info_out);

/* Seconds by which the k-th harmonic impulse precedes the linear impulse (k >= 2): L ln k. */
double n60_measure_ess_harmonic_lead_seconds(const n60_measure_ess_info *info, uint32_t harmonic);

/* ---- Deconvolution ---- */

/*
 * Regularised frequency-domain division Y conj(X) / (|X|^2 + lambda) with
 * lambda = regularization_ratio * max |X|^2, on a transform of transform_size(observed_count)
 * points. Returns the full circular response: out_count = transform size, so negative time
 * (harmonic impulses of an ESS) sits at the end of the buffer. The output is not windowed.
 */
int32_t n60_measure_deconvolve(const float *excitation, uint64_t excitation_count,
                               const float *observed, uint64_t observed_count,
                               double regularization_ratio,
                               float *out, uint64_t out_capacity, uint64_t *out_count);

/* ---- Synthetic reference room ---- */

#define N60_MEASURE_ROOM_BANDS 7 /* octave bands 125 Hz .. 8 kHz */

typedef struct n60_measure_room_params {
    double sample_rate;
    uint32_t seed;
    double direct_delay_seconds;     /* acoustic path, added to the IR */
    double direct_gain;
    double ir_seconds;               /* IR length, longer than the longest RT60 */
    double rt60_seconds[N60_MEASURE_ROOM_BANDS]; /* per octave band, 125 Hz .. 8 kHz */
    double diffuse_level_db;         /* diffuse tail level relative to the direct impulse */
    double mode_frequencies_hz[4];   /* 0 disables a mode */
    double mode_decay_seconds[4];    /* RT60 of each mode */
    double mode_level_db[4];         /* relative to the direct impulse */
    /* Capture model (n60_measure_room_capture only). */
    double harmonic_db[4];           /* H2..H5 re the instantaneous fundamental; <= -200 off */
    double latency_seconds;          /* playback-to-capture latency */
    double drift_ppm;                /* capture clock fast (+) or slow (-) against playback */
    double noise_dbfs;               /* RMS of seeded white noise; <= -200 off */
    uint32_t noise_seed;             /* 0: use seed; else an independent noise stream (repeats) */
} n60_measure_room_params;

/* Fills a deterministic default room for the rate (flat direct, 0.4 s RT60, no distortion). */
void n60_measure_room_defaults(double sample_rate, n60_measure_room_params *params);

int32_t n60_measure_room_ir_length(const n60_measure_room_params *params, uint64_t *frames_out);
int32_t n60_measure_room_ir(const n60_measure_room_params *params, float *out, uint64_t capacity,
                            uint64_t *count_out);

/* Frames the capture of `excitation_count` samples occupies (excitation + IR + latency + guard). */
int32_t n60_measure_room_capture_length(const n60_measure_room_params *params,
                                        uint64_t excitation_count, uint64_t *frames_out);
/*
 * Ideal harmonic generator (exact H2..H5 relative to the fundamental), then the room IR,
 * latency, clock drift (cubic interpolation) and seeded noise.
 */
int32_t n60_measure_room_capture(const n60_measure_room_params *params,
                                 const float *excitation, uint64_t excitation_count,
                                 float *out, uint64_t capacity, uint64_t *count_out);

/* ---- Timing reference and repeat averaging (E11 S2, design notes 4 and 5) ---- */

#define N60_MEASURE_MAX_REPEATS 16

/* Timing tiers recorded on each measurement. */
#define N60_MEASURE_TIMING_LOOPBACK 1  /* electrical loopback channel: exact */
#define N60_MEASURE_TIMING_ACOUSTIC 2  /* reference chirp on a reference speaker */
#define N60_MEASURE_TIMING_NONE 3      /* direct arrival, no inter-channel delay reported */

typedef struct n60_measure_chirp_params {
    double sample_rate;
    double start_hz;          /* 2000 */
    double end_hz;            /* 0: min(20000, 0.45 * sample_rate) */
    double duration_seconds;  /* 0.25 */
    double level_dbfs;        /* peak, <= 0 */
    double fade_seconds;      /* half-Hann rise and fall; 0.005 */
} n60_measure_chirp_params;

void n60_measure_chirp_defaults(double sample_rate, n60_measure_chirp_params *params);
int32_t n60_measure_chirp_length(const n60_measure_chirp_params *params, uint64_t *frames_out);
int32_t n60_measure_chirp_generate(const n60_measure_chirp_params *params, float *out, uint64_t capacity,
                                   uint64_t *count_out);

typedef struct n60_measure_arrival {
    double arrival_frames;          /* sub-sample capture frame at which the template begins */
    double peak_to_neighbourhood_db;/* correlation peak over the RMS of the rest of the correlation */
} n60_measure_arrival;

/*
 * Matched-filter arrival of `tmpl` inside `capture` (FFT cross-correlation, parabolic peak).
 * Used for tier (a) (template = the loopback program) and tier (b) (template = the chirp).
 * Returns ERR_TIMING_REFERENCE when the peak is under `min_peak_db` above the neighbourhood
 * (default 20); `arrival_out` is still filled so the UI can show why it failed.
 */
int32_t n60_measure_find_arrival(const float *tmpl, uint64_t tmpl_count, const float *capture,
                                 uint64_t capture_count, double sample_rate, double min_peak_db,
                                 n60_measure_arrival *arrival_out);

/* Tier (c): sub-sample position of the largest |sample| of [begin, end) with a parabolic peak. */
int32_t n60_measure_peak_position(const float *data, uint64_t count, uint64_t begin, uint64_t end,
                                  double *position_out);

typedef struct n60_measure_average_params {
    double sample_rate;
    uint32_t repeat_count;           /* 1..N60_MEASURE_MAX_REPEATS */
    uint64_t length_frames;          /* every repeat has this many frames */
    uint64_t repeat_period_frames;   /* start-to-start spacing of the repeats, for the drift estimate */
    double min_coherence;            /* 0.9 */
    double max_level_diff_db;        /* 1.0, 200 Hz - 5 kHz level against the median repeat */
    double drift_warning_ppm;        /* 20 */
} n60_measure_average_params;

typedef struct n60_measure_average_result {
    uint32_t accepted_count;
    uint32_t rejected_mask;          /* bit r set: repeat r rejected */
    uint32_t drift_warning;          /* 1 when |drift_ppm| > drift_warning_ppm */
    double drift_ppm;                /* slope of the reference arrivals across repeats */
    double coherence[N60_MEASURE_MAX_REPEATS];
    double level_db[N60_MEASURE_MAX_REPEATS];
} n60_measure_average_result;

void n60_measure_average_defaults(double sample_rate, n60_measure_average_params *params);

/*
 * Aligns every repeat to repeat 0 using its reference `arrivals[r]` (frames, sub-sample, from
 * n60_measure_find_arrival or n60_measure_peak_position) with an exact FFT fractional shift,
 * rejects repeats whose coherence with the median repeat or whose level differ too much
 * (needs three or more repeats to reject), and writes the coherent time-domain mean of the
 * rest. Output length is length_frames. Deterministic.
 */
int32_t n60_measure_average_repeats(const n60_measure_average_params *params,
                                    const float *const *repeats, const double *arrivals,
                                    float *out, uint64_t capacity,
                                    n60_measure_average_result *result_out);

/* ---- Harmonic distortion from a synchronised-ESS response (E11 S3, design note 9) ---- */

#define N60_MEASURE_MAX_HARMONIC 5
#define N60_MEASURE_NO_DATA_DB (-999.0) /* a curve point whose harmonic lies above the sweep band */

typedef struct n60_measure_distortion_params {
    double sample_rate;
    double sweep_start_hz;
    double sweep_end_hz;
    double sweep_rate_seconds;       /* L from n60_measure_ess_info */
    uint64_t linear_index;           /* frame of the linear impulse; UINT64_MAX: largest |sample| in the first half */
    double smoothing_octaves;        /* power smoothing of every curve; 1/3 */
    uint32_t points_per_octave;      /* output grid density, log spaced; 12 */
    double response_seconds;         /* room response one wants inside each harmonic window; 0.05 */
    double edge_guard_octaves;       /* a harmonic point is reported only when its smoothing band ends this far
                                        below sweep_end_hz (the sweep's fade-out and the regularised division
                                        corrupt the last part of the band); 0.1 */
} n60_measure_distortion_params;

typedef struct n60_measure_distortion_info {
    uint32_t point_count;
    uint64_t linear_index;           /* as used */
    double min_window_seconds;       /* shortest harmonic window (H5), half the gap to H4 */
    double min_sweep_seconds;        /* shortest sweep whose H5 window holds response_seconds */
    uint32_t clean_separation;       /* 1 when the sweep is at least min_sweep_seconds */
} n60_measure_distortion_info;

void n60_measure_distortion_defaults(double sample_rate, const n60_measure_ess_info *sweep,
                                     double start_hz, double end_hz, n60_measure_distortion_params *params);

/* Shortest sweep over start..end for which the 5th harmonic window holds response_seconds. */
double n60_measure_distortion_min_sweep_seconds(double start_hz, double end_hz, double response_seconds);

/*
 * `response` is the full circular deconvolved response of a synchronised sweep (n60_measure_deconvolve
 * output). The k-th harmonic impulse sits L ln k before the linear one; each is windowed to half the
 * gap to the next impulse in time and its spectrum read at k f, so harmonic k is plotted against the
 * fundamental f in dB re the linear response at f. Arrays hold `capacity` points; frequency_hz and
 * the dB curves are filled for point_count points. harmonic_db[k-2] is N60_MEASURE_NO_DATA_DB where
 * k f exceeds the sweep band. thd_db sums the harmonics that are in band (power).
 */
int32_t n60_measure_distortion_analyze(const n60_measure_distortion_params *params,
                                       const float *response, uint64_t response_count,
                                       double *frequency_hz, double *fundamental_db,
                                       double *harmonic_db[N60_MEASURE_MAX_HARMONIC - 1], double *thd_db,
                                       uint32_t capacity, n60_measure_distortion_info *info_out);

/* ---- Decay times from an impulse response (E11 S3, design note 9) ---- */

#define N60_MEASURE_DECAY_OCTAVE 1
#define N60_MEASURE_DECAY_THIRD_OCTAVE 3

#define N60_MEASURE_DECAY_FLAG_EDT_RANGE 1u   /* decay range under 10 dB: EDT not reported */
#define N60_MEASURE_DECAY_FLAG_T20_RANGE 2u   /* under 25 dB: T20 not reported */
#define N60_MEASURE_DECAY_FLAG_T30_RANGE 4u   /* under 35 dB: T30 not reported */
#define N60_MEASURE_DECAY_FLAG_NO_DECAY 8u    /* no measurable decay (silent or not decaying) */

typedef struct n60_measure_decay_band {
    double centre_hz;                /* exact base-10 centre (1000 * 10^(0.1 n) for thirds) */
    double edt_seconds;              /* 0 when unavailable; see flags */
    double t20_seconds;
    double t30_seconds;
    double rt60_seconds;             /* T30 when available, else T20, else EDT, else 0 */
    double decay_range_db;           /* Schroeder drop reached before the noise floor */
    double noise_floor_db;           /* re the band peak */
    uint32_t flags;
} n60_measure_decay_band;

/*
 * Causal IEC 61260-1 base-10 band filters (double, order 3 Butterworth band-pass), Lundeby
 * truncation with noise compensation, Schroeder backward integration. Bands are those with
 * nominal centres in [min_centre_hz, max_centre_hz] (63..8000 by default) whose upper edge is
 * under 0.45 fs. bands_per_octave is 1 or 3.
 */
int32_t n60_measure_decay_analyze(const float *ir, uint64_t count, double sample_rate,
                                  uint32_t bands_per_octave, double min_centre_hz, double max_centre_hz,
                                  n60_measure_decay_band *bands, uint32_t capacity, uint32_t *band_count);

#ifdef __cplusplus
}
#endif

#endif
