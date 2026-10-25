// Timing reference and repeat averaging (E11 S2, design notes 4 and 5).
//
// Offline only (control or worker thread): allocates, deterministic, never throws across the C
// boundary. The chirp is a log sweep (Farina) with a half-Hann rise and fall. Arrivals are the
// peak of the FFT cross-correlation, refined by an exact band-limited evaluation of it.
// Repeats are aligned with an exact FFT fractional shift (a phase ramp), then averaged.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "offline_fft.hpp"
#include "n60/measure.h"

namespace {

using n60::fft::offline::Cplx;
constexpr double kPi = 3.14159265358979323846264338327950288;

double chirpEnd(const n60_measure_chirp_params *p) {
    return p->end_hz > 0.0 ? p->end_hz : std::fmin(20000.0, 0.45 * p->sample_rate);
}

bool validChirp(const n60_measure_chirp_params *p) {
    if (p == nullptr) return false;
    const double end = chirpEnd(p);
    return std::isfinite(p->sample_rate) && p->sample_rate > 0 && std::isfinite(p->start_hz) && p->start_hz > 0 &&
           std::isfinite(end) && end > p->start_hz && end < p->sample_rate * 0.5 &&
           std::isfinite(p->duration_seconds) && p->duration_seconds > 0 && p->duration_seconds <= 5.0 &&
           std::isfinite(p->level_dbfs) && p->level_dbfs <= 0 && std::isfinite(p->fade_seconds) &&
           p->fade_seconds >= 0 && p->fade_seconds <= p->duration_seconds * 0.5;
}

uint64_t chirpFrames(const n60_measure_chirp_params *p) {
    return static_cast<uint64_t>(std::llround(p->duration_seconds * p->sample_rate));
}

double medianOf(std::vector<double> values) {
    const size_t mid = values.size() / 2;
    std::nth_element(values.begin(), values.begin() + static_cast<std::ptrdiff_t>(mid), values.end());
    const double upper = values[mid];
    if (values.size() % 2 == 1) return upper;
    const double lower = *std::max_element(values.begin(), values.begin() + static_cast<std::ptrdiff_t>(mid));
    return 0.5 * (lower + upper);
}

}  // namespace

