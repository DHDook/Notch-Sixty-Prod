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
        // Instantaneous frequency from the analytic phase (central difference), used to fade a
        // harmonic out as it approaches Nyquist so nothing aliases back into the band (a real
        // converter has no alias products here; the fade spans 0.45..0.5 fs and is smooth).
        std::vector<double> phase(excitation_count);
        for (uint64_t i = 0; i < excitation_count; ++i) phase[i] = std::atan2(quadrature[i], static_cast<double>(excitation[i]));
        for (uint64_t i = 0; i < excitation_count; ++i) {
            const double x = excitation[i];
            const double r = std::hypot(x, quadrature[i]);
            if (r <= 1e-12) continue;
            const double c = std::min(1.0, std::max(-1.0, x / r));
            double step = 0.0;
            if (i > 0 && i + 1 < excitation_count) {
                double d = phase[i + 1] - phase[i - 1];
                while (d > kPi) d -= 2.0 * kPi;
                while (d < -kPi) d += 2.0 * kPi;
                step = std::fabs(d) / 2.0;  // radians per sample
            }
            const double fInst = step / (2.0 * kPi);  // cycles per sample
            double tPrev = 1.0, tCur = c, sum = 0.0;
            for (int k = 2; k <= 5; ++k) {
                const double tNext = 2.0 * c * tCur - tPrev;
                const double fk = k * fInst;
                const double fade = fk <= 0.45 ? 1.0 : (fk >= 0.5 ? 0.0 : 0.5 * (1.0 + std::cos(kPi * (fk - 0.45) / 0.05)));
                sum += g[k - 2] * fade * tNext;
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
    Rng rng((params->noise_seed != 0 ? params->noise_seed : params->seed) ^ 0xA5A5A5A5u);
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
                // Lanczos (a = 12) windowed-sinc fractional delay: flat to ~0.9 of Nyquist, so
                // alignment tests are limited by the estimator and not by the simulator.
                constexpr int kA = 12;
                double sum = 0.0;
                for (int t = -kA + 1; t <= kA; ++t) {
                    const int64_t idx = base + t;
                    if (idx < 0 || idx >= static_cast<int64_t>(convLen)) continue;
                    const double x = f - static_cast<double>(t);
                    const double px = kPi * x;
                    const double kernel = std::fabs(x) < 1e-12 ? 1.0 : (std::sin(px) / px) * (std::sin(px / kA) / (px / kA));
                    sum += kernel * room[static_cast<uint64_t>(idx)];
                }
                value = sum;
            }
        }
        if (noiseRms > 0.0) value += noiseRms * rng.gaussian();
        out[j] = static_cast<float>(value);
    }
    *count_out = total;
    return N60_MEASURE_OK;
}

}  // extern "C"

// ---- Multi-source, multi-seat room (E10 S1) ----
namespace {

bool validMulti(const n60_measure_multiroom_params *p) {
    if (p == nullptr || !validRoom(&p->base)) return false;
    if (p->source_count < 1 || p->source_count > N60_MEASURE_MULTIROOM_MAX) return false;
    if (p->seat_count < 1 || p->seat_count > N60_MEASURE_MULTIROOM_MAX) return false;
    if (p->reflection_count > N60_MEASURE_MULTIROOM_REFLECTIONS || p->allpass_count > N60_MEASURE_MULTIROOM_ALLPASS) return false;
    if (!std::isfinite(p->modal_variation) || p->modal_variation < 0.0 || p->modal_variation > 0.95) return false;
    for (uint32_t i = 0; i < N60_MEASURE_MULTIROOM_MAX; ++i) {
        if (!std::isfinite(p->source_delay_seconds[i]) || p->source_delay_seconds[i] < 0.0) return false;
        if (!std::isfinite(p->seat_delay_seconds[i]) || p->seat_delay_seconds[i] < 0.0) return false;
    }
    for (uint32_t i = 0; i < p->reflection_count; ++i) {
        if (!std::isfinite(p->reflection_delay_seconds[i]) || p->reflection_delay_seconds[i] <= 0.0 ||
            !std::isfinite(p->reflection_gain_db[i])) return false;
    }
    for (uint32_t i = 0; i < p->allpass_count; ++i) {
        if (!std::isfinite(p->allpass_f0_hz[i]) || p->allpass_f0_hz[i] <= 0.0 || p->allpass_f0_hz[i] >= 0.2 * p->base.sample_rate) return false;
        if (!std::isfinite(p->allpass_q[i]) || p->allpass_q[i] < 0.3 || p->allpass_q[i] > 20.0) return false;
    }
    return std::isfinite(p->ir_noise_dbfs);
}

double allpassPhase(const n60_measure_multiroom_params *p, double hz) {
    double sum = 0.0;
    for (uint32_t i = 0; i < p->allpass_count; ++i) {
        const double w0 = 2.0 * kPi * p->allpass_f0_hz[i];
        const double w = 2.0 * kPi * hz;
        sum += -2.0 * std::atan2(w * w0 / p->allpass_q[i], w0 * w0 - w * w);
    }
    return sum;
}

double allpassGroupDelay(const n60_measure_multiroom_params *p, double hz) {
    double sum = 0.0;
    for (uint32_t i = 0; i < p->allpass_count; ++i) {
        const double w0 = 2.0 * kPi * p->allpass_f0_hz[i];
        const double w = 2.0 * kPi * hz;
        const double a = w0 * w0 - w * w;
        const double b = w * w0 / p->allpass_q[i];
        sum += 2.0 * (w0 / p->allpass_q[i]) * (w0 * w0 + w * w) / (a * a + b * b);
    }
    return sum;
}

}  // namespace

