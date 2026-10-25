// Real-time analyser: IEC 61260-1 base-10 fractional-octave bands from a Hann FFT (E11 S8,
// design note 7). Worker thread only: create allocates, process reuses preallocated buffers
// except for the offline FFT's own scratch.
//
// Scaling: with a periodic Hann window w, the one-sided mean-square per bin is
// p_k = 2 |X_k|^2 / (N sum w^2) (halved at DC and Nyquist), so the sum over all bins equals the
// mean square of the frame (Parseval) and a sine of peak A reads A^2 / 2 in total. A band's
// power is the density p_k / binHz integrated over its exact edges, bins weighted by their
// overlap. Band layout: IEC 61260-1 section 5.4, G = 10^(3/10), odd N: fm = 1000 G^(x/N),
// even N: fm = 1000 G^((2x+1)/(2N)), edges fm G^(+-1/(2N)).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <new>
#include <vector>

#include "offline_fft.hpp"
#include "n60/measure.h"

namespace {

using n60::fft::offline::Cplx;
constexpr double kPi = 3.14159265358979323846264338327950288;

bool validOrder(uint32_t n) { return n == 1 || n == 3 || n == 6 || n == 12 || n == 24 || n == 48; }
bool validSize(uint32_t n) { return n >= 1024 && n <= (1u << 20) && (n & (n - 1)) == 0; }

struct Band {
    double centre, lower, upper;
};

bool layout(uint32_t n, double fs, double minHz, double maxHz, std::vector<Band> &out) {
    out.clear();
    if (!validOrder(n) || !(fs >= 8000) || !(minHz > 0) || !(maxHz > minHz)) return false;
    const double g = std::pow(10.0, 0.3);
    const double edge = std::pow(g, 1.0 / (2.0 * n));
    for (int32_t x = -14 * static_cast<int32_t>(n); x <= 14 * static_cast<int32_t>(n); ++x) {
        const double e = (n % 2 == 1) ? static_cast<double>(x) / n : (2.0 * x + 1.0) / (2.0 * n);
        const double fm = 1000.0 * std::pow(g, e);
        if (fm < minHz * 0.99 || fm > maxHz * 1.01) continue;  // nominal 20 Hz is 19.95 exactly
        if (fm * edge > fs * 0.5) continue;
        out.push_back({fm, fm / edge, fm * edge});
    }
    return !out.empty();
}

}  // namespace

struct n60_rta {
    n60_rta_params p{};
    std::vector<Band> bands;
    std::vector<double> window, history, frame, prefix, bandPower, avg;
    std::vector<Cplx> spectrum;
    uint64_t written = 0, sinceFrame = 0, frames = 0;
    double hop = 0, alpha = 1.0, sumW2 = 0, binHz = 0;
};

int32_t n60_rta_default_fft_size(double sample_rate, uint32_t bands_per_octave, uint32_t *size_out) {
    if (size_out == nullptr || !validOrder(bands_per_octave) || !std::isfinite(sample_rate) || sample_rate < 8000) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    const double g = std::pow(10.0, 0.3), edge = std::pow(g, 1.0 / (2.0 * bands_per_octave));
    const double target = 0.5 * 20.0 * (edge - 1.0 / edge);
    uint32_t n = 4096;
    while (n < (1u << 20) && sample_rate / n > target) n <<= 1;
    *size_out = n;
    return N60_MEASURE_OK;
}

