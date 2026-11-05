/*
 * E26 S1: behavioural harness for the twin's bass-path models (ci/e4_twin_bass_path.hpp) at the eight standard rates:
 * delay in seconds, gain, polarity, the low-pass corner, the Linkwitz-Riley sum, and open pre-out versus
 * calibrated LFE out. These are the references every later E26 slice measures against.
 */
#include <cmath>
#include <cstdio>
#include <vector>

#include "e4_twin_bass_path.hpp"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;

// Steady amplitude of the summed output for a tone on the left feed only, measured by a single-bin DFT.
static double sumAmplitude(twin::BassSplit s, double rate, double hz, double *phaseOut = nullptr) {
    const size_t n = static_cast<size_t>(rate * 1.5), start = n / 2;
    double re = 0, im = 0;
    for (size_t i = 0; i < n; i++) {
        const double x = std::sin(2.0 * kPi * hz * static_cast<double>(i) / rate);
        const double y = s.step(x, 0.0).sum();
        if (i >= start) {
            re += y * std::cos(2.0 * kPi * hz * static_cast<double>(i) / rate);
            im += y * std::sin(2.0 * kPi * hz * static_cast<double>(i) / rate);
        }
    }
    const double span = static_cast<double>(n - start);
    if (phaseOut) *phaseOut = std::atan2(re, im);
    return 2.0 * std::sqrt(re * re + im * im) / span;
}

int main() {
    for (double rate : kRates) {
        twin::BassSplitConfig c;
        c.fs = rate;
        c.crossoverHz = 80.0;

        // Sub only (mains removed by measuring the sub output): a 20 Hz tone sums L and R to the mono half level.
        {
            twin::BassSplit s = twin::BassSplit::downstreamSub(c, false);
            double peak = 0;
            for (size_t i = 0; i < static_cast<size_t>(rate); i++) {
                const twin::BassSplit::Out o = s.step(std::sin(2.0 * kPi * 20.0 * static_cast<double>(i) / rate), 0.0);
                if (i > static_cast<size_t>(rate) / 2) peak = std::max(peak, std::fabs(o.sub));
            }
            CHECK(std::fabs(peak - 0.5) < 0.02, "rate %.0f: sub passes 20 Hz at half level (%.4f)", rate, peak);
        }
        // Corner: LR4 low-pass is -6 dB at the crossover.
        {
            twin::BassSplit s = twin::BassSplit::downstreamSub(c, false);
            double peak = 0;
            for (size_t i = 0; i < static_cast<size_t>(rate * 1.5); i++) {
                const twin::BassSplit::Out o = s.step(std::sin(2.0 * kPi * 80.0 * static_cast<double>(i) / rate), 0.0);
                if (i > static_cast<size_t>(rate)) peak = std::max(peak, std::fabs(o.sub));
            }
            CHECK(std::fabs(peak - 0.25) < 0.01, "rate %.0f: LR4 corner is -6 dB of the half level (%.4f)", rate, peak);
        }
        // Delay in seconds: the sub's impulse peak lands at the same time at every rate.
        {
            twin::BassSplitConfig d = c;
            d.subDelaySeconds = 0.010;
            twin::BassSplit s = twin::BassSplit::downstreamSub(d, false);
            twin::BassSplit ref = twin::BassSplit::downstreamSub(c, false);
            size_t pk = 0, pr = 0;
            double best = 0, bestRef = 0;
            for (size_t i = 0; i < static_cast<size_t>(rate * 0.2); i++) {
                const double x = i == 0 ? 1.0 : 0.0;
                const double v = std::fabs(s.step(x, x).sub), w = std::fabs(ref.step(x, x).sub);
                if (v > best) { best = v; pk = i; }
                if (w > bestRef) { bestRef = w; pr = i; }
            }
            const double shift = static_cast<double>(pk - pr) / rate;
            CHECK(std::fabs(shift - 0.010) < 1.5 / rate, "rate %.0f: sub delay is 10 ms (%.6f s)", rate, shift);
        }
        // Polarity flips the sub, and gain scales it.
        {
            twin::BassSplitConfig p = c;
            p.subPolarityInverted = true;
            p.subGain = 0.5;
            twin::BassSplit a = twin::BassSplit::downstreamSub(c, false);
            twin::BassSplit b = twin::BassSplit::downstreamSub(p, false);
            double dot = 0, na = 0, nb = 0;
            for (size_t i = 0; i < static_cast<size_t>(rate * 0.5); i++) {
                const double x = std::sin(2.0 * kPi * 30.0 * static_cast<double>(i) / rate);
                const double u = a.step(x, x).sub, v = b.step(x, x).sub;
                dot += u * v; na += u * u; nb += v * v;
            }
            CHECK(dot < 0 && std::fabs(std::sqrt(nb / na) - 0.5) < 1e-6, "rate %.0f: polarity and gain (%.4f)", rate,
                  std::sqrt(nb / na));
        }
        // The app splitter sums flat (LR4 complementary) away from the corner; an open pre-out keeps the mains full range.
        {
            const twin::BassSplit app = twin::BassSplit::appSplitter(c);
            const twin::BassSplit open = twin::BassSplit::downstreamSub(c, false);
            const twin::BassSplit lfe = twin::BassSplit::downstreamSub(c, true);
            // At 20 Hz both mains and sub carry the tone for open pre-out: left 1.0 plus sub up to 0.5.
            const double o = sumAmplitude(open, rate, 20.0);  // sub lags a little through the low-pass, so a bit under 1.5
            CHECK(o > 1.3 && o < 1.51, "rate %.0f: open pre-out adds the sub to full-range mains (%.4f)", rate, o);
            // Splitter and calibrated LFE out are the same split: the mains hold nothing at 20 Hz.
            const double a = sumAmplitude(app, rate, 20.0), l = sumAmplitude(lfe, rate, 20.0);
            CHECK(std::fabs(a - l) < 1e-9 && a < 0.55, "rate %.0f: splitter equals calibrated LFE out (%.4f vs %.4f)", rate, a, l);
        }
    }
    if (failures == 0) { std::puts("e26_bass_path: PASS"); return 0; }
    return 1;
}
