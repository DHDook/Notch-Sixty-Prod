/*
 * E4 S13: acoustic twin, a deterministic closed-loop room simulator for the
 * speaker-ANC tests. Test code only; nothing in the product links it.
 *
 * One speaker, one error microphone (at the listener) and one upstream
 * reference microphone, in a plane. Everything is evaluated in continuous
 * time and sampled at the converter rates, so a path is the same physical path
 * at every device rate (44.1 to 384 kHz).
 *
 * Secondary path (speaker to error microphone):
 *     delay  = distance / c(T) + latency          (fractional, linear interp)
 *     gain   = speakerGain / max(distance, 0.25 m)
 *     then a one-pole low-pass (impulse-invariant), then parallel room modes:
 *     each mode adds (10^(dB/20) - 1) times a unit-peak band-pass at its
 *     frequency, so the path gain at the mode centre is exactly dB.
 *     c(T) = 331.3 sqrt(1 + T / 273.15) m/s; T may drift linearly.
 * Disturbance: tonal noise sources that may move; each reaches a microphone
 * with amplitude / max(distance, 0.5 m) and phase 2 pi f (t - distance / c).
 * Clock drift: the microphone ADC clock runs at (1 + ppm 1e-6) of the speaker
 * DAC clock; the microphone samples are taken at t = n (1 + eps) / fs.
 * Microphone: white Gaussian noise, DC offset, hard clip at +-1.
 * Faults (inject): unplug, frozen, clipped, volume change, mic moved, device
 * loss and rate change. See Fault.
 */
