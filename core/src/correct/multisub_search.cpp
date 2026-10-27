// Deterministic multi-start local search for the multi-subwoofer optimiser (E8 A6a, n60/correct.h section 6).
//
// The evaluation budget is soft: it is checked between rounds and starts, so one round can overshoot it.
// Offline only: control or worker thread, allocates at entry (std::vector sized from the inputs), never called
// from an audio callback. Double precision, fixed summation order, fixed starts and a fixed-seed SplitMix64
// stream (Steele, Lea and Flood, "Fast splittable pseudorandom number generators", 2014), no threads, no clock:
// two runs give identical bits.
//
// Model. Sub s at seat n and bin b adds a_s * T[s][n][b] * exp(-j 2 pi f_b d_s) to the seat sum, where T is the
// precomputed unit-gain response, d_s the delay grid value, and a_s = (+-1) * 10^(g_s / 20) the polarity and
// gain. The seat level is L = 10 log10 |sum|^2. With normalised seat weights w and the weighted mean m_b of the
// levels at bin b, the weighted target error is Var_b + (m_b - t_b)^2, so the objective of the header
// (target_weight * error + variance_weight * variance, averaged over bins, plus the boost term) is
//   mean_b [ (wT + wV) Var_b + wT (m_b - t_b)^2 ] + reg * sum_s max(0, g_s)^2.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

#include "n60/correct.h"

namespace {

constexpr uint32_t kMaxSubs = N60_CORRECT_MULTISUB_MAX_SUBS;
constexpr double kLn2 = 0.69314718055994530942;
constexpr double kTenOverLn10 = 4.34294481903251827651;  // 10 / ln(10)

// 10 log10(p) for p >= 1e-24, accurate to about 1e-10 dB: the mantissa is reduced to [1/sqrt2, sqrt2] and
// ln(m) = 2 atanh((m - 1) / (m + 1)) is summed to t^13 (|t| <= 0.172).
inline double powerToDb(double p) {
    if (p < 1.0e-24) p = 1.0e-24;
    uint64_t bits;
    std::memcpy(&bits, &p, sizeof bits);
    int e = static_cast<int>((bits >> 52) & 0x7ffu) - 1023;
    bits = (bits & 0x000fffffffffffffull) | 0x3ff0000000000000ull;
    double m;
    std::memcpy(&m, &bits, sizeof m);
    if (m > 1.4142135623730951) {
        m *= 0.5;
        ++e;
    }
    const double t = (m - 1.0) / (m + 1.0);
    const double t2 = t * t;
    const double ln = 2.0 * t * (1.0 + t2 * (1.0 / 3.0 + t2 * (1.0 / 5.0 + t2 * (1.0 / 7.0 + t2 * (1.0 / 9.0 + t2 * (1.0 / 11.0 + t2 * (1.0 / 13.0)))))));
    return kTenOverLn10 * (ln + static_cast<double>(e) * kLn2);
}

struct Setting {
    uint32_t d = 0, g = 0, p = 0;
    bool operator==(const Setting &o) const { return d == o.d && g == o.g && p == o.p; }
};

struct State {
    Setting s[kMaxSubs];
};

struct Move {
    uint32_t n = 0;
    uint32_t sub[2] = {0, 0};
    Setting set[2];
};

struct SplitMix64 {
    uint64_t x;
    uint64_t next() {
        x += 0x9E3779B97F4A7C15ull;
        uint64_t z = x;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
};

class Search {
public:
    uint32_t S = 0, N = 0, B = 0, K = 0, G = 0;
    uint64_t evals = 0;
    uint64_t budget = 0;
    bool exhausted = false;

    bool build(const n60_correct_multisub_problem &p);
    double objective(const State &st, double *error, double *variance);
    State greedy(State st, uint32_t passes);
    State improve(State st, uint32_t rounds);
    uint32_t zeroGain() const { return g0_; }
    uint32_t delayCount() const { return K; }
    uint32_t gainCount() const { return G; }

private:
    uint32_t stride_ = 0;  // B * N cells per sub
    std::vector<double> tre_, tim_, phr_, phi_, glin_, gdb_, wn_, target_;
    std::vector<double> rre_, rim_;
    double wT_ = 1, wV_ = 0, reg_ = 0;
    uint32_t g0_ = 0;

