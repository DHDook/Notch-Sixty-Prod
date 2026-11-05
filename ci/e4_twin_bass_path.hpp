/*
 * E26 S1: bass-path models for the acoustic-twin tests. Test code only; nothing in the product links it.
 *
 * Anti-noise enters before any bass split, so the path the anti-noise plays is feed -> split -> mains and sub ->
 * room. These two models stand for the split, and sum its outputs (equal unit paths to the listener) so a test can
 * measure the combined path from one feed. Specified in seconds and hertz, so a path is the same at every device rate.
 *
 *   downstreamSub: a receiver or a powered sub. Mono sum (L+R)/2 -> Linkwitz-Riley 4 low-pass -> delay -> gain ->
 *                  polarity. `mainsHighPass` false is an open pre-out (the mains stay full range, the app adds no
 *                  split); true is a calibrated LFE out whose mains are high-passed at the same crossover.
 *   appSplitter:   the stereo-session bus splitter: the same chain with the mains always high-passed.
 */
#ifndef E4_TWIN_BASS_PATH_HPP
#define E4_TWIN_BASS_PATH_HPP

#include <cmath>
#include <cstddef>
#include <vector>

namespace twin {

struct BassSplitConfig {
    double fs = 48000.0;
    double crossoverHz = 80.0;
    double subDelaySeconds = 0.0;
    double subGain = 1.0;
    bool subPolarityInverted = false;
    bool mainsHighPass = true;
};

class BassSplit {
public:
    struct Out { double left, right, sub; double sum() const { return left + right + sub; } };

    explicit BassSplit(const BassSplitConfig &c) : cfg_(c) {
        design(true, lp_[0]); design(true, lp_[1]);
        design(false, hpL_[0]); design(false, hpL_[1]);
        design(false, hpR_[0]); design(false, hpR_[1]);
        ring_.assign(static_cast<size_t>(c.subDelaySeconds * c.fs) + 4u, 0.0);
    }

    static BassSplit downstreamSub(const BassSplitConfig &c, bool mainsHighPass) {
        BassSplitConfig d = c;
        d.mainsHighPass = mainsHighPass;
        return BassSplit(d);
    }
    static BassSplit appSplitter(const BassSplitConfig &c) {
        BassSplitConfig d = c;
        d.mainsHighPass = true;
        return BassSplit(d);
    }

    Out step(double l, double r) {
        double sub = 0.5 * (l + r);
        sub = run(lp_[1], run(lp_[0], sub));
        ring_[head_] = sub;
        const double delayFrames = cfg_.subDelaySeconds * cfg_.fs;
        const size_t whole = static_cast<size_t>(delayFrames);
        const double frac = delayFrames - static_cast<double>(whole);
        const size_t n = ring_.size();
        const double a = ring_[(head_ + n - whole) % n];
        const double b = ring_[(head_ + n - whole - 1u) % n];
        head_ = (head_ + 1u) % n;
        double delayed = a + (b - a) * frac;
        delayed *= cfg_.subGain * (cfg_.subPolarityInverted ? -1.0 : 1.0);
        double ml = l, mr = r;
        if (cfg_.mainsHighPass) { ml = run(hpL_[1], run(hpL_[0], l)); mr = run(hpR_[1], run(hpR_[0], r)); }
        return {ml, mr, delayed};
    }

private:
    struct Bq { double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0; };

    void design(bool lowPass, Bq &q) const {
        const double w = 2.0 * 3.14159265358979323846 * cfg_.crossoverHz / cfg_.fs;
        const double cs = std::cos(w), alpha = std::sin(w) / (2.0 * 0.70710678118654752440);
        const double a0 = 1.0 + alpha;
        q.a1 = -2.0 * cs / a0;
        q.a2 = (1.0 - alpha) / a0;
        q.b0 = (lowPass ? (1.0 - cs) : (1.0 + cs)) / (2.0 * a0);
        q.b1 = (lowPass ? (1.0 - cs) : -(1.0 + cs)) / a0;
        q.b2 = q.b0;
    }
    static double run(Bq &q, double x) {
        const double y = q.b0 * x + q.z1;
        q.z1 = q.b1 * x - q.a1 * y + q.z2;
        q.z2 = q.b2 * x - q.a2 * y;
        return y;
    }

    BassSplitConfig cfg_;
    Bq lp_[2], hpL_[2], hpR_[2];
    std::vector<double> ring_;
    size_t head_ = 0;
};

}  // namespace twin

#endif
