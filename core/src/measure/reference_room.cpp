// Deterministic synthetic reference room (E11 S1, design note 13).
//
// A known impulse response (direct arrival, a few exponentially decaying modes, and a
// diffuse tail with a set RT60 per octave band), a harmonic generator with exact
// H2..H5 levels, latency, clock drift and seeded noise. It exists so
// every analysis test has a ground truth; it is shipped in the core so XCTest can reach it.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "offline_fft.hpp"
#include "n60/measure.h"

namespace {

using n60::fft::offline::Cplx;
constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr double kLn1000 = 6.907755278982137;  // 60 dB as a natural-log amplitude decay
constexpr uint64_t kGuardFrames = 64;

struct Rng {
    uint64_t state;
    explicit Rng(uint32_t seed) : state(0x9E3779B97F4A7C15ull ^ (static_cast<uint64_t>(seed) << 17) ^ seed) {
        if (state == 0) state = 1;
    }
    uint64_t next() {  // xorshift64*
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        return state * 0x2545F4914F6CDD1Dull;
    }
    double uniform() { return (static_cast<double>(next() >> 11) + 0.5) / 9007199254740992.0; }
    double gaussian() {
        const double a = uniform();
        const double b = uniform();
        return std::sqrt(-2.0 * std::log(a)) * std::cos(2.0 * kPi * b);
    }
};

bool validRoom(const n60_measure_room_params *p) {
    if (p == nullptr) return false;
    if (!std::isfinite(p->sample_rate) || p->sample_rate < 8000 || p->sample_rate > 768000) return false;
    if (!std::isfinite(p->ir_seconds) || p->ir_seconds <= 0 || p->ir_seconds > 10) return false;
    if (!std::isfinite(p->direct_delay_seconds) || p->direct_delay_seconds < 0 ||
        p->direct_delay_seconds >= p->ir_seconds) {
        return false;
    }
    if (!std::isfinite(p->latency_seconds) || p->latency_seconds < 0 || p->latency_seconds > 5) return false;
    if (!std::isfinite(p->drift_ppm) || std::fabs(p->drift_ppm) > 1000) return false;
    for (int b = 0; b < N60_MEASURE_ROOM_BANDS; ++b) {
        if (!std::isfinite(p->rt60_seconds[b]) || p->rt60_seconds[b] <= 0) return false;
    }
    return true;
}

uint64_t irFrames(const n60_measure_room_params *p) {
    return static_cast<uint64_t>(std::llround(p->ir_seconds * p->sample_rate));
}

bool buildIr(const n60_measure_room_params *p, std::vector<double> &ir) {
    const uint64_t len = irFrames(p);
    const double fs = p->sample_rate;
    ir.assign(len, 0.0);
    const uint64_t delay = static_cast<uint64_t>(std::llround(p->direct_delay_seconds * fs));
    if (delay >= len) return false;
    ir[delay] += p->direct_gain;

    for (int m = 0; m < 4; ++m) {
        const double f = p->mode_frequencies_hz[m];
        if (f <= 0 || p->mode_decay_seconds[m] <= 0 || f >= fs * 0.45) continue;
        const double level = p->direct_gain * std::pow(10.0, p->mode_level_db[m] / 20.0);
        for (uint64_t i = delay + 1; i < len; ++i) {
            const double t = static_cast<double>(i - delay) / fs;
            ir[i] += level * std::exp(-kLn1000 * t / p->mode_decay_seconds[m]) * std::sin(2.0 * kPi * f * t);
        }
    }

    uint64_t n = 2;
    while (n < len) n <<= 1;
    Rng rng(p->seed);
    std::vector<double> tail(len, 0.0);
    for (int b = 0; b < N60_MEASURE_ROOM_BANDS; ++b) {
        const double centre = 125.0 * std::pow(2.0, b);
        const double lo = centre / std::sqrt(2.0);
        const double hi = std::min(centre * std::sqrt(2.0), fs * 0.45);
        std::vector<Cplx> spectrum(n / 2 + 1, Cplx{0.0, 0.0});
        for (uint64_t k = 1; k < n / 2; ++k) {
            const double f = static_cast<double>(k) * fs / static_cast<double>(n);
            const double phase = 2.0 * kPi * rng.uniform();  // drawn for every bin: stable stream
            if (f >= lo && f < hi) spectrum[k] = Cplx{std::cos(phase), std::sin(phase)};
        }
        std::vector<double> band;
        if (!n60::fft::offline::realInverse(spectrum, n, band)) return false;
        for (uint64_t i = delay + 1; i < len; ++i) {
            const double t = static_cast<double>(i - delay) / fs;
            tail[i] += band[i] * std::exp(-kLn1000 * t / p->rt60_seconds[b]);
        }
    }
    // Normalise the tail so its RMS over the first 50 ms equals the requested level.
    const uint64_t window = std::min<uint64_t>(len - delay - 1, static_cast<uint64_t>(0.05 * fs));
    double energy = 0.0;
    for (uint64_t i = 0; i < window; ++i) energy += tail[delay + 1 + i] * tail[delay + 1 + i];
    if (window > 0 && energy > 0.0) {
        const double rms = std::sqrt(energy / static_cast<double>(window));
        const double scale = p->direct_gain * std::pow(10.0, p->diffuse_level_db / 20.0) / rms;
        for (uint64_t i = delay + 1; i < len; ++i) ir[i] += tail[i] * scale;
    }
    return true;
}

}  // namespace

