/*
 * E4 S22: behavioural harness for programme removal. The real Quiet Zone runtime demodulates the
 * programme at each tone frequency (N60ActiveQuietZoneRuntimeAccumulateProgramme) and reports it
 * in the telemetry; the real remote tonal core (N60RemoteTonal.h) takes it out of the error
 * microphone's tone. The harness models the room: the microphone carries the disturbance, the
 * anti-noise (the gain the kernel plays through the secondary path) and the programme through
 * per-channel paths S_L and S_R, all as phasors relative to the kernel's tone oscillator.
 *
 * At the eight standard rates, with music 20 dB over the noise:
 *  - at a tone frequency the converged weight is within 0.5 dB of -D/S with
 *    removal on, and visibly biased with it off;
 *  - the removed tone equals the programme's true level at the microphone within 5 %;
 *  - with no programme the removal changes nothing.
 * Kernel side: the means are per-tone, cleared by each capture, ignore non-finite samples, and
 * an inactive tone has none.
 */
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

extern "C" {
#include "N60ActiveQuietZone.h"
}
#include "N60RemoteTonal.h"

using cd = std::complex<double>;
static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kTicks = 1e9;
static const uint64_t kBase = 1000000000ull;
static const double kTau = 6.283185307179586;
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

static double db(double ratio) { return 20.0 * std::log10(std::max(ratio, 1e-12)); }

struct Scenario {
    double fs = 48000;
    uint32_t tones = 2;
    double hz[2] = {60.0, 90.0};
    cd sL[2] = {{0.8, 0.3}, {0.5, -0.6}};      // speaker-to-microphone paths
    cd sR[2] = {{0.4, -0.5}, {0.7, 0.2}};
    cd disturbance[2] = {{0.02, 0.01}, {-0.01, 0.015}};
    cd feedL[2] = {{0.2, 0.05}, {0.15, -0.1}};  // programme amplitude per tone, 0 = none
    cd feedR[2] = {{0.1, -0.1}, {0.2, 0.05}};
    double offsetHz = 0.0;                       // programme sits this far above the tone (unused: 0)
    bool remove = true;
    double seconds = 40.0;
};

struct Outcome {
    cd weight[2];
    cd removed[2];
    cd micProgramme[2];  // the programme's true tone at the microphone (last block)
    bool ok = false;
};

