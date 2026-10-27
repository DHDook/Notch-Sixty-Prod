// E8 A6a/A6b: n60_correct_multisub_search and n60_correct_multisub_eq_search on their own tables (n60/correct.h section 6).
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/correct.h"

namespace {

struct Table {
    std::vector<double> re, im, freq, target, weight, delay, gain;
    n60_correct_multisub_problem p{};
};

// Two subs, two seats, 4 bins. Sub 1 equals sub 0 with its sign flipped: summed as measured they cancel, so the
// search must invert exactly one of them to restore the sum.
void makeTable(Table &t, uint32_t bins, double spacing, uint32_t delays, double delayStep) {
    const uint32_t subs = 2, seats = 2;
    t.re.assign(subs * seats * bins, 0.0);
    t.im.assign(subs * seats * bins, 0.0);
    for (uint32_t s = 0; s < subs; ++s)
        for (uint32_t n = 0; n < seats; ++n)
            for (uint32_t b = 0; b < bins; ++b) t.re[(s * seats + n) * bins + b] = (s == 0 ? 1.0 : -1.0) * (0.5 + 0.1 * n);
    for (uint32_t b = 0; b < bins; ++b) {
        t.freq.push_back(30.0 + spacing * b);
        t.target.push_back(0.0);
    }
    t.weight = {1.0, 1.0};
    for (uint32_t k = 0; k < delays; ++k) t.delay.push_back(0.001 * delayStep * k);
    for (int g = -6; g <= 0; ++g) t.gain.push_back(g);
    t.p.struct_size = sizeof t.p;
    t.p.sub_count = subs;
    t.p.seat_count = seats;
    t.p.bin_count = bins;
    t.p.response_re = t.re.data();
    t.p.response_im = t.im.data();
    t.p.frequency_hz = t.freq.data();
    t.p.target_db = t.target.data();
    t.p.seat_weight = t.weight.data();
    t.p.delay_seconds = t.delay.data();
    t.p.delay_count = delays;
    t.p.gain_db = t.gain.data();
    t.p.gain_count = static_cast<uint32_t>(t.gain.size());
    t.p.target_error_weight = 1.0;
    t.p.seat_variance_weight = 1.5;
    t.p.boost_regularisation = 0.02;
    t.p.greedy_passes = 3;
    t.p.starts = 12;
    t.p.rounds = 24;
    t.p.evaluation_budget = 2000000;
}

}  // namespace

int main() {
    Table t;
    makeTable(t, 4, 10.0, 9, 1.0);
    n60_correct_multisub_result a{}, b{};
    assert(n60_correct_multisub_search(&t.p, &a) == N60_CORRECT_OK);
    assert(n60_correct_multisub_search(&t.p, &b) == N60_CORRECT_OK);
    assert(std::memcmp(&a, &b, sizeof a) == 0);  // identical bits
    assert((a.polarity[0] ^ a.polarity[1]) == 1u);  // one inverted: the pair no longer cancels
    assert(a.delay_index[0] == 0u && a.delay_index[1] == 0u);
    assert(a.gain_index[0] <= 6u && a.gain_index[1] <= 6u && a.objective < 5.0);  // a cancelled pair would sit near -120 dB
    assert(a.starts_run == 12u && a.budget_exhausted == 0u && a.evaluations > 0u);
    assert(std::isfinite(a.objective) && a.objective >= 0.0);

    // A budget smaller than the greedy phase stops after start 0 and flags it.
    t.p.evaluation_budget = 10;
    n60_correct_multisub_result c{};
    assert(n60_correct_multisub_search(&t.p, &c) == N60_CORRECT_OK);
    assert(c.budget_exhausted == 1u && c.starts_run == 1u);
    assert(c.objective <= a.objective + 1.0e-9 + 1.0e-6 * a.objective + 10.0);

    // The delay span stops at 0.5 / smallest bin spacing: 20 Hz spacing allows 25 ms.
    Table sparse;
    makeTable(sparse, 4, 20.0, 61, 1.0);
    n60_correct_multisub_result d{};
    assert(n60_correct_multisub_search(&sparse.p, &d) == N60_CORRECT_OK);
    assert(d.delay_count_used == 26u);

    // Argument checks.
    n60_correct_multisub_result e{};
    assert(n60_correct_multisub_search(nullptr, &e) == N60_CORRECT_ERR_ARGUMENT);
    Table bad;
    makeTable(bad, 4, 10.0, 9, 1.0);
    bad.p.sub_count = 9;
    assert(n60_correct_multisub_search(&bad.p, &e) == N60_CORRECT_ERR_CAPACITY);
    bad.p.sub_count = 2;
    bad.p.starts = 0;
    assert(n60_correct_multisub_search(&bad.p, &e) == N60_CORRECT_ERR_ARGUMENT);
    bad.p.starts = 12;
    bad.re[0] = NAN;
    assert(n60_correct_multisub_search(&bad.p, &e) == N60_CORRECT_ERR_NONFINITE);

    // EQ stage (A6b): one sub, one seat, a +6 dB peak at bin 2 against a 0 dB target; the cut must land there.
    {
        const uint32_t bins = 5;
        std::vector<double> re(bins, 1.0), im(bins, 0.0), freq, target(bins, 0.0), eq;
        re[2] = 2.0;  // +6 dB
        for (uint32_t b = 0; b < bins; ++b) freq.push_back(40.0 + 10.0 * b);
        for (int v = -8; v <= 0; ++v) eq.push_back(v);
        double weight = 1.0;
        n60_correct_multisub_eq_problem q{};
        q.struct_size = sizeof q;
        q.sub_count = 1;
        q.seat_count = 1;
        q.bin_count = bins;
        q.response_re = re.data();
        q.response_im = im.data();
        q.frequency_hz = freq.data();
        q.target_db = target.data();
        q.seat_weight = &weight;
        q.eq_db = eq.data();
        q.eq_count = static_cast<uint32_t>(eq.size());
        q.target_error_weight = 1.0;
        q.seat_variance_weight = 1.5;
        q.eq_regularisation = 0.03;
        q.eq_smoothness = 0.08;
        q.max_slope_db_per_octave = 12.0;
        q.null_guard_db = 10.0;
        q.passes = 2;
        q.rounds = 8;
        q.evaluation_budget = 100000;
        n60_correct_multisub_eq_result x{}, y{};
        assert(n60_correct_multisub_eq_search(&q, &x) == N60_CORRECT_OK);
        assert(n60_correct_multisub_eq_search(&q, &y) == N60_CORRECT_OK);
        assert(std::memcmp(&x, &y, sizeof x) == 0);
        assert(eq[x.eq_index[0][2]] < -2.0 && eq[x.eq_index[0][0]] == 0.0);
        assert(x.budget_exhausted == 0u && x.evaluations > 0u);
        q.passes = 0;  // stage off: EQ stays at 0 dB
        assert(n60_correct_multisub_eq_search(&q, &y) == N60_CORRECT_OK && eq[y.eq_index[0][2]] == 0.0);
        q.passes = 2;
        q.evaluation_budget = 1;
        assert(n60_correct_multisub_eq_search(&q, &y) == N60_CORRECT_OK && y.budget_exhausted == 1u);
        assert(y.objective >= x.objective - 1.0e-12);
        q.eq_count = 0;
        assert(n60_correct_multisub_eq_search(&q, &y) == N60_CORRECT_ERR_ARGUMENT);
        assert(n60_correct_multisub_eq_search(nullptr, &y) == N60_CORRECT_ERR_ARGUMENT);
    }
    std::puts("correct multisub ok");
    return 0;
}
