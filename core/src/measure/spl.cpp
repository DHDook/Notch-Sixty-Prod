// SPL meter: A, C and Z weighting, Fast, Slow, Leq and C-peak (E11 S8, design note 7).
//
// Weighting: the analogue A and C prototypes of IEC 61672-1 (poles 20.598997, 107.65265,
// 737.86223 and 12194.217 Hz) mapped to biquads by the bilinear transform, pre-warped so the
// mapping is exact at 1 kHz, then normalised to 0 dB at 1 kHz. Double precision, transposed
// direct form II. The warping error above about 0.2 fs is inside the class 1 tolerance for
// every standard rate (tested). Time weighting: first-order exponential on the squared
// weighted signal (IEC 61672-1, 125 ms and 1 s).
// Worker thread only: create allocates, process does not.
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <new>

#include "n60/measure.h"

namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr double kPoleLow = 20.598997;
constexpr double kPoleMid1 = 107.65265;
constexpr double kPoleMid2 = 737.86223;
constexpr double kPoleHigh = 12194.217;

struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;
    double step(double x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    std::complex<double> response(double w) const {
        const std::complex<double> q = std::polar(1.0, -w);
        return (b0 + b1 * q + b2 * q * q) / (1.0 + a1 * q + a2 * q * q);
    }
};

// Analogue section (n2 s^2 + n1 s + n0) / (d2 s^2 + d1 s + d0) -> biquad, s = K (1 - q) / (1 + q).
Biquad section(double n2, double n1, double n0, double d2, double d1, double d0, double K) {
    const double K2 = K * K;
    const double nb0 = n2 * K2 + n1 * K + n0, nb1 = -2.0 * n2 * K2 + 2.0 * n0, nb2 = n2 * K2 - n1 * K + n0;
    const double da0 = d2 * K2 + d1 * K + d0, da1 = -2.0 * d2 * K2 + 2.0 * d0, da2 = d2 * K2 - d1 * K + d0;
    Biquad s;
    s.b0 = nb0 / da0;
    s.b1 = nb1 / da0;
    s.b2 = nb2 / da0;
    s.a1 = da1 / da0;
    s.a2 = da2 / da0;
    return s;
}

struct Chain {
    Biquad s[3];
    int count = 0;
    double gain = 1.0;
    double step(double x) {
        double y = x * gain;
        for (int i = 0; i < count; ++i) y = s[i].step(y);
        return y;
    }
    double magnitude(double w) const {
        std::complex<double> h = gain;
        for (int i = 0; i < count; ++i) h *= s[i].response(w);
        return std::abs(h);
    }
};

bool design(Chain &c, uint32_t weighting, double fs) {
    c = Chain();
    if (weighting == N60_SPL_WEIGHT_Z) return true;
    if (weighting != N60_SPL_WEIGHT_A && weighting != N60_SPL_WEIGHT_C) return false;
    const double w0 = 2.0 * kPi * 1000.0;
    const double K = w0 / std::tan(w0 / (2.0 * fs));
    const double a = 2.0 * kPi * kPoleLow, p = 2.0 * kPi * kPoleMid1, q = 2.0 * kPi * kPoleMid2, h = 2.0 * kPi * kPoleHigh;
    c.s[c.count++] = section(1, 0, 0, 1, 2 * a, a * a, K);
    if (weighting == N60_SPL_WEIGHT_A) c.s[c.count++] = section(1, 0, 0, 1, p + q, p * q, K);
    c.s[c.count++] = section(0, 0, 1, 1, 2 * h, h * h, K);
    c.gain = 1.0 / c.magnitude(2.0 * kPi * 1000.0 / fs);
    return std::isfinite(c.gain);
}

double toDB(double ms) { return ms > 1e-20 ? 10.0 * std::log10(ms) : N60_SPL_FLOOR_DB; }

}  // namespace

struct n60_spl_meter {
    double fs = 48000;
    Chain weighting;
    Chain cPeak;
    double alphaFast = 0, alphaSlow = 0;
    double fast = 0, slow = 0, sumSq = 0, peak = 0;
    uint64_t frames = 0;
    double offset = 0;
};

