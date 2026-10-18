#ifndef N60Fxlms_h
#define N60Fxlms_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__clang__)
#define N60_FXLMS_NONNULL _Nonnull
#define N60_FXLMS_NULLABLE _Nullable
#else
#define N60_FXLMS_NONNULL
#define N60_FXLMS_NULLABLE
#endif

/*
 * E4 S5: adaptive speaker-ANC core (filtered-x LMS). C interface over a C++20
 * core (n60_fxlms.cpp). Not wired into the render kernel yet; S6 wires the
 * tonal core behind the e4.adaptive-anc flag, with the howl guard
 * (N60AncGuard.h) after its output.
 *
 * Design (docs/epics/E4.md, design decisions 1-3):
 *  - Filter at the native rate, adapt off the audio thread. The realtime side
 *    synthesises the anti-noise and hands error and probe samples to a worker
 *    through a lock-free ring. The worker decimates them, adapts, and
 *    publishes new weights through a lock-free triple buffer. The adaptation
 *    itself costs the same per second at every rate; the two decimators cost
 *    about 32 multiply-adds per native frame (25 M/s on the worker at 768 kHz).
 *    Valid for 8 kHz to 768 kHz; below 24 kHz fd lies between 4 and 8 kHz.
 *  - Decimation: factor D = floor(fs / 4000), so the adaptation rate
 *    fd = fs / D is 4000 Hz (48 kHz family) or 4009.09 Hz (44.1 kHz family).
 *    Filter: L = 16 D + 1 taps, h[i] = 2 fc sinc(2 fc (i - 8 D)) w[i] with
 *    fc = 0.3 / D cycles per sample and the Blackman window
 *    w[i] = 0.42 - 0.5 cos(2 pi i / (L - 1)) + 0.08 cos(4 pi i / (L - 1)),
 *    scaled to unity DC gain (cutoff 0.3 fd, about 1.2 kHz). Linear phase,
 *    delay 8 D native frames (2 ms).
 *  - Narrowband FxLMS (Kuo and Morgan, Active Noise Control Systems, 1996,
 *    ch. 4), one complex weight W per tone. Anti-noise at native frame n:
 *        y[n] = sum_k Re(W_k exp(j 2 pi f_k n / fs)).
 *    Per decimated error sample e (native frame n), with S_k the secondary-path
 *    estimate at f_k and the decimator delay G = 8 D compensated:
 *        W_k <- (1 - lambda / fd) W_k
 *               - 2 / (tau fd |S_k|^2) e conj(S_k) exp(-j 2 pi f_k (n - G) / fs).
 *    With an exact path estimate the weight error decays as exp(-t / tau), and
 *    the fixed point is W_k = -D_k / (S + lambda tau S_k) for a disturbance
 *    Re(D_k exp(j 2 pi f_k n / fs)) and true path S. A tone adapts only while
 *    |S_k| >= pathFloor and, with the probe on, once the path model has had
 *    three path convergence times since the last reset. Each |W_k| is held to the per-tone cap and sum |W_k|
 *    to the aggregate cap (today's tonal caps, -24 and -18 dBFS).
 *    Step limit: tau >= 0.1 s. The mean loop dW/dt = -(S / S_k) W(t - d) / tau
 *    stays stable while d / tau < pi / 2 - |arg(S / S_k)|, so tau = 0.1 s
 *    holds for loop delays d up to 50 ms with path phase errors up to 60 deg.
 *  - Online secondary-path model by auxiliary noise (Eriksson and Allie, 1989;
 *    Kuo and Morgan ch. 3): a low-level probe, white noise through a 400 Hz
 *    second-order Butterworth low-pass scaled to probeLevelDBFS RMS, is added
 *    to the output. An NLMS FIR of pathTaps taps at fd regresses the error on
 *    the probe, both first notched at every tone (pole radius exp(-pi 10 / fd))
 *    so the tones do not swamp the probe. Step mu = pathTaps / (T fd) for a
 *    path convergence time T. S_k is the FIR's response at f_k, refreshed every
 *    16 decimated samples. With the probe off, S_k is the fixed tone seed.
 *    The model spans pathTaps / fd (16 ms at 64 taps, 32 ms at 128): the whole
 *    loop delay (output latency, acoustics, input latency) must fit inside
 *    it, which S6 checks against the measured round trip. The decimated error
 *    is clamped to +/-8, and a non-finite path or weight resets the model
 *    (counted in modelResets).
 *  - Block FxLMS for FIR weights (S9 wires it): normalised and leaky,
 *        w <- (1 - lambda B / fs) w - mu / (B N (P + 1e-8)) sum_block e x'
 *    with x' the reference through the path estimate and P a running mean of
 *    x'^2 over N samples. The 1e-8 floor (-80 dBFS) keeps the step bounded
 *    when the reference is near silent. Step limit mu <= 0.5. Leakage biases
 *    the converged weights by roughly lambda N / (mu fs) of their size, so a
 *    small step needs a small leakage.
 *
 * Realtime behaviour (N60AdaptiveTonal):
 *  - Allocation: Create allocates the ring and buffers once. Process, Service,
 *    RequestReset and ReadStatus never allocate.
 *  - Synchronisation: lock-free. One realtime thread calls Process; one worker
 *    thread calls Service; one thread (any) calls ReadStatus. RequestReset is
 *    any thread.
 *  - Latency: none added to the output. The adaptation loop sees a chunk
 *    (16 decimated samples, 4 ms), the decimator delay (2 ms), worker
 *    scheduling and one realtime buffer (weights are cross-faded over the
 *    buffer that first reads them).
 *  - Sample rate: fixed per core, 8 kHz to 768 kHz. A rate change needs a new
 *    core.
 *  - Channels: one output channel and one error microphone per core.
 *  - Reset: RequestReset zeroes weights and the path model at the worker's
 *    next Service. A ring overflow drops whole chunks; the worker then
 *    restarts its filters (not the weights) and counts a gap. The caller must
 *    call MarkDiscontinuity after any break in the audio (stop/start, HAL
 *    overload, device change at the same rate) so the worker never adapts
 *    across it.
 * The Block FxLMS and Decimator objects are worker-side only: one thread, no
 * realtime use.
 */

