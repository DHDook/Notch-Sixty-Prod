// EDT, T20, T30 and RT60 per octave and third-octave band (E11 S3, design note 9).
//
// Band filters: causal IEC 61260-1 base-10 bands, an order-3 Butterworth band-pass (three
// biquads, double) designed per rate by the bilinear transform with band-edge pre-warping and
// unity gain at the centre frequency. Decay: Lundeby et al. (1995) iterative noise-floor and
// truncation-point search on the band energy, then Schroeder (1965) backward integration with
// the extrapolated tail beyond the truncation point added back. EDT/T20/T30 are least-squares
// fits to the decay curve over 0..-10, -5..-25 and -5..-35 dB, scaled to 60 dB.
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <vector>

#include "n60/measure.h"

namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
using Complex = std::complex<double>;

struct Biquad {
    double b0 = 0, a1 = 0, a2 = 0;  // numerator b0 (1 - z^-2), denominator 1 + a1 z^-1 + a2 z^-2
    double s1 = 0, s2 = 0;
    double process(double x) {  // transposed direct form II
        const double y = b0 * x + s1;
        s1 = -a1 * y + s2;
        s2 = -b0 * x - a2 * y;
        return y;
    }
};

// Returns false when the band edges do not fit under Nyquist.
bool designBand(double fs, double centre, int bandsPerOctave, std::vector<Biquad> &out) {
    const double g = std::pow(10.0, 0.3);
    const double f1 = centre * std::pow(g, -1.0 / (2.0 * bandsPerOctave));
    const double f2 = centre * std::pow(g, 1.0 / (2.0 * bandsPerOctave));
    if (f2 >= 0.45 * fs) return false;
    const double w1 = std::tan(kPi * f1 / fs);
    const double w2 = std::tan(kPi * f2 / fs);
    const double w0sq = w1 * w2;
    const double bw = w2 - w1;
    // Order-3 Butterworth low-pass prototype poles in the left half plane.
    const Complex prototype[3] = {Complex(-1.0, 0.0), Complex(-0.5, 0.86602540378443865), Complex(-0.5, -0.86602540378443865)};
    out.clear();
    auto addPair = [&](Complex s) {  // s and its conjugate: one biquad
        const Complex z = (1.0 + s) / (1.0 - s);
        Biquad q;
        q.a1 = -2.0 * z.real();
        q.a2 = std::norm(z);
        q.b0 = 1.0;
        out.push_back(q);
    };
    // Real prototype pole: roots of s^2 - p bw s + w0sq are a conjugate pair.
    {
        const Complex p = prototype[0];
        const Complex root = std::sqrt(p * p * bw * bw - 4.0 * w0sq);
        addPair((p * bw + root) / 2.0);
    }
    // Complex prototype pole p (its conjugate adds the mirrored poles): two biquads.
    {
        const Complex p = prototype[1];
        const Complex root = std::sqrt(p * p * bw * bw - 4.0 * w0sq);
        addPair((p * bw + root) / 2.0);
        addPair((p * bw - root) / 2.0);
    }
    // Unity gain at the centre frequency.
    const double w = 2.0 * std::atan(std::sqrt(w0sq));
    const Complex zi = std::polar(1.0, -w);
    Complex response(1.0, 0.0);
    for (const Biquad &q : out) {
        const Complex num = q.b0 * (1.0 - zi * zi);
        const Complex den = 1.0 + q.a1 * zi + q.a2 * zi * zi;
        response *= num / den;
    }
    const double gain = std::abs(response);
    if (!(gain > 0) || !std::isfinite(gain)) return false;
    out[0].b0 /= gain;
    return true;
}

// Least-squares line through (x_i, y_i) for i in [a, b]; slope per sample.
bool fitLine(const std::vector<double> &y, size_t a, size_t b, double &slope, double &intercept) {
    if (b <= a) return false;
    const double n = static_cast<double>(b - a + 1);
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (size_t i = a; i <= b; ++i) {
        const double x = static_cast<double>(i);
        sx += x; sy += y[i]; sxx += x * x; sxy += x * y[i];
    }
    const double den = n * sxx - sx * sx;
    if (std::fabs(den) < 1e-12) return false;
    slope = (n * sxy - sx * sy) / den;
    intercept = (sy - slope * sx) / n;
    return true;
}

struct Decay {
    bool ok = false;
    double edt = 0, t20 = 0, t30 = 0, range = 0, noise = 0;
};

