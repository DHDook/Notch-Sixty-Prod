#ifndef N60RemoteTonal_h
#define N60RemoteTonal_h

#include <stdbool.h>
#include <stdint.h>

#include "N60ActiveQuietZone.h"
#include "N60Fxlms.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * E4 S18a: remote adaptive tonal canceller (n60_remote_tonal.cpp). Worker side only.
 *
 * The S6 core (N60AdaptiveTonal) makes its own tone phase from its frame counter and assumes
 * the error microphone shares the output's sample clock and arrives without delay. This core is
 * the same narrowband FxLMS for the live path, where the render thread plays fixed complex L/R
 * gains per tone through the Quiet Zone runtime (N60ActiveQuietZone.h) and the microphone
 * arrives in 250 ms polls from another device with its own clock. Instead of an oscillator it
 * takes, per microphone block:
 *   - the host time of the block's first frame (the ambient-monitor anchor), and
 *   - the render thread's telemetry (host time, tone phasor, complex gain playing, every 5 ms),
 * and maps each microphone sample to the phasor and gain the kernel played at that host time.
 * Host time is common to both devices, so there is no unknown phase offset and no drift
 * between the clocks beyond the microphone's own deviation from nominal over one block
 * (100 ppm over 250 ms is 1.4 degrees at 150 Hz).
 *
 * Maths (one complex weight W per tone; the L/R split is the fixed complex share pair, so the
 * gain playing is G_L = W s_L and G_R = W s_R, and S is the speaker-to-microphone response of
 * that split, S = S_L s_L + S_R s_R):
 *  - Demodulation. For a block of N samples x[n] with Hann window w[n], phasor p[n] = exp(j phi[n])
 *    the kernel played at the sample's host time, the complex tone at the microphone relative to
 *    the kernel's phasor is  M = 2 sum w x conj(p) / sum w  and the window-mean gain playing
 *    is  Gbar = sum w G / sum w  (G = the W-equivalent of the gain record,
 *    (conj(s_L) G_L + conj(s_R) G_R) / (|s_L|^2 + |s_R|^2)). Gains are looked up at the sample's
 *    time minus loopDelaySeconds (the speaker-to-microphone latency; default 0).
 *  - Modified FxLMS (Bjarnason, "Analysis of the filtered-X LMS algorithm", IEEE Trans. Speech
 *    Audio Process. 3(6), 1995; the error re-referenced to the current weight is the "modified"
 *    form of Kuo and Morgan, Active Noise Control Systems, 1996, sec. 4.5):
 *        e_v = M - Shat (Gbar - W)            (the error as if W had been playing)
 *        W  <- (1 - lambda dt) W - a e_v / Shat,   a = 1 - exp(-dt / tau)
 *    for a block of dt seconds. With M = D + S Gbar this is e_v = D + S Gbar - Shat (Gbar - W),
 *    so a stationary tone disturbance D gives the fixed point (Gbar = W, no dither)
 *        W = -a D / (lambda dt Shat + a S)  ->  -D / (S + lambda tau Shat)   for small dt,
 *    independent of how late the microphone block arrives: the delay is in M and Gbar, not in
 *    the loop. A tone adapts only while |Shat| >= pathFloor and the block is covered by
 *    telemetry. |W s| is held to the per-tone cap and the sum over tones to the aggregate cap
 *    (-24 and -18 dBFS), and to the caller's attempt cap.
 *  - Gain dither (per-tone form of the auxiliary-noise method, Eriksson and Allie, 1989). The
 *    record handed out multiplies each W by a pseudo-random factor (default +-0.5 dB,
 *    +-3 degrees, new every 0.5 s, xorshift64* from ditherSeed). Per tone the model
 *        M = D + S Gbar
 *    is fitted per tone by a two-state Kalman filter over (D, S), each a random walk: D (a
 *    disturbance that drifts) has the larger process noise, S (the path) the smaller, so a moving
 *    disturbance does not leak into S when the gain barely varies. S is Shat. S's variance is
 *    capped at (0.5 |seed|)^2 and re-opened when two blocks in a row are 6 sigma off. Shat starts
 *    at pathSeed.
 *  - Mic-moved detector. Compared with the reference path (the seed, or the estimate when
 *    CaptureReference is called): a tone is "off" when |arg(Shat / Sref)| > 30 degrees or
 *    |20 log10 |Shat / Sref|| > 3 dB; any tone off for 1 s continuously (kind 1), or two or more
 *    tones whose path moved 15 degrees or more within 2 s or whose fitted disturbance turned 25
 *    degrees or more within 1 s (kind 2), latches MicMoved (a pure flag; the controller decides
 *    what to do) until AcknowledgeMove. Limit: a move that turns the disturbance and the path
 *    together leaves the cancelling weight unchanged and the cancelled loop hides it; it is
 *    harmless to the canceller and is not flagged until the path is excited.
 *  - Re-identification (BeginReidentify): faster path memory (0.5 s) and dither raised to
 *    +-1.5 dB, +-9 degrees, until EndReidentify.
 *  - Slew: a record's W-equivalent is limited to slewDB and slewDegrees from the gain playing
 *    now (the newest telemetry record), so adaptation stays well below the kernel guard's
 *    growth trip (6 dB per 20 ms). 0 disables a limit.
 *
 * Frequency tracking (E4 S19). A fan, compressor or pump drifts; the kernel's tone follows it
 * phase-continuously (N60ActiveQuietZone.h glide). Each tone's instantaneous disturbance estimate
 * Dm = M - Shat Gbar is a phasor relative to the kernel's, so it turns at (f_d - f_k) cycles per
 * second. A second-order phase-locked loop per tone (critically damped, loop noise bandwidth
 * trackBandwidthHz, default 0.5 Hz; Gardner, Phaselock Techniques, 3rd ed., 2005, ch. 2 and 4)
 * locks to arg(Dm) once per block: phase error e = wrap(arg Dm - pred),
 *     theta <- pred + kp e,    df <- df + ki e / (2 pi dt),    pred = theta + 2 pi df dt,
 * kp = 2 zeta wn dt, ki = (wn dt)^2, wn = 8 zeta BL / (4 zeta^2 + 1), zeta = 0.707. df is the
 * estimated disturbance-minus-kernel frequency. The suggested kernel frequency is the current one
 * plus df, limited to frequencySlewPerSecond of the frequency per second and to the tracking
 * range (+-trackRangeFraction of the armed frequency). The caller applies it with
 * N60RemoteTonalSetToneFrequency, which keeps the weight (the cancelling phasor is in the
 * kernel's frame, so a continuous retune leaves it valid) and carries the tracked path over.
 * Unambiguous only while |df| < 1 / (2 block seconds) (2 Hz for 250 ms blocks), far above the
 * slew limit. Tracking is declared lost (latched) when the requested offset stays outside the
 * range for 3 blocks, the loop stays unlocked (|e| > 1.2 rad) for 12 blocks, or the disturbance
 * estimate stays 12 dB under its recent peak for 6 s (the tone jumped out of range or stopped).
 *
 * Programme removal (E4 S22). Records without a programme mean (first record of a tone, after a
 * reset, non-finite) are left out of the window average, not counted as silence. The kernel's
 * mean is rectangular over the inter-record interval, so music a little off the tone leaks in as
 * a small bias (not a whole number of cycles); the verifier's 6 dB rule keeps that harmless.
 * Music plays through the same speakers and paths as the anti-noise,
 * so at a tone frequency it reaches the microphone as P_mic = S_L P_L + S_R P_R, with P_c the
 * programme's tone on channel c (the same complex amplitude convention as the gain: peak
 * amplitude relative to the kernel phasor). The kernel demodulates the programme feeds with the
 * tone oscillator (one multiply-add per channel per tone per frame) and reports the means in the
 * telemetry; the core forms the window mean P_c the way it does Gbar and subtracts
 * M <- M - Shat (rho_L P_L + rho_R P_R) before the path fit, the weight update, the frequency
 * loop and the mic-moved check, rho_c = S_c / S from the per-channel seeds, so music adds path
 * excitation instead of bias. The path used is the reference path (the seed, or the estimate when
 * CaptureReference was last called), not the running fit: subtracting the fit would feed the fit's
 * own change back into the disturbance it is separating from the path, and the loop diverges
 * (found in the S22 harness). A path that has moved since the reference leaves a residual
 * (S - Sref) P in the disturbance, which the mic-moved check and re-solve then own. A record's means cover
 * the frames since the previous record and are looked up like the gain, one loop delay earlier;
 * the offset (at most a callback) matters only for programme that changes within a few ms.
 * Off by default.
 *
 * Realtime behaviour: worker side only, one thread for every call. Create allocates; nothing
 * else does. Latency: none (no audio is passed through). Sample rate: the microphone's, any
 * (8 kHz to 768 kHz); the output rate does not enter. Channels: one microphone, stereo output
 * through the shares. Reset: Reset restores the seeds; MarkDiscontinuity drops history and
 * holds the weights (counted in gaps); a tone, rate or device change needs a new core.
 */

