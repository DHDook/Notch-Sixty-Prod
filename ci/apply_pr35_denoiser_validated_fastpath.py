#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
c_path = ROOT / "NotchSixty/Audio/Realtime/N60SpectralDenoiser.c"
h_path = ROOT / "NotchSixty/Audio/Realtime/N60SpectralDenoiser.h"
r_path = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.c"
text = c_path.read_text()
header = h_path.read_text()
render = r_path.read_text()

# Hot spectral helpers consume the already-validated immutable snapshot by pointer.
text = text.replace(
    "static bool bin_is_protected(N60SpectralDenoiserSnapshot snapshot, double sampleRate, uint32_t bin) {\n    if (!snapshot.protectedRangeEnabled) return false;\n    double frequency = (double)bin * sampleRate / (double)snapshot.fftSize;\n    return frequency >= (double)snapshot.protectedLowHz && frequency <= (double)snapshot.protectedHighHz;\n}",
    "static bool bin_is_protected(const N60SpectralDenoiserSnapshot *snapshot, double sampleRate, uint32_t bin) {\n    if (!snapshot->protectedRangeEnabled) return false;\n    double frequency = (double)bin * sampleRate / (double)snapshot->fftSize;\n    return frequency >= (double)snapshot->protectedLowHz && frequency <= (double)snapshot->protectedHighHz;\n}"
)
text = text.replace(
    "    N60SpectralDenoiserSnapshot snapshot,\n    double sampleRate\n) {\n    if (snapshot.profileRevision == runtime->lastProfileRevision) return;\n    runtime->lastProfileRevision = snapshot.profileRevision;\n    uint32_t binCount = snapshot.fftSize / 2u + 1u;\n    if (snapshot.profileCommand == N60DenoiserProfileCommandReset) {\n        reset_profile(runtime, binCount);\n    } else if (snapshot.profileCommand == N60DenoiserProfileCommandCapture) {\n        begin_capture(runtime, sampleRate, snapshot.hopSize, binCount);\n    }\n}",
    "    const N60SpectralDenoiserSnapshot *snapshot,\n    double sampleRate\n) {\n    if (snapshot->profileRevision == runtime->lastProfileRevision) return;\n    runtime->lastProfileRevision = snapshot->profileRevision;\n    uint32_t binCount = snapshot->fftSize / 2u + 1u;\n    if (snapshot->profileCommand == N60DenoiserProfileCommandReset) {\n        reset_profile(runtime, binCount);\n    } else if (snapshot->profileCommand == N60DenoiserProfileCommandCapture) {\n        begin_capture(runtime, sampleRate, snapshot->hopSize, binCount);\n    }\n}"
)

start = text.index("static void process_spectral_frame(")
end = text.index("\n}\n\nvoid N60SpectralDenoiserProcessStereoFrame(", start) + 3
block = text[start:end]
block = block.replace("    N60SpectralDenoiserSnapshot snapshot,", "    const N60SpectralDenoiserSnapshot *snapshot,")
# Only within this helper, convert direct field access and protected checks.
for field in [
    "fftSize", "thresholdDBFS", "hopSize", "reductionAmount", "dehissStrength",
    "decisionDirectedAlpha", "minimumGain", "spectralSmoothingRadius",
    "suppressionAttack", "suppressionRelease", "latencyFrames"
]:
    block = block.replace(f"snapshot.{field}", f"snapshot->{field}")
block = block.replace("bin_is_protected(snapshot, sampleRate, bin)", "bin_is_protected(snapshot, sampleRate, bin)")
text = text[:start] + block + text[end:]

