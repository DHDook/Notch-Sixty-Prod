// E7 S2: the control-plane resampler (n60/resample.h) at all 64 pairs of the eight standard rates.
//  - passband: a tone at 0.9 x the lower Nyquist keeps its amplitude within 0.01 dB;
//  - rejection: alias (down) and image (up) tones are at least kMinRejectionDb below the input tone;
//  - onset: an impulse delayed by D source frames peaks within one output frame of D * dst / src;
//  - tap count: ceil(in * dst / src); equal rates copy exactly;
//  - agrees with an independent double-precision reference of the documented formula to -120 dB;
//  - a batch equals the same signals resampled one by one; bad arguments return 0 and leave the output alone.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/resample.h"

namespace {
int failures = 0;
void check(bool ok, const char *what, double src, double dst, double value = 0.0) {
    if (!ok) { std::fprintf(stderr, "FAIL %s %.1f -> %.1f (%.6g)\n", what, src, dst, value); ++failures; }
}

const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
constexpr double kPi = 3.14159265358979323846;
constexpr double kMinRejectionDb = 100.0;

double i0(double x) {
    double sum = 1.0, term = 1.0, k = 1.0;
    while (term > 1e-14 * sum) { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1; }
    return sum;
}

// Amplitude of a sine at `freq` (Hz) in y[from, to), Kaiser (beta 16) windowed so far leakage is below -120 dB.
double toneAmplitude(const std::vector<float> &y, size_t from, size_t to, double freq, double rate) {
    const size_t n = to - from;
    double re = 0, im = 0, wsum = 0;
    const double i0b = i0(16.0);
    for (size_t k = 0; k < n; ++k) {
        const double r = 2.0 * (static_cast<double>(k) + 0.5) / static_cast<double>(n) - 1.0;
        const double w = i0(16.0 * std::sqrt(1.0 - r * r)) / i0b;
        const double ph = 2.0 * kPi * freq * static_cast<double>(from + k) / rate;
        re += w * y[from + k] * std::cos(ph);
        im -= w * y[from + k] * std::sin(ph);
        wsum += w;
    }
    return 2.0 * std::sqrt(re * re + im * im) / wsum;
}

std::vector<float> tone(double freq, double rate, size_t n) {
    std::vector<float> x(n);
    for (size_t i = 0; i < n; ++i) x[i] = static_cast<float>(std::sin(2.0 * kPi * freq * static_cast<double>(i) / rate + 0.3));
    return x;
}

// Independent reference of the documented formula, double precision throughout.
std::vector<double> reference(const std::vector<float> &x, double src, double dst, int quality) {
    const uint32_t outN = n60_resample_output_count(static_cast<uint32_t>(x.size()), src, dst);
    const double step = src / dst, c = 0.95 * (dst < src ? dst / src : 1.0), H = (quality ? 66.0 : 32.0) / c, beta = quality ? 10.2 : 8.6;
    std::vector<double> y(outN, 0.0);
    for (uint32_t j = 0; j < outN; ++j) {
        const double p = j * step;
        const long lo = std::max(0L, static_cast<long>(std::ceil(p - H)));
        const long hi = std::min(static_cast<long>(x.size()) - 1, static_cast<long>(std::floor(p + H)));
        double acc = 0;
        for (long k = lo; k <= hi; ++k) {
            const double d = p - k, a = c * d;
            const double s = std::fabs(a) < 1e-12 ? 1.0 : std::sin(kPi * a) / (kPi * a);
            const double r = d / H;
            acc += x[k] * c * s * (i0(beta * std::sqrt(std::max(0.0, 1 - r * r))) / i0(beta)) * step;
        }
        y[j] = acc;
    }
    return y;
}

void testPair(double src, double dst, int quality) {
    const double lowNyq = 0.5 * std::fmin(src, dst);
    const double c = 0.95 * (dst < src ? dst / src : 1.0);
    const double H = (quality ? 66.0 : 32.0) / c, step = src / dst;
    const size_t nIn = static_cast<size_t>(std::fmax(2048.0, std::ceil(3072.0 * src / dst)));
    const uint32_t nOut = n60_resample_output_count(static_cast<uint32_t>(nIn), src, dst);
    check(nOut == static_cast<uint32_t>(std::ceil(nIn * dst / src)), "tap count", src, dst, nOut);
    const size_t from = static_cast<size_t>(std::ceil((H + 8.0) / step)) + 4;
    
    const size_t to = nOut - from;

    // Passband: 0.9 x lower Nyquist.
    {
        // A tone gains src/dst (impulse-response semantics); the standard kernel is held to 0.01 dB at 0.8 x and 0.4 dB at 0.9 x.
        const double f = (quality ? 0.9 : 0.8) * lowNyq;
        std::vector<float> x = tone(f, src, nIn), y(nOut);
        check(n60_resample_batch(x.data(), static_cast<uint32_t>(nIn), 1, src, dst, quality, y.data(), y.size()) == 1, "run", src, dst);
        const double db = 20.0 * std::log10(toneAmplitude(y, from, to, f, dst) / step);
        check(std::fabs(db) < 0.01, quality ? "precise passband 0.01 dB at 0.9 Nyquist" : "standard passband 0.01 dB at 0.8 Nyquist", src, dst, db);
        if (!quality) {
            const double f9 = 0.9 * lowNyq;
            std::vector<float> x9 = tone(f9, src, nIn), y9(nOut);
            n60_resample_batch(x9.data(), static_cast<uint32_t>(nIn), 1, src, dst, quality, y9.data(), y9.size());
            const double d9 = 20.0 * std::log10(toneAmplitude(y9, from, to, f9, dst) / step);
            check(std::fabs(d9) < 0.4, "standard passband 0.4 dB at 0.9 Nyquist", src, dst, d9);
        }
    }
    // Rejection: alias tone (down) or image tone (up).
    if (std::fabs(src - dst) >= 0.5) {
        const double fractions[] = {0.40, 0.33, 0.27, 0.45};
        for (double fr : fractions) {
            double f, fObs;
            if (dst < src) {
                f = std::fmin(0.98 * 0.5 * src, 1.1 * lowNyq * (0.9 + fr * 0.1));     // above the lower Nyquist
                fObs = std::fabs(f - std::round(f / dst) * dst);
            } else {
                f = fr * 0.5 * src;
                const double img = src - f;
                fObs = std::fabs(img - std::round(img / dst) * dst);
            }
            if (std::fabs(fObs - f) < 0.02 * dst || fObs < 0.01 * dst) continue;
            std::vector<float> x = tone(f, src, nIn), y(nOut);
            n60_resample_batch(x.data(), static_cast<uint32_t>(nIn), 1, src, dst, quality, y.data(), y.size());
            const double db = 20.0 * std::log10(std::fmax(1e-30, toneAmplitude(y, from, to, fObs, dst) / step));
            check(db <= (quality ? -kMinRejectionDb : -75.0), dst < src ? (quality ? "precise alias rejection" : "standard alias rejection") : (quality ? "precise image rejection" : "standard image rejection"), src, dst, db);
            break;
        }
    }
    // Onset: impulse at D source frames.
    {
        const size_t D = 400;
        std::vector<float> x(2048, 0.0f), y(n60_resample_output_count(2048, src, dst));
        x[D] = 1.0f;
        n60_resample_batch(x.data(), 2048, 1, src, dst, quality, y.data(), y.size());
        size_t peak = 0;
        for (size_t i = 0; i < y.size(); ++i) if (std::fabs(y[i]) > std::fabs(y[peak])) peak = i;
        const double expect = D * dst / src;
        check(std::fabs(static_cast<double>(peak) - expect) <= 1.0, "onset within one frame", src, dst, static_cast<double>(peak) - expect);
    }
    // Agrees with the double reference to -120 dB (relative to the reference's peak).
    {
        std::vector<float> x(1024);
        for (size_t i = 0; i < x.size(); ++i) x[i] = static_cast<float>(std::sin(0.05 * i * i * 0.01) * std::exp(-0.004 * i));
        std::vector<float> y(n60_resample_output_count(1024, src, dst));
        n60_resample_batch(x.data(), 1024, 1, src, dst, quality, y.data(), y.size());
        if (std::fabs(src - dst) >= 0.5) {
            const std::vector<double> ref = reference(x, src, dst, quality);
            double peak = 0, err = 0;
            for (double v : ref) peak = std::fmax(peak, std::fabs(v));
            for (size_t i = 0; i < ref.size(); ++i) err = std::fmax(err, std::fabs(ref[i] - y[i]));
            check(err <= 1e-6 * peak, "reference -120 dB", src, dst, 20 * std::log10(err / peak));
        } else {
            check(std::memcmp(x.data(), y.data(), x.size() * sizeof(float)) == 0, "equal rate copies", src, dst);
        }
    }
    // Batch equals one by one.
    {
        std::vector<float> a(300), b(300);
        for (size_t i = 0; i < 300; ++i) { a[i] = static_cast<float>(std::sin(0.2 * i)); b[i] = static_cast<float>(std::cos(0.07 * i)); }
        std::vector<float> both(a), ya(n60_resample_output_count(300, src, dst)), yb(ya.size()), yboth(2 * ya.size());
        both.insert(both.end(), b.begin(), b.end());
        n60_resample_batch(a.data(), 300, 1, src, dst, quality, ya.data(), ya.size());
        n60_resample_batch(b.data(), 300, 1, src, dst, quality, yb.data(), yb.size());
        n60_resample_batch(both.data(), 300, 2, src, dst, quality, yboth.data(), yboth.size());
        check(std::memcmp(ya.data(), yboth.data(), ya.size() * sizeof(float)) == 0 &&
              std::memcmp(yb.data(), yboth.data() + ya.size(), yb.size() * sizeof(float)) == 0, "batch equals single", src, dst);
    }
}

void testBadArguments() {
    float x[4] = {1, 2, 3, 4}, y[16], marker[16];
    for (int i = 0; i < 16; ++i) y[i] = marker[i] = 7.0f;
    check(n60_resample_batch(nullptr, 4, 1, 48000, 96000, 1, y, 16) == 0, "null in", 0, 0);
    check(n60_resample_batch(x, 0, 1, 48000, 96000, 1, y, 16) == 0, "empty", 0, 0);
    check(n60_resample_batch(x, 4, 0, 48000, 96000, 1, y, 16) == 0, "no signals", 0, 0);
    check(n60_resample_batch(x, 4, 1, 0, 96000, 1, y, 16) == 0, "zero src rate", 0, 0);
    check(n60_resample_batch(x, 4, 1, 48000, NAN, 1, y, 16) == 0, "nan dst rate", 0, 0);
    check(n60_resample_batch(x, 4, 1, 48000, 96000, 1, y, 7) == 0, "capacity too small", 0, 0);
    check(std::memcmp(y, marker, sizeof y) == 0, "output untouched on failure", 0, 0);
    check(n60_resample_batch(x, 4, 1, 48000, 96000, 2, y, 16) == 0, "bad quality", 0, 0);
    check(n60_resample_output_count(4, 48000, 96000) == 8 && n60_resample_output_count(1, 96000, 44100) == 1 &&
          n60_resample_output_count(0, 48000, 96000) == 0 && n60_resample_output_count(5, 0, 96000) == 5, "output count", 0, 0);
}
}  // namespace

int main() {
    for (double src : kRates)
        for (double dst : kRates) { testPair(src, dst, N60_RESAMPLE_STANDARD); testPair(src, dst, N60_RESAMPLE_PRECISE); }
    testBadArguments();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("resample ok");
    return 0;
}
