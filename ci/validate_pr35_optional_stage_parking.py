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
    "if (!snapshot->enabled && snapshot->profileCommand != N60DenoiserProfileCommandCapture)",
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
