// E36 S3: see N60VirtualRingPump.h.
//
// Realtime documentation (AGENTS.md section 4):
//   Allocation: none in Process or the IOProc; the scratch is allocated in Create.
//   Synchronisation: none. The reader is owned by the DAC callback; the control plane reads counters relaxed.
//   Latency: the ring's prime level (default 1024 frames) plus whatever the bridge's startup gate adds.
//   Rates: any; the pump moves frames. Channels: the ring may carry 1 to 16; the bridge takes the first two.
//   Reset: the reader re-primes on attach, epoch change and underrun; Destroy frees the scratch.
#include "N60VirtualRingPump.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int N60VirtualRingMapShm(const char *name, const void **base, size_t *bytes) {
    *base = NULL;
    *bytes = 0;
    const int fd = shm_open(name, O_RDONLY, 0);
    if (fd < 0) return errno;
    struct stat info;
    if (fstat(fd, &info) != 0) { const int e = errno; close(fd); return e; }
    if ((uint64_t)info.st_size < N60_VD_RING_BYTES) { close(fd); return EINVAL; }
    void *mapped = mmap(NULL, N60_VD_RING_BYTES, PROT_READ, MAP_SHARED, fd, 0);
    const int e = errno;
    close(fd);
    if (mapped == MAP_FAILED) return e;
    *base = mapped;
    *bytes = N60_VD_RING_BYTES;
    return 0;
}

void N60VirtualRingUnmap(const void *base, size_t bytes) {
    if (base != NULL && bytes > 0) munmap((void *)base, bytes);
}

struct N60VirtualRingPump {
    N60RealtimeAudioBridge *bridge;
    n60_vd_ring_reader reader;
    float *scratch;
    uint32_t maxFrames;
};

N60VirtualRingPump *N60VirtualRingPumpCreate(
    N60RealtimeAudioBridge *bridge, const void *ringBase, size_t ringBytes, uint32_t primeFrames, uint32_t maxFrames
) {
    if (bridge == NULL || ringBase == NULL || maxFrames == 0) return NULL;
    N60VirtualRingPump *pump = (N60VirtualRingPump *)calloc(1, sizeof *pump);
    if (pump == NULL) return NULL;
    pump->scratch = (float *)calloc((size_t)maxFrames * 2u, sizeof(float));
    if (pump->scratch == NULL || n60_vd_ring_reader_attach(&pump->reader, ringBase, ringBytes, primeFrames) != N60_VD_OK) {
        free(pump->scratch);
        free(pump);
        return NULL;
    }
    pump->bridge = bridge;
    pump->maxFrames = maxFrames;
    return pump;
}

void N60VirtualRingPumpDestroy(N60VirtualRingPump *pump) {
    if (pump == NULL) return;
    free(pump->scratch);
    free(pump);
}

N60_RT_NONBLOCKING_C void N60VirtualRingPumpProcess(N60VirtualRingPump *pump, uint32_t frames) {
    if (pump == NULL) return;
    while (frames > 0) {
        const uint32_t chunk = frames < pump->maxFrames ? frames : pump->maxFrames;
        n60_vd_ring_read(&pump->reader, pump->scratch, chunk, 2u);
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = 2;
        list.mBuffers[0].mDataByteSize = chunk * 2u * (uint32_t)sizeof(float);
        list.mBuffers[0].mData = pump->scratch;
        // The capture proc reads only the input list; the other arguments are unused by it.
        AudioTimeStamp unused;
        memset(&unused, 0, sizeof unused);
        AudioBufferList none;
        memset(&none, 0, sizeof none);
        N60CaptureIOProc(0, &unused, &list, &unused, &none, &unused, pump->bridge);
        frames -= chunk;
    }
}

N60_RT_NONBLOCKING_C OSStatus N60VirtualRingOutputIOProc(
    AudioDeviceID inDevice, const AudioTimeStamp * _Nonnull inNow, const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime, AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime, void * _Nullable clientData
) {
    N60VirtualRingPump *pump = (N60VirtualRingPump *)clientData;
    if (pump == NULL) return noErr;
    if (outOutputData != NULL && outOutputData->mNumberBuffers > 0 && outOutputData->mBuffers[0].mNumberChannels > 0) {
        const AudioBuffer *first = &outOutputData->mBuffers[0];
        N60VirtualRingPumpProcess(pump, first->mDataByteSize / (first->mNumberChannels * (uint32_t)sizeof(float)));
    }
    return N60OutputIOProc(inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, pump->bridge);
}

const n60_vd_ring_reader *N60VirtualRingPumpReader(const N60VirtualRingPump *pump) {
    return &pump->reader;
}