    double amp(const Setting &s) const { return (s.p ? -1.0 : 1.0) * glin_[s.g]; }
    double boost(const Setting &s) const {
        const double b = std::max(0.0, gdb_[s.g]);
        return reg_ * b * b;
    }
    double cells(const double *rre, const double *rim, const Move &mv, double *error, double *variance);
    void sumExcluding(const State &st, int ex0, int ex1);
    double candidate(const Move &mv, double boostOthers);
};

bool Search::build(const n60_correct_multisub_problem &p) {
    S = p.sub_count;
    B = p.bin_count;
    G = p.gain_count;
    wT_ = p.target_error_weight;
    wV_ = p.seat_variance_weight;
    reg_ = p.boost_regularisation;
    budget = p.evaluation_budget;

    // Active seats: positive weight, normalised in index order.
    std::vector<uint32_t> seats;
    double total = 0.0;
    for (uint32_t n = 0; n < p.seat_count; ++n) {
        if (p.seat_weight[n] > 0.0) {
            seats.push_back(n);
            total += p.seat_weight[n];
        }
    }
    N = static_cast<uint32_t>(seats.size());
    wn_.resize(N);
    for (uint32_t i = 0; i < N; ++i) wn_[i] = p.seat_weight[seats[i]] / total;

    // Delay grid, bounded by the phase-wrap limit 0.5 / smallest bin spacing.
    double minSpacing = 0.0;
    for (uint32_t b = 0; b + 1 < B; ++b) {
        const double d = std::fabs(p.frequency_hz[b + 1] - p.frequency_hz[b]);
        if (d > 0.0 && (minSpacing == 0.0 || d < minSpacing)) minSpacing = d;
    }
    const double limit = minSpacing > 0.0 ? 0.5 / minSpacing * (1.0 + 1.0e-9) : 1.0e30;
    K = 1;
    while (K < p.delay_count && p.delay_seconds[K] <= limit) ++K;

    stride_ = B * N;
    tre_.assign(static_cast<size_t>(S) * stride_, 0.0);
    tim_.assign(static_cast<size_t>(S) * stride_, 0.0);
    for (uint32_t s = 0; s < S; ++s) {
        for (uint32_t i = 0; i < N; ++i) {
            const size_t src = (static_cast<size_t>(s) * p.seat_count + seats[i]) * B;
            for (uint32_t b = 0; b < B; ++b) {
                tre_[static_cast<size_t>(s) * stride_ + static_cast<size_t>(b) * N + i] = p.response_re[src + b];
                tim_[static_cast<size_t>(s) * stride_ + static_cast<size_t>(b) * N + i] = p.response_im[src + b];
            }
        }
    }
    constexpr double kTwoPi = 6.28318530717958647692;
    phr_.resize(static_cast<size_t>(K) * B);
    phi_.resize(static_cast<size_t>(K) * B);
    for (uint32_t k = 0; k < K; ++k) {
        for (uint32_t b = 0; b < B; ++b) {
            const double theta = kTwoPi * p.frequency_hz[b] * p.delay_seconds[k];
            phr_[static_cast<size_t>(k) * B + b] = std::cos(theta);
            phi_[static_cast<size_t>(k) * B + b] = -std::sin(theta);
        }
    }
    glin_.resize(G);
    gdb_.assign(p.gain_db, p.gain_db + G);
    for (uint32_t g = 0; g < G; ++g) glin_[g] = std::pow(10.0, p.gain_db[g] / 20.0);
    target_.assign(p.target_db, p.target_db + B);
    double bestAbs = 1.0e300;
    for (uint32_t g = 0; g < G; ++g) {
        if (std::fabs(p.gain_db[g]) < bestAbs) {
            bestAbs = std::fabs(p.gain_db[g]);
            g0_ = g;
        }
    }
    rre_.assign(stride_, 0.0);
    rim_.assign(stride_, 0.0);
    return true;
}

// Objective of the cell sums R plus the contribution of up to two moved subs.
double Search::cells(const double *rre, const double *rim, const Move &mv, double *error, double *variance) {
    double total = 0.0, totalVar = 0.0;
    double amps[2] = {0, 0};
    for (uint32_t k = 0; k < mv.n; ++k) amps[k] = amp(mv.set[k]);
    for (uint32_t b = 0; b < B; ++b) {
        double mean = 0.0, sq = 0.0;
        for (uint32_t n = 0; n < N; ++n) {
            const size_t i = static_cast<size_t>(b) * N + n;
            double re = rre[i], im = rim[i];
            for (uint32_t k = 0; k < mv.n; ++k) {
                const size_t c = static_cast<size_t>(mv.sub[k]) * stride_ + i;
                const size_t q = static_cast<size_t>(mv.set[k].d) * B + b;
                const double pr = phr_[q], pi = phi_[q];
                re += amps[k] * (tre_[c] * pr - tim_[c] * pi);
                im += amps[k] * (tre_[c] * pi + tim_[c] * pr);
            }
            const double db = powerToDb(re * re + im * im);
            mean += wn_[n] * db;
            sq += wn_[n] * db * db;
        }
        double var = sq - mean * mean;
        if (var < 0.0) var = 0.0;
        const double e = mean - target_[b];
        total += var + e * e;
        totalVar += var;
    }
    if (error != nullptr) *error = total / B;
    if (variance != nullptr) *variance = totalVar / B;
    return (wT_ * total + wV_ * totalVar) / B;
}

void Search::sumExcluding(const State &st, int ex0, int ex1) {
    std::fill(rre_.begin(), rre_.end(), 0.0);
    std::fill(rim_.begin(), rim_.end(), 0.0);
    for (uint32_t s = 0; s < S; ++s) {
        if (static_cast<int>(s) == ex0 || static_cast<int>(s) == ex1) continue;
        const double a = amp(st.s[s]);
        for (uint32_t b = 0; b < B; ++b) {
            const size_t q = static_cast<size_t>(st.s[s].d) * B + b;
            const double pr = phr_[q], pi = phi_[q];
            for (uint32_t n = 0; n < N; ++n) {
                const size_t i = static_cast<size_t>(b) * N + n;
                const size_t c = static_cast<size_t>(s) * stride_ + i;
                rre_[i] += a * (tre_[c] * pr - tim_[c] * pi);
                rim_[i] += a * (tre_[c] * pi + tim_[c] * pr);
            }
        }
    }
}

double Search::objective(const State &st, double *error, double *variance) {
    sumExcluding(st, -1, -1);
    Move none;
    double boosts = 0.0;
    for (uint32_t s = 0; s < S; ++s) boosts += boost(st.s[s]);
    return cells(rre_.data(), rim_.data(), none, error, variance) + boosts;
}

// Scores a candidate against the cached R (the other subs) and the boost of the unmoved subs.
double Search::candidate(const Move &mv, double boostOthers) {
    ++evals;
    double boosts = boostOthers;
    for (uint32_t k = 0; k < mv.n; ++k) boosts += boost(mv.set[k]);
    return cells(rre_.data(), rim_.data(), mv, nullptr, nullptr) + boosts;
}

State Search::greedy(State st, uint32_t passes) {
    for (uint32_t pass = 0; pass < passes; ++pass) {
        for (uint32_t s = 0; s < S; ++s) {
            sumExcluding(st, static_cast<int>(s), -1);
            double boostOthers = 0.0;
            for (uint32_t o = 0; o < S; ++o) {
                if (o != s) boostOthers += boost(st.s[o]);
            }
            Move mv;
            mv.n = 1;
            mv.sub[0] = s;
            double best = INFINITY;
            Setting bestSet = st.s[s];
            for (uint32_t p = 0; p < 2; ++p) {
                for (uint32_t d = 0; d < K; ++d) {
                    mv.set[0] = st.s[s];
                    mv.set[0].p = p;
                    mv.set[0].d = d;
                    const double o = candidate(mv, boostOthers);
                    if (o < best) {
                        best = o;
                        bestSet = mv.set[0];
                    }
                }
            }
            st.s[s].p = bestSet.p;
            st.s[s].d = bestSet.d;
            best = INFINITY;
            uint32_t bestGain = st.s[s].g;
            for (uint32_t g = 0; g < G; ++g) {
                mv.set[0] = st.s[s];
                mv.set[0].g = g;
                const double o = candidate(mv, boostOthers);
                if (o < best) {
                    best = o;
                    bestGain = g;
                }
            }
            st.s[s].g = bestGain;
        }
    }
    return st;
}

State Search::improve(State st, uint32_t rounds) {
    double cur = objective(st, nullptr, nullptr);
    for (uint32_t round = 0; round < rounds; ++round) {
        if (evals >= budget) {
            exhausted = true;
            break;
        }
        double bestObjective = cur - (1.0e-6 * std::fabs(cur) + 1.0e-12);
        bool found = false;
        Move bestMove;
        auto consider = [&](const Move &mv, double boostOthers) {
            const double o = candidate(mv, boostOthers);
            if (o < bestObjective) {
                bestObjective = o;
                bestMove = mv;
                found = true;
            }
        };
        double boostAll = 0.0;
        for (uint32_t s = 0; s < S; ++s) boostAll += boost(st.s[s]);

        // (a) One sub: delay x polarity, then gain.
        for (uint32_t s = 0; s < S; ++s) {
            sumExcluding(st, static_cast<int>(s), -1);
            const double boostOthers = boostAll - boost(st.s[s]);
            Move mv;
            mv.n = 1;
            mv.sub[0] = s;
            for (uint32_t p = 0; p < 2; ++p) {
                for (uint32_t d = 0; d < K; ++d) {
                    mv.set[0] = st.s[s];
                    mv.set[0].p = p;
                    mv.set[0].d = d;
                    if (mv.set[0] == st.s[s]) continue;
                    consider(mv, boostOthers);
                }
            }
            for (uint32_t g = 0; g < G; ++g) {
                mv.set[0] = st.s[s];
                mv.set[0].g = g;
                if (mv.set[0] == st.s[s]) continue;
                consider(mv, boostOthers);
            }
        }
        // (b) Pair relative delay, (c) pair swap.
        for (uint32_t i = 0; i < S; ++i) {
            for (uint32_t j = i + 1; j < S; ++j) {
                sumExcluding(st, static_cast<int>(i), static_cast<int>(j));
                const double boostOthers = boostAll - boost(st.s[i]) - boost(st.s[j]);
                Move mv;
                mv.n = 2;
                mv.sub[0] = i;
                mv.sub[1] = j;
                for (int k = -4; k <= 4; ++k) {
                    if (k == 0) continue;
                    const int64_t di = static_cast<int64_t>(st.s[i].d) + k;
                    const int64_t dj = static_cast<int64_t>(st.s[j].d) - k;
                    if (di < 0 || dj < 0 || di >= K || dj >= K) continue;
                    for (uint32_t flip = 0; flip < 2; ++flip) {
                        mv.set[0] = st.s[i];
                        mv.set[1] = st.s[j];
                        mv.set[0].d = static_cast<uint32_t>(di);
                        mv.set[1].d = static_cast<uint32_t>(dj);
                        if (flip) mv.set[1].p ^= 1u;
                        consider(mv, boostOthers);
                    }
                }
                // (d) On a small delay grid, every joint (delay, polarity) pair for the two subs.
                if (4u * K * K <= 1024u) {
                    for (uint32_t pi = 0; pi < 2; ++pi) {
                        for (uint32_t di = 0; di < K; ++di) {
                            for (uint32_t pj = 0; pj < 2; ++pj) {
                                for (uint32_t dj = 0; dj < K; ++dj) {
                                    mv.set[0] = st.s[i];
                                    mv.set[1] = st.s[j];
                                    mv.set[0].p = pi;
                                    mv.set[0].d = di;
                                    mv.set[1].p = pj;
                                    mv.set[1].d = dj;
                                    if (mv.set[0] == st.s[i] && mv.set[1] == st.s[j]) continue;
                                    consider(mv, boostOthers);
                                }
                            }
                        }
                    }
                }
                if (!(st.s[i] == st.s[j])) {
                    mv.set[0] = st.s[j];
                    mv.set[1] = st.s[i];
                    consider(mv, boostOthers);
                }
            }
        }
        if (!found) break;
        for (uint32_t k = 0; k < bestMove.n; ++k) st.s[bestMove.sub[k]] = bestMove.set[k];
        cur = objective(st, nullptr, nullptr);  // recomputed from scratch: rounding never accumulates
    }
    return st;
}

void normalise(State &st, uint32_t subs) {
    uint32_t low = st.s[0].d;
    for (uint32_t s = 1; s < subs; ++s) low = std::min(low, st.s[s].d);
    for (uint32_t s = 0; s < subs; ++s) st.s[s].d -= low;
}

uint64_t totalDelay(const State &st, uint32_t subs) {
    uint64_t t = 0;
    for (uint32_t s = 0; s < subs; ++s) t += st.s[s].d;
    return t;
}

uint32_t inversions(const State &st, uint32_t subs) {
    uint32_t t = 0;
    for (uint32_t s = 0; s < subs; ++s) t += st.s[s].p;
    return t;
}

bool finiteArray(const double *a, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        if (!std::isfinite(a[i])) return false;
    }
    return true;
}

}  // namespace