#define N60_FXLMS_MAX_TONES 4u
#define N60_FXLMS_MAX_PATH_TAPS 128u
#define N60_FXLMS_MAX_BLOCK_TAPS 512u
#define N60_FXLMS_MIN_CONVERGENCE_SECONDS 0.1
#define N60_FXLMS_MAX_BLOCK_STEP 0.5f

typedef struct {
    float re;
    float im;
} N60AncComplex;

/* Decimator ---------------------------------------------------------------- */

/// D = floor(fs / 4000), or 0 outside 8 kHz to 768 kHz.
uint32_t N60AncDecimationFactor(double sampleRate);
/// Group delay of the decimation filter, native frames (8 D).
uint32_t N60AncDecimatorDelayFrames(double sampleRate);

typedef struct N60AncDecimator N60AncDecimator;
N60AncDecimator * N60_FXLMS_NULLABLE N60AncDecimatorCreate(double sampleRate);
void N60AncDecimatorDestroy(N60AncDecimator * N60_FXLMS_NULLABLE decimator);
/// Emits one output for every D inputs (the first after D inputs). Returns the
/// number written, at most capacity.
uint32_t N60AncDecimatorProcess(
    N60AncDecimator * N60_FXLMS_NONNULL decimator,
    const float * N60_FXLMS_NONNULL input,
    uint32_t frames,
    float * N60_FXLMS_NONNULL output,
    uint32_t capacity
);

/* Adaptive tonal canceller ------------------------------------------------- */

typedef struct {
    double sampleRate;
    uint32_t toneCount;                    /* 0 to 4 */
    float toneHz[N60_FXLMS_MAX_TONES];     /* 20 to 150 Hz */
    /// Weight convergence time constant tau, s (default 0.25, minimum 0.1).
    double convergenceSeconds;
    /// Leakage lambda, 1/s (default 0.01, 0 to 10).
    double leakagePerSecond;
    float toneCapDBFS;                     /* default -24 */
    float aggregateCapDBFS;                /* default -18 */
    /// Secondary-path estimate used when the probe is off.
    N60AncComplex toneSeed[N60_FXLMS_MAX_TONES];
    float pathFloor;                       /* default 1e-3 */
    bool probeEnabled;                     /* default false */
    /// Shadow mode (S6): the output is not played, so adapt on the virtual
    /// error e + sum_k Re(S_k W_k exp(j 2 pi f_k (n - G) / fs)). Requires the
    /// probe off (the probe is output; ConfigIsValid rejects both). Process
    /// still writes the output; the caller meters and discards it.
    bool shadow;
    float probeLevelDBFS;                  /* default -50, -90 to -40 */
    uint64_t probeSeed;
    uint32_t pathTaps;                     /* default 64, 8 to 128 */
    /// Path convergence time T, s (default 0.5); pathTaps / (T fd) <= 0.5.
    double pathConvergenceSeconds;
    /// Ring length, s (default 0.25, 0.05 to 2).
    double ringSeconds;
} N60AdaptiveTonalConfig;