#define N60_REMOTE_TONAL_HISTORY 2048u

typedef struct {
    double micSampleRate;                 /* nominal, 8 kHz to 768 kHz */
    /// mach_timebase-derived host ticks per second (1e9 on Apple Silicon is not guaranteed).
    double hostTicksPerSecond;
    uint32_t toneCount;                   /* 1 to 4 */
    float toneHz[N60_FXLMS_MAX_TONES];
    /// Fixed complex L/R split of W (gain = W * share).
    N60AncComplex leftShare[N60_FXLMS_MAX_TONES];
    N60AncComplex rightShare[N60_FXLMS_MAX_TONES];
    /// Secondary path of the split at each tone (the offline path) and the starting weight.
    N60AncComplex pathSeed[N60_FXLMS_MAX_TONES];
    N60AncComplex weightSeed[N60_FXLMS_MAX_TONES];
    double convergenceSeconds;            /* tau, default 1, minimum 0.1 */
    double leakagePerSecond;              /* default 0.002 (fixed point short of -D/S by lambda tau) */
    float pathFloor;                      /* default 1e-3 */
    float toneCapDBFS;                    /* default -24 */
    float aggregateCapDBFS;               /* default -18 */
    double loopDelaySeconds;              /* default 0 */
    uint64_t ditherSeed;
    float ditherDB;                       /* default 0.5 */
    float ditherDegrees;                  /* default 3 */
    double ditherPeriodSeconds;           /* default 0.5 */
    double pathMemorySeconds;             /* default 2 */
    /// Assumed microphone noise (amplitude, demodulated) for the path fit; default 1e-5.
    double measurementNoise;
    float slewDB;                         /* default 1.5; 0 = off */
    float slewDegrees;                    /* default 10; 0 = off */
    /// E4 S19 frequency tracking.
    double trackBandwidthHz;              /* PLL loop noise bandwidth, default 0.5, 0.05 to 2 */
    double frequencySlewPerSecond;        /* fraction of the frequency per second, default 0.005 */
    double trackRangeFraction;            /* around the armed frequency, default 0.10, 0 = fixed */
    /// E4 S22 programme removal. When true the core takes the programme (the music) out of the
    /// measured tone before anything else uses it; see the header comment. The per-channel
    /// speaker-to-microphone paths at each tone (zero = unknown: the combined path is split by
    /// the shares, S_L = S_R = S / (s_L + s_R)).
    bool removeProgramme;                 /* default false */
    N60AncComplex leftPathSeed[N60_FXLMS_MAX_TONES];
    N60AncComplex rightPathSeed[N60_FXLMS_MAX_TONES];
} N60RemoteTonalConfig;