extern "C" {

void n60_measure_chirp_defaults(double sample_rate, n60_measure_chirp_params *p) {
    if (p == nullptr) return;
    *p = n60_measure_chirp_params{};
    p->sample_rate = sample_rate;
    p->start_hz = 2000.0;
    p->end_hz = 0.0;
    p->duration_seconds = 0.25;
    p->level_dbfs = -6.0;
    p->fade_seconds = 0.005;
}

int32_t n60_measure_chirp_length(const n60_measure_chirp_params *p, uint64_t *frames_out) {
    if (!validChirp(p) || frames_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    *frames_out = chirpFrames(p);
    return N60_MEASURE_OK;
}

int32_t n60_measure_chirp_generate(const n60_measure_chirp_params *p, float *out, uint64_t capacity,
                                   uint64_t *count_out) {
    if (!validChirp(p) || out == nullptr || count_out == nullptr) return N60_MEASURE_ERR_ARGUMENT;
    const uint64_t n = chirpFrames(p);
    if (capacity < n) return N60_MEASURE_ERR_CAPACITY;
    const double f1 = p->start_hz, f2 = chirpEnd(p), fs = p->sample_rate;
    const double rate = p->duration_seconds / std::log(f2 / f1);  // L: f(t) = f1 exp(t / L)
    const double amplitude = std::pow(10.0, p->level_dbfs / 20.0);
    const double fade = p->fade_seconds * fs;
    for (uint64_t i = 0; i < n; ++i) {
        const double t = static_cast<double>(i) / fs;
        double value = std::sin(2.0 * kPi * f1 * rate * (std::exp(t / rate) - 1.0));
        const double x = static_cast<double>(i);
        if (fade > 0.0) {
            if (x < fade) value *= 0.5 * (1.0 - std::cos(kPi * x / fade));
            const double fromEnd = static_cast<double>(n - 1) - x;
            if (fromEnd < fade) value *= 0.5 * (1.0 - std::cos(kPi * fromEnd / fade));
        }
        out[i] = static_cast<float>(amplitude * value);
    }
    *count_out = n;
    return N60_MEASURE_OK;
}

int32_t n60_measure_find_arrival(const float *tmpl, uint64_t tmpl_count, const float *capture,
                                 uint64_t capture_count, double sample_rate, double min_peak_db,
                                 n60_measure_arrival *arrival_out) {
    if (tmpl == nullptr || capture == nullptr || arrival_out == nullptr || tmpl_count < 2 ||
        capture_count < tmpl_count || !std::isfinite(sample_rate) || sample_rate <= 0 ||
        !std::isfinite(min_peak_db)) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    uint64_t n = 0;
    const int32_t sizeStatus = n60_measure_transform_size(capture_count + tmpl_count, &n);
    if (sizeStatus != N60_MEASURE_OK) return sizeStatus;
    std::vector<Cplx> spectrumT, spectrumC;
    {
        std::vector<double> buffer(n, 0.0);
        for (uint64_t i = 0; i < tmpl_count; ++i) buffer[i] = tmpl[i];
        if (!n60::fft::offline::realForward(buffer.data(), n, spectrumT)) return N60_MEASURE_ERR_ALLOC;
        std::fill(buffer.begin(), buffer.end(), 0.0);
        for (uint64_t i = 0; i < capture_count; ++i) buffer[i] = capture[i];
        if (!n60::fft::offline::realForward(buffer.data(), n, spectrumC)) return N60_MEASURE_ERR_ALLOC;
    }
    // c[lag] = sum_j tmpl[j] capture[lag + j]  ->  C conj(T).
    for (size_t k = 0; k < spectrumC.size(); ++k) {
        const Cplx c = spectrumC[k], t = spectrumT[k];
        spectrumC[k] = Cplx{c.re * t.re + c.im * t.im, c.im * t.re - c.re * t.im};
    }
    std::vector<double> corr;
    if (!n60::fft::offline::realInverse(spectrumC, n, corr)) return N60_MEASURE_ERR_ALLOC;

    const uint64_t lags = capture_count - tmpl_count + 1;  // lags where the template fits
    uint64_t best = 0;
    double bestAbs = 0.0;
    for (uint64_t i = 0; i < lags; ++i) {
        const double a = std::fabs(corr[i]);
        if (a > bestAbs) {
            bestAbs = a;
            best = i;
        }
    }
    if (bestAbs <= 0.0) {
        arrival_out->arrival_frames = 0.0;
        arrival_out->peak_to_neighbourhood_db = -300.0;
        return N60_MEASURE_ERR_TIMING_REFERENCE;
    }
    const uint64_t guard = std::max<uint64_t>(8, static_cast<uint64_t>(0.005 * sample_rate));
    double energy = 0.0;
    uint64_t counted = 0;
    for (uint64_t i = 0; i < lags; ++i) {
        const uint64_t distance = i > best ? i - best : best - i;
        if (distance <= guard) continue;
        energy += corr[i] * corr[i];
        ++counted;
    }
    const double rms = counted > 0 ? std::sqrt(energy / static_cast<double>(counted)) : 0.0;
    arrival_out->peak_to_neighbourhood_db = rms > 0.0 ? 20.0 * std::log10(bestAbs / rms) : 300.0;
    // Sub-sample refinement: the correlation is band-limited, so it can be evaluated exactly at
    // fractional lags from its spectrum. Golden-section search for the extremum of the peak
    // (sign of the integer peak) over +-1 sample, over the bins that carry energy.
    double maxBin = 0.0;
    for (const Cplx &c : spectrumC) maxBin = std::fmax(maxBin, c.re * c.re + c.im * c.im);
    std::vector<size_t> active;
    for (size_t k = 1; k + 1 < spectrumC.size(); ++k) {
        if (spectrumC[k].re * spectrumC[k].re + spectrumC[k].im * spectrumC[k].im > maxBin * 1e-10) active.push_back(k);
    }
    const double sign = corr[best] >= 0.0 ? 1.0 : -1.0;
    auto value = [&](double lag) {
        double sum = 0.0;
        for (size_t k : active) {
            const double a = 2.0 * kPi * static_cast<double>(k) * lag / static_cast<double>(n);
            sum += spectrumC[k].re * std::cos(a) - spectrumC[k].im * std::sin(a);
        }
        return sign * sum;
    };
    double lo = static_cast<double>(best) - 1.0, hi = static_cast<double>(best) + 1.0;
    const double golden = 0.6180339887498949;
    double x1 = hi - golden * (hi - lo), x2 = lo + golden * (hi - lo);
    double f1 = value(x1), f2 = value(x2);
    for (int iteration = 0; iteration < 28; ++iteration) {
        if (f1 < f2) {
            lo = x1; x1 = x2; f1 = f2; x2 = lo + golden * (hi - lo); f2 = value(x2);
        } else {
            hi = x2; x2 = x1; f2 = f1; x1 = hi - golden * (hi - lo); f1 = value(x1);
        }
    }
    arrival_out->arrival_frames = 0.5 * (lo + hi);
    return arrival_out->peak_to_neighbourhood_db >= min_peak_db ? N60_MEASURE_OK : N60_MEASURE_ERR_TIMING_REFERENCE;
}

int32_t n60_measure_peak_position(const float *data, uint64_t count, uint64_t begin, uint64_t end,
                                  double *position_out) {
    if (data == nullptr || position_out == nullptr || begin >= end || end > count) return N60_MEASURE_ERR_ARGUMENT;
    uint64_t best = begin;
    for (uint64_t i = begin; i < end; ++i) {
        if (std::fabs(data[i]) > std::fabs(data[best])) best = i;
    }
    // Windowed-sinc (Lanczos a = 8) interpolation around the integer peak, golden-section search
    // for the extremum over +-1 sample; far more accurate than a parabola near Nyquist.
    constexpr int kA = 8;
    const double sign = data[best] >= 0.0f ? 1.0 : -1.0;
    auto value = [&](double position) {
        const int64_t base = static_cast<int64_t>(std::floor(position));
        double sum = 0.0;
        for (int t = -kA + 1; t <= kA; ++t) {
            const int64_t idx = base + t;
            if (idx < 0 || idx >= static_cast<int64_t>(count)) continue;
            const double x = position - static_cast<double>(idx);
            const double px = kPi * x;
            const double kernel = std::fabs(x) < 1e-12 ? 1.0 : (std::sin(px) / px) * (std::sin(px / kA) / (px / kA));
            sum += kernel * data[static_cast<uint64_t>(idx)];
        }
        return sign * sum;
    };
    double lo = static_cast<double>(best) - 1.0, hi = static_cast<double>(best) + 1.0;
    const double golden = 0.6180339887498949;
    double x1 = hi - golden * (hi - lo), x2 = lo + golden * (hi - lo);
    double f1 = value(x1), f2 = value(x2);
    for (int iteration = 0; iteration < 30; ++iteration) {
        if (f1 < f2) {
            lo = x1; x1 = x2; f1 = f2; x2 = lo + golden * (hi - lo); f2 = value(x2);
        } else {
            hi = x2; x2 = x1; f2 = f1; x1 = hi - golden * (hi - lo); f1 = value(x1);
        }
    }
    const double offset = 0.5 * (lo + hi) - static_cast<double>(best);
    *position_out = static_cast<double>(best) + offset;
    return N60_MEASURE_OK;
}

void n60_measure_average_defaults(double sample_rate, n60_measure_average_params *p) {
    if (p == nullptr) return;
    *p = n60_measure_average_params{};
    p->sample_rate = sample_rate;
    p->repeat_count = 2;
    p->min_coherence = 0.9;
    p->max_level_diff_db = 1.0;
    p->drift_warning_ppm = 20.0;
}

int32_t n60_measure_average_repeats(const n60_measure_average_params *p, const float *const *repeats,
                                    const double *arrivals, float *out, uint64_t capacity,
                                    n60_measure_average_result *result_out) {
    if (p == nullptr || repeats == nullptr || arrivals == nullptr || out == nullptr || result_out == nullptr ||
        p->repeat_count < 1 || p->repeat_count > N60_MEASURE_MAX_REPEATS || p->length_frames < 2 ||
        !std::isfinite(p->sample_rate) || p->sample_rate <= 0 || !(p->min_coherence >= 0) ||
        !(p->max_level_diff_db >= 0)) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    const uint32_t count = p->repeat_count;
    const uint64_t length = p->length_frames;
    if (capacity < length) return N60_MEASURE_ERR_CAPACITY;
    double maxShift = 0.0;
    for (uint32_t r = 0; r < count; ++r) {
        if (repeats[r] == nullptr || !std::isfinite(arrivals[r])) return N60_MEASURE_ERR_ARGUMENT;
        maxShift = std::fmax(maxShift, std::fabs(arrivals[r] - arrivals[0]));
    }
    uint64_t n = 0;
    const int32_t sizeStatus =
        n60_measure_transform_size(length + 2 * static_cast<uint64_t>(std::ceil(maxShift)) + 16, &n);
    if (sizeStatus != N60_MEASURE_OK) return sizeStatus;

    *result_out = n60_measure_average_result{};
    std::vector<std::vector<float>> aligned(count);
    std::vector<double> levels(count, 0.0);
    {
        std::vector<double> buffer(n);
        std::vector<Cplx> spectrum;
        const double binHz = p->sample_rate / static_cast<double>(n);
        for (uint32_t r = 0; r < count; ++r) {
            std::fill(buffer.begin(), buffer.end(), 0.0);
            for (uint64_t i = 0; i < length; ++i) buffer[i] = repeats[r][i];
            if (!n60::fft::offline::realForward(buffer.data(), n, spectrum)) return N60_MEASURE_ERR_ALLOC;
            // Level over 200 Hz - 5 kHz (a shift does not change magnitudes).
            double energy = 0.0;
            for (size_t k = 1; k + 1 < spectrum.size(); ++k) {
                const double f = static_cast<double>(k) * binHz;
                if (f < 200.0 || f > 5000.0) continue;
                energy += spectrum[k].re * spectrum[k].re + spectrum[k].im * spectrum[k].im;
            }
            levels[r] = energy > 0.0 ? 10.0 * std::log10(energy) : -300.0;
            // x'(n) = x(n + s): X'(k) = X(k) exp(+i 2 pi k s / N) moves repeat r's reference onto repeat 0's.
            const double s = arrivals[r] - arrivals[0];
            for (size_t k = 0; k < spectrum.size(); ++k) {
                const double a = 2.0 * kPi * static_cast<double>(k) * s / static_cast<double>(n);
                const double c = std::cos(a), sn = std::sin(a);
                const Cplx v = spectrum[k];
                spectrum[k] = Cplx{v.re * c - v.im * sn, v.re * sn + v.im * c};
            }
            spectrum.back().im = 0.0;  // the Nyquist bin of a real signal is real
            std::vector<double> shifted;
            if (!n60::fft::offline::realInverse(spectrum, n, shifted)) return N60_MEASURE_ERR_ALLOC;
            aligned[r].resize(length);
            for (uint64_t i = 0; i < length; ++i) aligned[r][i] = static_cast<float>(shifted[i]);
        }
    }

    uint32_t rejected = 0;
    for (uint32_t r = 0; r < count; ++r) {
        result_out->coherence[r] = 1.0;
        result_out->level_db[r] = levels[r];
    }
    if (count >= 3) {
        std::vector<double> median(length);
        std::vector<double> column(count);
        for (uint64_t i = 0; i < length; ++i) {
            for (uint32_t r = 0; r < count; ++r) column[r] = aligned[r][i];
            median[i] = medianOf(column);
        }
        double medianEnergy = 0.0;
        for (double v : median) medianEnergy += v * v;
        const double medianLevel = medianOf(levels);
        for (uint32_t r = 0; r < count; ++r) {
            double dot = 0.0, own = 0.0;
            for (uint64_t i = 0; i < length; ++i) {
                dot += static_cast<double>(aligned[r][i]) * median[i];
                own += static_cast<double>(aligned[r][i]) * aligned[r][i];
            }
            const double denominator = std::sqrt(own * medianEnergy);
            const double coherence = denominator > 0.0 ? dot / denominator : 0.0;
            result_out->coherence[r] = coherence;
            if (coherence < p->min_coherence || std::fabs(levels[r] - medianLevel) > p->max_level_diff_db) {
                rejected |= 1u << r;
            }
        }
    }
    uint32_t accepted = 0;
    std::vector<double> sum(length, 0.0);
    for (uint32_t r = 0; r < count; ++r) {
        if (rejected & (1u << r)) continue;
        ++accepted;
        for (uint64_t i = 0; i < length; ++i) sum[i] += aligned[r][i];
    }
    result_out->rejected_mask = rejected;
    result_out->accepted_count = accepted;
    if (accepted == 0) return N60_MEASURE_ERR_NO_ACCEPTED_REPEATS;
    for (uint64_t i = 0; i < length; ++i) out[i] = static_cast<float>(sum[i] / static_cast<double>(accepted));

    // Drift: least-squares slope of the arrival shift against elapsed frames, in ppm.
    if (count >= 2) {
        const double period = p->repeat_period_frames > 0 ? static_cast<double>(p->repeat_period_frames)
                                                          : static_cast<double>(length);
        double meanX = 0.0, meanY = 0.0;
        for (uint32_t r = 0; r < count; ++r) {
            meanX += static_cast<double>(r) * period;
            meanY += arrivals[r] - arrivals[0];
        }
        meanX /= count;
        meanY /= count;
        double sxy = 0.0, sxx = 0.0;
        for (uint32_t r = 0; r < count; ++r) {
            const double dx = static_cast<double>(r) * period - meanX;
            sxy += dx * (arrivals[r] - arrivals[0] - meanY);
            sxx += dx * dx;
        }
        result_out->drift_ppm = sxx > 0.0 ? 1e6 * sxy / sxx : 0.0;
        result_out->drift_warning = std::fabs(result_out->drift_ppm) > p->drift_warning_ppm ? 1u : 0u;
    }
    return N60_MEASURE_OK;
}

}  // extern "C"
