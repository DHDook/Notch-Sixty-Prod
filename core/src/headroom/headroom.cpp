// E9 S6: per-output headroom maths (n60/headroom.h). Offline; control or worker thread only.
#include "n60/headroom.h"
#include "n60/xover.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <vector>

#include "snapshot.hpp"

namespace {

using Cx = std::complex<double>;
constexpr double kPi = 3.14159265358979323846;

struct Biquad {
    double b0, b1, b2, a1, a2;
};

// One prepared stage: either a cascade of biquads, a pure complex factor source (delay, gain, make-up) or a FIR.
struct Prepared {
    enum Kind { Cascade, Gain, Delay, Fir } kind = Cascade;
    std::vector<Biquad> sections;
    double gain = 1.0;       // Gain: signed linear; Cascade: extra scalar
    double delayFrames = 0;
    const float *taps = nullptr;
    uint32_t tapCount = 0;
};

Cx biquadAt(const Biquad &q, double w) {
    const Cx z1 = std::polar(1.0, -w);
    const Cx z2 = z1 * z1;
    return (q.b0 + q.b1 * z1 + q.b2 * z2) / (1.0 + q.a1 * z1 + q.a2 * z2);
}

bool addPeq(std::vector<Biquad> &out, uint32_t type, double rate, double hz, double db, double q) {
    double c[5];
    if (!n60::designBiquad(type, rate, hz, db, q, c)) return false;
    out.push_back({c[0], c[1], c[2], c[3], c[4]});
    return true;
}

bool allFinite(const float *p, uint32_t n) {
    for (uint32_t i = 0; i < n; ++i) {
        if (!std::isfinite(p[i])) return false;
    }
    return true;
}

bool prepare(const n60_headroom_stage &s, double rate, Prepared &out) {
    if (s.param_count > N60_HEADROOM_MAX_PARAMS || (s.param_count != 0 && s.params == nullptr)) return false;
    if (s.param_count != 0 && !allFinite(s.params, s.param_count)) return false;
    const float *p = s.params;
    switch (s.kind) {
        case N60_HEADROOM_STAGE_GAIN:
            if (s.param_count != 1) return false;
            out.kind = Prepared::Gain;
            out.gain = p[0];
            return true;
        case N60_HEADROOM_STAGE_DELAY:
            if (s.param_count != 1 || p[0] < 0.0f) return false;
            out.kind = Prepared::Delay;
            out.delayFrames = p[0];
            return true;
        case N60_HEADROOM_STAGE_PEQ:
            if (s.param_count < 4 || s.param_count % 4 != 0) return false;
            for (uint32_t i = 0; i < s.param_count; i += 4) {
                if (p[i] < 0.0f || p[i] > 7.0f) return false;
                if (!addPeq(out.sections, static_cast<uint32_t>(p[i]), rate, p[i + 1], p[i + 2], p[i + 3])) return false;
            }
            return true;
        case N60_HEADROOM_STAGE_BIQUAD:
            if (s.param_count < 5 || s.param_count % 5 != 0) return false;
            for (uint32_t i = 0; i < s.param_count; i += 5) {
                out.sections.push_back({p[i], p[i + 1], p[i + 2], p[i + 3], p[i + 4]});
            }
            return true;
        case N60_HEADROOM_STAGE_LINKWITZ: {
            // Designed in double exactly as the graph's XOVER stage does: float biquad coefficients lose the low-frequency
            // response of a 20 Hz transform at 352.8 and 384 kHz.
            if (s.param_count != 4) return false;
            n60_xover_cascade c;
            if (n60_xover_linkwitz(p[0], p[1], p[2], p[3], rate, &c) != N60_XOVER_OK || c.count != 1) return false;
            out.sections.push_back({c.sections[0].b0, c.sections[0].b1, c.sections[0].b2, c.sections[0].a1, c.sections[0].a2});
            return true;
        }
        case N60_HEADROOM_STAGE_FIR:
            if (s.tap_count < 1 || s.tap_count > N60_HEADROOM_MAX_FIR_TAPS || s.taps == nullptr) return false;
            if (!allFinite(s.taps, s.tap_count)) return false;
            out.kind = Prepared::Fir;
            out.taps = s.taps;
            out.tapCount = s.tap_count;
            return true;
        case N60_HEADROOM_STAGE_DYN_EQ: {
            if (s.param_count < 16 || (s.param_count - 1) % 15 != 0) return false;
            for (uint32_t i = 1; i + 15 <= s.param_count; i += 15) {
                const float *b = p + i;
                const double shape = b[0], hz = b[1], q = b[2];
                // Largest level the band can reach: static gain plus the full boost when it may boost.
                const double boost = (b[9] == 1.0f || b[9] == 2.0f) ? b[12] : 0.0;
                const double g = std::clamp(static_cast<double>(b[3]) + boost, -42.0, 18.0);
                if (shape == 5.0) {
                    if (!addPeq(out.sections, 1, rate, hz, -0.5 * g, q) || !addPeq(out.sections, 2, rate, hz, 0.5 * g, q)) return false;
                    continue;
                }
                static const uint32_t kType[5] = {0, 1, 2, 5, 7};
                if (shape < 0.0 || shape > 4.0) return false;
                if (!addPeq(out.sections, kType[static_cast<int>(shape)], rate, hz, g, q)) return false;
            }
            return true;
        }
        case N60_HEADROOM_STAGE_COMPRESSOR:
            if (s.param_count < 6) return false;
            out.kind = Prepared::Gain;  // below threshold the gain is the make-up
            out.gain = std::pow(10.0, p[5] / 20.0);
            return true;
        default:
            return false;
    }
}

Cx firAt(const float *h, uint32_t n, double w) {
    // Direct DFT by rotation, re-seeded every block so the recurrence error stays far below 1e-9.
    constexpr uint32_t kBlock = 256;
    const Cx step = std::polar(1.0, -w);
    Cx sum = 0.0;
    for (uint32_t base = 0; base < n; base += kBlock) {
        Cx rot = std::polar(1.0, -w * static_cast<double>(base));
        const uint32_t end = std::min(n, base + kBlock);
        for (uint32_t i = base; i < end; ++i) {
            sum += static_cast<double>(h[i]) * rot;
            rot *= step;
        }
    }
    return sum;
}

Cx chainAt(const std::vector<Prepared> &chain, double w) {
    Cx r = 1.0;
    for (const Prepared &s : chain) {
        switch (s.kind) {
            case Prepared::Gain: r *= s.gain; break;
            case Prepared::Delay: r *= std::polar(1.0, -w * s.delayFrames); break;
            case Prepared::Fir: r *= firAt(s.taps, s.tapCount, w); break;
            case Prepared::Cascade:
                for (const Biquad &q : s.sections) r *= biquadAt(q, w);
                break;
        }
    }
    return r;
}

bool prepareChain(const n60_headroom_stage *stages, uint32_t count, double rate, std::vector<Prepared> &out) {
    if (count > 64 || (count != 0 && stages == nullptr)) return false;
    out.resize(count);
    for (uint32_t i = 0; i < count; ++i) {
        if (!prepare(stages[i], rate, out[i])) return false;
    }
    return true;
}

}  // namespace

