// E20 S1: render benchmark harness for libn60core (portable C++, no Apple framework; see docs/PERFORMANCE.md).
//
// Scenarios (docs/epics/E20.md design note 3):
//   R1 stereo, every stage on, plus 2 subs      R2 5.1 plus 2 subs, room FIR per lane
//   R3 7.1.4 plus 4 subs                        R4 262,144-tap FIR on 2 and 8 lanes (R4a, R4b); 32,768 taps (R4c, R4d, E9 S8)
//   R5 binaural, 16 sources, 8,192 taps         R6 wide PEQ at the 512-slot cap (E6 G30)
//   R8 MIMO treatment stage, 8 sources, armed (E20 S8)
//   R7 ANC lane feed maths, offline (built only with -DN60_BENCH_ANC; compute only, nothing reaches a device)
// at the eight standard rates and two block sizes: "ref" is 2.67 ms (128 frames at 48 kHz, 1,024 at 384 kHz) and
// "stress" a quarter of that. Load = render time / buffer period on one core. Each cell reports the median of
// --runs runs of the mean load (median) and of the p99.9 block load (best, i.e. lowest, of the runs: a hosted runner's
// scheduling tail hits single runs, and the default is five runs so at least best-of-3), plus the worst block seen (max).
//
// Output is flat JSON ("R1/48000/ref/mean": 0.0123). --baseline compares every */mean key with a stored file:
// fail above 1.5x, warn above 1.2x. --budgets checks the "ref" rows against budgets.json (E20 Q1); budget breaches
// are warnings until --enforce-budgets (turned on by E20 S10). --profile-only skips the load numbers (the hooks distort
// them) and reports only the profile rows. With a build that defines N60_GRAPH_PROFILE for
// libn60core (see n60/profile.h), --profile also reports per-stage-kind ns per lane-sample ("R1/48000/prof/17").
//
// Realtime: this is a test tool; it allocates freely outside the timed region and never inside process().
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <condition_variable>
#include <map>
#include <mutex>
#include <atomic>
#include <thread>
#include <sstream>
#include <string>
#include <vector>

#include "n60/graph.h"
#include "n60/mimo.h"
#include "n60/profile.h"

#ifdef N60_BENCH_ANC
#include "N60AncLaneFeed.h"
#endif

// -DN60_BENCH_PROFILE links the per-stage hooks of a libn60core built with -DN60_GRAPH_PROFILE; without it the
// harness runs against product objects and --profile is a no-op.
#ifdef N60_BENCH_PROFILE
static void profReset() { n60_profile_reset(); }
static uint32_t profRead(n60_profile_entry *e, uint32_t n) { return n60_profile_read(e, n); }
#else
static void profReset() {}
static uint32_t profRead(n60_profile_entry *, uint32_t) { return 0; }
#endif

namespace {

constexpr double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
constexpr uint32_t kMaxLanes = 24;

uint64_t mix(uint64_t x) {
    x += 0x9E3779B97F4A7C15ull;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
    return x ^ (x >> 31);
}
float noise(uint64_t pos, uint64_t seed) {
    return static_cast<float>(static_cast<int64_t>(mix(pos * 64 + seed * 0x1000193ull)) >> 40) / 8388608.0f * 0.25f;
}
std::vector<float> decaying(uint32_t taps, uint64_t seed, float scale) {
    std::vector<float> h(taps);
    for (uint32_t n = 0; n < taps; ++n) h[n] = noise(n, seed) * scale * static_cast<float>(std::exp(-6.0 * n / taps));
    return h;
}

// Block lengths: ref is 128 frames scaled by the rate's octave above 48 kHz, stress is a quarter of it.
uint32_t refFrames(double rate) {
    uint32_t f = 128;
    for (double r = 88000; r <= rate; r *= 2) f *= 2;
    return f;
}

// ---- Scenario graph description ---------------------------------------------------------------------------------

struct Built {
    std::deque<std::vector<float>> store;
    std::vector<n60_stage_desc> stages;
    n60_layout_graph *layoutGraph = nullptr;
    n60_graph_desc desc{};
    uint32_t lanes = 0;
    bool ok = true;
    std::string why;
    ~Built() { n60_layout_graph_free(layoutGraph); }

