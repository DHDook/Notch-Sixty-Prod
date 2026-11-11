/*
 * libn60core headroom maths (E9 S6, design note 10). Offline design maths: nothing here runs on an audio callback.
 * Allocation: the function allocates scratch on the calling (control or worker) thread. Realtime: not for an audio
 * callback. Latency: not applicable. Sample rate: any rate; the grid stops at 0.45 * fs. Channels: one output per
 * call. Deterministic: fixed grid, fixed summation order, no threads, no randomness; results use the platform libm.
 *
 * What it computes. For one output lane it evaluates the composite magnitude, on a 1/48-octave grid from 10 Hz to
 * 0.45 fs, of everything that can reach that lane, for a full-scale input on every source, and returns the peak
 * gain, the frequency of the peak and the true-peak margin. The caller (Swift, E9 S7) fills the description from
 * the stage descriptors it already publishes.
 *
 * Model. An output has one or more paths (a program lane, or each lane a bass manager redirects into a sub) and an
 * optional tail chain after the sum (sub EQ, output gain). Each path is a chain of stages with a complex response
 * (so delay and polarity count). Paths add as their combine mode says (owner Q3): COHERENT paths add as complex
 * numbers (the front pair of a stereo bass sum: +6.02 dB for two identical lanes); POWER paths add as power
 * (uncorrelated redirected lanes: +3.01 dB for two equal lanes). The Strict option makes every path coherent. The
 * sum is sqrt(|sum of coherent responses|^2 + sum of |power responses|^2).
 *
 * Stages. GAIN (signed linear gain; negative is polarity), PEQ (graph types 0..7, 4 params per section), BIQUAD
 * (raw coefficients, for crossovers), DELAY (integer frames), FIR (any convolver stage: program, room, speaker IR,
 * driver; direct DFT of the taps, so any length to 262,144), DYN_EQ (graph parameter layout, each band at its
 * maximum static plus boost gain; a tilt band is a low shelf at -g/2 and a high shelf at +g/2), COMPRESSOR (its
 * make-up gain: the gain when the signal is below threshold). Anything else is not modelled and has unity gain,
 * so the caller must not pass a stage that can add level without describing it.
 *
 * True-peak margin. A sample-peak of 0 dBFS can read up to +0.5 dB at 4x oversampling, so a lane needs
 * peak + 0.5 dB of headroom against its ceiling. required_trim_db is that need, clamped at 0 (never boosts).
 */
#ifndef N60_HEADROOM_H
#define N60_HEADROOM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_HEADROOM_ABI_VERSION 3 /* 3 (E19 S5): MIMO term and budget; 2 (E9 S7b): N60_HEADROOM_STAGE_LINKWITZ */

#define N60_HEADROOM_OK 0
#define N60_HEADROOM_ERR_ARGUMENT (-1) /* null pointer, bad struct size, bad rate or count */
#define N60_HEADROOM_ERR_STAGE (-2)    /* unknown stage kind, bad parameter count or a non-finite value */
#define N60_HEADROOM_ERR_ALLOC (-3)

#define N60_HEADROOM_TRUE_PEAK_MARGIN_DB 0.5
#define N60_HEADROOM_GRID_STEPS_PER_OCTAVE 48u
#define N60_HEADROOM_MIN_HZ 10.0
#define N60_HEADROOM_MAX_FRACTION 0.45 /* of the sample rate */

#define N60_HEADROOM_STAGE_GAIN 1u     /* params[0] = linear gain (negative inverts polarity); count 1 */
#define N60_HEADROOM_STAGE_PEQ 2u      /* 4 per section: type 0..7, Hz, dB, Q; count 4..64 */
#define N60_HEADROOM_STAGE_BIQUAD 3u   /* 5 per section: b0 b1 b2 a1 a2 (a0 = 1), cascade; count 5..40 */
#define N60_HEADROOM_STAGE_DELAY 4u    /* params[0] = frames (>= 0); count 1 */
#define N60_HEADROOM_STAGE_FIR 5u      /* taps (floats) in the `taps` pointer; tap_count 1..262144 */
#define N60_HEADROOM_STAGE_DYN_EQ 6u   /* params as the graph's Dynamic EQ: [0] linked, then 15 per band; 16, 31, ... */
#define N60_HEADROOM_STAGE_LINKWITZ 8u /* params f0 Hz, Q0, fp Hz, Qp (the XOVER stage's transform, designed in double); count 4 */
#define N60_HEADROOM_STAGE_COMPRESSOR 7u /* graph Compressor params; uses [5] make-up dB; count >= 6 */