typedef struct {
    uint64_t blocks;                      /* blocks adapted */
    uint64_t uncoveredBlocks;             /* skipped: telemetry did not cover the block */
    uint64_t gaps;
    uint64_t modelResets;                 /* non-finite path or weight */
    uint64_t nonFiniteSamples;
    uint64_t records;                     /* records produced by NextRecord */
    double lastBlockSeconds;              /* host time of the last block end, s */
    N60AncComplex weight[N60_FXLMS_MAX_TONES];
    N60AncComplex path[N60_FXLMS_MAX_TONES];
    N60AncComplex referencePath[N60_FXLMS_MAX_TONES];
    /// Fitted disturbance and measured tone (relative to the kernel phasor) of the last block.
    N60AncComplex disturbance[N60_FXLMS_MAX_TONES];
    N60AncComplex measuredTone[N60_FXLMS_MAX_TONES];
    float pathPhaseDegrees[N60_FXLMS_MAX_TONES];   /* arg(Shat / Sref) */
    float pathLevelDB[N60_FXLMS_MAX_TONES];        /* 20 log10 |Shat / Sref| */
    bool adapting[N60_FXLMS_MAX_TONES];
    bool micMoved;                        /* latched */
    /// 1 = a tone beyond 30 degrees / 3 dB for 1 s, 2 = fast phase change on two tones.
    uint32_t micMovedKind;
    double micMovedAtSeconds;
    bool reidentifying;
    /// E4 S19: the frequency the core wants the kernel at, the estimated disturbance-minus-kernel
    /// offset, whether the loop is locked, and the latched loss of tracking per tone.
    double frequencyHz[N60_FXLMS_MAX_TONES];
    double suggestedHz[N60_FXLMS_MAX_TONES];
    double offsetHz[N60_FXLMS_MAX_TONES];
    bool locked[N60_FXLMS_MAX_TONES];
    bool trackingLost;
    /// E4 S22: the programme's tone at the microphone that was taken out of the last block (zero
    /// when removal is off), relative to the kernel phasor, and the programme tone before the
    /// speaker-to-microphone path, summed over the two channels in power (peak amplitude).
    N60AncComplex programmeAtMic[N60_FXLMS_MAX_TONES];
    float programmeFeedLevel[N60_FXLMS_MAX_TONES];
} N60RemoteTonalStatus;

