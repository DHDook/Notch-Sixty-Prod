#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
h_path = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.h"
c_path = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.c"
header = h_path.read_text()
text = c_path.read_text()

old_field = """typedef struct {
    N60DSPGraphSnapshot snapshot;
    uint32_t slotIndex;
    bool acquired;
"""
new_field = """typedef struct {
    // Points at the reader-pinned snapshot slot for the lifetime of this render
    // context. The publisher cannot overwrite that slot until EndRender releases
    // its reader count, so copying the full graph once per callback is unnecessary.
    const N60DSPGraphSnapshot *snapshot;
    uint32_t slotIndex;
    bool acquired;
"""
if new_field not in header:
    if header.count(old_field) != 1:
        raise RuntimeError("render-context snapshot field anchor mismatch")
    header = header.replace(old_field, new_field, 1)

old_acquire = """        if (slotIndex == atomic_load_explicit(&kernel->activeSlot, memory_order_acquire)) {
            context.snapshot = slot->snapshot;
            context.slotIndex = slotIndex;
            context.acquired = true;
            return context;
        }
"""
new_acquire = """        if (slotIndex == atomic_load_explicit(&kernel->activeSlot, memory_order_acquire)) {
            context.snapshot = &slot->snapshot;
            context.slotIndex = slotIndex;
            context.acquired = true;
            return context;
        }
"""
if new_acquire not in text:
    if text.count(old_acquire) != 1:
        raise RuntimeError("acquire render-context anchor mismatch")
    text = text.replace(old_acquire, new_acquire, 1)

# The render context now pins the immutable slot instead of owning a copy.
text = text.replace("context->snapshot.", "context->snapshot->")
text = text.replace("context.snapshot.", "context.snapshot->")
text = text.replace("prepare_runtime_for_snapshot(kernel, &context.snapshot);", "prepare_runtime_for_snapshot(kernel, context.snapshot);")

# Defensive pointer checks at render/diagnostics boundaries.
text = text.replace(
    "if (context.acquired) {\n        prepare_runtime_for_snapshot(kernel, context.snapshot);",
    "if (context.acquired && context.snapshot != NULL) {\n        prepare_runtime_for_snapshot(kernel, context.snapshot);",
    1,
)
text = text.replace(
    "if (context.acquired) {\n        diagnostics.publishedGeneration = context.snapshot->generation;",
    "if (context.acquired && context.snapshot != NULL) {\n        diagnostics.publishedGeneration = context.snapshot->generation;",
    1,
)

# Process path should never dereference a missing snapshot even if acquisition failed.
text = text.replace(
    "uint32_t referenceDelayFrames = context->acquired ? context->snapshot->latencyFrames : 0;",
    "uint32_t referenceDelayFrames = context->acquired && context->snapshot != NULL ? context->snapshot->latencyFrames : 0;",
    1,
)
text = text.replace(
    "if (context->acquired && !context->snapshot->bypassed) {",
    "if (context->acquired && context->snapshot != NULL && !context->snapshot->bypassed) {",
    1,
)
text = text.replace(
    "if (context->acquired) {\n        float alignedLeft = left;",
    "if (context->acquired && context->snapshot != NULL) {\n        float alignedLeft = left;",
    1,
)

# There must be no graph-value copy left in acquire_render_context.
acquire_start = text.index("static N60RenderKernelRenderContext acquire_render_context")
acquire_end = text.index("static uint64_t convolution_state_latency", acquire_start)
acquire = text[acquire_start:acquire_end]
if "context.snapshot = slot->snapshot" in acquire:
    raise RuntimeError("full graph copy remains in acquire_render_context")
if "context.snapshot = &slot->snapshot" not in acquire:
    raise RuntimeError("pinned snapshot pointer not installed")

h_path.write_text(header)
c_path.write_text(text)
