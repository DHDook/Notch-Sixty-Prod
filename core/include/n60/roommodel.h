/*
 * libn60core room-model interpolation (E29 S3, domain version N60_ROOMMODEL_ABI_VERSION). Offline design maths: nothing
 * here runs on an audio callback and nothing here arms or changes an engine snapshot. Allocation: the call allocates
 * its working arrays and frees them before it returns (control or worker thread only). Realtime: not for an audio
 * callback. Latency: none (offline). Sample rate: any rate 8 kHz..768 kHz, all neighbour responses at the one rate in
 * the query; the maths is rate-free (frequency domain), so the eight standard rates up to 384 kHz are all valid.
 * Channels: one source to one receiver path per call. Deterministic: fixed summation order, no threads, no randomness;
 * neighbours tied on distance are ranked by their order in the input. The core is built without exceptions: the working arrays are std::vector, so an out-of-memory aborts (E29 gap G6, as the other offline maths).
 *
 * Question answered (docs/epics/E29.md design note 4): what would the response from one source be at a position nobody
 * measured, given measured responses at nearby positions? A derived path is never persisted and always carries
 * confidence; consumers that need an authoritative path (room correction design, Quiet Zone, MIMO design) never use it.
 *
 * Neighbours (domain version 2). Of the input neighbours, those within the trust radius of the query are candidates. The
 * default radius (trustRadiusM 0) is spacing-aware: the larger of 0.5 m and 1.42 x the node spacing (the distance from the
 * node nearest the query to its nearest other input node), so a whole grid cell is always in range (0.71 m for a 0.5 m
 * grid); an explicit radius is used as given. None within the radius: the query is "not measured", reason OUTSIDE_TRUST.
 * Nothing outside the radius is ever extrapolated. Weights: of the nearest 16 candidates, the triangle that holds the
 * query (coplanar within 2 cm) with the smallest longest edge gives barycentric weights; a grid cell is split on one
 * fixed diagonal (nodes ranked by x, then y, then z). With no such triangle (fewer than three nodes, collinear nodes, query
 * outside every triangle) the weights are the inverse distances of the nearest three. A node of weight zero is dropped:
 * it is not used, not counted in neighboursUsed and not in the spread.
 *
 * Low band (below f_c = c / (4 d), c the speed of sound, d the nearest-neighbour spacing: the smallest distance between
 * two triangle nodes (before dropping zero weights), or twice the query's distance with one neighbour; 0.5 m gives about 171 Hz). Each neighbour's
 * response H_i is advanced by its direct-arrival delay, H_i' = H_i exp(+j w tau_i) with tau_i = |source - p_i| / c,
 * blended with the weights w_i above (barycentric; inverse-distance w_i = (1 / max(d_i, 1 mm)) / sum(1 / max(d_j, 1 mm)) in the
 * fallback, d_i the distance from the query to neighbour i), and the delay of the query position restored, H_q = exp(-j w tau_q) sum_i w_i H_i'. This
 * generalises the head-survey blend and is exact when every neighbour is the query's own response. The complex result
 * is returned on the DFT grid of the query's FFT size. It needs phase trust: if any used neighbour has
 * phaseTrusted == 0 (timing tier none) the low band is magnitude-only like the high band and complexValid is 0.
 *
 * Above f_c: third-octave band energy only, no phase. Band power P_i is the mean |H_i|^2 over the DFT bins of the band
 * (the DFT of the response as supplied, unnormalised, so levels are in dB re 1 per unit of impulse-response sum) and
 * the blend is the weighted power average sum_i w_i P_i. A band that lies wholly below f_c takes its level
 * from the complex blend when complexValid, so level and complex output agree.
 *
 * Bands: N60_ROOMMODEL_BAND_COUNT third-octave bands, centre 1000 Hz * 2^(k/3), k = -15..12 (31.25 Hz to 16 kHz),
 * edges at centre * 2^(+-1/6). Bands reaching above the lower of Nyquist and 20 kHz are reported unavailable.
 *
 * Spread and confidence, per band. spread is the largest minus the smallest used neighbour's band level in dB (a single
 * neighbour cannot show spread: it is reported as half the limit). scatter is the root mean square of the used
 * neighbours' repeatScatterDb (repeat-measurement scatter, 0 when unknown). Spread above the limit (default 8 dB)
 * marks that band SPREAD with zero confidence (its complex bins below f_c are still returned: the blend is the best estimate and the status tells the consumer not to rely on it); only nodes of non-zero weight count; otherwise
 * confidence = max(0, 1 - sqrt(spread^2 + scatter^2) / limit), in 0..1.
 */
#ifndef N60_ROOMMODEL_H
#define N60_ROOMMODEL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_ROOMMODEL_ABI_VERSION 2u

#define N60_ROOMMODEL_OK 0
#define N60_ROOMMODEL_ERR_ARGUMENT (-1) /* null pointer, bad rate/size, non-finite value, ir longer than the FFT */
#define N60_ROOMMODEL_NOT_MEASURED 1    /* well-formed query with no answer; result.reason says why */

