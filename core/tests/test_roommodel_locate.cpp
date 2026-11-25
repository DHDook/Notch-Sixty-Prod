// E29 S5: acoustic locate (n60/roommodel.h). Synthetic anechoic and image-source rooms at the eight standard rates.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "n60/n60.h"

static int failures = 0;
#define CHECK(cond, msg)                                              \
    do {                                                              \
        if (!(cond)) {                                                \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); \
            ++failures;                                               \
        }                                                             \
    } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;
static const double kC = 343.0;
static const double kRoom[3] = {5.0, 4.0, 2.8};
static const double kBeta = 0.85;
static const double kIrSeconds = 0.1;

static const double kLeft[3] = {1.5, 0.3, 0.9};
static const double kRight[3] = {3.5, 0.3, 0.9};
static const double kRear[3] = {1.0, 3.6, 1.0};   // a third full-range speaker behind the seat
static const double kFarRight[3] = {4.6, 1.2, 1.0};
static const double kSeat[3] = {2.3, 2.6, 1.1};

static void addArrival(std::vector<double> &h, double pos, double amp) {
    const int taps = 16;
    const int c0 = static_cast<int>(std::floor(pos));
    for (int t = c0 - taps + 1; t <= c0 + taps; ++t) {
        if (t < 0 || t >= static_cast<int>(h.size())) continue;
        const double x = static_cast<double>(t) - pos;
        const double s = std::fabs(x) < 1e-12 ? 1.0 : std::sin(kPi * x) / (kPi * x);
        const double win = 0.5 * (1.0 + std::cos(kPi * x / taps));
        h[static_cast<size_t>(t)] += amp * s * win;
    }
}

// Impulse response from a source to a receiver: the direct path alone (reflect false) or an image-source room.
static std::vector<float> makeIr(const double *src, const double *p, double rate, bool room, uint32_t shiftFrames) {
    const uint32_t frames = static_cast<uint32_t>(rate * kIrSeconds);
    std::vector<double> h(frames, 0.0);
    if (!room) {
        const double dx = src[0] - p[0], dy = src[1] - p[1], dz = src[2] - p[2];
        const double r = std::sqrt(dx * dx + dy * dy + dz * dz);
        addArrival(h, r / kC * rate + shiftFrames, 1.0 / r);
    } else {
        const double maxPath = kIrSeconds * kC;
        const int order[3] = {static_cast<int>(maxPath / (2 * kRoom[0])) + 1, static_cast<int>(maxPath / (2 * kRoom[1])) + 1,
                              static_cast<int>(maxPath / (2 * kRoom[2])) + 1};
        for (int ix = -order[0]; ix <= order[0]; ++ix)
            for (int iy = -order[1]; iy <= order[1]; ++iy)
                for (int iz = -order[2]; iz <= order[2]; ++iz)
                    for (int mask = 0; mask < 8; ++mask) {
                        const int mx = mask & 1, my = (mask >> 1) & 1, mz = (mask >> 2) & 1;
                        const double sx = (mx ? -src[0] : src[0]) + 2 * ix * kRoom[0];
                        const double sy = (my ? -src[1] : src[1]) + 2 * iy * kRoom[1];
                        const double sz = (mz ? -src[2] : src[2]) + 2 * iz * kRoom[2];
                        const double dx = sx - p[0], dy = sy - p[1], dz = sz - p[2];
                        const double r = std::sqrt(dx * dx + dy * dy + dz * dz);
                        if (r > maxPath || r < 1e-3) continue;
                        const int hits = std::abs(ix - mx) + std::abs(ix) + std::abs(iy - my) + std::abs(iy) +
                                         std::abs(iz - mz) + std::abs(iz);
                        addArrival(h, r / kC * rate + shiftFrames, std::pow(kBeta, hits) / r);
                    }
    }
    std::vector<float> out(frames);
    for (uint32_t i = 0; i < frames; ++i) out[i] = static_cast<float>(h[i]);
    return out;
}

static n60_roommodel_locate_query makeQuery(double rate, uint32_t count) {
    n60_roommodel_locate_query q{};
    q.structSize = sizeof q;
    q.speakerCount = count;
    q.sampleRate = rate;
    q.seatHeightM = kSeat[2];
    return q;
}

static n60_roommodel_locate_result makeResult() {
    n60_roommodel_locate_result r{};
    r.structSize = sizeof r;
    return r;
}

static n60_roommodel_locate_speaker speaker(const double *pos, const std::vector<float> &ir) {
    n60_roommodel_locate_speaker s{};
    for (int i = 0; i < 3; ++i) s.position[i] = pos[i];
    s.ir = ir.data();
    s.irFrames = static_cast<uint32_t>(ir.size());
    s.timingTrusted = 1;
    return s;
}

