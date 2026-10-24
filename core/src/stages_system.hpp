// libn60core ABI v4 system stages (E6 S5): bass management, ambient compensation,
// symmetry, speaker crossfeed, crosstalk cancellation, headphone DSP, pause gate,
// protection, mute and the ANC points (howl guard, injection, reference capture).
// Declarations shared with snapshot.cpp, which owns the arena layout and stage table.
#ifndef N60_CORE_STAGES_SYSTEM_HPP
#define N60_CORE_STAGES_SYSTEM_HPP

#include "snapshot.hpp"

namespace n60 {

bool isSystemKind(uint32_t kind);

// Control thread. Checks lanes, parameter count and ranges of one ABI v4 system stage.
n60_status validateSystemStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Control thread. Bytes of per-lane state and of stage-shared state (rate dependent).
void systemSizes(const n60_stage_desc &s, double sampleRate, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled).
void systemInit(SnapHeader *h, const StageRec &r);

// Realtime thread. Runs the stage in place over `frames` frames of the output lanes.
void runSystem(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames);

// Pure range and liveness check for one parameter (see validateParam).
n60_status validateSystemParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value);

// Frames of latency one lane of this stage adds.
uint32_t systemLatency(const SnapHeader *h, const StageRec &r);

// Realtime thread. A rebuild starts: every ANC injection stage of this snapshot begins its 10 ms
// mute ramp and stays held until the host posts a new re-arm revision (any revision already present is
// absorbed). silentNow starts the hold at zero for an instance that has not yet been audible. Returns how
// many stages.
uint32_t systemRebuildMute(SnapHeader *h, bool silentNow);

// Realtime thread. ABI v12: a protection stage that continues from the live snapshot keeps the gain rider's
// sustained reduction and attenuation (the limiter and half-band state restart, as before).
void systemRiderCarry(SnapHeader *from, SnapHeader *to);

// Control thread. Protection limiter and true-peak readback (ABI v8); false for other kinds or lanes.
bool readProtectionDynamics(SnapHeader *h, const StageRec &r, uint32_t lane, n60_dynamics_readback *out);

// Control thread. Howl guard status and capture ring reads (immutable fields plus atomics).
bool readGuardStatus(const SnapHeader *h, uint32_t stageId, n60_guard_status *out);
n60_status readCapture(const SnapHeader *h, uint32_t stageId, uint32_t lane, uint64_t startSample, float *dst,
                       uint32_t frames, uint64_t *written);

}  // namespace n60

#endif
