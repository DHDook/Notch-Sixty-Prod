// E36 S3: behavioural tests for the virtual driver programme ring and clock steering (n60/vd_ring.h) at the eight
// standard rates. Deterministic: seeded generator, no wall clock.
#include "n60/vd_ring.h"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

static int failures = 0;
#define CHECK(cond, msg)                                                  \
    do {                                                                  \
        if (!(cond)) {                                                    \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); \
            ++failures;                                                   \
        }                                                                 \
    } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const uint32_t kChannels[] = {2, 6, 8, 12, 16};  // stereo, 5.1, 7.1, 7.1.4, the build constant

struct Lcg {
    uint32_t s;
    uint32_t next() { s = s * 1664525u + 1013904223u; return s >> 8; }
    double unit() { return (next() & 0xFFFF) / 65536.0; }
};

// Sample value is a pure function of (frame, channel) so any gap or reorder shows.
static float sampleAt(uint64_t frame, uint32_t ch) { return static_cast<float>(frame % 100003u) + 0.001f * static_cast<float>(ch); }

static std::vector<unsigned char> makeRing(uint32_t channels, uint32_t rate) {
    std::vector<unsigned char> mem(N60_VD_RING_BYTES, 0);
    CHECK(n60_vd_ring_writer_init(mem.data(), mem.size(), channels, rate) == N60_VD_OK, "writer init");
    return mem;
}

static void writeFrames(std::vector<unsigned char> &mem, uint32_t channels, uint64_t first, uint32_t count) {
    std::vector<float> block(static_cast<size_t>(count) * channels);
    for (uint32_t i = 0; i < count; ++i)
        for (uint32_t c = 0; c < channels; ++c) block[static_cast<size_t>(i) * channels + c] = sampleAt(first + i, c);
    n60_vd_ring_write(mem.data(), block.data(), count, 1);
}

static void testGeometry() {
    CHECK(n60_vd_ring_abi_version() == N60_VD_RING_ABI_VERSION, "abi version");
    CHECK(n60_vd_ring_capacity_frames(0) == 0 && n60_vd_ring_capacity_frames(17) == 0, "invalid channels");
    // 384 kHz with 12 channels fits the fixed ring with at least 0.4 s of room; so does 16 channels with 0.3 s.
    CHECK(n60_vd_ring_capacity_frames(12) >= 0.4 * 384000.0, "12 channels at 384 kHz fit");
    CHECK(n60_vd_ring_capacity_frames(16) >= 0.3 * 384000.0, "16 channels at 384 kHz fit");
    CHECK(sizeof(n60_vd_ring_header) <= N60_VD_RING_HEADER_BYTES, "header fits");
    std::vector<unsigned char> mem(N60_VD_RING_BYTES, 0);
    n60_vd_ring_reader r;
    CHECK(n60_vd_ring_reader_attach(&r, mem.data(), mem.size(), 0) == N60_VD_ERR_MAGIC, "blank memory refused");
    CHECK(n60_vd_ring_reader_attach(&r, mem.data(), 100, 0) == N60_VD_ERR_ARGUMENT, "short mapping refused");
    CHECK(n60_vd_ring_writer_init(mem.data(), mem.size(), 17, 48000) == N60_VD_ERR_GEOMETRY, "17 channels refused");
    n60_vd_ring_writer_init(mem.data(), mem.size(), 2, 48000);
    reinterpret_cast<n60_vd_ring_header *>(mem.data())->layoutVersion = 99;
    CHECK(n60_vd_ring_reader_attach(&r, mem.data(), mem.size(), 0) == N60_VD_ERR_VERSION, "unknown layout version refused");
}