extern "C" int32_t n60_correct_multisub_search(const n60_correct_multisub_problem *problem, n60_correct_multisub_result *result) {
    if (problem == nullptr || result == nullptr || problem->response_re == nullptr || problem->response_im == nullptr ||
        problem->frequency_hz == nullptr || problem->target_db == nullptr || problem->seat_weight == nullptr ||
        problem->delay_seconds == nullptr || problem->gain_db == nullptr || problem->struct_size < sizeof(*problem) ||
        problem->sub_count == 0 || problem->seat_count == 0 || problem->bin_count == 0 || problem->delay_count == 0 ||
        problem->gain_count == 0 || problem->greedy_passes == 0 || problem->greedy_passes > 8 || problem->starts == 0 ||
        problem->starts > 64 || problem->rounds == 0 || problem->rounds > 64) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    if (problem->sub_count > kMaxSubs || problem->delay_count > N60_CORRECT_MULTISUB_MAX_DELAYS ||
        problem->gain_count > N60_CORRECT_MULTISUB_MAX_GAINS || problem->seat_count > 64u || problem->bin_count > 4096u) {
        return N60_CORRECT_ERR_CAPACITY;
    }
    const size_t table = static_cast<size_t>(problem->sub_count) * problem->seat_count * problem->bin_count;
    if (!finiteArray(problem->response_re, table) || !finiteArray(problem->response_im, table) ||
        !finiteArray(problem->frequency_hz, problem->bin_count) || !finiteArray(problem->target_db, problem->bin_count) ||
        !finiteArray(problem->seat_weight, problem->seat_count) || !finiteArray(problem->delay_seconds, problem->delay_count) ||
        !finiteArray(problem->gain_db, problem->gain_count) || !std::isfinite(problem->target_error_weight) ||
        !std::isfinite(problem->seat_variance_weight) || !std::isfinite(problem->boost_regularisation)) {
        return N60_CORRECT_ERR_NONFINITE;
    }
    if (problem->delay_seconds[0] != 0.0 || problem->target_error_weight < 0.0 || problem->seat_variance_weight < 0.0 ||
        problem->boost_regularisation < 0.0) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    for (uint32_t k = 1; k < problem->delay_count; ++k) {
        if (!(problem->delay_seconds[k] > problem->delay_seconds[k - 1])) return N60_CORRECT_ERR_ARGUMENT;
    }
    for (uint32_t b = 0; b < problem->bin_count; ++b) {
        if (!(problem->frequency_hz[b] > 0.0)) return N60_CORRECT_ERR_ARGUMENT;
    }
    bool anySeat = false;
    for (uint32_t n = 0; n < problem->seat_count; ++n) {
        if (problem->seat_weight[n] < 0.0) return N60_CORRECT_ERR_ARGUMENT;
        if (problem->seat_weight[n] > 0.0) anySeat = true;
    }
    if (!anySeat) return N60_CORRECT_ERR_ARGUMENT;

    Search search;
    search.build(*problem);
    const uint32_t S = problem->sub_count;
    const uint32_t K = search.delayCount();
    const uint32_t G = search.gainCount();

    State zero;
    for (uint32_t s = 0; s < S; ++s) zero.s[s].g = search.zeroGain();

    std::vector<State> results;
    results.reserve(problem->starts);

    // Start 0: the coordinate sweeps (never worse than greedy), then the local search.
    State first = search.greedy(zero, problem->greedy_passes);
    first = search.improve(first, problem->rounds);
    results.push_back(first);

    SplitMix64 rng{N60_CORRECT_MULTISUB_SEED};
    for (uint32_t start = 1; start < problem->starts; ++start) {
        if (search.evals >= search.budget) {
            search.exhausted = true;
            break;
        }
        State st = zero;
        if (start <= 4) {
            for (uint32_t s = 0; s < S; ++s) {
                switch (start) {
                    case 1: st.s[s].p = 0; break;
                    case 2: st.s[s].p = s & 1u; break;
                    case 3: st.s[s].p = s < S / 2 ? 1u : 0u; break;
                    default: st.s[s].p = first.s[s].p ^ 1u; break;
                }
            }
        } else {
            for (uint32_t s = 0; s < S; ++s) {
                st.s[s].d = static_cast<uint32_t>(rng.next() % K);
                st.s[s].p = static_cast<uint32_t>(rng.next() & 1u);
                st.s[s].g = static_cast<uint32_t>(rng.next() % G);
            }
        }
        results.push_back(search.improve(st, problem->rounds));
    }

    // Normalise and score every start; start 0 bounds what is acceptable.
    std::vector<double> scores(results.size());
    double best = INFINITY;
    for (size_t r = 0; r < results.size(); ++r) {
        normalise(results[r], S);
        scores[r] = search.objective(results[r], nullptr, nullptr);
        best = std::min(best, scores[r]);
    }
    // Robust pick: among results within 0.02 dB^2 of the best and no worse than start 0, the lowest worst-case
    // objective when one sub's delay moves by one step; ties: smaller total delay, fewer inversions, lower index.
    size_t pick = 0;
    double pickWorst = INFINITY;
    for (size_t r = 0; r < results.size(); ++r) {
        if (!(scores[r] <= best + 0.02) || !(scores[r] <= scores[0])) continue;
        double worst = scores[r];
        for (uint32_t s = 0; s < S; ++s) {
            for (int dir = -1; dir <= 1; dir += 2) {
                const int64_t d = static_cast<int64_t>(results[r].s[s].d) + dir;
                if (d < 0 || d >= K) continue;
                State probe = results[r];
                probe.s[s].d = static_cast<uint32_t>(d);
                worst = std::max(worst, search.objective(probe, nullptr, nullptr));
            }
        }
        bool better = r == 0 || worst < pickWorst;
        if (!better && worst == pickWorst) {
            const uint64_t td = totalDelay(results[r], S), tp = totalDelay(results[pick], S);
            better = td < tp || (td == tp && inversions(results[r], S) < inversions(results[pick], S));
        }
        if (better) {
            pick = r;
            pickWorst = worst;
        }
    }

    if (!std::isfinite(scores[pick])) return N60_CORRECT_ERR_NONFINITE;
    std::memset(result, 0, sizeof(*result));
    result->struct_size = sizeof(*result);
    const State &chosen = results[pick];
    for (uint32_t s = 0; s < S; ++s) {
        result->delay_index[s] = chosen.s[s].d;
        result->gain_index[s] = chosen.s[s].g;
        result->polarity[s] = chosen.s[s].p;
    }
    result->objective = search.objective(chosen, &result->target_error, &result->seat_variance);
    result->evaluations = search.evals;
    result->starts_run = static_cast<uint32_t>(results.size());
    result->budget_exhausted = search.exhausted ? 1u : 0u;
    result->delay_count_used = K;
    return N60_CORRECT_OK;
}

