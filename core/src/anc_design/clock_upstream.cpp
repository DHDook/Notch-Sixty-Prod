// E21 S10a: HAL sample-clock analysis and the upstream survey (n60/anc_design.h), ported from the Swift
// QuietZoneHALClockAnalyzer, QuietZoneUpstreamLeadEstimator and QuietZoneUpstreamAssessment.
//
// Clock analysis: a least-squares line through (host time, sample frame) per clock gives the measured rate and the worst
// timestamp residual; drift is the rate difference in ppm. Upstream lead: both channels are low-passed (Hann-windowed sinc,
// 400 Hz) and decimated to about 4 kHz with the same linear-phase FIR, then cross-correlated; the lead is the lag of the
// unbiased normalised correlation peak refined by a parabola. Control plane only: allocates, not thread-safe.
#include <cmath>
#include <cstring>

#include "design_common.hpp"

using namespace n60::anc_design;

namespace {

constexpr uint32_t kMinimumObservations = 8;
constexpr double kMinimumDuration = 2.0;
constexpr double kMaxRelativeDriftPPM = 100.0;
constexpr double kMaxNominalErrorPPM = 200.0;
constexpr double kMaxResidual = 0.0005;

struct Fit {
    double rate;
    double worstResidual;
};

int evaluate(const n60_anc_clock_observation *obs, uint32_t count, Fit &fit) {
    if (obs == nullptr || count < kMinimumObservations || count > 4096) return N60_ANC_CLOCK_ERR_INSUFFICIENT;
    const double firstTime = obs[0].hostTimeSeconds;
    const double firstFrame = obs[0].sampleFrame;
    if (!std::isfinite(firstTime) || !std::isfinite(firstFrame) || firstTime < 0 || firstFrame < 0)
        return N60_ANC_CLOCK_ERR_TIMEBASE;
    for (uint32_t i = 0; i < count; ++i) {
        if (!std::isfinite(obs[i].hostTimeSeconds) || !std::isfinite(obs[i].sampleFrame) || obs[i].hostTimeSeconds < 0 ||
            obs[i].sampleFrame < 0)
            return N60_ANC_CLOCK_ERR_TIMEBASE;
        if (i > 0 && !(obs[i].hostTimeSeconds > obs[i - 1].hostTimeSeconds && obs[i].sampleFrame > obs[i - 1].sampleFrame))
            return N60_ANC_CLOCK_ERR_DISCONTINUITY;
    }
    const double duration = obs[count - 1].hostTimeSeconds - firstTime;
    if (!(duration >= kMinimumDuration)) return N60_ANC_CLOCK_ERR_INSUFFICIENT;
    const double n = static_cast<double>(count);
    double sumT = 0, sumF = 0;
    for (uint32_t i = 0; i < count; ++i) {
        sumT += obs[i].hostTimeSeconds - firstTime;
        sumF += obs[i].sampleFrame - firstFrame;
    }
    const double meanT = sumT / n, meanF = sumF / n;
    double numerator = 0, denominator = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const double t = obs[i].hostTimeSeconds - firstTime, f = obs[i].sampleFrame - firstFrame;
        numerator += (t - meanT) * (f - meanF);
        denominator += (t - meanT) * (t - meanT);
    }
    if (!(denominator > 1.0e-12)) return N60_ANC_CLOCK_ERR_TIMEBASE;
    const double rate = numerator / denominator;
    const double intercept = meanF - rate * meanT;
    if (!std::isfinite(rate) || !(rate > 0)) return N60_ANC_CLOCK_ERR_TIMEBASE;
    double worst = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const double t = obs[i].hostTimeSeconds - firstTime, f = obs[i].sampleFrame - firstFrame;
        worst = std::max(worst, std::fabs(f - (intercept + rate * t)) / rate);
    }
    if (!std::isfinite(worst)) return N60_ANC_CLOCK_ERR_TIMEBASE;
    fit = Fit{rate, worst};
    return 0;
}

}  // namespace

