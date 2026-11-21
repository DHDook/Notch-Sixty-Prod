// Room-correction FIR design maths (E21 S6a and S6b, n60/correct.h section 7).
//
// The port of the numbers-to-numbers part of RoomCorrectionFIRDesigner.swift and RoomCorrectionTargetDesigner.swift:
// target curves, magnitude smoothing, the correction preview, the spectrum of a finished FIR and the headroom rules.
// Offline only: control or worker thread, allocates freely, never called from an audio callback. Double precision,
// fixed summation order, no threads. Portable: no Apple framework.
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <string>
#include <vector>

#include "common.hpp"
#include "../measure/offline_fft.hpp"

namespace {

using n60::correct::kPi;

int32_t validateTarget(const double *f, const double *g, uint32_t n) {
    if (f == nullptr || g == nullptr || n < 2) return N60_CORRECT_ERR_TARGET_POINTS;
    double previous = 0.0;
    for (uint32_t i = 0; i < n; ++i) {
        if (!std::isfinite(f[i]) || !(f[i] > previous) || !std::isfinite(g[i])) return N60_CORRECT_ERR_TARGET_CURVE;
        previous = f[i];
    }
    return N60_CORRECT_OK;
}

int32_t validateResponse(const double *f, const double *db, uint32_t n) {
    if (f == nullptr || db == nullptr || n == 0) return N60_CORRECT_ERR_RESPONSE;
    double previous = 0.0;
    for (uint32_t i = 0; i < n; ++i) {
        if (!std::isfinite(f[i]) || !(f[i] > previous) || !std::isfinite(db[i])) return N60_CORRECT_ERR_RESPONSE;
        previous = f[i];
    }
    return N60_CORRECT_OK;
}

// Caller has validated the curve.
double interpolateTarget(const double *f, const double *g, uint32_t n, double hz) {
    if (hz <= f[0]) return g[0];
    if (hz >= f[n - 1]) return g[n - 1];
    for (uint32_t i = 0; i + 1 < n; ++i) {
        if (!(hz <= f[i + 1])) continue;
        const double lowerLog = std::log(f[i]);
        const double upperLog = std::log(f[i + 1]);
        const double fraction = (std::log(hz) - lowerLog) / (upperLog - lowerLog);
        return g[i] + fraction * (g[i + 1] - g[i]);
    }
    return g[n - 1];
}

void smooth(const double *f, const double *db, uint32_t n, double octaves, double *out) {
    if (octaves <= 0.0) {
        for (uint32_t i = 0; i < n; ++i) out[i] = db[i];
        return;
    }
    const double halfWidth = octaves * 0.5;
    for (uint32_t i = 0; i < n; ++i) {
        const double center = f[i];
        double weightedSum = 0.0;
        double totalWeight = 0.0;
        for (uint32_t k = 0; k < n; ++k) {
            const double distance = std::fabs(std::log2(f[k] / center));
            if (!(distance <= halfWidth)) continue;
            const double normalized = halfWidth > 0.0 ? std::min(distance / halfWidth, 1.0) : 0.0;
            const double weight = 0.5 * (1.0 + std::cos(kPi * normalized));
            if (!(weight > 0.0)) continue;
            weightedSum += db[k] * weight;
            totalWeight += weight;
        }
        out[i] = totalWeight > 0.0 ? weightedSum / totalWeight : db[i];
    }
}

double edgeTaper(double frequency, double low, double high) {
    if (!(frequency > low) || !(frequency < high)) return 0.0;
    const double totalOctaves = std::log2(high / low);
    const double width = std::min(N60_CORRECT_EDGE_TAPER_OCTAVES, std::max(totalOctaves * 0.25, 1.0e-9));
    const double distance = std::min(std::log2(frequency / low), std::log2(high / frequency));
    if (!(distance < width)) return 1.0;
    const double normalized = std::min(std::max(distance / width, 0.0), 1.0);
    return 0.5 - 0.5 * std::cos(kPi * normalized);
}

void makeCorrection(const double *f, const double *raw, const double *smoothed, const double *target, uint32_t n,
                    const n60_correct_preview_params &p, double low, double high, double *out) {
    for (uint32_t i = 0; i < n; ++i) {
        out[i] = 0.0;
        const double frequency = f[i];
        if (!(frequency >= low) || !(frequency <= high)) continue;
        double requested = target[i] - smoothed[i];
        requested = std::min(std::max(requested, -p.maximum_cut_db), p.maximum_boost_db);
        if (requested > 0.0) {
            const double depth = std::max(0.0, smoothed[i] - raw[i]);
            if (depth > N60_CORRECT_NARROW_NULL_START_DB) {
                const double protectedBoost = std::max(0.0, p.maximum_boost_db - (depth - N60_CORRECT_NARROW_NULL_START_DB));
                requested = std::min(requested, protectedBoost);
            }
        }
        out[i] = requested * edgeTaper(frequency, low, high);
    }
}

bool gridsMatch(const double *a, const double *b, uint32_t n) {
    for (uint32_t i = 0; i < n; ++i) {
        const double tolerance = std::max(1.0e-6, std::fabs(a[i]) * 1.0e-9);
        if (std::fabs(a[i] - b[i]) > tolerance) return false;
    }
    return true;
}

bool isSpace(char c) { return c == ' ' || c == '\t' || c == '\v' || c == '\f'; }

// Whole-field double parse (Swift Double(String) accepts the same decimal, hex, inf and nan forms strtod does).
bool parseDouble(const std::string &field, double &value) {
    if (field.empty()) return false;
    char *end = nullptr;
    value = std::strtod(field.c_str(), &end);
    return end == field.c_str() + field.size();
}

}  // namespace