    const float *keep(std::vector<float> v) {
        store.push_back(std::move(v));
        return store.back().data();
    }
    void add(uint32_t kind, uint32_t id, std::vector<float> p, uint64_t mask = 0, uint32_t laneA = N60_LANE_ALL, uint32_t laneB = 0) {
        n60_stage_desc s;
        std::memset(&s, 0, sizeof s);
        s.structSize = sizeof s;
        s.kind = kind;
        s.stageId = id;
        s.laneA = mask != 0 ? 0 : laneA;
        s.laneB = laneB;
        s.laneMask = mask;
        s.paramCount = static_cast<uint32_t>(p.size());
        s.params = p.empty() ? nullptr : keep(std::move(p));
        stages.push_back(s);
    }
    void begin(double rate, uint32_t block, uint32_t laneCount) {
        lanes = laneCount;
        std::memset(&desc, 0, sizeof desc);
        desc.structSize = sizeof desc;
        desc.abiVersion = N60_GRAPH_ABI_VERSION;
        desc.sampleRate = rate;
        desc.maxBlockFrames = block;
        desc.inputChannels = desc.outputChannels = laneCount;
        desc.firScheme = N60_FIR_SCHEME_NONUNIFORM;
    }
    const n60_graph_desc *finish() {
        desc.stages = stages.data();
        desc.stageCount = static_cast<uint32_t>(stages.size());
        return &desc;
    }
};

uint64_t maskOf(uint32_t first, uint32_t count) {
    uint64_t m = 0;
    for (uint32_t i = 0; i < count; ++i) m |= 1ull << (first + i);
    return m;
}

// Every stage of the production chain on `mains` main lanes (0..mains-1) and `subs` sub lanes after them.
void fullChain(Built &b, double rate, uint32_t mains, uint32_t subs, uint32_t roomTaps) {
    const uint32_t lanes = mains + subs;
    const uint64_t mainMask = maskOf(0, mains);
    std::vector<float> cleanup(26, 0.0f);
    cleanup[0] = 1; cleanup[1] = 1; cleanup[2] = 20; cleanup[3] = 1; cleanup[5] = 50; cleanup[6] = 3; cleanup[7] = 20; cleanup[9] = 50;
    for (int i = 10; i < 26; ++i) cleanup[i] = -30;
    b.add(N60_STAGE_SANITISE, 1, {});
    b.add(N60_STAGE_METER_IN, 2, {});
    b.add(N60_STAGE_GAIN, 3, {0.8f});
    b.add(N60_STAGE_CLEANUP, 4, cleanup, 0, 0, 1);
    b.add(N60_STAGE_PEQ, 5, {0, 60, 9, 2, 2, 6000, -6, 0.7f, 0, 250, -3, 1.2f, 0, 1500, 2, 1.5f});
    b.add(N60_STAGE_DYN_EQ, 6, {1, 0, 1000, 1, 0, -40, 3, -12, 10, 100, 0, -40, 3, 6, 0, 20});
    b.add(N60_STAGE_FIR, 7, decaying(2048, 5, 0.02f), mainMask);
    b.add(N60_STAGE_COMPRESSOR, 8, {-30, 4, 6, 5, 80, 2, 0, 1, 100, 1});
    b.add(N60_STAGE_EXPANDER, 9, {-50, 2, -20, 5, 80, 1});
    b.add(N60_STAGE_METER_OUT, 10, {});
    std::vector<float> bm = {80, 0, static_cast<float>(mains), -1, 120, 0, 0, 0, 0};
    if (subs > 1) {
        bm.push_back(static_cast<float>(subs - 1));  // extension word: extra subs
        for (uint32_t s = 1; s < subs; ++s) { bm.push_back(static_cast<float>(mains + s)); bm.push_back(0); bm.push_back(0); bm.push_back(0); }
    }
    b.add(N60_STAGE_BASS_MGMT, 11, bm, mainMask);
    b.add(N60_STAGE_ROOM_FIR, 12, decaying(roomTaps, 6, 0.02f), mainMask);
    b.add(N60_STAGE_AMBIENT, 13, {3, 100, 0, 1, 1000, 1, 1, 8000, 0, 1});
    b.add(N60_STAGE_CORE_DYNAMICS, 14, {-30, 4, 6, 5, 80, 2, 0, 1, 100, 1});
    b.add(N60_STAGE_OUTPUT_GAIN, 15, {0.9f});
    b.add(N60_STAGE_PROTECTION, 16, {1, -1, 1, 50, 5, 1, 2});
    b.add(N60_STAGE_FINAL_SANITISE, 17, {});
    b.add(N60_STAGE_FINAL_METER, 18, {});
    (void)rate;
    (void)lanes;
}

void longFir(Built &b, uint32_t lanes, uint32_t taps = 262144) {
    b.add(N60_STAGE_SANITISE, 1, {});
    b.add(N60_STAGE_FIR, 2, decaying(taps, 7, 0.01f));
    b.add(N60_STAGE_FINAL_METER, 3, {});
    (void)lanes;
}

void widePeq(Built &b, double rate) {
    b.add(N60_STAGE_SANITISE, 1, {});
    const double top = std::min(18000.0, 0.45 * rate);
    for (uint32_t st = 0; st < 32; ++st) {  // 32 stages x 16 sections = the 512-slot cap
        std::vector<float> p;
        for (uint32_t s = 0; s < 16; ++s) {
            const double u = (st * 16.0 + s) / 511.0;
            p.push_back(0);
            p.push_back(static_cast<float>(30.0 * std::pow(top / 30.0, u)));
            p.push_back((s & 1u) ? 1.0f : -1.0f);
            p.push_back(1.4f);
        }
        b.add(N60_STAGE_PEQ, 10 + st, p);
    }
    b.add(N60_STAGE_FINAL_METER, 3, {});
}

// R8 (E20 S8, G30): the E19 MIMO treatment stage armed on 8 source lanes with 4,096 low-rate taps per filter, the
// largest the stage accepts. It already runs its filters at fs/D (graph.h "MIMO treatment"), so this is the cost of the
// treatment injection filters as shipped.
void mimoTreatment(Built &b, double rate) {
    uint32_t D = 0;
    double lr = 0;
    n60_mimo_low_rate(rate, &D, &lr);
    const uint32_t S = 8, T = 4096;
    std::vector<float> p = {static_cast<float>(D), static_cast<float>(T), static_cast<float>(S), 0.0f, 1.0f, 0.0f, 0.0f, 0.0f};
    for (uint32_t s = 0; s < S; ++s) p.push_back(10.0f);
    const std::vector<float> taps = decaying(S * S * T, 11, 0.001f);
    p.insert(p.end(), taps.begin(), taps.end());
    b.add(N60_STAGE_SANITISE, 1, {});
    b.add(N60_STAGE_MIMO, 2, p, maskOf(0, S));
    b.add(N60_STAGE_FINAL_METER, 3, {});
}

// Scenario ids. R4 splits into 2 and 8 lanes.
const char *const kScenarioIds[] = {"R1", "R2", "R3", "R4a", "R4b", "R4c", "R4d", "R5", "R6", "R7", "R8"};

bool buildScenario(const std::string &id, double rate, uint32_t block, Built &b) {
    if (id == "R1") { b.begin(rate, block, 4); fullChain(b, rate, 2, 2, 8192); return true; }
    if (id == "R2") { b.begin(rate, block, 8); fullChain(b, rate, 6, 2, 4096); return true; }
    if (id == "R3") { b.begin(rate, block, 16); fullChain(b, rate, 12, 4, 4096); return true; }
    if (id == "R4a") { b.begin(rate, block, 2); longFir(b, 2); return true; }
    if (id == "R4b") { b.begin(rate, block, 8); longFir(b, 8); return true; }
    // E9 S1 benchmark rows: the 32,768-tap FIR (the uniform scheme's ceiling) on 2 and 8 lanes, the comparison for R4a and R4b.
    if (id == "R4c") { b.begin(rate, block, 2); longFir(b, 2, 32768); return true; }
    if (id == "R4d") { b.begin(rate, block, 8); longFir(b, 8, 32768); return true; }
    if (id == "R8") { b.begin(rate, block, 8); mimoTreatment(b, rate); return true; }
    if (id == "R6") { b.begin(rate, block, 2); widePeq(b, rate); return true; }
    if (id == "R5") {
        n60_layout lay;
        n60_layout_standard(N60_LAYOUT_9_1_6, &lay);
        const uint32_t taps = 8192;
        std::vector<float> ir(static_cast<size_t>(lay.channelCount) * 2 * taps);
        for (size_t i = 0; i < ir.size(); ++i) ir[i] = noise(i, 9) * 0.5f * static_cast<float>(std::exp(-6.0 * double(i % taps) / taps));
        n60_binaural_profile p;
        std::memset(&p, 0, sizeof p);
        p.structSize = sizeof p;
        p.taps = taps;
        p.orientations = 1;
        p.equalEarChannel = -1;
        p.responses = ir.data();
        n60_layout_options o;
        std::memset(&o, 0, sizeof o);
        o.structSize = sizeof o;
        o.sampleRate = rate;
        o.maxBlockFrames = block;
        o.layout = &lay;
        o.graphChannels = lay.channelCount;
        o.mode = N60_MODE_BINAURAL;
        o.binaural = &p;
        o.protection = 1;
        if (n60_layout_graph_build(&o, &b.layoutGraph) != N60_STATUS_OK) { b.why = "layout build failed"; return false; }
        b.lanes = lay.channelCount;
        b.desc = *n60_layout_graph_desc(b.layoutGraph);
        return true;
    }
    return false;
}

// ---- Timing -----------------------------------------------------------------------------------------------------

struct Cell {
    double mean = 0, p999 = 0, max = 0;
};

double median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v.empty() ? 0.0 : v[v.size() / 2];
}