extern "C" {

void n60_measure_room_defaults(double sample_rate, n60_measure_room_params *p) {
    if (p == nullptr) return;
    *p = n60_measure_room_params{};
    p->sample_rate = sample_rate;
    p->seed = 1;
    p->direct_delay_seconds = 0.004;
    p->direct_gain = 1.0;
    p->ir_seconds = 1.0;
    static const double rt60[N60_MEASURE_ROOM_BANDS] = {0.6, 0.55, 0.5, 0.45, 0.4, 0.35, 0.3};
    for (int b = 0; b < N60_MEASURE_ROOM_BANDS; ++b) p->rt60_seconds[b] = rt60[b];
    p->diffuse_level_db = -12.0;
    p->mode_frequencies_hz[0] = 52.0;
    p->mode_frequencies_hz[1] = 87.0;
    p->mode_frequencies_hz[2] = 141.0;
    p->mode_frequencies_hz[3] = 0.0;
    p->mode_decay_seconds[0] = 0.9;
    p->mode_decay_seconds[1] = 0.7;
    p->mode_decay_seconds[2] = 0.5;
    p->mode_decay_seconds[3] = 0.5;
    p->mode_level_db[0] = -8.0;
    p->mode_level_db[1] = -10.0;
    p->mode_level_db[2] = -12.0;
    p->mode_level_db[3] = -200.0;
    for (int h = 0; h < 4; ++h) p->harmonic_db[h] = -200.0;
    p->latency_seconds = 0.0;
    p->drift_ppm = 0.0;
    p->noise_dbfs = -200.0;
}

int32_t n60_measure_room_ir_length(const n60_measure_room_params *params, uint64_t *frames_out) {
    if (!validRoom(params) || frames_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    *frames_out = irFrames(params);
    return N60_MEASURE_OK;
}

int32_t n60_measure_room_ir(const n60_measure_room_params *params, float *out, uint64_t capacity,
                            uint64_t *count_out) {
    if (!validRoom(params) || out == nullptr || count_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    const uint64_t len = irFrames(params);
    if (capacity < len) return N60_MEASURE_ERR_CAPACITY;
    std::vector<double> ir;
    if (!buildIr(params, ir)) return N60_MEASURE_ERR_ARGUMENT;
    for (uint64_t i = 0; i < len; ++i) out[i] = static_cast<float>(ir[i]);
    *count_out = len;
    return N60_MEASURE_OK;
}

int32_t n60_measure_room_capture_length(const n60_measure_room_params *params, uint64_t excitation_count,
                                        uint64_t *frames_out) {
    if (!validRoom(params) || frames_out == nullptr || excitation_count == 0) return N60_MEASURE_ERR_ARGUMENT;
    *frames_out = excitation_count + irFrames(params) +
                  static_cast<uint64_t>(std::ceil(params->latency_seconds * params->sample_rate)) + kGuardFrames;
    return N60_MEASURE_OK;
}

int32_t n60_measure_room_capture(const n60_measure_room_params *params,
                                 const float *excitation, uint64_t excitation_count,
                                 float *out, uint64_t capacity, uint64_t *count_out) {
    if (excitation == nullptr || out == nullptr || count_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    uint64_t total = 0;
    int32_t status = n60_measure_room_capture_length(params, excitation_count, &total);
    if (status != N60_MEASURE_OK) return status;
    if (capacity < total) return N60_MEASURE_ERR_CAPACITY;

    // Nonlinearity: ideal harmonic generator. With the analytic signal of the excitation,
    // x = r cos(theta), the output is x + sum g_k r cos(k theta), so H2..H5 sit at exactly
    // the set levels relative to the instantaneous fundamental, with no DC pedestal while the
    // sweep fades (a static polynomial would add one, and its ramps would smear the IR).
    double g[4];
    for (int h = 0; h < 4; ++h) g[h] = params->harmonic_db[h] > -199.0 ? std::pow(10.0, params->harmonic_db[h] / 20.0) : 0.0;
    std::vector<double> driven(excitation_count);
    for (uint64_t i = 0; i < excitation_count; ++i) driven[i] = excitation[i];
    if (g[0] != 0.0 || g[1] != 0.0 || g[2] != 0.0 || g[3] != 0.0) {
        uint64_t hn = 2;
        while (hn < excitation_count) hn <<= 1;
        if (hn > N60_MEASURE_MAX_TRANSFORM) return N60_MEASURE_ERR_SIZE;
        std::vector<double> padded(hn, 0.0);
        for (uint64_t i = 0; i < excitation_count; ++i) padded[i] = excitation[i];
        std::vector<Cplx> spectrum;
        if (!n60::fft::offline::realForward(padded.data(), hn, spectrum)) return N60_MEASURE_ERR_ALLOC;
        // Hilbert transform: multiply positive-frequency bins by -i.
        for (size_t k = 0; k < spectrum.size(); ++k) {
            const Cplx c = spectrum[k];
            spectrum[k] = (k == 0 || k + 1 == spectrum.size()) ? Cplx{0.0, 0.0} : Cplx{c.im, -c.re};
        }
        std::vector<double> quadrature;
        if (!n60::fft::offline::realInverse(spectrum, hn, quadrature)) return N60_MEASURE_ERR_ALLOC;
        for (uint64_t i = 0; i < excitation_count; ++i) {
            const double x = excitation[i];
            const double r = std::hypot(x, quadrature[i]);
            if (r <= 1e-12) continue;
            const double c = std::min(1.0, std::max(-1.0, x / r));
            double tPrev = 1.0, tCur = c, sum = 0.0;
            for (int k = 2; k <= 5; ++k) {
                const double tNext = 2.0 * c * tCur - tPrev;
                sum += g[k - 2] * tNext;
                tPrev = tCur;
                tCur = tNext;
            }
            driven[i] = x + r * sum;
        }
    }

    std::vector<double> ir;
    if (!buildIr(params, ir)) return N60_MEASURE_ERR_ARGUMENT;
    const uint64_t convLen = excitation_count + ir.size() - 1;
    uint64_t n = 2;
    while (n < convLen) n <<= 1;
    if (n > N60_MEASURE_MAX_TRANSFORM) return N60_MEASURE_ERR_SIZE;
    driven.resize(n, 0.0);
    ir.resize(n, 0.0);
    std::vector<Cplx> a, b;
    if (!n60::fft::offline::realForward(driven.data(), n, a) || !n60::fft::offline::realForward(ir.data(), n, b)) {
        return N60_MEASURE_ERR_ALLOC;
    }
    for (size_t k = 0; k < a.size(); ++k) {
        a[k] = Cplx{a[k].re * b[k].re - a[k].im * b[k].im, a[k].re * b[k].im + a[k].im * b[k].re};
    }
    std::vector<double> room;
    if (!n60::fft::offline::realInverse(a, n, room)) return N60_MEASURE_ERR_ALLOC;

    // Latency and clock drift: sample the room output at fractional positions (cubic Lagrange).
    const double rate = 1.0 + params->drift_ppm * 1e-6;
    const double latencyFrames = params->latency_seconds * params->sample_rate;
    Rng rng(params->seed ^ 0xA5A5A5A5u);
    const double noiseRms = params->noise_dbfs > -199.0 ? std::pow(10.0, params->noise_dbfs / 20.0) : 0.0;
    for (uint64_t j = 0; j < total; ++j) {
        const double position = static_cast<double>(j) * rate - latencyFrames;
        double value = 0.0;
        if (position >= 0.0 && position < static_cast<double>(convLen)) {
            const int64_t base = static_cast<int64_t>(std::floor(position));
            const double f = position - static_cast<double>(base);
            if (f == 0.0) {
                value = room[static_cast<uint64_t>(base)];
            } else {
                double s[4];
                for (int t = 0; t < 4; ++t) {
                    const int64_t idx = base - 1 + t;
                    s[t] = (idx >= 0 && idx < static_cast<int64_t>(convLen)) ? room[static_cast<uint64_t>(idx)] : 0.0;
                }
                const double c0 = -f * (f - 1) * (f - 2) / 6.0;
                const double c1 = (f + 1) * (f - 1) * (f - 2) / 2.0;
                const double c2 = -(f + 1) * f * (f - 2) / 2.0;
                const double c3 = (f + 1) * f * (f - 1) / 6.0;
                value = c0 * s[0] + c1 * s[1] + c2 * s[2] + c3 * s[3];
            }
        }
        if (noiseRms > 0.0) value += noiseRms * rng.gaussian();
        out[j] = static_cast<float>(value);
    }
    *count_out = total;
    return N60_MEASURE_OK;
}

}  // extern "C"
