// E33 S21: fit EQ bands to a curve (n60/eqfit.h). Offline; control or worker thread only.
#include "n60/eqfit.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "snapshot.hpp"

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kStopFraction = 0.02;  // best candidate must remove this share of the error
constexpr double kMinGainDb = 0.3;
constexpr double kBoostQCap = 4.0;
constexpr double kMinQ = 0.5;
constexpr double kMaxQ = 10.0;
constexpr double kShelfQ = 0.7071067811865476;
constexpr double kBoostWeight = 0.5;

// dB magnitude of one cookbook band at every listed frequency; false when the design refuses.
bool bandResponse(uint32_t type, double rate, double f, double gain, double q, const std::vector<double> &hz,
                  std::vector<double> &out) {
    double c[5];
    out.assign(hz.size(), 0.0);
    if (!n60::designBiquad(type, rate, f, gain, q, c)) return false;
    for (size_t i = 0; i < hz.size(); ++i) {
        const double w = 2.0 * kPi * hz[i] / rate;
        const double cw = std::cos(w), c2 = std::cos(2.0 * w);
        const double num = c[0] * c[0] + c[1] * c[1] + c[2] * c[2] + 2.0 * (c[0] * c[1] + c[1] * c[2]) * cw +
                           2.0 * c[0] * c[2] * c2;
        const double den = 1.0 + c[3] * c[3] + c[4] * c[4] + 2.0 * (c[3] + c[3] * c[4]) * cw + 2.0 * c[4] * c2;
        if (!(num > 0.0) || !(den > 0.0)) return false;
        out[i] = 10.0 * std::log10(num / den);
    }
    return true;
}

double interp(const double *f, const double *v, uint32_t n, double x) {
    if (x <= f[0]) return v[0];
    if (x >= f[n - 1]) return v[n - 1];
    uint32_t lo = 0, hi = n - 1;
    while (hi - lo > 1) {
        const uint32_t mid = (lo + hi) / 2;
        if (f[mid] <= x) lo = mid; else hi = mid;
    }
    const double t = (std::log(x) - std::log(f[lo])) / (std::log(f[hi]) - std::log(f[lo]));
    return v[lo] + t * (v[hi] - v[lo]);
}

struct Candidate {
    n60_eqfit_band band{};
    double sse = 0.0;
    std::vector<double> response;
    bool valid = false;
};

double weightedSse(const std::vector<double> &r, const std::vector<double> &resp) {
    double s = 0.0;
    for (size_t i = 0; i < r.size(); ++i) {
        const double d = r[i] - resp[i];
        s += (r[i] < 0.0 ? 1.0 : kBoostWeight) * d * d;
    }
    return s;
}

// Least-squares gain for a band shape, probed at g0, then evaluated exactly.
void tryBand(uint32_t type, double f, double q, double g0, double maxBoost, double maxCut, double rate,
             const std::vector<double> &hz, const std::vector<double> &r, Candidate &best) {
    if (std::fabs(g0) < 1e-6) return;
    std::vector<double> h;
    if (!bandResponse(type, rate, f, g0, q, hz, h)) return;
    double num = 0.0, den = 0.0;
    for (size_t i = 0; i < r.size(); ++i) {
        const double wt = r[i] < 0.0 ? 1.0 : kBoostWeight;
        num += wt * r[i] * h[i];
        den += wt * h[i] * h[i];
    }
    if (!(den > 0.0)) return;
    double g = g0 * num / den;
    g = std::min(std::max(g, -maxCut), maxBoost);
    if (std::fabs(g) < kMinGainDb) return;
    std::vector<double> resp;
    if (!bandResponse(type, rate, f, g, q, hz, resp)) return;
    const double sse = weightedSse(r, resp);
    if (!best.valid || sse < best.sse) {
        best.band = {type, f, g, q};
        best.sse = sse;
        best.response.swap(resp);
        best.valid = true;
    }
}

bool finiteAll(const double *p, uint32_t n) {
    for (uint32_t i = 0; i < n; ++i) {
        if (!std::isfinite(p[i])) return false;
    }
    return true;
}

double clampDb(double v, double maxCut, double maxBoost) { return std::min(std::max(v, -maxCut), maxBoost); }

}  // namespace

