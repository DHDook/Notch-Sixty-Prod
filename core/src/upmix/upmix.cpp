// E14 S1: stereo upmix engine. Design note: docs/epics/E14.md (S1 design note).
//
// Per STFT bin the smoothed 2 x 2 covariance C = E[X X^H] of (L, R) has eigenvalues l1 >= l2. The principal eigenvector
// v = (cos t, sin t e^{-j phi}) (t the pan angle, phi the phase of E[L R*]) gives the primary component S = v^H X; the
// part of X orthogonal to v is ambience. The primary is re-panned over L, C, R (pairwise constant power, Pulkki 1997); the
// ambience goes to the surrounds and heights through per-speaker seeded decorrelators. Principal-component
// primary/ambient decomposition: Goodwin and Jot, "Primary-ambient signal decomposition and vector-based localization for
// spatial audio coding and enhancement", ICASSP 2007; frequency-domain upmix: Avendano and Jot, JAES 52(7/8), 2004;
// correlation-based ambience: Merimaa, Goodwin and Jot, AES 123rd Convention, 2007.
#include "upmix.hpp"

#include <cmath>
#include <cstring>
#include <new>

#include "../fft.hpp"

namespace n60::upmix {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kSmoothSeconds = 0.25;   // statistics time constant
constexpr double kRampSeconds = 0.05;     // strength ramp time constant
constexpr double kWarmSeconds = 0.3;      // strength fades in over this much programme after a reset
constexpr float kRhoLow = 0.5f;          // coherence below this: no primary is extracted
constexpr float kRhoHigh = 0.9f;         // coherence above this: the whole principal component is primary
constexpr float kSilenceFrame = 1e-10f;   // mean frame power (about -100 dBFS) below which warm-up does not advance

uint32_t roundUp4(uint32_t v) { return (v + 3u) & ~3u; }

uint32_t xorshift(uint32_t &s) {
    s ^= s << 13;
    s ^= s >> 17;
    s ^= s << 5;
    return s;
}

bool isLeftAmbient(uint32_t r) {
    return r == N60_ROLE_SIDE_LEFT || r == N60_ROLE_REAR_LEFT || r == N60_ROLE_WIDE_LEFT ||
           r == N60_ROLE_TOP_FRONT_LEFT || r == N60_ROLE_TOP_MIDDLE_LEFT || r == N60_ROLE_TOP_REAR_LEFT;
}
bool isRightAmbient(uint32_t r) {
    return r == N60_ROLE_SIDE_RIGHT || r == N60_ROLE_REAR_RIGHT || r == N60_ROLE_WIDE_RIGHT ||
           r == N60_ROLE_TOP_FRONT_RIGHT || r == N60_ROLE_TOP_MIDDLE_RIGHT || r == N60_ROLE_TOP_REAR_RIGHT;
}

}  // namespace

uint32_t Engine::frameLengthFor(double sampleRate) {
    if (!(sampleRate >= 8000.0 && sampleRate <= 768000.0)) return 0;
    const int e = static_cast<int>(std::lround(std::log2(sampleRate / 48000.0)));
    const int clamped = e < -3 ? -3 : (e > 4 ? 4 : e);
    return clamped >= 0 ? (1024u << clamped) : (1024u >> -clamped);
}