// ---------------------------------------------------------------------------------------------------------------
// EQ stage (E8 A6b, n60/correct.h section 6). With the delay, gain and polarity fixed, each sub s has an EQ level
// e[s][b] on a grid at every bin b. The table C[s][n][b] is the final complex response of sub s (gain, delay and
// polarity included, EQ 0 dB); the EQ multiplies it by 10^(v/20). The objective is the GLOBAL one of
// N60MultiSubEvaluateObjective with the constant boost term dropped:
//   (1/B) sum_b [ wT (Var_b + (m_b - t_b)^2) + wV Var_b ]
//   + eqReg / (S B) sum_s,b v^2 + eqSmooth / (S B) sum_s,b>0 (v[b] - v[b-1])^2.
// Feasible levels: |v[b] - v[b-1]| <= max(slope * |log2(f_b / f_(b-1))|, smallest grid step), and no positive level at a
// bin where an active seat is more than `null_guard_db` below target with all EQ at 0 dB.
// Moves, all accepting only strict improvements so the result is never worse than start 0 (the per-bin sweeps):
//   chain: one sub over all bins, an exact Viterbi pass with the other subs fixed;
//   pair:  two subs jointly at one bin, over a window of +-4 grid levels around the current ones.
// Offline only; allocates at entry; fixed order; sums recomputed from scratch after each accepted move; no randomness.
namespace {

constexpr uint32_t kMaxEqBins = N60_CORRECT_MULTISUB_MAX_EQ_BINS;
constexpr uint32_t kMaxEqLevels = N60_CORRECT_MULTISUB_MAX_EQ_LEVELS;
constexpr int kPairRadius = 4;

class EqSearch {
public:
    uint32_t S = 0, N = 0, B = 0, L = 0;
    uint64_t evals = 0, budget = 0;
    bool exhausted = false;
    uint32_t e[kMaxSubs][kMaxEqBins] = {};