extern "C" {

void n60_anc_clock_limits_get(n60_anc_clock_limits *o) {
    if (o == nullptr) return;
    o->minimumObservations = kMinimumObservations;
    o->minimumObservationDuration = kMinimumDuration;
    o->maximumRelativeDriftPPM = kMaxRelativeDriftPPM;
    o->maximumNominalRateErrorPPM = kMaxNominalErrorPPM;
    o->maximumWorstResidualSeconds = kMaxResidual;
}

int32_t n60_anc_hal_clock_analyze(double nominal, const n60_anc_clock_observation *input, uint32_t inputCount,
                                  const n60_anc_clock_observation *output, uint32_t outputCount, n60_anc_clock_health *health) {
    if (health == nullptr) return N60_ANC_DESIGN_ERR_ARGUMENT;
    if (!std::isfinite(nominal) || !(nominal >= 8000 && nominal <= 768000)) return N60_ANC_CLOCK_ERR_TIMEBASE;
    Fit in{}, outFit{};
    if (int e = evaluate(input, inputCount, in)) return e;
    if (int e = evaluate(output, outputCount, outFit)) return e;
    const double inputStart = input[0].hostTimeSeconds, outputStart = output[0].hostTimeSeconds;
    const double inputEnd = input[inputCount - 1].hostTimeSeconds, outputEnd = output[outputCount - 1].hostTimeSeconds;
    const double overlap = std::min(inputEnd, outputEnd) - std::max(inputStart, outputStart);
    if (!(overlap >= kMinimumDuration)) return N60_ANC_CLOCK_ERR_TIMEBASE;
    const double relative = std::fabs(in.rate - outFit.rate) / nominal * 1.0e6;
    const double inputOffset = std::fabs(in.rate - nominal) / nominal * 1.0e6;
    const double outputOffset = std::fabs(outFit.rate - nominal) / nominal * 1.0e6;
    if (!(in.worstResidual <= kMaxResidual) || !(outFit.worstResidual <= kMaxResidual)) return N60_ANC_CLOCK_ERR_JITTER;
    if (!(relative <= kMaxRelativeDriftPPM && inputOffset <= kMaxNominalErrorPPM && outputOffset <= kMaxNominalErrorPPM))
        return N60_ANC_CLOCK_ERR_DRIFT;
    health->measuredInputRateHz = in.rate;
    health->measuredOutputRateHz = outFit.rate;
    health->relativeDriftPPM = relative;
    health->worstInputResidualSeconds = in.worstResidual;
    health->worstOutputResidualSeconds = outFit.worstResidual;
    health->observationDurationSeconds = overlap;
    return N60_ANC_DESIGN_OK;
}

}  // extern "C"

// ---- Upstream lead estimator ----
namespace {

constexpr double kTargetRate = 4000.0;
constexpr double kCutoffHz = 400.0;
constexpr double kMaximumLagSeconds = 0.3;

// A growing float stream whose growth reports failure instead of throwing.
struct Stream {
    n60::NothrowArray<float> data;
    size_t count{0};
    size_t capacity{0};
    bool push(float v) {
        if (count == capacity) {
            const size_t next = capacity == 0 ? 8192 : capacity * 2;
            n60::NothrowArray<float> grown;
            if (!grown.allocate(next)) return false;
            for (size_t i = 0; i < count; ++i) grown[i] = data[i];
            data = std::move(grown);
            capacity = next;
        }
        data[count++] = v;
        return true;
    }
};

}  // namespace

struct n60_anc_upstream_lead_estimator {
    double sampleRate{0};
    uint32_t decimation{1};
    uint32_t length{0};
    n60::NothrowArray<float> taps, referenceRing, errorRing;
    uint32_t ringPosition{0};
    uint32_t sinceOutput{0};
    Stream reference, error;
};