bool Engine::init(const n60_upmix_config &cfg) {
    n_ = 0;
    if (cfg.structSize != sizeof(n60_upmix_config) || cfg.channelCount < 2 || cfg.channelCount > N60_LAYOUT_MAX_CHANNELS) return false;
    const uint32_t n = frameLengthFor(cfg.sampleRate);
    if (n == 0) return false;
    laneFl_ = laneFr_ = laneC_ = -1;
    leftCount_ = rightCount_ = 0;
    uint32_t seen = 0;
    for (uint32_t c = 0; c < cfg.channelCount; ++c) {
        const uint32_t r = cfg.roles[c];
        if (r == N60_ROLE_UNUSED || r >= 32u) continue;
        if (seen & (1u << r)) return false;  // duplicate role
        seen |= 1u << r;
        if (r == N60_ROLE_FRONT_LEFT) laneFl_ = static_cast<int32_t>(c);
        else if (r == N60_ROLE_FRONT_RIGHT) laneFr_ = static_cast<int32_t>(c);
        else if (r == N60_ROLE_FRONT_CENTER) laneC_ = static_cast<int32_t>(c);
        else if (isLeftAmbient(r)) {
            if (leftCount_ >= kMaxAmbientPerSide) return false;
            left_[leftCount_].lane = c;
            ++leftCount_;
        } else if (isRightAmbient(r)) {
            if (rightCount_ >= kMaxAmbientPerSide) return false;
            right_[rightCount_].lane = c;
            ++rightCount_;
        }
    }
    if (laneFl_ < 0 || laneFr_ < 0) return false;

    // Decorrelator delays (seeded) and total arena size.
    static const double kLo[kDecorStages] = {1.3, 3.1, 5.3, 8.2};
    static const double kHi[kDecorStages] = {3.0, 5.2, 8.0, 12.0};
    uint32_t decorFloats = 0;
    auto planDecor = [&](Decor &d, uint32_t role) {
        uint32_t s = (cfg.seed * 2654435761u) ^ ((role + 1u) * 0x9E3779B1u);
        if (s == 0) s = 0x1234567u;
        for (uint32_t i = 0; i < kDecorStages; ++i) {
            const double u1 = (xorshift(s) >> 8) / 16777216.0;
            const double u2 = (xorshift(s) >> 8) / 16777216.0;
            const double ms = kLo[i] + (kHi[i] - kLo[i]) * u1;
            uint32_t dl = static_cast<uint32_t>(std::lround(cfg.sampleRate * ms / 1000.0));
            d.delay[i] = dl < 2 ? 2 : dl;
            d.g[i] = static_cast<float>((i & 1u ? -1.0 : 1.0) * (0.45 + 0.15 * u2));
            decorFloats += roundUp4(d.delay[i]);
        }
    };
    uint32_t li = 0, ri = 0;
    for (uint32_t c = 0; c < cfg.channelCount; ++c) {
        if (isLeftAmbient(cfg.roles[c])) planDecor(left_[li++], cfg.roles[c]);
        else if (isRightAmbient(cfg.roles[c])) planDecor(right_[ri++], cfg.roles[c]);
    }

    const uint32_t bins = n / 2 + 1;
    const uint32_t planFloats = roundUp4(static_cast<uint32_t>((fft::realPlanBytes(n) + 3) / 4));
    const uint32_t total = planFloats + 2 * roundUp4(n) + 2 * roundUp4(n) /* windows, rings */ +
                           2 * roundUp4(n + 2) + 5 * roundUp4(n + 2) + 5 * roundUp4(n) + 5 * roundUp4(n) +
                           4 * roundUp4(bins) + decorFloats + 64;
    if (!arena_.allocate(total)) return false;
    uint32_t off = 0;
    auto take = [&](uint32_t count) {
        float *p = &arena_[off];
        off += roundUp4(count);
        return p;
    };
    plan_ = take(planFloats);
    if (!fft::realPlanInit(plan_, n)) return false;
    inL_ = take(n);
    inR_ = take(n);
    wnd_ = take(n);
    synth_ = take(n);
    specL_ = take(n + 2);
    specR_ = take(n + 2);
    for (int j = 0; j < 5; ++j) out_[j] = take(n + 2);
    for (int j = 0; j < 5; ++j) ola_[j] = take(n);
    for (int j = 0; j < 5; ++j) fifo_[j] = take(n);
    pll_ = take(bins);
    prr_ = take(bins);
    plrRe_ = take(bins);
    plrIm_ = take(bins);
    for (uint32_t i = 0; i < leftCount_; ++i)
        for (uint32_t s = 0; s < kDecorStages; ++s) left_[i].buf[s] = take(left_[i].delay[s]);
    for (uint32_t i = 0; i < rightCount_; ++i)
        for (uint32_t s = 0; s < kDecorStages; ++s) right_[i].buf[s] = take(right_[i].delay[s]);

    n_ = n;
    hop_ = n / 4;
    bins_ = bins;
    channels_ = cfg.channelCount;
    fs_ = cfg.sampleRate;
    const double kmax = std::floor(N60_UPMIX_MAX_HZ / (fs_ / n));
    kMax_ = kmax > bins - 1 ? bins - 1 : static_cast<uint32_t>(kmax);
    smoothA_ = static_cast<float>(std::exp(-static_cast<double>(hop_) / (fs_ * kSmoothSeconds)));
    strengthA_ = static_cast<float>(1.0 - std::exp(-static_cast<double>(hop_) / (fs_ * kRampSeconds)));
    warmNeeded_ = static_cast<uint32_t>(std::ceil(kWarmSeconds * fs_ / hop_));
    leftGain_ = leftCount_ ? static_cast<float>(1.0 / std::sqrt(static_cast<double>(leftCount_))) : 0.0f;
    rightGain_ = rightCount_ ? static_cast<float>(1.0 / std::sqrt(static_cast<double>(rightCount_))) : 0.0f;
    // sqrt(Hann) analysis and synthesis; periodic Hann at hop n/4 sums to 2, folded into the synthesis window.
    for (uint32_t i = 0; i < n; ++i) {
        const double h = 0.5 * (1.0 - std::cos(2.0 * kPi * i / n));
        wnd_[i] = static_cast<float>(std::sqrt(h));
        synth_[i] = static_cast<float>(0.5 * std::sqrt(h));
    }
    float s = cfg.strength;
    target_ = (s >= 0.0f && s <= 1.0f) ? s : (s > 1.0f ? 1.0f : 0.0f);
    reset();
    return true;
}