typedef struct {
    /// Increments with every worker publish.
    uint64_t sequence;
    uint64_t decimatedSamples;
    uint64_t gaps;
    uint64_t droppedFrames;
    /// Times a non-finite path or weight forced a model reset.
    uint64_t modelResets;
    N60AncComplex weight[N60_FXLMS_MAX_TONES];
    N60AncComplex path[N60_FXLMS_MAX_TONES];
    bool adapting[N60_FXLMS_MAX_TONES];
    /// Complex tone amplitude at the microphone (0.5 s one-pole average of
    /// 2 e exp(-j phase), valid once the decimator has warmed up), as
    /// measured and as predicted with the adaptive output. Equal unless
    /// shadowed. Other tones beat in at |f_j - f_k|: about 6% ripple at 5 Hz
    /// spacing, so read them as levels for well-separated tones.
    N60AncComplex measuredTone[N60_FXLMS_MAX_TONES];
    N60AncComplex predictedTone[N60_FXLMS_MAX_TONES];
} N60AdaptiveTonalStatus;

typedef struct N60AdaptiveTonal N60AdaptiveTonal;

N60AdaptiveTonalConfig N60AdaptiveTonalConfigDefault(double sampleRate);
bool N60AdaptiveTonalConfigIsValid(const N60AdaptiveTonalConfig * N60_FXLMS_NONNULL config);
/// Control plane. NULL for an invalid configuration or no memory.
N60AdaptiveTonal * N60_FXLMS_NULLABLE N60AdaptiveTonalCreate(
    const N60AdaptiveTonalConfig * N60_FXLMS_NONNULL config
);
/// Control plane, after Process and Service have stopped.
void N60AdaptiveTonalDestroy(N60AdaptiveTonal * N60_FXLMS_NULLABLE core);

/// Realtime. Writes anti-noise (tones plus probe) to output and queues the
/// error and probe samples for the worker. A non-finite error sample is
/// queued as zero (the howl guard reports it).
void N60AdaptiveTonalProcess(
    N60AdaptiveTonal * N60_FXLMS_NONNULL core,
    const float * N60_FXLMS_NONNULL error,
    float * N60_FXLMS_NONNULL output,
    uint32_t frames
);
/// Worker. Adapts on everything queued and publishes. Returns the number of
/// decimated samples used.
uint32_t N60AdaptiveTonalService(N60AdaptiveTonal * N60_FXLMS_NONNULL core);
/// Any thread.
void N60AdaptiveTonalRequestReset(N60AdaptiveTonal * N60_FXLMS_NONNULL core);
/// Any thread. The next Process starts a fresh chunk after a frame gap, so
/// the worker restarts its filters instead of adapting across the break.
void N60AdaptiveTonalMarkDiscontinuity(N60AdaptiveTonal * N60_FXLMS_NONNULL core);
/// One status-reader thread. The latest published status.
N60AdaptiveTonalStatus N60AdaptiveTonalReadStatus(N60AdaptiveTonal * N60_FXLMS_NONNULL core);

/* Block FxLMS (worker side) ------------------------------------------------ */

typedef struct {
    /// Rate of the sequences given to Update (normally fd).
    double sampleRate;
    uint32_t taps;                         /* 1 to 512, default 64 */
    uint32_t blockFrames;                  /* 1 to 1024, default 32 */
    float step;                            /* (0, 0.5], default 0.1 */
    double leakagePerSecond;               /* 0 to 10, default 0.01 */
} N60BlockFxlmsConfig;

typedef struct N60BlockFxlms N60BlockFxlms;

