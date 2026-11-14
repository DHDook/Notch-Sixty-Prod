/*
 * libn60core control-plane resampler (E7 S2). Converts impulse responses and other assets between sample rates:
 * Kaiser-windowed band-limited sinc interpolation in double precision.
 *
 * Derivation (public: J. O. Smith, "Digital Audio Resampling Home Page", band-limited interpolation; Kaiser window
 * from Kaiser and Schafer 1980). Output sample j sits at source position p = j * src_rate / dst_rate. It is
 * sum_k x[k] * h(p - k) with h(d) = c * sinc(c * d) * w(d / H) * step, where c = 0.95 * min(1, dst_rate / src_rate)
 * is the cut-off in source-sample units (0.95 of the lower Nyquist, leaving a transition band), step =
 * src_rate / dst_rate, H = crossings / c is the half width in source samples and w is a Kaiser window (crossings and beta per quality below). The
 * "* step" factor scales the amplitude so the frequency response (not just the waveform) is preserved across the
 * rate change. Content above the lower Nyquist is band-limited, never invented.
 *
 * Output count is ceil(in_count * dst_rate / src_rate), at least 1. Samples before 0 and after the end read as
 * zero. The STANDARD kernel is the same arithmetic as the Swift resampler it replaces (BinauralProfileAsset, E6 S9c):
 * the interpolation kernel for one output tap is built once and applied to every signal in the batch. The tap
 * amplitudes are scaled by src_rate / dst_rate (impulse-response semantics): a tone gains that factor, an impulse
 * response keeps its frequency response.
 *
 * Realtime documentation (docs/REALTIME_RULES.md): CONTROL PLANE ONLY. Never call from an audio callback.
 *  - Allocation: one scratch kernel of 2 * ceil(H) + 2 doubles (H up to about 70 / c) per call (nothrow); returns 0 if it fails.
 *  - Synchronisation: none; reentrant, no shared state.
 *  - Latency: not applicable (offline); the response onset is preserved (output sample 0 is source sample 0).
 *  - Sample rate: any finite rate pair; tested at 44.1, 48, 88.2, 96, 176.4, 192, 352.8 and 384 kHz (all 64 pairs).
 *  - Channels: any number of equal-length signals per call (the caller flattens, signal-major).
 *  - Reset: stateless.
 */
#ifndef N60_RESAMPLE_H
#define N60_RESAMPLE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Kernel choice. STANDARD is the binaural kernel: 32 zero crossings, Kaiser beta 8.6 (-0.27 dB at 0.9 x the lower
 * Nyquist, about 80 to 90 dB of rejection at the edge); output is within -120 dB of the Swift resampler it replaced.
 * PRECISE is for assets whose response matters to the dB (speaker IR, research SOFA): 66 crossings, beta 10.2, flat
 * to 0.01 dB at 0.9 x the lower Nyquist and at least 100 dB of rejection from 1.0 x. */
#define N60_RESAMPLE_STANDARD 0
#define N60_RESAMPLE_PRECISE 1

/* ceil(in_count * dst_rate / src_rate), at least 1. Returns in_count for a bad rate or in_count 0. */
uint32_t n60_resample_output_count(uint32_t in_count, double src_rate, double dst_rate);

/*
 * Resamples signal_count signals of in_count samples each. in is signal-major (signal s starts at
 * in + s * in_count); out is signal-major with stride out_count = n60_resample_output_count(...) and must hold
 * signal_count * out_count floats. Equal rates (within 0.5 Hz) copy. Returns 1 on success; 0 for a bad argument,
 * a non-finite rate, too small an out_capacity (floats) or a failed scratch allocation (out is then untouched).
 */
int n60_resample_batch(const float *in, uint32_t in_count, uint32_t signal_count, double src_rate, double dst_rate,
                       int quality, float *out, uint64_t out_capacity);

#ifdef __cplusplus
}
#endif

#endif /* N60_RESAMPLE_H */
