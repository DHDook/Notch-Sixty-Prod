#ifndef N60ActiveQuietZone_h
#define N60ActiveQuietZone_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_ACTIVE_QUIET_ZONE_MAX_TONES 4u
#define N60_ACTIVE_QUIET_ZONE_MIN_HZ 20.0
#define N60_ACTIVE_QUIET_ZONE_MAX_HZ 150.0
#define N60_ACTIVE_QUIET_ZONE_MAX_TONE_PEAK_DBFS (-24.0)
#define N60_ACTIVE_QUIET_ZONE_MAX_AGGREGATE_PEAK_DBFS (-18.0)

typedef struct {
    double frequencyHz;
    float leftReal;
    float leftImaginary;
    float rightReal;
    float rightImaginary;
    // Prepared by SnapshotSet; callers may leave these zero in input values.
    double incrementCosine;
    double incrementSine;
} N60ActiveQuietZoneToneSnapshot;

typedef struct {
    bool enabled;
    uint32_t toneCount;
    uint32_t transitionFrames;
    N60ActiveQuietZoneToneSnapshot
        tones[N60_ACTIVE_QUIET_ZONE_MAX_TONES];
} N60ActiveQuietZoneSnapshot;

typedef struct {
    double frequencyHz;
    double phaseRadians;
    double oscillatorCosine;
    double oscillatorSine;
    double incrementCosine;
    double incrementSine;
    float currentLeftReal;
    float currentLeftImaginary;
    float currentRightReal;
    float currentRightImaginary;
    float startLeftReal;
    float startLeftImaginary;
    float startRightReal;
    float startRightImaginary;
    float targetLeftReal;
    float targetLeftImaginary;
    float targetRightReal;
    float targetRightImaginary;
    uint32_t transitionFramesTotal;
    uint32_t transitionFramesRemaining;
    bool active;
} N60ActiveQuietZoneToneRuntime;

typedef struct {
    double sampleRate;
    N60ActiveQuietZoneToneRuntime
        tones[N60_ACTIVE_QUIET_ZONE_MAX_TONES];
    float lastLeft;
    float lastRight;
    uint64_t processedFrames;
    uint64_t sanitizedSamples;
} N60ActiveQuietZoneRuntime;

N60ActiveQuietZoneSnapshot
N60ActiveQuietZoneSnapshotMakeBypassed(void);

bool N60ActiveQuietZoneSnapshotSet(
    N60ActiveQuietZoneSnapshot * _Nonnull snapshot,
    const N60ActiveQuietZoneToneSnapshot * _Nullable tones,
    uint32_t toneCount,
    uint32_t transitionFrames,
    double sampleRate,
    bool enabled
);

void N60ActiveQuietZoneRuntimeReset(
    N60ActiveQuietZoneRuntime * _Nonnull runtime,
    double sampleRate
);

/// Control-plane preparation invoked when an immutable graph snapshot changes.
/// Active frequency changes are fail-closed: callers must first publish a
/// zero/bypassed snapshot, allowing the current tone to fade out, before
/// introducing a different frequency in the same slot.
bool N60ActiveQuietZoneRuntimeSchedule(
    N60ActiveQuietZoneRuntime * _Nonnull runtime,
    const N60ActiveQuietZoneSnapshot * _Nonnull snapshot,
    double sampleRate
);

/// Realtime-safe synthesis. No allocation, locks, logging, or transcendental
/// calls occur here; phase increments are prepared during Schedule().
void N60ActiveQuietZoneRuntimeProcessFrame(
    N60ActiveQuietZoneRuntime * _Nonnull runtime,
    float * _Nonnull left,
    float * _Nonnull right
);

void N60ActiveQuietZoneRuntimeLastFrame(
    const N60ActiveQuietZoneRuntime * _Nonnull runtime,
    float * _Nonnull left,
    float * _Nonnull right
);

#ifdef __cplusplus
}
#endif

#endif
