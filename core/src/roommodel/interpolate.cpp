// Room-model interpolation (E29 S3, n60/roommodel.h). Offline design maths: allocates, never on an audio callback.
// Derivation and the band/blend definitions are in the header; summation order is fixed (neighbours in rank order,
// bins ascending) so results are bit-identical across runs.
#include "n60/roommodel.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "../measure/offline_fft.hpp"

namespace {

using n60::fft::offline::Cplx;
constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr int kFirstBandK = -15;
constexpr double kMaxBandHz = 20000.0;
constexpr size_t kSearchNodes = 16;  // nearest in-trust nodes searched for the enclosing triangle

double dist3(const double *a, const double *b) {
    const double dx = a[0] - b[0];
    const double dy = a[1] - b[1];
    const double dz = a[2] - b[2];
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

bool finite3(const double *v) { return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]); }

double bandCentre(uint32_t i) { return 1000.0 * std::exp2(static_cast<double>(kFirstBandK + static_cast<int>(i)) / 3.0); }

double toDb(double power) { return 10.0 * std::log10(std::max(power, 1e-300)); }

struct Used {
    uint32_t index;
    double dist;
};

// Mean of values over bins [lo, hi] (inclusive); a band narrower than one bin takes the nearest bin.
double meanPower(const std::vector<double> &power, double binHz, double loHz, double hiHz, double centreHz) {
    const int64_t last = static_cast<int64_t>(power.size()) - 1;
    int64_t a = static_cast<int64_t>(std::ceil(loHz / binHz));
    int64_t b = static_cast<int64_t>(std::floor(hiHz / binHz));
    a = std::max<int64_t>(a, 1);
    b = std::min<int64_t>(b, last);
    if (b < a) {
        const int64_t k = std::min<int64_t>(std::max<int64_t>(static_cast<int64_t>(std::llround(centreHz / binHz)), 1), last);
        return power[static_cast<size_t>(k)];
    }
    double s = 0;
    for (int64_t k = a; k <= b; ++k) s += power[static_cast<size_t>(k)];
    return s / static_cast<double>(b - a + 1);
}

