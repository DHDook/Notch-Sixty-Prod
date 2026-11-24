/*
 * ANC design maths (E21 S10a, domain version N60_ANC_DESIGN_ABI_VERSION). Numbers-to-numbers only: the Quiet Zone virtual
 * seat designer (per-band regularised stereo least squares with the rank-one bass conditioning), the causal FIR compiler
 * (Tikhonov real-tap fit with the common-mode tie), the HAL sample-clock analysis and the upstream survey (lead
 * estimator and assessment) and, from version 2, the passive ambient field analysis. Controllers, evidence capture, readiness and value types stay in Swift.
 *
 * Offline only: control or worker thread, allocates (never throws across this boundary), deterministic (fixed order, no
 * threads). Never called from an audio callback. Nothing here arms, enables or changes a live ANC path: every output is a
 * preview or a diagnostic, exactly as the Swift maths it replaces. No Apple framework.
 */
#ifndef N60_ANC_DESIGN_H
#define N60_ANC_DESIGN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_ANC_DESIGN_ABI_VERSION 2u /* 2: ambient field analysis (E21 S10b) */

#define N60_ANC_DESIGN_MAX_BANDS 64u
#define N60_ANC_DESIGN_MAX_TAPS 64u

/* Result codes. The virtual seat designer and FIR compiler have their own ranges so Swift maps them to its errors. */
#define N60_ANC_DESIGN_OK 0
#define N60_ANC_DESIGN_ERR_ARGUMENT (-1)
#define N60_ANC_DESIGN_ERR_ALLOC (-2)
/* Virtual seat designer. */
#define N60_ANC_SEAT_ERR_MEASUREMENTS (-10) /* empty or more than 64 bands */
#define N60_ANC_SEAT_ERR_MODEL (-11)        /* invalid transfer values, grid or non-finite result */
#define N60_ANC_SEAT_ERR_COHERENCE (-12)
#define N60_ANC_SEAT_ERR_AUTHORITY (-13)
#define N60_ANC_SEAT_ERR_LEAKAGE (-14)
#define N60_ANC_SEAT_ERR_BENEFIT (-15)
#define N60_ANC_SEAT_ERR_BUDGET (-16)
/* Causal FIR compiler. */
#define N60_ANC_FIR_ERR_CLOCK (-20) /* sample rate, tap count or budget */
#define N60_ANC_FIR_ERR_MODEL (-21)
#define N60_ANC_FIR_ERR_RANK (-22)
#define N60_ANC_FIR_ERR_GAIN (-23)
#define N60_ANC_FIR_ERR_NONCAUSAL (-24)
#define N60_ANC_FIR_ERR_REDUCTION (-25)
/* HAL clock analysis. */
#define N60_ANC_CLOCK_ERR_INSUFFICIENT (-30)
#define N60_ANC_CLOCK_ERR_TIMEBASE (-31)
#define N60_ANC_CLOCK_ERR_DISCONTINUITY (-32)
#define N60_ANC_CLOCK_ERR_DRIFT (-33)
#define N60_ANC_CLOCK_ERR_JITTER (-34)

uint32_t n60_anc_design_abi_version(void);

typedef struct n60_anc_complex {
    double re;
    double im;
} n60_anc_complex;

/* Limits shared with the Swift side (read by tests, never literals). */
typedef struct n60_anc_seat_limits {
    double minimumCoherence;           /* 0.85 */
    double maximumLeakageFraction;     /* 0.10 */
    double minimumModeledReductionDB;  /* 0.25 */
    double minimumAuthority;           /* 1e-5 */
    double minimumReserveSeconds;      /* 0.002 */
    double firPeakGainLimit;           /* 0.0630957... (-24 dB) */
    double firMaximumRelativeFitError; /* 0.18 */
    double firMinimumSampleRate;       /* 1000 */
    double firMaximumSampleRate;       /* 768000 */
} n60_anc_seat_limits;
void n60_anc_seat_limits_get(n60_anc_seat_limits *out);

/* ---- Bass plant conditioning (rank-one handling of the 2x2 plant) ---- */
#define N60_ANC_BASS_FREE 0
#define N60_ANC_BASS_TIKHONOV 1
#define N60_ANC_BASS_COMMON 2

/* Condition number in dB of [[a, b], [c, d]] (rows: error points, columns: L and R); infinity when singular. */
double n60_anc_bass_condition_db(n60_anc_complex a, n60_anc_complex b, n60_anc_complex c, n60_anc_complex d);
/* Classifies a condition number: returns a N60_ANC_BASS_* mode and writes the Tikhonov scale (1 unless TIKHONOV). */
int32_t n60_anc_bass_mode(double conditionDB, double *lambdaScale);