# Replace the public per-frame body with a validated core plus a defensive wrapper.
start = text.index("void N60SpectralDenoiserProcessStereoFrame(")
end = text.index("\n}\n\nN60SpectralDenoiserTelemetry", start) + 3
new_process = r'''static void process_stereo_frame_validated(
    N60SpectralDenoiserRuntime *runtime,
    const N60SpectralDenoiserSnapshot *snapshot,
    double sampleRate,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (runtime->activeFFTSize != snapshot->fftSize) {
        reset_processing_state(runtime);
        runtime->activeFFTSize = snapshot->fftSize;
    }

    handle_profile_command(runtime, snapshot, sampleRate);

    uint32_t size = snapshot->fftSize;
    runtime->inputLeft[runtime->inputWrite] = inputLeft;
    runtime->inputRight[runtime->inputWrite] = inputRight;
    runtime->inputWrite = (runtime->inputWrite + 1u) % size;
    if (runtime->samplesAvailable < size) runtime->samplesAvailable += 1u;

    uint32_t outputIndex = (uint32_t)(runtime->sampleIndex & (N60_DENOISER_OUTPUT_RING_SIZE - 1u));
    bool outputValid = runtime->outputGenerationTag[outputIndex] == runtime->outputGeneration;
    float delayedLeft = outputValid ? runtime->outputLeft[outputIndex] : 0.0f;
    float delayedRight = outputValid ? runtime->outputRight[outputIndex] : 0.0f;
    if (outputValid) {
        runtime->outputLeft[outputIndex] = 0.0f;
        runtime->outputRight[outputIndex] = 0.0f;
    }

    if (runtime->samplesAvailable == size) {
        if (runtime->samplesSinceFrame == 0u) {
            uint64_t frameStart = runtime->sampleIndex + 1u - (uint64_t)size;
            process_spectral_frame(runtime, snapshot, sampleRate, frameStart);
        }
        runtime->samplesSinceFrame += 1u;
        if (runtime->samplesSinceFrame >= snapshot->hopSize) runtime->samplesSinceFrame = 0u;
    }

    if (snapshot->enabled) {
        *outputLeft = delayedLeft;
        *outputRight = delayedRight;
    } else {
        *outputLeft = inputLeft;
        *outputRight = inputRight;
    }
    runtime->sampleIndex += 1u;
}

void N60SpectralDenoiserProcessStereoFrameValidated(
    N60SpectralDenoiserRuntime *runtime,
    const N60SpectralDenoiserSnapshot *snapshot,
    double sampleRate,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (outputLeft == NULL || outputRight == NULL) return;
    if (runtime == NULL || snapshot == NULL) {
        *outputLeft = inputLeft;
        *outputRight = inputRight;
        return;
    }
    process_stereo_frame_validated(runtime, snapshot, sampleRate, inputLeft, inputRight, outputLeft, outputRight);
}

void N60SpectralDenoiserProcessStereoFrame(
    N60SpectralDenoiserRuntime *runtime,
    N60SpectralDenoiserSnapshot snapshot,
    double sampleRate,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (outputLeft == NULL || outputRight == NULL) return;
    if (runtime == NULL || !N60SpectralDenoiserSnapshotIsValid(snapshot, sampleRate)) {
        *outputLeft = inputLeft;
        *outputRight = inputRight;
        return;
    }
    process_stereo_frame_validated(runtime, &snapshot, sampleRate, inputLeft, inputRight, outputLeft, outputRight);
}
'''
text = text[:start] + new_process + text[end:]

# Header adds an explicitly prevalidated fast path while keeping the safe legacy/test API intact.
anchor = """void N60SpectralDenoiserProcessStereoFrame(
    N60SpectralDenoiserRuntime *runtime,
    N60SpectralDenoiserSnapshot snapshot,
    double sampleRate,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
);
"""
addition = """// Render-kernel fast path. The caller must have already validated the immutable
// snapshot at graph publication. This avoids repeated validation/copying at audio rate.
void N60SpectralDenoiserProcessStereoFrameValidated(
    N60SpectralDenoiserRuntime *runtime,
    const N60SpectralDenoiserSnapshot *snapshot,
    double sampleRate,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
);

""" + anchor
if "N60SpectralDenoiserProcessStereoFrameValidated" not in header:
    if anchor not in header:
        raise RuntimeError("denoiser header process anchor missing")
    header = header.replace(anchor, addition, 1)

old_call = """        N60SpectralDenoiserProcessStereoFrame(
            kernel->denoiserRuntime,
            context->snapshot.dynamics.spectralDenoiser,
            context->snapshot.sampleRate,
"""
new_call = """        N60SpectralDenoiserProcessStereoFrameValidated(
            kernel->denoiserRuntime,
            &context->snapshot.dynamics.spectralDenoiser,
            context->snapshot.sampleRate,
"""
if new_call not in render:
    if old_call not in render:
        raise RuntimeError("render denoiser call anchor missing")
    render = render.replace(old_call, new_call, 1)

# Make sure the hot helper no longer has accidental by-value snapshot signatures.
hot = text[text.index("static bool bin_is_protected"):text.index("N60SpectralDenoiserTelemetry")]
if "process_spectral_frame(\n    N60SpectralDenoiserRuntime *runtime,\n    N60SpectralDenoiserSnapshot snapshot" in hot:
    raise RuntimeError("spectral frame still copies snapshot")

c_path.write_text(text)
h_path.write_text(header)
r_path.write_text(render)
