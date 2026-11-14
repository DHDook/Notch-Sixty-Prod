// libn60core ABI v4 system stages (E6 S5): bass management, ambient compensation,
// symmetry, speaker crossfeed, crosstalk cancellation, headphone DSP, pause gate,
// protection, mute and the ANC points (howl guard, injection, reference capture).
// Declarations shared with snapshot.cpp, which owns the arena layout and stage table.
#ifndef N60_CORE_STAGES_SYSTEM_HPP
#define N60_CORE_STAGES_SYSTEM_HPP

#include "snapshot.hpp"
#include "jobs.hpp"
#include "platform/rt.hpp"

namespace n60 {

bool isSystemKind(uint32_t kind) N60_RT_NONBLOCKING;

// Control thread. Checks lanes, parameter count and ranges of one ABI v4 system stage.
n60_status validateSystemStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Control thread. Bytes of per-lane state and of stage-shared state (rate dependent).
void systemSizes(const n60_stage_desc &s, double sampleRate, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled).
void systemInit(SnapHeader *h, const StageRec &r);

// Realtime thread. Runs the stage in place over `frames` frames of the output lanes.
void runSystem(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING;

// Realtime thread. E20 S10b: PROTECTION with its lanes as jobs (oversample and clip per lane, the limiter across lanes on
// this thread, then limiter output and downsample per lane). Bit-identical to runSystem. False (nothing done) when the stage
// cannot run that way (bypass, no oversampling, the gain rider engaged); the caller then runs it serially.
bool systemProtectionParallel(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames, JobHost &jobs) N60_RT_NONBLOCKING;
// Control thread (snapshot build). True when the stage can ever run through systemProtectionParallel (static parameters).
bool systemProtectionEligible(const SnapHeader *h, const StageRec &r);
// Any thread. One lane job of a PROTECTION step (mode 1: up, clip; mode 2: look-ahead delay and gain; mode 3: down).
void systemProtectionJob(void *ctx, uint32_t mode, uint32_t lane) N60_RT_NONBLOCKING;

// E20 R3: stages whose lanes are independent and run as phase jobs next to the FIR lanes (AMBIENT). Prepare and Finish run on the
// calling thread before and after the lane jobs; Run processes one lane (any thread). Bit-identical to runSystem.
bool systemLaneParallel(const StageRec &r) N60_RT_NONBLOCKING;
void systemLanePrepare(SnapHeader *h, StageRec &r) N60_RT_NONBLOCKING;
void systemLaneRun(SnapHeader *h, const StageRec &r, uint32_t laneIndex, float *buf, uint32_t frames) N60_RT_NONBLOCKING;
void systemLaneFinish(SnapHeader *h, StageRec &r, uint32_t frames) N60_RT_NONBLOCKING;

// Pure range and liveness check for one parameter (see validateParam).
n60_status validateSystemParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING;

// Frames of latency one lane of this stage adds.
uint32_t systemLatency(const SnapHeader *h, const StageRec &r) N60_RT_NONBLOCKING;

// Realtime thread. A rebuild starts: every ANC injection stage of this snapshot begins its 10 ms
// mute ramp and stays held until the host posts a new re-arm revision (any revision already present is
// absorbed). silentNow starts the hold at zero for an instance that has not yet been audible. Returns how
// many stages.
uint32_t systemRebuildMute(SnapHeader *h, bool silentNow) N60_RT_NONBLOCKING;

// Realtime thread. ABI v12: a protection stage that continues from the live snapshot keeps the gain rider's
// sustained reduction and attenuation (the limiter and half-band state restart, as before).
// Returns the bytes copied, for the caller to charge to the callback budget (G38).
uint64_t systemRiderCarry(SnapHeader *from, SnapHeader *to) N60_RT_NONBLOCKING;

// ABI v30. Control thread, last step of a snapshot build: works out each delta lane's delay from the latency the lane has
// before the subtract, and binds the subtract to its capture. False when the ring cannot hold a block plus the delay.
bool deltaFinalize(SnapHeader *h);
// Realtime thread, at adopt: the capture ring of `to` starts from the same-id ring of `from` (bounded copy, no allocation).
// Returns the bytes copied for the callback budget.
uint64_t deltaCarry(SnapHeader *from, SnapHeader *to) N60_RT_NONBLOCKING;

// Control thread. Protection limiter and true-peak readback (ABI v8); false for other kinds or lanes.
bool readProtectionDynamics(SnapHeader *h, const StageRec &r, uint32_t lane, n60_dynamics_readback *out);

// Control thread. Howl guard status and capture ring reads (immutable fields plus atomics).
bool readGuardStatus(const SnapHeader *h, uint32_t stageId, n60_guard_status *out);
n60_status readCapture(const SnapHeader *h, uint32_t stageId, uint32_t lane, uint64_t startSample, float *dst,
                       uint32_t frames, uint64_t *written);

}  // namespace n60

#endif
