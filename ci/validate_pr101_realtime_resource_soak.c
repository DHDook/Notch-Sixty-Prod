#include <CoreAudio/CoreAudio.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60RealtimeAudioBridge.h"

#define SAMPLE_RATE 96000.0
#define BUFFER_FRAMES 512u
#define BRIDGE_CAPACITY 65536u
#define WARMUP_CALLBACKS 2048u
#define SOAK_BLOCKS 16u
#define NORMAL_CALLBACKS_PER_BLOCK 1024u
#define STARVATION_FAULTS_PER_BLOCK 32u

static float input_samples[BUFFER_FRAMES * 2u];
static float output_samples[BUFFER_FRAMES * 2u];

static void configure_buffer_lists(
    AudioBufferList *input,
    AudioBufferList *output
) {
    *input = (AudioBufferList){0};
    input->mNumberBuffers = 1u;
    input->mBuffers[0].mNumberChannels = 2u;
    input->mBuffers[0].mDataByteSize =
        BUFFER_FRAMES * 2u * (UInt32)sizeof(float);
    input->mBuffers[0].mData = input_samples;

    *output = (AudioBufferList){0};
    output->mNumberBuffers = 1u;
    output->mBuffers[0].mNumberChannels = 2u;
    output->mBuffers[0].mDataByteSize =
        BUFFER_FRAMES * 2u * (UInt32)sizeof(float);
    output->mBuffers[0].mData = output_samples;
}

static void fill_input(uint64_t sequence) {
    for (uint32_t frame = 0u; frame < BUFFER_FRAMES; ++frame) {
        uint64_t pattern = sequence * BUFFER_FRAMES + frame;
        input_samples[frame * 2u] =
            (pattern & 1u) == 0u ? 0.18f : -0.17f;
        input_samples[frame * 2u + 1u] =
            (pattern & 2u) == 0u ? -0.13f : 0.14f;
    }
}

static void poison_output(void) {
    for (uint32_t index = 0u; index < BUFFER_FRAMES * 2u; ++index) {
        output_samples[index] = NAN;
    }
}

static bool output_is_finite(void) {
    for (uint32_t index = 0u; index < BUFFER_FRAMES * 2u; ++index) {
        if (!isfinite(output_samples[index])) return false;
    }
    return true;
}

static bool output_is_exact_silence(void) {
    for (uint32_t index = 0u; index < BUFFER_FRAMES * 2u; ++index) {
        if (output_samples[index] != 0.0f) return false;
    }
    return true;
}

static bool output_has_signal(void) {
    for (uint32_t index = 0u; index < BUFFER_FRAMES * 2u; ++index) {
        if (fabsf(output_samples[index]) > 1.0e-7f) return true;
    }
    return false;
}

static bool capture_once(
    N60RealtimeAudioBridge *bridge,
    AudioBufferList *input,
    AudioBufferList *output,
    uint64_t sequence
) {
    fill_input(sequence);
    AudioTimeStamp timestamp = {0};
    return N60CaptureIOProc(
        0,
        &timestamp,
        input,
        &timestamp,
        output,
        &timestamp,
        bridge
    ) == noErr;
}

static bool output_once(
    N60RealtimeAudioBridge *bridge,
    AudioBufferList *input,
    AudioBufferList *output
) {
    AudioTimeStamp timestamp = {0};
    poison_output();
    return N60OutputIOProc(
        0,
        &timestamp,
        input,
        &timestamp,
        output,
        &timestamp,
        bridge
    ) == noErr;
}

static size_t heap_bytes_in_use(void) {
    malloc_statistics_t statistics = {0};
    malloc_zone_statistics(malloc_default_zone(), &statistics);
    return statistics.size_in_use;
}

static uint64_t resident_bytes(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(
        mach_task_self(),
        MACH_TASK_BASIC_INFO,
        (task_info_t)&info,
        &count
    );
    return result == KERN_SUCCESS ? (uint64_t)info.resident_size : 0u;
}