static Outcome run(const Scenario &sc) {
    Outcome out{};
    const double fs = sc.fs;
    N60ActiveQuietZoneSnapshot snap = N60ActiveQuietZoneSnapshotMakeBypassed();
    N60ActiveQuietZoneToneSnapshot t[N60_ACTIVE_QUIET_ZONE_MAX_TONES] = {};
    const float g = 0.01f;
    for (uint32_t k = 0; k < sc.tones; ++k) {
        t[k].frequencyHz = sc.hz[k];
        t[k].leftReal = g;
        t[k].rightReal = g;
    }
    if (!N60ActiveQuietZoneSnapshotSet(&snap, t, sc.tones, 64u, fs, true)) return out;
    snap.armGeneration = 1;
    N60ActiveQuietZoneRuntime rt;
    N60ActiveQuietZoneRuntimeReset(&rt, fs);
    if (!N60ActiveQuietZoneRuntimeSchedule(&rt, &snap, fs)) return out;

    const double shareAmp = std::sqrt(0.5);
    N60RemoteTonalConfig cfg = N60RemoteTonalConfigDefault(fs, kTicks);
    cfg.toneCount = sc.tones;
    cfg.removeProgramme = sc.remove;
    cfg.convergenceSeconds = 1.0;
    for (uint32_t k = 0; k < sc.tones; ++k) {
        cfg.toneHz[k] = static_cast<float>(sc.hz[k]);
        cfg.leftShare[k] = {static_cast<float>(shareAmp), 0.0f};
        cfg.rightShare[k] = {static_cast<float>(shareAmp), 0.0f};
        const cd s = sc.sL[k] * shareAmp + sc.sR[k] * shareAmp;  // path of the split
        cfg.pathSeed[k] = {static_cast<float>(s.real()), static_cast<float>(s.imag())};
        cfg.leftPathSeed[k] = {static_cast<float>(sc.sL[k].real()), static_cast<float>(sc.sL[k].imag())};
        cfg.rightPathSeed[k] = {static_cast<float>(sc.sR[k].real()), static_cast<float>(sc.sR[k].imag())};
        cfg.weightSeed[k] = {0.0f, 0.0f};
    }
    if (!N60RemoteTonalConfigIsValid(&cfg)) return out;
    N60RemoteTonal *core = N60RemoteTonalCreate(&cfg);
    if (core == nullptr) return out;
    N60ActiveQuietZoneTelemetry *ring = N60ActiveQuietZoneTelemetryCreate();
    N60ActiveQuietZoneGainMailbox *mailbox = N60ActiveQuietZoneGainMailboxCreate();

    const uint64_t total = static_cast<uint64_t>(sc.seconds * fs);
    const uint64_t spacing = static_cast<uint64_t>(0.005 * fs);
    const uint32_t block = static_cast<uint32_t>(0.25 * fs);
    std::vector<float> mic, held;
    uint64_t heldHost = 0;
    mic.reserve(block);
    uint64_t blockStart = 0;
    uint64_t processedBlocks = 0;
    cd feedMic[2] = {};
    auto host = [&](uint64_t n) { return kBase + static_cast<uint64_t>(static_cast<double>(n) / fs * kTicks); };

    for (uint64_t n = 0; n < total; ++n) {
        if (n > 0 && n % spacing == 0) {
            N60ActiveQuietZoneRuntimeApplyMailbox(&rt, mailbox, &snap, fs);
            N60ActiveQuietZoneTelemetryRecord rec;
            if (N60ActiveQuietZoneRuntimeCaptureTelemetry(&rt, host(n), n, &rec)) {
                N60ActiveQuietZoneTelemetryPush(ring, &rec);
                N60ActiveQuietZoneTelemetryRecord popped;
                while (N60ActiveQuietZoneTelemetryPop(ring, &popped)) N60RemoteTonalPushTelemetry(core, &popped);
            }
        }
        // Programme: a sinusoid per tone, in the tone oscillator's frame (plus an offset).
        double left = 0.0, right = 0.0, micSample = 0.0;
        const double time = static_cast<double>(n) / fs;
        for (uint32_t k = 0; k < sc.tones; ++k) {
            const cd p{rt.tones[k].oscillatorCosine, rt.tones[k].oscillatorSine};
            const cd turn = std::polar(1.0, kTau * sc.offsetHz * time);
            const cd al = sc.feedL[k] * turn, ar = sc.feedR[k] * turn;
            left += (al * p).real();
            right += (ar * p).real();
            const cd prog = sc.sL[k] * al + sc.sR[k] * ar;
            // The anti-noise: the gain the kernel is playing through each speaker's path.
            const N60ActiveQuietZoneToneRuntime &tr = rt.tones[k];
            const cd anti = sc.sL[k] * cd{tr.currentLeftReal, tr.currentLeftImaginary}
                + sc.sR[k] * cd{tr.currentRightReal, tr.currentRightImaginary};
            micSample += ((sc.disturbance[k] + prog + anti) * p).real();
            feedMic[k] = sc.sL[k] * sc.feedL[k] + sc.sR[k] * sc.feedR[k];
        }
        N60ActiveQuietZoneRuntimeAccumulateProgramme(&rt, static_cast<float>(left), static_cast<float>(right));
        float ol = 0.0f, orr = 0.0f;
        N60ActiveQuietZoneRuntimeProcessFrame(&rt, &ol, &orr);
        mic.push_back(static_cast<float>(micSample));
        if (mic.size() == block) {
            blockStart = n + 1 - block;
            const uint64_t hostFirst = host(blockStart);
            // Coverage needs records past the block's end, so a block is processed one block late.
            if (!held.empty()) {
                if (N60RemoteTonalProcessMic(core, held.data(), static_cast<uint32_t>(held.size()), heldHost)) {
                    ++processedBlocks;
                    N60ActiveQuietZoneGainRecord next;
                    if (N60RemoteTonalNextRecord(core, 1u, 0.0f, &next)) N60ActiveQuietZoneGainMailboxPublish(mailbox, &next);
                }
            }
            held = mic;
            heldHost = hostFirst;
            mic.clear();
        }
    }
    const N60RemoteTonalStatus st = N60RemoteTonalReadStatus(core);
    out.ok = processedBlocks > 20;
    for (uint32_t k = 0; k < sc.tones; ++k) {
        out.weight[k] = {st.weight[k].re, st.weight[k].im};
        out.removed[k] = {st.programmeAtMic[k].re, st.programmeAtMic[k].im};
        out.micProgramme[k] = feedMic[k];
    }
    N60ActiveQuietZoneTelemetryDestroy(ring);
    N60ActiveQuietZoneGainMailboxDestroy(mailbox);
    N60RemoteTonalDestroy(core);
    return out;
}

static cd combined(const Scenario &sc, uint32_t k) {
    const double a = std::sqrt(0.5);
    return sc.sL[k] * a + sc.sR[k] * a;
}

