/*
 * libn60core program fold-down (E25 S8a). Folds N program channels (3..16) onto two feeds with a
 * fixed gain matrix: y_o[n] = sum_c g[o][c] * x_c[n]. Portable C++20 behind a C interface; no Apple
 * framework, no exceptions, no allocation.
 *
 * Derivation. The coefficients are ITU-R BS.775-3 downmix gains (computed by the app in
 * ProgramFoldDown.swift). The sum is plain float multiply-add in channel order, which is exactly the
 * arithmetic of one ROUTE stage destination lane (core/src/stages_route.cpp), so the capture-side fold
 * and a ROUTE stage built from the same entries agree to float rounding.
 *
 * Realtime documentation (docs/REALTIME_RULES.md):
 *  - Allocation: none. The matrix is a plain struct the caller owns (2 x 16 floats).
 *  - Synchronisation: none. The matrix is immutable while processing; the caller installs it before
 *    IO starts and frees it after IO stops.
 *  - Latency: 0 frames.
 *  - Sample rate: not applicable (the matrix is rate-free); valid at every rate to 384 kHz.
 *  - Channels: 3..16 in, exactly 2 out. Each input channel has its own pointer and stride, so an
 *    interleaved buffer and N mono buffers are both handled.
 *  - Reset: stateless.
 */
#ifndef N60_FOLD_H
#define N60_FOLD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_FOLD_MAX_CHANNELS 16u
#define N60_FOLD_OUTPUTS 2u

typedef struct n60_fold_matrix {
    uint32_t channel_count;                                  /* 3..N60_FOLD_MAX_CHANNELS */
    float gain[N60_FOLD_OUTPUTS][N60_FOLD_MAX_CHANNELS];     /* [0] left feed, [1] right feed, device channel order */
} n60_fold_matrix;

/* Builds a matrix from two rows of channel_count gains. Returns 1 on success, 0 on a bad count, a null
 * pointer or a non-finite gain (the matrix is then zeroed). */
int n60_fold_matrix_make(n60_fold_matrix *matrix, uint32_t channel_count, const float *left, const float *right);

/* E20 S10 part 7: declared non-blocking, so the bridge's realtime callbacks can be checked with -Wfunction-effects.
 * The definition (fold.cpp) is verified under -Werror=function-effects in the core build. */
#if defined(__clang__) && defined(__has_attribute) && !defined(__cplusplus)
#if __has_attribute(nonblocking)
#define N60_FOLD_PROCESS_EFFECTS __attribute__((nonblocking))
#endif
#elif defined(__cplusplus) && defined(__clang__) && defined(__has_cpp_attribute)
#if __has_cpp_attribute(clang::nonblocking)
#define N60_FOLD_PROCESS_EFFECTS noexcept [[clang::nonblocking]]
#endif
#endif
#ifndef N60_FOLD_PROCESS_EFFECTS
#define N60_FOLD_PROCESS_EFFECTS
#endif
/* Folds `frames` frames. channels[c] points at the first sample of channel c and strides[c] is the
 * distance in floats between consecutive frames of that channel. out receives interleaved L,R pairs
 * (2 * frames floats). A matrix of zero channels writes silence. Safe on a realtime thread. */
void n60_fold_down_process(const n60_fold_matrix *matrix, const float *const *channels, const uint32_t *strides,
                           uint32_t frames, float *out) N60_FOLD_PROCESS_EFFECTS;

#ifdef __cplusplus
}
#endif

#endif