// energy[0] is the band peak. Returns decay times; zero where the range is insufficient.
Decay analyseEnergy(const std::vector<double> &energy, double fs, uint32_t &flags) {
    Decay d;
    const size_t n = energy.size();
    if (n < 64) { flags |= N60_MEASURE_DECAY_FLAG_NO_DECAY; return d; }
    double peak = 0;
    for (double e : energy) peak = std::max(peak, e);
    if (!(peak > 1e-300)) { flags |= N60_MEASURE_DECAY_FLAG_NO_DECAY; return d; }

    auto toDb = [](double e) { return 10.0 * std::log10(std::max(e, 1e-300)); };
    auto blockLevels = [&](size_t block, std::vector<double> &levels) {
        levels.clear();
        for (size_t i = 0; i + block <= n; i += block) {
            double sum = 0;
            for (size_t j = 0; j < block; ++j) sum += energy[i + j];
            levels.push_back(toDb(sum / static_cast<double>(block)));
        }
    };
    auto meanEnergy = [&](size_t a, size_t b) {
        double sum = 0;
        for (size_t i = a; i < b; ++i) sum += energy[i];
        return sum / static_cast<double>(std::max<size_t>(1, b - a));
    };

    // Lundeby iteration.
    size_t block = std::max<size_t>(4, static_cast<size_t>(0.01 * fs));
    double noiseDb = toDb(meanEnergy(n - std::max<size_t>(1, n / 10), n));
    double slope = 0, intercept = 0;  // dB per frame, dB at frame 0
    double crossing = static_cast<double>(n);
    std::vector<double> levels;
    bool haveLine = false;
    for (int iteration = 0; iteration < 8; ++iteration) {
        blockLevels(block, levels);
        if (levels.size() < 4) break;
        // Regression from the peak to the first block under noise + 8 dB.
        size_t last = levels.size() - 1;
        for (size_t i = 1; i < levels.size(); ++i) {
            if (levels[i] < noiseDb + 8.0) { last = i; break; }
        }
        if (last < 2) { last = std::min<size_t>(2, levels.size() - 1); }
        // Least-squares line against block-centre frame positions.
        double sx = 0, sy = 0, sxx = 0, sxy = 0;
        const double cnt = static_cast<double>(last + 1);
        for (size_t i = 0; i <= last; ++i) {
            const double x = (static_cast<double>(i) + 0.5) * static_cast<double>(block);
            sx += x; sy += levels[i]; sxx += x * x; sxy += x * levels[i];
        }
        const double den = cnt * sxx - sx * sx;
        if (std::fabs(den) < 1e-12) break;
        const double b = (cnt * sxy - sx * sy) / den;
        const double a = (sy - b * sx) / cnt;
        if (!(b < 0)) { haveLine = false; break; }
        slope = b; intercept = a; haveLine = true;
        crossing = (noiseDb - intercept) / slope;
        // New block length: about five blocks per 10 dB of decay.
        const size_t newBlock = std::max<size_t>(4, static_cast<size_t>(10.0 / (-slope) / 5.0));
        // Noise: mean energy after the crossing point (plus a 5 dB safety), else the last tenth.
        const double safety = 5.0 / (-slope);
        const double start = crossing + safety;
        double newNoiseDb = noiseDb;
        if (start < static_cast<double>(n) * 0.95) {
            newNoiseDb = toDb(meanEnergy(static_cast<size_t>(std::max(0.0, start)), n));
        } else {
            newNoiseDb = toDb(meanEnergy(n - std::max<size_t>(1, n / 10), n));
        }
        const bool settled = std::fabs(newNoiseDb - noiseDb) < 0.2 && newBlock == block;
        noiseDb = newNoiseDb;
        block = newBlock;
        if (settled) break;
    }
    if (!haveLine) { flags |= N60_MEASURE_DECAY_FLAG_NO_DECAY; return d; }
    crossing = (noiseDb - intercept) / slope;
    // Truncation point: where the fitted line meets the noise floor, no later than the data end.
    size_t truncation = static_cast<size_t>(std::max(8.0, std::min(crossing, static_cast<double>(n) - 1.0)));
    // Tail beyond the truncation: the fitted line extrapolated to infinity, integrated.
    const double lineEnergyAtTruncation = std::pow(10.0, (intercept + slope * static_cast<double>(truncation)) / 10.0);
    const double perFrame = -slope * std::log(10.0) / 10.0;  // 1/frames
    const double tail = lineEnergyAtTruncation / perFrame;

    std::vector<double> curve(truncation + 1);
    double running = tail;
    for (size_t i = truncation + 1; i-- > 0;) {
        running += energy[i];
        curve[i] = running;
    }
    const double total = curve[0];
    for (double &c : curve) c = toDb(c / total);
    d.range = -curve[truncation];
    d.noise = noiseDb - toDb(peak);
    d.ok = true;

    auto firstBelow = [&](double level) -> long {
        for (size_t i = 0; i <= truncation; ++i) if (curve[i] <= level) return static_cast<long>(i);
        return -1;
    };
    auto decayTime = [&](double upper, double lower) -> double {
        const long a = firstBelow(upper);
        const long b = firstBelow(lower);
        if (a < 0 || b < 0 || b <= a + 1) return 0.0;
        double m = 0, c = 0;
        if (!fitLine(curve, static_cast<size_t>(a), static_cast<size_t>(b), m, c) || !(m < 0)) return 0.0;
        return 60.0 / (-m * fs);
    };
    // EDT starts at the curve's first point (0 dB), not at the first sample under it.
    {
        const long b = firstBelow(-10.0);
        double m = 0, c = 0;
        if (d.range >= 10.0 && b > 1 && fitLine(curve, 0, static_cast<size_t>(b), m, c) && m < 0) d.edt = 60.0 / (-m * fs);
    }
    if (d.range >= 25.0) d.t20 = decayTime(-5.0, -25.0);
    if (d.range >= 35.0) d.t30 = decayTime(-5.0, -35.0);
    if (d.range < 10.0) flags |= N60_MEASURE_DECAY_FLAG_EDT_RANGE;
    if (d.range < 25.0) flags |= N60_MEASURE_DECAY_FLAG_T20_RANGE;
    if (d.range < 35.0) flags |= N60_MEASURE_DECAY_FLAG_T30_RANGE;
    return d;
}

}  // namespace