int main(void) {
    N60RealtimeAudioBridgeSetMeteringDemand(false);
    N60RealtimeAudioBridgeSetOutputVUMeterDemand(false);

    N60RealtimeAudioBridge *bridge =
        N60RealtimeAudioBridgeCreate(BRIDGE_CAPACITY);
    if (bridge == NULL) {
        fprintf(stderr, "unable to create realtime bridge\n");
        return EXIT_FAILURE;
    }

    N60DSPGraphSnapshot snapshot = N60DSPGraphSnapshotMakeUnity(SAMPLE_RATE);
    if (!N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot)) {
        fprintf(stderr, "unable to publish unity graph\n");
        N60RealtimeAudioBridgeDestroy(bridge);
        return EXIT_FAILURE;
    }
    N60RealtimeAudioBridgeConfigureOutputGate(bridge, 0u, 0u);

    AudioBufferList input = {0};
    AudioBufferList output = {0};
    configure_buffer_lists(&input, &output);

    uint64_t sequence = 0u;
    uint64_t non_finite_samples = 0u;
    uint64_t unexpected_dropouts = 0u;
    uint64_t unrecovered_faults = 0u;
    uint64_t injected_faults = 0u;
    uint64_t recovered_faults = 0u;

    for (uint32_t index = 0u; index < WARMUP_CALLBACKS; ++index) {
        if (!capture_once(bridge, &input, &output, sequence++)
            || !output_once(bridge, &input, &output)
            || !output_is_finite()
            || !output_has_signal()) {
            fprintf(stderr, "warmup callback failed\n");
            N60RealtimeAudioBridgeDestroy(bridge);
            return EXIT_FAILURE;
        }
    }

    // Prime malloc/task telemetry before taking the post-warmup baseline so
    // the measurement itself cannot masquerade as retained callback growth.
    (void)heap_bytes_in_use();
    (void)resident_bytes();

    const size_t heap_baseline = heap_bytes_in_use();
    const uint64_t resident_baseline = resident_bytes();
    size_t maximum_heap_growth = 0u;
    uint64_t maximum_resident = resident_baseline;

    for (uint32_t block = 0u; block < SOAK_BLOCKS; ++block) {
        for (uint32_t index = 0u;
             index < NORMAL_CALLBACKS_PER_BLOCK;
             ++index) {
            if (!capture_once(bridge, &input, &output, sequence++)
                || !output_once(bridge, &input, &output)) {
                fprintf(stderr, "normal callback failed\n");
                N60RealtimeAudioBridgeDestroy(bridge);
                return EXIT_FAILURE;
            }
            if (!output_is_finite()) {
                non_finite_samples += BUFFER_FRAMES * 2u;
            } else if (!output_has_signal()) {
                unexpected_dropouts += 1u;
            }
        }

        for (uint32_t fault = 0u;
             fault < STARVATION_FAULTS_PER_BLOCK;
             ++fault) {
            injected_faults += 1u;

            // The direct SPSC ring is empty after every matched capture/output
            // pair. Deliberately call output without capture: this is an
            // injected starvation fault and must fail closed to exact silence.
            if (!output_once(bridge, &input, &output)) {
                fprintf(stderr, "injected starvation callback failed\n");
                N60RealtimeAudioBridgeDestroy(bridge);
                return EXIT_FAILURE;
            }
            if (!output_is_finite()) {
                non_finite_samples += BUFFER_FRAMES * 2u;
            }
            if (!output_is_exact_silence()) {
                unexpected_dropouts += 1u;
            }

            // Re-prime exactly one hardware quantum. Recovery is accepted only
            // if the very next output is finite and carries signal again.
            if (!capture_once(bridge, &input, &output, sequence++)
                || !output_once(bridge, &input, &output)
                || !output_is_finite()
                || !output_has_signal()) {
                unrecovered_faults += 1u;
            } else {
                recovered_faults += 1u;
            }
        }

        const size_t heap_now = heap_bytes_in_use();
        const uint64_t resident_now = resident_bytes();
        if (heap_now > heap_baseline) {
            const size_t growth = heap_now - heap_baseline;
            if (growth > maximum_heap_growth) {
                maximum_heap_growth = growth;
            }
        }
        if (resident_now > maximum_resident) {
            maximum_resident = resident_now;
        }
    }

    const size_t heap_final = heap_bytes_in_use();
    const uint64_t resident_final = resident_bytes();
    if (resident_final > maximum_resident) {
        maximum_resident = resident_final;
    }

    N60RealtimeAudioBridgeSnapshot counters =
        N60RealtimeAudioBridgeGetSnapshot(bridge);

    const uint64_t normal_callbacks =
        (uint64_t)SOAK_BLOCKS * NORMAL_CALLBACKS_PER_BLOCK;
    const uint64_t expected_faults =
        (uint64_t)SOAK_BLOCKS * STARVATION_FAULTS_PER_BLOCK;
    const uint64_t expected_underrun_frames =
        expected_faults * BUFFER_FRAMES;
    const uint64_t expected_capture_callbacks =
        WARMUP_CALLBACKS + normal_callbacks + expected_faults;
    const uint64_t expected_output_callbacks =
        expected_capture_callbacks + expected_faults;

    const int64_t heap_growth =
        heap_final >= heap_baseline
            ? (int64_t)(heap_final - heap_baseline)
            : -(int64_t)(heap_baseline - heap_final);
    const int64_t resident_growth =
        resident_final >= resident_baseline
            ? (int64_t)(resident_final - resident_baseline)
            : -(int64_t)(resident_baseline - resident_final);

    const bool callback_accounting_ok =
        counters.captureCallbacks == expected_capture_callbacks
        && counters.outputCallbacks == expected_output_callbacks
        && counters.underrunFrames == expected_underrun_frames
        && counters.overrunFrames == 0u
        && counters.unsupportedBufferLayouts == 0u
        && counters.bufferedFrames == 0u;
    const bool dropout_recovery_accepted =
        injected_faults == expected_faults
        && recovered_faults == injected_faults
        && unrecovered_faults == 0u
        && unexpected_dropouts == 0u
        && non_finite_samples == 0u
        && callback_accounting_ok;
    const bool resource_stability_accepted =
        maximum_heap_growth == 0u
        && heap_final <= heap_baseline
        && callback_accounting_ok
        && non_finite_samples == 0u;

    printf("{\n");
    printf("  \"schemaVersion\": 1,\n");
    printf("  \"campaign\": \"PR101_REALTIME_RESOURCE_DROPOUT_SOAK\",\n");
    printf("  \"evidenceAuthority\": \"macOSCI\",\n");
    printf("  \"sampleRateHz\": 96000,\n");
    printf("  \"bufferFrames\": %u,\n", BUFFER_FRAMES);
    printf("  \"warmupCallbacks\": %u,\n", WARMUP_CALLBACKS);
    printf("  \"normalCallbacks\": %" PRIu64 ",\n", normal_callbacks);
    printf("  \"injectedStarvationFaults\": %" PRIu64 ",\n", injected_faults);
    printf("  \"recoveredFaults\": %" PRIu64 ",\n", recovered_faults);
    printf("  \"expectedUnderrunFrames\": %" PRIu64 ",\n", expected_underrun_frames);
    printf("  \"observedUnderrunFrames\": %" PRIu64 ",\n", counters.underrunFrames);
    printf("  \"unexpectedDropouts\": %" PRIu64 ",\n", unexpected_dropouts);
    printf("  \"nonFiniteSamples\": %" PRIu64 ",\n", non_finite_samples);
    printf("  \"unrecoveredFaults\": %" PRIu64 ",\n", unrecovered_faults);
    printf("  \"overrunFrames\": %" PRIu64 ",\n", counters.overrunFrames);
    printf(
        "  \"unsupportedBufferLayouts\": %" PRIu64 ",\n",
        counters.unsupportedBufferLayouts
    );
    printf("  \"captureCallbacks\": %" PRIu64 ",\n", counters.captureCallbacks);
    printf("  \"outputCallbacks\": %" PRIu64 ",\n", counters.outputCallbacks);
    printf("  \"heapBytesInUseBaseline\": %zu,\n", heap_baseline);
    printf("  \"heapBytesInUseFinal\": %zu,\n", heap_final);
    printf("  \"heapRetainedGrowthBytes\": %" PRId64 ",\n", heap_growth);
    printf("  \"maximumCheckpointHeapGrowthBytes\": %zu,\n", maximum_heap_growth);
    printf("  \"residentBytesBaseline\": %" PRIu64 ",\n", resident_baseline);
    printf("  \"residentBytesFinal\": %" PRIu64 ",\n", resident_final);
    printf("  \"residentGrowthBytes\": %" PRId64 ",\n", resident_growth);
    printf("  \"maximumResidentBytesObserved\": %" PRIu64 ",\n", maximum_resident);
    printf(
        "  \"dropoutRecoveryStressAccepted\": %s,\n",
        dropout_recovery_accepted ? "true" : "false"
    );
    printf(
        "  \"resourceStabilityAccepted\": %s,\n",
        resource_stability_accepted ? "true" : "false"
    );
    printf("  \"physicalAcceptanceComplete\": false,\n");
    printf("  \"releaseAcceptanceComplete\": false,\n");
    printf("  \"doesNotEstablish\": [\n");
    printf("    \"production Mac thermal stability\",\n");
    printf("    \"real device unplug or replug recovery\",\n");
    printf("    \"real sleep or wake recovery\",\n");
    printf("    \"speaker safety\",\n");
    printf("    \"physical acoustic acceptance\",\n");
    printf("    \"live feed-forward ANC authorization\"\n");
    printf("  ]\n");
    printf("}\n");

    N60RealtimeAudioBridgeDestroy(bridge);
    N60RealtimeAudioBridgeSetMeteringDemand(false);
    N60RealtimeAudioBridgeSetOutputVUMeterDemand(false);

    return resource_stability_accepted && dropout_recovery_accepted
        ? EXIT_SUCCESS
        : EXIT_FAILURE;
}
