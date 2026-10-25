// Full-circular regularised deconvolution (E11 S1, design note 3).
//
// H = Y conj(X) / (|X|^2 + lambda), lambda = ratio * max |X|^2: the same maths as the Swift
// analyser (RoomCorrectionMeasurementAnalyzer), but in double precision and returning the
// whole circular response so the negative-time harmonic impulses are kept.
#include <cmath>
#include <cstdint>
#include <vector>

#include "offline_fft.hpp"
#include "n60/measure.h"

namespace {
using n60::fft::offline::Cplx;
}

extern "C" {

uint32_t n60_measure_abi_version(void) { return N60_MEASURE_ABI_VERSION; }

int32_t n60_measure_transform_size(uint64_t required_frames, uint64_t *size_out) {
    if (size_out == nullptr || required_frames < 1) return N60_MEASURE_ERR_ARGUMENT;
    uint64_t size = 2;
    while (size < required_frames) {
        if (size >= N60_MEASURE_MAX_TRANSFORM) return N60_MEASURE_ERR_SIZE;
        size <<= 1;
    }
    if (size > N60_MEASURE_MAX_TRANSFORM) return N60_MEASURE_ERR_SIZE;
    *size_out = size;
    return N60_MEASURE_OK;
}

int32_t n60_measure_deconvolve(const float *excitation, uint64_t excitation_count,
                               const float *observed, uint64_t observed_count,
                               double regularization_ratio,
                               float *out, uint64_t out_capacity, uint64_t *out_count) {
    if (excitation == nullptr || observed == nullptr || out == nullptr || out_count == nullptr ||
        excitation_count == 0 || observed_count < 2 || excitation_count > observed_count ||
        !std::isfinite(regularization_ratio) || regularization_ratio < 0) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    uint64_t n = 0;
    const int32_t sizeStatus = n60_measure_transform_size(observed_count, &n);
    if (sizeStatus != N60_MEASURE_OK) return sizeStatus;
    if (out_capacity < n) return N60_MEASURE_ERR_CAPACITY;

    std::vector<Cplx> spectrumX;
    std::vector<Cplx> spectrumY;
    {
        std::vector<double> buffer(n, 0.0);
        for (uint64_t i = 0; i < excitation_count; ++i) buffer[i] = excitation[i];
        if (!n60::fft::offline::realForward(buffer.data(), n, spectrumX)) return N60_MEASURE_ERR_ALLOC;
        for (uint64_t i = 0; i < n; ++i) buffer[i] = i < observed_count ? observed[i] : 0.0;
        if (!n60::fft::offline::realForward(buffer.data(), n, spectrumY)) return N60_MEASURE_ERR_ALLOC;
    }
    double maxPower = 0.0;
    for (const Cplx &c : spectrumX) {
        const double power = c.re * c.re + c.im * c.im;
        if (power > maxPower) maxPower = power;
    }
    if (!std::isfinite(maxPower) || maxPower <= 1e-300) return N60_MEASURE_ERR_UNUSABLE_EXCITATION;
    double lambda = maxPower * regularization_ratio;
    if (lambda < 1e-300) lambda = 1e-300;
    for (size_t k = 0; k < spectrumX.size(); ++k) {
        const Cplx x = spectrumX[k];
        const Cplx y = spectrumY[k];
        const double denominator = x.re * x.re + x.im * x.im + lambda;
        spectrumY[k] = Cplx{(y.re * x.re + y.im * x.im) / denominator,
                            (y.im * x.re - y.re * x.im) / denominator};
    }
    std::vector<double> response;
    if (!n60::fft::offline::realInverse(spectrumY, n, response)) return N60_MEASURE_ERR_ALLOC;
    for (uint64_t i = 0; i < n; ++i) out[i] = static_cast<float>(response[i]);
    *out_count = n;
    return N60_MEASURE_OK;
}

}  // extern "C"