void Engine::reset() N60_RT_NONBLOCKING {
    if (n_ == 0) return;
    // Everything the engine owns past the plan and the windows restarts from silence.
    const uint32_t clear = n_;
    for (uint32_t i = 0; i < clear; ++i) {
        inL_[i] = inR_[i] = 0.0f;
        for (int j = 0; j < 5; ++j) {
            ola_[j][i] = 0.0f;
            fifo_[j][i] = 0.0f;
        }
    }
    for (uint32_t k = 0; k < bins_; ++k) pll_[k] = prr_[k] = plrRe_[k] = plrIm_[k] = 0.0f;
    auto clearDecor = [](Decor &d) {
        for (uint32_t s = 0; s < kDecorStages; ++s) {
            d.pos[s] = 0;
            for (uint32_t i = 0; i < d.delay[s]; ++i) d.buf[s][i] = 0.0f;
        }
    };
    for (uint32_t i = 0; i < leftCount_; ++i) clearDecor(left_[i]);
    for (uint32_t i = 0; i < rightCount_; ++i) clearDecor(right_[i]);
    hopCount_ = 0;
    inPos_ = 0;
    fifoR_ = 0;
    fifoW_ = hop_;  // primed with one hop of zeros: total latency is exactly one frame
    warmFrames_ = 0;
    current_ = target_;
}

void Engine::setStrength(float strength) N60_RT_NONBLOCKING {
    target_ = (strength >= 0.0f && strength <= 1.0f) ? strength : (strength > 1.0f ? 1.0f : 0.0f);
}

float Engine::decorrelate(Decor &d, float x) N60_RT_NONBLOCKING {
    // Schroeder all-pass cascade, lattice form: w = x + g w[n-d]; y = -g w + w[n-d]. Unit magnitude at every frequency.
    for (uint32_t s = 0; s < kDecorStages; ++s) {
        float *b = d.buf[s];
        const float wd = b[d.pos[s]];
        const float w = x + d.g[s] * wd;
        x = wd - d.g[s] * w;
        b[d.pos[s]] = w;
        if (++d.pos[s] == d.delay[s]) d.pos[s] = 0;
    }
    return x;
}

