/*
 * Virtual driver programme ring and clock steering (E36 S3, domain version N60_VD_RING_ABI_VERSION).
 *
 * The driver (a separate repository, X1/X2) writes the mixed programme into a POSIX shared-memory ring; the app maps it
 * read-only and reads it from the DAC's callback. No input stream is used, so macOS shows no capture indicator (E36 G1,
 * transport A, closed 23 Nov 2026). This header is the shared artefact: the driver repository copies it. It has no
 * platform include, so mapping the memory (shm_open, mmap) is the backend's job; see
 * NotchSixty/Audio/VirtualDevice/N60VirtualRingPump.c.
 *
 * Layout: a 4096-byte header, then `capacityFrames` frames of interleaved float32, `channels` per frame. The writer is
 * the only thread that stores `writeFrames` (release); the reader loads it (acquire). Counters are monotonic frame
 * numbers, never wrapped; frame n lives at slot n % capacityFrames. A writer restart bumps `epoch`.
 *
 * Realtime: n60_vd_ring_read and n60_vd_ring_write allocate nothing, take no lock and make no system call. Latency: the
 * reader adds `primeFrames` of fill (default 1024 frames; the app passes the larger of 1024 and two callbacks) and nothing else. Rates: any, the ring carries frames, not
 * seconds. Channels: 1 to N60_VD_RING_MAX_CHANNELS in the ring, any count out (extra ring channels are dropped, extra
 * output channels are zero). Reset: attach, epoch change and underrun re-prime.
 */
#ifndef N60_VD_RING_H
#define N60_VD_RING_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_VD_RING_ABI_VERSION 1u

#define N60_VD_RING_MAGIC 0x4E365652u /* 'N6VR' */
#define N60_VD_RING_LAYOUT_VERSION 1u
#define N60_VD_RING_HEADER_BYTES 4096u
/* Fixed size: 384 kHz x 12 channels holds 0.45 s, 384 kHz x 16 channels 0.34 s. */
#define N60_VD_RING_BYTES 8388608u /* 8 MiB; a plain literal so Swift imports it */
#define N60_VD_RING_MAX_CHANNELS 16u

/* Header, little-endian, 8-byte aligned. Fields marked (atomic) are accessed with acquire/release atomics only. */
typedef struct n60_vd_ring_header {
    uint32_t magic;
    uint32_t layoutVersion;
    uint32_t channels;
    uint32_t sampleRate;
    uint32_t capacityFrames;
    uint32_t headerBytes;
    uint32_t epoch;           /* (atomic) bumped by the writer on every restart */
    uint32_t reserved0;
    uint64_t writeFrames;     /* (atomic) frames written since the epoch began */
    uint64_t lastHostTime;    /* (atomic) host time at the end of the last write, 0 if unknown */
    uint64_t reserved1[4];
} n60_vd_ring_header;

/* Result codes. */
#define N60_VD_OK 0
#define N60_VD_ERR_ARGUMENT (-1)
#define N60_VD_ERR_MAGIC (-2)    /* not a ring */
#define N60_VD_ERR_VERSION (-3)  /* layout version this build does not speak */
#define N60_VD_ERR_GEOMETRY (-4) /* channels, capacity or size inconsistent */

uint32_t n60_vd_ring_abi_version(void);
/* Frames the fixed ring holds for a channel count (0 for an invalid count). */
uint32_t n60_vd_ring_capacity_frames(uint32_t channels);

/* Writer side (the driver; tests use it as the reference). Starts or restarts a ring in `bytes` of zeroed or old memory. */
int n60_vd_ring_writer_init(void *base, size_t bytes, uint32_t channels, uint32_t sampleRate);
/* Realtime. Appends `frames` interleaved frames. Returns frames written (always `frames`: a full ring overwrites the oldest). */
uint32_t n60_vd_ring_write(void *base, const float *interleaved, uint32_t frames, uint64_t hostTime);

/* Reader state. Owned by one realtime thread; the counters may be read from the control plane (relaxed). */
typedef struct n60_vd_ring_reader {
    const void *base;
    uint64_t readPos;
    uint32_t epoch;
    uint32_t channels;
    uint32_t capacityFrames;
    uint32_t primeFrames;     /* fill needed before output starts, and the fill kept after a drop */
    uint32_t highFrames;      /* above this the reader drops back to primeFrames */
    uint32_t running;         /* 0 priming (silence), 1 playing */
    uint32_t fillFrames;      /* (atomic, relaxed) fill at the end of the last read */
    uint32_t hasPlayed;       /* 1 once real audio has been output */
    uint64_t fillSum;         /* (atomic) sum of the fill after each running read */
    uint64_t fillSamples;     /* (atomic) number of running reads summed */
    uint64_t underrunFrames;  /* (atomic) silence frames output while running or priming after data had played */
    uint64_t droppedFrames;   /* (atomic) frames skipped because the ring ran too full */
    uint64_t overruns;        /* (atomic) times the writer lapped the reader mid-read */
    uint64_t epochChanges;    /* (atomic) */
} n60_vd_ring_reader;

/* Control plane. Validates the ring and primes the reader. primeFrames 0 picks 1024; it is clamped to a quarter of the ring. */
int n60_vd_ring_reader_attach(n60_vd_ring_reader *reader, const void *base, size_t bytes, uint32_t primeFrames);
/* Realtime. Writes `frames` interleaved frames of `outChannels` into `out`: real programme when primed, silence else.
 * Returns the number of real frames written (the rest is silence). */
uint32_t n60_vd_ring_read(n60_vd_ring_reader *reader, float *out, uint32_t frames, uint32_t outChannels);

/* Control plane. Mean fill in frames over the reads since the last call (pass the same two counters each time, zero at
 * first); a negative value means no running read happened in the window. */
double n60_vd_ring_reader_mean_fill(const n60_vd_ring_reader *reader, uint64_t *prevSum, uint64_t *prevSamples);

/* Clock steering (control plane). The driver's clock is multiplied by the returned scalar so the fill stays at the target.
 * Proportional-integral on the filtered fill error in seconds; the integral is the driver-versus-DAC clock offset. */
typedef struct n60_vd_steer {
    double sampleRate;
    double targetFrames;
    double filteredFrames;
    double integral;          /* seconds of error x second */
    double scalar;
    uint32_t primed;
    uint32_t reserved;
} n60_vd_steer;

#define N60_VD_STEER_MAX_PPM 1000.0 /* the scalar stays within 1 +- 0.001 */

void n60_vd_steer_init(n60_vd_steer *steer, double sampleRate, uint32_t targetFrames);
/* One update per `dtSeconds` (the app uses 0.25 s). Returns the new scalar, also stored in steer->scalar. */
double n60_vd_steer_update(n60_vd_steer *steer, double meanFillFrames, double dtSeconds);

#ifdef __cplusplus
}
#endif

#endif