extern "C" {

void n60_measure_multiroom_defaults(double sample_rate, n60_measure_multiroom_params *p) {
    if (p == nullptr) return;
    *p = n60_measure_multiroom_params{};
    p->struct_size = sizeof(n60_measure_multiroom_params);
    n60_measure_room_defaults(sample_rate, &p->base);
    p->source_count = 1;
    p->seat_count = 1;
    for (uint32_t i = 0; i < N60_MEASURE_MULTIROOM_MAX; ++i) {
        p->source_delay_seconds[i] = 0.0;
        p->seat_delay_seconds[i] = 0.0;
    }
    // Mode levels are set so each resonance peaks at a fixed gain over the direct sound at any rate:
    // a decaying sinusoid of amplitude A and decay rate alpha (per sample) has a spectral peak of
    // A / (2 alpha). Peaks below unity keep the room minimum phase apart from the allpass sections.
    static const double peakGain[3] = {0.6, 0.5, 0.4};
    for (int m = 0; m < 3; ++m) {
        const double alpha = kLn1000 / (p->base.mode_decay_seconds[m] * sample_rate);
        p->base.mode_level_db[m] = 20.0 * std::log10(peakGain[m] * 2.0 * alpha / p->base.direct_gain);
    }
    // The diffuse tail is normalised per sample, so its in-band level grows with the rate; scale it
    // so the level against the direct sound is the same at every rate (-60 dB per sample at 48 kHz).
    p->base.diffuse_level_db = -60.0 - 10.0 * std::log10(sample_rate / 48000.0);
    p->modal_variation = 0.3;
    p->reflection_count = 2;
    p->reflection_delay_seconds[0] = 0.0031;
    p->reflection_gain_db[0] = -9.0;
    p->reflection_delay_seconds[1] = 0.0075;
    p->reflection_gain_db[1] = -12.0;
    p->ir_noise_dbfs = -200.0;
}

int32_t n60_measure_multiroom_ir_length(const n60_measure_multiroom_params *params, uint64_t *frames_out) {
    if (!validMulti(params) || frames_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    *frames_out = irFrames(&params->base);
    return N60_MEASURE_OK;
}

double n60_measure_multiroom_arrival_frames(const n60_measure_multiroom_params *params, uint32_t source, uint32_t seat) {
    if (!validMulti(params) || source >= params->source_count || seat >= params->seat_count) return -1.0;
    return std::floor(0.5 + (params->base.direct_delay_seconds + params->source_delay_seconds[source] +
                              params->seat_delay_seconds[seat]) * params->base.sample_rate);
}

double n60_measure_multiroom_allpass_phase(const n60_measure_multiroom_params *params, double hz) {
    if (!validMulti(params)) return 0.0;
    return allpassPhase(params, hz);
}

double n60_measure_multiroom_allpass_group_delay(const n60_measure_multiroom_params *params, double hz) {
    if (!validMulti(params)) return 0.0;
    return allpassGroupDelay(params, hz);
}

int32_t n60_measure_multiroom_ir(const n60_measure_multiroom_params *params, uint32_t source, uint32_t seat,
                                 float *out, uint64_t capacity, uint64_t *count_out) {
    if (!validMulti(params) || out == nullptr || count_out == nullptr || source >= params->source_count ||
        seat >= params->seat_count) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    const n60_measure_room_params &base = params->base;
    const uint64_t len = irFrames(&base);
    if (capacity < len) return N60_MEASURE_ERR_CAPACITY;
    const double fs = base.sample_rate;

    // Direct sound and diffuse tail for this path; the modes are added below with seat gains.
    n60_measure_room_params path = base;
    path.direct_delay_seconds = base.direct_delay_seconds + params->source_delay_seconds[source] + params->seat_delay_seconds[seat];
    if (path.direct_delay_seconds >= path.ir_seconds) return N60_MEASURE_ERR_ARGUMENT;
    path.seed = base.seed + 1u + source * N60_MEASURE_MULTIROOM_MAX + seat;
    for (int m = 0; m < 4; ++m) path.mode_frequencies_hz[m] = 0.0;
    std::vector<double> ir;
    if (!buildIr(&path, ir)) return N60_MEASURE_ERR_ARGUMENT;
    const uint64_t delay = static_cast<uint64_t>(std::llround(path.direct_delay_seconds * fs));

    // Modes: shared frequencies and decays, per-seat gain (sign included), phase from the path delay.
    Rng seatRng(base.seed * 7919u + 104729u * (seat + 1u));
    for (int m = 0; m < 4; ++m) {
        const double u = 2.0 * seatRng.uniform() - 1.0;  // drawn for every mode: stable stream
        const double f = base.mode_frequencies_hz[m];
        if (f <= 0 || base.mode_decay_seconds[m] <= 0 || f >= fs * 0.45) continue;
        const double level = base.direct_gain * std::pow(10.0, base.mode_level_db[m] / 20.0) * (1.0 + params->modal_variation * u);
        for (uint64_t i = delay + 1; i < len; ++i) {
            const double t = static_cast<double>(i - delay) / fs;
            ir[i] += level * std::exp(-kLn1000 * t / base.mode_decay_seconds[m]) * std::sin(2.0 * kPi * f * t);
        }
    }
    // Early reflections: the same absolute times and gains at every seat.
    const uint64_t baseDelay = static_cast<uint64_t>(std::llround(base.direct_delay_seconds * fs));
    for (uint32_t r = 0; r < params->reflection_count; ++r) {
        const uint64_t at = baseDelay + static_cast<uint64_t>(std::llround(params->reflection_delay_seconds[r] * fs));
        if (at < len) ir[at] += base.direct_gain * std::pow(10.0, params->reflection_gain_db[r] / 20.0);
    }
    if (params->ir_noise_dbfs > -199.0) {
        Rng noise(base.seed * 31u + 1000003u * (source * N60_MEASURE_MULTIROOM_MAX + seat + 1u));
        const double rms = base.direct_gain * std::pow(10.0, params->ir_noise_dbfs / 20.0);
        for (uint64_t i = 0; i < len; ++i) ir[i] += rms * noise.gaussian();
    }
    if (params->allpass_count > 0) {
        uint64_t n = 2;
        while (n < len) n <<= 1;
        ir.resize(n, 0.0);
        std::vector<Cplx> spectrum;
        if (!n60::fft::offline::realForward(ir.data(), n, spectrum)) return N60_MEASURE_ERR_ALLOC;
        for (size_t k = 1; k + 1 < spectrum.size(); ++k) {
            const double ph = allpassPhase(params, static_cast<double>(k) * fs / static_cast<double>(n));
            const double c = std::cos(ph), s = std::sin(ph);
            const Cplx v = spectrum[k];
            spectrum[k] = Cplx{v.re * c - v.im * s, v.re * s + v.im * c};
        }
        std::vector<double> shaped;
        if (!n60::fft::offline::realInverse(spectrum, n, shaped)) return N60_MEASURE_ERR_ALLOC;
        ir.assign(shaped.begin(), shaped.begin() + static_cast<std::ptrdiff_t>(len));
    }
    for (uint64_t i = 0; i < len; ++i) out[i] = static_cast<float>(ir[i]);
    *count_out = len;
    return N60_MEASURE_OK;
}

}  // extern "C"
