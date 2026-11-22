// Speaker Optimizer PEQ and FIR candidate searches (E21 S9a, n60/speaker.h section 3).
//
// The port of SpeakerOptimizerPEQCandidateDesigner and SpeakerOptimizerFIRCandidateDesigner (the numeric parts), in double
// precision in the same order. Offline only; allocates; deterministic; never an audio callback. No Apple framework.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#include "../measure/offline_fft.hpp"
#include "n60/correct.h"
#include "n60/speaker.h"

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();

struct Band {
    double centre = 0, q = 0, gain = 0, b0 = 0, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
};

bool makePeak(double centre, double q, double gain, double sr, Band *out) {
    if (!std::isfinite(centre) || !std::isfinite(q) || !std::isfinite(gain) || !std::isfinite(sr) || !(centre > 0) ||
        !(centre < sr * 0.49) || !(q > 0) || !(sr > 0))
        return false;
    const double w = 2 * kPi * centre / sr;
    const double a = std::pow(10.0, gain / 40);
    const double alpha = std::sin(w) / (2 * q);
    const double a0 = 1 + alpha / a;
    if (!std::isfinite(a0) || !(a0 > 0)) return false;
    const double c = std::cos(w);
    Band r;
    r.centre = centre;
    r.q = q;
    r.gain = gain;
    r.b0 = (1 + alpha * a) / a0;
    r.b1 = (-2 * c) / a0;
    r.b2 = (1 - alpha * a) / a0;
    r.a1 = (-2 * c) / a0;
    r.a2 = (1 - alpha / a) / a0;
    for (double v : {r.b0, r.b1, r.b2, r.a1, r.a2})
        if (!std::isfinite(v)) return false;
    if (!(std::fabs(r.a2) < 1) || !(1 + r.a1 + r.a2 > 0) || !(1 - r.a1 + r.a2 > 0)) return false;
    *out = r;
    return true;
}

double magnitudeDb(const Band &b, double f, double sr) {
    const double w = 2 * kPi * f / sr;
    const double rn = b.b0 + b.b1 * std::cos(w) + b.b2 * std::cos(2 * w);
    const double in = -b.b1 * std::sin(w) - b.b2 * std::sin(2 * w);
    const double rd = 1 + b.a1 * std::cos(w) + b.a2 * std::cos(2 * w);
    const double id = -b.a1 * std::sin(w) - b.a2 * std::sin(2 * w);
    const double num = rn * rn + in * in;
    const double den = rd * rd + id * id;
    if (!std::isfinite(num) || !std::isfinite(den) || !(num > 0) || !(den > 0)) return kNaN;
    return 10 * std::log10(num / den);
}

double bandsAt(const std::vector<Band> &bands, double f, double sr) {
    double s = 0.0;
    for (const Band &b : bands) s += magnitudeDb(b, f, sr);
    return s;
}

double ceilHalf(double v) { return v > 1e-6 ? std::ceil((v + 0.5) * 2) / 2 : 0.0; }

struct Evidence {
    const n60_speaker_candidate_problem &p;
    uint32_t n;
    double rmse(uint32_t pos, const double *correction) const {
        const double *s = p.position_db + static_cast<size_t>(pos) * n;
        double sum = 0.0;
        for (uint32_t i = 0; i < n; ++i) {
            const double r = s[i] + (correction ? correction[i] : 0.0) - p.target_db[i];
            sum += r * r;
        }
        return std::sqrt(sum / static_cast<double>(n));
    }
    double weighted(const double *correction) const {
        double total = 0.0;
        for (uint32_t i = 0; i < p.position_count; ++i) {
            const double e = rmse(i, correction);
            total += p.position_weight[i] * e * e;
        }
        return std::sqrt(total);
    }
    double worstRegression(const double *correction) const {
        double worst = -std::numeric_limits<double>::infinity();
        for (uint32_t i = 0; i < p.position_count; ++i) worst = std::max(worst, rmse(i, correction) - rmse(i, nullptr));
        return worst;
    }
};