    void build(const n60_correct_multisub_eq_problem &p);
    void start0(uint32_t passes, bool legacy);
    void startBest(uint32_t passes);
    bool chainMove(uint32_t s);
    bool pairMoves();
    double total(double *error, double *variance);
    uint32_t rounds(uint32_t maxRounds);

private:
    std::vector<double> cre_, cim_, lin_, val_, wn_, target_, rre_, rim_, orr_, oim_;
    std::vector<double> dc_, cost_;
    std::vector<int32_t> back_;
    std::vector<uint32_t> top_;
    std::vector<double> jump_;
    double wT_ = 1, wV_ = 0, rg_ = 0, sm_ = 0;

    size_t at(uint32_t s, uint32_t b) const { return (static_cast<size_t>(s) * B + b) * N; }
    bool ok(uint32_t i, uint32_t j, uint32_t b) const { return std::fabs(val_[i] - val_[j]) <= jump_[b] + 1.0e-9; }
    double unary(uint32_t l) const { return rg_ * val_[l] * val_[l]; }
    double pairCost(uint32_t i, uint32_t j) const { return sm_ * (val_[i] - val_[j]) * (val_[i] - val_[j]); }
    double data(uint32_t b, const double *re, const double *im, double *error, double *variance) const;
    void binSum(uint32_t b, int ex0, int ex1, double *re, double *im) const;
    void fullSums();
    double neighbours(uint32_t s, uint32_t b, uint32_t l) const;
    bool feasible(uint32_t s, uint32_t b, uint32_t l) const;
};

void EqSearch::build(const n60_correct_multisub_eq_problem &p) {
    S = p.sub_count;
    B = p.bin_count;
    L = p.eq_count;
    wT_ = p.target_error_weight;
    wV_ = p.seat_variance_weight;
    rg_ = p.eq_regularisation / (static_cast<double>(S) * B);
    sm_ = p.eq_smoothness / (static_cast<double>(S) * B);
    budget = p.evaluation_budget;

    std::vector<uint32_t> seats;
    double totalWeight = 0.0;
    for (uint32_t n = 0; n < p.seat_count; ++n) {
        if (p.seat_weight[n] > 0.0) {
            seats.push_back(n);
            totalWeight += p.seat_weight[n];
        }
    }
    N = static_cast<uint32_t>(seats.size());
    wn_.resize(N);
    for (uint32_t i = 0; i < N; ++i) wn_[i] = p.seat_weight[seats[i]] / totalWeight;
    cre_.assign(static_cast<size_t>(S) * B * N, 0.0);
    cim_.assign(static_cast<size_t>(S) * B * N, 0.0);
    for (uint32_t s = 0; s < S; ++s) {
        for (uint32_t i = 0; i < N; ++i) {
            const size_t src = (static_cast<size_t>(s) * p.seat_count + seats[i]) * B;
            for (uint32_t b = 0; b < B; ++b) {
                cre_[at(s, b) + i] = p.response_re[src + b];
                cim_[at(s, b) + i] = p.response_im[src + b];
            }
        }
    }
    val_.assign(p.eq_db, p.eq_db + L);
    lin_.resize(L);
    double step = 1.0e30;
    for (uint32_t l = 0; l < L; ++l) {
        lin_[l] = std::pow(10.0, val_[l] / 20.0);
        if (l > 0) step = std::min(step, val_[l] - val_[l - 1]);
    }
    target_.assign(p.target_db, p.target_db + B);
    jump_.assign(B, 1.0e30);
    for (uint32_t b = 1; b < B; ++b) {
        const double oct = std::fabs(std::log2(p.frequency_hz[b] / p.frequency_hz[b - 1]));
        jump_[b] = L > 1 ? std::max(p.max_slope_db_per_octave * oct, step) : 1.0e30;
    }
    rre_.assign(static_cast<size_t>(B) * N, 0.0);
    rim_.assign(static_cast<size_t>(B) * N, 0.0);
    orr_.assign(N, 0.0);
    oim_.assign(N, 0.0);
    dc_.assign(static_cast<size_t>(B) * L, 0.0);
    cost_.assign(static_cast<size_t>(B) * L, 0.0);
    back_.assign(static_cast<size_t>(B) * L, 0);

    // Null guard: with all EQ at 0 dB, an active seat more than null_guard_db below target forbids positive levels.
    uint32_t zero = 0;
    for (uint32_t l = 1; l < L; ++l) {
        if (std::fabs(val_[l]) < std::fabs(val_[zero])) zero = l;
    }
    top_.assign(B, L - 1);
    uint32_t lastNonPositive = 0;
    for (uint32_t l = 0; l < L; ++l) {
        if (val_[l] <= 0.0) lastNonPositive = l;
    }
    for (uint32_t b = 0; b < B; ++b) {
        bool nullBin = false;
        for (uint32_t n = 0; n < N && !nullBin; ++n) {
            double re = 0.0, im = 0.0;
            for (uint32_t s = 0; s < S; ++s) {
                re += cre_[at(s, b) + n];
                im += cim_[at(s, b) + n];
            }
            if (target_[b] - powerToDb(re * re + im * im) > p.null_guard_db) nullBin = true;
        }
        if (nullBin) top_[b] = lastNonPositive;
        for (uint32_t s = 0; s < S; ++s) e[s][b] = std::min(zero, top_[b]);
    }
    fullSums();
}

double EqSearch::data(uint32_t b, const double *re, const double *im, double *error, double *variance) const {
    double mean = 0.0, sq = 0.0;
    for (uint32_t n = 0; n < N; ++n) {
        const double db = powerToDb(re[n] * re[n] + im[n] * im[n]);
        mean += wn_[n] * db;
        sq += wn_[n] * db * db;
    }
    double var = sq - mean * mean;
    if (var < 0.0) var = 0.0;
    const double err = mean - target_[b];
    if (error != nullptr) *error = (var + err * err) / B;
    if (variance != nullptr) *variance = var / B;
    return (wT_ * (var + err * err) + wV_ * var) / B;
}

// Sum of all subs at bin b, skipping up to two.
void EqSearch::binSum(uint32_t b, int ex0, int ex1, double *re, double *im) const {
    for (uint32_t n = 0; n < N; ++n) {
        re[n] = 0.0;
        im[n] = 0.0;
    }
    for (uint32_t s = 0; s < S; ++s) {
        if (static_cast<int>(s) == ex0 || static_cast<int>(s) == ex1) continue;
        const double a = lin_[e[s][b]];
        for (uint32_t n = 0; n < N; ++n) {
            re[n] += a * cre_[at(s, b) + n];
            im[n] += a * cim_[at(s, b) + n];
        }
    }
}

void EqSearch::fullSums() {
    for (uint32_t b = 0; b < B; ++b) binSum(b, -1, -1, &rre_[static_cast<size_t>(b) * N], &rim_[static_cast<size_t>(b) * N]);
}

// Smoothness cost of sub s at bin b with level l against its neighbours' current levels.
double EqSearch::neighbours(uint32_t s, uint32_t b, uint32_t l) const {
    double c = 0.0;
    if (b > 0) c += pairCost(e[s][b - 1], l);
    if (b + 1 < B) c += pairCost(l, e[s][b + 1]);
    return c;
}

bool EqSearch::feasible(uint32_t s, uint32_t b, uint32_t l) const {
    if (l > top_[b]) return false;
    if (b > 0 && !ok(e[s][b - 1], l, b)) return false;
    if (b + 1 < B && !ok(l, e[s][b + 1], b + 1)) return false;
    return true;
}

double EqSearch::total(double *error, double *variance) {
    double sum = 0.0, err = 0.0, var = 0.0;
    for (uint32_t b = 0; b < B; ++b) {
        double be = 0.0, bv = 0.0;
        sum += data(b, &rre_[static_cast<size_t>(b) * N], &rim_[static_cast<size_t>(b) * N], &be, &bv);
        err += be;
        var += bv;
        for (uint32_t s = 0; s < S; ++s) {
            sum += unary(e[s][b]);
            if (b > 0) sum += pairCost(e[s][b - 1], e[s][b]);
        }
    }
    if (error != nullptr) *error = err;
    if (variance != nullptr) *variance = var;
    return sum;
}

// Start sweeps: `passes` sweeps, per bin and per sub the best feasible level. The default sweep scores on the global
// objective and keeps the current level unless another is strictly better. The legacy sweep reproduces the A4
// per-bin rule (the local objective weights the EQ terms `subs` times more heavily than the global one, and the lowest
// level wins a tie), so a start that is never worse than the A4 stage is always among the candidates.
void EqSearch::start0(uint32_t passes, bool legacy) {
    const double regScale = legacy ? static_cast<double>(S) : 1.0;
    std::vector<double> re(N), im(N);
    for (uint32_t pass = 0; pass < passes; ++pass) {
        for (uint32_t b = 0; b < B; ++b) {
            for (uint32_t s = 0; s < S; ++s) {
                binSum(b, static_cast<int>(s), -1, orr_.data(), oim_.data());
                const uint32_t cur = e[s][b];
                auto cost = [&](uint32_t l) {
                    for (uint32_t n = 0; n < N; ++n) {
                        re[n] = orr_[n] + lin_[l] * cre_[at(s, b) + n];
                        im[n] = oim_[n] + lin_[l] * cim_[at(s, b) + n];
                    }
                    ++evals;
                    return data(b, re.data(), im.data(), nullptr, nullptr) + regScale * (unary(l) + neighbours(s, b, l));
                };
                if (legacy) {
                    uint32_t pick = cur;
                    double lowest = INFINITY;
                    for (uint32_t l = 0; l < L; ++l) {
                        if (!feasible(s, b, l)) continue;
                        const double c = cost(l);
                        if (c < lowest) {
                            lowest = c;
                            pick = l;
                        }
                    }
                    if (pick != cur) {
                        e[s][b] = pick;
                        binSum(b, -1, -1, &rre_[static_cast<size_t>(b) * N], &rim_[static_cast<size_t>(b) * N]);
                    }
                    continue;
                }
                // Keep the current level unless another feasible one is strictly better.
                const double curCost = cost(cur);
                uint32_t best = cur;
                double bestCost = curCost;
                for (uint32_t l = 0; l < L; ++l) {
                    if (l == cur || !feasible(s, b, l)) continue;
                    const double c = cost(l);
                    if (c < bestCost - 1.0e-12 * (1.0 + std::fabs(bestCost))) {
                        bestCost = c;
                        best = l;
                    }
                }
                if (best != cur) {
                    e[s][b] = best;
                    binSum(b, -1, -1, &rre_[static_cast<size_t>(b) * N], &rim_[static_cast<size_t>(b) * N]);
                }
            }
        }
    }
}

// Start 0: the better of the global-objective sweep and the legacy sweep, both from the initial state.
void EqSearch::startBest(uint32_t passes) {
    uint32_t init[kMaxSubs][kMaxEqBins];
    std::memcpy(init, e, sizeof init);
    start0(passes, false);
    const double a = total(nullptr, nullptr);
    uint32_t keep[kMaxSubs][kMaxEqBins];
    std::memcpy(keep, e, sizeof keep);
    std::memcpy(e, init, sizeof init);
    fullSums();
    start0(passes, true);
    if (!(total(nullptr, nullptr) < a)) {
        std::memcpy(e, keep, sizeof keep);
        fullSums();
    }
}

// Exact Viterbi pass over the bins for sub s with the others fixed.
bool EqSearch::chainMove(uint32_t s) {
    std::vector<double> re(N), im(N);
    for (uint32_t b = 0; b < B; ++b) {
        binSum(b, static_cast<int>(s), -1, orr_.data(), oim_.data());
        for (uint32_t l = 0; l < L; ++l) {
            if (l > top_[b]) {
                dc_[static_cast<size_t>(b) * L + l] = INFINITY;
                continue;
            }
            for (uint32_t n = 0; n < N; ++n) {
                re[n] = orr_[n] + lin_[l] * cre_[at(s, b) + n];
                im[n] = oim_[n] + lin_[l] * cim_[at(s, b) + n];
            }
            ++evals;
            dc_[static_cast<size_t>(b) * L + l] = data(b, re.data(), im.data(), nullptr, nullptr);
        }
    }
    double current = 0.0;
    for (uint32_t b = 0; b < B; ++b) {
        current += dc_[static_cast<size_t>(b) * L + e[s][b]] + unary(e[s][b]);
        if (b > 0) current += pairCost(e[s][b - 1], e[s][b]);
    }
    for (uint32_t l = 0; l < L; ++l) cost_[l] = dc_[l] + unary(l);
    for (uint32_t b = 1; b < B; ++b) {
        for (uint32_t l = 0; l < L; ++l) {
            const size_t i = static_cast<size_t>(b) * L + l;
            cost_[i] = INFINITY;
            back_[i] = -1;
            if (l > top_[b]) continue;
            double best = INFINITY;
            int32_t arg = -1;
            for (uint32_t k = 0; k < L; ++k) {
                const double prev = cost_[static_cast<size_t>(b - 1) * L + k];
                if (!(prev < INFINITY) || !ok(k, l, b)) continue;
                const double c = prev + pairCost(k, l);
                if (c < best) {
                    best = c;
                    arg = static_cast<int32_t>(k);
                }
            }
            if (arg >= 0) {
                cost_[i] = best + dc_[i] + unary(l);
                back_[i] = arg;
            }
        }
    }
    double best = INFINITY;
    int32_t arg = -1;
    for (uint32_t l = 0; l < L; ++l) {
        const double c = cost_[static_cast<size_t>(B - 1) * L + l];
        if (c < best) {
            best = c;
            arg = static_cast<int32_t>(l);
        }
    }
    if (arg < 0 || !(best < current - 1.0e-12 * (1.0 + std::fabs(current)))) return false;
    for (uint32_t b = B; b-- > 0;) {
        e[s][b] = static_cast<uint32_t>(arg);
        arg = back_[static_cast<size_t>(b) * L + static_cast<uint32_t>(arg)];
    }
    fullSums();
    return true;
}

// Two subs jointly at one bin over a window of +-kPairRadius levels; every pair and bin in index order.
bool EqSearch::pairMoves() {
    bool any = false;
    std::vector<double> re(N), im(N);
    for (uint32_t b = 0; b < B; ++b) {
        for (uint32_t s = 0; s < S; ++s) {
            for (uint32_t t = s + 1; t < S; ++t) {
                binSum(b, static_cast<int>(s), static_cast<int>(t), orr_.data(), oim_.data());
                const uint32_t cs = e[s][b], ct = e[t][b];
                auto cost = [&](uint32_t ls, uint32_t lt) {
                    for (uint32_t n = 0; n < N; ++n) {
                        re[n] = orr_[n] + lin_[ls] * cre_[at(s, b) + n] + lin_[lt] * cre_[at(t, b) + n];
                        im[n] = oim_[n] + lin_[ls] * cim_[at(s, b) + n] + lin_[lt] * cim_[at(t, b) + n];
                    }
                    ++evals;
                    return data(b, re.data(), im.data(), nullptr, nullptr) + unary(ls) + unary(lt) +
                           neighbours(s, b, ls) + neighbours(t, b, lt);
                };
                const double current = cost(cs, ct);
                double best = current;
                uint32_t bs = cs, bt = ct;
                const int lo = -kPairRadius, hi = kPairRadius;
                for (int ds = lo; ds <= hi; ++ds) {
                    const int ls = static_cast<int>(cs) + ds;
                    if (ls < 0 || ls >= static_cast<int>(L) || !feasible(s, b, static_cast<uint32_t>(ls))) continue;
                    for (int dt = lo; dt <= hi; ++dt) {
                        const int lt = static_cast<int>(ct) + dt;
                        if (lt < 0 || lt >= static_cast<int>(L) || !feasible(t, b, static_cast<uint32_t>(lt))) continue;
                        if (ds == 0 && dt == 0) continue;
                        const double c = cost(static_cast<uint32_t>(ls), static_cast<uint32_t>(lt));
                        if (c < best - 1.0e-12 * (1.0 + std::fabs(best))) {
                            best = c;
                            bs = static_cast<uint32_t>(ls);
                            bt = static_cast<uint32_t>(lt);
                        }
                    }
                }
                if (bs != cs || bt != ct) {
                    e[s][b] = bs;
                    e[t][b] = bt;
                    binSum(b, -1, -1, &rre_[static_cast<size_t>(b) * N], &rim_[static_cast<size_t>(b) * N]);
                    any = true;
                }
            }
        }
    }
    return any;
}

uint32_t EqSearch::rounds(uint32_t maxRounds) {
    uint32_t run = 0;
    double obj = total(nullptr, nullptr);
    for (uint32_t r = 0; r < maxRounds; ++r) {
        if (evals >= budget) {
            exhausted = true;
            break;
        }
        ++run;
        for (uint32_t s = 0; s < S; ++s) chainMove(s);
        if (S > 1) {
            if (evals >= budget) {
                exhausted = true;
            } else {
                pairMoves();
            }
        }
        const double now = total(nullptr, nullptr);
        const bool small = obj - now <= 1.0e-6 * std::fabs(now);
        obj = now;
        if (small || exhausted) break;
    }
    return run;
}

}  // namespace