using Clock = std::chrono::steady_clock;

struct Signal {
    std::vector<float> data;
    Signal() : data((1u << 16) + 4096) { for (size_t i = 0; i < data.size(); ++i) data[i] = noise(i, 3); }
    const float *at(uint64_t blk, uint32_t lane, uint32_t frames) const {
        return data.data() + ((blk * 509u + lane * 7919u) % (1u << 16)) + 0 * frames;
    }
};

struct Config {
    std::vector<double> rates{std::begin(kRates), std::end(kRates)};
    std::vector<std::string> scenarios{std::begin(kScenarioIds), std::end(kScenarioIds)};
    double seconds = 0.2;
    int runs = 5;
    bool profile = false, profileOnly = false, enforceBudgets = false, selfTest = false;
    uint32_t workers = 0;  // E20 S10: R2 and R3 also run on this many worker threads (label "refw"), the budget rows
    std::string out, baseline, budgets;
};

bool graphRun(n60_graph *g, uint32_t lanes, uint32_t frames, uint64_t blk, const Signal &sig, std::vector<float> &outBuf) {
    const float *ip[kMaxLanes];
    float *op[kMaxLanes];
    for (uint32_t l = 0; l < lanes; ++l) { ip[l] = sig.at(blk, l, frames); op[l] = outBuf.data() + size_t(l) * 4096; }
    const bool ok = n60_graph_process(g, ip, op, frames) == N60_STATUS_OK;
    n60_graph_collect(g);
    return ok;
}