bool problemValid(const n60_speaker_candidate_problem *p) {
    if (p == nullptr || p->struct_size != sizeof(n60_speaker_candidate_problem) || p->bin_count < 16 || p->position_count == 0 ||
        p->frequency_hz == nullptr || p->target_db == nullptr || p->desired_db == nullptr || p->position_db == nullptr ||
        p->position_weight == nullptr || !std::isfinite(p->sample_rate) || !(p->sample_rate > 0))
        return false;
    for (uint32_t i = 0; i < p->bin_count; ++i) {
        const double f = p->frequency_hz[i];
        if (!std::isfinite(f) || !(f > 0) || !(f < p->sample_rate * 0.49)) return false;
        if (i > 0 && !(f > p->frequency_hz[i - 1])) return false;
        if (!std::isfinite(p->target_db[i]) || !std::isfinite(p->desired_db[i])) return false;
    }
    return true;
}

std::vector<double> gainSteps(double maximum) {
    std::vector<double> gains;
    if (!(maximum >= 0.25)) return gains;
    double gain = 0.5;
    while (gain <= maximum + 1e-9) {
        gains.push_back(gain);
        gain += 0.5;
    }
    if (!gains.empty() && gains.back() < maximum - 1e-6) gains.push_back(maximum);
    return gains;
}

double modeledRmse(const std::vector<double> &actual, const double *desired) {
    if (actual.empty()) return std::numeric_limits<double>::infinity();
    double sq = 0.0;
    for (size_t i = 0; i < actual.size(); ++i) {
        const double d = actual[i] - desired[i];
        sq += d * d;
    }
    return std::sqrt(sq / static_cast<double>(actual.size()));
}

}  // namespace