#define N60_HEADROOM_COMBINE_COHERENT 0u
#define N60_HEADROOM_COMBINE_POWER 1u

#define N60_HEADROOM_MAX_FIR_TAPS 262144u
#define N60_HEADROOM_MAX_PARAMS 1024u

typedef struct n60_headroom_stage {
    uint32_t kind;        /* N60_HEADROOM_STAGE_* */
    uint32_t param_count;
    const float *params;  /* param_count floats */
    uint32_t tap_count;   /* FIR only */
    const float *taps;    /* FIR only */
} n60_headroom_stage;

typedef struct n60_headroom_path {
    uint32_t combine;     /* N60_HEADROOM_COMBINE_* */
    uint32_t stage_count;
    const n60_headroom_stage *stages;
} n60_headroom_path;

typedef struct n60_headroom_output {
    uint32_t struct_size; /* sizeof(n60_headroom_output) */
    double sample_rate;   /* 8000..768000 */
    uint32_t strict;      /* 1: every path adds coherently (worst case) */
    uint32_t path_count;  /* 1..64 */
    const n60_headroom_path *paths;
    uint32_t tail_stage_count; /* stages after the sum, 0..64 */
    const n60_headroom_stage *tail_stages;
    double ceiling_db;    /* the lane's ceiling in dBFS, normally <= 0 */
} n60_headroom_output;

typedef struct n60_headroom_result {
    uint32_t struct_size;    /* sizeof(n60_headroom_result); set by the caller */
    double peak_gain_db;     /* highest composite gain on the grid */
    double peak_hz;          /* where it occurs */
    double true_peak_margin_db; /* N60_HEADROOM_TRUE_PEAK_MARGIN_DB */
    double required_trim_db; /* max(0, peak + margin - ceiling_db): the attenuation that keeps a full-scale input under the ceiling */
    uint32_t grid_points;
} n60_headroom_result;

uint32_t n60_headroom_abi_version(void);

/* Evaluates one output. Control or worker thread only. */
int n60_headroom_evaluate(const n60_headroom_output *output, n60_headroom_result *result);

/*
 * MIMO term (E19 S5, design note 6). The MIMO stage (graph kind N60_STAGE_MIMO, `n60/graph.h`) sends program
 * source s through y_s = x_s z^-L + delta_s; for a full-scale input on every source the worst gain of row s is
 *     G_s(f) = sum over t of | E_st(f) + [t == s] e^(-j 2 pi f tau) |,
 * the same sum the design checks (`n60_mimo_info.peak_gain_db`, `n60_mimo_realisation.gain_peak_db`), here evaluated
 * on the stage's own published parameters so the headroom model and the stage cannot disagree. `params` is the
 * stage's parameter array in the graph layout (8 + S + S*S*T floats: D, T, S, tauFrames, ..., bounds, taps) and
 * `sample_rate` the graph rate. The grid is 0.25 Hz from 5 Hz to min(0.4 fs/D, 1,000 Hz); above it the delta is
 * zero and the gain is 1, so the result is never below 0 dB. Control or worker thread only; allocates nothing.
 * Returns N60_HEADROOM_OK, or N60_HEADROOM_ERR_ARGUMENT for a null pointer, bad source, rate or layout.
 */
int n60_headroom_mimo_term(double sample_rate, const float *params, uint32_t param_count, uint32_t source,
                           double *peak_gain_db, double *peak_hz);

/*
 * The gain budget of a MIMO source (dB re 1): the most the MIMO row's peak gain may reach. With `chain_peak_db` the
 * peak composite gain of everything after the stage on that output (`n60_headroom_evaluate` with the stage left out),
 * a full-scale input reaches the ceiling when row gain + chain peak + N60_HEADROOM_TRUE_PEAK_MARGIN_DB = ceiling_db.
 * The treatment may cost the program up to `trim_allowance_db` of output trim (the headroom assistant's Apply, E9 S7;
 * 3 dB by default, `N60_HEADROOM_MIMO_TRIM_ALLOWANCE_DB`), so
 *     budget = ceiling_db - N60_HEADROOM_TRUE_PEAK_MARGIN_DB - chain_peak_db + trim_allowance_db.
 * Pass it as the source's `gain_limit_db` in `n60_mimo_problem`; the design re-solves with more regularisation (at most
 * 4 steps) and then refuses by name. A budget below 0 dB means even the untreated path does not fit.
 */
#define N60_HEADROOM_MIMO_TRIM_ALLOWANCE_DB 3.0
double n60_headroom_mimo_budget_db(double ceiling_db, double trim_allowance_db, double chain_peak_db);

#ifdef __cplusplus
}
#endif

#endif