int32_t n60_spl_create(double sample_rate, uint32_t weighting, n60_spl_meter **meter_out) {
    if (meter_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    *meter_out = nullptr;
    if (!std::isfinite(sample_rate) || sample_rate < 8000 || sample_rate > 768000) return N60_MEASURE_ERR_ARGUMENT;
    n60_spl_meter *m = new (std::nothrow) n60_spl_meter();
    if (m == nullptr) return N60_MEASURE_ERR_ALLOC;
    m->fs = sample_rate;
    if (!design(m->weighting, weighting, sample_rate) || !design(m->cPeak, N60_SPL_WEIGHT_C, sample_rate)) {
        delete m;
        return N60_MEASURE_ERR_ARGUMENT;
    }
    m->alphaFast = 1.0 - std::exp(-1.0 / (0.125 * sample_rate));
    m->alphaSlow = 1.0 - std::exp(-1.0 / (1.0 * sample_rate));
    *meter_out = m;
    return N60_MEASURE_OK;
}

void n60_spl_destroy(n60_spl_meter *meter) { delete meter; }

void n60_spl_reset(n60_spl_meter *m) {
    if (m == nullptr) return;
    for (Biquad &b : m->weighting.s) b.z1 = b.z2 = 0;
    for (Biquad &b : m->cPeak.s) b.z1 = b.z2 = 0;
    m->fast = m->slow = m->sumSq = m->peak = 0;
    m->frames = 0;
}

int32_t n60_spl_set_calibration_db(n60_spl_meter *m, double offset_db) {
    if (m == nullptr || !std::isfinite(offset_db) || std::fabs(offset_db) > 300.0) return N60_MEASURE_ERR_ARGUMENT;
    m->offset = offset_db;
    return N60_MEASURE_OK;
}

int32_t n60_spl_process(n60_spl_meter *m, const float *samples, uint64_t count) {
    if (m == nullptr || (samples == nullptr && count != 0)) return N60_MEASURE_ERR_ARGUMENT;
    double fast = m->fast, slow = m->slow, sum = m->sumSq, peak = m->peak;
    for (uint64_t i = 0; i < count; ++i) {
        const double x = std::isfinite(samples[i]) ? static_cast<double>(samples[i]) : 0.0;
        const double y = m->weighting.step(x);
        const double c = m->cPeak.step(x);
        const double sq = y * y;
        fast += m->alphaFast * (sq - fast);
        slow += m->alphaSlow * (sq - slow);
        sum += sq;
        peak = std::max(peak, std::fabs(c));
    }
    m->fast = fast;
    m->slow = slow;
    m->sumSq = sum;
    m->peak = peak;
    m->frames += count;
    return N60_MEASURE_OK;
}

int32_t n60_spl_read(const n60_spl_meter *m, n60_spl_reading *out) {
    if (m == nullptr || out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    out->fast_db = toDB(m->fast) + m->offset;
    out->slow_db = toDB(m->slow) + m->offset;
    out->leq_db = (m->frames ? toDB(m->sumSq / static_cast<double>(m->frames)) : N60_SPL_FLOOR_DB) + m->offset;
    out->c_peak_db = (m->peak > 1e-10 ? 20.0 * std::log10(m->peak) : N60_SPL_FLOOR_DB) + m->offset;
    out->elapsed_seconds = static_cast<double>(m->frames) / m->fs;
    return N60_MEASURE_OK;
}

int32_t n60_spl_weighting_response_db(double sample_rate, uint32_t weighting, double frequency_hz, double *db_out) {
    if (db_out == nullptr || !std::isfinite(sample_rate) || sample_rate < 8000 || !std::isfinite(frequency_hz) ||
        frequency_hz <= 0 || frequency_hz >= sample_rate / 2) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    Chain c;
    if (!design(c, weighting, sample_rate)) return N60_MEASURE_ERR_ARGUMENT;
    *db_out = 20.0 * std::log10(c.magnitude(2.0 * kPi * frequency_hz / sample_rate));
    return N60_MEASURE_OK;
}