void Engine::process(const float *left, const float *right, float *const *out, uint32_t frames) N60_RT_NONBLOCKING {
    if (n_ == 0) return;
    const uint32_t mask = n_ - 1;
    uint32_t done = 0;
    while (done < frames) {
        uint32_t chunk = frames - done;
        if (chunk > hop_ - hopCount_) chunk = hop_ - hopCount_;
        for (uint32_t i = 0; i < chunk; ++i) {
            const float l = left[done + i], r = right[done + i];
            inL_[inPos_] = (l > -1e6f && l < 1e6f) ? l : 0.0f;
            inR_[inPos_] = (r > -1e6f && r < 1e6f) ? r : 0.0f;
            inPos_ = (inPos_ + 1) & mask;
        }
        hopCount_ += chunk;
        if (hopCount_ == hop_) {
            hopCount_ = 0;
            runFrame();
        }
        for (uint32_t c = 0; c < channels_; ++c)
            for (uint32_t i = 0; i < chunk; ++i) out[c][done + i] = 0.0f;
        for (uint32_t i = 0; i < chunk; ++i) {
            const uint32_t at = fifoR_ & mask;
            ++fifoR_;
            out[laneFl_][done + i] = fifo_[0][at];
            out[laneFr_][done + i] = fifo_[2][at];
            if (laneC_ >= 0) out[laneC_][done + i] = fifo_[1][at];
            const float aL = fifo_[3][at], aR = fifo_[4][at];
            for (uint32_t s = 0; s < leftCount_; ++s) out[left_[s].lane][done + i] = leftGain_ * decorrelate(left_[s], aL);
            for (uint32_t s = 0; s < rightCount_; ++s) out[right_[s].lane][done + i] = rightGain_ * decorrelate(right_[s], aR);
        }
        done += chunk;
    }
}

