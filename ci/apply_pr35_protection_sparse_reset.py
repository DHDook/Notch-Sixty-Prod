#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "NotchSixty/Audio/Realtime/N60Protection.c"
text = path.read_text()

old = """void N60ProtectionRuntimeReset(N60ProtectionRuntime *runtime) {
    if (runtime == NULL) return;
    memset(runtime, 0, sizeof(*runtime));
    runtime->limiterGain = 1.0f;
}
"""

new = """void N60ProtectionRuntimeReset(N60ProtectionRuntime *runtime) {
    if (runtime == NULL) return;

    // The large limiter delay/deque backing arrays do not need to be cleared.
    // Resetting the sequence/count metadata makes every old entry unreachable,
    // and delay slots are overwritten before they become readable again. Keep
    // callback-side graph activation bounded by clearing only live runtime state.
    memset(&runtime->upStage1, 0, sizeof(runtime->upStage1));
    memset(&runtime->upStage2, 0, sizeof(runtime->upStage2));
    memset(&runtime->downStage2, 0, sizeof(runtime->downStage2));
    memset(&runtime->downStage1, 0, sizeof(runtime->downStage1));
    runtime->downStage2Phase = 0u;
    runtime->downStage1Phase = 0u;

    runtime->limiterSequence = 0u;
    runtime->limiterGain = 1.0f;
    runtime->gainRiderAttenuationDB = 0.0f;
    runtime->sustainedLimiterGainReductionDB = 0.0f;

    runtime->peakDequeHead = 0u;
    runtime->peakDequeCount = 0u;
    memset(&runtime->telemetry, 0, sizeof(runtime->telemetry));
}
"""

if new in text:
    raise SystemExit(0)
if text.count(old) != 1:
    raise RuntimeError(f"expected one protection reset body, found {text.count(old)}")
path.write_text(text.replace(old, new, 1))