extern "C" {

int32_t n60_speaker_peq_design(const n60_speaker_candidate_problem *p, const n60_speaker_peq_constraints *c,
                               n60_speaker_peq_result *r) {
    if (!problemValid(p) || c == nullptr || r == nullptr || r->correction_db == nullptr || c->maximum_bands == 0 ||
        c->maximum_bands > N60_SPEAKER_MAX_BANDS || !(c->maximum_band_gain_db > 0))
        return N60_SPEAKER_ERR_ARGUMENT;
    const uint32_t n = p->bin_count;
    const double sr = p->sample_rate;
    const double *f = p->frequency_hz;
    const Evidence ev{*p, n};
    const double low = f[0], high = f[n - 1];
    const double maximumCentre = std::min(high, sr * 0.45);
    std::vector<double> allowedQs;
    for (double q : {0.55, 0.7, 1.0, 1.4, 2.0, 2.8, 4.0, 5.0, 6.0})
        if (q >= c->minimum_q && q <= c->maximum_q) allowedQs.push_back(q);
    const std::vector<double> cuts = gainSteps(std::min(p->maximum_cut_db, c->maximum_band_gain_db));
    const std::vector<double> boosts = gainSteps(std::min(p->maximum_boost_db, c->maximum_band_gain_db));
    std::vector<double> gains;
    for (double g : cuts) gains.push_back(-g);
    for (double g : boosts) gains.push_back(g);

    const double before = ev.weighted(nullptr);
    std::vector<double> corrections(n, 0.0), proposed(n), shape(n), bestShape(n);
    std::vector<Band> bands;
    double current = before;
    const double baselineError = before;
    std::vector<double> zeroRmse(p->position_count);
    for (uint32_t i = 0; i < p->position_count; ++i) zeroRmse[i] = ev.rmse(i, nullptr);
    // Out-of-band probe frequencies of the selection check.
    std::vector<double> outside;
    const double nyquist = sr * 0.5;
    for (int i = 0; i <= 48; ++i) {
        const double fo = 10 * std::pow((nyquist * 0.98) / 10, static_cast<double>(i) / 48);
        if (fo >= low && fo <= high) continue;
        outside.push_back(fo);
    }
    const uint32_t stride = std::max<uint32_t>(1, n / 48);
    const double minImp = c->minimum_improvement_db;

    for (uint32_t round = 0; round < c->maximum_bands; ++round) {
        bool haveBest = false;
        Band bestBand;
        double bestRmse = std::numeric_limits<double>::infinity();
        const double currentModeled = modeledRmse(corrections, p->desired_db);
        for (uint32_t index = 0; index < n; ++index) {
            if (index % stride != 0) continue;
            if (p->authorized && !p->authorized[index]) continue;
            const double centre = f[index];
            if (!(centre >= low * 1.15 && centre <= maximumCentre / 1.15)) continue;
            for (double gain : gains) {
                for (double q : allowedQs) {
                    Band band;
                    if (!makePeak(centre, q, gain, sr, &band)) continue;
                    bool ok = true;
                    for (uint32_t i = 0; i < n; ++i) {
                        shape[i] = magnitudeDb(band, f[i], sr);
                        if (!std::isfinite(shape[i])) {
                            ok = false;
                            break;
                        }
                    }
                    if (!ok) continue;
                    for (uint32_t i = 0; i < n; ++i) proposed[i] = corrections[i] + shape[i];
                    if (!(modeledRmse(proposed, p->desired_db) + minImp < currentModeled)) continue;
                    // passesChecks
                    const double candidateError = ev.weighted(proposed.data());
                    if (!std::isfinite(candidateError) || candidateError > baselineError + 1e-8) continue;
                    for (uint32_t pos = 0; pos < p->position_count && ok; ++pos)
                        if (!(ev.rmse(pos, proposed.data()) <= zeroRmse[pos] + p->maximum_seat_degradation_db + 1e-8)) ok = false;
                    if (!ok) continue;
                    double upper = 0.0;
                    for (const Band &b : bands) upper += std::max(0.0, b.gain);
                    upper += std::max(0.0, band.gain);
                    const double reserve = upper > 0 ? std::ceil((upper + 0.5) * 2) / 2 : 0.0;
                    if (!(reserve <= c->maximum_headroom_db + 1e-8)) continue;
                    for (uint32_t i = 0; i < n && ok; ++i)
                        if (!(std::isfinite(proposed[i]) && proposed[i] >= -p->maximum_cut_db - 1e-8 &&
                              proposed[i] <= p->maximum_boost_db + 1e-8))
                            ok = false;
                    if (!ok) continue;
                    if (p->protected_leakage_db >= 0 && p->authorized) {
                        for (uint32_t i = 0; i < n && ok; ++i)
                            if (!p->authorized[i] && std::fabs(proposed[i]) > p->protected_leakage_db + 1e-8) ok = false;
                        if (!ok) continue;
                    }
                    std::vector<Band> withBand = bands;
                    withBand.push_back(band);
                    for (double fo : outside) {
                        const double sum = bandsAt(withBand, fo, sr);
                        if (!std::isfinite(sum) || std::fabs(sum) > c->maximum_out_of_band_db + 1e-8) {
                            ok = false;
                            break;
                        }
                    }
                    if (!ok) continue;
                    const double result = candidateError;
                    if (result + minImp < current && result < bestRmse) {
                        haveBest = true;
                        bestBand = band;
                        bestRmse = result;
                        bestShape = shape;
                    }
                }
            }
        }
        if (!haveBest) break;
        bands.push_back(bestBand);
        for (uint32_t i = 0; i < n; ++i) corrections[i] += bestShape[i];
        current = bestRmse;
    }

    // Final dense audit.
    uint32_t removals = 0;
    while (!bands.empty()) {
        bool pass = true;
        double maximumPositive = 0.0;
        for (int i = 0; i <= 2048 && pass; ++i) {
            const double fo = 10 * std::pow((nyquist * 0.999) / 10, static_cast<double>(i) / 2048);
            const double gain = bandsAt(bands, fo, sr);
            if (!std::isfinite(gain) || !(gain >= -p->maximum_cut_db - 1e-6) || !(gain <= p->maximum_boost_db + 1e-6)) {
                pass = false;
                break;
            }
            if ((fo < low || fo > high) && std::fabs(gain) > c->maximum_out_of_band_db + 1e-6) {
                pass = false;
                break;
            }
            maximumPositive = std::max(maximumPositive, gain);
        }
        if (pass) pass = ceilHalf(maximumPositive) <= c->maximum_headroom_db + 1e-6;
        if (pass) break;
        bands.pop_back();
        ++removals;
    }
    for (uint32_t i = 0; i < n; ++i) corrections[i] = bandsAt(bands, f[i], sr);
    current = ev.weighted(corrections.data());

    double peak = 0.0;
    if (!bands.empty()) {
        for (int i = 0; i <= 1024; ++i) {
            const double fo = 10 * std::pow((nyquist * 0.99) / 10, static_cast<double>(i) / 1024);
            const double gain = bandsAt(bands, fo, sr);
            if (!std::isfinite(gain)) {
                peak = kNaN;
                break;
            }
            peak = std::max(peak, gain);
        }
    }
    if (!std::isfinite(peak) || peak > c->maximum_headroom_db + 1e-6) return N60_SPEAKER_ERR_PEAK;

    std::memset(r->bands, 0, sizeof r->bands);
    r->band_count = static_cast<uint32_t>(bands.size());
    for (size_t i = 0; i < bands.size(); ++i) {
        r->bands[i].frequency_hz = bands[i].centre;
        r->bands[i].gain_db = bands[i].gain;
        r->bands[i].q = bands[i].q;
        r->bands[i].b0 = static_cast<float>(bands[i].b0);
        r->bands[i].b1 = static_cast<float>(bands[i].b1);
        r->bands[i].b2 = static_cast<float>(bands[i].b2);
        r->bands[i].a1 = static_cast<float>(bands[i].a1);
        r->bands[i].a2 = static_cast<float>(bands[i].a2);
    }
    r->audit_removals = removals;
    std::memcpy(r->correction_db, corrections.data(), n * sizeof(double));
    r->rmse_before_db = before;
    r->rmse_after_db = current;
    r->worst_seat_regression_db = ev.worstRegression(corrections.data());
    r->maximum_positive_gain_db = peak;
    r->recommended_headroom_db = peak > 1e-6 ? std::ceil((peak + 0.5) * 2) / 2 : 0.0;
    return N60_SPEAKER_OK;
}

namespace {
struct Curve {
    const double *f;
    const double *v;
    uint32_t n;
};
double curveAmplitude(double hz, void *user) {
    const Curve &c = *static_cast<const Curve *>(user);
    double db = 0.0;
    n60_speaker_interpolate_log(c.f, c.v, c.n, hz, &db);
    return std::pow(10.0, db / 20.0);
}
}  // namespace

int32_t n60_speaker_fir_design(const n60_speaker_candidate_problem *p, const n60_speaker_fir_constraints *c,
                               n60_speaker_fir_result *r) {
    if (!problemValid(p) || c == nullptr || r == nullptr || r->taps == nullptr || r->response_db == nullptr ||
        c->tap_count < 3 || c->tap_count % 2 == 0 || c->maximum_taps == 0)
        return N60_SPEAKER_ERR_ARGUMENT;
    const uint32_t n = p->bin_count;
    const double sr = p->sample_rate;
    const double *f = p->frequency_hz;
    const Evidence ev{*p, n};
    const uint64_t required = std::max<uint64_t>(4096, static_cast<uint64_t>(c->tap_count) * 4);
    if (required > static_cast<uint64_t>(c->maximum_taps) * 8) return N60_SPEAKER_ERR_ARGUMENT;
    uint64_t size = 1;
    while (size < required) size <<= 1;
    if (!n60::fft::offline::validSize(size)) return N60_SPEAKER_ERR_ARGUMENT;

    Curve curve{f, p->desired_db, n};
    n60_correct_band_taper taper{f[0], f[n - 1], 1.0 / 3.0};
    n60_correct_two_band_report report;
    std::memset(&report, 0, sizeof report);
    const int32_t status = n60_correct_synthesize_linear_phase_capped(sr, (c->tap_count - 1) / 2, curveAmplitude, &curve, &taper,
                                                                       c->single_band_cap, r->taps, c->tap_count, nullptr, 0,
                                                                       &report);
    if (status == N60_CORRECT_ERR_TOO_LONG) return N60_SPEAKER_ERR_TOO_LONG;
    if (status != N60_CORRECT_OK || report.low_tap_count != 0 || report.full_tap_count != c->tap_count)
        return N60_SPEAKER_ERR_NONFINITE;
    for (uint32_t i = 0; i < c->tap_count; ++i)
        if (!std::isfinite(r->taps[i])) return N60_SPEAKER_ERR_NONFINITE;

    std::vector<double> padded(size, 0.0);
    for (uint32_t i = 0; i < c->tap_count; ++i) padded[i] = static_cast<double>(r->taps[i]);
    std::vector<n60::fft::offline::Cplx> spectrum;
    if (!n60::fft::offline::realForward(padded.data(), size, spectrum)) return N60_SPEAKER_ERR_ALLOC;
    const uint64_t half = size / 2;

    for (uint32_t i = 0; i < n; ++i) {
        const double coordinate = f[i] / sr * static_cast<double>(size);
        if (!std::isfinite(coordinate) || coordinate < 0 || coordinate > static_cast<double>(half)) return N60_SPEAKER_ERR_GRID;
        const uint64_t lo = std::min<uint64_t>(half, static_cast<uint64_t>(std::floor(coordinate)));
        const uint64_t hi = std::min<uint64_t>(half, lo + 1);
        const double t = coordinate - static_cast<double>(lo);
        const double lm = std::hypot(spectrum[lo].re, spectrum[lo].im);
        const double hm = std::hypot(spectrum[hi].re, spectrum[hi].im);
        const double gain = 20 * std::log10(std::max(1e-10, lm + t * (hm - lm)));
        if (!std::isfinite(gain)) return N60_SPEAKER_ERR_NONFINITE;
        r->response_db[i] = gain;
    }

    const double before = ev.weighted(nullptr);
    const double after = ev.weighted(r->response_db);
    const double worst = ev.worstRegression(r->response_db);

    uint32_t blockers = 0;
    double maxGain = 0.0;
    const double low = f[0], high = f[n - 1];
    for (uint64_t bin = 0; bin <= half; ++bin) {
        const double frequency = static_cast<double>(bin) * sr / static_cast<double>(size);
        const double power = spectrum[bin].re * spectrum[bin].re + spectrum[bin].im * spectrum[bin].im;
        const double gain = 10 * std::log10(std::max(power, 1e-20));
        if (!std::isfinite(gain)) {
            blockers |= N60_SPEAKER_FIR_BLOCK_NONFINITE;
            break;
        }
        maxGain = std::max(maxGain, gain);
        if (gain < -p->maximum_cut_db - c->maximum_truncation_overshoot_db ||
            gain > p->maximum_boost_db + c->maximum_truncation_overshoot_db) {
            blockers |= N60_SPEAKER_FIR_BLOCK_OVERSHOOT;
            break;
        }
        if ((frequency < low || frequency > high) && std::fabs(gain) > c->maximum_out_of_band_db) {
            blockers |= N60_SPEAKER_FIR_BLOCK_OUT_OF_BAND;
            break;
        }
    }
    const double reserve = maxGain > 1e-6 ? std::ceil((maxGain + 0.5) * 2) / 2 : 0.0;
    if (reserve > c->maximum_headroom_db) blockers |= N60_SPEAKER_FIR_BLOCK_HEADROOM;
    if (p->protected_leakage_db >= 0 && p->authorized) {
        for (uint32_t i = 0; i < n; ++i)
            if (!p->authorized[i] && std::fabs(r->response_db[i]) > p->protected_leakage_db + 1.0e-8) {
                blockers |= N60_SPEAKER_FIR_BLOCK_LEAKAGE;
                break;
            }
    }
    if (!std::isfinite(after) || after > before - c->minimum_improvement_db) blockers |= N60_SPEAKER_FIR_BLOCK_NO_GAIN;
    if (worst > c->maximum_seat_degradation_db) blockers |= N60_SPEAKER_FIR_BLOCK_SEAT;

    r->blockers = blockers;
    r->rmse_before_db = before;
    r->rmse_after_db = after;
    r->worst_seat_regression_db = worst;
    r->maximum_positive_gain_db = maxGain;
    r->recommended_headroom_db = reserve;
    return N60_SPEAKER_OK;
}

}  // extern "C"
