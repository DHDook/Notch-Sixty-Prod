// E21 S10a: causal FIR compiler (n60/anc_design.h), ported from the Swift QuietZoneCausalFIRCompiler with the same order of
// operations. Refits the complex per-band controls with real causal taps: Tikhonov least squares on the basis
// H(f) = sum h[n] exp(-j 2 pi f n / fs) with late taps penalised by 0.02 + 0.25 (n / (N-1))^2 (Nelson and Elliott, Active
// Control of Sound, ch. 6). In bands where the measured 2x2 plant is rank one the L and R taps are tied (weight 10) so the
// pair is one common-mode filter there. A preflight only: the result carries no deployment permission.
#include <cstring>

#include "design_common.hpp"

using namespace n60::anc_design;

namespace {

// Pivoted Gaussian elimination of `matrix x = rhs` (row-major size x size). Returns 0 or N60_ANC_FIR_ERR_RANK.
int solveSystem(double *matrix, double *rhs, double *solution, int size) {
    auto at = [&](int r, int c) -> double & { return matrix[static_cast<size_t>(r) * size + c]; };
    for (int k = 0; k < size; ++k) {
        int pivot = k;
        for (int row = k + 1; row < size; ++row)
            if (std::fabs(at(row, k)) > std::fabs(at(pivot, k))) pivot = row;
        if (!std::isfinite(at(pivot, k)) || !(std::fabs(at(pivot, k)) > 1.0e-12)) return N60_ANC_FIR_ERR_RANK;
        if (pivot != k) {
            for (int j = 0; j < size; ++j) std::swap(at(k, j), at(pivot, j));
            std::swap(rhs[k], rhs[pivot]);
        }
        const double d = at(k, k);
        for (int j = k; j < size; ++j) at(k, j) /= d;
        rhs[k] /= d;
        for (int row = k + 1; row < size; ++row) {
            const double s = at(row, k);
            if (s == 0) continue;
            for (int j = k; j < size; ++j) at(row, j) -= s * at(k, j);
            rhs[row] -= s * rhs[k];
        }
    }
    for (int i = size - 1; i >= 0; --i) {
        double x = rhs[i];
        for (int j = i + 1; j < size; ++j) x -= at(i, j) * solution[j];
        solution[i] = x;
    }
    return 0;
}

C firResponse(const double *taps, int count, double frequency, double sampleRate) {
    double re = 0, im = 0;
    const double omega = 2 * kPi * frequency / sampleRate;
    for (int i = 0; i < count; ++i) {
        const double angle = omega * static_cast<double>(i);
        re += taps[i] * std::cos(angle);
        im -= taps[i] * std::sin(angle);
    }
    return {re, im};
}

}  // namespace

