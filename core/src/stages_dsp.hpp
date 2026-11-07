// libn60core ABI v3 stages (E6 S4): compressor, expander, dynamic EQ, spectral
// denoiser and program FIR. Declarations shared with snapshot.cpp, which owns the
// arena layout and the stage table.
#ifndef N60_CORE_STAGES_DSP_HPP
#define N60_CORE_STAGES_DSP_HPP

#include "snapshot.hpp"

namespace n60 {

bool isDspKind(uint32_t kind);

// Control thread. Checks lanes, parameter count and ranges of one ABI v3 stage.
n60_status validateDspStage(const n60_stage_desc &s, double sampleRate, uint32_t outputChannels, uint32_t firScheme);

// Control thread. Bytes of per-lane state and of stage-shared state.
void dspSizes(const n60_stage_desc &s, uint32_t firScheme, size_t &perLane, size_t &shared);

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
//
// lazy (E9 S2, firScheme 1 with a rebuild fade): the running state of such a stage is not copied here. The fixed part
// is, and the bulk (input ring and spectrum delay lines) is copied by dspFirCarryStep over the next callbacks while
// both snapshots run the same input. `*pending` is set when dspFirCarryStep has work. The returned warm-up then
// covers the settle time after the copy, not the copy itself (the graph holds the warm-up while the copy runs).
// A filter whose taps changed but whose tap schedule, lanes and every upstream stage are unchanged is seeded the
// same way. Without lazy a firScheme 1 filter longer than N60_FIR_MAX_TAPS is not carried (it warms in full).
uint32_t dspFirCarry(SnapHeader *from, SnapHeader *to, bool lazy, bool *pending);
// Position of the lazy copy over the (stage, lane, byte) space of the incoming snapshot.
struct FirCarryCursor {
    uint32_t stage = 0, lane = 0;
    uint64_t offset = 0;
    uint32_t fromEpoch = 0, toEpoch = 0;  // history epochs at adoption; a change ends the carry
};
// Realtime thread. Copies at most `maxBytes` of the lazy carry and returns the bytes copied; sets *done when
// nothing is left. `from` is the outgoing snapshot, `to` the incoming one.
uint64_t dspFirCarryStep(SnapHeader *from, SnapHeader *to, FirCarryCursor &cursor, uint64_t maxBytes, bool *done);
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
