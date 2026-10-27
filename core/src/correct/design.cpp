// Multi-seat room-correction design on the correction grid (E10 S1, design notes 2 and 3).
//
// Per seat: a frequency-dependent window (FDW) response by per-frequency windowed DFT, the
// minimum phase of its magnitude, and the excess phase after a linear-phase fit. Across seats:
// a weighted power-average magnitude, the weighted phase coherence R(f) and the correction
// -arg(sum w e^{j phi}) * g(R). Offline only; double precision; fixed summation order.
#include <algorithm>
#include <cmath>
#include <complex>

#include "common.hpp"
#include "../measure/offline_fft.hpp"

namespace {

using namespace n60::correct;
using Complex = std::complex<double>;

constexpr uint32_t kGrid = N60_CORRECT_GRID_POINTS;

bool isFiniteValue(double v) { return std::isfinite(v); }

bool validDesignParams(const n60_correct_design_params *p) {
    if (p == nullptr) return false;
    if (p->mode != N60_CORRECT_MODE_MIN_PHASE && p->mode != N60_CORRECT_MODE_MIXED_PHASE) return false;
    if (!isFiniteValue(p->correction_low_hz) || !isFiniteValue(p->correction_high_hz) || !(p->correction_low_hz >= 1.0) ||
        !(p->correction_high_hz > p->correction_low_hz)) {
        return false;
    }
    if (!isFiniteValue(p->smoothing_octaves) || p->smoothing_octaves < 0.0 || p->smoothing_octaves > 2.0) return false;
    if (!isFiniteValue(p->max_boost_db) || p->max_boost_db < 0.0 || p->max_boost_db > 30.0) return false;
    if (!isFiniteValue(p->max_cut_db) || p->max_cut_db < 0.0 || p->max_cut_db > 40.0) return false;
    if (!isFiniteValue(p->fdw_cycles_low) || !isFiniteValue(p->fdw_cycles_high) || p->fdw_cycles_low < 1.0 || p->fdw_cycles_high < 1.0 ||
        p->fdw_cycles_low > 60.0 || p->fdw_cycles_high > 60.0) {
        return false;
    }
    if (!isFiniteValue(p->fdw_knee_hz) || p->fdw_knee_hz < 20.0 || p->fdw_knee_hz > 19000.0) return false;
    if (!isFiniteValue(p->spread_threshold_db) || p->spread_threshold_db < 0.0) return false;
    if (!isFiniteValue(p->phase_limit_hz) || p->phase_limit_hz < 100.0 || p->phase_limit_hz > 2000.0) return false;
    if (!isFiniteValue(p->coherence_low) || !isFiniteValue(p->coherence_high) || p->coherence_low < 0.0 ||
        !(p->coherence_high > p->coherence_low) || p->coherence_high > 1.0) {
        return false;
    }
    if (p->target_points > 0) {
        if (p->target_frequencies_hz == nullptr || p->target_gain_db == nullptr) return false;
        for (uint32_t i = 0; i < p->target_points; ++i) {
            if (!isFiniteValue(p->target_frequencies_hz[i]) || !isFiniteValue(p->target_gain_db[i]) || !(p->target_frequencies_hz[i] > 0.0)) return false;
            if (i > 0 && !(p->target_frequencies_hz[i] > p->target_frequencies_hz[i - 1])) return false;
        }
    }
    return true;
}

bool validProblem(const n60_correct_problem *p, uint32_t channel) {
    if (p == nullptr || p->irs == nullptr) return false;
    if (!isFiniteValue(p->sample_rate) || p->sample_rate < 8000.0 || p->sample_rate > 768000.0) return false;
    if (p->channel_count == 0 || p->seat_count == 0 || channel >= p->channel_count || p->main_seat >= p->seat_count) return false;
    for (uint32_t s = 0; s < p->seat_count; ++s) {
        const n60_correct_seat_ir &ir = p->irs[static_cast<size_t>(channel) * p->seat_count + s];
        if (ir.ir == nullptr || ir.frames < 64 || !isFiniteValue(ir.arrival_frames) || ir.arrival_frames < 0.0 ||
            ir.arrival_frames >= static_cast<double>(ir.frames) || !isFiniteValue(ir.weight) || ir.weight < 0.0) {
            return false;
        }
    }
    return true;
}

const n60_correct_seat_ir &seatOf(const n60_correct_problem *p, uint32_t channel, uint32_t seat) {
    return p->irs[static_cast<size_t>(channel) * p->seat_count + seat];
}

// FDW cycles at a frequency: cycles_low at and below the knee, then log-linear to cycles_high at 20 kHz.
double windowCycles(const n60_correct_design_params &p, double hz) {
    if (hz <= p.fdw_knee_hz) return p.fdw_cycles_low;
    const double x = std::min(1.0, std::log(hz / p.fdw_knee_hz) / std::log(20000.0 / p.fdw_knee_hz));
    return p.fdw_cycles_low + (p.fdw_cycles_high - p.fdw_cycles_low) * x;
}

// Tukey (alpha 0.5) window on u in [-1, 1].
double tukey(double u) {
    const double a = std::fabs(u);
    if (a >= 1.0) return 0.0;
    if (a <= 0.5) return 1.0;
    return 0.5 * (1.0 + std::cos(kPi * (a - 0.5) / 0.5));
}

// Windowed DFT of the seat IR at every grid point. The window is a Tukey of `cycles` periods
// centred on the direct arrival. The phase keeps the absolute sample index, so it includes the
// pure delay of the arrival.
void fdwSeat(const n60_correct_seat_ir &seat, double fs, const n60_correct_design_params &p,
             std::vector<Complex> &response) {
    response.assign(kGrid, Complex(0.0, 0.0));
    const int64_t frames = static_cast<int64_t>(seat.frames);
    for (uint32_t g = 0; g < kGrid; ++g) {
        const double f = gridFrequency(g);
        if (f >= fs * 0.5) {  // above the measurement Nyquist: hold the last value so the log magnitude stays finite
            response[g] = g > 0 ? Complex(std::abs(response[g - 1]), 0.0) : Complex(1.0, 0.0);
            continue;
        }
        const double half = windowCycles(p, f) / f * fs * 0.5;  // half window in samples
        const int64_t n0 = std::max<int64_t>(0, static_cast<int64_t>(std::ceil(seat.arrival_frames - half)));
        const int64_t n1 = std::min<int64_t>(frames - 1, static_cast<int64_t>(std::floor(seat.arrival_frames + half)));
        const double omega = 2.0 * kPi * f / fs;
        const Complex step(std::cos(omega), -std::sin(omega));
        Complex rotor(1.0, 0.0);
        double re = 0.0, im = 0.0;
        for (int64_t n = n0; n <= n1; ++n) {
            if (((n - n0) & 1023) == 0) {
                const double ph = omega * static_cast<double>(n);
                rotor = Complex(std::cos(ph), -std::sin(ph));
            }
            const double w = tukey((static_cast<double>(n) - seat.arrival_frames) / half) * static_cast<double>(seat.ir[n]);
            re += w * rotor.real();
            im += w * rotor.imag();
            rotor *= step;
        }
        response[g] = Complex(re, im);
    }
}

// Minimum phase of the grid magnitudes, sampled back on the grid.
bool gridMinimumPhase(const std::vector<Complex> &response, double fs, std::vector<double> &phase_on_grid) {
    uint64_t n = nextPow2(static_cast<uint64_t>(fs));
    if (n < 32768) n = 32768;
    const uint64_t half = n / 2;
    std::vector<double> gridLog(kGrid);
    for (uint32_t g = 0; g < kGrid; ++g) gridLog[g] = std::log(std::max(std::abs(response[g]), 1e-12));
    std::vector<double> logMagnitude(half + 1);
    for (uint64_t k = 0; k <= half; ++k) {
        const double f = static_cast<double>(k) * fs / static_cast<double>(n);
        double x = f > 0.0 ? gridPosition(f) : 0.0;
        x = std::min(std::max(x, 0.0), static_cast<double>(kGrid - 1));
        const uint32_t lo = std::min<uint32_t>(static_cast<uint32_t>(std::floor(x)), kGrid - 2);
        const double fr = x - static_cast<double>(lo);
        logMagnitude[k] = gridLog[lo] + fr * (gridLog[lo + 1] - gridLog[lo]);
    }
    std::vector<double> bins;
    if (!minimumPhase(logMagnitude, n, bins)) return false;
    phase_on_grid.resize(kGrid);
    for (uint32_t g = 0; g < kGrid; ++g) {
        const double f = gridFrequency(g);
        const double position = f / fs * static_cast<double>(n);
        const uint64_t lo = std::min<uint64_t>(static_cast<uint64_t>(std::floor(position)), half - 1);
        const double fr = position - static_cast<double>(lo);
        phase_on_grid[g] = bins[lo] + fr * (bins[lo + 1] - bins[lo]);
    }
    return true;
}

// Excess phase (as unit phasors) of one seat from its FDW response.
bool excessPhasors(const std::vector<Complex> &response, double arrival_frames, double fs, std::vector<Complex> &phasors) {
    std::vector<double> minPhase;
    if (!gridMinimumPhase(response, fs, minPhase)) return false;
    const double t0 = arrival_frames / fs;
    std::vector<double> residual(kGrid, 0.0);
    for (uint32_t g = 0; g < kGrid; ++g) {
        const double w = 2.0 * kPi * gridFrequency(g);
        const double mag = std::abs(response[g]);
        Complex z = mag > 0.0 ? response[g] / mag : Complex(1.0, 0.0);
        z *= std::polar(1.0, w * t0 - minPhase[g]);
        residual[g] = std::atan2(z.imag(), z.real());
    }
    // Linear-phase fit 100 Hz .. 1 kHz: the delay that makes the residual phasors add up best
    // (a search, so a noisy or wrapped phase cannot mislead it), then the constant phase of that
    // sum. What remains is phase that no pure delay can explain.
    std::vector<Complex> unit(kGrid);
    std::vector<uint32_t> used;
    for (uint32_t g = 0; g < kGrid; ++g) {
        const double f = gridFrequency(g);
        unit[g] = std::polar(1.0, residual[g]);
        if (f >= 100.0 && f <= 1000.0) used.push_back(g);
    }
    auto coherenceAt = [&](double tau, Complex &sum) {
        sum = Complex(0.0, 0.0);
        for (uint32_t g : used) sum += unit[g] * std::polar(1.0, -2.0 * kPi * gridFrequency(g) * tau);
        return std::abs(sum);
    };
    double slopeDelay = 0.0, best = -1.0;
    Complex bestSum(1.0, 0.0), probe;
    for (int step = -150; step <= 150; ++step) {  // +-3 ms in 20 us steps
        const double tau = step * 20e-6;
        const double value = coherenceAt(tau, probe);
        if (value > best) { best = value; slopeDelay = tau; bestSum = probe; }
    }
    const double centre = slopeDelay;
    for (int step = -20; step <= 20; ++step) {  // refine in 1 us steps
        const double tau = centre + step * 1e-6;
        const double value = coherenceAt(tau, probe);
        if (value > best) { best = value; slopeDelay = tau; bestSum = probe; }
    }
    const double slope = 2.0 * kPi * slopeDelay;
    const double intercept = std::arg(bestSum);
    (void)best;
    phasors.resize(kGrid);
    for (uint32_t g = 0; g < kGrid; ++g) {
        const double w = 2.0 * kPi * gridFrequency(g);
        phasors[g] = std::polar(1.0, residual[g] - slope * w - intercept);
    }
    return true;
}

double octaveEdgeLow(double hz, double limit) {
    // 1 well below the limit, raised-cosine to 0 over the third octave ending at the limit.
    if (hz >= limit) return 0.0;
    const double x = std::log2(limit / hz) * 3.0;
    return x >= 1.0 ? 1.0 : 0.5 * (1.0 - std::cos(kPi * x));
}

}  // namespace