/* ---- Virtual seat designer ---- */
typedef struct n60_anc_seat_band {
    double frequencyHz;
    n60_anc_complex sourceToReference;
    n60_anc_complex sourceToListener;
    n60_anc_complex leftSecondaryAtListener;
    n60_anc_complex rightSecondaryAtListener;
    n60_anc_complex leftLeakageAtReference;
    n60_anc_complex rightLeakageAtReference;
    double measuredCoherence;
} n60_anc_seat_band;

typedef struct n60_anc_seat_band_result {
    double frequencyHz;
    n60_anc_complex disturbanceTransfer;
    n60_anc_complex leftFilter;
    n60_anc_complex rightFilter;
    n60_anc_complex predictedResidual;
    double modeledReductionDB;
    double predictedReferenceLeakageFraction;
} n60_anc_seat_band_result;

typedef struct n60_anc_seat_options {
    uint32_t structSize;          /* sizeof(n60_anc_seat_options) */
    double reserveSeconds;        /* conservative budget reserve; NaN when the budget is not physically plausible */
    double minimumFrequencyHz;    /* validated ActiveQuietZoneConfiguration range */
    double maximumFrequencyHz;
    double maximumPerSourceTonePeakDBFS;
    double maximumAggregateSourcePeakDBFS;
    int32_t bassConditioning;     /* nonzero: condition each band by the measured 2x2 plant */
    double pathChangeToleranceDB; /* the bass path watch gain tolerance (leakage limit is divided by it in shared bands) */
} n60_anc_seat_options;

/* `bands` may be in any order; `results` has room for `bandCount` entries and is written in ascending frequency order.
 * Writes the worst modelled reduction and the lowest coherence. */
int32_t n60_anc_virtual_seat_design(const n60_anc_seat_band *bands, uint32_t bandCount, const n60_anc_seat_options *options,
                                    n60_anc_seat_band_result *results, double *worstReductionDB,
                                    double *minimumCoherence);

/* ---- Causal FIR compiler ---- */
typedef struct n60_anc_fir_options {
    uint32_t structSize;
    double reserveSeconds; /* as above */
    double sampleRate;
    uint32_t tapCount;
    int32_t bassConditioning;
    double pathChangeToleranceDB;
} n60_anc_fir_options;

typedef struct n60_anc_fir_result {
    float leftTaps[N60_ANC_DESIGN_MAX_TAPS];
    float rightTaps[N60_ANC_DESIGN_MAX_TAPS];
    uint32_t tapCount;
    double worstPredictedReductionDB;
    double maximumRelativeFitError;
    double maximumReferenceEchoFraction;
} n60_anc_fir_result;

/* `results` must be the output of n60_anc_virtual_seat_design for the same bands (ascending, same frequencies). */
int32_t n60_anc_causal_fir_compile(const n60_anc_seat_band *bands, const n60_anc_seat_band_result *results,
                                   uint32_t bandCount, const n60_anc_fir_options *options, n60_anc_fir_result *out);

/* ---- HAL clock analysis ---- */
typedef struct n60_anc_clock_observation {
    double hostTimeSeconds;
    double sampleFrame;
} n60_anc_clock_observation;

typedef struct n60_anc_clock_health {
    double measuredInputRateHz;
    double measuredOutputRateHz;
    double relativeDriftPPM;
    double worstInputResidualSeconds;
    double worstOutputResidualSeconds;
    double observationDurationSeconds;
} n60_anc_clock_health;

typedef struct n60_anc_clock_limits {
    uint32_t minimumObservations;       /* 8 */
    double minimumObservationDuration;  /* 2 s */
    double maximumRelativeDriftPPM;     /* 100 */
    double maximumNominalRateErrorPPM;  /* 200 */
    double maximumWorstResidualSeconds; /* 0.0005 */
} n60_anc_clock_limits;
void n60_anc_clock_limits_get(n60_anc_clock_limits *out);

int32_t n60_anc_hal_clock_analyze(double nominalSampleRate, const n60_anc_clock_observation *input, uint32_t inputCount,
                                  const n60_anc_clock_observation *output, uint32_t outputCount,
                                  n60_anc_clock_health *health);

/* ---- Upstream survey ---- */
typedef struct n60_anc_upstream_lead_estimator n60_anc_upstream_lead_estimator;

