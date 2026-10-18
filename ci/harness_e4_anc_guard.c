/*
 * E4 S4: behavioural harness for the speaker-ANC howl guard (N60AncGuard.h).
 * Runs every scenario at the eight standard rates, feeding audio in
 * 511-frame buffers so detector blocks straddle buffer boundaries.
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60AncGuard.h"

#define CHUNK 511u
static const double kRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000
};
static int failures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
        failures++; \
    } \
} while (0)

static double tau(void) { return 2.0 * acos(-1.0); }
static double amp(double db) { return pow(10.0, db / 20.0); }

typedef struct {
    float *anti;
    float *ref;
    float *err;
    size_t frames;
} Signal;

static Signal make_signal(size_t frames, bool withRef, bool withErr) {
    Signal s = {
        .anti = calloc(frames, sizeof(float)),
        .ref = withRef ? calloc(frames, sizeof(float)) : NULL,
        .err = withErr ? calloc(frames, sizeof(float)) : NULL,
        .frames = frames,
    };
    if (!s.anti || (withRef && !s.ref) || (withErr && !s.err)) {
        fprintf(stderr, "out of memory\n");
        exit(2);
    }
    return s;
}

static void free_signal(Signal *s) {
    free(s->anti);
    free(s->ref);
    free(s->err);
}

/* Feeds the whole signal through the guard in CHUNK-frame buffers. */
static void run(N60AncGuard *guard, Signal *s, size_t from, size_t to) {
    for (size_t i = from; i < to; i += CHUNK) {
        const uint32_t n = (uint32_t)((to - i) < CHUNK ? (to - i) : CHUNK);
        N60AncGuardProcess(guard, s->anti + i, s->ref ? s->ref + i : NULL,
                           s->err ? s->err + i : NULL, n);
    }
}

static N60AncGuard *make_guard(double rate, bool withBaseline) {
    N60AncGuardConfig config = N60AncGuardConfigDefault(rate);
    if (withBaseline) {
        config.hasErrorBaseline = true;
        for (uint32_t k = 0; k < N60_ANC_GUARD_BAND_COUNT; ++k) {
            config.errorBaselineDB[k] = -40.0f;
        }
    }
    N60AncGuard *guard = N60AncGuardCreate(&config);
    if (!guard) {
        fprintf(stderr, "guard create failed at %.0f Hz\n", rate);
        exit(2);
    }
    return guard;
}

static uint32_t uniform_state = 12345u;
static float noise(void) {
    uniform_state = uniform_state * 1664525u + 1013904223u;
    return (float)((uniform_state >> 8) / 8388608.0 - 1.0);
}

static size_t ramp_frames(double rate) { return (size_t)lround(rate * 0.010); }

/* A growing loop trips Growth within 50 ms, then mutes and stays muted. */
static void growth_trips_and_latches(double rate) {
    /* Onset part-way through a detector block: the worst case. */
    const size_t onset = (size_t)(0.2053 * rate);
    const size_t frames = (size_t)(1.2 * rate);
    Signal s = make_signal(frames, true, false);
    for (size_t i = 0; i < frames; ++i) {
        const double t = (double)i / rate;
        const double grownDB = i < onset ? 0.0 : 0.5 * 1000.0 * (t - (double)onset / rate);
        const double db = fmin(-50.0 + grownDB, -10.0);
        s.anti[i] = (float)(amp(db) * sin(tau() * 60.0 * t));
        s.ref[i] = 0.01f * noise();
    }
    N60AncGuard *guard = make_guard(rate, false);
    run(guard, &s, 0, frames);
    const N60AncGuardStatus st = N60AncGuardReadStatus(guard);
    CHECK(st.trip == N60AncGuardTripGrowth, "%.0f Hz: trip %d, want growth", rate, st.trip);
    CHECK(st.tripFrame > onset && st.tripFrame - onset <= (uint64_t)(0.050 * rate),
          "%.0f Hz: tripped %.1f ms after onset", rate,
          ((double)st.tripFrame - (double)onset) * 1000.0 / rate);
    CHECK(st.muted, "%.0f Hz: not muted", rate);
    const size_t silentFrom = (size_t)st.tripFrame + ramp_frames(rate);
    for (size_t i = silentFrom; i < frames; ++i) {
        if (s.anti[i] != 0.0f) {
            CHECK(false, "%.0f Hz: output %g after mute at %zu", rate, s.anti[i], i);
            break;
        }
    }
    CHECK(st.tripCount == 1, "%.0f Hz: %llu trips", rate, (unsigned long long)st.tripCount);

    /* Re-arm: steady tone ramps back up and does not trip. */
    N60AncGuardRequestRearm(guard);
    const size_t steadyFrames = (size_t)(1.0 * rate);
    Signal steady = make_signal(steadyFrames, false, false);
    for (size_t i = 0; i < steadyFrames; ++i) {
        steady.anti[i] = (float)(0.1 * sin(tau() * 60.0 * (double)i / rate));
    }
    float original[2] = {steady.anti[1], steady.anti[steadyFrames - 1]};
    run(guard, &steady, 0, steadyFrames);
    const N60AncGuardStatus after = N60AncGuardReadStatus(guard);
    CHECK(after.trip == N60AncGuardTripNone && !after.muted,
          "%.0f Hz: re-armed guard reports trip %d", rate, after.trip);
    CHECK(fabsf(steady.anti[1]) <= fabsf(original[0]) * 2.0f / (float)ramp_frames(rate) + 1e-7f,
          "%.0f Hz: re-arm did not ramp in", rate);
    CHECK(fabsf(steady.anti[steadyFrames - 1] - original[1]) < 1e-6f,
          "%.0f Hz: re-armed output not restored", rate);
    free_signal(&steady);
    free_signal(&s);
    N60AncGuardDestroy(guard);
}