// Steady state: writer and reader at the same clock, jittered block sizes; every sample arrives in order, bit exact.
static void testStreaming(double rate, uint32_t channels) {
    auto mem = makeRing(channels, static_cast<uint32_t>(rate));
    n60_vd_ring_reader reader;
    CHECK(n60_vd_ring_reader_attach(&reader, mem.data(), mem.size(), 1024) == N60_VD_OK, "attach");
    Lcg rng{static_cast<uint32_t>(rate) ^ channels};
    uint64_t written = 0, expected = 0;
    bool started = false;
    const uint32_t outCh = 2;  // the stereo bridge: first two programme channels
    std::vector<float> out(2048 * outCh);
    uint64_t mismatches = 0, real = 0;
    const uint64_t total = static_cast<uint64_t>(rate * 2.0);
    while (written < total) {
        const uint32_t block = 128 + (rng.next() % 384);  // reader callback size
        // The writer is a little ahead, in bursts different from the reader's.
        const uint32_t burst = block + (rng.next() % 5) - 2;
        writeFrames(mem, channels, written, burst);
        written += burst;
        const uint32_t got = n60_vd_ring_read(&reader, out.data(), block, outCh);
        if (got > 0 && !started) { started = true; expected = reader.readPos - got; }
        for (uint32_t i = 0; i < got; ++i) {
            for (uint32_t c = 0; c < outCh; ++c)
                if (out[i * outCh + c] != sampleAt(expected + i, c)) ++mismatches;
        }
        if (got < block) {
            for (uint32_t i = got; i < block; ++i)
                for (uint32_t c = 0; c < outCh; ++c) if (out[i * outCh + c] != 0.0f) ++mismatches;
        }
        expected += got;
        real += got;
    }
    CHECK(started && real > total / 2, "audio flowed");
    CHECK(mismatches == 0, "bit exact, in order");
    CHECK(reader.droppedFrames == 0 && reader.overruns == 0, "no drops at matched clocks");
}

static void testChannelMapping() {
    auto mem = makeRing(6, 48000);
    n60_vd_ring_reader reader;
    n60_vd_ring_reader_attach(&reader, mem.data(), mem.size(), 64);
    writeFrames(mem, 6, 0, 256);
    std::vector<float> out(64 * 8);
    uint32_t got = n60_vd_ring_read(&reader, out.data(), 64, 8);  // wider than the ring: extras are zero
    CHECK(got == 64, "full block");
    bool ok = true;
    for (uint32_t i = 0; i < got; ++i) {
        for (uint32_t c = 0; c < 6; ++c) ok = ok && out[i * 8 + c] == sampleAt(reader.readPos - got + i, c);
        ok = ok && out[i * 8 + 6] == 0.0f && out[i * 8 + 7] == 0.0f;
    }
    CHECK(ok, "extra output channels are silent");
}

// A callback larger than the default prime level works when the prime level is two callbacks (what the app passes).
static void testLargeCallbacks() {
    for (double rate : kRates) {
        auto mem = makeRing(12, static_cast<uint32_t>(rate));
        n60_vd_ring_reader reader;
        CHECK(n60_vd_ring_reader_attach(&reader, mem.data(), mem.size(), 2 * 2048) == N60_VD_OK, "attach");
        std::vector<float> out(2048 * 2);
        uint64_t written = 0;
        writeFrames(mem, 12, 0, 4096);
        written = 4096;
        for (int i = 0; i < 200; ++i) {
            writeFrames(mem, 12, written, 2048);
            written += 2048;
            n60_vd_ring_read(&reader, out.data(), 2048, 2);
        }
        CHECK(reader.underrunFrames == 0 && reader.droppedFrames == 0, "2048-frame callbacks stream cleanly");
    }
}

static void testUnderrunAndPrime() {
    auto mem = makeRing(2, 48000);
    n60_vd_ring_reader reader;
    n60_vd_ring_reader_attach(&reader, mem.data(), mem.size(), 256);
    std::vector<float> out(512 * 2, 1.0f);
    CHECK(n60_vd_ring_read(&reader, out.data(), 128, 2) == 0 && out[0] == 0.0f, "silence before data");
    CHECK(reader.underrunFrames == 0, "start-up silence is not an underrun");
    writeFrames(mem, 2, 0, 200);
    CHECK(n60_vd_ring_read(&reader, out.data(), 128, 2) == 0, "below the prime level stays silent");
    writeFrames(mem, 2, 200, 200);
    CHECK(n60_vd_ring_read(&reader, out.data(), 128, 2) == 128, "primed: audio flows");
    // Drain: 272 left, ask for 512.
    const uint32_t got = n60_vd_ring_read(&reader, out.data(), 512, 2);
    CHECK(got == 272, "partial block when the ring runs dry");
    CHECK(reader.underrunFrames == 512 - 272, "underrun counted");
    CHECK(out[got * 2] == 0.0f && out[511 * 2] == 0.0f, "rest is silence");
    // Re-primes before playing again.
    writeFrames(mem, 2, 400, 100);
    CHECK(n60_vd_ring_read(&reader, out.data(), 64, 2) == 0, "re-prime after an underrun");
}

