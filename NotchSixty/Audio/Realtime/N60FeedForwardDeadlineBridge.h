#ifndef N60FeedForwardDeadlineBridge_h
#define N60FeedForwardDeadlineBridge_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_FF_DEADLINE_MAX_FRAMES 4096u
#define N60_FF_DEADLINE_MAX_TAPS 64u
#define N60_FF_SHADOW_MAX_STEREO_SUM 0.10f
#define N60_FF_SHADOW_FADE_FRAMES 128u

typedef struct N60FeedForwardDeadlineBridge N60FeedForwardDeadlineBridge;

typedef enum {
    N60FFDeadlineFaultNone = 0,
    N60FFDeadlineFaultInvalidPlan = 1,
    N60FFDeadlineFaultRouteChange = 2,
    N60FFDeadlineFaultBadReference = 3,
    N60FFDeadlineFaultClockDiscontinuity = 4,
    N60FFDeadlineFaultStaleWitness = 5,
    N60FFDeadlineFaultMissedDeadline = 6,
    N60FFDeadlineFaultOverflow = 7,
    N60FFDeadlineFaultStopped = 8,
    N60FFDeadlineFaultOutputEnvelope = 9
} N60FFDeadlineFault;

/// Control-plane trusted identity tokens MUST be regenerated when the
/// actual route/clock changes. Matching tokens are not hardware attestation.
typedef struct {
    uint64_t routeLeaseToken;
    uint64_t synchronizedClockToken;
    double sampleRate;
    double conservativeNoiseLeadSeconds;
    double referenceAcquisitionSeconds;
    double processingSeconds;
    double commandToSeatSeconds;
    double totalSafetyGuardSeconds;
} N60FFDeadlinePlan;

/// Timestamps MUST ALREADY be translated to a calibrated shared seconds
/// timebase outside this bridge. Callback machine ticks alone are insufficient.
typedef struct {
    uint64_t routeLeaseToken;
    uint64_t synchronizedClockToken;
    double sampleRate;
    double firstFrame;
    double firstFrameHostSeconds;
    double witnessedAtSeconds;
} N60FFDeadlineOutputWitness;

typedef struct {
    double referenceFrame;
    double acousticAtHostSeconds;
    double availableAtHostSeconds;
    double evaluatedAtHostSeconds;
    float referenceSample;
} N60FFDeadlineReference;

/// Diagnostic metadata ONLY. Neither anti-noise PCM nor a live output pointer
/// is returned. The actual speaker render graph cannot consume this as audio.
typedef struct {
    double referenceFrame;
    uint64_t hypotheticalOutputFrame;
    double hypotheticalOutputTimeSeconds;
    double estimatedProcessingSlackSeconds;
} N60FFDeadlineRecord;

typedef struct {
    uint32_t queuedRecords;
    uint32_t capacityRecords;
    uint64_t acceptedRecords;
    uint64_t rejectedRecords;
    uint32_t maximumObservedStereoSumMicro;
    uint32_t faultFadeFramesRemaining;
    double simulatedFaultFadeGain;
    bool simulatedBypassReached;
    N60FFDeadlineFault firstFault;
    bool halted;
    bool outputConnected;
    bool liveANCQualified;
} N60FFDeadlineSnapshot;

/// Allocates once on control plane. Requires power-of-two capacity 256..4096.
/// No run-time allocation, locks or Core Audio calls in Process/Read.
N60FeedForwardDeadlineBridge *N60FFDeadlineBridgeCreate(
    uint32_t capacityRecords,
    const N60FFDeadlinePlan *plan,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount
);
/// Control plane after producer and consumer have ceased.
void N60FFDeadlineBridgeDestroy(N60FeedForwardDeadlineBridge *bridge);
void N60FFDeadlineBridgeStop(N60FeedForwardDeadlineBridge *bridge);

/// Producer/control-thread dry-run ONLY. Advances an imaginary fade to bypass
/// after a fault. No PCM is produced and no DAC is affected. A real callback
/// must implement and independently verify its own fault-to-silence action.
bool N60FFDeadlineBridgeAdvanceFaultFade(
    N60FeedForwardDeadlineBridge *bridge,
    uint32_t frames
);

/// Exactly ONE producer invokes Process. Failures halt permanently, flush the
/// dry-run FIR and discard all previously queued diagnostic records.
bool N60FFDeadlineBridgeProcess(
    N60FeedForwardDeadlineBridge *bridge,
    const N60FFDeadlineReference *reference,
    const N60FFDeadlineOutputWitness *output
);

/// Exactly ONE consumer reads. Reports records only; no audio samples.
uint32_t N60FFDeadlineBridgeRead(
    N60FeedForwardDeadlineBridge *bridge,
    N60FFDeadlineRecord *records,
    uint32_t maximumRecords
);

N60FFDeadlineSnapshot N60FFDeadlineBridgeGetSnapshot(
    const N60FeedForwardDeadlineBridge *bridge
);

#ifdef __cplusplus
}
#endif
#endif