typedef struct N60RemoteTonal N60RemoteTonal;

N60RemoteTonalConfig N60RemoteTonalConfigDefault(double micSampleRate, double hostTicksPerSecond);
bool N60RemoteTonalConfigIsValid(const N60RemoteTonalConfig * N60_FXLMS_NONNULL config);
/// Control plane. NULL for an invalid configuration or no memory.
N60RemoteTonal * N60_FXLMS_NULLABLE N60RemoteTonalCreate(
    const N60RemoteTonalConfig * N60_FXLMS_NONNULL config
);
void N60RemoteTonalDestroy(N60RemoteTonal * N60_FXLMS_NULLABLE core);

/// Records the render thread's telemetry (oldest first). A record whose host time is not later
/// than the newest, or whose tones differ from the configuration, is dropped.
void N60RemoteTonalPushTelemetry(
    N60RemoteTonal * N60_FXLMS_NONNULL core,
    const N60ActiveQuietZoneTelemetryRecord * N60_FXLMS_NONNULL record
);
/// One microphone block; hostTime is the first frame's host time (0 = unknown, block skipped).
/// Adapts when telemetry covers the block. Returns true if it adapted.
bool N60RemoteTonalProcessMic(
    N60RemoteTonal * N60_FXLMS_NONNULL core,
    const float * N60_FXLMS_NONNULL samples,
    uint32_t frames,
    uint64_t hostTime
);
/// Fills a mailbox record from the current weights with the dither and slew applied. False when
/// the core has not yet seen a telemetry record (nothing to slew from) or a weight is non-finite.
bool N60RemoteTonalNextRecord(
    N60RemoteTonal * N60_FXLMS_NONNULL core,
    uint64_t armGeneration,
    float attemptCapLinear,
    N60ActiveQuietZoneGainRecord * N60_FXLMS_NONNULL record
);
/// Freezes the weights (the path fit keeps running) while true.
void N60RemoteTonalSetHold(N60RemoteTonal * N60_FXLMS_NONNULL core, bool hold);
void N60RemoteTonalBeginReidentify(N60RemoteTonal * N60_FXLMS_NONNULL core);
void N60RemoteTonalEndReidentify(N60RemoteTonal * N60_FXLMS_NONNULL core);
/// Makes the current path estimate the reference for the mic-moved check.
void N60RemoteTonalCaptureReference(N60RemoteTonal * N60_FXLMS_NONNULL core);
void N60RemoteTonalAcknowledgeMove(N60RemoteTonal * N60_FXLMS_NONNULL core);
/// E4 S19: moves tone k to hz (within the tracking range of the armed frequency, 20 to 150 Hz).
/// The weight is kept. A non-NULL pathSeed is the secondary path of the split at the new
/// frequency; the tracked path and the reference path are scaled by pathSeed / old seed, so the
/// tracked deviation carries over. NULL keeps the path as it is. The next gain record carries hz.
bool N60RemoteTonalSetToneFrequency(
    N60RemoteTonal * N60_FXLMS_NONNULL core,
    uint32_t tone,
    double hz,
    const N60AncComplex * N60_FXLMS_NULLABLE pathSeed
);
/// Re-seeds the weights (for example W Sold / Snew after a re-solve).
bool N60RemoteTonalSetWeights(
    N60RemoteTonal * N60_FXLMS_NONNULL core,
    const N60AncComplex * N60_FXLMS_NONNULL weights,
    uint32_t count
);
void N60RemoteTonalMarkDiscontinuity(N60RemoteTonal * N60_FXLMS_NONNULL core);
void N60RemoteTonalReset(N60RemoteTonal * N60_FXLMS_NONNULL core);
N60RemoteTonalStatus N60RemoteTonalReadStatus(const N60RemoteTonal * N60_FXLMS_NONNULL core);

#ifdef __cplusplus
}
#endif

#endif
