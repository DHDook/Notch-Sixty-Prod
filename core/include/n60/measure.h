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

#define N60_MEASURE_ABI_VERSION 3

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

/* ---- Multi-source, multi-seat reference room (E10 S1) ----
 * N sources by K seats. Every seat shares the direct sound's early reflections (coherent), has its
 * own modal gains (so levels differ between seats), its own diffuse tail and noise, and one set of
 * second-order allpass sections gives every path a known excess phase and group delay.
 */
#define N60_MEASURE_MULTIROOM_MAX 8
#define N60_MEASURE_MULTIROOM_REFLECTIONS 4
#define N60_MEASURE_MULTIROOM_ALLPASS 4

typedef struct n60_measure_multiroom_params {
    uint32_t struct_size;
    n60_measure_room_params base;     /* direct path, modes, diffuse tail; capture fields unused */
    uint32_t source_count;            /* 1 .. MULTIROOM_MAX */
    uint32_t seat_count;              /* 1 .. MULTIROOM_MAX */
    double source_delay_seconds[N60_MEASURE_MULTIROOM_MAX]; /* added to the direct delay per source */
    double seat_delay_seconds[N60_MEASURE_MULTIROOM_MAX];   /* added to the direct delay per seat */
    double modal_variation;           /* seat modal gain = 1 + modal_variation * u, u in [-1, 1) seeded */
    uint32_t reflection_count;
    double reflection_delay_seconds[N60_MEASURE_MULTIROOM_REFLECTIONS]; /* after the base direct delay */
    double reflection_gain_db[N60_MEASURE_MULTIROOM_REFLECTIONS];       /* re the direct impulse */
    uint32_t allpass_count;
    double allpass_f0_hz[N60_MEASURE_MULTIROOM_ALLPASS];
    double allpass_q[N60_MEASURE_MULTIROOM_ALLPASS];
    double ir_noise_dbfs;             /* seeded white noise added per (source, seat) IR; <= -200 off */
} n60_measure_multiroom_params;

void n60_measure_multiroom_defaults(double sample_rate, n60_measure_multiroom_params *params);
int32_t n60_measure_multiroom_ir_length(const n60_measure_multiroom_params *params, uint64_t *frames_out);
int32_t n60_measure_multiroom_ir(const n60_measure_multiroom_params *params, uint32_t source, uint32_t seat,
                                 float *out, uint64_t capacity, uint64_t *count_out);
/* Direct arrival of one path in frames. */
double n60_measure_multiroom_arrival_frames(const n60_measure_multiroom_params *params, uint32_t source, uint32_t seat);
/* Analytic phase (radians, continuous from 0) and group delay (seconds) of the allpass sections. */
double n60_measure_multiroom_allpass_phase(const n60_measure_multiroom_params *params, double hz);
double n60_measure_multiroom_allpass_group_delay(const n60_measure_multiroom_params *params, double hz);

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

/* ---- Waterfall (cumulative spectral decay) and spectrogram (E11 S4, design note 9) ---- */

typedef struct n60_measure_waterfall_params {
    double sample_rate;
    uint64_t arrival_index;     /* direct arrival frame; UINT64_MAX: largest |sample| */
    double step_seconds;        /* slice spacing: 0.0003 (speaker) or 0.02 (room) */
    uint32_t slice_count;       /* 40 (speaker) or 30 (room) */
    double window_seconds;      /* fixed end of every window, measured from the arrival */
    double rise_seconds;        /* half-Hann rise ending at each slice start; 0.0001 */
    double smoothing_octaves;   /* power smoothing; 1/24 */
    uint32_t points_per_octave; /* log-spaced output grid; 24 */
    double min_hz;              /* 20 */
    double max_hz;              /* min(20000, 0.45 fs) */
} n60_measure_waterfall_params;

typedef struct n60_measure_waterfall_info {
    uint32_t point_count;       /* frequency points per slice */
    uint32_t slice_count;
    uint64_t arrival_index;     /* as used */
    uint64_t end_index;         /* fixed window end (exclusive), clamped to the response length */
} n60_measure_waterfall_info;

