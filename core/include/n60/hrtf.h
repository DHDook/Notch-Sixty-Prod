/*
 * libn60core generic HRTF generator (E13 S11, domain version N60_HRTF_ABI_VERSION). Offline design maths: nothing here
 * runs on an audio callback. Allocation: none (the caller owns the output arrays). Realtime: not for an audio callback.
 * Latency: each response carries N60_HRTF_GUARD_FRAMES of fixed lead-in plus the model's arrival delay. Sample rate:
 * any rate 8 kHz..768 kHz, generated natively (no resampling). Channels: one source direction per call, two ears out.
 * Deterministic: fixed formulas, fixed summation order, no threads, no randomness; uses the platform libm.
 * No exceptions are thrown across the C boundary.
 *
 * Model (public, textbook; no measured third-party data). A rigid sphere head of radius a = 0.0875 m with the ears on
 * the sphere at azimuth +-100 degrees (ear offset 10 degrees behind the interaural axis), speed of sound c = 343 m/s.
 * psi is the angle between the source direction and an ear's direction. Arrival delay (Woodworth 1938, extended to
 * any direction): t(psi) = -(a/c) cos(psi) for psi < 90 degrees (the wavefront reaches the ear directly), and
 * t(psi) = (a/c)(psi - 90 degrees) beyond (it creeps round the sphere); a constant a/c is added so every delay is >= 0.
 * Head shadow (Brown and Duda 1998, "A structural model for binaural sound synthesis", IEEE Trans. Speech Audio
 * Process. 6(5)): the one-pole, one-zero filter H(s) = (1 + alpha s T) / (1 + s T) with T = a / (2 c) and
 * alpha(psi) = 1.05 + 0.95 cos(psi * 180 / 150 degrees), so DC gain is 1 and the high-frequency gain is alpha. It is
 * discretised by the bilinear transform at the requested rate. Each ear's response is the shadow filter's impulse
 * response convolved with a 16-tap Kaiser-windowed sinc fractional delay (Kaiser beta 8) of the arrival delay plus
 * the guard. Azimuth is positive to the right, elevation positive up, both in degrees, as the app's binaural assets.
 */
#ifndef N60_HRTF_H
#define N60_HRTF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_HRTF_ABI_VERSION 1u

#define N60_HRTF_OK 0
#define N60_HRTF_ERR_ARGUMENT (-1) /* null pointer, bad rate, non-finite or out-of-range angle, bad tap count */

#define N60_HRTF_GUARD_FRAMES 8u    /* fixed lead-in so the fractional-delay kernel never reaches before sample 0 */
#define N60_HRTF_MIN_RATE 8000.0
#define N60_HRTF_MAX_RATE 768000.0

/* The closed-form model for one direction (the same numbers the impulse responses are built from). */
typedef struct n60_hrtf_generic_model {
    double delay_s[2];    /* [0] left, [1] right: arrival delay in seconds, without the guard frames */
    double hf_gain[2];    /* alpha for each ear: high-frequency gain of the head shadow (DC gain is 1) */
    double shadow_s;      /* T, the shadow filter's time constant in seconds */
} n60_hrtf_generic_model;

uint32_t n60_hrtf_abi_version(void);

/* Taps per response at a rate (3 ms, rounded up, at least 64). Returns 0 for a bad rate. */
uint32_t n60_hrtf_generic_taps(double sample_rate);

/* Fills the closed-form model. azimuth -180..180, elevation -90..90. Returns N60_HRTF_OK or an error. */
int n60_hrtf_generic_model_at(double azimuth_deg, double elevation_deg, n60_hrtf_generic_model *out);

/* Writes `taps` float samples to each of left and right. `taps` must be at least n60_hrtf_generic_taps(rate). */
int n60_hrtf_generic_ir(double sample_rate, double azimuth_deg, double elevation_deg, uint32_t taps,
                        float *left, float *right);

#ifdef __cplusplus
}
#endif

#endif