/* Music-like reference with transients, anti-noise following it, a steady
 * tone without reference, and a quiet error residual: none of these trip. */
static void normal_programme_does_not_trip(double rate) {
    const size_t frames = (size_t)(5.0 * rate);
    Signal s = make_signal(frames, true, true);
    for (size_t i = 0; i < frames; ++i) {
        const double t = (double)i / rate;
        const double am = 0.6 + 0.4 * sin(tau() * 0.5 * t);
        double music = am * 0.05 * (sin(tau() * 80.0 * t)
            + sin(tau() * 220.0 * t) + sin(tau() * 440.0 * t));
        if (fmod(t, 0.5) < 0.005) music *= 10.0;  /* +20 dB, 5 ms burst */
        s.ref[i] = (float)music;
        s.anti[i] = (float)(-0.3 * music);
        s.err[i] = amp(-70.0) * noise();
    }
    N60AncGuard *guard = make_guard(rate, true);
    run(guard, &s, 0, frames);
    N60AncGuardStatus st = N60AncGuardReadStatus(guard);
    CHECK(st.trip == N60AncGuardTripNone, "%.0f Hz: programme tripped %d at %.3f s",
          rate, st.trip, (double)st.tripFrame / rate);
    N60AncGuardDestroy(guard);

    for (size_t i = 0; i < frames; ++i) {
        s.anti[i] = (float)(amp(-24.0) * sin(tau() * 50.0 * (double)i / rate));
    }
    guard = make_guard(rate, false);
    for (size_t i = 0; i < frames; i += CHUNK) {
        const uint32_t n = (uint32_t)((frames - i) < CHUNK ? (frames - i) : CHUNK);
        N60AncGuardProcess(guard, s.anti + i, NULL, NULL, n);
    }
    st = N60AncGuardReadStatus(guard);
    CHECK(st.trip == N60AncGuardTripNone, "%.0f Hz: stable tone tripped %d", rate, st.trip);
    CHECK(st.processedFrames == frames, "%.0f Hz: processed %llu", rate,
          (unsigned long long)st.processedFrames);
    N60AncGuardDestroy(guard);
    free_signal(&s);
}

/* An error-band rise trips at the end of the third block and the mute ramp
 * is linear over 10 ms with no step. */
static void error_rise_ramp_is_linear(double rate) {
    const size_t block = (size_t)lround(rate * N60_ANC_GUARD_BLOCK_SECONDS);
    const size_t ramp = ramp_frames(rate);
    const size_t frames = 6 * block;
    const double band = N60AncGuardBandCentreHz(6);
    Signal s = make_signal(frames, false, true);
    for (size_t i = 0; i < frames; ++i) {
        s.anti[i] = 0.1f;
        s.err[i] = (float)(0.3 * sin(tau() * band * (double)i / rate));
    }
    N60AncGuard *guard = make_guard(rate, true);
    run(guard, &s, 0, frames);
    const N60AncGuardStatus st = N60AncGuardReadStatus(guard);
    CHECK(st.trip == N60AncGuardTripErrorRise, "%.0f Hz: trip %d, want error rise", rate, st.trip);
    CHECK(st.tripFrame == 3 * block, "%.0f Hz: trip frame %llu, want %zu", rate,
          (unsigned long long)st.tripFrame, 3 * block);
    float largestStep = 0.0f;
    for (size_t i = 1; i < frames; ++i) {
        largestStep = fmaxf(largestStep, fabsf(s.anti[i] - s.anti[i - 1]));
    }
    CHECK(largestStep <= 0.1f / (float)ramp * 1.01f, "%.0f Hz: ramp step %g", rate, largestStep);
    for (size_t k = 0; k < ramp; ++k) {
        const float want = 0.1f * (1.0f - (float)(k + 1) / (float)ramp);
        const float got = s.anti[3 * block + k];
        if (fabsf(got - want) > 2e-6f) {
            CHECK(false, "%.0f Hz: ramp[%zu] %g, want %g", rate, k, got, want);
            break;
        }
    }
    CHECK(s.anti[3 * block + ramp - 1] == 0.0f, "%.0f Hz: not zero at ramp end", rate);
    free_signal(&s);
    N60AncGuardDestroy(guard);
}