// Runs `runs` passes of `blocks` blocks; fills the cell and (optionally) the per-kind profile. Returns false on error.
bool timeGraph(n60_graph *g, uint32_t lanes, double rate, uint32_t frames, const Config &cfg, Cell &cell, bool &finite) {
    static const Signal sig;
    std::vector<float> outBuf(size_t(lanes) * 4096, 0.0f);
    const double period = frames / rate;
    const uint64_t blocks = std::max<uint64_t>(32, static_cast<uint64_t>(cfg.seconds * rate / frames));
    uint64_t blk = 0;
    for (int i = 0; i < 64; ++i) if (!graphRun(g, lanes, frames, blk++, sig, outBuf)) return false;  // warm-up
    std::vector<double> means, p999s;
    std::vector<double> times(blocks);
    double worst = 0;
    finite = true;
    for (int run = 0; run < cfg.runs; ++run) {
        double sum = 0;
        for (uint64_t i = 0; i < blocks; ++i) {
            const auto t0 = Clock::now();
            const bool ok = graphRun(g, lanes, frames, blk++, sig, outBuf);
            const auto t1 = Clock::now();
            if (!ok) return false;
            times[i] = std::chrono::duration<double>(t1 - t0).count() / period;
            sum += times[i];
        }
        for (uint32_t l = 0; l < lanes; ++l) for (uint32_t i = 0; i < frames; ++i) if (!std::isfinite(outBuf[size_t(l) * 4096 + i])) finite = false;
        std::vector<double> sorted(times);
        std::sort(sorted.begin(), sorted.end());
        means.push_back(sum / blocks);
        p999s.push_back(sorted[std::min<size_t>(sorted.size() - 1, static_cast<size_t>(0.999 * sorted.size()))]);
        worst = std::max(worst, sorted.back());
    }
    cell.mean = median(means);
    cell.p999 = *std::min_element(p999s.begin(), p999s.end());  // best of the runs: single-run runner tail noise
    cell.max = worst;
    return true;
}

#ifdef N60_BENCH_ANC
bool timeAnc(double rate, uint32_t frames, const Config &cfg, Cell &cell) {
    constexpr uint32_t kCh = 6;
    N60AncLaneFeedConfig c = {};
    N60SpeakerBusSplitterSnapshot splitter;
    if (!N60SpeakerBusSplitterSnapshotMake(rate, N60SpeakerCrossoverModeMainsSub, 80.0, N60CrossoverTopologyLinkwitzRiley24, 2000.0,
                                           N60CrossoverTopologyLinkwitzRiley24, 1.0f, false, false, 80.0, 0.707, &splitter)) return false;
    N60ActiveQuietZoneSnapshot tonal = N60ActiveQuietZoneSnapshotMakeBypassed();
    N60ActiveQuietZoneToneSnapshot t[1] = {};
    t[0].frequencyHz = 60.0; t[0].leftReal = 0.05f; t[0].rightReal = 0.05f;
    if (!N60ActiveQuietZoneSnapshotSet(&tonal, t, 1u, 64u, rate, true)) return false;
    tonal.armGeneration = 1;
    c.sampleRate = rate; c.maxBlockFrames = 4096; c.channels = kCh;
    c.programmeLeft = 0; c.programmeRight = 1; c.sourceLeft = 2; c.sourceRight = 3; c.sourceSub = 4;
    c.splitter = splitter; c.peakLimit = 1.0f; c.fadeInSeconds = 0.0;
    N60AncLaneFeed *feed = N60AncLaneFeedCreate(&c);
    if (feed == nullptr) return false;
    N60AncLaneFeedSetTonalSnapshot(feed, &tonal);
    N60AncLaneFeedArm(feed);  // offline compute only: nothing here reaches a device
    N60AncLaneFeedRenewLease(feed, static_cast<uint64_t>(rate * 3600.0));
    static const Signal sig;
    std::vector<float> outBuf(size_t(kCh) * 4096);
    const float *ip[kCh];
    float *op[kCh];
    const double period = frames / rate;
    const uint64_t blocks = std::max<uint64_t>(32, static_cast<uint64_t>(cfg.seconds * rate / frames));
    std::vector<double> means, p999s, times(blocks);
    double worst = 0;
    uint64_t blk = 0;
    for (int run = -1; run < cfg.runs; ++run) {
        double sum = 0;
        for (uint64_t i = 0; i < blocks; ++i, ++blk) {
            for (uint32_t l = 0; l < kCh; ++l) { ip[l] = sig.at(blk, l, frames); op[l] = outBuf.data() + size_t(l) * 4096; }
            const auto t0 = Clock::now();
            N60AncLaneFeedProcess(feed, ip, op, kCh, frames);
            const auto t1 = Clock::now();
            times[i] = std::chrono::duration<double>(t1 - t0).count() / period;
            sum += times[i];
        }
        if (run < 0) continue;  // warm-up pass
        std::vector<double> sorted(times);
        std::sort(sorted.begin(), sorted.end());
        means.push_back(sum / blocks);
        p999s.push_back(sorted[std::min<size_t>(sorted.size() - 1, static_cast<size_t>(0.999 * sorted.size()))]);
        worst = std::max(worst, sorted.back());
    }
    N60AncLaneFeedDestroy(feed);
    cell.mean = median(means); cell.p999 = *std::min_element(p999s.begin(), p999s.end()); cell.max = worst;
    return true;
}
#endif

// ---- Results, JSON, gates ---------------------------------------------------------------------------------------

