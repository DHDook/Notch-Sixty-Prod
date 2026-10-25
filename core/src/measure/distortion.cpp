// H2..H5 from a synchronised-ESS response (E11 S3, design note 9).
//
// With a synchronised sweep the k-th harmonic impulse sits exactly L ln k before the linear
// impulse in the circular deconvolved response. Each impulse is windowed to half the gap to
// the next impulse in time; the windowed spectrum of harmonic k, read at k f, is the level of
// that harmonic produced by a fundamental at f. Power is smoothed in fractions of an octave
// and compared with the linear response at f through the same window, so the room response
// inside the window cancels and a flat direct path reads the generator's levels exactly.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

#include "band_mean.hpp"
#include "offline_fft.hpp"
#include "n60/measure.h"

namespace {

using n60::measure::BandMean;
using n60::fft::offline::Cplx;
constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr int kHarmonics = N60_MEASURE_MAX_HARMONIC;

bool validParams(const n60_measure_distortion_params *p) {
    return p != nullptr && std::isfinite(p->sample_rate) && p->sample_rate >= 8000 && p->sample_rate <= 768000 &&
           std::isfinite(p->sweep_start_hz) && std::isfinite(p->sweep_end_hz) && p->sweep_start_hz > 0 &&
           p->sweep_end_hz > p->sweep_start_hz * 1.5 && p->sweep_end_hz < p->sample_rate * 0.5 &&
           std::isfinite(p->sweep_rate_seconds) && p->sweep_rate_seconds > 0 &&
           std::isfinite(p->smoothing_octaves) && p->smoothing_octaves >= 0 && p->smoothing_octaves <= 2 &&
           p->points_per_octave >= 1 && p->points_per_octave <= 96 && std::isfinite(p->response_seconds) &&
           p->response_seconds >= 0 && std::isfinite(p->edge_guard_octaves) && p->edge_guard_octaves >= 0 &&
           p->edge_guard_octaves <= 1;
}

// Power spectrum of response[centre - pre, centre + length) (circular), half-Hann rise over
// `pre` frames and half-Hann fall over the last half, zero padded to m.
bool windowedPower(const float *x, uint64_t n, uint64_t centre, uint64_t pre, uint64_t length, uint64_t m,
                   std::vector<double> &power) {
    std::vector<double> buffer(m, 0.0);
    const uint64_t total = pre + length;
    const uint64_t fall = std::max<uint64_t>(1, length / 2);
    for (uint64_t j = 0; j < total && j < m; ++j) {
        const uint64_t index = (centre + n - pre + j) % n;
        double w = 1.0;
        if (j < pre) {
            w = 0.5 * (1.0 - std::cos(kPi * (static_cast<double>(j) + 0.5) / static_cast<double>(pre)));
        } else if (j >= total - fall) {
            w = 0.5 * (1.0 + std::cos(kPi * (static_cast<double>(j - (total - fall)) + 0.5) / static_cast<double>(fall)));
        }
        buffer[j] = w * x[index];
    }
    std::vector<Cplx> spectrum;
    if (!n60::fft::offline::realForward(buffer.data(), m, spectrum)) return false;
    power.resize(spectrum.size());
    for (size_t k = 0; k < spectrum.size(); ++k) power[k] = spectrum[k].re * spectrum[k].re + spectrum[k].im * spectrum[k].im;
    return true;
}

double gapFrames(const n60_measure_distortion_params *p, int k) {  // harmonic k to harmonic k-1 (k=2: to the linear)
    return p->sweep_rate_seconds * std::log(static_cast<double>(k) / (k - 1)) * p->sample_rate;
}

}  // namespace

