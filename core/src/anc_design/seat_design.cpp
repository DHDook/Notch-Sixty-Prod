// E21 S10a: Quiet Zone virtual seat designer, rank-one bass conditioning and causal FIR compiler (n60/anc_design.h).
//
// Offline control-plane maths ported from the Swift QuietZoneVirtualSeatDesigner, BassPlantConditioning and
// QuietZoneCausalFIRCompiler with the same order of operations, so the Swift parity tests hold at 1e-9. Per band, the
// anti-noise weights solve h + Sl*Ul + Sr*Ur = 0 by damped minimum-energy least squares (Tikhonov, lambda = 3.5% of the
// actuator power); a joint peak and aggregate cap then scales the whole grid. The FIR compiler refits the complex weights
// with real causal taps by Tikhonov least squares with exponentially rising late-tap penalties (Nelson and Elliott,
// Active Control of Sound, ch. 6 and 7). No allocation on any audio path: this file is never called from a callback.
#include "design_common.hpp"

using namespace n60::anc_design;

extern "C" {

uint32_t n60_anc_design_abi_version(void) { return N60_ANC_DESIGN_ABI_VERSION; }

void n60_anc_seat_limits_get(n60_anc_seat_limits *o) {
    if (o == nullptr) return;
    o->minimumCoherence = kMinimumCoherence;
    o->maximumLeakageFraction = kMaximumLeakage;
    o->minimumModeledReductionDB = kMinimumReduction;
    o->minimumAuthority = kMinimumAuthority;
    o->minimumReserveSeconds = kMinimumReserve;
    o->firPeakGainLimit = kPeakGainLimit;
    o->firMaximumRelativeFitError = kMaxFitError;
    o->firMinimumSampleRate = kMinRate;
    o->firMaximumSampleRate = kMaxRate;
}

double n60_anc_bass_condition_db(n60_anc_complex a_, n60_anc_complex b_, n60_anc_complex c_, n60_anc_complex d_) {
    const C a = make(a_), b = make(b_), c = make(c_), d = make(d_);
    const double detMagnitude = mag(a * d - b * c);
    const double f = mag(a) * mag(a) + mag(b) * mag(b) + mag(c) * mag(c) + mag(d) * mag(d);
    if (!std::isfinite(f) || !(f > 0)) return INFINITY;
    if (!std::isfinite(detMagnitude) || !(detMagnitude > 1.0e-15 * f)) return INFINITY;
    const double root = std::sqrt(std::max(f * f - 4 * detMagnitude * detMagnitude, 0.0));
    const double sigmaMaxSquared = (f + root) / 2;
    return 10 * std::log10(sigmaMaxSquared * sigmaMaxSquared / (detMagnitude * detMagnitude));
}

int32_t n60_anc_bass_mode(double db, double *lambdaScale) {
    if (lambdaScale != nullptr) *lambdaScale = 1.0;
    if (!std::isfinite(db) || db < 0) return N60_ANC_BASS_COMMON;
    if (db > 20.0) return N60_ANC_BASS_COMMON;
    if (db > 10.0) {
        const double t = (db - 10.0) / (20.0 - 10.0);
        if (lambdaScale != nullptr) *lambdaScale = 1 + (10.0 - 1) * t;
        return N60_ANC_BASS_TIKHONOV;
    }
    return N60_ANC_BASS_FREE;
}

int32_t n60_anc_virtual_seat_design(const n60_anc_seat_band *bands, uint32_t bandCount, const n60_anc_seat_options *opt,
                                    n60_anc_seat_band_result *results, double *worstReductionDB,
                                    double *minimumCoherence) {
    if (bands == nullptr || opt == nullptr || results == nullptr || opt->structSize < sizeof(n60_anc_seat_options))
        return N60_ANC_DESIGN_ERR_ARGUMENT;
    if (!std::isfinite(opt->reserveSeconds) || !(opt->reserveSeconds >= kMinimumReserve)) return N60_ANC_SEAT_ERR_BUDGET;
    if (bandCount == 0 || bandCount > N60_ANC_DESIGN_MAX_BANDS) return N60_ANC_SEAT_ERR_MEASUREMENTS;
    const bool bass = opt->bassConditioning != 0;

    n60::NothrowArray<uint32_t> order;
    if (!sortedOrder(bands, bandCount, order)) return N60_ANC_DESIGN_ERR_ALLOC;

    for (uint32_t i = 0; i < bandCount; ++i) {
        const n60_anc_seat_band &band = bands[order[i]];
        const C comps[6] = {make(band.sourceToReference),         make(band.sourceToListener),
                            make(band.leftSecondaryAtListener),   make(band.rightSecondaryAtListener),
                            make(band.leftLeakageAtReference),    make(band.rightLeakageAtReference)};
        bool ok = std::isfinite(band.frequencyHz) && band.frequencyHz >= opt->minimumFrequencyHz &&
                  band.frequencyHz <= opt->maximumFrequencyHz &&
                  (i == 0 || band.frequencyHz > bands[order[i - 1]].frequencyHz + 0.01);
        for (const C &z : comps) ok = ok && finite(z);
        ok = ok && mag(comps[0]) > 1.0e-7 && mag(comps[1]) > 1.0e-7 && std::isfinite(band.measuredCoherence);
        if (!ok) return N60_ANC_SEAT_ERR_MODEL;
        if (!(band.measuredCoherence >= kMinimumCoherence) || !(band.measuredCoherence <= 1)) return N60_ANC_SEAT_ERR_COHERENCE;
    }

    n60::NothrowArray<C> dist, lw, rw;
    if (!dist.allocate(bandCount) || !lw.allocate(bandCount) || !rw.allocate(bandCount)) return N60_ANC_DESIGN_ERR_ALLOC;

    for (uint32_t i = 0; i < bandCount; ++i) {
        const n60_anc_seat_band &band = bands[order[i]];
        const C h = make(band.sourceToListener) / make(band.sourceToReference);
        const C left = make(band.leftSecondaryAtListener);
        const C right = make(band.rightSecondaryAtListener);
        const double authority = mag(left) * mag(left) + mag(right) * mag(right);
        if (!std::isfinite(authority) || !(authority > kMinimumAuthority)) return N60_ANC_SEAT_ERR_AUTHORITY;
        C l, r;
        Plant plant{N60_ANC_BASS_FREE, 1.0};
        if (bass) plant = assess(band);
        if (plant.mode == N60_ANC_BASS_COMMON) {
            const C summed = left + right;
            const double summedPower = mag(summed) * mag(summed);
            if (!std::isfinite(summedPower) || !(summedPower > kMinimumAuthority)) return N60_ANC_SEAT_ERR_AUTHORITY;
            const C weight = -(conj(summed) * h) / (summedPower + std::max(summedPower * 0.035, 1.0e-9));
            l = weight;
            r = weight;
        } else {
            double scale = 1.0;
            if (plant.mode == N60_ANC_BASS_TIKHONOV) scale = std::max(plant.scale, 1.0);
            const double lambda = std::max(authority * 0.035 * scale, 1.0e-9);
            l = -(conj(left) * h) / (authority + lambda);
            r = -(conj(right) * h) / (authority + lambda);
        }
        if (!finite(l) || !finite(r)) return N60_ANC_SEAT_ERR_MODEL;
        dist[i] = h;
        lw[i] = l;
        rw[i] = r;
    }

    double sumL = 0, sumR = 0, peakL = 0, peakR = 0;
    for (uint32_t i = 0; i < bandCount; ++i) {
        sumL += mag(lw[i]);
        sumR += mag(rw[i]);
        peakL = std::max(peakL, mag(lw[i]));
        peakR = std::max(peakR, mag(rw[i]));
    }
    const double capPerSource = std::pow(10.0, opt->maximumPerSourceTonePeakDBFS / 20);
    const double capAggregate = std::pow(10.0, opt->maximumAggregateSourcePeakDBFS / 20);
    const double peak = std::max(peakL, peakR);
    if (!std::isfinite(sumL) || !std::isfinite(sumR) || !std::isfinite(peak)) return N60_ANC_SEAT_ERR_MODEL;
    const double scale = std::min(std::min(1.0, capPerSource / std::max(peak, 1.0e-12)),
                                  std::min(capAggregate / std::max(sumL, 1.0e-12), capAggregate / std::max(sumR, 1.0e-12)));

    double worst = INFINITY;
    double minCoherence = INFINITY;
    for (uint32_t i = 0; i < bandCount; ++i) {
        const n60_anc_seat_band &band = bands[order[i]];
        const C leftFilter = lw[i] * scale;
        const C rightFilter = rw[i] * scale;
        const C response = dist[i] + make(band.leftSecondaryAtListener) * leftFilter +
                           make(band.rightSecondaryAtListener) * rightFilter;
        const double benefit = 20 * std::log10(mag(dist[i]) / std::max(mag(response), 1.0e-15));
        const C echo = make(band.leftLeakageAtReference) * leftFilter + make(band.rightLeakageAtReference) * rightFilter;
        const double fraction = mag(echo);
        if (!std::isfinite(benefit) || !std::isfinite(fraction)) return N60_ANC_SEAT_ERR_MODEL;
        if (!(fraction <= leakageLimit(band, bass, opt->pathChangeToleranceDB))) return N60_ANC_SEAT_ERR_LEAKAGE;
        if (!(benefit >= kMinimumReduction)) return N60_ANC_SEAT_ERR_BENEFIT;
        worst = std::min(worst, benefit);
        minCoherence = std::min(minCoherence, band.measuredCoherence);
        n60_anc_seat_band_result &res = results[i];
        res.frequencyHz = band.frequencyHz;
        res.disturbanceTransfer = out(dist[i]);
        res.leftFilter = out(leftFilter);
        res.rightFilter = out(rightFilter);
        res.predictedResidual = out(response);
        res.modeledReductionDB = benefit;
        res.predictedReferenceLeakageFraction = fraction;
    }
    if (worstReductionDB != nullptr) *worstReductionDB = worst;
    if (minimumCoherence != nullptr) *minimumCoherence = minCoherence;
    return N60_ANC_DESIGN_OK;
}

}  // extern "C"

