// E36 S3: feeds the realtime bridge from the virtual driver's shared-memory ring, in place of the capture IOProc.
// macOS backend (C): the ring reader itself is portable and lives in core/ (n60/vd_ring.h).
#ifndef N60_VIRTUAL_RING_PUMP_H
#define N60_VIRTUAL_RING_PUMP_H

#include <CoreAudio/CoreAudio.h>
#include <stddef.h>
#include <stdint.h>
#include "../Realtime/N60RealtimeAudioBridge.h"
#include "n60/vd_ring.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct N60VirtualRingPump N60VirtualRingPump;

/// Control plane. Maps the driver's shared-memory ring read-only (`shm_open` is variadic, so Swift cannot call it).
/// Returns 0 and the mapping, or the errno that stopped it (ENOENT: no driver is publishing; EINVAL: object too small).
int N60VirtualRingMapShm(const char * _Nonnull name, const void * _Nullable * _Nonnull base, size_t * _Nonnull bytes);
void N60VirtualRingUnmap(const void * _Nullable base, size_t bytes);

/// Control plane. Maps nothing: `ringBase` is the read-only mapping the caller owns and keeps alive until Destroy.
/// `maxFrames` is the largest callback the output device will ask for; the pump chunks anything bigger.
/// Allocates the stereo scratch here, never in the callback. NULL when the ring is not valid.
N60VirtualRingPump * _Nullable N60VirtualRingPumpCreate(
    N60RealtimeAudioBridge * _Nonnull bridge, const void * _Nonnull ringBase, size_t ringBytes,
    uint32_t primeFrames, uint32_t maxFrames);
/// Control plane. The general form: `captureProc` and `outputProc` are the session's own IOProcs (stereo, N-channel or
/// binaural bridge) and `clientData` is what they expect (their bridge). The pump hands them `channels` interleaved
/// channels read from the ring. Scratch is `maxFrames * channels` floats, allocated here.
N60VirtualRingPump * _Nullable N60VirtualRingPumpCreateWithProcs(
    void * _Nonnull clientData, AudioDeviceIOProc _Nonnull captureProc, AudioDeviceIOProc _Nonnull outputProc,
    uint32_t channels, const void * _Nonnull ringBase, size_t ringBytes, uint32_t primeFrames, uint32_t maxFrames);
void N60VirtualRingPumpDestroy(N60VirtualRingPump * _Nullable pump);

/// Realtime. Reads `frames` from the ring and hands them to N60CaptureIOProc exactly as the tap's capture IOProc would.
/// Silence while the ring primes or after an underrun, so the bridge always receives a full block.
N60_RT_NONBLOCKING_C void N60VirtualRingPumpProcess(N60VirtualRingPump * _Nonnull pump, uint32_t frames);

/// The DAC's IOProc for the driver path: pumps the ring into the bridge, then runs N60OutputIOProc on the same buffers.
/// `clientData` is the pump. One IOProc, one clock: no second device is read (E36 design note 9).
N60_RT_NONBLOCKING_C OSStatus N60VirtualRingOutputIOProc(
    AudioDeviceID inDevice, const AudioTimeStamp * _Nonnull inNow, const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime, AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime, void * _Nullable clientData);

/// Control plane reads of the reader's counters (relaxed). `meanFill` follows n60_vd_ring_reader_mean_fill.
const n60_vd_ring_reader * _Nonnull N60VirtualRingPumpReader(const N60VirtualRingPump * _Nonnull pump);

#ifdef __cplusplus
}
#endif

#endif