static void testDropAndEpoch() {
    auto mem = makeRing(2, 48000);
    n60_vd_ring_reader reader;
    n60_vd_ring_reader_attach(&reader, mem.data(), mem.size(), 512);
    std::vector<float> out(256 * 2);
    uint64_t written = 0;
    const uint32_t cap = n60_vd_ring_capacity_frames(2);
    while (written < cap * 3 / 4) { writeFrames(mem, 2, written, 4096); written += 4096; }
    const uint32_t got = n60_vd_ring_read(&reader, out.data(), 256, 2);
    CHECK(got == 256 && reader.droppedFrames > 0, "a ring that ran too full drops to the prime level");
    CHECK(out[0] == sampleAt(written - 512, 0), "after the drop, the newest prime level is played");
    CHECK(reader.fillFrames == 512 - 256, "fill reported");
    // Writer restart: epoch changes, reader re-primes at the new position.
    n60_vd_ring_writer_init(mem.data(), mem.size(), 2, 48000);
    CHECK(n60_vd_ring_read(&reader, out.data(), 256, 2) == 0 && reader.epochChanges == 1, "epoch change re-primes");
    writeFrames(mem, 2, 0, 1024);
    CHECK(n60_vd_ring_read(&reader, out.data(), 256, 2) == 256 && out[0] == sampleAt(0, 0), "plays the new stream from its start");
    // Restart with a different channel count: the reader re-reads the geometry and plays aligned audio.
    n60_vd_ring_writer_init(mem.data(), mem.size(), 6, 48000);
    CHECK(n60_vd_ring_read(&reader, out.data(), 256, 2) == 0, "re-primes after a geometry change");
    writeFrames(mem, 6, 0, 1024);
    CHECK(n60_vd_ring_read(&reader, out.data(), 256, 2) == 256 && out[0] == sampleAt(0, 0) && out[1] == sampleAt(0, 1) &&
              out[2] == sampleAt(1, 0), "aligned after a channel-count change");
    // Invalid header: write refuses instead of dividing by zero.
    std::vector<unsigned char> blank(N60_VD_RING_BYTES, 0);
    float one[2] = {0, 0};
    CHECK(n60_vd_ring_write(blank.data(), one, 1, 0) == 0, "write on an unwritten ring does nothing");
}

// Two real threads: nothing torn, nothing out of order (frames may be dropped, never reordered or mixed).
static void testThreads() {
    auto mem = makeRing(2, 48000);
    n60_vd_ring_reader reader;
    n60_vd_ring_reader_attach(&reader, mem.data(), mem.size(), 1024);
    std::atomic<bool> done{false};
    std::atomic<uint64_t> published{0};
    std::thread writer([&] {
        uint64_t n = 0;
        std::vector<float> block(480 * 2);
        for (int burst = 0; burst < 4000; ++burst) {  // a fixed amount of audio, then done: no wall-clock dependence
            for (uint32_t i = 0; i < 480; ++i) { block[i * 2] = sampleAt(n + i, 0); block[i * 2 + 1] = sampleAt(n + i, 1); }
            n60_vd_ring_write(mem.data(), block.data(), 480, 1);
            n += 480;
            published.store(n);
            std::this_thread::yield();
        }
        done.store(true);
    });
    while (published.load() < 4096) std::this_thread::yield();  // the writer has started; bounded by its fixed work
    std::vector<float> out(300 * 2);
    uint64_t bad = 0, real = 0;
    // Read while the writer runs, then drain what is left: after `done` the ring holds far more than the prime level,
    // so audio is guaranteed to arrive however the threads were scheduled.
    bool finished = false;
    while (!finished) {
        finished = done.load();
        const uint32_t got = n60_vd_ring_read(&reader, out.data(), 300, 2);
        for (uint32_t k = 0; k < got; ++k) {
            if (std::fabs(out[k * 2 + 1] - (out[k * 2] + 0.001f)) > 1e-3f) ++bad;
            ++real;
        }
    }
    writer.join();
    CHECK(bad == 0, "no torn frames across threads");
    CHECK(real > 0, "audio arrived");
}

// Steering against a model of the driver clock. fill' = rate * ((1 + ppm) * scalar - 1).
struct SteerRun { double finalScalar; double tailMeanScalar; double maxAbsErrFrames; double settledAtSec; double minFill, maxFill; };

