// E25 S8a program fold-down. See n60/fold.h for the derivation and the realtime notes.
#include "n60/fold.h"

#include <cmath>
#include <cstddef>

extern "C" {

int n60_fold_matrix_make(n60_fold_matrix *matrix, uint32_t channel_count, const float *left, const float *right) {
    if (matrix == nullptr) return 0;
    *matrix = n60_fold_matrix{};
    if (channel_count < 3u || channel_count > N60_FOLD_MAX_CHANNELS || left == nullptr || right == nullptr) return 0;
    for (uint32_t c = 0; c < channel_count; ++c) {
        if (!std::isfinite(left[c]) || !std::isfinite(right[c])) return 0;
    }
    matrix->channel_count = channel_count;
    for (uint32_t c = 0; c < channel_count; ++c) {
        matrix->gain[0][c] = left[c];
        matrix->gain[1][c] = right[c];
    }
    return 1;
}

void n60_fold_down_process(const n60_fold_matrix *matrix, const float *const *channels, const uint32_t *strides,
                           uint32_t frames, float *out) N60_FOLD_PROCESS_EFFECTS {
    if (out == nullptr || frames == 0u) return;
    if (matrix == nullptr || channels == nullptr || strides == nullptr || matrix->channel_count == 0u ||
        matrix->channel_count > N60_FOLD_MAX_CHANNELS) {
        for (uint32_t i = 0; i < 2u * frames; ++i) out[i] = 0.0f;
        return;
    }
    const uint32_t count = matrix->channel_count;
    for (uint32_t n = 0; n < frames; ++n) {
        float l = 0.0f;
        float r = 0.0f;
        for (uint32_t c = 0; c < count; ++c) {
            const float x = channels[c][static_cast<std::size_t>(n) * strides[c]];
            l += matrix->gain[0][c] * x;
            r += matrix->gain[1][c] * x;
        }
        out[2u * n] = l;
        out[2u * n + 1u] = r;
    }
}

}  // extern "C"
