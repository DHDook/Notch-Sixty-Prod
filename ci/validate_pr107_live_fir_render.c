#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../NotchSixty/Audio/Realtime/N60LiveNChannelRenderCore.h"

static void assert_near(float actual, float expected, float tolerance) {
    assert(isfinite(actual));
    assert(fabsf(actual - expected) <= tolerance);
}

static N60LiveNChannelRenderGraph make_stereo_graph(void) {
    const N60ProgramChannelLayout layout =
        N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    assert(N60ProgramChannelLayoutIsValid(&layout));

    N60ProgramLaneGraphSnapshot lanes =
        N60ProgramLaneGraphSnapshotMakeUnity(48000.0, layout);
    assert(N60ProgramLaneGraphFinalize(&lanes));

    uint32_t programPhysical[N60_MAX_PROGRAM_CHANNELS];
    for (uint32_t index = 0u;
         index < N60_MAX_PROGRAM_CHANNELS;
         ++index) {
        programPhysical[index] =
            N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }
    programPhysical[0] = 0u;
    programPhysical[1] = 1u;

    N60LiveNChannelOutputMap map = {0};
    assert(
        N60LiveNChannelOutputMapCompile(
            layout,
            2u,
            programPhysical,
            false,
            0u,
            NULL,
            &map
        )
    );

    N60MultichannelBassManagementSnapshot bass = {0};
    N60LiveNChannelRenderGraph graph = {0};
    assert(
        N60LiveNChannelRenderGraphMake(
            48000.0,
            layout,
            lanes,
            false,
            bass,
            map,
            &graph
        )
    );
    return graph;
}

static N60ProgramFIRProgramInfo make_info(
    uint32_t activeMask,
    const float *taps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames
) {
    N60ProgramFIRProgram *program =
        N60ProgramFIRProgramCreate(
            2u,
            activeMask,
            taps,
            tapCount,
            declaredLatencyFrames
        );
    assert(program != NULL);
    const N60ProgramFIRProgramInfo info =
        N60ProgramFIRProgramGetInfo(program);
    assert(N60ProgramFIRProgramInfoIsValid(info));
    N60ProgramFIRProgramDestroy(program);
    return info;
}

static void test_graph_latency_counts_upstream_fir_when_all_lanes_active(void) {
    const float taps[] = {
        0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f,
    };
    N60LiveNChannelRenderGraph graph = make_stereo_graph();
    const N60ProgramFIRProgramInfo info =
        make_info(0x3u, taps, 3u, 1u);

    assert(
        N60LiveNChannelRenderGraphSetProgramFIRInfo(
            &graph, info, true
        )
    );
    assert(N60LiveNChannelRenderGraphIsValid(&graph));
    assert(graph.laneGraph.coherenceLatencyFrames == 257u);
    assert(
        graph.laneGraph.lanes[0]
            .upstreamProcessingLatencyFrames == 257u
    );
    assert(
        graph.laneGraph.lanes[1]
            .upstreamProcessingLatencyFrames == 257u
    );
    assert(
        N60ProgramLaneGraphEffectiveDelayFrames(
            &graph.laneGraph, 0u
        ) == 0u
    );
    assert(
        N60ProgramLaneGraphEffectiveDelayFrames(
            &graph.laneGraph, 1u
        ) == 0u
    );
    assert(
        N60LiveNChannelRenderGraphLatencyFrames(&graph)
            == 257u
    );
}

static void test_sparse_fir_and_lane_compensation_realign_outputs(void) {
    const float taps[] = {0.0f, 1.0f, 0.0f};
    N60LiveNChannelRenderGraph graph = make_stereo_graph();
    const N60ProgramFIRProgramInfo info =
        make_info(0x1u, taps, 3u, 1u);

    assert(
        N60LiveNChannelRenderGraphSetProgramFIRInfo(
            &graph, info, true
        )
    );
    assert(
        graph.laneGraph.lanes[0]
            .upstreamProcessingLatencyFrames == 257u
    );
    assert(
        graph.laneGraph.lanes[1]
            .upstreamProcessingLatencyFrames == 0u
    );
    assert(
        N60ProgramLaneGraphEffectiveDelayFrames(
            &graph.laneGraph, 0u
        ) == 0u
    );
    assert(
        N60ProgramLaneGraphEffectiveDelayFrames(
            &graph.laneGraph, 1u
        ) == 257u
    );
    assert(
        N60LiveNChannelRenderGraphLatencyFrames(&graph)
            == 257u
    );

    N60LiveNChannelRenderRuntime *runtime =
        N60LiveNChannelRenderRuntimeCreate();
    assert(runtime != NULL);
    assert(
        N60LiveNChannelRenderRuntimeConfigureProgramFIR(
            runtime, &graph, taps
        )
    );
    assert(
        N60LiveNChannelRenderRuntimePrepare(
            runtime, &graph
        )
    );

    const uint32_t alignedImpulseFrame = 257u;
    for (uint32_t frame = 0u;
         frame <= alignedImpulseFrame + 2u;
         ++frame) {
        N60ProgramTransportFrame input = {0};
        input.channels[0] = frame == 0u ? 1.0f : 0.0f;
        input.channels[1] = frame == 0u ? 1.0f : 0.0f;

        N60LiveNChannelPhysicalFrame physical = {0};
        assert(
            N60LiveNChannelRenderProcessFrame(
                runtime,
                &graph,
                &input,
                &physical,
                NULL
            )
        );
        assert(physical.physicalChannelCount == 2u);

        if (frame == alignedImpulseFrame) {
            assert_near(physical.values[0], 1.0f, 1.0e-5f);
            assert_near(physical.values[1], 1.0f, 1.0e-5f);
        } else {
            assert_near(physical.values[0], 0.0f, 1.0e-5f);
            assert_near(physical.values[1], 0.0f, 1.0e-5f);
        }
    }

    N60LiveNChannelRenderRuntimeDestroy(runtime);
}

