// Room-model acoustic locate (E29 S5, n60/roommodel.h section "locate"). Offline design maths: allocates, never on an
// audio callback. Deterministic: fixed iteration count and summation order, no threads, no randomness.
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "../measure/offline_fft.hpp"
#include "n60/roommodel.h"

namespace {

using n60::fft::offline::Cplx;
constexpr double kPi = 3.14159265358979323846264338327950288;

// Arrival time in seconds of the IR's first strong high-frequency pulse (the tweeter), or a negative value when none.
// The IR is high-passed (zero phase, raised-cosine edge from 0.8 f to f), so its Hilbert envelope peaks at the arrival;
// the arrival is the first local envelope maximum above half the global maximum, refined by a parabola through it.
double arrivalSeconds(const float *ir, uint32_t frames, double rate, double highPassHz) {
    size_t n = 64;
    while (n < frames + 8u) n <<= 1;
    if (n > N60_ROOMMODEL_MAX_FFT_SIZE) return -1.0;
    std::vector<double> x(n, 0.0);
    for (uint32_t i = 0; i < frames; ++i) x[i] = static_cast<double>(ir[i]);
    std::vector<Cplx> spec;
    if (!n60::fft::offline::realForward(x.data(), n, spec)) return -1.0;
    const double binHz = rate / static_cast<double>(n);
    std::vector<Cplx> hil(spec.size());
    for (size_t k = 0; k < spec.size(); ++k) {
        const double f = static_cast<double>(k) * binHz;
        double g = 1.0;
        if (f < 0.8 * highPassHz) g = 0.0;
        else if (f < highPassHz) g = 0.5 * (1.0 - std::cos(kPi * (f - 0.8 * highPassHz) / (0.2 * highPassHz)));
        const Cplx s{spec[k].re * g, spec[k].im * g};
        spec[k] = s;
        hil[k] = Cplx{s.im, -s.re};  // multiply by -j: the Hilbert transform
    }
    hil.front() = Cplx{0, 0};
    hil.back() = Cplx{0, 0};
    std::vector<double> a, b;
    if (!n60::fft::offline::realInverse(spec, n, a) || !n60::fft::offline::realInverse(hil, n, b)) return -1.0;
    std::vector<double> env(n);
    double peak = 0;
    for (size_t i = 0; i < n; ++i) {
        env[i] = std::sqrt(a[i] * a[i] + b[i] * b[i]);
        peak = std::max(peak, env[i]);
    }
    if (!(peak > 0)) return -1.0;
    const size_t end = std::min<size_t>(frames, n - 1);
    for (size_t i = 1; i < end; ++i) {
        if (env[i] >= 0.5 * peak && env[i] >= env[i - 1] && env[i] > env[i + 1]) {
            const double y0 = env[i - 1], y1 = env[i], y2 = env[i + 1];
            const double den = y0 - 2.0 * y1 + y2;
            const double off = den < 0 ? std::clamp(0.5 * (y0 - y2) / den, -0.5, 0.5) : 0.0;
            return (static_cast<double>(i) + off) / rate;
        }
    }
    return -1.0;
}

double dist3(const double *a, const double *b) {
    const double dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

bool finite3(const double *v) { return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]); }

}  // namespace