N60BlockFxlmsConfig N60BlockFxlmsConfigDefault(double sampleRate);
bool N60BlockFxlmsConfigIsValid(const N60BlockFxlmsConfig * N60_FXLMS_NONNULL config);
N60BlockFxlms * N60_FXLMS_NULLABLE N60BlockFxlmsCreate(
    const N60BlockFxlmsConfig * N60_FXLMS_NONNULL config
);
void N60BlockFxlmsDestroy(N60BlockFxlms * N60_FXLMS_NULLABLE fxlms);
/// Secondary-path estimate, at most 128 taps. False if count is out of range.
bool N60BlockFxlmsSetPath(
    N60BlockFxlms * N60_FXLMS_NONNULL fxlms,
    const float * N60_FXLMS_NONNULL taps,
    uint32_t count
);
/// reference: the reference microphone; error: the residual, same frames.
void N60BlockFxlmsUpdate(
    N60BlockFxlms * N60_FXLMS_NONNULL fxlms,
    const float * N60_FXLMS_NONNULL reference,
    const float * N60_FXLMS_NONNULL error,
    uint32_t frames
);
/// Copies min(count, taps) weights.
void N60BlockFxlmsCopyWeights(
    const N60BlockFxlms * N60_FXLMS_NONNULL fxlms,
    float * N60_FXLMS_NONNULL weights,
    uint32_t count
);
/// Seeds min(count, taps) weights; the rest are zeroed.
void N60BlockFxlmsSetWeights(
    N60BlockFxlms * N60_FXLMS_NONNULL fxlms,
    const float * N60_FXLMS_NONNULL weights,
    uint32_t count
);

/* Feed-forward shadow (E4 S9, worker side) ---------------------------------- */

/*
 * Broadband feed-forward canceller in shadow mode (n60_ff_shadow.cpp): one
 * reference microphone, two outputs (left, right) and one error microphone,
 * the 1 x 2 x 1 multichannel FxLMS (Kuo and Morgan 1996, ch. 5) built from
 * two block FxLMS cores that share one error. Nothing it computes is played.
 *  - Both microphones (same device, same clock) are decimated at the native
 *    rate by the decimator above to fd ~ 4 kHz, then band-limited by the same
 *    filter: a fourth-order Linkwitz-Riley high-pass at bandLowHz and
 *    low-pass at bandHighHz, each two cascaded second-order Butterworth
 *    sections (RBJ Audio EQ Cookbook, Q = 1 / sqrt 2; -6 dB at the corner).
 *    Microphone samples are clamped to +/-8 first.
 *    Filtering both commutes with every linear path, so the weights minimise
 *    the band-limited error only. Fourth order keeps the weakly excited skirts,
 *    which adapt slowly, from holding up the residual.
 *  - Per decimated sample n, with x the band-limited reference, e the
 *    band-limited error, W_c the weights and S_c = z^-delta_c s_c the path
 *    estimates (bulk delay plus up to 128 taps):
 *        y_c[n] = sum_k W_c[k] x[n - k]
 *        e_v[n] = e[n] + sum_c sum_j s_c[j] y_c[n - delta_c - j]
 *    and core c updates on reference x[n - delta_c], path s_c and error e_v
 *    (the virtual error: what the microphone would hear if y were played).
 *    e_v is clamped to +/-8.
 *  - At every block boundary (when the weights change), each channel's
 *    sum |W_c| (a bound on its peak gain) is held to peakGainLimit by scaling
 *    (counted in gainLimited); a non-finite weight restores the seed (counted
 *    in modelResets).
 *  - Meters: one-pole 0.5 s mean squares of e, e_v and y_c.
 *  - Step: per channel at most 0.25, so the two channels together stay within
 *    the block core's 0.5. The default (0.05 with 8-sample blocks) costs
 *    about 0.2 dB of misadjustment over the noise floor with an 8-sample path
 *    delay; 0.2 costs about 1 dB but converges four times faster.
 * Realtime behaviour: worker side only, one thread for every call. Create
 * allocates; nothing else does. Latency: none (no output). Sample rate fixed
 * per object, 8 kHz to 768 kHz native; a rate change needs a new object.
 * Reset: Reset (and SetSeed) restores the seed weights, clears the meters and
 * restarts the filters; MarkDiscontinuity restarts the filters and histories
 * only (weights and meters kept) and counts a gap.
 * Call it after any break in either microphone stream.
 */