extern "C" {

uint32_t n60_headroom_abi_version(void) { return N60_HEADROOM_ABI_VERSION; }

int n60_headroom_evaluate(const n60_headroom_output *o, n60_headroom_result *r) {
    if (o == nullptr || r == nullptr || o->struct_size != sizeof(n60_headroom_output) ||
        r->struct_size != sizeof(n60_headroom_result) || !std::isfinite(o->sample_rate) || o->sample_rate < 8000.0 ||
        o->sample_rate > 768000.0 || o->path_count < 1 || o->path_count > 64 || o->paths == nullptr ||
        !std::isfinite(o->ceiling_db)) {
        return N60_HEADROOM_ERR_ARGUMENT;
    }
    std::vector<std::vector<Prepared>> paths(o->path_count);
    std::vector<Prepared> tail;
    for (uint32_t i = 0; i < o->path_count; ++i) {
        const n60_headroom_path &p = o->paths[i];
        if (p.combine > N60_HEADROOM_COMBINE_POWER) return N60_HEADROOM_ERR_ARGUMENT;
        if (!prepareChain(p.stages, p.stage_count, o->sample_rate, paths[i])) return N60_HEADROOM_ERR_STAGE;
    }
    if (!prepareChain(o->tail_stages, o->tail_stage_count, o->sample_rate, tail)) return N60_HEADROOM_ERR_STAGE;

    const double maxHz = N60_HEADROOM_MAX_FRACTION * o->sample_rate;
    double bestDb = -1.0e300, bestHz = N60_HEADROOM_MIN_HZ;
    uint32_t points = 0;
    for (uint32_t k = 0;; ++k) {
        const double hz = N60_HEADROOM_MIN_HZ * std::exp2(static_cast<double>(k) / N60_HEADROOM_GRID_STEPS_PER_OCTAVE);
        if (hz > maxHz) break;
        const double w = 2.0 * kPi * hz / o->sample_rate;
        Cx coherent = 0.0;
        double power = 0.0;
        for (uint32_t i = 0; i < o->path_count; ++i) {
            const Cx h = chainAt(paths[i], w);
            if (o->strict != 0 || o->paths[i].combine == N60_HEADROOM_COMBINE_COHERENT) {
                coherent += h;
            } else {
                power += std::norm(h);
            }
        }
        const double mag = std::sqrt(std::norm(coherent) + power) * std::abs(chainAt(tail, w));
        const double db = 20.0 * std::log10(std::max(mag, 1.0e-30));
        if (db > bestDb) {
            bestDb = db;
            bestHz = hz;
        }
        ++points;
    }
    r->peak_gain_db = bestDb;
    r->peak_hz = bestHz;
    r->true_peak_margin_db = N60_HEADROOM_TRUE_PEAK_MARGIN_DB;
    r->required_trim_db = std::max(0.0, bestDb + N60_HEADROOM_TRUE_PEAK_MARGIN_DB - o->ceiling_db);
    r->grid_points = points;
    return N60_HEADROOM_OK;
}

int n60_headroom_mimo_term(double sample_rate, const float *params, uint32_t param_count, uint32_t source,
                           double *peak_gain_db, double *peak_hz) {
    if (params == nullptr || peak_gain_db == nullptr || !std::isfinite(sample_rate) || sample_rate < 44100.0 ||
        sample_rate > 384000.5 || param_count < 8) {
        return N60_HEADROOM_ERR_ARGUMENT;
    }
    const double dD = params[0], dT = params[1], dS = params[2], dTau = params[3];
    if (!(dD >= 1.0 && dD <= 128.0) || !(dT >= 1.0 && dT <= 4096.0) || !(dS >= 1.0 && dS <= 8.0) || !(dTau >= 0.0) || !std::isfinite(dTau) ||
        dD != std::floor(dD) || dT != std::floor(dT) || dS != std::floor(dS)) {
        return N60_HEADROOM_ERR_ARGUMENT;
    }
    const uint32_t D = static_cast<uint32_t>(dD), T = static_cast<uint32_t>(dT), S = static_cast<uint32_t>(dS);
    if (source >= S || param_count != 8u + S + S * S * T) return N60_HEADROOM_ERR_ARGUMENT;
    const double fsLow = sample_rate / D, tauSeconds = dTau / sample_rate;
    const float *taps = params + 8 + S;
    const double maxHz = std::min(0.4 * fsLow, 1000.0);
    double best = 1.0, bestHz = 0.0;  // the direct path alone is 0 dB
    for (double hz = 5.0; hz <= maxHz; hz += 0.25) {
        const double wLow = 2.0 * kPi * hz / fsLow;
        double gain = 0.0;
        for (uint32_t t = 0; t < S; ++t) {
            Cx e = firAt(taps + (static_cast<size_t>(source) * S + t) * T, T, wLow);
            if (t == source) e += std::polar(1.0, -2.0 * kPi * hz * tauSeconds);
            gain += std::abs(e);
        }
        if (gain > best) {
            best = gain;
            bestHz = hz;
        }
    }
    *peak_gain_db = 20.0 * std::log10(best);
    if (peak_hz != nullptr) *peak_hz = bestHz;
    return N60_HEADROOM_OK;
}

double n60_headroom_mimo_budget_db(double ceiling_db, double trim_allowance_db, double chain_peak_db) {
    return ceiling_db - N60_HEADROOM_TRUE_PEAK_MARGIN_DB - chain_peak_db + trim_allowance_db;
}

}  // extern "C"