extern "C" {

int32_t n60_correct_builtin_target(uint32_t index, double *frequency_hz, double *gain_db, uint32_t capacity,
                                   uint32_t *count) {
    static const double kFlatF[] = {20, 20000};
    static const double kFlatG[] = {0, 0};
    static const double kTiltF[] = {20, 1000, 20000};
    static const double kTiltG[] = {1.0, 0, -2.5};
    static const double kShelfF[] = {20, 80, 200, 1000, 20000};
    static const double kShelfG[] = {4.0, 4.0, 1.0, 0, -2.5};
    if (frequency_hz == nullptr || gain_db == nullptr || count == nullptr || index >= N60_CORRECT_BUILTIN_TARGETS) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    const double *f = index == 0 ? kFlatF : (index == 1 ? kTiltF : kShelfF);
    const double *g = index == 0 ? kFlatG : (index == 1 ? kTiltG : kShelfG);
    const uint32_t n = index == 0 ? 2u : (index == 1 ? 3u : 5u);
    if (capacity < n) return N60_CORRECT_ERR_CAPACITY;
    for (uint32_t i = 0; i < n; ++i) {
        frequency_hz[i] = f[i];
        gain_db[i] = g[i];
    }
    *count = n;
    return N60_CORRECT_OK;
}

int32_t n60_correct_target_parse(const char *text, uint64_t length, double *frequency_hz, double *gain_db,
                                 uint32_t capacity, uint32_t *count, uint32_t *error_line) {
    if ((text == nullptr && length != 0) || frequency_hz == nullptr || gain_db == nullptr || count == nullptr) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    if (error_line != nullptr) *error_line = 0;
    struct Point {
        double f;
        double g;
    };
    std::vector<Point> points;
    bool sawData = false;
    uint32_t lineNumber = 0;
    uint64_t pos = 0;
    while (pos <= length) {
        // One line: up to the next LF or CR (each breaks a line, so a CRLF pair counts twice).
        uint64_t end = pos;
        while (end < length && text[end] != '\n' && text[end] != '\r') ++end;
        ++lineNumber;
        uint64_t b = pos;
        uint64_t e = end;
        while (b < e && isSpace(text[b])) ++b;
        while (e > b && isSpace(text[e - 1])) --e;
        pos = end + 1;
        if (b == e) continue;
        const char first = text[b];
        const bool slashes = e - b >= 2 && text[b] == '/' && text[b + 1] == '/';
        if (first == '#' || first == ';' || first == '*' || slashes) continue;
        sawData = true;
        std::string fields[3];
        uint32_t fieldCount = 0;
        bool inField = false;
        for (uint64_t i = b; i < e; ++i) {
            const char c = text[i] == ',' ? ' ' : text[i];
            if (isSpace(c)) {
                inField = false;
                continue;
            }
            if (!inField) {
                inField = true;
                ++fieldCount;
            }
            if (fieldCount <= 3) fields[fieldCount - 1].push_back(c);
        }
        double frequency = 0.0;
        double gain = 0.0;
        if (fieldCount != 2 || !parseDouble(fields[0], frequency) || !parseDouble(fields[1], gain)) {
            if (error_line != nullptr) *error_line = lineNumber;
            return N60_CORRECT_ERR_PARSE_LINE;
        }
        if (!std::isfinite(frequency) || !(frequency > 0.0)) {
            if (error_line != nullptr) *error_line = lineNumber;
            return N60_CORRECT_ERR_PARSE_FREQUENCY;
        }
        if (!std::isfinite(gain)) {
            if (error_line != nullptr) *error_line = lineNumber;
            return N60_CORRECT_ERR_PARSE_GAIN;
        }
        points.push_back({frequency, gain});
    }
    if (!sawData) return N60_CORRECT_ERR_PARSE_EMPTY;
    std::stable_sort(points.begin(), points.end(), [](const Point &a, const Point &b) { return a.f < b.f; });
    std::vector<Point> merged;
    size_t i = 0;
    while (i < points.size()) {
        size_t j = i;
        double sum = 0.0;
        while (j < points.size() && points[j].f == points[i].f) sum += points[j++].g;
        merged.push_back({points[i].f, sum / static_cast<double>(j - i)});
        i = j;
    }
    if (merged.size() < 2) return N60_CORRECT_ERR_TARGET_POINTS;
    if (merged.size() > capacity) return N60_CORRECT_ERR_CAPACITY;
    for (size_t k = 0; k < merged.size(); ++k) {
        frequency_hz[k] = merged[k].f;
        gain_db[k] = merged[k].g;
    }
    *count = static_cast<uint32_t>(merged.size());
    return N60_CORRECT_OK;
}

int32_t n60_correct_target_interpolate(const double *frequency_hz, const double *gain_db, uint32_t count,
                                       const double *query_hz, uint32_t query_count, double *out_db) {
    const int32_t status = validateTarget(frequency_hz, gain_db, count);
    if (status != N60_CORRECT_OK) return status;
    if ((query_hz == nullptr || out_db == nullptr) && query_count != 0) return N60_CORRECT_ERR_ARGUMENT;
    for (uint32_t i = 0; i < query_count; ++i) {
        if (!std::isfinite(query_hz[i]) || !(query_hz[i] > 0.0)) return N60_CORRECT_ERR_TARGET_CURVE;
    }
    for (uint32_t i = 0; i < query_count; ++i) out_db[i] = interpolateTarget(frequency_hz, gain_db, count, query_hz[i]);
    return N60_CORRECT_OK;
}

int32_t n60_correct_magnitude_smooth(const double *frequency_hz, const double *magnitude_db, uint32_t count,
                                     double octaves, double *out_db) {
    const int32_t status = validateResponse(frequency_hz, magnitude_db, count);
    if (status != N60_CORRECT_OK) return status;
    if (out_db == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    if (!std::isfinite(octaves) || octaves < 0.0) return N60_CORRECT_ERR_SMOOTHING;
    smooth(frequency_hz, magnitude_db, count, octaves, out_db);
    return N60_CORRECT_OK;
}

int32_t n60_correct_preview(const n60_correct_preview_params *params, const double *frequency_hz, uint32_t count,
                            const double *left_db, const double *right_frequency_hz, const double *right_db,
                            const double *target_frequency_hz, const double *target_gain_db, uint32_t target_count, n60_correct_preview_out *out) {
    if (params == nullptr || out == nullptr || out->target_db == nullptr || out->smoothed_left_db == nullptr ||
        out->smoothed_right_db == nullptr || out->left_correction_db == nullptr || out->right_correction_db == nullptr) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    const n60_correct_preview_params &p = *params;
    int32_t status = validateResponse(frequency_hz, left_db, count);
    if (status != N60_CORRECT_OK) return status;
    status = validateResponse(right_frequency_hz, right_db, count);
    if (status != N60_CORRECT_OK) return status;
    if (!gridsMatch(frequency_hz, right_frequency_hz, count)) return N60_CORRECT_ERR_GRID;
    status = validateTarget(target_frequency_hz, target_gain_db, target_count);
    if (status != N60_CORRECT_OK) return status;
    if (!std::isfinite(p.correction_low_hz) || !std::isfinite(p.correction_high_hz) || !(p.correction_low_hz > 0.0) ||
        !(p.correction_high_hz > p.correction_low_hz)) {
        return N60_CORRECT_ERR_RANGE;
    }
    if (!std::isfinite(p.smoothing_octaves) || p.smoothing_octaves < 0.0) return N60_CORRECT_ERR_SMOOTHING;
    if (!std::isfinite(p.maximum_boost_db) || p.maximum_boost_db < 0.0) return N60_CORRECT_ERR_BOOST;
    if (!std::isfinite(p.maximum_cut_db) || p.maximum_cut_db < 0.0) return N60_CORRECT_ERR_CUT;
    if (p.tap_count == 0 || p.tap_count > p.tap_limit) return N60_CORRECT_ERR_TAP_COUNT;

    const double measuredLow = p.has_usable_low != 0 ? p.usable_low_hz : frequency_hz[0];
    const double measuredHigh = p.has_usable_high != 0 ? p.usable_high_hz : frequency_hz[count - 1];
    if (!std::isfinite(measuredLow) || !(measuredLow > 0.0) || !std::isfinite(measuredHigh) ||
        !(measuredHigh > measuredLow)) {
        return N60_CORRECT_ERR_USABLE;
    }
    const double effectiveLow = std::max(std::max(p.correction_low_hz, measuredLow), frequency_hz[0]);
    const double effectiveHigh = std::min(std::min(p.correction_high_hz, measuredHigh), frequency_hz[count - 1]);
    if (!(effectiveHigh > effectiveLow)) return N60_CORRECT_ERR_NO_RANGE;

    smooth(frequency_hz, left_db, count, p.smoothing_octaves, out->smoothed_left_db);
    smooth(frequency_hz, right_db, count, p.smoothing_octaves, out->smoothed_right_db);
    for (uint32_t i = 0; i < count; ++i) {
        out->target_db[i] = interpolateTarget(target_frequency_hz, target_gain_db, target_count, frequency_hz[i]);
    }
    makeCorrection(frequency_hz, left_db, out->smoothed_left_db, out->target_db, count, p, effectiveLow, effectiveHigh,
                   out->left_correction_db);
    makeCorrection(frequency_hz, right_db, out->smoothed_right_db, out->target_db, count, p, effectiveLow,
                   effectiveHigh, out->right_correction_db);
    double maximum = 0.0;
    for (uint32_t i = 0; i < count; ++i) {
        maximum = std::max(maximum, std::max(out->left_correction_db[i], out->right_correction_db[i]));
    }
    out->effective_low_hz = effectiveLow;
    out->effective_high_hz = effectiveHigh;
    out->maximum_positive_db = maximum;
    out->estimated_headroom_db = n60_correct_recommended_headroom_db(maximum);
    return N60_CORRECT_OK;
}

double n60_correct_recommended_headroom_db(double maximum_positive_db) {
    return maximum_positive_db > 0.0 ? std::ceil((maximum_positive_db + 0.25) * 2.0) / 2.0 : 0.0;
}

int32_t n60_correct_fir_transform_size(uint32_t tap_count, uint32_t tap_limit, uint32_t *size) {
    if (size == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    if (tap_count == 0 || tap_count > tap_limit) return N60_CORRECT_ERR_TAP_COUNT;
    const uint64_t taps = tap_count;
    const uint64_t maximum = std::max<uint64_t>(1ull << 20, static_cast<uint64_t>(tap_limit) * 2);
    const uint64_t required = std::max<uint64_t>(
        N60_CORRECT_FIR_MIN_TRANSFORM, std::min<uint64_t>(taps * N60_CORRECT_FIR_OVERSAMPLING, std::max(taps * 2, maximum)));
    if (required > maximum) return N60_CORRECT_ERR_TRANSFORM;
    uint64_t power = 1;
    while (power < required) power <<= 1;
    if (power > maximum) return N60_CORRECT_ERR_TRANSFORM;
    *size = static_cast<uint32_t>(power);
    return N60_CORRECT_OK;
}

int32_t n60_correct_fir_response(const float *taps, uint32_t tap_count, double sample_rate, uint32_t transform_size,
                                 const double *frequency_hz, uint32_t count, double *out_db, double *maximum_positive_db) {
    if (taps == nullptr || frequency_hz == nullptr || out_db == nullptr || maximum_positive_db == nullptr ||
        !(sample_rate > 0.0) || !std::isfinite(sample_rate) || tap_count == 0 || transform_size < tap_count ||
        !n60::fft::offline::validSize(transform_size)) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    std::vector<double> padded(transform_size, 0.0);
    for (uint32_t i = 0; i < tap_count; ++i) {
        if (!std::isfinite(taps[i])) return N60_CORRECT_ERR_NONFINITE;
        padded[i] = static_cast<double>(taps[i]);
    }
    std::vector<n60::fft::offline::Cplx> spectrum;
    if (!n60::fft::offline::realForward(padded.data(), transform_size, spectrum)) return N60_CORRECT_ERR_ALLOC;
    const uint32_t half = transform_size / 2;
    std::vector<double> magnitude(half + 1);
    double maximum = 0.0;
    for (uint32_t k = 0; k <= half; ++k) {
        const double m = std::hypot(spectrum[k].re, spectrum[k].im);
        if (!std::isfinite(m)) return N60_CORRECT_ERR_NONFINITE;
        magnitude[k] = m;
        if (m > 0.0) maximum = std::max(maximum, 20.0 * std::log10(m));
    }
    for (uint32_t i = 0; i < count; ++i) {
        const double bin = frequency_hz[i] / sample_rate * static_cast<double>(transform_size);
        const double flo = std::floor(bin);
        const uint32_t lower = static_cast<uint32_t>(std::max(0.0, std::min(flo, static_cast<double>(half))));
        const uint32_t upper = std::min(lower + 1, half);
        const double fraction = std::max(0.0, std::min(bin - static_cast<double>(lower), 1.0));
        const double mag = magnitude[lower] + fraction * (magnitude[upper] - magnitude[lower]);
        const double db = 20.0 * std::log10(std::max(mag, 1.0e-12));
        if (!std::isfinite(db)) return N60_CORRECT_ERR_NONFINITE;
        out_db[i] = db;
    }
    *maximum_positive_db = maximum;
    return N60_CORRECT_OK;
}

int32_t n60_correct_scale_taps(const float *taps, uint32_t count, double headroom_db, float *out) {
    if ((taps == nullptr || out == nullptr) && count != 0) return N60_CORRECT_ERR_ARGUMENT;
    if (!std::isfinite(headroom_db) || headroom_db < 0.0) return N60_CORRECT_ERR_HEADROOM;
    const double scale = std::pow(10.0, -headroom_db / 20.0);
    if (!std::isfinite(scale) || !(scale > 0.0) || scale > 1.0) return N60_CORRECT_ERR_HEADROOM;
    for (uint32_t i = 0; i < count; ++i) {
        const float v = static_cast<float>(static_cast<double>(taps[i]) * scale);
        if (!std::isfinite(v)) return N60_CORRECT_ERR_NONFINITE;
        out[i] = v;
    }
    return N60_CORRECT_OK;
}

}  // extern "C"