// Weights for the enclosing triangle (E29 S3 follow-up, gap G6). Among every triple of candidates whose triangle holds the
// query (coplanar within 2 cm, barycentric coordinates >= 0) the one with the smallest longest edge wins, so a point on a
// shared edge never picks a wedge spanning two cells; a cell's two diagonals tie, and the tie goes to the lexicographically
// position rank triple (x, then y, then z: one fixed diagonal per cell, so the choice does not depend on where the query is). On success cand is
// replaced by the three nodes (nearest first) and w by their barycentric weights; false when no triangle holds the query
// or the nodes are collinear.
bool pickTriangle(const n60_roommodel_neighbour *nb, const double *qp, std::vector<Used> &cand, std::vector<double> &w) {
    const size_t n = cand.size();
    if (n < 3) return false;
    // Nodes ranked by position (x, then y, then z): in a cell A < B < C < D this keeps the one diagonal B-C.
    std::vector<size_t> order(n), rank(n);
    for (size_t i = 0; i < n; ++i) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        const double *pa = nb[cand[a].index].position, *pb = nb[cand[b].index].position;
        for (int d = 0; d < 3; ++d)
            if (pa[d] != pb[d]) return pa[d] < pb[d];
        return false;
    });
    for (size_t r2 = 0; r2 < n; ++r2) rank[order[r2]] = r2;
    auto dot = [](const double *a, const double *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; };
    bool found = false;
    size_t best[3] = {0, 0, 0};
    double bw[3] = {0, 0, 0};
    double bestEdge = 0;
    size_t bestKey[3] = {0, 0, 0};
    for (size_t i = 0; i < n; ++i)
        for (size_t j = i + 1; j < n; ++j)
            for (size_t l = j + 1; l < n; ++l) {
                const double *A = nb[cand[i].index].position, *B = nb[cand[j].index].position,
                             *C = nb[cand[l].index].position;
                double e0[3], e1[3], p[3];
                for (int d = 0; d < 3; ++d) {
                    e0[d] = B[d] - A[d];
                    e1[d] = C[d] - A[d];
                    p[d] = qp[d] - A[d];
                }
                const double d00 = dot(e0, e0), d01 = dot(e0, e1), d11 = dot(e1, e1), d20 = dot(p, e0), d21 = dot(p, e1);
                const double den = d00 * d11 - d01 * d01;
                if (!(d00 > 0) || !(d11 > 0) || !(den > 1e-9 * d00 * d11)) continue;  // collinear
                const double v = (d11 * d20 - d01 * d21) / den, u2 = (d00 * d21 - d01 * d20) / den, u0 = 1.0 - v - u2;
                if (u0 < -1e-9 || v < -1e-9 || u2 < -1e-9) continue;
                double res[3];
                for (int d = 0; d < 3; ++d) res[d] = p[d] - v * e0[d] - u2 * e1[d];
                if (std::sqrt(dot(res, res)) > 0.02) continue;  // the query is not in this triangle's plane
                const double edge = std::sqrt(std::max(d00, std::max(d11, d00 + d11 - 2.0 * d01)));
                size_t key[3] = {rank[i], rank[j], rank[l]};
                std::sort(key, key + 3);
                if (found) {
                    if (edge > bestEdge * (1.0 + 1e-6)) continue;
                    if (edge >= bestEdge * (1.0 - 1e-6)) {  // equal longest edge: fixed-diagonal rule
                        const bool better = key[2] != bestKey[2] ? key[2] < bestKey[2]
                                            : key[1] != bestKey[1] ? key[1] > bestKey[1]
                                                                   : key[0] > bestKey[0];
                        if (!better) continue;
                    }
                }
                for (int d = 0; d < 3; ++d) bestKey[d] = key[d];
                found = true;
                bestEdge = edge;
                best[0] = i; best[1] = j; best[2] = l;
                bw[0] = u0; bw[1] = v; bw[2] = u2;
            }
    if (!found) return false;
    size_t idx[3] = {0, 1, 2};
    std::stable_sort(idx, idx + 3, [&](size_t a, size_t b) { return cand[best[a]].dist < cand[best[b]].dist; });
    std::vector<Used> out;
    w.assign(3, 0.0);
    double sum = 0;
    for (int t = 0; t < 3; ++t) {
        out.push_back(cand[best[idx[t]]]);
        w[static_cast<size_t>(t)] = std::max(0.0, bw[idx[t]]);
        sum += w[static_cast<size_t>(t)];
    }
    for (double &x : w) x /= sum;
    cand = out;
    return true;
}

void markRefused(n60_roommodel_result *r, int32_t reason) {
    r->reason = reason;
    for (uint32_t b = 0; b < N60_ROOMMODEL_BAND_COUNT; ++b) {
        r->bandStatus[b] = N60_ROOMMODEL_BAND_REFUSED;
        r->levelDb[b] = 0;
        r->spreadDb[b] = 0;
        r->confidence[b] = 0;
    }
}