/* Non-finite samples never pass and trip at once; over-ceiling samples are
 * clamped and trip at once. */
static void bad_samples_trip_immediately(double rate) {
    const size_t frames = (size_t)(0.1 * rate);
    Signal s = make_signal(frames, false, false);
    for (size_t i = 0; i < frames; ++i) {
        s.anti[i] = (float)(0.05 * sin(tau() * 60.0 * (double)i / rate));
    }
    s.anti[1000] = NAN;
    s.anti[1001] = INFINITY;
    N60AncGuard *guard = make_guard(rate, false);
    run(guard, &s, 0, frames);
    N60AncGuardStatus st = N60AncGuardReadStatus(guard);
    CHECK(st.trip == N60AncGuardTripNonFinite && st.tripFrame == 1000,
          "%.0f Hz: trip %d at %llu", rate, st.trip, (unsigned long long)st.tripFrame);
    for (size_t i = 0; i < frames; ++i) {
        if (!isfinite(s.anti[i])) {
            CHECK(false, "%.0f Hz: non-finite output at %zu", rate, i);
            break;
        }
    }
    N60AncGuardDestroy(guard);

    for (size_t i = 0; i < frames; ++i) {
        s.anti[i] = (float)(0.05 * sin(tau() * 60.0 * (double)i / rate));
    }
    s.anti[2000] = 0.9f;
    s.anti[2001] = -0.9f;
    guard = make_guard(rate, false);
    run(guard, &s, 0, frames);
    st = N60AncGuardReadStatus(guard);
    CHECK(st.trip == N60AncGuardTripOverCeiling && st.tripFrame == 2000,
          "%.0f Hz: trip %d at %llu", rate, st.trip, (unsigned long long)st.tripFrame);
    for (size_t i = 0; i < frames; ++i) {
        if (fabsf(s.anti[i]) > 0.5f) {
            CHECK(false, "%.0f Hz: %g above ceiling at %zu", rate, s.anti[i], i);
            break;
        }
    }
    free_signal(&s);
    N60AncGuardDestroy(guard);
}

/* A fade-in at half the growth threshold, and an error rise while the
 * anti-noise is silent, do not trip. */
static void contract_cases_do_not_trip(double rate) {
    const size_t frames = (size_t)(1.0 * rate);
    Signal s = make_signal(frames, false, true);
    for (size_t i = 0; i < frames; ++i) {
        const double t = (double)i / rate;
        const double db = fmin(-80.0 + 0.125 * 1000.0 * t, -24.0); /* 2.5 dB / 20 ms */
        s.anti[i] = (float)(amp(db) * sin(tau() * 60.0 * t));
    }
    N60AncGuard *guard = make_guard(rate, false);
    for (size_t i = 0; i < frames; i += CHUNK) {
        const uint32_t n = (uint32_t)((frames - i) < CHUNK ? (frames - i) : CHUNK);
        N60AncGuardProcess(guard, s.anti + i, NULL, NULL, n);
    }
    CHECK(N60AncGuardReadStatus(guard).trip == N60AncGuardTripNone,
          "%.0f Hz: slow fade-in tripped", rate);
    N60AncGuardDestroy(guard);

    const double band = N60AncGuardBandCentreHz(3);
    for (size_t i = 0; i < frames; ++i) {
        s.anti[i] = 0.0f;
        s.err[i] = (float)(0.3 * sin(tau() * band * (double)i / rate));
    }
    guard = make_guard(rate, true);
    run(guard, &s, 0, frames);
    CHECK(N60AncGuardReadStatus(guard).trip == N60AncGuardTripNone,
          "%.0f Hz: error rise with silent anti-noise tripped", rate);
    free_signal(&s);
    N60AncGuardDestroy(guard);
}

/* A howl that loops through the reference microphone grows in both signals;
 * the reference may excuse only 3 dB of it, so it still trips. A failed
 * (non-finite) reference or error microphone trips at once. */
