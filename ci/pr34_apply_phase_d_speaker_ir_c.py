from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


# Render-kernel public contract.
path = "NotchSixty/Audio/Realtime/N60RenderKernel.h"
text = read(path)
text = replace_once(
    text,
    "    N60ConvolutionGraphState convolution;\n    N60ConvolutionGraphState roomCorrection;\n",
    "    N60ConvolutionGraphState convolution;\n    N60ConvolutionGraphState roomCorrection;\n    N60ConvolutionGraphState speakerIR;\n",
    "graph state",
)
text = replace_once(
    text,
    "    uint64_t convolutionProgramMisses;\n    uint64_t roomCorrectionProgramMisses;\n",
    "    uint64_t convolutionProgramMisses;\n    uint64_t roomCorrectionProgramMisses;\n    uint64_t speakerIRProgramMisses;\n",
    "diagnostic misses",
)
text = replace_once(
    text,
    "    uint32_t roomCorrectionDeclaredLatencyFrames;\n    N60StereoMeterReading inputMeter;\n",
    "    uint32_t roomCorrectionDeclaredLatencyFrames;\n    bool speakerIREnabled;\n    uint32_t speakerIRProgramSlot;\n    uint64_t speakerIRProgramGeneration;\n    uint32_t speakerIRTapCount;\n    uint32_t speakerIRPartitionCount;\n    uint32_t speakerIREngineLatencyFrames;\n    uint32_t speakerIRDeclaredLatencyFrames;\n    N60StereoMeterReading inputMeter;\n",
    "speaker diagnostics fields",
)
room_setter = """bool N60DSPGraphSnapshotSetRoomCorrectionProgram(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
);
"""
text = replace_once(
    text,
    room_setter,
    room_setter + """bool N60DSPGraphSnapshotSetSpeakerIRProgram(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
);
""",
    "speaker graph setter declaration",
)
room_prepare = """bool N60RenderKernelPrepareRoomCorrectionProgram(
    N60RenderKernel * _Nonnull kernel,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
"""
text = replace_once(
    text,
    room_prepare,
    room_prepare + """bool N60RenderKernelPrepareSpeakerIRProgram(
    N60RenderKernel * _Nonnull kernel,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
""",
    "speaker prepare declaration",
)
write(path, text)


