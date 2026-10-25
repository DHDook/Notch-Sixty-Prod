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

#ifdef __cplusplus
}
#endif

#endif