using Results = std::map<std::string, double>;

std::string key(const std::string &scn, double rate, const char *block, const char *metric) {
    char buf[96];
    std::snprintf(buf, sizeof buf, "%s/%.0f/%s/%s", scn.c_str(), rate, block, metric);
    return buf;
}

// Stage kinds ranked by total time per lane-sample, slowest first.
std::vector<n60_profile_entry> rankProfile(std::vector<n60_profile_entry> v) {
    std::sort(v.begin(), v.end(), [](const n60_profile_entry &a, const n60_profile_entry &b) {
        const double x = a.laneFrames ? double(a.ns) / double(a.laneFrames) : 0;
        const double y = b.laneFrames ? double(b.ns) / double(b.laneFrames) : 0;
        return x > y;
    });
    return v;
}

#ifdef N60_BENCH_PROFILE
bool profileAvailable() { return true; }
#else
bool profileAvailable() { return false; }
#endif

// E20 S10 (G4): worker threads for the parallel render, as the Apple host runs them minus Workgroups. The R2/R3 fade
// and mean budgets are judged on this critical path (the caller's time with workers), not on the single-thread run.
struct WorkerHost {
    n60_graph *g = nullptr;
    std::mutex m;
    std::condition_variable cv;
    std::atomic<uint64_t> epoch{0};
    std::atomic<bool> quit{false};
    std::vector<std::thread> threads;
    static void wake(void *ctx, uint32_t) {
        WorkerHost *h = static_cast<WorkerHost *>(ctx);
        { std::lock_guard<std::mutex> lk(h->m); h->epoch.fetch_add(1); }
        h->cv.notify_all();
    }
    void start(n60_graph *graph, uint32_t n) {
        g = graph;
        n60_graph_set_wake(g, &WorkerHost::wake, this);
        n60_graph_set_workers(g, n);
        for (uint32_t w = 1; w <= n; ++w) {
            threads.emplace_back([this, w] {
                uint64_t seen = 0;
                for (;;) {
                    {
                        std::unique_lock<std::mutex> lk(m);
                        cv.wait(lk, [&] { return quit.load() || epoch.load() != seen; });
                        if (quit.load()) return;
                        seen = epoch.load();
                    }
                    n60_graph_worker_run(g, w);
                }
            });
        }
    }
    void stop() {
        n60_graph_set_workers(g, 0);
        { std::lock_guard<std::mutex> lk(m); quit = true; }
        cv.notify_all();
        for (auto &t : threads) t.join();
        threads.clear();
        n60_graph_set_wake(g, nullptr, nullptr);
    }
};

bool runCell(const std::string &id, double rate, uint32_t frames, const Config &cfg, Cell &cell, bool &finite, std::vector<n60_profile_entry> *prof, uint32_t workers = 0) {
    finite = true;
    if (id == "R7") {
#ifdef N60_BENCH_ANC
        return timeAnc(rate, frames, cfg, cell);
#else
        return false;
#endif
    }
    Built b;
    if (!buildScenario(id, rate, frames, b)) { std::fprintf(stderr, "scenario %s at %.0f: %s\n", id.c_str(), rate, b.why.c_str()); return false; }
    n60_graph *g = nullptr;
    const n60_graph_desc *d = b.layoutGraph ? &b.desc : b.finish();
    const n60_status s = n60_graph_build(d, &g);
    if (s != N60_STATUS_OK || g == nullptr) { std::fprintf(stderr, "scenario %s at %.0f: build status %d\n", id.c_str(), rate, static_cast<int>(s)); return false; }
    WorkerHost host;
    if (workers != 0) host.start(g, workers);
    const bool ok = timeGraph(g, b.lanes, rate, frames, cfg, cell, finite);
    // The profile pass runs while the workers are still up when asked with workers: a parallel phase is timed whole on the
    // calling thread, so the rows are the critical path per stage kind.
    const bool profWithWorkers = workers != 0;
    if (!profWithWorkers || prof == nullptr) { if (workers != 0) host.stop(); }
    if (ok && prof != nullptr && profileAvailable()) {
        profReset();
        Config one = cfg;
        one.runs = 1;
        Cell scratch;
        bool f2;
        timeGraph(g, b.lanes, rate, frames, one, scratch, f2);
        n60_profile_entry e[64];
        const uint32_t n = profRead(e, 64);
        prof->assign(e, e + n);
    }
    if (profWithWorkers && prof != nullptr) host.stop();
    n60_graph_retire(g);
    return ok;
}

void writeJson(const std::string &path, const Results &r, const Config &cfg) {
    std::ostringstream o;
    o << "{\n  \"schema\": 1,\n  \"seconds\": " << cfg.seconds << ",\n  \"runs\": " << cfg.runs << ",\n  \"results\": {\n";
    size_t i = 0;
    for (const auto &kv : r) {
        char buf[160];
        std::snprintf(buf, sizeof buf, "    \"%s\": %.6g%s\n", kv.first.c_str(), kv.second, ++i < r.size() ? "," : "");
        o << buf;
    }
    o << "  }\n}\n";
    if (path.empty()) { std::fputs(o.str().c_str(), stdout); return; }
    std::ofstream f(path);
    f << o.str();
}