# Realtime implementation. Reuse the proven partitioned-convolution abstraction,
# but give Speaker IR completely independent prepared-program storage and misses.
path = "NotchSixty/Audio/Realtime/N60RenderKernel.c"
text = read(path)
text = replace_once(
    text,
    "    N60PartitionedConvolver *convolver;\n    N60PartitionedConvolver *roomCorrectionConvolver;\n",
    "    N60PartitionedConvolver *convolver;\n    N60PartitionedConvolver *roomCorrectionConvolver;\n    N60PartitionedConvolver *speakerIRConvolver;\n",
    "kernel convolver storage",
)
text = replace_once(
    text,
    "    _Atomic uint64_t convolutionProgramMisses;\n    _Atomic uint64_t roomCorrectionProgramMisses;\n",
    "    _Atomic uint64_t convolutionProgramMisses;\n    _Atomic uint64_t roomCorrectionProgramMisses;\n    _Atomic uint64_t speakerIRProgramMisses;\n",
    "kernel miss storage",
)
text = replace_once(
    text,
    "        || !convolution_snapshot_is_valid(snapshot.convolution)\n        || !convolution_snapshot_is_valid(snapshot.roomCorrection)) {",
    "        || !convolution_snapshot_is_valid(snapshot.convolution)\n        || !convolution_snapshot_is_valid(snapshot.roomCorrection)\n        || !convolution_snapshot_is_valid(snapshot.speakerIR)) {",
    "snapshot validity",
)
text = replace_once(
    text,
    "    snapshot.roomCorrection.enabled = false;\n    snapshot.roomCorrection.programSlot = N60_CONVOLUTION_NO_PROGRAM;\n    return snapshot;\n",
    "    snapshot.roomCorrection.enabled = false;\n    snapshot.roomCorrection.programSlot = N60_CONVOLUTION_NO_PROGRAM;\n    snapshot.speakerIR.enabled = false;\n    snapshot.speakerIR.programSlot = N60_CONVOLUTION_NO_PROGRAM;\n    return snapshot;\n",
    "unity speaker state",
)
room_setter_impl = """bool N60DSPGraphSnapshotSetRoomCorrectionProgram(
    N60DSPGraphSnapshot *snapshot,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
) {
    if (snapshot == NULL) return false;
    return set_convolution_graph_state(
        snapshot,
        &snapshot->roomCorrection,
        programSlot,
        programInfo,
        enabled
    );
}
"""
text = replace_once(
    text,
    room_setter_impl,
    room_setter_impl + """
bool N60DSPGraphSnapshotSetSpeakerIRProgram(
    N60DSPGraphSnapshot *snapshot,
    uint32_t programSlot,
    N60ConvolutionProgramInfo programInfo,
    bool enabled
) {
    if (snapshot == NULL) return false;
    return set_convolution_graph_state(
        snapshot,
        &snapshot->speakerIR,
        programSlot,
        programInfo,
        enabled
    );
}
""",
    "speaker graph setter",
)
create_anchor = """    if (kernel->denoiserRuntime == NULL) {
        N60ProtectionRuntimeDestroy(kernel->protectionRuntime);
        N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);
        N60PartitionedConvolverDestroy(kernel->convolver);
        free(kernel);
        return NULL;
    }
    N60DSPGraphSnapshot initial = N60DSPGraphSnapshotMakeUnity(48000.0);
"""
create_replacement = """    if (kernel->denoiserRuntime == NULL) {
        N60ProtectionRuntimeDestroy(kernel->protectionRuntime);
        N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);
        N60PartitionedConvolverDestroy(kernel->convolver);
        free(kernel);
        return NULL;
    }
    kernel->speakerIRConvolver = N60PartitionedConvolverCreate();
    if (kernel->speakerIRConvolver == NULL) {
        N60SpectralDenoiserDestroy(kernel->denoiserRuntime);
        N60ProtectionRuntimeDestroy(kernel->protectionRuntime);
        N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);
        N60PartitionedConvolverDestroy(kernel->convolver);
        free(kernel);
        return NULL;
    }
    N60DSPGraphSnapshot initial = N60DSPGraphSnapshotMakeUnity(48000.0);
"""
text = replace_once(text, create_anchor, create_replacement, "speaker convolver allocation")
text = replace_once(
    text,
    "    N60ProtectionRuntimeDestroy(kernel->protectionRuntime);\n    N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);\n    N60PartitionedConvolverDestroy(kernel->convolver);\n    free(kernel);\n",
    "    N60ProtectionRuntimeDestroy(kernel->protectionRuntime);\n    N60PartitionedConvolverDestroy(kernel->speakerIRConvolver);\n    N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);\n    N60PartitionedConvolverDestroy(kernel->convolver);\n    free(kernel);\n",
    "speaker convolver destruction",
)
text = replace_once(
    text,
    "    N60PartitionedConvolverReset(kernel->convolver);\n    N60PartitionedConvolverReset(kernel->roomCorrectionConvolver);\n",
    "    N60PartitionedConvolverReset(kernel->convolver);\n    N60PartitionedConvolverReset(kernel->roomCorrectionConvolver);\n    N60PartitionedConvolverReset(kernel->speakerIRConvolver);\n",
    "speaker convolver reset",
)
text = replace_once(
    text,
    "    atomic_store_explicit(&kernel->convolutionProgramMisses, 0, memory_order_relaxed);\n    atomic_store_explicit(&kernel->roomCorrectionProgramMisses, 0, memory_order_relaxed);\n",
    "    atomic_store_explicit(&kernel->convolutionProgramMisses, 0, memory_order_relaxed);\n    atomic_store_explicit(&kernel->roomCorrectionProgramMisses, 0, memory_order_relaxed);\n    atomic_store_explicit(&kernel->speakerIRProgramMisses, 0, memory_order_relaxed);\n",
    "speaker misses reset",
)
room_prepare_impl = """bool N60RenderKernelPrepareRoomCorrectionProgram(
    N60RenderKernel *kernel,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (kernel == NULL) return false;
    return prepare_program(
        kernel->roomCorrectionConvolver,
        slot,
        leftTaps,
        rightTaps,
        tapCount,
        declaredLatencyFrames,
        programInfoOut
    );
}
"""
text = replace_once(
    text,
    room_prepare_impl,
    room_prepare_impl + """
bool N60RenderKernelPrepareSpeakerIRProgram(
    N60RenderKernel *kernel,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (kernel == NULL) return false;
    return prepare_program(
        kernel->speakerIRConvolver,
        slot,
        leftTaps,
        rightTaps,
        tapCount,
        declaredLatencyFrames,
        programInfoOut
    );
}
""",
    "speaker prepare implementation",
)
text = replace_once(
    text,
    "    if (!prepared_program_matches_graph_state(kernel->convolver, snapshot.convolution)\n        || !prepared_program_matches_graph_state(kernel->roomCorrectionConvolver, snapshot.roomCorrection)) {",
    "    if (!prepared_program_matches_graph_state(kernel->convolver, snapshot.convolution)\n        || !prepared_program_matches_graph_state(kernel->roomCorrectionConvolver, snapshot.roomCorrection)\n        || !prepared_program_matches_graph_state(kernel->speakerIRConvolver, snapshot.speakerIR)) {",
    "speaker publish validation",
)
room_render = """        if (context->snapshot.roomCorrection.enabled) {
            float correctedLeft = left;
            float correctedRight = right;
            if (N60PartitionedConvolverProcessSample(
                    kernel->roomCorrectionConvolver,
                    context->snapshot.roomCorrection.programSlot,
                    context->snapshot.roomCorrection.programGeneration,
                    left,
                    right,
                    &correctedLeft,
                    &correctedRight)) {
                left = correctedLeft;
                right = correctedRight;
            } else {
                atomic_fetch_add_explicit(&kernel->roomCorrectionProgramMisses, 1, memory_order_relaxed);
            }
        }

        N60DynamicsProcessCoreStereoFrameWithMasterGain"""