extern "C" {

int32_t n60_measure_decay_analyze(const float *ir, uint64_t count, double sample_rate, uint32_t bands_per_octave,
                                  double min_centre_hz, double max_centre_hz, n60_measure_decay_band *bands,
                                  uint32_t capacity, uint32_t *band_count) {
    if (ir == nullptr || bands == nullptr || band_count == nullptr || !std::isfinite(sample_rate) ||
        sample_rate < 8000 || sample_rate > 768000 || (bands_per_octave != 1 && bands_per_octave != 3) ||
        !(min_centre_hz > 0) || !(max_centre_hz >= min_centre_hz) || count < 256) {
        return N60_MEASURE_ERR_ARGUMENT;
    }
    // Start at the direct arrival: the largest |sample|.
    uint64_t peak = 0;
    double best = -1.0;
    for (uint64_t i = 0; i < count; ++i) {
        const double a = std::fabs(static_cast<double>(ir[i]));
        if (a > best) { best = a; peak = i; }
    }
    uint32_t produced = 0;
    const int step = bands_per_octave == 1 ? 3 : 1;  // index n of 1000 * 10^(0.1 n)
    for (int index = -12; index <= 9; index += step) {
        const double centre = 1000.0 * std::pow(10.0, 0.1 * index);
        if (centre < min_centre_hz * 0.99 || centre > max_centre_hz * 1.01) continue;
        std::vector<Biquad> filter;
        if (!designBand(sample_rate, centre, static_cast<int>(bands_per_octave), filter)) continue;
        if (produced >= capacity) return N60_MEASURE_ERR_CAPACITY;
        std::vector<double> energy;
        energy.reserve(count - peak);
        for (uint64_t i = 0; i < count; ++i) {
            double v = ir[i];
            for (Biquad &q : filter) v = q.process(v);
            if (i >= peak) energy.push_back(v * v);
        }
        n60_measure_decay_band band{};
        band.centre_hz = centre;
        // Start at the band's own peak: the filter delays the arrival by its group delay.
        size_t start = 0;
        {
            const size_t smooth = std::max<size_t>(1, static_cast<size_t>(0.002 * sample_rate));
            double bestSum = -1.0;
            double sum = 0.0;
            for (size_t i = 0; i < energy.size(); ++i) {
                sum += energy[i];
                if (i >= smooth) sum -= energy[i - smooth];
                if (sum > bestSum) { bestSum = sum; start = i >= smooth ? i - smooth + 1 : 0; }
                if (i > static_cast<size_t>(0.2 * sample_rate)) break;
            }
        }
        std::vector<double> tail(energy.begin() + static_cast<std::ptrdiff_t>(start), energy.end());
        const Decay d = analyseEnergy(tail, sample_rate, band.flags);
        if (d.ok) {
            band.edt_seconds = d.edt;
            band.t20_seconds = d.t20;
            band.t30_seconds = d.t30;
            band.rt60_seconds = d.t30 > 0 ? d.t30 : (d.t20 > 0 ? d.t20 : d.edt);
            band.decay_range_db = d.range;
            band.noise_floor_db = d.noise;
        }
        bands[produced++] = band;
    }
    *band_count = produced;
    return N60_MEASURE_OK;
}

}  // extern "C"
