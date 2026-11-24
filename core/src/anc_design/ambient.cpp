// E21 S10b: passive ambient field analysis (n60/anc_design.h, version 2). Port of the Swift AmbientFieldAnalyzer maths.
// Offline: worker thread, allocates with std::vector (built with -fno-exceptions, so an out-of-memory aborts, as in the other design maths, gap G9), never throws, deterministic. Never called from an audio callback and
// never produces audio. Spectra use the double-precision offline FFT (src/measure/offline_fft.hpp), so no Apple framework.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <new>
#include <vector>

#include "n60/anc_design.h"
#include "../measure/offline_fft.hpp"
#include "../nothrow_array.hpp"

namespace {

using n60::NothrowArray;
using n60::fft::offline::Cplx;

constexpr double kPi = 3.14159265358979323846;

double clamp01(double v) { return std::min(std::max(v, 0.0), 1.0); }
double dbfsAmp(double a) { return (std::isfinite(a) && a > 1.0e-15) ? 20.0 * std::log10(a) : -300.0; }
double dbfsPow(double p) { return (std::isfinite(p) && p > 1.0e-30) ? 10.0 * std::log10(p) : -300.0; }

double rmsOf(const float *x, size_t n) {
    if (n == 0) return 0;
    double sum = 0;
    for (size_t i = 0; i < n; ++i) sum += double(x[i]) * double(x[i]);
    return std::sqrt(sum / double(n));
}

// Smallest power of two >= required, with the Swift limits. Returns 0 when too large.
uint64_t transformSize(uint64_t required) {
    if (required == 0) return 1;
    uint64_t size = 1;
    while (size < required) {
        if (size > 262144) return 0;
        size <<= 1;
    }
    return size <= 524288 ? size : 0;
}

bool leastSquaresGain(const float *obs, const float *ref, size_t n, double &gain) {
    if (n == 0) return false;
    double cross = 0, refE = 0;
    for (size_t i = 0; i < n; ++i) {
        cross += double(obs[i]) * double(ref[i]);
        refE += double(ref[i]) * double(ref[i]);
    }
    if (!(refE > 1.0e-20)) return false;
    gain = cross / refE;
    return std::isfinite(gain);
}

bool correlationOf(const float *a, const float *b, size_t n, double &out) {
    if (n == 0) return false;
    double cross = 0, ae = 0, be = 0;
    for (size_t i = 0; i < n; ++i) {
        cross += double(a[i]) * double(b[i]);
        ae += double(a[i]) * double(a[i]);
        be += double(b[i]) * double(b[i]);
    }
    const double d = std::sqrt(ae * be);
    if (!(d > 1.0e-20)) return false;
    out = std::min(std::max(cross / d, -1.0), 1.0);
    return true;
}

struct Frame {
    uint64_t size{0};
    std::vector<Cplx> spec;  // size/2 + 1 bins
    double windowEnergy{1};
};

double binPower(const Frame &f, size_t bin) {
    const double r = f.spec[bin].re, i = f.spec[bin].im;
    return 2.0 * (r * r + i * i) / (double(f.size) * f.windowEnergy);
}

// Zero-padded real forward transform of `x` (n samples) to `size` points.
bool forward(const double *x, size_t n, uint64_t size, std::vector<Cplx> &spec) {
    std::vector<double> padded;
    padded.assign(size_t(size), 0.0);
    if (padded.size() != size) return false;
    std::copy(x, x + n, padded.begin());
    return n60::fft::offline::realForward(padded.data(), size, spec);
}

bool makeFrame(const float *samples, size_t n, Frame &out) {
    out.size = transformSize(n);
    if (out.size < 2) out.size = 2;
    std::vector<double> w(n);
    double energy = 0;
    if (n == 1) {
        w[0] = samples[0];
        energy = 1;
    } else {
        const double den = double(n - 1);
        for (size_t i = 0; i < n; ++i) {
            const double window = 0.5 - 0.5 * std::cos(2.0 * kPi * double(i) / den);
            w[i] = double(samples[i]) * double(float(window));
            energy += window * window;
        }
    }
    out.windowEnergy = std::max(energy, std::numeric_limits<double>::denorm_min());
    return forward(w.data(), n, out.size, out.spec);
}

uint32_t makeBands(const n60_ambient_config &c, const Frame &f, double sampleRate, n60_ambient_band *out) {
    const double nyquist = sampleRate * 0.5;
    const double minimum = std::max(c.minimumFrequencyHz, sampleRate / double(f.size));
    const double maximum = std::min(c.maximumFrequencyHz, nyquist * 0.98);
    if (!(maximum > minimum)) return 0;
    const double ratio = maximum / minimum;
    const int count = c.spectrumBandCount;
    for (int band = 0; band < count; ++band) {
        const double lower = minimum * std::pow(ratio, double(band) / double(count));
        const double upper = minimum * std::pow(ratio, double(band + 1) / double(count));
        const double center = std::sqrt(lower * upper);
        const int64_t firstBin = std::max<int64_t>(1, int64_t(std::floor(lower * double(f.size) / sampleRate)));
        const int64_t lastBin = std::min<int64_t>(int64_t(f.size / 2) - 1,
                                                  std::max<int64_t>(firstBin, int64_t(std::ceil(upper * double(f.size) / sampleRate))));
        double magSq = 0;
        for (int64_t bin = firstBin; bin <= lastBin; ++bin) {
            const double r = f.spec[size_t(bin)].re, i = f.spec[size_t(bin)].im;
            magSq += r * r + i * i;
        }
        const double power = 2.0 * magSq / (double(f.size) * f.windowEnergy);
        out[band] = n60_ambient_band{lower, center, upper, dbfsPow(power)};
    }
    return uint32_t(count);
}

uint32_t makeTones(const n60_ambient_config &c, const Frame &f, double sampleRate, uint32_t capacity, n60_ambient_tone *out,
                   bool &ok) {
    ok = true;
    const double maximum = std::min(c.tonalSearchUpperHz, sampleRate * 0.49);
    const int64_t firstBin = std::max<int64_t>(2, int64_t(std::ceil(c.minimumFrequencyHz * double(f.size) / sampleRate)));
    const int64_t lastBin = std::min<int64_t>(int64_t(f.size / 2) - 2, int64_t(std::floor(maximum * double(f.size) / sampleRate)));
    if (!(lastBin > firstBin)) return 0;

    std::vector<n60_ambient_tone> candidates;
    std::vector<double> neighborhood;
        for (int64_t bin = firstBin; bin <= lastBin; ++bin) {
            const double power = binPower(f, size_t(bin));
            const double previous = binPower(f, size_t(bin - 1));
            const double next = binPower(f, size_t(bin + 1));
            if (!(power > previous && power >= next)) continue;
            neighborhood.clear();
            const int64_t lo = std::max(firstBin, bin - 12), hi = std::min(lastBin, bin + 12);
            for (int64_t nb = lo; nb <= hi; ++nb) {
                if (std::llabs(nb - bin) > 2) neighborhood.push_back(binPower(f, size_t(nb)));
            }
            if (neighborhood.empty()) continue;
            std::sort(neighborhood.begin(), neighborhood.end());
            const double noise = neighborhood[neighborhood.size() / 2];
            const double prominence = 10.0 * std::log10(std::max(power, 1.0e-30) / std::max(noise, 1.0e-30));
            if (!(prominence >= c.minimumTonalProminenceDB)) continue;
            n60_ambient_tone t{};
            t.frequencyHz = double(bin) * sampleRate / double(f.size);
            t.levelDBFS = dbfsPow(power);
            t.prominenceDB = prominence;
            t.phaseRadians = std::atan2(f.spec[size_t(bin)].im, f.spec[size_t(bin)].re);
            candidates.push_back(t);
        }
    std::stable_sort(candidates.begin(), candidates.end(), [](const n60_ambient_tone &a, const n60_ambient_tone &b) {
        if (a.levelDBFS == b.levelDBFS) return a.prominenceDB > b.prominenceDB;
        return a.levelDBFS > b.levelDBFS;
    });
    const uint32_t limit = std::min<uint32_t>(uint32_t(c.maximumTonalComponents), capacity);
    uint32_t accepted = 0;
    for (const auto &cand : candidates) {
        if (accepted == limit) break;
        bool duplicate = false;
        for (uint32_t i = 0; i < accepted; ++i) {
            if (std::fabs(out[i].frequencyHz - cand.frequencyHz) <
                std::max(sampleRate / double(f.size) * 3.0, cand.frequencyHz * 0.025)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) out[accepted++] = cand;
    }
    return accepted;
}

double stationarity(const n60_ambient_config &c, const float *x, size_t n) {
    const size_t segCount = std::min<size_t>(size_t(c.segmentCount), n / 256);
    if (segCount < 2) return 0;
    const size_t length = n / segCount;
    std::vector<double> levels;
    for (size_t s = 0; s < segCount; ++s) {
        const size_t start = s * length;
        const size_t end = s == segCount - 1 ? n : start + length;
        if (end <= start) continue;
        double sum = 0;
        for (size_t i = start; i < end; ++i) sum += double(x[i]) * double(x[i]);
        levels.push_back(dbfsAmp(std::sqrt(sum / double(end - start))));
    }
    if (levels.size() < 2) return 0;
    double mean = 0;
    for (double v : levels) mean += v;
    mean /= double(levels.size());
    double variance = 0;
    for (double v : levels) variance += (v - mean) * (v - mean);
    variance /= double(levels.size());
    return clamp01(std::exp(-std::sqrt(variance) / 6.0));
}

int32_t periodicity(const n60_ambient_config &c, const float *x, size_t n, double sampleRate, double &score,
                    bool &hasFrequency, double &frequency) {
    score = 0;
    hasFrequency = false;
    double mean = 0;
    for (size_t i = 0; i < n; ++i) mean += double(x[i]);
    mean /= double(n);
    const uint64_t size = transformSize(uint64_t(n) * 2);
    if (size == 0) return N60_AMBIENT_ERR_TRANSFORM_TOO_LARGE;
    std::vector<double> centered;
    std::vector<Cplx> spec;
    std::vector<double> ac;
        centered.resize(n);
        for (size_t i = 0; i < n; ++i) centered[i] = double(float(double(x[i]) - mean));
        if (!forward(centered.data(), n, size, spec)) return N60_ANC_DESIGN_ERR_ALLOC;
        for (auto &b : spec) b = Cplx{b.re * b.re + b.im * b.im, 0.0};
        if (!n60::fft::offline::realInverse(spec, size, ac)) return N60_ANC_DESIGN_ERR_ALLOC;
    const double zero = ac[0];
    if (!(std::isfinite(zero) && zero > 1.0e-20)) return N60_ANC_DESIGN_OK;
    const int64_t minLag = std::max<int64_t>(1, int64_t(std::floor(sampleRate / c.tonalSearchUpperHz)));
    const int64_t maxLag = std::min<int64_t>(int64_t(n / 2), int64_t(std::ceil(sampleRate / c.minimumFrequencyHz)));
    if (!(maxLag > minLag)) return N60_ANC_DESIGN_OK;
    double best = 0;
    int64_t bestLag = 0;
    for (int64_t lag = minLag; lag <= maxLag; ++lag) {
        const double normalized = ac[size_t(lag)] / zero;
        if (normalized > best) {
            best = normalized;
            bestLag = lag;
        }
    }
    score = clamp01(best);
    if (bestLag > 0) {
        hasFrequency = true;
        frequency = sampleRate / double(bestLag);
    }
    return N60_ANC_DESIGN_OK;
}

// Convolves playback with the impulse response and keeps the first playback.size() samples, rounded to float.
bool predictPlayback(const float *playback, size_t n, const float *ir, size_t taps, std::vector<float> &out, int32_t &err) {
    const uint64_t size = transformSize(uint64_t(n) + taps - 1);
    if (size == 0) {
        err = N60_AMBIENT_ERR_TRANSFORM_TOO_LARGE;
        return false;
    }
        std::vector<double> a(playback, playback + n), b(ir, ir + taps), r;
        std::vector<Cplx> sa, sb;
        if (!forward(a.data(), n, size, sa) || !forward(b.data(), taps, size, sb)) {
            err = N60_ANC_DESIGN_ERR_ALLOC;
            return false;
        }
        for (size_t i = 0; i < sa.size(); ++i) {
            sa[i] = Cplx{sa[i].re * sb[i].re - sa[i].im * sb[i].im, sa[i].re * sb[i].im + sa[i].im * sb[i].re};
        }
        if (!n60::fft::offline::realInverse(sa, size, r)) {
            err = N60_ANC_DESIGN_ERR_ALLOC;
            return false;
        }
        out.resize(n);
        for (size_t i = 0; i < n; ++i) out[i] = float(r[i]);
    return true;
}

double normalizedCorrelation(const float *mic, const float *ref, size_t n, int64_t lag, int64_t stride) {
    double dot = 0, me = 0, re = 0;
    int64_t count = 0;
    for (int64_t index = 0; index < int64_t(n); index += std::max<int64_t>(stride, 1)) {
        const int64_t ri = index - lag;
        if (ri >= 0 && ri < int64_t(n)) {
            const double o = mic[index], m = ref[ri];
            dot += o * m;
            me += o * o;
            re += m * m;
            ++count;
        }
    }
    if (count < 64 || !(me > 1.0e-18) || !(re > 1.0e-18)) return -1;
    return dot / std::sqrt(me * re);
}

struct Alignment {
    std::vector<float> aligned;
    int64_t lag{0};
    double confidence{1};
};

bool alignPlayback(const n60_ambient_config &c, const float *mic, const std::vector<float> &pred, double sampleRate,
                   Alignment &out) {
    const size_t n = pred.size();
        out.aligned = pred;
    out.lag = 0;
    out.confidence = 1;
    if (n == 0 || !(c.maximumPlaybackAlignmentSeconds > 0)) return true;
    const int64_t maximumLag =
        std::min<int64_t>(int64_t(std::llround(sampleRate * c.maximumPlaybackAlignmentSeconds)), std::max<int64_t>(int64_t(n) / 3, 0));
    if (maximumLag <= 0) return true;
    const int64_t stride = std::max<int64_t>(int64_t(std::llround(sampleRate / c.alignmentSearchRateHz)), 1);
    const int64_t coarseMax = std::max<int64_t>(maximumLag / stride, 1);
    int64_t bestLag = 0;
    double best = -std::numeric_limits<double>::infinity();
    for (int64_t coarse = -coarseMax; coarse <= coarseMax; ++coarse) {
        const int64_t lag = coarse * stride;
        const double corr = normalizedCorrelation(mic, pred.data(), n, lag, stride);
        if (corr > best) {
            best = corr;
            bestLag = lag;
        }
    }
    const int64_t lo = std::max(-maximumLag, bestLag - stride), hi = std::min(maximumLag, bestLag + stride);
    for (int64_t lag = lo; lag <= hi; ++lag) {
        const double corr = normalizedCorrelation(mic, pred.data(), n, lag, 1);
        if (corr > best) {
            best = corr;
            bestLag = lag;
        }
    }
    std::fill(out.aligned.begin(), out.aligned.end(), 0.0f);
    int64_t overlap = 0;
    for (int64_t i = 0; i < int64_t(n); ++i) {
        const int64_t s = i - bestLag;
        if (s < 0 || s >= int64_t(n)) continue;
        out.aligned[size_t(i)] = pred[size_t(s)];
        ++overlap;
    }
    const double overlapFraction = double(overlap) / double(std::max<int64_t>(int64_t(n), 1));
    const double corrConfidence = clamp01((std::max(best, 0.0) - 0.05) / 0.55);
    const double boundaryFraction = double(std::llabs(bestLag)) / double(maximumLag);
    const double boundaryConfidence = clamp01((1.0 - boundaryFraction) / 0.15);
    out.lag = bestLag;
    out.confidence = clamp01(corrConfidence * overlapFraction * std::max(boundaryConfidence, 0.15));
    return true;
}

void estimateScale(const n60_ambient_config &c, const float *mic, const std::vector<float> &pred, double &gainOut,
                   double &confOut) {
    const size_t n = pred.size();
    double global = 0;
    const bool haveGlobal = leastSquaresGain(mic, pred.data(), n, global);
    const double gain = std::min(std::max(haveGlobal ? global : 1.0, 0.0), 4.0);
    gainOut = gain;
    if (!haveGlobal || !(global > 0.025)) {
        confOut = 0.20;
        return;
    }
    const size_t segCount = std::min<size_t>(size_t(c.segmentCount), n / 256);
    if (segCount < 2) {
        confOut = 0.35;
        return;
    }
    const size_t segLen = n / segCount;
    std::vector<double> gains, corrs;
    std::vector<float> residual;
    for (size_t s = 0; s < segCount; ++s) {
        const size_t start = s * segLen;
        const size_t end = s == segCount - 1 ? n : start + segLen;
        if (end <= start) continue;
        const float *obs = mic + start;
        const float *ref = pred.data() + start;
        const size_t len = end - start;
        if (!(dbfsAmp(rmsOf(ref, len)) > c.negligiblePlaybackDBFS)) continue;
        double local = 0;
        if (leastSquaresGain(obs, ref, len, local)) {
            gains.push_back(std::min(std::max(local, 0.0), 4.0));
            residual.resize(len);
            for (size_t i = 0; i < len; ++i) residual[i] = float(double(obs[i]) - gain * double(ref[i]));
            double r = 0;
            corrs.push_back(correlationOf(residual.data(), ref, len, r) ? std::fabs(r) : 0.0);
        }
    }
    if (gains.size() < 2) {
        confOut = 0.45;
        return;
    }
    double mean = 0;
    for (double g : gains) mean += g;
    mean /= double(gains.size());
    double variance = 0;
    for (double g : gains) variance += (g - mean) * (g - mean);
    variance /= double(gains.size());
    const double spread = std::sqrt(variance) / std::max(std::fabs(mean), 0.10);
    const double stability = std::exp(-spread / 0.35);
    double rc = 0.5;
    if (!corrs.empty()) {
        rc = 0;
        for (double v : corrs) rc += v;
        rc /= double(corrs.size());
    }
    const double decorrelation = 1.0 - std::min(std::max(rc, 0.0), 1.0);
    confOut = clamp01(0.15 + 0.55 * stability + 0.30 * decorrelation);
}

bool validConfig(const n60_ambient_config &c) {
    return c.structSize >= sizeof(n60_ambient_config) && c.minimumAnalysisFrames >= 256 &&
           c.maximumAnalysisFrames >= c.minimumAnalysisFrames && c.maximumAnalysisFrames <= 131072 &&
           c.maximumImpulseTaps > 0 && c.maximumImpulseTaps <= 32768 && c.spectrumBandCount >= 8 &&
           c.spectrumBandCount <= int32_t(N60_AMBIENT_MAX_BANDS) && c.segmentCount >= 2 && c.segmentCount <= 32 &&
           std::isfinite(c.minimumFrequencyHz) && c.minimumFrequencyHz > 0 && std::isfinite(c.maximumFrequencyHz) &&
           c.maximumFrequencyHz > c.minimumFrequencyHz && std::isfinite(c.lowFrequencyUpperHz) &&
           c.lowFrequencyUpperHz > c.minimumFrequencyHz && std::isfinite(c.tonalSearchUpperHz) &&
           c.tonalSearchUpperHz > c.minimumFrequencyHz && std::isfinite(c.minimumTonalProminenceDB) &&
           c.maximumTonalComponents > 0 && std::isfinite(c.maximumPlaybackAlignmentSeconds) &&
           c.maximumPlaybackAlignmentSeconds >= 0 && c.maximumPlaybackAlignmentSeconds <= 1.0 &&
           std::isfinite(c.alignmentSearchRateHz) && c.alignmentSearchRateHz >= 500 && c.alignmentSearchRateHz <= 8000;
}

int32_t classify(double level, double stationarityScore, double period, bool hasTone, double toneProminence) {
    if (level < -100) return N60_AMBIENT_CHARACTER_QUIET;
    if (stationarityScore < 0.45) return N60_AMBIENT_CHARACTER_NONSTATIONARY;
    const double prominence = hasTone ? toneProminence : 0;
    if (prominence >= 12 && period >= 0.45) return N60_AMBIENT_CHARACTER_TONAL_PERIODIC;
    if (prominence >= 8) return N60_AMBIENT_CHARACTER_TONAL;
    if (period >= 0.45) return N60_AMBIENT_CHARACTER_MIXED;
    return N60_AMBIENT_CHARACTER_BROADBAND;
}

}  // namespace

extern "C" {

void n60_ambient_config_default(n60_ambient_config *out) {
    if (out == nullptr) return;
    n60_ambient_config c{};
    c.structSize = sizeof(n60_ambient_config);
    c.minimumAnalysisFrames = 4096;
    c.maximumAnalysisFrames = 65536;
    c.maximumImpulseTaps = 8192;
    c.spectrumBandCount = 64;
    c.segmentCount = 8;
    c.minimumFrequencyHz = 20.0;
    c.maximumFrequencyHz = 20000.0;
    c.lowFrequencyUpperHz = 250.0;
    c.tonalSearchUpperHz = 1000.0;
    c.minimumTonalProminenceDB = 8.0;
    c.maximumTonalComponents = 8;
    c.negligiblePlaybackDBFS = -70.0;
    c.maximumPlaybackAlignmentSeconds = 0.35;
    c.alignmentSearchRateHz = 2000.0;
    *out = c;
}

uint32_t n60_ambient_window_frames(const n60_ambient_config *config, uint32_t microphoneCount) {
    if (config == nullptr || config->maximumAnalysisFrames <= 0) return 0;
    return std::min<uint32_t>(microphoneCount, uint32_t(config->maximumAnalysisFrames));
}

int32_t n60_ambient_analyze(const n60_ambient_config *config, const float *microphone, uint32_t microphoneCount,
                            const n60_ambient_source *sources, uint32_t sourceCount, double sampleRate,
                            n60_ambient_result *result, n60_ambient_band *spectrumOut, n60_ambient_band *modeledSpectrumOut,
                            n60_ambient_tone *tonesOut, uint32_t toneCapacity, float *residualOut) {
    if (config == nullptr || result == nullptr || spectrumOut == nullptr || modeledSpectrumOut == nullptr ||
        tonesOut == nullptr || residualOut == nullptr || (microphone == nullptr && microphoneCount > 0) ||
        (sources == nullptr && sourceCount > 0)) {
        return N60_ANC_DESIGN_ERR_ARGUMENT;
    }
    if (!validConfig(*config)) return N60_AMBIENT_ERR_CONFIGURATION;
    const n60_ambient_config &c = *config;
    if (!(std::isfinite(sampleRate) && sampleRate > 0)) return N60_AMBIENT_ERR_SAMPLE_RATE;
    if (microphoneCount < uint32_t(c.minimumAnalysisFrames)) return N60_AMBIENT_ERR_INSUFFICIENT;
    for (uint32_t i = 0; i < microphoneCount; ++i) {
        if (!std::isfinite(microphone[i])) return N60_AMBIENT_ERR_NONFINITE_MICROPHONE;
    }
    for (uint32_t s = 0; s < sourceCount; ++s) {
        const n60_ambient_source &src = sources[s];
        if (src.samples == nullptr) return N60_AMBIENT_ERR_LENGTH_MISMATCH;
        for (uint32_t i = 0; i < microphoneCount; ++i) {
            if (!std::isfinite(src.samples[i])) return N60_AMBIENT_ERR_NONFINITE_PLAYBACK;
        }
        if (src.impulse != nullptr) {
            bool nonzero = false;
            if (src.impulseCount == 0) return N60_AMBIENT_ERR_ACOUSTIC_MODEL;
            for (uint32_t i = 0; i < src.impulseCount; ++i) {
                if (!std::isfinite(src.impulse[i])) return N60_AMBIENT_ERR_ACOUSTIC_MODEL;
                if (std::fabs(src.impulse[i]) > 1.0e-12f) nonzero = true;
            }
            if (!nonzero) return N60_AMBIENT_ERR_ACOUSTIC_MODEL;
        }
    }

    const size_t frames = std::min<size_t>(microphoneCount, size_t(c.maximumAnalysisFrames));
    const float *mic = microphone + (microphoneCount - frames);
    n60_ambient_result r{};
    r.analyzedFrames = uint32_t(frames);
    const double micLevel = dbfsAmp(rmsOf(mic, frames));
    r.microphoneLevelDBFS = micLevel;
    r.separationMode = N60_AMBIENT_MODE_MICROPHONE_ONLY;
    double confidence = 1.0;
    const float *residual = mic;
    std::vector<float> residualStore;
    uint32_t modeledCount = 0;
        std::vector<uint32_t> audible;
        bool unmodelled = false;
        for (uint32_t s = 0; s < sourceCount; ++s) {
            const float *w = sources[s].samples + (microphoneCount - frames);
            if (dbfsAmp(rmsOf(w, frames)) > c.negligiblePlaybackDBFS) {
                audible.push_back(s);
                if (sources[s].impulse == nullptr) unmodelled = true;
            }
        }
        if (!audible.empty()) {
            if (unmodelled) {
                r.separationMode = N60_AMBIENT_MODE_MODEL_UNAVAILABLE;
                confidence = 0.15;
            } else {
                std::vector<float> predicted(frames, 0.0f), contribution;
                for (uint32_t s : audible) {
                    const n60_ambient_source &src = sources[s];
                    const size_t taps = std::min<size_t>(src.impulseCount, size_t(c.maximumImpulseTaps));
                    int32_t err = N60_ANC_DESIGN_OK;
                    if (!predictPlayback(src.samples + (microphoneCount - frames), frames, src.impulse, taps, contribution, err)) {
                        return err;
                    }
                    for (size_t i = 0; i < frames; ++i) predicted[i] += contribution[i];
                }
                Alignment al;
                if (!alignPlayback(c, mic, predicted, sampleRate, al)) return N60_ANC_DESIGN_ERR_ALLOC;
                r.hasAlignment = 1;
                r.alignmentLagFrames = int32_t(al.lag);
                r.alignmentConfidence = al.confidence;
                double gain = 0, scaleConf = 0;
                estimateScale(c, mic, al.aligned, gain, scaleConf);
                r.hasPredictionGain = 1;
                r.predictionGain = gain;
                r.hasPredictedLevel = 1;
                r.predictedPlaybackLevelDBFS = dbfsAmp(rmsOf(al.aligned.data(), frames) * gain);
                residualStore.resize(frames);
                std::vector<float> scaled(frames);
                for (size_t i = 0; i < frames; ++i) {
                    residualStore[i] = float(double(mic[i]) - gain * double(al.aligned[i]));
                    scaled[i] = float(double(al.aligned[i]) * gain);
                }
                residual = residualStore.data();
                Frame pf;
                if (!makeFrame(scaled.data(), frames, pf)) return N60_ANC_DESIGN_ERR_ALLOC;
                modeledCount = makeBands(c, pf, sampleRate, modeledSpectrumOut);
                r.hasModeledSpectrum = 1;
                r.separationMode = N60_AMBIENT_MODE_MODELED_SUBTRACTION;
                confidence = scaleConf * al.confidence;
            }
        }

        const double ambientLevel = dbfsAmp(rmsOf(residual, frames));
        r.ambientLevelDBFS = ambientLevel;
        Frame frame;
        if (!makeFrame(residual, frames, frame)) return N60_ANC_DESIGN_ERR_ALLOC;
        r.spectrumCount = makeBands(c, frame, sampleRate, spectrumOut);
        bool ok = true;
        r.tonalCount = makeTones(c, frame, sampleRate, toneCapacity, tonesOut, ok);
        if (!ok) return N60_ANC_DESIGN_ERR_ALLOC;
        r.stationarityScore = stationarity(c, residual, frames);
        double pscore = 0, pfreq = 0;
        bool hasP = false;
        const int32_t perr = periodicity(c, residual, frames, sampleRate, pscore, hasP, pfreq);
        if (perr != N60_ANC_DESIGN_OK) return perr;
        r.periodicityScore = pscore;
        r.hasPeriodicFrequency = hasP ? 1 : 0;
        r.periodicFrequencyHz = hasP ? pfreq : 0;

        const double lowUpper = std::min(c.lowFrequencyUpperHz, sampleRate * 0.49);
        double lowP = 0, totalP = 0;
        for (uint32_t i = 0; i < r.spectrumCount; ++i) {
            const double p = std::pow(10.0, spectrumOut[i].levelDBFS / 10.0);
            totalP += p;
            if (spectrumOut[i].centerFrequencyHz <= lowUpper) lowP += p;
        }
        r.lowFrequencyEnergyFraction = totalP > 0 ? clamp01(lowP / totalP) : 0;
        r.cancellationCandidateScore =
            clamp01(confidence * r.stationarityScore * std::min(1.0, r.lowFrequencyEnergyFraction * 1.25 + pscore * 0.15));
        r.character = classify(ambientLevel, r.stationarityScore, pscore, r.tonalCount > 0,
                               r.tonalCount > 0 ? tonesOut[0].prominenceDB : 0);
        r.separationConfidence = clamp01(confidence);
        (void)modeledCount;
        std::copy(residual, residual + frames, residualOut);
    *result = r;
    return N60_ANC_DESIGN_OK;
}

}  // extern "C"