extern "C" int32_t n60_correct_multisub_eq_search(const n60_correct_multisub_eq_problem *problem, n60_correct_multisub_eq_result *result) {
    if (problem == nullptr || result == nullptr || problem->response_re == nullptr || problem->response_im == nullptr ||
        problem->frequency_hz == nullptr || problem->target_db == nullptr || problem->seat_weight == nullptr ||
        problem->eq_db == nullptr || problem->struct_size < sizeof(*problem) || problem->sub_count == 0 ||
        problem->seat_count == 0 || problem->bin_count == 0 || problem->eq_count == 0 || problem->passes > 8 ||
        problem->rounds == 0 || problem->rounds > 32) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    if (problem->sub_count > kMaxSubs || problem->eq_count > kMaxEqLevels || problem->seat_count > 64u ||
        problem->bin_count > kMaxEqBins) {
        return N60_CORRECT_ERR_CAPACITY;
    }
    const size_t table = static_cast<size_t>(problem->sub_count) * problem->seat_count * problem->bin_count;
    if (!finiteArray(problem->response_re, table) || !finiteArray(problem->response_im, table) ||
        !finiteArray(problem->frequency_hz, problem->bin_count) || !finiteArray(problem->target_db, problem->bin_count) ||
        !finiteArray(problem->seat_weight, problem->seat_count) || !finiteArray(problem->eq_db, problem->eq_count) ||
        !std::isfinite(problem->target_error_weight) || !std::isfinite(problem->seat_variance_weight) ||
        !std::isfinite(problem->eq_regularisation) || !std::isfinite(problem->eq_smoothness) ||
        !std::isfinite(problem->max_slope_db_per_octave) || !std::isfinite(problem->null_guard_db)) {
        return N60_CORRECT_ERR_NONFINITE;
    }
    if (problem->target_error_weight < 0.0 || problem->seat_variance_weight < 0.0 || problem->eq_regularisation < 0.0 ||
        problem->eq_smoothness < 0.0 || problem->max_slope_db_per_octave < 0.0) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    for (uint32_t l = 1; l < problem->eq_count; ++l) {
        if (!(problem->eq_db[l] > problem->eq_db[l - 1])) return N60_CORRECT_ERR_ARGUMENT;
    }
    for (uint32_t b = 0; b < problem->bin_count; ++b) {
        if (!(problem->frequency_hz[b] > 0.0)) return N60_CORRECT_ERR_ARGUMENT;
    }
    bool anySeat = false;
    for (uint32_t n = 0; n < problem->seat_count; ++n) {
        if (problem->seat_weight[n] < 0.0) return N60_CORRECT_ERR_ARGUMENT;
        if (problem->seat_weight[n] > 0.0) anySeat = true;
    }
    if (!anySeat) return N60_CORRECT_ERR_ARGUMENT;

    std::unique_ptr<EqSearch> search(new (std::nothrow) EqSearch());
    if (!search) return N60_CORRECT_ERR_ALLOC;
    search->build(*problem);
    search->startBest(problem->passes);
    uint32_t run = 0;
    if (problem->passes > 0) run = search->rounds(problem->rounds);
    std::memset(result, 0, sizeof(*result));
    result->struct_size = sizeof(*result);
    for (uint32_t s = 0; s < problem->sub_count; ++s) {
        for (uint32_t b = 0; b < problem->bin_count; ++b) result->eq_index[s][b] = search->e[s][b];
    }
    result->objective = search->total(&result->target_error, &result->seat_variance);
    if (!std::isfinite(result->objective)) return N60_CORRECT_ERR_NONFINITE;
    result->evaluations = search->evals;
    result->rounds_run = run;
    result->budget_exhausted = search->exhausted ? 1u : 0u;
    return N60_CORRECT_OK;
}