#define N60_FF_SHADOW_MAX_BULK_DELAY 512u
#define N60_FF_SHADOW_MAX_STEP 0.25f

typedef struct {
    double sampleRate;                     /* native, 8 kHz to 768 kHz */
    uint32_t taps;                         /* at fd, 1 to 512, default 128 */
    uint32_t blockFrames;                  /* at fd, 1 to 1024, default 8 */
    float step;                            /* per channel, (0, 0.25], default 0.05 */
    double leakagePerSecond;               /* 0 to 10, default 0.01 */
    float bandLowHz;                       /* 10 to 100, default 20 */
    float bandHighHz;                      /* 2 bandLowHz to 0.25 fd, default 200 */
    /// Sum |W_c| per channel, (0, 16]; default 0.0631 (-24 dB), the offline
    /// compiler's limit.
    float peakGainLimit;
} N60FeedForwardShadowConfig;

typedef struct {
    double decimatedRate;
    uint64_t decimatedSamples;
    /// Decimated samples adapted since the last restart (gap, reset, create).
    uint64_t samplesSinceRestart;
    uint64_t gaps;
    uint64_t modelResets;
    uint64_t gainLimited;
    /// Mean squares at fd: band-limited error microphone, virtual error, and
    /// each shadow output.
    float measuredPower;
    float predictedPower;
    float outputPower[2];
    float weightGain[2];                   /* sum |W_c| */
} N60FeedForwardShadowStatus;

typedef struct N60FeedForwardShadow N60FeedForwardShadow;

N60FeedForwardShadowConfig N60FeedForwardShadowConfigDefault(double sampleRate);
bool N60FeedForwardShadowConfigIsValid(
    const N60FeedForwardShadowConfig * N60_FXLMS_NONNULL config
);
N60FeedForwardShadow * N60_FXLMS_NULLABLE N60FeedForwardShadowCreate(
    const N60FeedForwardShadowConfig * N60_FXLMS_NONNULL config
);
void N60FeedForwardShadowDestroy(N60FeedForwardShadow * N60_FXLMS_NULLABLE shadow);
/// channel 0 = left, 1 = right. Path at fd: bulkDelay (0 to 512) decimated
/// samples, then count (1 to 128) taps. Default: no delay, one unit tap.
/// Restarts the filters. False if out of range.
bool N60FeedForwardShadowSetPath(
    N60FeedForwardShadow * N60_FXLMS_NONNULL shadow,
    uint32_t channel,
    uint32_t bulkDelay,
    const float * N60_FXLMS_NONNULL taps,
    uint32_t count
);
/// Seeds both channels with min(count, taps) weights (the rest zero), keeps
/// them for Reset, and restarts the filters. False if a weight is non-finite.
bool N60FeedForwardShadowSetSeed(
    N60FeedForwardShadow * N60_FXLMS_NONNULL shadow,
    const float * N60_FXLMS_NONNULL left,
    const float * N60_FXLMS_NONNULL right,
    uint32_t count
);
/// Native-rate frames from the two microphones, sample-aligned. Non-finite
/// samples count as zero.
void N60FeedForwardShadowProcess(
    N60FeedForwardShadow * N60_FXLMS_NONNULL shadow,
    const float * N60_FXLMS_NONNULL reference,
    const float * N60_FXLMS_NONNULL error,
    uint32_t frames
);
void N60FeedForwardShadowMarkDiscontinuity(N60FeedForwardShadow * N60_FXLMS_NONNULL shadow);
void N60FeedForwardShadowReset(N60FeedForwardShadow * N60_FXLMS_NONNULL shadow);
N60FeedForwardShadowStatus N60FeedForwardShadowReadStatus(
    const N60FeedForwardShadow * N60_FXLMS_NONNULL shadow
);
/// Copies min(count, taps) weights of one channel.
void N60FeedForwardShadowCopyWeights(
    const N60FeedForwardShadow * N60_FXLMS_NONNULL shadow,
    uint32_t channel,
    float * N60_FXLMS_NONNULL weights,
    uint32_t count
);

#ifdef __cplusplus
}
#endif

#endif