#define N60_ROOMMODEL_REASON_NONE 0
#define N60_ROOMMODEL_REASON_OUTSIDE_TRUST 1 /* no neighbour within the trust radius */
#define N60_ROOMMODEL_REASON_NO_NEIGHBOURS 2 /* the neighbour list was empty */

#define N60_ROOMMODEL_BAND_OK 0
#define N60_ROOMMODEL_BAND_SPREAD 1      /* used neighbours disagree by more than the limit */
#define N60_ROOMMODEL_BAND_UNAVAILABLE 2 /* band above the lower of Nyquist and 20 kHz */
#define N60_ROOMMODEL_BAND_REFUSED 3     /* the whole query was refused */

#define N60_ROOMMODEL_BAND_COUNT 28u
#define N60_ROOMMODEL_MAX_NEIGHBOURS 3u
#define N60_ROOMMODEL_DEFAULT_TRUST_M 0.5 /* minimum default radius; see the spacing-aware rule above */
#define N60_ROOMMODEL_CELL_DIAGONAL 1.42 /* default radius is at least this times the node spacing */
#define N60_ROOMMODEL_DEFAULT_SPREAD_DB 8.0
#define N60_ROOMMODEL_DEFAULT_SOUND_SPEED 343.0
#define N60_ROOMMODEL_MAX_FFT_SIZE 2097152u
#define N60_ROOMMODEL_MAX_NEIGHBOUR_INPUTS 4096u /* neighbourCount upper bound */

/* One measured path to a known position. ir is irFrames samples at the query's rate with the source's own
 * latency already removed (timing tier loopback or reference), so the direct arrival sits at |source - position| / c. */
typedef struct n60_roommodel_neighbour {
    double position[3];       /* metres, room frame */
    const float *ir;
    uint32_t irFrames;
    uint32_t phaseTrusted;    /* 1 when timing tier is loopback or reference; 0 for magnitude-only */
    double repeatScatterDb;   /* repeat-measurement scatter, dB; 0 when unknown */
} n60_roommodel_neighbour;

typedef struct n60_roommodel_query {
    uint32_t structSize;      /* sizeof(n60_roommodel_query) */
    uint32_t fftSize;         /* power of two, at least every irFrames, at most N60_ROOMMODEL_MAX_FFT_SIZE */
    double sampleRate;
    double soundSpeed;        /* m/s; 0 for the default 343 */
    double trustRadiusM;      /* 0 for the default 0.5 m */
    double spreadLimitDb;     /* 0 for the default 8 dB */
    double source[3];         /* position of the source the paths were measured from */
    double query[3];          /* position to estimate */
    uint32_t neighbourCount;
    uint32_t reserved;
} n60_roommodel_query;

typedef struct n60_roommodel_result {
    uint32_t structSize;      /* sizeof(n60_roommodel_result) */
    int32_t reason;           /* N60_ROOMMODEL_REASON_*; none when status is OK */
    uint32_t neighboursUsed;
    uint32_t complexValid;    /* 1 when lowRe/lowIm hold the complex blend */
    double crossoverHz;       /* f_c */
    double nearestDistanceM;
    double spacingM;          /* d used for f_c */
    double binHz;             /* sampleRate / fftSize */
    double delaySeconds;      /* tau_q, the restored direct-arrival delay */
    double bandCentreHz[N60_ROOMMODEL_BAND_COUNT];
    double levelDb[N60_ROOMMODEL_BAND_COUNT];
    double spreadDb[N60_ROOMMODEL_BAND_COUNT];
    double confidence[N60_ROOMMODEL_BAND_COUNT];
    int32_t bandStatus[N60_ROOMMODEL_BAND_COUNT]; /* N60_ROOMMODEL_BAND_* */
} n60_roommodel_result;

uint32_t n60_roommodel_abi_version(void);

/* f_c = c / (4 d); 0 for a non-positive d or c. */
double n60_roommodel_crossover_hz(double spacingM, double soundSpeed);

/* Centre frequency of band index 0..N60_ROOMMODEL_BAND_COUNT-1; 0 out of range. */
double n60_roommodel_band_centre_hz(uint32_t index);

/*
 * Fills result and, when non-null (both or neither), lowRe/lowIm (fftSize / 2 + 1 doubles each: bins 0..Nyquist of the DFT of the
 * estimated response, zero above f_c and when not complexValid). Returns OK (an estimate, possibly
 * with refused bands), NOT_MEASURED (result.reason set, bands REFUSED, arrays zeroed) or a negative error.
 */
int32_t n60_roommodel_interpolate(const n60_roommodel_query *query, const n60_roommodel_neighbour *neighbours,
                                  n60_roommodel_result *result, double *lowRe, double *lowIm);

#ifdef __cplusplus
}
#endif

#endif