static void loop_through_reference_trips(double rate) {
    const size_t onset = (size_t)(0.1037 * rate);
    const size_t frames = (size_t)(0.4 * rate);
    Signal s = make_signal(frames, true, true);
    for (size_t i = 0; i < frames; ++i) {
        const double t = (double)i / rate;
        /* 1 dB/ms: a loop-through howl must beat the 6 dB threshold plus the
         * 3 dB reference allowance by a margin to trip within 50 ms. */
        const double db = fmin(-50.0 + (i < onset ? 0.0 : 1000.0 * (t - (double)onset / rate)), -10.0);
        const double x = amp(db) * sin(tau() * 60.0 * t);
        s.anti[i] = (float)x;
        s.ref[i] = (float)(2.0 * x);
    }
    N60AncGuard *guard = make_guard(rate, false);
    run(guard, &s, 0, frames);
    N60AncGuardStatus st = N60AncGuardReadStatus(guard);
    CHECK(st.trip == N60AncGuardTripGrowth, "%.0f Hz: loop through reference: trip %d", rate, st.trip);
    CHECK(st.tripFrame > onset && st.tripFrame - onset <= (uint64_t)(0.050 * rate),
          "%.0f Hz: loop through reference tripped %.1f ms after onset", rate,
          ((double)st.tripFrame - (double)onset) * 1000.0 / rate);
    N60AncGuardDestroy(guard);

    for (int which = 0; which < 2; ++which) {
        for (size_t i = 0; i < frames; ++i) {
            s.anti[i] = (float)(0.05 * sin(tau() * 60.0 * (double)i / rate));
            s.ref[i] = 0.01f;
            s.err[i] = 0.0f;
        }
        if (which == 0) s.ref[3000] = NAN; else s.err[3000] = INFINITY;
        guard = make_guard(rate, true);
        run(guard, &s, 0, frames);
        st = N60AncGuardReadStatus(guard);
        CHECK(st.trip == N60AncGuardTripNonFinite && st.tripFrame == 3000,
              "%.0f Hz: failed %s mic: trip %d at %llu", rate, which ? "error" : "reference",
              st.trip, (unsigned long long)st.tripFrame);
        N60AncGuardDestroy(guard);
    }
    free_signal(&s);
}

static void config_validation(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        const N60AncGuardConfig config = N60AncGuardConfigDefault(kRates[r]);
        CHECK(N60AncGuardConfigIsValid(&config), "default invalid at %.0f Hz", kRates[r]);
    }
    N60AncGuardConfig bad = N60AncGuardConfigDefault(4000.0);
    CHECK(N60AncGuardCreate(&bad) == NULL, "4 kHz accepted");
    bad = N60AncGuardConfigDefault(48000.0);
    bad.muteRampSeconds = 0.0;
    CHECK(N60AncGuardCreate(&bad) == NULL, "zero ramp accepted");
    bad = N60AncGuardConfigDefault(48000.0);
    bad.hasErrorBaseline = true;
    bad.errorBaselineDB[4] = NAN;
    CHECK(N60AncGuardCreate(&bad) == NULL, "NaN baseline accepted");
    bad = N60AncGuardConfigDefault(48000.0);
    bad.outputCeiling = 1.5f;
    CHECK(N60AncGuardCreate(&bad) == NULL, "ceiling above full scale accepted");
    bad = N60AncGuardConfigDefault(48000.0);
    bad.growthDBPer20ms = 1e30f;
    CHECK(N60AncGuardCreate(&bad) == NULL, "growth threshold that disables detection accepted");
    bad = N60AncGuardConfigDefault(48000.0);
    bad.errorRiseDB = 100.0f;
    CHECK(N60AncGuardCreate(&bad) == NULL, "error threshold above 40 dB accepted");
    bad = N60AncGuardConfigDefault(48000.0);
    bad.referenceAllowanceDB = 60.0f;
    CHECK(N60AncGuardCreate(&bad) == NULL, "reference allowance above 20 dB accepted");
    CHECK(fabs(N60AncGuardBandCentreHz(0) - 20.0) < 1e-9
          && fabs(N60AncGuardBandCentreHz(15) - 500.0) < 1e-9, "band edges");
}

int main(void) {
    config_validation();
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        const double rate = kRates[r];
        growth_trips_and_latches(rate);
        normal_programme_does_not_trip(rate);
        error_rise_ramp_is_linear(rate);
        bad_samples_trip_immediately(rate);
        contract_cases_do_not_trip(rate);
        loop_through_reference_trips(rate);
    }
    if (failures) {
        fprintf(stderr, "e4_anc_guard: %d failure(s)\n", failures);
        return 1;
    }
    puts("e4_anc_guard: all scenarios pass at 8 rates");
    return 0;
}
