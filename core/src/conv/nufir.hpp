// libn60core non-uniform partitioned FIR engine (E9 S1, design note 1-4).
//
// One engine for FIR, ROOM_FIR, SPEAKER_IR and DRIVER_FIR lanes of 1 to 262,144 taps at a fixed
// latency of 256 frames. Zero added delay beyond the 256-frame base block (Gardner 1995, Garcia 2002,
// Wefers 2015): three segments of increasing partition size cover the filter in order,
//   segment 0: 256-frame partitions,  up to 4,  taps [0, 1024)
//   segment 1: 1024-frame partitions, up to 4,  taps [1024, 5120)
//   segment 2: 4096-frame partitions, up to 63, taps [5120, 263168)
// so the cost is known and independent of the host block size. Only the fft.hpp abstraction is used.
//
// Scheduling (all counted in 256-frame ticks T; conv block T is the 256 output frames n = 256T..256T+255
// and is computed at the end of tick T from the input up to and including block T, then emitted during
// tick T+1):
//  - segment 0 runs a whole overlap-save step every tick.
//  - segment 1's output block m (ticks 4m..4m+3) needs input block m-1, which completes at tick 4m-1;
//    the older partitions' multiply-adds run one per tick during the three ticks before, then the
//    forward FFT, newest multiply-add and inverse FFT run at tick 4m-1.
//  - segment 2's output block m (ticks 16m+4..16m+19) needs input block m-1, complete at tick 16m-1,
//    and its first sample is needed 4 ticks later (the 1024-frame offset is slack). The forward FFT
//    runs at phase 0 of tick 16m, the newest multiply-add at phase 1, the inverse FFT at phase 2; the
//    older partitions' multiply-adds are spread over phases 3..15 of the tick cycle before.
//  The deterministic operation counter (Counter) records the cost of every tick; at 262,144 taps the
//  worst tick is below 2.5 times the mean (tested).
//
// A tap set that is a single 1.0 runs as a plain ring delay of (index + 256) frames: bit exact, O(1)
// per sample, and the latency-alignment delta FIR costs nothing at any length.
//
// Realtime documentation (AGENTS.md section 4):
//  - allocation: none. All state lives in caller-provided memory sized by sharedBytes / laneBytes
//    and built on the control thread by init; process allocates nothing and takes no lock.
//  - synchronisation: none. The shared block holds FFT plans, tap spectra (immutable after init) and
//    one scratch FFT buffer that the lane being processed owns for the duration of a process call.
//  - latency: exactly kBlock (256) frames, any tap count.
//  - sample rate: not applicable (frame counts only). Any block length from 1 up gives bit-identical
//    results (the work is driven by the tick counter, never by the block length).
//  - channels: one independent lane state per channel; identical taps share the spectra.
//  - reset (E9 S2): a delay-mode lane resets in O(1) (a fill counter masks the stale ring). An FFT lane clears
//    its rings, output blocks and accumulators (about 170 KiB), never the spectrum delay lines (a per-segment
//    count marks them empty), through resetStep, which clears at most the caller's byte budget per call and
//    reports whether it finished; until it does the lane outputs silence and drops its input (the host mutes
//    the history length after a discontinuity anyway).
//  - carry (E9 S2): a lane of a filter that continues across a rebuild is copied from the outgoing instance in
//    two parts. carryHeader (fixed, small) at adoption, then carryCopy spreads the rest (input ring and
//    spectrum delay lines, up to about 2.2 MiB per lane) over callbacks by a byte budget. Both instances then
//    run the same input in lockstep from the adoption block, so a slot copied late still holds exactly what the
//    incoming lane would hold; the accumulators and output blocks are not copied but recomputed, which takes
//    kSettleFrames after the copy ends.
#ifndef N60_CORE_CONV_NUFIR_HPP
#define N60_CORE_CONV_NUFIR_HPP

#include <cstddef>
#include <cstdint>

#include "../platform/rt.hpp"

namespace n60::conv {

constexpr uint32_t kBlock = 256;
constexpr uint32_t kMaxTaps = 262144;
// Frames after a lazy carry completes until an FFT lane's output equals the lane it was copied from: three
// 16-tick cycles of the 4,096 segment (accumulation, inverse transform, emission).
constexpr uint32_t kSettleFrames = 48 * kBlock;

// Deterministic cost record. Operations are counted in flops-equivalents: 5 N log2 N per N-point
// complex FFT, 8 per complex multiply-add bin, N per window fill or mirror.
struct Counter {
    uint64_t lastTick = 0;
    uint64_t worstTick = 0;
    uint64_t totalOps = 0;
    uint64_t ticks = 0;
};

// Stage-shared header. Written by init; `hashLo` / `hashHi` are filled in by the owner (state-carry identity).
struct Shared {
    uint32_t taps;
    uint32_t mode;    // 0 = convolution, 1 = unit impulse run as a delay
    uint32_t delay;   // mode 1: the impulse index (output delay is delay + kBlock frames)
    uint32_t parts[3];
    uint32_t hashLo, hashHi;
};

// Control thread. Bytes of stage-shared and of one lane's state for a tap set (taps are inspected for the
// unit-impulse case). n must be 1..kMaxTaps.
size_t sharedBytes(const float *taps, uint32_t n);
size_t laneBytes(const float *taps, uint32_t n);

// Control thread. `shared` is sharedBytes(taps, n) zeroed bytes, 16-byte aligned.
void init(void *shared, const float *taps, uint32_t n);

// Realtime. Epoch bookkeeping: the owner compares laneEpoch with its history epoch and calls resetStep (or
// resetLane, which finishes the whole reset at once; tests and the control thread only).
uint32_t laneEpoch(const void *lane) N60_RT_NONBLOCKING;
void resetLane(const void *shared, void *lane, uint32_t epoch);
// Realtime. Clears the lane for `epoch` in steps. `budget` (bytes, may be null for unlimited) is reduced by what
// this call cleared. Returns true when the lane is reset and on `epoch`.
bool resetStep(const void *shared, void *lane, uint32_t epoch, uint64_t *budget) N60_RT_NONBLOCKING;

// Realtime. Lazy lane carry between two lanes of the same tap schedule (same Shared parts and mode).
// carryHeader copies the fixed part now and puts `dst` on `epoch`. carryBytes is the size of the rest;
// carryCopy copies up to `maxBytes` of it from byte `offset` and returns the bytes copied (0 at the end).
void carryHeader(const void *shared, const void *src, void *dst, uint32_t epoch) N60_RT_NONBLOCKING;
size_t carryBytes(const void *shared) N60_RT_NONBLOCKING;
size_t carryCopy(const void *shared, const void *src, void *dst, size_t offset, size_t maxBytes) N60_RT_NONBLOCKING;
// Frames after the copy completes before the lane output matches the source lane (0 in delay mode).
uint32_t carrySettleFrames(const void *shared) N60_RT_NONBLOCKING;

// Realtime. In place over `frames` frames of one lane. `counter` may be null.
// `scratch` (E20 S5): null uses the stage's shared scratch FFT buffer, which two lanes of one stage must not do at the same
// time. A parallel job passes its own buffer of scratchBytes() bytes (16-byte aligned); results are bit-identical.
size_t scratchBytes();
void process(void *shared, void *lane, float *buf, uint32_t frames, Counter *counter, void *scratch = nullptr) N60_RT_NONBLOCKING;

}  // namespace n60::conv

#endif