extern "C" {

void n60_measure_distortion_defaults(double sample_rate, const n60_measure_ess_info *sweep, double start_hz,
                                     double end_hz, n60_measure_distortion_params *p) {
    if (p == nullptr) return;
    *p = n60_measure_distortion_params{};
    p->sample_rate = sample_rate;
    p->sweep_start_hz = start_hz;
    p->sweep_end_hz = end_hz;
    p->sweep_rate_seconds = sweep != nullptr ? sweep->sweep_rate_seconds : 0.0;
    p->linear_index = UINT64_MAX;
    p->smoothing_octaves = 1.0 / 3.0;
    p->points_per_octave = 12;
    p->response_seconds = 0.05;
    p->edge_guard_octaves = 0.1;
}

double n60_measure_distortion_min_sweep_seconds(double start_hz, double end_hz, double response_seconds) {
    if (!(start_hz > 0) || !(end_hz > start_hz) || !(response_seconds >= 0)) return 0.0;
    const double rate = 2.0 * response_seconds / std::log(5.0 / 4.0);
    return rate * std::log(end_hz / start_hz);
}

int32_t n60_measure_distortion_analyze(const n60_measure_distortion_params *params, const float *response,
                                       uint64_t response_count, double *frequency_hz, double *fundamental_db,
                                       double *harmonic_db[N60_MEASURE_MAX_HARMONIC - 1], double *thd_db,
                                       uint32_t capacity, n60_measure_distortion_info *info_out) {
    if (!validParams(params) || response == nullptr || frequency_hz == nullptr || fundamental_db == nullptr ||
        harmonic_db == nullptr || thd_db == nullptr || info_out == nullptr || response_count < 1024) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    for (int h = 0; h < kHarmonics - 1; ++h) {
        if (harmonic_db[h] == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    }
    const double fs = params->sample_rate;
    const uint64_t n = response_count;
    const double ratio = params->sweep_end_hz / params->sweep_start_hz;
    const uint32_t points = static_cast<uint32_t>(std::floor(std::log2(ratio) * params->points_per_octave + 1e-9)) + 1;
    *info_out = n60_measure_distortion_info{};
    info_out->point_count = points;
    if (capacity < points) return N60_MEASURE_ERR_CAPACITY;

    uint64_t p0 = params->linear_index;
    if (p0 == UINT64_MAX) {
        double best = -1.0;
        for (uint64_t i = 0; i < n / 2; ++i) {
            const double a = std::fabs(static_cast<double>(response[i]));
            if (a > best) { best = a; p0 = i; }
        }
    }
    if (p0 >= n) return N60_MEASURE_ERR_ARGUMENT;
    info_out->linear_index = p0;

    // Window geometry per harmonic (frames).
    uint64_t centre[kHarmonics + 1] = {0}, pre[kHarmonics + 1] = {0}, length[kHarmonics + 1] = {0};
    uint64_t longest = 0;
    for (int k = 2; k <= kHarmonics; ++k) {
        const double lead = params->sweep_rate_seconds * std::log(static_cast<double>(k)) * fs;
        const uint64_t leadFrames = static_cast<uint64_t>(std::llround(lead)) % n;
        centre[k] = (p0 + n - leadFrames) % n;
        const double gap = gapFrames(params, k);
        length[k] = std::max<uint64_t>(16, static_cast<uint64_t>(0.5 * gap));
        pre[k] = std::max<uint64_t>(4, std::min<uint64_t>(static_cast<uint64_t>(0.02 * fs), static_cast<uint64_t>(0.4 * gap)));
        longest = std::max(longest, pre[k] + length[k]);
    }
    const uint64_t pre1 = pre[2];
    const double shortest = static_cast<double>(length[kHarmonics]) / fs;
    info_out->min_window_seconds = shortest;
    info_out->min_sweep_seconds =
        n60_measure_distortion_min_sweep_seconds(params->sweep_start_hz, params->sweep_end_hz, params->response_seconds);
    info_out->clean_separation = (params->sweep_rate_seconds * std::log(ratio) >= info_out->min_sweep_seconds) ? 1 : 0;

    uint64_t m = 2;
    while (m < longest) m <<= 1;
    if (m > N60_MEASURE_MAX_TRANSFORM) return N60_MEASURE_ERR_SIZE;
    const double binHz = fs / static_cast<double>(m);

    // Fundamental through each harmonic's window (so room response in the window cancels), plus
    // one through the H2 window for the reported fundamental curve.
    std::vector<double> power;
    std::vector<BandMean> fundamental;
    std::vector<BandMean> harmonic;
    fundamental.reserve(kHarmonics + 1);
    harmonic.reserve(kHarmonics + 1);
    for (int k = 0; k <= kHarmonics; ++k) {
        fundamental.emplace_back(std::vector<double>{0.0}, binHz);
        harmonic.emplace_back(std::vector<double>{0.0}, binHz);
    }
    for (int k = 2; k <= kHarmonics; ++k) {
        if (!windowedPower(response, n, centre[k], pre[k], length[k], m, power)) return N60_MEASURE_ERR_ALLOC;
        harmonic[k] = BandMean(power, binHz);
        if (!windowedPower(response, n, p0, pre1, length[k], m, power)) return N60_MEASURE_ERR_ALLOC;
        fundamental[k] = BandMean(power, binHz);
    }

    const double half = std::pow(2.0, params->smoothing_octaves / 2.0);
    const double guard = std::pow(2.0, -params->edge_guard_octaves);
    auto dB = [](double num, double den) {
        return std::max(-300.0, 10.0 * std::log10(std::max(num, 1e-300) / std::max(den, 1e-300)));
    };
    for (uint32_t i = 0; i < points; ++i) {
        const double f = params->sweep_start_hz * std::pow(2.0, static_cast<double>(i) / params->points_per_octave);
        frequency_hz[i] = f;
        // The sweep has no energy below its start: clamp every smoothing band to the swept range.
        const double fLo = std::max(f / half, params->sweep_start_hz);
        const double refLevel = fundamental[2].mean(fLo, std::max(f * half, fLo), f);
        fundamental_db[i] = 10.0 * std::log10(std::max(refLevel, 1e-300));
        double thdPower = 0.0;
        bool any = false;
        for (int k = 2; k <= kHarmonics; ++k) {
            const double fk = f * k;
            if (fk * half > params->sweep_end_hz * guard) {
                harmonic_db[k - 2][i] = N60_MEASURE_NO_DATA_DB;
                continue;
            }
            const double hi = fk * half;
            const double lo = std::min(std::max(fk / half, k * params->sweep_start_hz), hi);
            const double ph = harmonic[k].mean(lo, hi, fk);
            const double pf = fundamental[k].mean(fLo, std::max(f * half, fLo), f);
            const double level = dB(ph, pf);
            harmonic_db[k - 2][i] = level;
            thdPower += std::pow(10.0, level / 10.0);
            any = true;
        }
        thd_db[i] = any ? 10.0 * std::log10(std::max(thdPower, 1e-30)) : N60_MEASURE_NO_DATA_DB;
    }
    return N60_MEASURE_OK;
}

}  // extern "C"