typedef struct n60_anc_upstream_estimate {
    double leadSeconds;
    double peakCorrelation;
    double resolutionSeconds;
} n60_anc_upstream_estimate;

/* NULL on a bad rate or allocation failure. Control thread only. */
n60_anc_upstream_lead_estimator *n60_anc_upstream_lead_create(double sampleRate);
void n60_anc_upstream_lead_destroy(n60_anc_upstream_lead_estimator *);
/* A lost callback: forget the filter history so no output spans the gap. */
void n60_anc_upstream_lead_mark_discontinuity(n60_anc_upstream_lead_estimator *);
/* Returns 0, or N60_ANC_DESIGN_ERR_ALLOC. */
int32_t n60_anc_upstream_lead_ingest(n60_anc_upstream_lead_estimator *, const float *reference, const float *error,
                                     uint32_t frames);
uint32_t n60_anc_upstream_lead_decimation(const n60_anc_upstream_lead_estimator *);
uint32_t n60_anc_upstream_lead_decimated_count(const n60_anc_upstream_lead_estimator *);
/* Copies up to `capacity` decimated samples of each stream; returns the count available. */
uint32_t n60_anc_upstream_lead_decimated(const n60_anc_upstream_lead_estimator *, float *reference, float *error,
                                         uint32_t capacity);
/* 1 and fills `out` when there is enough signal (2 s or more) and energy; 0 otherwise. */
int32_t n60_anc_upstream_lead_estimate(const n60_anc_upstream_lead_estimator *, n60_anc_upstream_estimate *out);

#define N60_ANC_UPSTREAM_SUITABLE 0
#define N60_ANC_UPSTREAM_MOVE_FURTHER_OUT 1
#define N60_ANC_UPSTREAM_LOW_COHERENCE 2
#define N60_ANC_UPSTREAM_NO_COMMON_NOISE 3

typedef struct n60_anc_upstream_survey_band {
    double frequencyHz;
    double coherence;
} n60_anc_upstream_survey_band;

typedef struct n60_anc_upstream_assessment {
    int32_t verdict; /* N60_ANC_UPSTREAM_* */
    double leadSeconds;
    double leadUncertaintySeconds;
    double budgetSeconds;
    double meanCoherence;
    uint32_t bandCount;          /* in-band rows written to bandsOut */
    double predictedReductionDB; /* valid when hasPrediction */
    int32_t hasPrediction;
} n60_anc_upstream_assessment;

/* The coherence bound -10 log10(1 - g^2), capped at 30 dB (Nelson and Elliott, Active Control of Sound, ch. 7). */
double n60_anc_upstream_reduction_bound_db(double coherence);

/* Assesses the upstream position. `estimate` may be NULL. The 25-150 Hz rows of `survey` are copied to `bandsOut` and
 * their coherence bounds to `boundsOut` (both with capacity `surveyCount`). */
void n60_anc_upstream_assess(const n60_anc_upstream_estimate *estimate, const n60_anc_upstream_survey_band *survey,
                             uint32_t surveyCount, double latencySeconds, double flightSeconds, double clockOffsetErrorSeconds,
                             n60_anc_upstream_survey_band *bandsOut, double *boundsOut, n60_anc_upstream_assessment *out);

/* ---- Ambient field analysis (E21 S10b, version 2) ----------------------------------------------------------------
 * Passive, offline estimator: removes the modelled playback from a microphone window (bounded alignment search, bounded
 * least-squares gain, segment-stability confidence) and reports the residual's level, band spectrum, tones, stationarity,
 * periodicity and character. It never generates cancellation audio and runs on a worker thread only. Maths is the former
 * Swift `AmbientFieldAnalyzer`, in double precision on the offline FFT (n60::fft::offline), so results agree with the Swift
 * float vDSP path to within float rounding. Allocates, never throws, deterministic. */

#define N60_AMBIENT_MAX_BANDS 256u

#define N60_AMBIENT_ERR_SAMPLE_RATE (-40)
#define N60_AMBIENT_ERR_INSUFFICIENT (-41)
#define N60_AMBIENT_ERR_LENGTH_MISMATCH (-42)
#define N60_AMBIENT_ERR_NONFINITE_MICROPHONE (-43)
#define N60_AMBIENT_ERR_NONFINITE_PLAYBACK (-44)
#define N60_AMBIENT_ERR_ACOUSTIC_MODEL (-45)
#define N60_AMBIENT_ERR_CONFIGURATION (-46)
#define N60_AMBIENT_ERR_TRANSFORM_TOO_LARGE (-47)