extern "C" {

n60_anc_upstream_lead_estimator *n60_anc_upstream_lead_create(double sampleRate) {
    if (!std::isfinite(sampleRate) || !(sampleRate >= 1000 && sampleRate <= 768000)) return nullptr;
    auto *e = new (std::nothrow) n60_anc_upstream_lead_estimator();
    if (e == nullptr) return nullptr;
    e->sampleRate = sampleRate;
    e->decimation = static_cast<uint32_t>(std::max(1.0, std::round(sampleRate / kTargetRate)));
    e->length = 8 * e->decimation + 1;
    if (!e->taps.allocate(e->length) || !e->referenceRing.allocate(e->length) || !e->errorRing.allocate(e->length)) {
        delete e;
        return nullptr;
    }
    // Hann-windowed sinc, eight output periods long, unity DC gain.
    const double edge = kCutoffHz / sampleRate;
    const double centre = static_cast<double>(e->length - 1) / 2;
    n60::NothrowArray<double> h;
    if (!h.allocate(e->length)) {
        delete e;
        return nullptr;
    }
    double sum = 0;
    for (uint32_t n = 0; n < e->length; ++n) {
        const double t = static_cast<double>(n) - centre;
        const double sinc = t == 0 ? 2 * edge : std::sin(2 * kPi * edge * t) / (kPi * t);
        const double window = 0.5 - 0.5 * std::cos(2 * kPi * static_cast<double>(n) / static_cast<double>(e->length - 1));
        h[n] = sinc * window;
    }
    for (uint32_t n = 0; n < e->length; ++n) sum += h[n];
    for (uint32_t n = 0; n < e->length; ++n) e->taps[n] = static_cast<float>(h[n] / sum);
    return e;
}

void n60_anc_upstream_lead_destroy(n60_anc_upstream_lead_estimator *e) { delete e; }

void n60_anc_upstream_lead_mark_discontinuity(n60_anc_upstream_lead_estimator *e) {
    if (e == nullptr) return;
    for (uint32_t k = 0; k < e->length; ++k) e->referenceRing[k] = e->errorRing[k] = 0;
    e->ringPosition = 0;
    e->sinceOutput = 0;
}

int32_t n60_anc_upstream_lead_ingest(n60_anc_upstream_lead_estimator *e, const float *reference, const float *error,
                                     uint32_t frames) {
    if (e == nullptr || (frames > 0 && (reference == nullptr || error == nullptr))) return N60_ANC_DESIGN_ERR_ARGUMENT;
    const uint32_t length = e->length;
    for (uint32_t i = 0; i < frames; ++i) {
        e->referenceRing[e->ringPosition] = reference[i];
        e->errorRing[e->ringPosition] = error[i];
        e->ringPosition = (e->ringPosition + 1) % length;
        e->sinceOutput += 1;
        if (e->sinceOutput == e->decimation) {
            e->sinceOutput = 0;
            // ringPosition is the oldest sample; the taps are symmetric, so order does not matter.
            float r = 0, x = 0;
            uint32_t p = e->ringPosition;
            for (uint32_t k = 0; k < length; ++k) {
                r += e->taps[k] * e->referenceRing[p];
                x += e->taps[k] * e->errorRing[p];
                p += 1;
                if (p == length) p = 0;
            }
            if (!e->reference.push(r) || !e->error.push(x)) return N60_ANC_DESIGN_ERR_ALLOC;
        }
    }
    return N60_ANC_DESIGN_OK;
}

uint32_t n60_anc_upstream_lead_decimation(const n60_anc_upstream_lead_estimator *e) { return e ? e->decimation : 0; }
uint32_t n60_anc_upstream_lead_decimated_count(const n60_anc_upstream_lead_estimator *e) {
    return e ? static_cast<uint32_t>(e->reference.count) : 0;
}
uint32_t n60_anc_upstream_lead_decimated(const n60_anc_upstream_lead_estimator *e, float *reference, float *error,
                                         uint32_t capacity) {
    if (e == nullptr) return 0;
    const uint32_t n = static_cast<uint32_t>(e->reference.count);
    const uint32_t m = std::min(n, capacity);
    if (reference != nullptr && error != nullptr)
        for (uint32_t i = 0; i < m; ++i) {
            reference[i] = e->reference.data[i];
            error[i] = e->error.data[i];
        }
    return n;
}

int32_t n60_anc_upstream_lead_estimate(const n60_anc_upstream_lead_estimator *e, n60_anc_upstream_estimate *outEstimate) {
    if (e == nullptr || outEstimate == nullptr) return 0;
    const size_t n = e->reference.count;
    const double fs = e->sampleRate / static_cast<double>(e->decimation);
    if (n < static_cast<size_t>(2 * fs)) return 0;
    const long maxLag = std::min(static_cast<long>(kMaximumLagSeconds * fs), static_cast<long>(n / 4));
    n60::NothrowArray<double> x, d, r;
    if (!x.allocate(n) || !d.allocate(n) || !r.allocate(static_cast<size_t>(2 * maxLag + 1))) return 0;
    double meanX = 0, meanD = 0;
    for (size_t i = 0; i < n; ++i) {
        meanX += e->reference.data[i];
        meanD += e->error.data[i];
    }
    meanX /= static_cast<double>(n);
    meanD /= static_cast<double>(n);
    double xx = 0, dd = 0;
    for (size_t i = 0; i < n; ++i) {
        x[i] = e->reference.data[i] - meanX;
        d[i] = e->error.data[i] - meanD;
        xx += x[i] * x[i];
        dd += d[i] * d[i];
    }
    if (!(xx > 0) || !(dd > 0)) return 0;
    const double norm = std::sqrt(xx * dd);
    // r[k] = sum x[i] d[i + k]: d lags x by k. Unbiased in the overlap, so a long lag is not penalised.
    for (long k = -maxLag; k <= maxLag; ++k) {
        const long overlap = static_cast<long>(n) - std::labs(k);
        const double *xp = &x[0] + std::max(0L, -k);
        const double *dp = &d[0] + std::max(0L, k);
        double dot = 0;
        for (long i = 0; i < overlap; ++i) dot += xp[i] * dp[i];
        r[static_cast<size_t>(k + maxLag)] = dot / norm * static_cast<double>(n) / static_cast<double>(overlap);
    }
    const size_t count = static_cast<size_t>(2 * maxLag + 1);
    size_t peak = 0;
    for (size_t i = 1; i < count; ++i)
        if (r[peak] < r[i]) peak = i;
    double offset = 0;
    if (peak > 0 && peak < count - 1) {
        const double a = r[peak - 1], b = r[peak], c = r[peak + 1];
        const double denominator = a - 2 * b + c;
        if (denominator < 0) offset = std::min(std::max(0.5 * (a - c) / denominator, -0.5), 0.5);
    }
    outEstimate->leadSeconds = (static_cast<double>(static_cast<long>(peak) - maxLag) + offset) / fs;
    outEstimate->peakCorrelation = std::min(std::max(r[peak], 0.0), 1.0);
    outEstimate->resolutionSeconds = 0.5 / fs;
    return 1;
}

double n60_anc_upstream_reduction_bound_db(double coherence) {
    const double g = std::min(std::max(coherence, 0.0), 1.0);
    if (!(g < 1)) return 30.0;
    return std::min(-10 * std::log10(1 - g), 30.0);
}

void n60_anc_upstream_assess(const n60_anc_upstream_estimate *estimate, const n60_anc_upstream_survey_band *survey,
                             uint32_t surveyCount, double latencySeconds, double flightSeconds, double clockOffsetErrorSeconds,
                             n60_anc_upstream_survey_band *bandsOut, double *boundsOut, n60_anc_upstream_assessment *res) {
    if (res == nullptr) return;
    std::memset(res, 0, sizeof *res);
    uint32_t rows = 0;
    double coherenceSum = 0;
    for (uint32_t i = 0; i < surveyCount && survey != nullptr; ++i) {
        if (survey[i].frequencyHz >= 25.0 && survey[i].frequencyHz <= 150.0) {
            if (bandsOut != nullptr) bandsOut[rows] = survey[i];
            if (boundsOut != nullptr) boundsOut[rows] = n60_anc_upstream_reduction_bound_db(survey[i].coherence);
            ++rows;
        }
    }
    double boundSum = 0;
    for (uint32_t i = 0; i < rows && bandsOut != nullptr; ++i) {
        coherenceSum += bandsOut[i].coherence;
        if (boundsOut != nullptr) boundSum += boundsOut[i];
    }
    const double meanCoherence = rows == 0 ? 0 : coherenceSum / static_cast<double>(rows);
    const double budget = latencySeconds + flightSeconds + 0.001;
    const double lead = estimate != nullptr ? estimate->leadSeconds : 0;
    const double uncertainty = std::hypot(estimate != nullptr ? estimate->resolutionSeconds : 0, clockOffsetErrorSeconds);
    int32_t verdict = N60_ANC_UPSTREAM_SUITABLE;
    if (estimate != nullptr && estimate->peakCorrelation >= 0.2) {
        if (lead - uncertainty <= budget) verdict = N60_ANC_UPSTREAM_MOVE_FURTHER_OUT;
        else if (meanCoherence < 0.85) verdict = N60_ANC_UPSTREAM_LOW_COHERENCE;
    } else {
        verdict = N60_ANC_UPSTREAM_NO_COMMON_NOISE;
    }
    res->verdict = verdict;
    res->leadSeconds = lead;
    res->leadUncertaintySeconds = uncertainty;
    res->budgetSeconds = budget;
    res->meanCoherence = meanCoherence;
    res->bandCount = rows;
    if (verdict == N60_ANC_UPSTREAM_SUITABLE && rows > 0) {
        res->hasPrediction = 1;
        res->predictedReductionDB = boundSum / static_cast<double>(rows);
    }
}

}  // extern "C"