// Reads every "key": number pair of a JSON file (nested objects flatten; other values are skipped).
bool readFlat(const std::string &path, Results &out) {
    std::ifstream f(path);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    const std::string s = ss.str();
    size_t i = 0;
    while ((i = s.find('"', i)) != std::string::npos) {
        const size_t e = s.find('"', i + 1);
        if (e == std::string::npos) break;
        const std::string k = s.substr(i + 1, e - i - 1);
        size_t p = e + 1;
        while (p < s.size() && (s[p] == ' ' || s[p] == '\n' || s[p] == '\t' || s[p] == '\r')) ++p;
        if (p < s.size() && s[p] == ':') {
            ++p;
            char *end = nullptr;
            const double v = std::strtod(s.c_str() + p, &end);
            if (end != s.c_str() + p) out[k] = v;
        }
        i = e + 1;
    }
    return true;
}

struct Gate {
    int fails = 0, warns = 0;
};

// Baseline gate: every */mean key present in both. Fail above 1.5x, warn above 1.2x.
Gate compareBaseline(const Results &cur, const Results &base) {
    Gate g;
    for (const auto &kv : cur) {
        if (kv.first.size() < 5 || kv.first.compare(kv.first.size() - 5, 5, "/mean") != 0) continue;
        auto it = base.find(kv.first);
        if (it == base.end() || it->second <= 0) continue;
        const double ratio = kv.second / it->second;
        if (ratio > 1.5) { std::printf("FAIL %s: %.4g vs baseline %.4g (%.2fx)\n", kv.first.c_str(), kv.second, it->second, ratio); ++g.fails; }
        else if (ratio > 1.2) { std::printf("WARN %s: %.4g vs baseline %.4g (%.2fx)\n", kv.first.c_str(), kv.second, it->second, ratio); ++g.warns; }
    }
    return g;
}

// Budget gate on the "ref" rows: budgets.json holds "<scenario>/mean", "<scenario>/p999" and "<scenario>/fade2x" (twice the
// mean must fit). R4a and R4b share R4's entry. Breaches are warnings unless enforce.
Gate compareBudgets(const Results &cur, const Results &bud, bool enforce) {
    Gate g;
    for (const auto &kv : cur) {
        const size_t a = kv.first.find('/'), b = kv.first.find('/', a + 1), c = kv.first.find('/', b + 1);
        if (c == std::string::npos) continue;
        std::string scn = kv.first.substr(0, a);
        // R2 and R3 are judged on the critical path with workers ("refw", E20 S10); the others on the single-thread "ref" row.
        const char *judged = (scn == "R2" || scn == "R3") ? "refw" : "ref";
        if (kv.first.compare(b + 1, c - b - 1, judged) != 0) continue;
        const std::string metric = kv.first.substr(c + 1);
        if (scn == "R4a" || scn == "R4b") scn = "R4";
        double limit = 0, value = kv.second;
        auto it = bud.find(scn + "/" + metric);
        if (it != bud.end() && (metric == "mean" || metric == "p999")) limit = it->second;
        if (metric == "mean") {
            auto f = bud.find(scn + "/fade2x");
            if (f != bud.end() && 2.0 * value > f->second) {
                std::printf("%s %s: 2x mean %.4g over the fade budget %.4g\n", enforce ? "FAIL" : "WARN(budget)", kv.first.c_str(), 2.0 * value, f->second);
                enforce ? ++g.fails : ++g.warns;
            }
        }
        if (limit > 0 && value > limit) {
            std::printf("%s %s: %.4g over budget %.4g\n", enforce ? "FAIL" : "WARN(budget)", kv.first.c_str(), value, limit);
            enforce ? ++g.fails : ++g.warns;
        }
    }
    return g;
}

// ---- Self-test ------------------------------------------------------------------------------------------------

int selfFailures = 0;
#define SELF(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "SELF-TEST FAIL %s:%d: ", __FILE__, __LINE__); std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); ++selfFailures; } } while (0)