#define N60_AMBIENT_MODE_MICROPHONE_ONLY 0
#define N60_AMBIENT_MODE_MODELED_SUBTRACTION 1
#define N60_AMBIENT_MODE_MODEL_UNAVAILABLE 2

#define N60_AMBIENT_CHARACTER_QUIET 0
#define N60_AMBIENT_CHARACTER_BROADBAND 1
#define N60_AMBIENT_CHARACTER_TONAL 2
#define N60_AMBIENT_CHARACTER_TONAL_PERIODIC 3
#define N60_AMBIENT_CHARACTER_NONSTATIONARY 4
#define N60_AMBIENT_CHARACTER_MIXED 5

typedef struct n60_ambient_config {
    uint32_t structSize; /* sizeof(n60_ambient_config) */
    int32_t minimumAnalysisFrames;
    int32_t maximumAnalysisFrames;
    int32_t maximumImpulseTaps;
    int32_t spectrumBandCount;
    int32_t segmentCount;
    double minimumFrequencyHz;
    double maximumFrequencyHz;
    double lowFrequencyUpperHz;
    double tonalSearchUpperHz;
    double minimumTonalProminenceDB;
    int32_t maximumTonalComponents;
    double negligiblePlaybackDBFS;
    double maximumPlaybackAlignmentSeconds;
    double alignmentSearchRateHz;
} n60_ambient_config;

/* The production configuration (the Swift `AmbientAnalysisConfiguration.production` values). */
void n60_ambient_config_default(n60_ambient_config *out);

typedef struct n60_ambient_source {
    const float *samples;         /* same length as the microphone */
    const float *impulse;         /* NULL when the acoustic path is unknown */
    uint32_t impulseCount;
} n60_ambient_source;

typedef struct n60_ambient_band {
    double lowerFrequencyHz;
    double centerFrequencyHz;
    double upperFrequencyHz;
    double levelDBFS;
} n60_ambient_band;

typedef struct n60_ambient_tone {
    double frequencyHz;
    double levelDBFS;
    double prominenceDB;
    double phaseRadians;
} n60_ambient_tone;

typedef struct n60_ambient_result {
    uint32_t analyzedFrames;
    int32_t separationMode;      /* N60_AMBIENT_MODE_* */
    double separationConfidence;
    int32_t hasPredictionGain;
    double predictionGain;
    double microphoneLevelDBFS;
    int32_t hasPredictedLevel;
    double predictedPlaybackLevelDBFS;
    double ambientLevelDBFS;
    double stationarityScore;
    double periodicityScore;
    int32_t hasPeriodicFrequency;
    double periodicFrequencyHz;
    double lowFrequencyEnergyFraction;
    double cancellationCandidateScore;
    int32_t character;           /* N60_AMBIENT_CHARACTER_* */
    uint32_t spectrumCount;      /* rows written to spectrumOut */
    uint32_t tonalCount;         /* rows written to tonesOut */
    int32_t hasAlignment;
    int32_t alignmentLagFrames;
    double alignmentConfidence;
    int32_t hasModeledSpectrum;  /* modeledSpectrumOut written (spectrumCount rows) */
} n60_ambient_result;

/* Frames the analysis will use for `microphoneCount` samples: min(count, maximumAnalysisFrames). */
uint32_t n60_ambient_window_frames(const n60_ambient_config *config, uint32_t microphoneCount);

/* Analyses the last window_frames samples of `microphone` and of each source. Capacities: `residualOut` and
 * `spectrumOut`/`modeledSpectrumOut` at least n60_ambient_window_frames and config.spectrumBandCount rows; `tonesOut` at
 * `toneCapacity` rows (the tone count is min(config.maximumTonalComponents, toneCapacity)). Returns N60_ANC_DESIGN_OK or
 * an N60_AMBIENT_ERR_* / N60_ANC_DESIGN_ERR_* code, and leaves `result` untouched on error. */
int32_t n60_ambient_analyze(const n60_ambient_config *config, const float *microphone, uint32_t microphoneCount,
                            const n60_ambient_source *sources, uint32_t sourceCount, double sampleRate,
                            n60_ambient_result *result, n60_ambient_band *spectrumOut, n60_ambient_band *modeledSpectrumOut,
                            n60_ambient_tone *tonesOut, uint32_t toneCapacity, float *residualOut);

#ifdef __cplusplus
}
#endif

#endif