int32_t n60_rta_band_layout(uint32_t bands_per_octave, double sample_rate, double min_hz, double max_hz, double *centre_hz,
                            double *lower_hz, double *upper_hz, uint32_t capacity, uint32_t *band_count) {
    if (band_count == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    std::vector<Band> bands;
    if (!layout(bands_per_octave, sample_rate, min_hz, max_hz, bands)) return N60_MEASURE_ERR_ARGUMENT;
    *band_count = static_cast<uint32_t>(bands.size());
    if (capacity < bands.size()) return N60_MEASURE_ERR_CAPACITY;
    for (size_t i = 0; i < bands.size(); ++i) {
        if (centre_hz) centre_hz[i] = bands[i].centre;
        if (lower_hz) lower_hz[i] = bands[i].lower;
        if (upper_hz) upper_hz[i] = bands[i].upper;
    }
    return N60_MEASURE_OK;
}

int32_t n60_rta_create(const n60_rta_params *params, n60_rta **rta_out) {
    if (params == nullptr || rta_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    *rta_out = nullptr;
    const n60_rta_params &p = *params;
    if (!std::isfinite(p.sample_rate) || p.sample_rate < 8000 || p.sample_rate > 768000 || !validSize(p.fft_size) ||
        !validOrder(p.bands_per_octave) || p.averaging > N60_RTA_AVERAGE_INFINITE || !std::isfinite(p.calibration_db) ||
        !(p.time_constant_seconds >= 0)) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    n60_rta *r = new (std::nothrow) n60_rta();
    if (r == nullptr) return N60_MEASURE_ERR_ALLOC;
    r->p = p;
    if (r->p.min_hz <= 0) r->p.min_hz = 20.0;
    if (r->p.max_hz <= 0) r->p.max_hz = std::min(20000.0, p.sample_rate / 2);
    if (!layout(r->p.bands_per_octave, p.sample_rate, r->p.min_hz, r->p.max_hz, r->bands)) {
        delete r;
        return N60_MEASURE_ERR_ARGUMENT;
    }
    const uint32_t n = p.fft_size;
    r->window.resize(n);
    for (uint32_t i = 0; i < n; ++i) {
        r->window[i] = 0.5 - 0.5 * std::cos(2.0 * kPi * i / n);
        r->sumW2 += r->window[i] * r->window[i];
    }
    r->history.assign(n, 0.0);
    r->frame.assign(n, 0.0);
    r->prefix.assign(n / 2 + 2, 0.0);
    r->bandPower.assign(r->bands.size(), 0.0);
    r->avg.assign(r->bands.size(), 0.0);
    r->binHz = p.sample_rate / n;
    r->hop = n / 2.0;
    r->alpha = (p.averaging == N60_RTA_AVERAGE_EXPONENTIAL && p.time_constant_seconds > 0)
                   ? 1.0 - std::exp(-(r->hop / p.sample_rate) / p.time_constant_seconds)
                   : 1.0;
    *rta_out = r;
    return N60_MEASURE_OK;
}

void n60_rta_destroy(n60_rta *rta) { delete rta; }

void n60_rta_reset(n60_rta *r) {
    if (r == nullptr) return;
    std::fill(r->history.begin(), r->history.end(), 0.0);
    std::fill(r->avg.begin(), r->avg.end(), 0.0);
    r->written = r->sinceFrame = r->frames = 0;
}

namespace {

// Integral of the one-sided power density from 0 to f. Bin k spans u in [k, k+1], u = f / binHz + 0.5.
double cumulative(const n60_rta &r, double f, const std::vector<double> &power) {
    const size_t bins = power.size();
    double u = f / r.binHz + 0.5;
    if (u <= 0) return 0;
    if (u >= static_cast<double>(bins)) return r.prefix[bins];
    const size_t i = static_cast<size_t>(u);
    return r.prefix[i] + (u - static_cast<double>(i)) * power[i];
}

void analyseFrame(n60_rta &r, std::vector<double> &power) {
    const uint32_t n = r.p.fft_size;
    n60::fft::offline::realForward(r.frame.data(), n, r.spectrum);
    const double scale = 2.0 / (static_cast<double>(n) * r.sumW2);
    const size_t bins = n / 2 + 1;
    power.resize(bins);
    r.prefix[0] = 0;
    for (size_t k = 0; k < bins; ++k) {
        const double mag2 = r.spectrum[k].re * r.spectrum[k].re + r.spectrum[k].im * r.spectrum[k].im;
        power[k] = mag2 * scale * ((k == 0 || k == bins - 1) ? 0.5 : 1.0);
        r.prefix[k + 1] = r.prefix[k] + power[k];
    }
    for (size_t b = 0; b < r.bands.size(); ++b) {
        r.bandPower[b] = std::max(0.0, cumulative(r, r.bands[b].upper, power) - cumulative(r, r.bands[b].lower, power));
    }
    ++r.frames;
    if (r.p.averaging == N60_RTA_AVERAGE_NONE || r.frames == 1) {
        r.avg = r.bandPower;
    } else if (r.p.averaging == N60_RTA_AVERAGE_INFINITE) {
        const double w = 1.0 / static_cast<double>(r.frames);
        for (size_t b = 0; b < r.avg.size(); ++b) r.avg[b] += w * (r.bandPower[b] - r.avg[b]);
    } else {
        for (size_t b = 0; b < r.avg.size(); ++b) r.avg[b] += r.alpha * (r.bandPower[b] - r.avg[b]);
    }
}

}  // namespace

int32_t n60_rta_process(n60_rta *r, const float *samples, uint64_t count) {
    if (r == nullptr || (samples == nullptr && count != 0)) return N60_MEASURE_ERR_ARGUMENT;
    const uint32_t n = r->p.fft_size;
    const uint64_t hop = n / 2;
    std::vector<double> power;
    for (uint64_t i = 0; i < count; ++i) {
        r->history[r->written % n] = std::isfinite(samples[i]) ? static_cast<double>(samples[i]) : 0.0;
        ++r->written;
        ++r->sinceFrame;
        if (r->written >= n && r->sinceFrame >= hop) {
            r->sinceFrame = 0;
            for (uint32_t j = 0; j < n; ++j) r->frame[j] = r->history[(r->written - n + j) % n] * r->window[j];
            if (power.empty()) power.reserve(n / 2 + 1);
            analyseFrame(*r, power);
        }
    }
    return N60_MEASURE_OK;
}

uint32_t n60_rta_band_count(const n60_rta *r) { return r == nullptr ? 0 : static_cast<uint32_t>(r->bands.size()); }
uint64_t n60_rta_frames_analysed(const n60_rta *r) { return r == nullptr ? 0 : r->frames; }

int32_t n60_rta_read(const n60_rta *r, double *centre_hz, double *level_db, uint32_t capacity, uint32_t *band_count) {
    if (r == nullptr || band_count == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    *band_count = static_cast<uint32_t>(r->bands.size());
    if (capacity < r->bands.size()) return N60_MEASURE_ERR_CAPACITY;
    for (size_t b = 0; b < r->bands.size(); ++b) {
        if (centre_hz) centre_hz[b] = r->bands[b].centre;
        if (level_db) {
            level_db[b] = (r->frames > 0 && r->avg[b] > 1e-20 ? 10.0 * std::log10(r->avg[b]) : N60_SPL_FLOOR_DB) + r->p.calibration_db;
        }
    }
    return N60_MEASURE_OK;
}