#ifndef E4_ACOUSTIC_TWIN_HPP
#define E4_ACOUSTIC_TWIN_HPP

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace twin {

constexpr double kTau = 6.283185307179586476925286766559;

struct Vec2 {
    double x = 0, y = 0;
};

inline double distance(Vec2 a, Vec2 b) { return std::hypot(a.x - b.x, a.y - b.y); }

struct Mode {
    double hz = 60;
    double q = 8;
    double gainDB = 0;
};

struct Source {
    double hz = 60;
    double amplitude = 0.1;  /* at 1 m */
    double phase = 0;
    Vec2 position{-2, 0};
    Vec2 velocity{0, 0};
};

struct Config {
    double fs = 48000;
    uint64_t seed = 1;
    Vec2 speaker{0, 0};
    Vec2 listener{1, 0};
    Vec2 listenerVelocity{0, 0};
    Vec2 reference{-3, 0};
    double latencySeconds = 0.001;  /* converters and buffering */
    double speakerGain = 0.5;       /* at 1 m, before the low-pass */
    double lowpassHz = 800;
    std::vector<Mode> modes;
    std::vector<Source> sources;
    double micNoiseDBFS = -95;  /* -inf for none */
    double micDC = 0;
    double clockDriftPPM = 0;   /* microphone clock relative to the speaker's */
    double temperatureC = 20;
    double temperatureRateCPerS = 0;
};

enum class Fault {
    MicUnplug,    /* error mic reads its floor only (param 1: NaN stream) */
    MicFrozen,    /* error mic repeats its last sample */
    MicClipped,   /* error mic gain +40 dB, then the +-1 clip */
    VolumeChange, /* speaker gain changes by param dB */
    MicMoved,     /* listener jumps by (param, 0) m */
    PathInvert,   /* secondary path x -1 (a speaker wired out of phase) */
    DeviceLoss,   /* speaker output and both mics go to zero */
    Clear,        /* removes MicUnplug, MicFrozen, MicClipped, DeviceLoss */
};

struct Frame {
    float error;      /* error microphone, at the listener */
    float reference;  /* upstream reference microphone */
};

inline double speedOfSound(double celsius) { return 331.3 * std::sqrt(1.0 + celsius / 273.15); }

class Twin {
public:
    explicit Twin(const Config &config) : cfg_(config) { build(); }

    const Config &config() const { return cfg_; }
    uint64_t frame() const { return n_; }
    uint64_t rateChanges() const { return rateChanges_; }
    Vec2 listener() const { return listenerAt(timeNow()); }
    /* Speaker-to-error-mic distance now, m. */
    double pathDistance() const { return distance(cfg_.speaker, listener()); }
    /* Speaker-to-error-mic delay now, s. */
    double pathDelaySeconds() const { return delayFor(pathDistance(), timeNow()); }

    void inject(Fault fault, double param = 0) {
        switch (fault) {
        case Fault::MicUnplug:
            unplugged_ = true;
            unplugNaN_ = param != 0;
            break;
        case Fault::MicFrozen: frozen_ = true; break;
        case Fault::MicClipped: clipped_ = true; break;
        case Fault::VolumeChange: volumeScale_ *= std::pow(10.0, param / 20.0); break;
        case Fault::MicMoved:
            cfg_.listener = listenerAt(timeNow());
            cfg_.listener.x += param;
            epoch_ = timeNow();
            break;
        case Fault::PathInvert: volumeScale_ = -volumeScale_; break;
        case Fault::DeviceLoss: lost_ = true; break;
        case Fault::Clear:
            unplugged_ = frozen_ = clipped_ = lost_ = false;
            break;
        }
    }

    /* The device rate changes under the twin. Physical paths keep their
     * seconds; the filters and the history are rebuilt at the new rate and the
     * microphone stream restarts, as after a real Core Audio rate change. */
    void changeRate(double newFs) {
        const double now = timeNow();
        cfg_.listener = listenerAt(now);
        for (Source &s : cfg_.sources) {
            s.position.x += s.velocity.x * now;
            s.position.y += s.velocity.y * now;
        }
        cfg_.temperatureC += cfg_.temperatureRateCPerS * now;
        cfg_.fs = newFs;
        const uint64_t changes = rateChanges_ + 1;
        const bool u = unplugged_, f = frozen_, c = clipped_, l = lost_;
        const double v = volumeScale_;
        build();
        unplugged_ = u;
        frozen_ = f;
        clipped_ = c;
        lost_ = l;
        volumeScale_ = v;
        rateChanges_ = changes;
    }

    /* One frame: the speaker sample goes out, the microphones are read. */
    Frame step(float speakerSample) {
        const double fs = cfg_.fs;
        history_[n_ & mask_] = lost_ ? 0.0f : speakerSample;
        const double drift = 1.0 + cfg_.clockDriftPPM * 1e-6;
        const double t = static_cast<double>(n_) * drift / fs;  /* mic clock time */

        /* Speaker through the secondary path. */
        const Vec2 mic = listenerAt(t);
        const double dist = distance(cfg_.speaker, mic);
        const double delayFrames = delayFor(dist, t) * fs;
        double idx = static_cast<double>(n_) * drift - delayFrames;
        idx = std::min(idx, static_cast<double>(n_));  /* never read the future */
        double sec = 0.0;
        if (idx >= 0.0) {
            const auto i0 = static_cast<uint64_t>(std::floor(idx));
            const double frac = idx - std::floor(idx);
            const double a = history_[i0 & mask_];
            const double b = history_[(i0 + 1) & mask_];
            sec = (a + (b - a) * frac) * cfg_.speakerGain * volumeScale_ / std::max(dist, 0.25);
        }
        lp_ = lpA_ * lp_ + lpB_ * sec;
        double path = lp_;
        for (ModeState &m : modes_) path += m.extra * m.run(lp_);

        /* Disturbance at both microphones. */
        double dErr = 0.0, dRef = 0.0;
        for (const Source &s : cfg_.sources) {
            const Vec2 p{s.position.x + s.velocity.x * t, s.position.y + s.velocity.y * t};
            dErr += tone(s, p, mic, t);
            dRef += tone(s, p, cfg_.reference, t);
        }

        double err = path + dErr + cfg_.micDC + noise();
        double ref = dRef + noise();
        if (clipped_) err *= 100.0;
        if (unplugged_) err = noise();
        if (frozen_) err = lastErr_;
        err = std::clamp(err, -1.0, 1.0);
        ref = std::clamp(ref, -1.0, 1.0);
        lastErr_ = err;
        Frame out{static_cast<float>(err), static_cast<float>(ref)};
        if (unplugged_ && unplugNaN_) out.error = std::numeric_limits<float>::quiet_NaN();
        if (lost_) out = Frame{0.0f, 0.0f};
        ++n_;
        return out;
    }

private:
    struct ModeState {
        double b0 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0, extra = 0;
        double run(double x) {
            const double y = b0 * x + z1;
            z1 = -a1 * y + z2;  /* b1 = 0 for the constant-peak band-pass */
            z2 = b2 * x - a2 * y;
            return y;
        }
    };

    void build() {
        const double fs = cfg_.fs;
        n_ = 0;
        epoch_ = 0;
        const double maxDelay = 0.08;
        size_t len = 1;
        while (len < static_cast<size_t>(fs * maxDelay) + 8) len <<= 1;
        history_.assign(len, 0.0f);
        mask_ = len - 1;
        lp_ = 0;
        lpA_ = std::exp(-kTau * cfg_.lowpassHz / fs);
        lpB_ = 1.0 - lpA_;
        modes_.clear();
        for (const Mode &m : cfg_.modes) {
            ModeState s;
            const double w0 = kTau * m.hz / fs;
            const double alpha = std::sin(w0) / (2.0 * m.q);
            const double a0 = 1.0 + alpha;
            s.b0 = alpha / a0;
            s.b2 = -alpha / a0;
            s.a1 = -2.0 * std::cos(w0) / a0;
            s.a2 = (1.0 - alpha) / a0;
            s.extra = std::pow(10.0, m.gainDB / 20.0) - 1.0;
            modes_.push_back(s);
        }
        rng_ = cfg_.seed * 0x9E3779B97F4A7C15ull + 0x1234567ull;
        noiseRMS_ = std::isfinite(cfg_.micNoiseDBFS) ? std::pow(10.0, cfg_.micNoiseDBFS / 20.0) : 0.0;
        unplugged_ = frozen_ = clipped_ = lost_ = unplugNaN_ = false;
        volumeScale_ = 1.0;
        lastErr_ = 0.0;
        rateChanges_ = 0;
        spare_ = false;
    }

    double timeNow() const {
        return static_cast<double>(n_) * (1.0 + cfg_.clockDriftPPM * 1e-6) / cfg_.fs;
    }

    Vec2 listenerAt(double t) const {
        const double dt = t - epoch_;
        return {cfg_.listener.x + cfg_.listenerVelocity.x * dt, cfg_.listener.y + cfg_.listenerVelocity.y * dt};
    }

    double delayFor(double metres, double t) const {
        const double temp = cfg_.temperatureC + cfg_.temperatureRateCPerS * t;
        return metres / speedOfSound(temp) + cfg_.latencySeconds;
    }

    double tone(const Source &s, Vec2 from, Vec2 to, double t) const {
        const double d = distance(from, to);
        const double temp = cfg_.temperatureC + cfg_.temperatureRateCPerS * t;
        const double tau = d / speedOfSound(temp);
        return s.amplitude / std::max(d, 0.5) * std::cos(kTau * s.hz * (t - tau) + s.phase);
    }

    uint64_t next() {
        rng_ ^= rng_ << 13;
        rng_ ^= rng_ >> 7;
        rng_ ^= rng_ << 17;
        return rng_;
    }
    double uniform() { return (static_cast<double>(next() >> 11) + 0.5) / 9007199254740992.0; }
    double noise() {
        if (noiseRMS_ == 0.0) return 0.0;
        if (spare_) {
            spare_ = false;
            return spareValue_ * noiseRMS_;
        }
        const double r = std::sqrt(-2.0 * std::log(uniform()));
        const double a = kTau * uniform();
        spareValue_ = r * std::sin(a);
        spare_ = true;
        return r * std::cos(a) * noiseRMS_;
    }

    Config cfg_;
    std::vector<float> history_;
    size_t mask_ = 0;
    std::vector<ModeState> modes_;
    uint64_t n_ = 0;
    double epoch_ = 0; /* time at which cfg_.listener applies */
    double lp_ = 0, lpA_ = 0, lpB_ = 0;
    uint64_t rng_ = 1;
    double noiseRMS_ = 0;
    bool spare_ = false;
    double spareValue_ = 0;
    bool unplugged_ = false, unplugNaN_ = false, frozen_ = false, clipped_ = false, lost_ = false;
    double volumeScale_ = 1.0;
    double lastErr_ = 0;
    uint64_t rateChanges_ = 0;
};

}  // namespace twin

#endif
