from pathlib import Path


def require(path: str, *needles: str) -> None:
    text = Path(path).read_text()
    missing = [needle for needle in needles if needle not in text]
    if missing:
        raise SystemExit(f"{path}: missing disabled-stage contract marker(s): {missing}")


def reject(path: str, *needles: str) -> None:
    text = Path(path).read_text()
    found = [needle for needle in needles if needle in text]
    if found:
        raise SystemExit(f"{path}: forbidden disabled-stage pattern(s) present: {found}")


require(
    "NotchSixty/Audio/DynamicsConfiguration.swift",
    "mainsNotch.continuousTracking,\n            mainsNotch.region.fundamentalHz",
)
reject(
    "NotchSixty/Audio/DynamicsConfiguration.swift",
    "sampleRate,\n            true,\n            mainsNotch.region.fundamentalHz",
)

require(
    "NotchSixty/Audio/Realtime/N60SpectralDenoiser.c",
    "handle_profile_command(runtime, snapshot, sampleRate);",
    "if (!snapshot->enabled && !runtime->captureActive)",
    "park_stream_state(runtime);",
)
require(
    "NotchSixty/Audio/Realtime/N60DynamicEQ.c",
    "if (!snapshot->enabled && runtime->parked) return;",
    "if (!snapshot->enabled && runtime_can_park(runtime, snapshot))",
)
require(
    "NotchSixty/Audio/Realtime/N60DynamicEQ.h",
    "bool parked;",
)

# Every Dynamics substage has its own parked state. This is important when one
# sibling is active: OFF processors must not wake merely because core Dynamics is.
require(
    "NotchSixty/Audio/Realtime/N60Dynamics.h",
    "bool dcParked;",
    "bool infrasonicParked;",
    "bool mainsNotchParked;",
    "bool mainsDetectorParked;",
    "bool stereoModeParked;",
    "bool widenerParked;",
    "bool loudnessMatchParked;",
    "bool loudnessContourParked;",
    "bool dialogueLevelerParked;",
    "bool deHarshParked;",
    "bool deEsserParked;",
    "bool multibandParked;",
    "bool compressorParked;",
    "bool expanderParked;",
    "bool pauseGateParked;",
)
require(
    "NotchSixty/Audio/Realtime/N60Dynamics.c",
    "if (!snapshot->deHarsh.enabled && runtime->deHarshParked) return;",
    "if (!config->enabled && runtime->dialogueLevelerParked) return;",
    "if (!snapshot->deEsser.enabled && runtime->deEsserParked) return;",
    "if (!multiband->enabled && runtime->multibandParked) return;",
    "if (!snapshot->pauseGate.enabled && runtime->pauseGateParked) return;",
    "if (!enabled && runtime->stereoModeParked) return;",
    "if (!widener->enabled && runtime->widenerParked) return;",
    "if (!measurementNeeded && !snapshot->loudnessMatch.enabled && runtime->loudnessMatchParked) return;",
    "if (!config->enabled && runtime->loudnessContourParked) return;",
    "} else if (!runtime->compressorParked) {",
    "} else if (!runtime->expanderParked) {",
)

require(
    "NotchSixty/Audio/Realtime/N60Protection.c",
    "snapshot->effectiveFactor == N60OversamplingFactor1x",
    "!snapshot->softClipperEnabled",
    "!snapshot->limiterEnabled",
)
require(
    "NotchSixty/Audio/Realtime/N60FractionalDelay.h",
    "if (!runtime->current.enabled && runtime->transitionFramesRemaining == 0u)",
)
require(
    "NotchSixty/Audio/Realtime/N60RenderKernel.h",
    "bool meteringEnabled;",
    "N60DSPGraphSnapshotSetMeteringEnabled",
)
require(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    "snapshot.meteringEnabled = false;",
    "context->snapshot->meteringEnabled",
    "smoothed_gain_is_settled_at(&kernel->speakerCrossfeedAmount, 0.0f)",
    "smoothed_gain_is_settled_at(&kernel->crosstalkCancellationAmount, 0.0f)",
    "snapshot->crosstalkCancellation.enabled ? snapshot->crosstalkCancellation.headShadowAlpha : 0.0f",
)

# These FIR/crossover branches already obey the contract and are guarded here so
# future refactors do not accidentally make disabled processors hot again.
require(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    "if (context->snapshot->convolution.enabled)",
    "if (context->snapshot->roomCorrection.enabled)",
    "if (context->snapshot->speakerIR.enabled)",
    "if (!path->snapshot.enabled)",
)

print("PR35 optional-stage parking contract validation passed")