extern "C" {

void n60_correct_design_defaults(uint32_t mode, n60_correct_design_params *params) {
    if (params == nullptr) return;
    *params = n60_correct_design_params{};
    params->struct_size = sizeof(n60_correct_design_params);
    params->mode = mode;
    params->correction_low_hz = 20.0;
    params->correction_high_hz = 20000.0;
    params->smoothing_octaves = 1.0 / 6.0;
    params->max_boost_db = 6.0;
    params->max_cut_db = 12.0;
    params->fdw_cycles_low = 15.0;
    params->fdw_cycles_high = 5.0;
    params->fdw_knee_hz = 200.0;
    params->spread_threshold_db = 6.0;
    params->phase_limit_hz = 500.0;
    params->coherence_low = 0.6;
    params->coherence_high = 0.8;
}

int32_t n60_correct_fdw_response(const n60_correct_problem *problem, uint32_t channel, uint32_t seat,
                                 const n60_correct_design_params *params, double *real, double *imag,
                                 uint32_t capacity) {
    if (!validProblem(problem, channel) || !validDesignParams(params) || seat >= problem->seat_count || real == nullptr || imag == nullptr) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    if (capacity < kGrid) return N60_CORRECT_ERR_CAPACITY;
    std::vector<Complex> response;
    fdwSeat(seatOf(problem, channel, seat), problem->sample_rate, *params, response);
    for (uint32_t g = 0; g < kGrid; ++g) {
        real[g] = response[g].real();
        imag[g] = response[g].imag();
    }
    return N60_CORRECT_OK;
}

int32_t n60_correct_seat_excess_phase(const n60_correct_problem *problem, uint32_t channel, uint32_t seat,
                                      const n60_correct_design_params *params, double *phase_rad,
                                      uint32_t capacity) {
    if (!validProblem(problem, channel) || !validDesignParams(params) || seat >= problem->seat_count || phase_rad == nullptr) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    if (capacity < kGrid) return N60_CORRECT_ERR_CAPACITY;
    const n60_correct_seat_ir &ir = seatOf(problem, channel, seat);
    std::vector<Complex> response;
    fdwSeat(ir, problem->sample_rate, *params, response);
    std::vector<Complex> phasors;
    if (!excessPhasors(response, ir.arrival_frames, problem->sample_rate, phasors)) return N60_CORRECT_ERR_ALLOC;
    for (uint32_t g = 0; g < kGrid; ++g) phase_rad[g] = std::atan2(phasors[g].imag(), phasors[g].real());
    return N60_CORRECT_OK;
}

int32_t n60_correct_design_channel(const n60_correct_problem *problem, uint32_t channel,
                                   const n60_correct_design_params *params, n60_correct_design_grid *grid) {
    if (!validProblem(problem, channel) || !validDesignParams(params) || grid == nullptr ||
        grid->correction_db == nullptr || grid->correction_phase_rad == nullptr) {
        return N60_CORRECT_ERR_ARGUMENT;
    }
    const double fs = problem->sample_rate;
    const bool mixed = params->mode == N60_CORRECT_MODE_MIXED_PHASE;
    double weightSum = 0.0;
    for (uint32_t s = 0; s < problem->seat_count; ++s) weightSum += seatOf(problem, channel, s).weight;
    if (!(weightSum > 0.0)) return N60_CORRECT_ERR_ARGUMENT;

    const int halfWidth = static_cast<int>(std::lround(N60_CORRECT_GRID_PER_OCTAVE * params->smoothing_octaves * 0.5));
    std::vector<double> powerSum(kGrid, 0.0);
    std::vector<double> seatLow(kGrid, 1e300), seatHigh(kGrid, -1e300);
    std::vector<Complex> phasorSum(kGrid, Complex(0.0, 0.0));

    for (uint32_t s = 0; s < problem->seat_count; ++s) {
        const n60_correct_seat_ir &ir = seatOf(problem, channel, s);
        if (!(ir.weight > 0.0)) continue;
        std::vector<Complex> response;
        fdwSeat(ir, fs, *params, response);
        std::vector<double> power(kGrid);
        for (uint32_t g = 0; g < kGrid; ++g) power[g] = std::norm(response[g]);
        smoothPower(power, halfWidth);
        for (uint32_t g = 0; g < kGrid; ++g) {
            powerSum[g] += ir.weight * power[g];
            const double db = 10.0 * std::log10(std::max(power[g], 1e-24));
            seatLow[g] = std::min(seatLow[g], db);
            seatHigh[g] = std::max(seatHigh[g], db);
        }
        if (mixed) {
            std::vector<Complex> phasors;
            if (!excessPhasors(response, ir.arrival_frames, fs, phasors)) return N60_CORRECT_ERR_ALLOC;
            for (uint32_t g = 0; g < kGrid; ++g) phasorSum[g] += ir.weight * phasors[g];
        }
    }

    std::vector<double> measured(kGrid), spread(kGrid), raw(kGrid);
    for (uint32_t g = 0; g < kGrid; ++g) {
        measured[g] = 10.0 * std::log10(std::max(powerSum[g] / weightSum, 1e-24));
        spread[g] = seatHigh[g] - seatLow[g];
        const double f = gridFrequency(g);
        const double target = params->target_points > 0
            ? interpolateLogFrequency(params->target_frequencies_hz, params->target_gain_db, params->target_points, f,
                                      f < params->target_frequencies_hz[0] ? params->target_gain_db[0]
                                                                            : params->target_gain_db[params->target_points - 1])
            : 0.0;
        raw[g] = target - measured[g];
    }
    // Level reference: the mean correction over 500 Hz .. 2 kHz is zero, so the design shapes
    // the response without changing the overall level.
    double offset = 0.0, offsetCount = 0.0;
    for (uint32_t g = 0; g < kGrid; ++g) {
        const double f = gridFrequency(g);
        if (f >= 500.0 && f <= 2000.0) { offset += raw[g]; offsetCount += 1.0; }
    }
    if (offsetCount > 0.0) offset /= offsetCount;

    for (uint32_t g = 0; g < kGrid; ++g) {
        const double f = gridFrequency(g);
        // The boost limit falls linearly to a quarter of itself over 12 dB above the threshold.
        const double excess = std::max(0.0, spread[g] - params->spread_threshold_db);
        const double scale = std::max(0.25, 1.0 - 0.75 * excess / 12.0);
        const double boostLimit = params->max_boost_db * scale;
        double c = raw[g] - offset;
        c = std::min(std::max(c, -params->max_cut_db), boostLimit);
        const double edge = edgeWindow(f, params->correction_low_hz, std::min(params->correction_high_hz, 0.45 * fs));
        c *= edge;
        if (!isFiniteValue(c)) return N60_CORRECT_ERR_NONFINITE;
        grid->correction_db[g] = c;
        if (grid->measured_db != nullptr) grid->measured_db[g] = measured[g];
        if (grid->seat_spread_db != nullptr) grid->seat_spread_db[g] = spread[g];
        if (grid->boost_limit_db != nullptr) grid->boost_limit_db[g] = boostLimit;
    }

    // Phase: the correction removes the group delay of the mean excess phase where the seats agree
    // (weight g(R)), tapering to nothing at the phase limit. It is built by integrating that group
    // delay downward from the limit, so the correction is zero at and above the limit, has no
    // group-delay step where it stops, and holds its phase across stretches where the seats disagree.
    std::vector<double> phase(kGrid, 0.0), coherence(kGrid, 0.0);
    if (mixed) {
        std::vector<double> ramp(kGrid, 0.0), arg(kGrid, 0.0);
        double previous = 0.0;
        bool inRun = false;
        for (uint32_t g = 0; g < kGrid; ++g) {
            const Complex mean = phasorSum[g] / weightSum;
            const double r = std::abs(mean);
            coherence[g] = r;
            ramp[g] = std::min(1.0, std::max(0.0, (r - params->coherence_low) / (params->coherence_high - params->coherence_low)));
            if (ramp[g] <= 0.0) { inRun = false; continue; }
            double a = std::atan2(mean.imag(), mean.real());
            if (inRun) {
                while (a - previous > kPi) a -= 2.0 * kPi;
                while (a - previous < -kPi) a += 2.0 * kPi;
            }
            previous = a;
            inRun = true;
            arg[g] = a;
        }
        for (uint32_t g = kGrid - 1; g-- > 0;) {
            double value = phase[g + 1];
            if (ramp[g] > 0.0 && ramp[g + 1] > 0.0) {
                const double fMid = std::sqrt(gridFrequency(g) * gridFrequency(g + 1));
                const double weight = 0.5 * (ramp[g] + ramp[g + 1]) * octaveEdgeLow(fMid, params->phase_limit_hz) *
                                      edgeWindow(fMid, params->correction_low_hz, std::min(params->correction_high_hz, 0.45 * fs));
                value += weight * (arg[g + 1] - arg[g]);
            }
            if (!isFiniteValue(value)) return N60_CORRECT_ERR_NONFINITE;
            phase[g] = value;
        }
    }
    for (uint32_t g = 0; g < kGrid; ++g) {
        grid->correction_phase_rad[g] = phase[g];
        if (grid->coherence != nullptr) grid->coherence[g] = coherence[g];
    }
    return N60_CORRECT_OK;
}

int32_t n60_correct_default_seat_weights(uint32_t seat_count, uint32_t main_seat, double *weights, uint32_t capacity) {
    if (weights == nullptr || seat_count == 0) return N60_CORRECT_ERR_ARGUMENT;
    if (capacity < seat_count) return N60_CORRECT_ERR_CAPACITY;
    for (uint32_t s = 0; s < seat_count; ++s) weights[s] = s == main_seat ? 2.0 : 1.0;
    return N60_CORRECT_OK;
}

int32_t n60_correct_seat_coherence_contribution(const n60_correct_problem *problem, uint32_t channel,
                                                const n60_correct_design_params *params, double *contribution,
                                                uint32_t capacity) {
    if (!validProblem(problem, channel) || !validDesignParams(params) || contribution == nullptr) return N60_CORRECT_ERR_ARGUMENT;
    if (capacity < problem->seat_count) return N60_CORRECT_ERR_CAPACITY;
    const double fs = problem->sample_rate;
    double weightSum = 0.0;
    for (uint32_t s = 0; s < problem->seat_count; ++s) weightSum += std::max(0.0, seatOf(problem, channel, s).weight);
    if (!(weightSum > 0.0)) return N60_CORRECT_ERR_ARGUMENT;
    std::vector<std::vector<Complex>> phasors(problem->seat_count);
    std::vector<Complex> mean(kGrid, Complex(0.0, 0.0));
    for (uint32_t s = 0; s < problem->seat_count; ++s) {
        const n60_correct_seat_ir &ir = seatOf(problem, channel, s);
        if (!(ir.weight > 0.0)) continue;
        std::vector<Complex> response;
        fdwSeat(ir, fs, *params, response);
        if (!excessPhasors(response, ir.arrival_frames, fs, phasors[s])) return N60_CORRECT_ERR_ALLOC;
        for (uint32_t g = 0; g < kGrid; ++g) mean[g] += ir.weight * phasors[s][g];
    }
    std::vector<double> ramp(kGrid, 0.0);
    for (uint32_t g = 0; g < kGrid; ++g) {
        mean[g] /= weightSum;
        if (gridFrequency(g) >= params->phase_limit_hz) continue;
        ramp[g] = std::min(1.0, std::max(0.0, (std::abs(mean[g]) - params->coherence_low) / (params->coherence_high - params->coherence_low)));
    }
    for (uint32_t s = 0; s < problem->seat_count; ++s) {
        double sum = 0.0, norm = 0.0;
        if (!phasors[s].empty()) {
            for (uint32_t g = 0; g < kGrid; ++g) {
                if (!(ramp[g] > 0.0)) continue;
                const double m = std::abs(mean[g]);
                if (!(m > 0.0)) continue;
                sum += ramp[g] * (phasors[s][g] * std::conj(mean[g])).real() / m;
                norm += ramp[g];
            }
        }
        contribution[s] = norm > 0.0 ? sum / norm : 0.0;
    }
    return N60_CORRECT_OK;
}

int32_t n60_correct_latency_mode(uint32_t latency_mode, uint32_t *design_mode, double *budget_seconds) {
    uint32_t mode = N60_CORRECT_MODE_MIXED_PHASE;
    double budget = 0.0;
    switch (latency_mode) {
        case N60_CORRECT_LATENCY_VIDEO: mode = N60_CORRECT_MODE_MIN_PHASE; break;
        case N60_CORRECT_LATENCY_MUSIC_20MS: budget = 0.020; break;
        case N60_CORRECT_LATENCY_MUSIC_50MS: budget = 0.050; break;
        case N60_CORRECT_LATENCY_MUSIC_100MS: budget = 0.100; break;
        default: return N60_CORRECT_ERR_ARGUMENT;
    }
    if (design_mode != nullptr) *design_mode = mode;
    if (budget_seconds != nullptr) *budget_seconds = budget;
    return N60_CORRECT_OK;
}

uint32_t n60_correct_latency_mode_tap_count(uint32_t latency_mode, double sample_rate) {
    uint32_t mode = 0;
    double budget = 0.0;
    if (!(sample_rate > 0.0) || n60_correct_latency_mode(latency_mode, &mode, &budget) != N60_CORRECT_OK) return 0;
    const double tail = mode == N60_CORRECT_MODE_MIXED_PHASE ? 0.120 : 0.040;
    const double wanted = std::ceil((budget + tail) * sample_rate / 64.0) * 64.0;
    return static_cast<uint32_t>(std::min(wanted, static_cast<double>(N60_CORRECT_MAX_TAPS)));
}

}  // extern "C"