void Engine::runFrame() N60_RT_NONBLOCKING {
    const uint32_t n = n_, mask = n_ - 1;
    float energy = 0.0f;
    for (uint32_t i = 0; i < n; ++i) {
        const uint32_t at = (inPos_ + i) & mask;
        const float l = inL_[at], r = inR_[at];
        energy += l * l + r * r;
        specL_[i] = l * wnd_[i];
        specR_[i] = r * wnd_[i];
    }
    fft::forwardReal(plan_, specL_);
    fft::forwardReal(plan_, specR_);

    current_ += (target_ - current_) * strengthA_;
    if (std::fabs(target_ - current_) < 1e-5f) current_ = target_;
    if (energy / static_cast<float>(n) > kSilenceFrame && warmFrames_ < warmNeeded_) ++warmFrames_;
    const float warm = static_cast<float>(warmFrames_) / static_cast<float>(warmNeeded_);
    const float s = current_ * warm;

    const float kA = static_cast<float>(N60_UPMIX_AMBIENCE_FRACTION);
    const float movedL = leftCount_ ? s * kA : 0.0f;
    const float movedR = rightCount_ ? s * kA : 0.0f;
    const float keepL = std::sqrt(1.0f - movedL), keepR = std::sqrt(1.0f - movedR);
    const float moveGainL = std::sqrt(movedL), moveGainR = std::sqrt(movedR);
    const bool hasC = laneC_ >= 0;
    const float a = smoothA_, b = 1.0f - smoothA_;
    const float quarterPi = static_cast<float>(kPi / 4.0), halfPi = static_cast<float>(kPi / 2.0);

    for (uint32_t k = 0; k < bins_; ++k) {
        const float xlr = specL_[2 * k], xli = specL_[2 * k + 1];
        const float xrr = specR_[2 * k], xri = specR_[2 * k + 1];
        float oL[2] = {xlr, xli}, oC[2] = {0, 0}, oR[2] = {xrr, xri}, mL[2] = {0, 0}, mR[2] = {0, 0};
        if (k <= kMax_) {
            pll_[k] = a * pll_[k] + b * (xlr * xlr + xli * xli);
            prr_[k] = a * prr_[k] + b * (xrr * xrr + xri * xri);
            plrRe_[k] = a * plrRe_[k] + b * (xlr * xrr + xli * xri);   // L R*
            plrIm_[k] = a * plrIm_[k] + b * (xli * xrr - xlr * xri);
            const float tot = pll_[k] + prr_[k];
            if (tot > 1e-20f) {
                const float dd = pll_[k] - prr_[k];
                const float mag = std::sqrt(plrRe_[k] * plrRe_[k] + plrIm_[k] * plrIm_[k]);
                const float dist = std::sqrt(dd * dd + 4.0f * mag * mag);
                const float rho = dist / tot;
                float t = (rho - kRhoLow) / (kRhoHigh - kRhoLow);
                t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
                const float am = t * t * (3.0f - 2.0f * t);  // primary mask (amplitude), smoothstep of coherence
                const float c2 = dist > 1e-30f ? dd / dist : 1.0f;
                const float cosT = std::sqrt(std::fmax(0.0f, (1.0f + c2) * 0.5f));
                const float sinT = std::sqrt(std::fmax(0.0f, (1.0f - c2) * 0.5f));
                const float er = mag > 1e-30f ? plrRe_[k] / mag : 1.0f;
                const float ei = mag > 1e-30f ? plrIm_[k] / mag : 0.0f;
                // S = cos t * XL + sin t * e^{j phi} * XR
                const float sr = cosT * xlr + sinT * (er * xrr - ei * xri);
                const float si = cosT * xli + sinT * (er * xri + ei * xrr);
                // conj(e) * S, the phase the right lane carries
                const float pr = er * sr + ei * si, pi = er * si - ei * sr;
                const float theta = std::atan2(sinT, cosT);
                const float cphi = er > 0.0f ? er : 0.0f;
                const float sp = s * am * cphi;  // share of the primary moved toward the centre speaker
                float g0[3] = {cosT, 0.0f, sinT}, g1[3] = {cosT, 0.0f, sinT};
                if (hasC) {
                    if (theta < quarterPi) {
                        const float a1 = theta / quarterPi * halfPi;
                        g1[0] = std::cos(a1); g1[1] = std::sin(a1); g1[2] = 0.0f;
                    } else {
                        const float a1 = (theta - quarterPi) / quarterPi * halfPi;
                        g1[0] = 0.0f; g1[1] = std::cos(a1); g1[2] = std::sin(a1);
                    }
                }
                float g[3];
                for (int j = 0; j < 3; ++j) g[j] = (1.0f - sp) * g0[j] + sp * g1[j];
                const float gn = std::sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
                if (gn > 1e-12f) { g[0] /= gn; g[1] /= gn; g[2] /= gn; }
                // Primary lanes, and ambience = input minus the extracted primary a * v * S.
                const float pLr = am * g[0] * sr, pLi = am * g[0] * si;
                const float pCr = am * g[1] * sr, pCi = am * g[1] * si;
                const float pRr = am * g[2] * pr, pRi = am * g[2] * pi;
                const float aLr = xlr - am * cosT * sr, aLi = xli - am * cosT * si;
                const float aRr = xrr - am * sinT * pr, aRi = xri - am * sinT * pi;
                oL[0] = keepL * aLr + pLr; oL[1] = keepL * aLi + pLi;
                oC[0] = pCr; oC[1] = pCi;
                oR[0] = keepR * aRr + pRr; oR[1] = keepR * aRi + pRi;
                mL[0] = moveGainL * aLr; mL[1] = moveGainL * aLi;
                mR[0] = moveGainR * aRr; mR[1] = moveGainR * aRi;
                // Per-bin power equals input power (the cross terms lost where the mask is partial are restored).
                const float inP = xlr * xlr + xli * xli + xrr * xrr + xri * xri;
                const float outP = oL[0] * oL[0] + oL[1] * oL[1] + oC[0] * oC[0] + oC[1] * oC[1] + oR[0] * oR[0] +
                                   oR[1] * oR[1] + mL[0] * mL[0] + mL[1] * mL[1] + mR[0] * mR[0] + mR[1] * mR[1];
                if (outP > 1e-30f && inP > 1e-30f) {
                    float nrm = std::sqrt(inP / outP);
                    nrm = nrm < 0.7f ? 0.7f : (nrm > 1.5f ? 1.5f : nrm);
                    for (int j = 0; j < 2; ++j) { oL[j] *= nrm; oC[j] *= nrm; oR[j] *= nrm; mL[j] *= nrm; mR[j] *= nrm; }
                }
            }
        }
        out_[0][2 * k] = oL[0]; out_[0][2 * k + 1] = oL[1];
        out_[1][2 * k] = oC[0]; out_[1][2 * k + 1] = oC[1];
        out_[2][2 * k] = oR[0]; out_[2][2 * k + 1] = oR[1];
        out_[3][2 * k] = mL[0]; out_[3][2 * k + 1] = mL[1];
        out_[4][2 * k] = mR[0]; out_[4][2 * k + 1] = mR[1];
    }
    for (int j = 0; j < 5; ++j) {
        out_[j][1] = 0.0f;                  // DC and Nyquist are real
        out_[j][2 * (bins_ - 1) + 1] = 0.0f;
        fft::inverseReal(plan_, out_[j]);
        float *ola = ola_[j];
        for (uint32_t i = 0; i < n; ++i) ola[i] += out_[j][i] * synth_[i];
        // The first hop of the accumulator is final: queue it, then slide the accumulator down one hop.
        for (uint32_t i = 0; i < hop_; ++i) fifo_[j][(fifoW_ + i) & mask] = ola[i];
        for (uint32_t i = 0; i + hop_ < n; ++i) ola[i] = ola[i + hop_];
        for (uint32_t i = n - hop_; i < n; ++i) ola[i] = 0.0f;
    }
    fifoW_ += hop_;
}

}  // namespace n60::upmix