/* room = 0: speaker preset (0.3 ms x 40, window 3x the slice span); 1: room preset (20 ms x 30, 2x). */
void n60_measure_waterfall_defaults(double sample_rate, uint32_t room, n60_measure_waterfall_params *params);

/* Grid sizes only (no data needed). */
int32_t n60_measure_waterfall_describe(const n60_measure_waterfall_params *params, n60_measure_waterfall_info *info_out);

/*
 * Slice i covers [arrival + i step, end) with a half-Hann rise in the frames before it and a half-Hann
 * fall over the last quarter of the fixed window; its power spectrum is smoothed and read on the log
 * grid. out_db is slice-major (slice * point_count + point), dB with the loudest cell at 0, and holds
 * out_capacity cells (>= slice_count * point_count). A slice with under 16 frames left reads
 * N60_MEASURE_NO_DATA_DB.
 */
int32_t n60_measure_waterfall_analyze(const n60_measure_waterfall_params *params, const float *ir,
                                      uint64_t count, double *frequency_hz, double *out_db,
                                      uint64_t out_capacity, n60_measure_waterfall_info *info_out);

typedef struct n60_measure_spectrogram_params {
    double sample_rate;
    double window_seconds;      /* Hann (periodic); 0.01 */
    double max_hz;              /* 0: min(20000, 0.45 fs) */
    uint64_t begin_index;       /* first frame analysed */
    uint64_t end_index;         /* 0: the whole response */
} n60_measure_spectrogram_params;

typedef struct n60_measure_spectrogram_info {
    uint32_t frame_count;
    uint32_t bin_count;         /* bins 0 .. bin_count-1 at k * hz_per_bin */
    uint32_t window_frames;
    uint32_t hop_frames;        /* window / 4: 75 % overlap */
    uint32_t fft_size;
    double hz_per_bin;
    uint64_t begin_index;       /* frame j covers [begin + j hop, begin + j hop + window) */
} n60_measure_spectrogram_info;

void n60_measure_spectrogram_defaults(double sample_rate, n60_measure_spectrogram_params *params);
int32_t n60_measure_spectrogram_describe(const n60_measure_spectrogram_params *params, uint64_t count,
                                         n60_measure_spectrogram_info *info_out);
/* out_db is frame-major (frame * bin_count + bin), dB with the loudest cell at 0, floor -200. */
int32_t n60_measure_spectrogram_analyze(const n60_measure_spectrogram_params *params, const float *ir,
                                        uint64_t count, double *out_db, uint64_t out_capacity,
                                        n60_measure_spectrogram_info *info_out);

/* ---- Live monitor: SPSC ring, SPL meter, RTA (E11 S8, design note 7) ---- */

/*
 * Input monitor ring. One producer (the input-only IOProc) and one consumer (the analysis worker).
 * Mono float samples. Producer calls are wait-free and allocation-free; create and destroy are
 * control-plane. When the ring is full the frames that do not fit are dropped and counted, never
 * waited for.
 */
typedef struct n60_monitor_ring n60_monitor_ring;

/* capacity_frames: power of two, 256 .. 2^24. */
int32_t n60_monitor_ring_create(uint32_t capacity_frames, n60_monitor_ring **ring_out);
void n60_monitor_ring_destroy(n60_monitor_ring *ring);
/* Producer. Reads `frames` samples spaced `stride` floats apart (interleaved channel); non-finite samples are
 * stored as 0. Returns the frames accepted; the rest are counted as overruns. */
uint32_t n60_monitor_ring_push(n60_monitor_ring *ring, const float *samples, uint32_t stride, uint32_t frames);
/* Consumer. Returns frames copied (<= max_frames). */
uint32_t n60_monitor_ring_pop(n60_monitor_ring *ring, float *out, uint32_t max_frames);
uint32_t n60_monitor_ring_available(const n60_monitor_ring *ring);
uint64_t n60_monitor_ring_overrun_frames(const n60_monitor_ring *ring);
/* Consumer, while the producer is stopped. */
void n60_monitor_ring_reset(n60_monitor_ring *ring);

