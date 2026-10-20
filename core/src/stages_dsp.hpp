// libn60core ABI v3 stages (E6 S4): compressor, expander, dynamic EQ, spectral
// denoiser and program FIR. Declarations shared with snapshot.cpp, which owns the
// arena layout and the stage table.
#ifndef N60_CORE_STAGES_DSP_HPP
#define N60_CORE_STAGES_DSP_HPP

#include "snapshot.hpp"

namespace n60 {

bool isDspKind(uint32_t kind);

// Control thread. Checks lanes, parameter count and ranges of one ABI v3 stage.
n60_status validateDspStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels);

// Control thread. Bytes of per-lane state and of stage-shared state.
void dspSizes(const n60_stage_desc &s, size_t &perLane, size_t &shared);

// Control thread, while the snapshot is being built (arena zeroed, StageRec filled).
void dspInit(SnapHeader *h, const StageRec &r);

// Realtime thread. Runs the stage in place over `frames` frames of the output lanes.
void runDsp(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames);

// Pure range and liveness check for one parameter (see validateParam).
n60_status validateDspParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value);

// Control thread. Gain-reduction readback of a COMPRESSOR or EXPANDER lane (ABI v8); false for other kinds.
bool readDspDynamics(SnapHeader *h, const StageRec &r, uint32_t lane, n60_dynamics_readback *out);

// Frames of latency one lane of this stage adds.
uint32_t dspLatency(const SnapHeader *h, const StageRec &r);

// ABI v9 denoiser profile hand-off. All realtime thread, bounded copies, no allocation.
// Copies the profile of the first DENOISER stage of `from` into that of `to` when both exist at the same FFT
// size; false otherwise.
bool dspDenoiserCarry(SnapHeader *from, SnapHeader *to);
// ABI v10 (E6 S8d). Realtime thread. Copies the running state of every FIR stage of `to` that is the same filter
// (stage id, taps, lanes) in `from`, so an unrelated topology change does not restart a convolver. Returns the
// frames of silent warm-up the stages that could not be carried need to fill their history (0 = none).
uint32_t dspFirCarry(SnapHeader *from, SnapHeader *to);
// Control or realtime thread (pure). Frames of input history the FIR stages of `h` hold (longest taps + one partition).
uint32_t dspFirHistoryFrames(const SnapHeader *h);
// Profile of the first DENOISER stage of `h` to / from a plain value; false when `h` has no such stage.
bool dspDenoiserExport(SnapHeader *h, n60_denoiser_state *out);
bool dspDenoiserImport(SnapHeader *h, const n60_denoiser_state *in);
// Applies the kernel's "denoiser off" bookkeeping (quality change, profile command) to a parked state.
void denoiserParkedApplyView(n60_denoiser_state *st, uint32_t fftSize, uint32_t revision, uint32_t command);
// Clears a state to the fresh profile of that FFT size, remembering `lastRevision`.
void denoiserStateFresh(n60_denoiser_state *st, uint32_t fftSize, uint32_t lastRevision);

}  // namespace n60

#endif