extern "C" {

uint32_t n60_upmix_abi_version(void) { return N60_UPMIX_ABI_VERSION; }

uint32_t n60_upmix_frame_length(double sampleRate) { return n60::upmix::Engine::frameLengthFor(sampleRate); }

uint32_t n60_upmix_latency_frames(double sampleRate) { return n60::upmix::Engine::frameLengthFor(sampleRate); }

int32_t n60_upmix_process_offline(const n60_upmix_config *config, const float *left, const float *right, uint32_t frames,
                                  float *const *out, uint32_t blockFrames) {
    if (config == nullptr || left == nullptr || right == nullptr || out == nullptr) return N60_UPMIX_ERR_ARGUMENT;
    if (!(config->strength >= 0.0f && config->strength <= 1.0f)) return N60_UPMIX_ERR_ARGUMENT;
    if (config->structSize != sizeof(n60_upmix_config) || config->channelCount < 2 ||
        config->channelCount > N60_LAYOUT_MAX_CHANNELS)
        return N60_UPMIX_ERR_ARGUMENT;
    for (uint32_t c = 0; c < config->channelCount; ++c)
        if (out[c] == nullptr) return N60_UPMIX_ERR_ARGUMENT;
    n60::upmix::Engine *engine = new (std::nothrow) n60::upmix::Engine();
    if (engine == nullptr) return N60_UPMIX_ERR_ARGUMENT;
    if (!engine->init(*config)) {
        delete engine;
        return N60_UPMIX_ERR_ARGUMENT;
    }
    const uint32_t block = blockFrames == 0 ? (frames == 0 ? 1u : frames) : blockFrames;
    float *lanes[N60_LAYOUT_MAX_CHANNELS];
    for (uint32_t pos = 0; pos < frames; pos += block) {
        const uint32_t n = frames - pos < block ? frames - pos : block;
        for (uint32_t c = 0; c < config->channelCount; ++c) lanes[c] = out[c] + pos;
        engine->process(left + pos, right + pos, lanes, n);
    }
    delete engine;
    return N60_UPMIX_OK;
}

}  // extern "C"