static SteerRun runSteer(double rate, double ppm, double seconds, double settleTol, bool noise) {
    const uint32_t target = static_cast<uint32_t>(rate * 0.02);  // 20 ms
    n60_vd_steer s;
    n60_vd_steer_init(&s, rate, target);
    double fill = target;
    Lcg rng{12345};
    const double dt = 0.25;
    SteerRun r{1.0, 1.0, 0, -1, fill, fill};
    double tailSum = 0; int tailCount = 0;
    const double p = ppm * 1e-6;
    for (double t = 0; t < seconds; t += dt) {
        fill += rate * dt * ((1.0 + p) * s.scalar - 1.0);
        const double measured = fill + (noise ? (rng.unit() - 0.5) * 8.0 : 0.0);  // mean over a 250 ms window of many reads: a few frames of jitter
        n60_vd_steer_update(&s, measured, dt);
        if (t > seconds - 10.0) { tailSum += s.scalar; ++tailCount; }
        const double err = std::fabs(fill - target);
        if (err > r.maxAbsErrFrames) r.maxAbsErrFrames = err;
        if (fill < r.minFill) r.minFill = fill;
        if (fill > r.maxFill) r.maxFill = fill;
        if (r.settledAtSec < 0 && std::fabs((s.scalar - 1.0) * 1e6 + ppm) < settleTol && err < rate * 0.001) r.settledAtSec = t + dt;
        if (r.settledAtSec >= 0 && (std::fabs((s.scalar - 1.0) * 1e6 + ppm) >= settleTol * 5)) r.settledAtSec = -1;
    }
    r.finalScalar = s.scalar;
    r.tailMeanScalar = tailCount ? tailSum / tailCount : s.scalar;
    return r;
}

static void testSteering() {
    const double offsets[] = {-200.0, -50.0, 0.0, 50.0, 200.0};
    for (double rate : kRates) {
        for (double ppm : offsets) {
            const SteerRun r = runSteer(rate, ppm, 30.0, 40.0, true);
            CHECK(r.settledAtSec > 0 && r.settledAtSec <= 10.0, "converges within 10 s for +-200 ppm");
            CHECK(std::fabs((r.tailMeanScalar - 1.0) * 1e6 + ppm) < 8.0, "scalar cancels the offset");
            CHECK(r.maxAbsErrFrames < rate * 0.003, "fill stays within 3 ms of the target while converging");
        }
        // 24 simulated hours: bounded fill, no excursion towards empty or the drop level.
        const SteerRun day = runSteer(rate, 180.0, 24.0 * 3600.0, 10.0, true);
        CHECK(day.minFill > 0.5 * rate * 0.02 && day.maxFill < 1.5 * rate * 0.02, "24 h fill stays inside its bounds");
        // Clamp: an offset beyond the authority cannot push the scalar past 1 +- 1000 ppm.
        n60_vd_steer s; n60_vd_steer_init(&s, rate, 100);
        for (int i = 0; i < 400; ++i) n60_vd_steer_update(&s, 1e7, 0.25);
        CHECK(s.scalar >= 1.0 - 1.0001e-3 && s.scalar <= 1.0 + 1.0001e-3, "scalar clamped");
    }
}

// The measured mean fill the control plane sees is a window average of the realtime reads.
static void testMeanFill() {
    auto mem = makeRing(2, 48000);
    n60_vd_ring_reader reader;
    n60_vd_ring_reader_attach(&reader, mem.data(), mem.size(), 256);
    uint64_t ps = 0, pc = 0;
    CHECK(n60_vd_ring_reader_mean_fill(&reader, &ps, &pc) < 0, "no samples yet");
    writeFrames(mem, 2, 0, 1000);
    std::vector<float> out(100 * 2);
    n60_vd_ring_read(&reader, out.data(), 100, 2);  // fill 900 after
    n60_vd_ring_read(&reader, out.data(), 100, 2);  // 800
    CHECK(std::fabs(n60_vd_ring_reader_mean_fill(&reader, &ps, &pc) - 850.0) < 1e-9, "window mean");
    CHECK(n60_vd_ring_reader_mean_fill(&reader, &ps, &pc) < 0, "empty window");
}

int main() {
    testGeometry();
    for (double rate : kRates)
        for (uint32_t ch : kChannels) testStreaming(rate, ch);
    testChannelMapping();
    testLargeCallbacks();
    testUnderrunAndPrime();
    testDropAndEpoch();
    testThreads();
    testSteering();
    testMeanFill();
    if (failures) { std::fprintf(stderr, "%d failures\n", failures); return 1; }
    std::puts("vd ring tests passed");
    return 0;
}