extern "C" int32_t n60_anc_causal_fir_compile(const n60_anc_seat_band *bands, const n60_anc_seat_band_result *results,
                                              uint32_t bandCount, const n60_anc_fir_options *opt, n60_anc_fir_result *res) {
    if (bands == nullptr || results == nullptr || opt == nullptr || res == nullptr ||
        opt->structSize < sizeof(n60_anc_fir_options))
        return N60_ANC_DESIGN_ERR_ARGUMENT;
    const double rate = opt->sampleRate;
    if (!std::isfinite(rate) || !(rate >= kMinRate && rate <= kMaxRate) || opt->tapCount < 1 ||
        opt->tapCount > N60_ANC_DESIGN_MAX_TAPS || !std::isfinite(opt->reserveSeconds) ||
        !(opt->reserveSeconds >= kMinimumReserve))
        return N60_ANC_FIR_ERR_CLOCK;
    if (bandCount == 0 || bandCount > N60_ANC_DESIGN_MAX_BANDS) return N60_ANC_FIR_ERR_MODEL;
    const bool bass = opt->bassConditioning != 0;
    const int taps = static_cast<int>(opt->tapCount);
    const int count = static_cast<int>(bandCount);

    n60::NothrowArray<uint32_t> order, targetOrder;
    if (!sortedOrder(bands, bandCount, order) || !targetOrder.allocate(bandCount)) return N60_ANC_DESIGN_ERR_ALLOC;
    for (uint32_t i = 0; i < bandCount; ++i) targetOrder[i] = i;
    std::stable_sort(&targetOrder[0], &targetOrder[0] + bandCount,
                     [&](uint32_t x, uint32_t y) { return results[x].frequencyHz < results[y].frequencyHz; });

    n60::NothrowArray<double> basis, leftD, rightD;
    n60::NothrowArray<uint8_t> tied;
    if (!basis.allocate(static_cast<size_t>(2) * bandCount * taps) || !tied.allocate(bandCount) || !leftD.allocate(taps) ||
        !rightD.allocate(taps))
        return N60_ANC_DESIGN_ERR_ALLOC;
    bool anyTied = false;
    for (int i = 0; i < count; ++i) {
        const n60_anc_seat_band &m = bands[order[i]];
        const n60_anc_seat_band_result &t = results[targetOrder[i]];
        if (!std::isfinite(m.frequencyHz) || m.frequencyHz != t.frequencyHz || !std::isfinite(t.leftFilter.re) ||
            !std::isfinite(t.leftFilter.im) || !std::isfinite(t.rightFilter.re) || !std::isfinite(t.rightFilter.im))
            return N60_ANC_FIR_ERR_MODEL;
        tied[i] = (bass && assess(m).mode == N60_ANC_BASS_COMMON) ? 1 : 0;
        anyTied = anyTied || tied[i] != 0;
        const double omega = 2 * kPi * m.frequencyHz / rate;
        for (int n = 0; n < taps; ++n) {
            basis[static_cast<size_t>(2 * i) * taps + n] = std::cos(omega * static_cast<double>(n));
            basis[static_cast<size_t>(2 * i + 1) * taps + n] = -std::sin(omega * static_cast<double>(n));
        }
    }
    auto target = [&](int k) -> const n60_anc_seat_band_result & { return results[targetOrder[k]]; };
    auto bas = [&](int row, int n) { return basis[static_cast<size_t>(row) * taps + n]; };
    auto ridge = [&](int i) {
        const double late = static_cast<double>(i) / static_cast<double>(std::max(taps - 1, 1));
        return 0.02 + 0.25 * late * late;
    };

    const size_t size = anyTied ? static_cast<size_t>(2) * taps : static_cast<size_t>(taps);
    n60::NothrowArray<double> matrix, rhs, solution;
    if (!matrix.allocate(size * size) || !rhs.allocate(size) || !solution.allocate(size)) return N60_ANC_DESIGN_ERR_ALLOC;

    if (!anyTied) {
        for (int side = 0; side < 2; ++side) {
            for (int i = 0; i < taps; ++i) {
                for (int j = 0; j < taps; ++j) {
                    double value = 0;
                    for (int k = 0; k < 2 * count; ++k) value += bas(k, i) * bas(k, j);
                    matrix[static_cast<size_t>(i) * size + j] = value;
                }
                matrix[static_cast<size_t>(i) * size + i] += ridge(i);
                double acc = 0;
                for (int k = 0; k < count; ++k) {
                    const n60_anc_complex &d = side == 0 ? target(k).leftFilter : target(k).rightFilter;
                    acc += bas(2 * k, i) * d.re + bas(2 * k + 1, i) * d.im;
                }
                rhs[i] = acc;
            }
            if (solveSystem(&matrix[0], &rhs[0], &solution[0], taps) != 0) return N60_ANC_FIR_ERR_RANK;
            for (int i = 0; i < taps; ++i)
                if (!std::isfinite(solution[i])) return N60_ANC_FIR_ERR_RANK;
            double *dst = side == 0 ? &leftD[0] : &rightD[0];
            for (int i = 0; i < taps; ++i) dst[i] = solution[i];
        }
    } else {
        const double tieSquared = kTieWeight * kTieWeight;
        const int n2 = 2 * taps;
        for (int i = 0; i < taps; ++i) {
            for (int j = 0; j < taps; ++j) {
                double plain = 0, tie = 0;
                for (int k = 0; k < 2 * count; ++k) {
                    const double product = bas(k, i) * bas(k, j);
                    plain += product;
                    if (tied[k / 2]) tie += product;
                }
                tie *= tieSquared;
                matrix[static_cast<size_t>(i) * n2 + j] = plain + tie;
                matrix[static_cast<size_t>(taps + i) * n2 + taps + j] = plain + tie;
                matrix[static_cast<size_t>(i) * n2 + taps + j] = -tie;
                matrix[static_cast<size_t>(taps + i) * n2 + j] = -tie;
            }
            matrix[static_cast<size_t>(i) * n2 + i] += ridge(i);
            matrix[static_cast<size_t>(taps + i) * n2 + taps + i] += ridge(i);
            double accL = 0, accR = 0;
            for (int k = 0; k < count; ++k) {
                accL += bas(2 * k, i) * target(k).leftFilter.re + bas(2 * k + 1, i) * target(k).leftFilter.im;
                accR += bas(2 * k, i) * target(k).rightFilter.re + bas(2 * k + 1, i) * target(k).rightFilter.im;
            }
            rhs[i] = accL;
            rhs[taps + i] = accR;
        }
        if (solveSystem(&matrix[0], &rhs[0], &solution[0], n2) != 0) return N60_ANC_FIR_ERR_RANK;
        for (int i = 0; i < n2; ++i)
            if (!std::isfinite(solution[i])) return N60_ANC_FIR_ERR_RANK;
        for (int i = 0; i < taps; ++i) {
            leftD[i] = solution[i];
            rightD[i] = solution[taps + i];
        }
    }

    double boundL = 0, boundR = 0;
    for (int i = 0; i < taps; ++i) {
        boundL += std::fabs(leftD[i]);
        boundR += std::fabs(rightD[i]);
    }
    if (!(boundL <= kPeakGainLimit) || !(boundR <= kPeakGainLimit)) return N60_ANC_FIR_ERR_GAIN;

    double maxError = 0, worstReduction = INFINITY, maxEcho = 0;
    for (int i = 0; i < count; ++i) {
        const n60_anc_seat_band &m = bands[order[i]];
        const double f = m.frequencyHz;
        const C computedL = firResponse(&leftD[0], taps, f, rate);
        const C computedR = firResponse(&rightD[0], taps, f, rate);
        const C desiredL = make(target(i).leftFilter);
        const C desiredR = make(target(i).rightFilter);
        const double norm = std::max(mag(desiredL) + mag(desiredR), 1.0e-9);
        const double error = (mag(computedL - desiredL) + mag(computedR - desiredR)) / norm;
        if (!std::isfinite(error)) return N60_ANC_FIR_ERR_NONCAUSAL;
        maxError = std::max(maxError, error);
        if (tied[i]) {
            const double difference = mag(computedL - computedR);
            if (!(difference <= kTieTolerance * std::max(mag(computedL) + mag(computedR), 1.0e-9)))
                return N60_ANC_FIR_ERR_NONCAUSAL;
        }
        const C disturbance = make(target(i).disturbanceTransfer);
        const C predicted = disturbance + make(m.leftSecondaryAtListener) * computedL +
                            make(m.rightSecondaryAtListener) * computedR;
        const double benefit = 20 * std::log10(mag(disturbance) / std::max(mag(predicted), 1.0e-15));
        const double echo = mag(make(m.leftLeakageAtReference) * computedL + make(m.rightLeakageAtReference) * computedR);
        if (!(std::isfinite(benefit) && std::isfinite(echo) && benefit >= kMinimumReduction &&
              echo <= leakageLimit(m, bass, opt->pathChangeToleranceDB)))
            return N60_ANC_FIR_ERR_REDUCTION;
        maxEcho = std::max(maxEcho, echo);
        worstReduction = std::min(worstReduction, benefit);
    }
    if (!(maxError <= kMaxFitError)) return N60_ANC_FIR_ERR_NONCAUSAL;

    std::memset(res, 0, sizeof *res);
    for (int i = 0; i < taps; ++i) {
        res->leftTaps[i] = static_cast<float>(leftD[i]);
        res->rightTaps[i] = static_cast<float>(rightD[i]);
    }
    res->tapCount = opt->tapCount;
    res->worstPredictedReductionDB = worstReduction;
    res->maximumRelativeFitError = maxError;
    res->maximumReferenceEchoFraction = maxEcho;
    return N60_ANC_DESIGN_OK;
}
