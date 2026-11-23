// Speaker correction PEQ designer and grid interpolation (E21 S9a, n60/speaker.h sections 1 and 2).
//
// The port of the legacy N60SpeakerCorrectionDesigner.h in the same single-precision order, so results match it.
// Offline only: control or worker thread, never an audio callback. Portable: no Apple framework.
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

#include "n60/speaker.h"

namespace {

constexpr double kPi = 3.14159265358979323846;

bool is_finite_value(float v) { return std::isfinite(v); }

float biquadMagnitudeDb(const n60_speaker_band &b, double sample_rate, double frequency_hz) {
    const double omega = 2.0 * kPi * frequency_hz / sample_rate;
    const double cosine = std::cos(omega), sine = std::sin(omega);
    const double cos2 = std::cos(2.0 * omega), sin2 = std::sin(2.0 * omega);
    const double nr = static_cast<double>(b.b0) + static_cast<double>(b.b1) * cosine + static_cast<double>(b.b2) * cos2;
    const double ni = -static_cast<double>(b.b1) * sine - static_cast<double>(b.b2) * sin2;
    const double dr = 1.0 + static_cast<double>(b.a1) * cosine + static_cast<double>(b.a2) * cos2;
    const double di = -static_cast<double>(b.a1) * sine - static_cast<double>(b.a2) * sin2;
    const double np = nr * nr + ni * ni;
    const double dp = dr * dr + di * di;
    if (!std::isfinite(np) || !std::isfinite(dp) || np <= 0.0 || dp <= 1.0e-30) return 0.0f;
    return static_cast<float>(10.0 * std::log10(np / dp));
}

// RBJ peaking biquad in double, coefficients rounded to float (the legacy N60BiquadDesign for the peaking type).
bool makePeaking(double sample_rate, float frequency_hz, float gain_db, float q, n60_speaker_band *out) {
    const double f = frequency_hz, g = gain_db, qq = q;
    if (!std::isfinite(sample_rate) || sample_rate <= 0.0 || !std::isfinite(f) || f <= 0.0 || f >= sample_rate * 0.5 ||
        !std::isfinite(g) || g < -24.0 || g > 24.0 || !std::isfinite(qq) || qq <= 0.0)
        return false;
    const double omega = 2.0 * kPi * f / sample_rate;
    const double c = std::cos(omega), s = std::sin(omega);
    const double alpha = s / (2.0 * qq);
    const double A = std::pow(10.0, g / 40.0);
    const double b0 = 1.0 + alpha * A, b1 = -2.0 * c, b2 = 1.0 - alpha * A;
    const double a0 = 1.0 + alpha / A, a1 = -2.0 * c, a2 = 1.0 - alpha / A;
    if (!std::isfinite(a0) || std::fabs(a0) < 1.0e-20) return false;
    const double d[5] = {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
    for (double v : d)
        if (!std::isfinite(v)) return false;
    n60_speaker_band band{};
    band.frequency_hz = frequency_hz;
    band.gain_db = gain_db;
    band.q = q;
    band.b0 = static_cast<float>(d[0]);
    band.b1 = static_cast<float>(d[1]);
    band.b2 = static_cast<float>(d[2]);
    band.a1 = static_cast<float>(d[3]);
    band.a2 = static_cast<float>(d[4]);
    if (!is_finite_value(band.b0) || !is_finite_value(band.b1) || !is_finite_value(band.b2) || !is_finite_value(band.a1) || !is_finite_value(band.a2)) return false;
    *out = band;
    return true;
}

float planResponseDb(const n60_speaker_correction_source &d, double sample_rate, double frequency_hz) {
    float result = 0.0f;
    for (uint32_t i = 0; i < d.band_count; ++i) result += biquadMagnitudeDb(d.bands[i], sample_rate, frequency_hz);
    return result;
}

float clampGain(float requested, const n60_speaker_correction_settings &s) {
    if (requested > s.maximum_boost_db) return s.maximum_boost_db;
    if (requested < -s.maximum_cut_db) return -s.maximum_cut_db;
    return requested;
}

float rmsError(const float *frequency_hz, uint32_t bins, double sample_rate, const float *measured, const float *target,
               const n60_speaker_correction_source &d, const n60_speaker_correction_settings &s) {
    double sum = 0.0;
    uint32_t count = 0;
    for (uint32_t i = 0; i < bins; ++i) {
        const float hz = frequency_hz[i];
        if (hz < s.minimum_correction_hz || hz > s.maximum_correction_hz) continue;
        const float correction = planResponseDb(d, sample_rate, hz);
        const double error = static_cast<double>(target[i]) - (static_cast<double>(measured[i]) + static_cast<double>(correction));
        sum += error * error;
        count += 1;
    }
    if (count == 0) return INFINITY;
    return static_cast<float>(std::sqrt(sum / static_cast<double>(count)));
}

bool spaced(const n60_speaker_correction_source &d, float hz, float min_octaves) {
    if (min_octaves <= 0.0f) return true;
    for (uint32_t i = 0; i < d.band_count; ++i) {
        const float existing = static_cast<float>(d.bands[i].frequency_hz);
        if (existing <= 0.0f) continue;
        if (std::fabs(std::log2(hz / existing)) < min_octaves) return false;
    }
    return true;
}

bool weightedMagnitude(const n60_speaker_correction_problem &p, uint32_t source, std::vector<float> &mean, float *variance) {
    float total = 0.0f;
    for (uint32_t s = 0; s < p.seat_count; ++s)
        if (p.seat_weight[s] > 0.0f) total += p.seat_weight[s];
    if (!std::isfinite(total) || total <= 0.0f) return false;
    mean.assign(p.bin_count, 0.0f);
    for (uint32_t s = 0; s < p.seat_count; ++s) {
        if (p.seat_weight[s] <= 0.0f) continue;
        if (!p.response_valid[static_cast<size_t>(source) * p.seat_count + s]) return false;
        const float *m = p.magnitude_db + (static_cast<size_t>(source) * p.seat_count + s) * p.bin_count;
        const float normalized = p.seat_weight[s] / total;
        for (uint32_t i = 0; i < p.bin_count; ++i) mean[i] += m[i] * normalized;
    }
    float v = 0.0f;
    for (uint32_t s = 0; s < p.seat_count; ++s) {
        if (p.seat_weight[s] <= 0.0f) continue;
        const float *m = p.magnitude_db + (static_cast<size_t>(source) * p.seat_count + s) * p.bin_count;
        const float normalized = p.seat_weight[s] / total;
        for (uint32_t i = 0; i < p.bin_count; ++i) {
            const float difference = m[i] - mean[i];
            v += normalized * difference * difference / static_cast<float>(p.bin_count);
        }
    }
    *variance = v;
    return true;
}

}  // namespace

extern "C" {

uint32_t n60_speaker_abi_version(void) { return N60_SPEAKER_ABI_VERSION; }

int32_t n60_speaker_interpolate_log(const double *frequency_hz, const double *values, uint32_t count, double at_hz, double *out) {
    if (frequency_hz == nullptr || values == nullptr || out == nullptr || count < 2 || !std::isfinite(at_hz) || !(at_hz > 0.0))
        return N60_SPEAKER_ERR_ARGUMENT;
    if (at_hz <= frequency_hz[0]) {
        *out = values[0];
        return N60_SPEAKER_OK;
    }
    if (at_hz >= frequency_hz[count - 1]) {
        *out = values[count - 1];
        return N60_SPEAKER_OK;
    }
    uint32_t low = 0, high = count - 1;
    while (high - low > 1) {
        const uint32_t middle = (low + high) / 2;
        if (frequency_hz[middle] <= at_hz) low = middle;
        else high = middle;
    }
    const double denominator = std::log(frequency_hz[high] / frequency_hz[low]);
    if (!(denominator > 0.0)) {
        *out = values[low];
        return N60_SPEAKER_OK;
    }
    const double fraction = std::log(at_hz / frequency_hz[low]) / denominator;
    *out = values[low] + (values[high] - values[low]) * fraction;
    return N60_SPEAKER_OK;
}

double n60_speaker_target_gain_db(const double *frequency_hz, const double *gain_db, uint32_t count, double at_hz) {
    if (frequency_hz == nullptr || gain_db == nullptr || count < 2) return 0.0;
    if (at_hz <= frequency_hz[0]) return gain_db[0];
    if (at_hz >= frequency_hz[count - 1]) return gain_db[count - 1];
    for (uint32_t i = 1; i < count; ++i) {
        if (!(at_hz <= frequency_hz[i])) continue;
        const double denominator = std::log(frequency_hz[i] / frequency_hz[i - 1]);
        if (!(denominator > 0.0)) return gain_db[i - 1];
        const double fraction = std::log(at_hz / frequency_hz[i - 1]) / denominator;
        return gain_db[i - 1] + (gain_db[i] - gain_db[i - 1]) * fraction;
    }
    return 0.0;
}

void n60_speaker_correction_defaults(n60_speaker_correction_settings *s) {
    if (s == nullptr) return;
    s->maximum_band_count = 6;
    s->maximum_boost_db = 3.0f;
    s->maximum_cut_db = 10.0f;
    s->minimum_correction_hz = 20.0f;
    s->maximum_correction_hz = 20000.0f;
    s->minimum_useful_error_db = 0.75f;
    s->correction_damping = 0.72f;
    s->default_q = 1.15f;
    s->minimum_band_spacing_octaves = 0.28f;
}

int32_t n60_speaker_correction_settings_valid(const n60_speaker_correction_settings *s, double sample_rate) {
    if (s == nullptr) return 0;
    return s->maximum_band_count > 0 && s->maximum_band_count <= N60_SPEAKER_MAX_BANDS && std::isfinite(s->maximum_boost_db) &&
           s->maximum_boost_db >= 0.0f && s->maximum_boost_db <= 12.0f && std::isfinite(s->maximum_cut_db) &&
           s->maximum_cut_db >= 0.0f && s->maximum_cut_db <= 24.0f && std::isfinite(s->minimum_correction_hz) &&
           s->minimum_correction_hz > 0.0f && std::isfinite(s->maximum_correction_hz) &&
           s->maximum_correction_hz > s->minimum_correction_hz &&
           s->maximum_correction_hz < static_cast<float>(sample_rate * 0.5) && std::isfinite(s->minimum_useful_error_db) &&
           s->minimum_useful_error_db >= 0.0f && std::isfinite(s->correction_damping) && s->correction_damping > 0.0f &&
           s->correction_damping <= 1.0f && std::isfinite(s->default_q) && s->default_q >= 0.25f && s->default_q <= 8.0f &&
           std::isfinite(s->minimum_band_spacing_octaves) && s->minimum_band_spacing_octaves >= 0.0f &&
           s->minimum_band_spacing_octaves <= 2.0f;
}

int32_t n60_speaker_correction_design(const n60_speaker_correction_problem *p, n60_speaker_correction_source *sources) {
    if (p == nullptr || sources == nullptr || p->struct_size != sizeof(n60_speaker_correction_problem) || p->source_count == 0 ||
        p->seat_count == 0 || p->bin_count == 0 || p->frequency_hz == nullptr || p->target_db == nullptr ||
        p->seat_weight == nullptr || p->magnitude_db == nullptr || p->response_valid == nullptr)
        return N60_SPEAKER_ERR_ARGUMENT;
    const n60_speaker_correction_settings &settings = p->settings;
    if (!n60_speaker_correction_settings_valid(&settings, p->sample_rate)) return N60_SPEAKER_ERR_ARGUMENT;
    for (uint32_t i = 0; i < p->bin_count; ++i)
        if (!is_finite_value(p->target_db[i])) return N60_SPEAKER_ERR_NONFINITE;
    std::vector<n60_speaker_correction_source> out(p->source_count);
    std::vector<float> measured;
    {
        for (uint32_t source = 0; source < p->source_count; ++source) {
            float variance = 0.0f;
            if (!weightedMagnitude(*p, source, measured, &variance)) return N60_SPEAKER_ERR_ARGUMENT;
            n60_speaker_correction_source design{};
            design.valid = 1;
            design.seat_variance_db2 = variance;
            if (p->source_trim_db) design.trim_db = p->source_trim_db[source];
            if (p->source_delay_frames) design.delay_frames = p->source_delay_frames[source];
            if (p->source_polarity_inverted) design.polarity_inverted = p->source_polarity_inverted[source] ? 1 : 0;
            design.pre_rms_error_db =
                rmsError(p->frequency_hz, p->bin_count, p->sample_rate, measured.data(), p->target_db, design, settings);
            if (!std::isfinite(design.pre_rms_error_db)) return N60_SPEAKER_ERR_NONFINITE;
            float bestRMS = design.pre_rms_error_db;
            for (uint32_t iteration = 0; iteration < settings.maximum_band_count; ++iteration) {
                int32_t bestIndex = -1;
                float bestAbs = settings.minimum_useful_error_db;
                float gain = 0.0f;
                for (uint32_t i = 0; i < p->bin_count; ++i) {
                    const float hz = p->frequency_hz[i];
                    if (hz < settings.minimum_correction_hz || hz > settings.maximum_correction_hz) continue;
                    if (!spaced(design, hz, settings.minimum_band_spacing_octaves)) continue;
                    const float correction = planResponseDb(design, p->sample_rate, hz);
                    const float error = p->target_db[i] - (measured[i] + correction);
                    const float clamped = clampGain(error * settings.correction_damping, settings);
                    if (std::fabs(clamped) < settings.minimum_useful_error_db * 0.5f) continue;
                    const float absoluteError = std::fabs(error);
                    if (absoluteError > bestAbs) {
                        bestAbs = absoluteError;
                        bestIndex = static_cast<int32_t>(i);
                        gain = clamped;
                    }
                }
                if (bestIndex < 0) break;
                n60_speaker_band band{};
                if (!makePeaking(p->sample_rate, p->frequency_hz[bestIndex], gain, settings.default_q, &band))
                    return N60_SPEAKER_ERR_ARGUMENT;
                n60_speaker_correction_source candidate = design;
                candidate.bands[candidate.band_count++] = band;
                const float candidateRMS = rmsError(p->frequency_hz, p->bin_count, p->sample_rate, measured.data(),
                                                    p->target_db, candidate, settings);
                if (!std::isfinite(candidateRMS)) return N60_SPEAKER_ERR_NONFINITE;
                if (candidateRMS + 1.0e-4f < bestRMS) {
                    design = candidate;
                    bestRMS = candidateRMS;
                } else {
                    break;
                }
            }
            design.post_rms_error_db = bestRMS;
            out[source] = design;
        }
    }
    std::memcpy(sources, out.data(), out.size() * sizeof(n60_speaker_correction_source));
    return N60_SPEAKER_OK;
}

}  // extern "C"
