// Exponential sine sweep generation (E11 S1, design note 3).
//
// Synchronised ESS after Novak, Simon, Kadlec and Lotton, "Nonlinear system identification
// using exponential swept-sine signal" (IEEE Trans. Instrum. Meas., 2010) and Novak, Lotton
// and Simon, "Synchronized swept-sine" (J. Audio Eng. Soc. 63(10), 2015): the sweep rate is
// L = round(f1 T / ln(f2/f1)) / f1, so f1 L is an integer and the k-th harmonic impulse lands
// at the exact, phase-coherent offset -L ln k from the linear impulse.
#include <cmath>
#include <cstdint>

#include "n60/measure.h"

namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr double kMaxDurationSeconds = 60.0;

bool validParams(const n60_measure_ess_params *p) {
    if (p == nullptr) return false;
    return std::isfinite(p->sample_rate) && p->sample_rate > 0 && std::isfinite(p->start_hz) &&
           p->start_hz > 0 && std::isfinite(p->end_hz) && p->end_hz > p->start_hz &&
           p->end_hz < p->sample_rate * 0.5 && std::isfinite(p->duration_seconds) &&
           p->duration_seconds > 0 && p->duration_seconds <= kMaxDurationSeconds &&
           std::isfinite(p->level_dbfs) && p->level_dbfs <= 0 && std::isfinite(p->fade_seconds) &&
           p->fade_seconds >= 0 && p->fade_seconds <= p->duration_seconds * 0.5;
}

void describe(const n60_measure_ess_params *p, n60_measure_ess_info *info) {
    const double ratio = std::log(p->end_hz / p->start_hz);
    double rate = p->duration_seconds / ratio;
    if (p->synchronised != 0) {
        double cycles = std::round(p->start_hz * rate);
        if (cycles < 1.0) cycles = 1.0;
        rate = cycles / p->start_hz;
    }
    info->sweep_rate_seconds = rate;
    info->duration_seconds = rate * ratio;
    info->frame_count = static_cast<uint64_t>(std::llround(info->duration_seconds * p->sample_rate));
}

}  // namespace

extern "C" {

int32_t n60_measure_ess_describe(const n60_measure_ess_params *params, n60_measure_ess_info *info_out) {
    if (!validParams(params) || info_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    describe(params, info_out);
    if (info_out->frame_count < 2) return N60_MEASURE_ERR_ARGUMENT;
    return N60_MEASURE_OK;
}

int32_t n60_measure_ess_generate(const n60_measure_ess_params *params, float *out, uint64_t capacity,
                                 n60_measure_ess_info *info_out) {
    n60_measure_ess_info info{};
    const int32_t status = n60_measure_ess_describe(params, &info);
    if (status != N60_MEASURE_OK) return status;
    if (out == nullptr || capacity < info.frame_count) return N60_MEASURE_ERR_CAPACITY;
    const double amplitude = std::pow(10.0, params->level_dbfs / 20.0);
    const double rate = info.sweep_rate_seconds;
    const double phaseScale = 2.0 * kPi * params->start_hz * rate;
    uint64_t fade = static_cast<uint64_t>(std::llround(params->fade_seconds * params->sample_rate));
    if (fade > info.frame_count / 2) fade = info.frame_count / 2;
    for (uint64_t i = 0; i < info.frame_count; ++i) {
        const double t = static_cast<double>(i) / params->sample_rate;
        // expm1 keeps the phase accurate near t = 0.
        const double phase = phaseScale * std::expm1(t / rate);
        double envelope = 1.0;
        if (fade > 1) {
            if (i < fade) {
                envelope *= 0.5 - 0.5 * std::cos(kPi * static_cast<double>(i) / static_cast<double>(fade - 1));
            }
            if (i >= info.frame_count - fade) {
                const uint64_t r = info.frame_count - 1 - i;
                envelope *= 0.5 - 0.5 * std::cos(kPi * static_cast<double>(r) / static_cast<double>(fade - 1));
            }
        }
        out[i] = static_cast<float>(amplitude * envelope * std::sin(phase));
    }
    if (info_out != nullptr) *info_out = info;
    return N60_MEASURE_OK;
}

double n60_measure_ess_harmonic_lead_seconds(const n60_measure_ess_info *info, uint32_t harmonic) {
    if (info == nullptr || harmonic < 2) return 0.0;
    return info->sweep_rate_seconds * std::log(static_cast<double>(harmonic));
}

}  // extern "C"
