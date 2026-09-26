from pathlib import Path

# Phase A source integration is complete. This helper intentionally performs no
# mutation now; it verifies that the independently authored Phase A slices are
# present before the dedicated numerical validators/build/tests run. Keeping
# this check idempotent prevents CI from recursively rewriting already-integrated
# source on every branch push.

checks = {
    "NotchSixty/Audio/Realtime/N60Biquad.h": [
        "N60BiquadFilterTypeBandPass = 7",
        "N60BiquadFilterTypePeakingConstantQ = 8",
        "N60BiquadFilterTypeLinkwitzTransform = 9",
        "N60BiquadDesignLinkwitzTransform(",
    ],
    "NotchSixty/Audio/Realtime/N60RenderKernel.h": [
        "N60DSPGraphSnapshotSetEQPreparedBandForChannels(",
        "N60DSPGraphSnapshotSetEQPreparedBand(",
    ],
    "NotchSixty/Audio/Realtime/N60RenderKernel.c": [
        "bool N60DSPGraphSnapshotSetEQPreparedBandForChannels(",
        "bool N60DSPGraphSnapshotSetEQPreparedBand(",
    ],
    "NotchSixty/Audio/Realtime/N60LinearPhaseEQ.h": [
        "usesPreparedCoefficients",
        "preparedCoefficients",
    ],
    "NotchSixty/Audio/AudioIOEngine.swift": [
        "case bandPass",
        "case linkwitzTransform",
        "var constantQ: Bool",
        "var linkwitzTargetHz: Double",
        "var linkwitzTargetQ: Double",
        "func linkwitzCoefficients(sampleRate: Double)",
    ],
    "NotchSixty/ContentView.swift": [
        'Toggle("Constant Q"',
        'Text("Linkwitz")',
    ],
    "NotchSixtyTests/NotchSixtyTests.swift": [
        "testBandPassIsExposedBySwiftEQModelAndLinearPhaseProjection",
        "testConstantQIsTypedPerPeakAndProjectsIntoLinearPhase",
        "testLinkwitzTransformUsesAllFourPhysicalParametersInMinimumAndLinearPhase",
    ],
}

for path, markers in checks.items():
    text = Path(path).read_text()
    missing = [marker for marker in markers if marker not in text]
    if missing:
        raise SystemExit(f"PR34 Phase A integration verification failed for {path}: missing {missing}")

print("PR34 Phase A source integration verified; no mutation required.")