int32_t run(const n60_roommodel_query *q, const n60_roommodel_neighbour *nb, n60_roommodel_result *r, double *lowRe,
            double *lowIm) {
    const uint32_t n = q->fftSize;
    const size_t bins = static_cast<size_t>(n / 2 + 1);
    if (lowRe != nullptr) std::fill(lowRe, lowRe + bins, 0.0);
    if (lowIm != nullptr) std::fill(lowIm, lowIm + bins, 0.0);

    const double c = q->soundSpeed > 0 ? q->soundSpeed : N60_ROOMMODEL_DEFAULT_SOUND_SPEED;
    double trust = q->trustRadiusM > 0 ? q->trustRadiusM : N60_ROOMMODEL_DEFAULT_TRUST_M;
    if (!(q->trustRadiusM > 0)) {
        // Spacing-aware default: the node nearest the query and its nearest other node give the grid spacing, and the radius
        // is at least the cell diagonal (1.42 x spacing) so a whole cell is always in range.
        size_t near = 0;
        double nd = 1e300;
        for (uint32_t i = 0; i < q->neighbourCount; ++i) {
            const double d = dist3(nb[i].position, q->query);
            if (d < nd) { nd = d; near = i; }
        }
        double gridSpacing = 1e300;
        for (uint32_t i = 0; i < q->neighbourCount; ++i)
            if (i != near) gridSpacing = std::min(gridSpacing, dist3(nb[i].position, nb[near].position));
        if (gridSpacing < 1e300) trust = std::max(trust, N60_ROOMMODEL_CELL_DIAGONAL * gridSpacing);
    }
    const double limit = q->spreadLimitDb > 0 ? q->spreadLimitDb : N60_ROOMMODEL_DEFAULT_SPREAD_DB;
    const double binHz = q->sampleRate / static_cast<double>(n);
    r->binHz = binHz;
    r->delaySeconds = dist3(q->source, q->query) / c;
    for (uint32_t b = 0; b < N60_ROOMMODEL_BAND_COUNT; ++b) r->bandCentreHz[b] = bandCentre(b);

    // Rank candidates inside the trust radius: nearest first, ties by input order.
    std::vector<Used> cand;
    cand.reserve(q->neighbourCount);
    for (uint32_t i = 0; i < q->neighbourCount; ++i) {
        const double d = dist3(nb[i].position, q->query);
        if (d <= trust) cand.push_back({i, d});
    }
    std::stable_sort(cand.begin(), cand.end(), [](const Used &a, const Used &b) { return a.dist < b.dist; });
    if (q->neighbourCount == 0) {
        markRefused(r, N60_ROOMMODEL_REASON_NO_NEIGHBOURS);
        return N60_ROOMMODEL_NOT_MEASURED;
    }
    if (cand.empty()) {
        double nearest = 1e300;
        for (uint32_t i = 0; i < q->neighbourCount; ++i) nearest = std::min(nearest, dist3(nb[i].position, q->query));
        r->nearestDistanceM = nearest;
        markRefused(r, N60_ROOMMODEL_REASON_OUTSIDE_TRUST);
        return N60_ROOMMODEL_NOT_MEASURED;
    }
    r->nearestDistanceM = cand[0].dist;
    if (cand.size() > kSearchNodes) cand.resize(kSearchNodes);
    // Barycentric weights on the enclosing triangle; otherwise the inverse-distance blend of the nearest three.
    std::vector<double> w;
    if (!pickTriangle(nb, q->query, cand, w)) {
        if (cand.size() > N60_ROOMMODEL_MAX_NEIGHBOURS) cand.resize(N60_ROOMMODEL_MAX_NEIGHBOURS);
        w.assign(cand.size(), 0.0);
        double wsum = 0;
        for (size_t i = 0; i < cand.size(); ++i) {
            w[i] = 1.0 / std::max(cand[i].dist, 1e-3);
            wsum += w[i];
        }
        for (double &x : w) x /= wsum;
    }
    size_t k = cand.size();

    // Nearest-neighbour spacing sets the crossover.
    double spacing = 2.0 * std::max(cand[0].dist, 0.01);
    if (k >= 2) {
        spacing = 1e300;
        for (size_t a = 0; a < k; ++a)
            for (size_t b = a + 1; b < k; ++b)
                spacing = std::min(spacing, dist3(nb[cand[a].index].position, nb[cand[b].index].position));
        spacing = std::max(spacing, 0.01);
    }
    r->spacingM = spacing;
    r->crossoverHz = n60_roommodel_crossover_hz(spacing, c);

    // A zero-weight node (the third corner of a point on a cell edge) takes no part: it neither blends nor counts towards
    // the band spread. The spacing above still came from the whole triangle, so f_c does not jump at the edge.
    {
        size_t m = 0;
        for (size_t i = 0; i < k; ++i)
            if (w[i] > 1e-12) { cand[m] = cand[i]; w[m] = w[i]; ++m; }
        cand.resize(m);
        w.resize(m);
        double s2 = 0;
        for (double x : w) s2 += x;
        for (double &x : w) x /= s2;
        k = m;
    }
    r->neighboursUsed = static_cast<uint32_t>(k);

    bool phase = true;
    for (size_t i = 0; i < k; ++i)
        if (nb[cand[i].index].phaseTrusted == 0) phase = false;
    r->complexValid = phase ? 1u : 0u;

    // Spectra and per-neighbour power.
    std::vector<std::vector<Cplx>> spec(k);
    std::vector<std::vector<double>> power(k, std::vector<double>(bins));
    std::vector<double> buf(n);
    for (size_t i = 0; i < k; ++i) {
        const n60_roommodel_neighbour &nn = nb[cand[i].index];
        std::fill(buf.begin(), buf.end(), 0.0);
        for (uint32_t j = 0; j < nn.irFrames; ++j) buf[j] = static_cast<double>(nn.ir[j]);
        if (!n60::fft::offline::realForward(buf.data(), n, spec[i])) return N60_ROOMMODEL_ERR_ARGUMENT;
        for (size_t b = 0; b < bins; ++b) power[i][b] = spec[i][b].re * spec[i][b].re + spec[i][b].im * spec[i][b].im;
    }

    // Delay-compensated complex blend below f_c.
    std::vector<double> blendRe(bins, 0.0), blendIm(bins, 0.0), blendPow(bins, 0.0);
    std::vector<double> tau(k);
    for (size_t i = 0; i < k; ++i) tau[i] = dist3(q->source, nb[cand[i].index].position) / c;
    const double tauQ = r->delaySeconds;
    const size_t lowBins = std::min(bins, static_cast<size_t>(std::floor(r->crossoverHz / binHz)) + 1);
    if (phase) {
        for (size_t b = 1; b < lowBins; ++b) {
            const double wr = 2.0 * kPi * binHz * static_cast<double>(b);
            double re = 0, im = 0;
            for (size_t i = 0; i < k; ++i) {
                const double th = wr * tau[i];  // advance by +w tau_i
                const double cr = std::cos(th), ci = std::sin(th);
                re += w[i] * (spec[i][b].re * cr - spec[i][b].im * ci);
                im += w[i] * (spec[i][b].re * ci + spec[i][b].im * cr);
            }
            const double tq = -wr * tauQ;  // restore the query's delay
            const double qr = std::cos(tq), qi = std::sin(tq);
            blendRe[b] = re * qr - im * qi;
            blendIm[b] = re * qi + im * qr;
            blendPow[b] = blendRe[b] * blendRe[b] + blendIm[b] * blendIm[b];
        }
    }

    // Bands.
    const double ceilingHz = std::min(0.5 * q->sampleRate, kMaxBandHz);
    const double edge = std::exp2(1.0 / 6.0);
    std::vector<double> levels(k);
    for (uint32_t bnd = 0; bnd < N60_ROOMMODEL_BAND_COUNT; ++bnd) {
        const double fc = r->bandCentreHz[bnd];
        const double lo = fc / edge, hi = fc * edge;
        if (hi > ceilingHz) {
            r->bandStatus[bnd] = N60_ROOMMODEL_BAND_UNAVAILABLE;
            continue;
        }
        double blended = 0;
        double minL = 1e300, maxL = -1e300;
        for (size_t i = 0; i < k; ++i) {
            const double p = meanPower(power[i], binHz, lo, hi, fc);
            levels[i] = toDb(p);
            minL = std::min(minL, levels[i]);
            maxL = std::max(maxL, levels[i]);
            blended += w[i] * p;
        }
        if (phase && hi <= r->crossoverHz) blended = meanPower(blendPow, binHz, lo, hi, fc);
        const double spread = k >= 2 ? maxL - minL : 0.5 * limit;
        double scatter = 0;
        for (size_t i = 0; i < k; ++i) {
            const double s = nb[cand[i].index].repeatScatterDb;
            scatter += s * s;
        }
        scatter = std::sqrt(scatter / static_cast<double>(k));
        r->levelDb[bnd] = toDb(blended);
        r->spreadDb[bnd] = spread;
        if (spread > limit) {
            r->bandStatus[bnd] = N60_ROOMMODEL_BAND_SPREAD;
            r->confidence[bnd] = 0;
            // The complex bins stay: below f_c the delay-compensated blend is still the best estimate of a refused band
            // (on the 44.1 kHz grid a three-bin mode band reads 10 dB of node spread yet blends to -17 dB error), and the
            // SPREAD status with zero confidence tells the consumer not to trust it.
        } else {
            r->bandStatus[bnd] = N60_ROOMMODEL_BAND_OK;
            r->confidence[bnd] = std::max(0.0, 1.0 - std::sqrt(spread * spread + scatter * scatter) / limit);
        }
    }
    if (phase) {
        for (size_t b = 1; b < lowBins; ++b) {
            if (lowRe != nullptr) lowRe[b] = blendRe[b];
            if (lowIm != nullptr) lowIm[b] = blendIm[b];
        }
    }
    return N60_ROOMMODEL_OK;
}

}  // namespace