static double err(const n60_roommodel_locate_result &r) {
    const double dx = r.position[0] - kSeat[0], dy = r.position[1] - kSeat[1];
    return std::sqrt(dx * dx + dy * dy);
}

static void testAnechoicTwoSpeakers() {
    for (double rate : kRates) {
        const auto l = makeIr(kLeft, kSeat, rate, false, 0), r = makeIr(kRight, kSeat, rate, false, 0);
        n60_roommodel_locate_speaker sp[2] = {speaker(kLeft, l), speaker(kRight, r)};
        auto q = makeQuery(rate, 2);
        auto res = makeResult();
        CHECK(n60_roommodel_locate(&q, sp, &res) == N60_ROOMMODEL_OK, "anechoic two speakers locate");
        CHECK(err(res) < 0.02, "anechoic fix within 2 cm");
        CHECK(res.mirrorResolved == 1 && res.position[1] > kLeft[1], "two speakers resolve the front solution");
        CHECK(res.position[2] == kSeat[2], "height is the assumed height");
        CHECK(res.uncertaintyM > 0 && res.uncertaintyM < 0.05, "uncertainty reported and small");
        if (err(res) >= 0.02) std::fprintf(stderr, "  rate %.0f error %.4f m\n", rate, err(res));
    }
}

static void testRoomThreeAndFourSpeakers() {
    for (double rate : kRates) {
        const auto l = makeIr(kLeft, kSeat, rate, true, 0), r = makeIr(kRight, kSeat, rate, true, 0);
        const auto b = makeIr(kRear, kSeat, rate, true, 0), f = makeIr(kFarRight, kSeat, rate, true, 0);
        n60_roommodel_locate_speaker two[2] = {speaker(kLeft, l), speaker(kRight, r)};
        auto q2 = makeQuery(rate, 2);
        auto res = makeResult();
        CHECK(n60_roommodel_locate(&q2, two, &res) == N60_ROOMMODEL_OK, "room two speakers locate");
        CHECK(err(res) < 0.05, "room two-speaker fix within 5 cm");
        if (err(res) >= 0.05) std::fprintf(stderr, "  rate %.0f two-speaker error %.4f m\n", rate, err(res));

        n60_roommodel_locate_speaker four[4] = {speaker(kLeft, l), speaker(kRight, r), speaker(kRear, b), speaker(kFarRight, f)};
        auto q4 = makeQuery(rate, 4);
        auto res4 = makeResult();
        CHECK(n60_roommodel_locate(&q4, four, &res4) == N60_ROOMMODEL_OK, "room four speakers locate");
        CHECK(err(res4) < 0.05, "room least-squares fix within 5 cm");
        CHECK(res4.speakersUsed == 4, "all four used");
        CHECK(res4.residualRmsM < 0.03, "residual small for consistent positions");
        if (err(res4) >= 0.05) std::fprintf(stderr, "  rate %.0f four-speaker error %.4f m\n", rate, err(res4));
        for (int i = 0; i < 4; ++i)
            CHECK(std::fabs(res4.distanceM[i] - res4.fitDistanceM[i]) < 0.05, "measured and geometric distance agree");
    }
}

static void testSubExcluded() {
    const double rate = 48000;
    const auto l = makeIr(kLeft, kSeat, rate, true, 0), r = makeIr(kRight, kSeat, rate, true, 0);
    // A sub's response: a low-passed, much later pulse, from a position that would pull the fix away if it counted.
    std::vector<float> sub(static_cast<size_t>(rate * kIrSeconds), 0.0f);
    for (int i = 0; i < 400; ++i) sub[2000 + static_cast<size_t>(i)] = std::exp(-i / 120.0f) * std::sin(2 * 3.14159f * 60 * i / 48000.0f);
    const double subPos[3] = {0.2, 3.0, 0.3};
    n60_roommodel_locate_speaker sp[3] = {speaker(kLeft, l), speaker(kRight, r), speaker(subPos, sub)};
    sp[2].isSub = 1;
    auto q = makeQuery(rate, 3);
    auto res = makeResult();
    CHECK(n60_roommodel_locate(&q, sp, &res) == N60_ROOMMODEL_OK, "locate with a sub present");
    CHECK(res.speakerStatus[2] == N60_ROOMMODEL_LOCATE_SPEAKER_SUB, "sub marked excluded");
    CHECK(res.speakersUsed == 2, "only the two full-range speakers used");
    CHECK(err(res) < 0.05, "sub does not move the fix");
    // A sub without timing does not refuse the call either.
    sp[2].timingTrusted = 0;
    CHECK(n60_roommodel_locate(&q, sp, &res) == N60_ROOMMODEL_OK, "an untimed sub is ignored");
}