int selfTest() {
    // 1. A synthetic stage of known cost is ranked first.
    std::vector<n60_profile_entry> v(3);
    std::memset(v.data(), 0, v.size() * sizeof(n60_profile_entry));
    v[0] = {3, 0, 1000, 10, 100, 100};    // 10 ns per lane-sample
    v[1] = {9, 0, 900000, 10, 100, 100};  // known-expensive: 9000 ns per lane-sample
    v[2] = {5, 0, 5000, 10, 100, 100};
    auto ranked = rankProfile(v);
    SELF(ranked[0].kind == 9 && ranked[1].kind == 5 && ranked[2].kind == 3, "synthetic stage not ranked first");

    // 2. The gate fails on a doctored baseline, warns in the middle band and passes on equal numbers.
    Results cur = {{"R1/48000/ref/mean", 0.30}, {"R1/48000/ref/p999", 0.4}};
    Results same = {{"R1/48000/ref/mean", 0.30}};
    Results doctored = {{"R1/48000/ref/mean", 0.10}};
    Results mid = {{"R1/48000/ref/mean", 0.30 / 1.3}};
    SELF(compareBaseline(cur, same).fails == 0 && compareBaseline(cur, same).warns == 0, "equal baseline must pass");
    SELF(compareBaseline(cur, doctored).fails == 1, "doctored baseline must fail");
    SELF(compareBaseline(cur, mid).fails == 0 && compareBaseline(cur, mid).warns == 1, "1.3x must warn only");
    Results bud = {{"R1/mean", 0.25}, {"R1/p999", 0.5}, {"R1/fade2x", 0.5}};
    SELF(compareBudgets(cur, bud, true).fails == 2, "0.30 mean must break the 0.25 budget and the 0.5 fade rule");
    SELF(compareBudgets(cur, bud, false).fails == 0, "budget breaches only warn without --enforce-budgets");
    // R2 is judged on the worker row only: a single-thread breach is ignored, a worker-row breach fails when enforcing.
    Results r2 = {{"R2/48000/ref/mean", 0.9}, {"R2/48000/refw/mean", 0.3}};
    Results r2bad = {{"R2/48000/ref/mean", 0.3}, {"R2/48000/refw/mean", 0.9}};
    Results bud2 = {{"R2/mean", 0.5}, {"R2/fade2x", 0.8}};
    SELF(compareBudgets(r2, bud2, true).fails == 0, "R2 single-thread row is not the judged row");
    SELF(compareBudgets(r2bad, bud2, true).fails == 2, "R2 worker row over the mean and fade budgets fails");

    // 3. Flat JSON round trip.
    writeJson("n60_bench_selftest.json", cur, Config());
    Results back;
    SELF(readFlat("n60_bench_selftest.json", back) && back["R1/48000/ref/mean"] == 0.30, "json round trip");
    std::remove("n60_bench_selftest.json");

    // 4. Every scenario builds, runs and stays finite at all eight rates (both blocks for the cheap ones).
    Config cfg;
    cfg.seconds = 0.01;
    cfg.runs = 1;
    for (const char *id : kScenarioIds) {
        if (std::strcmp(id, "R7") == 0) {
#ifndef N60_BENCH_ANC
            continue;
#endif
        }
        for (double rate : kRates) {
            Cell cell;
            bool finite = true;
            const bool ok = runCell(id, rate, refFrames(rate), cfg, cell, finite, nullptr);
            SELF(ok && finite && cell.mean > 0, "scenario %s at %.0f did not run (ok %d finite %d)", id, rate, ok, finite);
            if (std::strcmp(id, "R1") == 0 || std::strcmp(id, "R6") == 0) {
                const bool ok2 = runCell(id, rate, refFrames(rate) / 4, cfg, cell, finite, nullptr);
                SELF(ok2 && finite, "scenario %s stress block at %.0f", id, rate);
            }
        }
    }

    // 5. With a profile build, the long FIR is ranked above every other stage in R4a.
    if (profileAvailable()) {
        std::vector<n60_profile_entry> prof;
        Cell cell;
        bool finite;
        runCell("R4a", 48000, 128, cfg, cell, finite, &prof);
        auto r = rankProfile(prof);
        SELF(!r.empty() && r[0].kind == N60_STAGE_FIR, "profile: long FIR must rank first (got kind %u)", r.empty() ? 0u : r[0].kind);
    } else {
        std::puts("self-test: product build (no profile symbols), profile ranking skipped");
    }
    std::puts(selfFailures == 0 ? "n60_bench self-test: all checks passed" : "n60_bench self-test: FAILED");
    return selfFailures == 0 ? 0 : 1;
}

std::vector<std::string> split(const std::string &s) {
    std::vector<std::string> v;
    std::stringstream ss(s);
    std::string t;
    while (std::getline(ss, t, ',')) if (!t.empty()) v.push_back(t);
    return v;
}

}  // namespace