/*
 * SPL meter (IEC 61672-1 weightings as double-precision IIR designed per rate by the bilinear transform,
 * pre-warped at 1 kHz and normalised to 0 dB there). Levels are dB re digital full scale (a sine of peak 1.0
 * reads -3.01) plus the calibration offset. Fast and Slow are exponential time weightings (125 ms, 1 s) of
 * the weighted mean square; Leq is the weighted mean square since reset; C-peak is the largest absolute
 * C-weighted sample. Worker thread only. create allocates; process does not.
 */
#define N60_SPL_WEIGHT_Z 0
#define N60_SPL_WEIGHT_A 1
#define N60_SPL_WEIGHT_C 2
#define N60_SPL_FLOOR_DB (-200.0)

typedef struct n60_spl_meter n60_spl_meter;

typedef struct n60_spl_reading {
    double fast_db;
    double slow_db;
    double leq_db;
    double c_peak_db;
    double elapsed_seconds;
} n60_spl_reading;

int32_t n60_spl_create(double sample_rate, uint32_t weighting, n60_spl_meter **meter_out);
void n60_spl_destroy(n60_spl_meter *meter);
void n60_spl_reset(n60_spl_meter *meter);
/* Offset in dB added to every reading (acoustic calibrator or microphone sensitivity). */
int32_t n60_spl_set_calibration_db(n60_spl_meter *meter, double offset_db);
int32_t n60_spl_process(n60_spl_meter *meter, const float *samples, uint64_t count);
int32_t n60_spl_read(const n60_spl_meter *meter, n60_spl_reading *reading_out);
/* Magnitude in dB of the designed digital weighting at frequency_hz (0 dB at 1 kHz). */
int32_t n60_spl_weighting_response_db(double sample_rate, uint32_t weighting, double frequency_hz, double *db_out);

/*
 * Real-time analyser. IEC 61260-1 base-10 fractional-octave bands (1, 3, 6, 12, 24, 48 per octave) read from a
 * Hann-windowed FFT with 50 % overlap; each band is the power density integrated over its exact edges, so a
 * band narrower than a bin still reads correctly. Levels are dB re full scale plus calibration_db. Averaging
 * is in the power domain. Worker thread only.
 */
#define N60_RTA_AVERAGE_NONE 0
#define N60_RTA_AVERAGE_EXPONENTIAL 1
#define N60_RTA_AVERAGE_INFINITE 2

typedef struct n60_rta_params {
    double sample_rate;
    uint32_t fft_size;           /* power of two, 1024 .. 2^20; see n60_rta_default_fft_size */
    uint32_t bands_per_octave;   /* 1, 3, 6, 12, 24 or 48 */
    uint32_t averaging;          /* N60_RTA_AVERAGE_* */
    double time_constant_seconds;/* exponential averaging */
    double min_hz;               /* 0: 20 */
    double max_hz;               /* 0: min(20000, sample_rate / 2) */
    double calibration_db;
} n60_rta_params;

typedef struct n60_rta n60_rta;

/* Smallest power of two whose bin width is at most half the 20 Hz band width, within 4096 .. 2^20. */
int32_t n60_rta_default_fft_size(double sample_rate, uint32_t bands_per_octave, uint32_t *size_out);
/* Centres and edges of the bands with centre in [min_hz, max_hz] and upper edge at or below sample_rate / 2. */
int32_t n60_rta_band_layout(uint32_t bands_per_octave, double sample_rate, double min_hz, double max_hz,
                            double *centre_hz, double *lower_hz, double *upper_hz, uint32_t capacity,
                            uint32_t *band_count);
int32_t n60_rta_create(const n60_rta_params *params, n60_rta **rta_out);
void n60_rta_destroy(n60_rta *rta);
void n60_rta_reset(n60_rta *rta);
int32_t n60_rta_process(n60_rta *rta, const float *samples, uint64_t count);
uint32_t n60_rta_band_count(const n60_rta *rta);
uint64_t n60_rta_frames_analysed(const n60_rta *rta);
/* Writes band_count centres and levels (floor N60_SPL_FLOOR_DB); fails with ERR_CAPACITY when too small. */
int32_t n60_rta_read(const n60_rta *rta, double *centre_hz, double *level_db, uint32_t capacity, uint32_t *band_count);

#ifdef __cplusplus
}
#endif

#endif