room_render_new = """        if (context->snapshot.roomCorrection.enabled) {
            float correctedLeft = left;
            float correctedRight = right;
            if (N60PartitionedConvolverProcessSample(
                    kernel->roomCorrectionConvolver,
                    context->snapshot.roomCorrection.programSlot,
                    context->snapshot.roomCorrection.programGeneration,
                    left,
                    right,
                    &correctedLeft,
                    &correctedRight)) {
                left = correctedLeft;
                right = correctedRight;
            } else {
                atomic_fetch_add_explicit(&kernel->roomCorrectionProgramMisses, 1, memory_order_relaxed);
            }
        }

        // Independent global speaker impulse-response slot. This deliberately
        // remains separate from main-EQ FIR and room correction so all three
        // audited FIR workflows can coexist in the current stereo graph.
        if (context->snapshot.speakerIR.enabled) {
            float convolvedLeft = left;
            float convolvedRight = right;
            if (N60PartitionedConvolverProcessSample(
                    kernel->speakerIRConvolver,
                    context->snapshot.speakerIR.programSlot,
                    context->snapshot.speakerIR.programGeneration,
                    left,
                    right,
                    &convolvedLeft,
                    &convolvedRight)) {
                left = convolvedLeft;
                right = convolvedRight;
            } else {
                atomic_fetch_add_explicit(&kernel->speakerIRProgramMisses, 1, memory_order_relaxed);
            }
        }

        N60DynamicsProcessCoreStereoFrameWithMasterGain"""