extern "C" {

uint32_t n60_roommodel_abi_version(void) { return N60_ROOMMODEL_ABI_VERSION; }

double n60_roommodel_crossover_hz(double spacingM, double soundSpeed) {
    if (!(spacingM > 0) || !(soundSpeed > 0) || !std::isfinite(spacingM) || !std::isfinite(soundSpeed)) return 0;
    return soundSpeed / (4.0 * spacingM);
}

double n60_roommodel_band_centre_hz(uint32_t index) {
    return index < N60_ROOMMODEL_BAND_COUNT ? bandCentre(index) : 0.0;
}

int32_t n60_roommodel_interpolate(const n60_roommodel_query *q, const n60_roommodel_neighbour *nb,
                                  n60_roommodel_result *r, double *lowRe, double *lowIm) {
    if (q == nullptr || r == nullptr || q->structSize < sizeof(n60_roommodel_query) ||
        r->structSize < sizeof(n60_roommodel_result)) {
        return N60_ROOMMODEL_ERR_ARGUMENT;
    }
    if (!std::isfinite(q->sampleRate) || q->sampleRate < 8000.0 || q->sampleRate > 768000.0) return N60_ROOMMODEL_ERR_ARGUMENT;
    if (!n60::fft::offline::validSize(q->fftSize) || q->fftSize < 64 || q->fftSize > N60_ROOMMODEL_MAX_FFT_SIZE) {
        return N60_ROOMMODEL_ERR_ARGUMENT;
    }
    if (!finite3(q->source) || !finite3(q->query)) return N60_ROOMMODEL_ERR_ARGUMENT;
    if (!std::isfinite(q->soundSpeed) || !std::isfinite(q->trustRadiusM) || !std::isfinite(q->spreadLimitDb) ||
        q->soundSpeed < 0 || q->trustRadiusM < 0 || q->spreadLimitDb < 0) {
        return N60_ROOMMODEL_ERR_ARGUMENT;
    }
    if (q->neighbourCount > N60_ROOMMODEL_MAX_NEIGHBOUR_INPUTS || (q->neighbourCount > 0 && nb == nullptr)) {
        return N60_ROOMMODEL_ERR_ARGUMENT;
    }
    for (uint32_t i = 0; i < q->neighbourCount; ++i) {
        if (nb[i].ir == nullptr || nb[i].irFrames == 0 || nb[i].irFrames > q->fftSize || !finite3(nb[i].position) ||
            !std::isfinite(nb[i].repeatScatterDb) || nb[i].repeatScatterDb < 0) {
            return N60_ROOMMODEL_ERR_ARGUMENT;
        }
        for (uint32_t j = 0; j < nb[i].irFrames; ++j)
            if (!std::isfinite(nb[i].ir[j])) return N60_ROOMMODEL_ERR_ARGUMENT;
    }
    *r = n60_roommodel_result{};
    r->structSize = sizeof(n60_roommodel_result);
    return run(q, nb, r, lowRe, lowIm);
}

}  // extern "C"