int main(int argc, char **argv) {
    Config cfg;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : std::string(); };
        if (a == "--out") cfg.out = next();
        else if (a == "--baseline") cfg.baseline = next();
        else if (a == "--budgets") cfg.budgets = next();
        else if (a == "--seconds") cfg.seconds = std::atof(next().c_str());
        else if (a == "--runs") cfg.runs = std::max(1, std::atoi(next().c_str()));
        else if (a == "--rates") { cfg.rates.clear(); for (auto &t : split(next())) cfg.rates.push_back(std::atof(t.c_str())); }
        else if (a == "--scenarios") cfg.scenarios = split(next());
        else if (a == "--profile") cfg.profile = true;
        else if (a == "--profile-only") { cfg.profile = cfg.profileOnly = true; }
        else if (a == "--workers") cfg.workers = static_cast<uint32_t>(std::max(0, std::atoi(next().c_str())));
        else if (a == "--enforce-budgets") cfg.enforceBudgets = true;
        else if (a == "--self-test") cfg.selfTest = true;
        else { std::fprintf(stderr, "unknown argument %s\n", a.c_str()); return 2; }
    }
    if (cfg.selfTest) return selfTest();
    if (cfg.profileOnly) { cfg.runs = 1; cfg.seconds = std::min(cfg.seconds, 0.05); }  // timing is not reported; the hooks distort it
    if (cfg.profile && !profileAvailable()) std::fputs("note: --profile needs libn60core built with -DN60_GRAPH_PROFILE and the harness with -DN60_BENCH_PROFILE; skipped\n", stderr);

    Results res;
    int errors = 0;
    for (const std::string &id : cfg.scenarios) {
#ifndef N60_BENCH_ANC
        if (id == "R7") { std::fputs("note: R7 needs -DN60_BENCH_ANC and the ANC objects; skipped\n", stderr); continue; }
#endif
        for (double rate : cfg.rates) {
            for (int blockKind = 0; blockKind < (cfg.profileOnly ? 1 : 2); ++blockKind) {
                const uint32_t frames = blockKind == 0 ? refFrames(rate) : refFrames(rate) / 4;
                const char *label = blockKind == 0 ? "ref" : "stress";
                Cell cell;
                bool finite = true;
                std::vector<n60_profile_entry> prof;
                if (!runCell(id, rate, frames, cfg, cell, finite, (cfg.profile && blockKind == 0) ? &prof : nullptr)) {
                    std::fprintf(stderr, "scenario %s rate %.0f %s block did not run\n", id.c_str(), rate, label);
                    ++errors;
                    continue;
                }
                if (!finite) { std::fprintf(stderr, "scenario %s rate %.0f: non-finite output\n", id.c_str(), rate); ++errors; }
                if (!cfg.profileOnly) {
                    res[key(id, rate, label, "mean")] = cell.mean;
                    res[key(id, rate, label, "p999")] = cell.p999;
                    res[key(id, rate, label, "max")] = cell.max;
                }
                std::printf("%-4s %7.0f Hz %-6s %4u frames  mean %6.2f%%  p99.9 %6.2f%%  max %6.2f%%\n", id.c_str(), rate, label, frames,
                            100 * cell.mean, 100 * cell.p999, 100 * cell.max);
                for (const auto &e : prof) {
                    if (e.laneFrames == 0) continue;
                    char k[96];
                    std::snprintf(k, sizeof k, "%s/%.0f/prof/%u", id.c_str(), rate, e.kind);
                    res[k] = double(e.ns) / double(e.laneFrames);
                }
            }
        }
    }
    // E20 S10 (G4): the critical path with workers, reference block only, for the scenarios whose budget is judged there.
    if (cfg.workers != 0 && (!cfg.profileOnly || cfg.profile)) {
        for (const std::string &id : cfg.scenarios) {
            if (id != "R2" && id != "R3") continue;
            for (double rate : cfg.rates) {
                Cell cell;
                bool finite = true;
                const uint32_t frames = refFrames(rate);
                std::vector<n60_profile_entry> wprof;
                if (!runCell(id, rate, frames, cfg, cell, finite, cfg.profile ? &wprof : nullptr, cfg.workers) || !finite) {
                    std::fprintf(stderr, "scenario %s rate %.0f with %u workers did not run\n", id.c_str(), rate, cfg.workers);
                    ++errors;
                    continue;
                }
                if (!cfg.profileOnly) {
                    res[key(id, rate, "refw", "mean")] = cell.mean;
                    res[key(id, rate, "refw", "p999")] = cell.p999;
                    res[key(id, rate, "refw", "max")] = cell.max;
                }
                for (const auto &e : wprof) {  // critical-path ns per lane-sample by stage kind, with workers
                    if (e.laneFrames == 0) continue;
                    char k[96];
                    std::snprintf(k, sizeof k, "%s/%.0f/profw/%u", id.c_str(), rate, e.kind);
                    res[k] = double(e.ns) / double(e.laneFrames);
                    std::printf("   profw kind %2u: %8.2f ns/lane-sample, %6.1f ns/frame (critical path)\n", e.kind, double(e.ns) / double(e.laneFrames), double(e.ns) / double(e.frames));
                }
                std::printf("%-4s %7.0f Hz %-6s %4u frames  mean %6.2f%%  p99.9 %6.2f%%  max %6.2f%%  (%u workers)\n", id.c_str(), rate, "refw", frames,
                            100 * cell.mean, 100 * cell.p999, 100 * cell.max, cfg.workers);
            }
        }
    }
    // E20 S10 (G6): enforcing needs R7 (ANC lane feed) in the JSON, so a workflow build that lost -DN60_BENCH_ANC fails loudly.
    if (cfg.enforceBudgets) {
        for (const std::string &id : cfg.scenarios) {
            if (id != "R7") continue;
            bool have = false;
            for (const auto &kv : res) if (kv.first.compare(0, 3, "R7/") == 0) have = true;
            if (!have) { std::fputs("FAIL R7 missing from the results (build with -DN60_BENCH_ANC)\n", stderr); ++errors; }
        }
    }
    writeJson(cfg.out, res, cfg);
    Gate total;
    if (!cfg.baseline.empty()) {
        Results base;
        if (readFlat(cfg.baseline, base)) {
            const Gate g = compareBaseline(res, base);
            total.fails += g.fails;
            total.warns += g.warns;
        } else {
            std::printf("note: no baseline at %s; regression gate skipped (commit one from the nightly artifact)\n", cfg.baseline.c_str());
        }
    }
    if (!cfg.budgets.empty()) {
        Results bud;
        if (readFlat(cfg.budgets, bud)) {
            const Gate g = compareBudgets(res, bud, cfg.enforceBudgets);
            total.fails += g.fails;
            total.warns += g.warns;
        } else {
            std::fprintf(stderr, "cannot read budgets %s\n", cfg.budgets.c_str());
            ++errors;
        }
    }
    std::printf("bench: %d error(s), %d gate failure(s), %d warning(s)\n", errors, total.fails, total.warns);
    return errors == 0 && total.fails == 0 ? 0 : 1;
}