text = replace_once(text, room_render, room_render_new, "speaker render stage")
text = replace_once(
    text,
    "        diagnostics.roomCorrectionDeclaredLatencyFrames = context.snapshot.roomCorrection.declaredLatencyFrames;\n        N60RenderKernelEndRender(mutableKernel, &context, 0);\n",
    "        diagnostics.roomCorrectionDeclaredLatencyFrames = context.snapshot.roomCorrection.declaredLatencyFrames;\n        diagnostics.speakerIREnabled = context.snapshot.speakerIR.enabled;\n        diagnostics.speakerIRProgramSlot = context.snapshot.speakerIR.programSlot;\n        diagnostics.speakerIRProgramGeneration = context.snapshot.speakerIR.programGeneration;\n        diagnostics.speakerIRTapCount = context.snapshot.speakerIR.tapCount;\n        diagnostics.speakerIRPartitionCount = context.snapshot.speakerIR.partitionCount;\n        diagnostics.speakerIREngineLatencyFrames = context.snapshot.speakerIR.engineLatencyFrames;\n        diagnostics.speakerIRDeclaredLatencyFrames = context.snapshot.speakerIR.declaredLatencyFrames;\n        N60RenderKernelEndRender(mutableKernel, &context, 0);\n",
    "speaker diagnostics snapshot",
)
text = replace_once(
    text,
    "    diagnostics.convolutionProgramMisses = atomic_load_explicit(&kernel->convolutionProgramMisses, memory_order_relaxed);\n    diagnostics.roomCorrectionProgramMisses = atomic_load_explicit(&kernel->roomCorrectionProgramMisses, memory_order_relaxed);\n",
    "    diagnostics.convolutionProgramMisses = atomic_load_explicit(&kernel->convolutionProgramMisses, memory_order_relaxed);\n    diagnostics.roomCorrectionProgramMisses = atomic_load_explicit(&kernel->roomCorrectionProgramMisses, memory_order_relaxed);\n    diagnostics.speakerIRProgramMisses = atomic_load_explicit(&kernel->speakerIRProgramMisses, memory_order_relaxed);\n",
    "speaker diagnostics misses",
)
write(path, text)


# Realtime bridge public API.
path = "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h"
text = read(path)
room_bridge_decl = """bool N60RealtimeAudioBridgePrepareRoomCorrectionProgram(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
"""
text = replace_once(
    text,
    room_bridge_decl,
    room_bridge_decl + """bool N60RealtimeAudioBridgePrepareSpeakerIRProgram(
    N60RealtimeAudioBridge * _Nonnull bridge,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo * _Nullable programInfoOut
);
""",
    "speaker bridge declaration",
)
write(path, text)

path = "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c"
text = read(path)
room_bridge_impl = """bool N60RealtimeAudioBridgePrepareRoomCorrectionProgram(
    N60RealtimeAudioBridge *bridge,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (bridge == NULL || bridge->renderKernel == NULL) return false;
    return N60RenderKernelPrepareRoomCorrectionProgram(
        bridge->renderKernel,
        slot,
        leftTaps,
        rightTaps,
        tapCount,
        declaredLatencyFrames,
        programInfoOut
    );
}
"""
text = replace_once(
    text,
    room_bridge_impl,
    room_bridge_impl + """
bool N60RealtimeAudioBridgePrepareSpeakerIRProgram(
    N60RealtimeAudioBridge *bridge,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    N60ConvolutionProgramInfo *programInfoOut
) {
    if (bridge == NULL || bridge->renderKernel == NULL) return false;
    return N60RenderKernelPrepareSpeakerIRProgram(
        bridge->renderKernel,
        slot,
        leftTaps,
        rightTaps,
        tapCount,
        declaredLatencyFrames,
        programInfoOut
    );
}
""",
    "speaker bridge implementation",
)
write(path, text)

print("PR34 Speaker IR realtime/bridge integration staged.")