static void test_graph_rejects_fir_on_semantic_lfe(void) {
    const N60ProgramChannelLayout layout =
        N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    assert(N60ProgramChannelLayoutIsValid(&layout));
    N60ProgramLaneGraphSnapshot lanes =
        N60ProgramLaneGraphSnapshotMakeUnity(48000.0, layout);
    assert(N60ProgramLaneGraphFinalize(&lanes));

    uint32_t programPhysical[N60_MAX_PROGRAM_CHANNELS];
    for (uint32_t index = 0u;
         index < N60_MAX_PROGRAM_CHANNELS;
         ++index) {
        programPhysical[index] =
            N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }
    for (uint32_t index = 0u; index < layout.channelCount; ++index) {
        programPhysical[index] = index;
    }

    N60LiveNChannelOutputMap map = {0};
    assert(
        N60LiveNChannelOutputMapCompile(
            layout,
            layout.channelCount,
            programPhysical,
            false,
            0u,
            NULL,
            &map
        )
    );
    N60MultichannelBassManagementSnapshot bass = {0};
    N60LiveNChannelRenderGraph graph = {0};
    assert(
        N60LiveNChannelRenderGraphMake(
            48000.0, layout, lanes, false, bass, map, &graph
        )
    );

    const float taps[] = {0.0f, 1.0f, 0.0f};
    N60ProgramFIRProgram *program =
        N60ProgramFIRProgramCreate(
            layout.channelCount,
            1u << 3u,
            taps,
            3u,
            1u
        );
    assert(program != NULL);
    const N60ProgramFIRProgramInfo info =
        N60ProgramFIRProgramGetInfo(program);
    N60ProgramFIRProgramDestroy(program);

    assert(
        !N60LiveNChannelRenderGraphSetProgramFIRInfo(
            &graph, info, true
        )
    );
}

static void test_runtime_requires_exact_graph_program_identity(void) {
    const float taps[] = {0.0f, 1.0f, 0.0f};
    N60LiveNChannelRenderGraph graph = make_stereo_graph();
    const N60ProgramFIRProgramInfo info =
        make_info(0x1u, taps, 3u, 1u);
    assert(
        N60LiveNChannelRenderGraphSetProgramFIRInfo(
            &graph, info, true
        )
    );

    N60LiveNChannelRenderRuntime *runtime =
        N60LiveNChannelRenderRuntimeCreate();
    assert(runtime != NULL);

    // A graph that declares FIR cannot prepare until the exact immutable
    // program/runtime has been prepared on the control plane.
    assert(
        !N60LiveNChannelRenderRuntimePrepare(
            runtime, &graph
        )
    );

    const float differentTaps[] = {0.0f, 0.5f, 0.0f};
    // Same structural metadata is intentionally allowed here; exact tap
    // fingerprint identity belongs to the later Swift deployment contract.
    assert(
        N60LiveNChannelRenderRuntimeConfigureProgramFIR(
            runtime, &graph, differentTaps
        )
    );
    assert(
        N60LiveNChannelRenderRuntimePrepare(
            runtime, &graph
        )
    );

    N60LiveNChannelRenderRuntimeDestroy(runtime);
}

int main(void) {
    test_graph_latency_counts_upstream_fir_when_all_lanes_active();
    test_sparse_fir_and_lane_compensation_realign_outputs();
    test_graph_rejects_fir_on_semantic_lfe();
    test_runtime_requires_exact_graph_program_identity();
    puts("PR107 live N-channel FIR render integration validation passed");
    return 0;
}