static void testRefusals() {
    const double rate = 96000;
    const auto l = makeIr(kLeft, kSeat, rate, false, 0), r = makeIr(kRight, kSeat, rate, false, 0);
    n60_roommodel_locate_speaker sp[2] = {speaker(kLeft, l), speaker(kRight, r)};
    auto q = makeQuery(rate, 2);
    auto res = makeResult();
    sp[1].timingTrusted = 0;
    CHECK(n60_roommodel_locate(&q, sp, &res) == N60_ROOMMODEL_NOT_MEASURED && res.reason == N60_ROOMMODEL_REASON_NO_LOOPBACK_TIMING,
          "refused without loopback timing");
    sp[1].timingTrusted = 1;
    auto q1 = makeQuery(rate, 1);
    CHECK(n60_roommodel_locate(&q1, sp, &res) == N60_ROOMMODEL_NOT_MEASURED && res.reason == N60_ROOMMODEL_REASON_TOO_FEW_SPEAKERS,
          "one speaker is too few");
    n60_roommodel_locate_speaker same[2] = {speaker(kLeft, l), speaker(kLeft, r)};
    CHECK(n60_roommodel_locate(&q, same, &res) == N60_ROOMMODEL_NOT_MEASURED && res.reason == N60_ROOMMODEL_REASON_DEGENERATE,
          "coincident speakers are degenerate");
    std::vector<float> silent(4800, 0.0f);
    n60_roommodel_locate_speaker quiet[2] = {speaker(kLeft, silent), speaker(kRight, silent)};
    CHECK(n60_roommodel_locate(&q, quiet, &res) == N60_ROOMMODEL_NOT_MEASURED && res.reason == N60_ROOMMODEL_REASON_NO_ARRIVAL,
          "silent IRs have no arrival");
}

static void testLatencyAndDeterminism() {
    const double rate = 192000;
    const uint32_t shift = 960;  // 5 ms of capture latency still in the IR
    const auto l = makeIr(kLeft, kSeat, rate, true, shift), r = makeIr(kRight, kSeat, rate, true, shift);
    n60_roommodel_locate_speaker sp[2] = {speaker(kLeft, l), speaker(kRight, r)};
    sp[0].latencySeconds = sp[1].latencySeconds = shift / rate;
    auto q = makeQuery(rate, 2);
    auto a = makeResult(), b = makeResult();
    CHECK(n60_roommodel_locate(&q, sp, &a) == N60_ROOMMODEL_OK, "latency subtracted");
    CHECK(err(a) < 0.05, "fix with the latency removed");
    CHECK(n60_roommodel_locate(&q, sp, &b) == N60_ROOMMODEL_OK, "second run");
    CHECK(a.position[0] == b.position[0] && a.position[1] == b.position[1], "deterministic");
}

static void testArgumentsAndAbi() {
    const double rate = 48000;
    const auto l = makeIr(kLeft, kSeat, rate, false, 0);
    n60_roommodel_locate_speaker sp[2] = {speaker(kLeft, l), speaker(kRight, l)};
    auto q = makeQuery(rate, 2);
    auto res = makeResult();
    CHECK(n60_roommodel_locate(nullptr, sp, &res) == N60_ROOMMODEL_ERR_ARGUMENT, "null query");
    CHECK(n60_roommodel_locate(&q, nullptr, &res) == N60_ROOMMODEL_ERR_ARGUMENT, "null speakers");
    auto bad = q;
    bad.structSize = 3;
    CHECK(n60_roommodel_locate(&bad, sp, &res) == N60_ROOMMODEL_ERR_ARGUMENT, "bad struct size");
    bad = q;
    bad.sampleRate = 100;
    CHECK(n60_roommodel_locate(&bad, sp, &res) == N60_ROOMMODEL_ERR_ARGUMENT, "bad rate");
    bad = q;
    bad.speakerCount = N60_ROOMMODEL_LOCATE_MAX_SPEAKERS + 1;
    CHECK(n60_roommodel_locate(&bad, sp, &res) == N60_ROOMMODEL_ERR_ARGUMENT, "too many speakers");
    CHECK(n60_roommodel_abi_version() == N60_ROOMMODEL_ABI_VERSION, "abi version");
}

int main() {
    testArgumentsAndAbi();
    testAnechoicTwoSpeakers();
    testRoomThreeAndFourSpeakers();
    testSubExcluded();
    testRefusals();
    testLatencyAndDeterminism();
    if (failures != 0) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("roommodel locate tests passed");
    return 0;
}