extern "C" int32_t n60_roommodel_locate(const n60_roommodel_locate_query *query,
                                        const n60_roommodel_locate_speaker *speakers,
                                        n60_roommodel_locate_result *result) {
    if (!query || !speakers || !result) return N60_ROOMMODEL_ERR_ARGUMENT;
    if (query->structSize != sizeof(n60_roommodel_locate_query) || result->structSize != sizeof(n60_roommodel_locate_result))
        return N60_ROOMMODEL_ERR_ARGUMENT;
    if (!(query->sampleRate >= 8000.0 && query->sampleRate <= 768000.0) || !std::isfinite(query->seatHeightM) ||
        query->seatHeightM < 0 || query->speakerCount == 0 || query->speakerCount > N60_ROOMMODEL_LOCATE_MAX_SPEAKERS ||
        !(query->soundSpeed >= 0) || !(query->highPassHz >= 0))
        return N60_ROOMMODEL_ERR_ARGUMENT;
    const double c = query->soundSpeed > 0 ? query->soundSpeed : N60_ROOMMODEL_DEFAULT_SOUND_SPEED;
    const double rate = query->sampleRate;
    const double hp = query->highPassHz > 0 ? query->highPassHz : N60_ROOMMODEL_LOCATE_HIGHPASS_HZ;
    if (hp >= 0.45 * rate) return N60_ROOMMODEL_ERR_ARGUMENT;
    for (uint32_t i = 0; i < query->speakerCount; ++i) {
        const n60_roommodel_locate_speaker &s = speakers[i];
        if (!finite3(s.position) || !s.ir || s.irFrames < 16 || !std::isfinite(s.latencySeconds)) return N60_ROOMMODEL_ERR_ARGUMENT;
    }

    const uint32_t count = query->speakerCount;
    *result = n60_roommodel_locate_result{};
    result->structSize = sizeof(n60_roommodel_locate_result);
    result->reason = N60_ROOMMODEL_REASON_NONE;
    for (uint32_t i = 0; i < count; ++i) result->speakerStatus[i] = N60_ROOMMODEL_LOCATE_SPEAKER_USED;

    // Subs are excluded (low-pass group delay); every other speaker needs loopback or reference timing.
    for (uint32_t i = 0; i < count; ++i) {
        if (speakers[i].isSub) result->speakerStatus[i] = N60_ROOMMODEL_LOCATE_SPEAKER_SUB;
        else if (!speakers[i].timingTrusted) result->speakerStatus[i] = N60_ROOMMODEL_LOCATE_SPEAKER_NO_TIMING;
    }
    auto refuse = [&](int32_t reason) {
        result->reason = reason;
        return static_cast<int32_t>(N60_ROOMMODEL_NOT_MEASURED);
    };
    uint32_t candidates = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (result->speakerStatus[i] == N60_ROOMMODEL_LOCATE_SPEAKER_NO_TIMING) return refuse(N60_ROOMMODEL_REASON_NO_LOOPBACK_TIMING);
        if (result->speakerStatus[i] == N60_ROOMMODEL_LOCATE_SPEAKER_USED) ++candidates;
    }
    if (candidates < 2) return refuse(N60_ROOMMODEL_REASON_TOO_FEW_SPEAKERS);

    // Time of flight to distance, then the horizontal radius at the assumed seat height.
    std::vector<uint32_t> used;
    std::vector<double> flight, radius;
    for (uint32_t i = 0; i < count; ++i) {
        if (result->speakerStatus[i] != N60_ROOMMODEL_LOCATE_SPEAKER_USED) continue;
        const double t = arrivalSeconds(speakers[i].ir, speakers[i].irFrames, rate, hp);
        const double d = (t - speakers[i].latencySeconds) * c;
        if (t < 0 || !(d > 0)) {
            result->speakerStatus[i] = N60_ROOMMODEL_LOCATE_SPEAKER_NO_ARRIVAL;
            continue;
        }
        const double dz = speakers[i].position[2] - query->seatHeightM;
        result->distanceM[i] = d;
        used.push_back(i);
        flight.push_back(d);
        radius.push_back(std::sqrt(std::max(d * d - dz * dz, 0.0)));
    }
    if (used.size() < 2) return refuse(N60_ROOMMODEL_REASON_NO_ARRIVAL);

    // Start: the two speakers furthest apart; of the two circle intersections take the one into the room (larger y).
    size_t ia = 0, ib = 1;
    double best = -1;
    for (size_t a = 0; a < used.size(); ++a)
        for (size_t b = a + 1; b < used.size(); ++b) {
            const double dx = speakers[used[a]].position[0] - speakers[used[b]].position[0];
            const double dy = speakers[used[a]].position[1] - speakers[used[b]].position[1];
            const double dd = std::sqrt(dx * dx + dy * dy);
            if (dd > best) { best = dd; ia = a; ib = b; }
        }
    if (!(best > 1e-3)) return refuse(N60_ROOMMODEL_REASON_DEGENERATE);
    const double ax = speakers[used[ia]].position[0], ay = speakers[used[ia]].position[1];
    const double bx = speakers[used[ib]].position[0], by = speakers[used[ib]].position[1];
    const double D = best;
    // Along the baseline from A: u = (r_a^2 - r_b^2 + D^2) / (2 D); offset h^2 = r_a^2 - u^2 (0 when the circles miss).
    const double u = (radius[ia] * radius[ia] - radius[ib] * radius[ib] + D * D) / (2.0 * D);
    const double h = std::sqrt(std::max(radius[ia] * radius[ia] - u * u, 0.0));
    const double ex = (bx - ax) / D, ey = (by - ay) / D;
    const double mx = ax + ex * u, my = ay + ey * u;
    const double c1x = mx - ey * h, c1y = my + ex * h;
    const double c2x = mx + ey * h, c2y = my - ex * h;
    double px = c1y >= c2y ? c1x : c2x;
    double py = c1y >= c2y ? c1y : c2y;
    result->mirrorResolved = 1;

    // Gauss-Newton on the 3D distances with the height fixed; at most 40 steps with a tiny damping term.
    const double height = query->seatHeightM;
    for (int iter = 0; iter < 40; ++iter) {
        double jtj00 = 0, jtj01 = 0, jtj11 = 0, jtr0 = 0, jtr1 = 0;
        for (size_t k = 0; k < used.size(); ++k) {
            const double *sp = speakers[used[k]].position;
            const double dx = px - sp[0], dy = py - sp[1], dz = height - sp[2];
            const double r = std::max(std::sqrt(dx * dx + dy * dy + dz * dz), 1e-6);
            const double j0 = dx / r, j1 = dy / r, res = r - flight[k];
            jtj00 += j0 * j0; jtj01 += j0 * j1; jtj11 += j1 * j1;
            jtr0 += j0 * res; jtr1 += j1 * res;
        }
        const double lam = 1e-9;
        jtj00 += lam; jtj11 += lam;
        const double det = jtj00 * jtj11 - jtj01 * jtj01;
        if (!(std::fabs(det) > 1e-12)) break;
        const double sx = -(jtj11 * jtr0 - jtj01 * jtr1) / det;
        const double sy = -(-jtj01 * jtr0 + jtj00 * jtr1) / det;
        px += sx; py += sy;
        if (std::fabs(sx) + std::fabs(sy) < 1e-9) break;
    }
    if (!std::isfinite(px) || !std::isfinite(py)) return refuse(N60_ROOMMODEL_REASON_DEGENERATE);

    const double at[3] = {px, py, height};
    double ss = 0;
    for (size_t k = 0; k < used.size(); ++k) {
        const double fit = dist3(at, speakers[used[k]].position);
        result->fitDistanceM[used[k]] = fit;
        ss += (fit - flight[k]) * (fit - flight[k]);
    }
    result->position[0] = px;
    result->position[1] = py;
    result->position[2] = height;
    result->speakersUsed = static_cast<uint32_t>(used.size());
    result->residualRmsM = std::sqrt(ss / static_cast<double>(used.size()));
    const double grid = c / rate;  // one sample of flight
    result->uncertaintyM = std::sqrt(result->residualRmsM * result->residualRmsM + grid * grid);
    return N60_ROOMMODEL_OK;
}