static void testRemoval(double fs) {
    for (const double offset : {0.0}) {
        Scenario on;
        on.fs = fs;
        on.offsetHz = offset;
        Scenario off = on;
        off.remove = false;
        const Outcome a = run(on);
        const Outcome b = run(off);
        CHECK(a.ok && b.ok, "%.0f Hz: too few blocks adapted", fs);
        if (!a.ok || !b.ok) continue;
        double worstOn = 0.0, bestOff = 1e9;
        for (uint32_t k = 0; k < on.tones; ++k) {
            const cd ideal = -on.disturbance[k] / combined(on, k);
            // The anti-noise is the core's own weight: error in dB against the ideal.
            const double errOn = std::fabs(db(std::abs(a.weight[k] / ideal)));
            const double errOff = std::fabs(db(std::abs(b.weight[k] / ideal)));
            worstOn = std::max(worstOn, errOn);
            bestOff = std::min(bestOff, errOff);
            const cd gone = a.removed[k];
            CHECK(std::abs(gone - a.micProgramme[k]) < 0.05 * std::abs(a.micProgramme[k]) + 1e-6,
                  "%.0f Hz offset %.1f tone %u: removed %.4f%+.4fj vs true %.4f%+.4fj", fs, offset, k,
                  gone.real(), gone.imag(), a.micProgramme[k].real(), a.micProgramme[k].imag());
        }
        CHECK(worstOn < 0.5, "%.0f Hz offset %.1f: weight off by %.2f dB with removal", fs, offset, worstOn);
        CHECK(bestOff > 3.0, "%.0f Hz offset %.1f: no bias without removal (%.2f dB): test would pass anyway", fs, offset, bestOff);
    }
}

static void testNoProgramme(double fs) {
    Scenario on;
    on.fs = fs;
    on.seconds = 20.0;
    for (int k = 0; k < 2; ++k) {
        on.feedL[k] = 0;
        on.feedR[k] = 0;
    }
    Scenario off = on;
    off.remove = false;
    const Outcome a = run(on), b = run(off);
    CHECK(a.ok && b.ok, "%.0f Hz: silent programme blocks", fs);
    for (uint32_t k = 0; k < 2 && a.ok && b.ok; ++k) {
        CHECK(std::abs(a.weight[k] - b.weight[k]) < 1e-5, "%.0f Hz: silence changed the weight", fs);
        CHECK(std::abs(a.removed[k]) < 1e-9, "%.0f Hz: removed %g with no programme", fs, std::abs(a.removed[k]));
    }
}

static void testKernelSums(double fs) {
    N60ActiveQuietZoneSnapshot snap = N60ActiveQuietZoneSnapshotMakeBypassed();
    N60ActiveQuietZoneToneSnapshot t[N60_ACTIVE_QUIET_ZONE_MAX_TONES] = {};
    t[0].frequencyHz = 60.0;
    t[0].leftReal = 0.01f;
    t[0].rightReal = 0.01f;
    CHECK(N60ActiveQuietZoneSnapshotSet(&snap, t, 1u, 64u, fs, true), "snapshot at %.0f", fs);
    snap.armGeneration = 1;
    N60ActiveQuietZoneRuntime rt;
    N60ActiveQuietZoneRuntimeReset(&rt, fs);
    CHECK(N60ActiveQuietZoneRuntimeSchedule(&rt, &snap, fs), "schedule at %.0f", fs);
    const uint64_t frames = static_cast<uint64_t>(0.5 * fs);
    for (uint64_t n = 0; n < frames; ++n) {
        const double l = (n % 97 == 0) ? NAN : 0.25;  // non-finite samples count as zero
        N60ActiveQuietZoneRuntimeAccumulateProgramme(&rt, static_cast<float>(l), 0.0f);
        float a = 0, b = 0;
        N60ActiveQuietZoneRuntimeProcessFrame(&rt, &a, &b);
    }
    N60ActiveQuietZoneTelemetryRecord rec;
    CHECK(N60ActiveQuietZoneRuntimeCaptureTelemetry(&rt, 5, frames, &rec), "capture at %.0f", fs);
    CHECK(rec.programmeFrames[0] == frames, "%.0f: %u frames, expected %llu", fs, rec.programmeFrames[0],
          static_cast<unsigned long long>(frames));
    CHECK(std::isfinite(rec.programme[0][0]) && std::isfinite(rec.programme[0][1]), "%.0f: non-finite mean", fs);
    CHECK(std::fabs(rec.programme[0][2]) < 1e-9f && std::fabs(rec.programme[0][3]) < 1e-9f,
          "%.0f: right channel carried a mean with silent programme", fs);
    CHECK(rec.programmeFrames[1] == 0u && rec.programmeFrames[2] == 0u, "%.0f: inactive tones have frames", fs);
    // The capture cleared the sums.
    CHECK(N60ActiveQuietZoneRuntimeCaptureTelemetry(&rt, 10, frames, &rec), "second capture at %.0f", fs);
    CHECK(rec.programmeFrames[0] == 0u, "%.0f: sums survived a capture", fs);
}

int main() {
    for (const double fs : kRates) {
        testKernelSums(fs);
        testRemoval(fs);
        testNoProgramme(fs);
    }
    if (failures != 0) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("e4_programme_removal: ok\n");
    return 0;
}