extern "C" uint32_t n60_eqfit_abi_version(void) { return N60_EQFIT_ABI_VERSION; }

extern "C" int n60_eqfit_fit(const n60_eqfit_problem *p, n60_eqfit_result *res) {
    if (p == nullptr || res == nullptr || p->struct_size != sizeof(n60_eqfit_problem) ||
        res->struct_size != sizeof(n60_eqfit_result) || p->frequencies_hz == nullptr || p->measured_db == nullptr ||
        p->target_db == nullptr || res->bands == nullptr)
        return N60_EQFIT_ERR_ARGUMENT;
    res->band_count = 0;
    res->rms_before_db = res->rms_after_db = res->low_hz = res->high_hz = 0.0;
    if (!std::isfinite(p->sample_rate) || p->sample_rate < 8000.0 || p->sample_rate > 768000.0 ||
        p->point_count < N60_EQFIT_MIN_POINTS || p->point_count > N60_EQFIT_MAX_POINTS || p->max_bands < 1 ||
        p->max_bands > N60_EQFIT_MAX_BANDS || !std::isfinite(p->max_boost_db) || p->max_boost_db < 0.0 ||
        p->max_boost_db > N60_EQFIT_MAX_GAIN_DB || !std::isfinite(p->max_cut_db) || !(p->max_cut_db > 0.0) ||
        p->max_cut_db > N60_EQFIT_MAX_GAIN_DB || !std::isfinite(p->low_hz) || !std::isfinite(p->high_hz))
        return N60_EQFIT_ERR_ARGUMENT;
    const uint32_t n = p->point_count;
    if (!finiteAll(p->frequencies_hz, n) || !finiteAll(p->measured_db, n) || !finiteAll(p->target_db, n) ||
        p->frequencies_hz[0] <= 0.0)
        return N60_EQFIT_ERR_DATA;
    for (uint32_t i = 1; i < n; ++i) {
        if (!(p->frequencies_hz[i] > p->frequencies_hz[i - 1])) return N60_EQFIT_ERR_DATA;
    }
    const double lo = std::max({p->low_hz, p->frequencies_hz[0], 1.0});
    const double hi = std::min({p->high_hz, p->frequencies_hz[n - 1], N60_EQFIT_MAX_FRACTION * p->sample_rate});
    if (!(hi > lo * 1.5)) return N60_EQFIT_ERR_DATA;
    uint32_t inRange = 0;
    for (uint32_t i = 0; i < n; ++i) {
        if (p->frequencies_hz[i] >= lo && p->frequencies_hz[i] <= hi) ++inRange;
    }
    if (inRange < N60_EQFIT_MIN_POINTS) return N60_EQFIT_ERR_DATA;

    // Log grid and the correction wanted on it.
    const double octaves = std::log2(hi / lo);
    const uint32_t m = static_cast<uint32_t>(std::ceil(octaves * N60_EQFIT_GRID_STEPS_PER_OCTAVE)) + 1;
    std::vector<double> hz(m), e(m), r(m);
    for (uint32_t i = 0; i < m; ++i) {
        hz[i] = lo * std::pow(2.0, octaves * static_cast<double>(i) / static_cast<double>(m - 1));
        e[i] = interp(p->frequencies_hz, p->target_db, n, hz[i]) - interp(p->frequencies_hz, p->measured_db, n, hz[i]);
    }
    for (uint32_t i = 0; i < m; ++i) {  // 5-point moving average, edges clamp
        double s = 0.0;
        for (int k = -2; k <= 2; ++k) {
            const int j = std::min(std::max(static_cast<int>(i) + k, 0), static_cast<int>(m) - 1);
            s += e[static_cast<size_t>(j)];
        }
        r[i] = s / 5.0;
    }
    double mean = 0.0;
    for (uint32_t i = 0; i < m; ++i) mean += r[i];
    mean /= static_cast<double>(m);
    for (uint32_t i = 0; i < m; ++i) r[i] -= mean;
    const auto rms = [](const std::vector<double> &v) {
        double s = 0.0;
        for (double x : v) s += x * x;
        return std::sqrt(s / static_cast<double>(v.size()));
    };
    res->rms_before_db = rms(r);

    std::vector<n60_eqfit_band> bands;
    const uint32_t cornerStep = N60_EQFIT_GRID_STEPS_PER_OCTAVE / 2;
    for (uint32_t round = 0; round < p->max_bands; ++round) {
        double sse0 = 0.0;
        uint32_t k = 0;
        double bestScore = -1.0;
        for (uint32_t i = 0; i < m; ++i) {
            sse0 += (r[i] < 0.0 ? 1.0 : kBoostWeight) * r[i] * r[i];
            const double score = (r[i] < 0.0 ? 1.0 : kBoostWeight) * std::fabs(r[i]);
            if (score > bestScore) { bestScore = score; k = i; }
        }
        if (!(sse0 > 0.0)) break;
        Candidate best;
        // Peaking: Q from the half-depth width of the error around the peak.
        const double peak = r[k];
        uint32_t left = k, right = k;
        while (left > 0 && r[left - 1] * peak > 0.0 && std::fabs(r[left - 1]) >= 0.5 * std::fabs(peak)) --left;
        while (right + 1 < m && r[right + 1] * peak > 0.0 && std::fabs(r[right + 1]) >= 0.5 * std::fabs(peak)) ++right;
        const double bw = static_cast<double>(right - left + 1) / static_cast<double>(N60_EQFIT_GRID_STEPS_PER_OCTAVE);
        const double qEst = 1.0 / (2.0 * std::sinh(0.5 * std::log(2.0) * bw));
        const double scales[3] = {0.7, 1.0, 1.4};
        for (double s : scales) {
            double q = std::min(std::max(qEst * s, kMinQ), kMaxQ);
            if (peak > 0.0) q = std::min(q, kBoostQCap);
            tryBand(N60_EQFIT_BAND_PEAKING, hz[k], q, clampDb(peak, p->max_cut_db, p->max_boost_db), p->max_boost_db,
                    p->max_cut_db, p->sample_rate, hz, r, best);
        }
        // Shelves at half-octave corners.
        for (uint32_t c = cornerStep; c + cornerStep < m; c += cornerStep) {
            double lowMean = 0.0, highMean = 0.0;
            for (uint32_t i = 0; i < cornerStep; ++i) lowMean += r[i];
            lowMean /= static_cast<double>(cornerStep);
            for (uint32_t i = 0; i < cornerStep; ++i) highMean += r[m - 1 - i];
            highMean /= static_cast<double>(cornerStep);
            tryBand(N60_EQFIT_BAND_LOW_SHELF, hz[c], kShelfQ, clampDb(lowMean, p->max_cut_db, p->max_boost_db),
                    p->max_boost_db, p->max_cut_db, p->sample_rate, hz, r, best);
            tryBand(N60_EQFIT_BAND_HIGH_SHELF, hz[c], kShelfQ, clampDb(highMean, p->max_cut_db, p->max_boost_db),
                    p->max_boost_db, p->max_cut_db, p->sample_rate, hz, r, best);
        }
        if (!best.valid || sse0 - best.sse < kStopFraction * sse0) break;
        bands.push_back(best.band);
        for (uint32_t i = 0; i < m; ++i) r[i] -= best.response[i];
    }
    std::stable_sort(bands.begin(), bands.end(),
                     [](const n60_eqfit_band &a, const n60_eqfit_band &b) { return a.frequency_hz < b.frequency_hz; });
    res->band_count = static_cast<uint32_t>(bands.size());
    for (size_t i = 0; i < bands.size(); ++i) res->bands[i] = bands[i];
    res->rms_after_db = rms(r);
    res->low_hz = lo;
    res->high_hz = hi;
    if (res->predicted_db != nullptr) {
        std::vector<double> freq(p->frequencies_hz, p->frequencies_hz + n), resp;
        for (uint32_t i = 0; i < n; ++i) res->predicted_db[i] = p->measured_db[i];
        for (const n60_eqfit_band &b : bands) {
            if (!bandResponse(b.type, p->sample_rate, b.frequency_hz, b.gain_db, b.q, freq, resp)) continue;
            for (uint32_t i = 0; i < n; ++i) res->predicted_db[i] += resp[i];
        }
    }
    return N60_EQFIT_OK;
}
