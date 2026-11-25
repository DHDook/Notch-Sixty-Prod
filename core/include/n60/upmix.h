/*
 * libn60core stereo upmixer (E14 S1, domain version N60_UPMIX_ABI_VERSION). Turns a stereo programme into the lanes of
 * a wider speaker layout: a stable centre extracted from the front image, ambience sent to the surrounds and heights, one
 * strength control. This header is the offline entry point (tests, design tools); the realtime stage (E14 S2) uses the
 * engine in core/src/upmix/upmix.hpp. Pure C: no platform header, no Apple framework.
 *
 * Method (docs/epics/E14.md design note): per STFT bin the smoothed 2 x 2 covariance of L and R gives a principal
 * (primary) component with a pan angle and a residual (ambience); the primary is re-panned over the front speakers, the
 * ambience is decorrelated per speaker and sent to the surrounds and heights. Never writes the LFE lane.
 *
 * Allocation: the offline call allocates and frees its working memory (control or worker thread only; the engine
 * allocates only in init). Latency: n60_upmix_latency_frames, constant per rate, every lane. Sample rate: any rate from
 * 8 kHz to 768 kHz; the frame length is fixed in time (about 21 to 23 ms), so the eight standard rates 44.1 to 384 kHz
 * all work natively, with no resampling. Channels: input is two lanes; output is the layout (front pair plus any of C,
 * LFE, surrounds, wides, heights). Reset: STFT history and smoothing restart from silence. Deterministic: seeded,
 * fixed summation order, no threads.
 */
#ifndef N60_UPMIX_H
#define N60_UPMIX_H

#include <stddef.h>
#include <stdint.h>

#include "n60/graph.h" /* n60_channel_role, N60_LAYOUT_MAX_CHANNELS */

#ifdef __cplusplus
extern "C" {
#endif

#define N60_UPMIX_ABI_VERSION 1u

#define N60_UPMIX_OK 0
#define N60_UPMIX_ERR_ARGUMENT (-1) /* null pointer, bad size, rate, strength or layout */

/* Design constants (docs/epics/E14.md design note). */
#define N60_UPMIX_AMBIENCE_FRACTION 0.75 /* share of the ambience power moved off the front pair at strength 1 */
#define N60_UPMIX_MAX_HZ 20000.0         /* bins above this stay on the front pair */

typedef struct n60_upmix_config {
    uint32_t structSize;    /* sizeof(n60_upmix_config) */
    uint32_t channelCount;  /* 2..N60_LAYOUT_MAX_CHANNELS; output lane c has role roles[c] */
    uint32_t roles[N60_LAYOUT_MAX_CHANNELS]; /* n60_channel_role; must hold FRONT_LEFT and FRONT_RIGHT */
    double sampleRate;
    float strength;         /* 0..1 */
    uint32_t seed;          /* decorrelator seed; the same seed gives bit-identical output */
    uint32_t reserved;
} n60_upmix_config;

uint32_t n60_upmix_abi_version(void);

/* STFT frame length in samples: 1024 * 2^round(log2(rate / 48000)); 0 for a rate outside 8 kHz..768 kHz. */
uint32_t n60_upmix_frame_length(double sampleRate);
/* Delay every output lane carries relative to the input, in frames (one STFT frame); 0 for a bad rate. */
uint32_t n60_upmix_latency_frames(double sampleRate);

/*
 * Upmixes `frames` samples. out[c] (channelCount pointers, each `frames` floats) receives lane c, delayed by the
 * latency, so out[FL][i] at strength 0 equals left[i - latency]. Input is processed in blocks of `blockFrames`
 * (0 for the whole buffer); the result does not depend on the block size. Non-finite input samples read as zero.
 * Returns N60_UPMIX_OK or N60_UPMIX_ERR_ARGUMENT.
 */
int32_t n60_upmix_process_offline(const n60_upmix_config *config, const float *left, const float *right,
                                  uint32_t frames, float *const *out, uint32_t blockFrames);

#ifdef __cplusplus
}
#endif

#endif
