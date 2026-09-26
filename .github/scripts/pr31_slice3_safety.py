from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"anchor not found: {label}")
    return text.replace(old, new, 1)

c = Path('NotchSixty/Audio/Realtime/N60SpectralDenoiser.c')
text = c.read_text()

old_signature = '''static void update_profile(
    N60SpectralDenoiserRuntime *runtime,
    const float *power,
    uint32_t binCount,
    double sampleRate,
    uint32_t hopSize
) {
'''
new_signature = '''static void update_profile(
    N60SpectralDenoiserRuntime *runtime,
    const float *power,
    uint32_t binCount,
    double sampleRate,
    uint32_t hopSize,
    float adaptiveCeilingPower
) {
'''
text = replace_once(text, old_signature, new_signature, 'profile signature')

old_adaptive = '''    for (uint32_t bin = 0; bin < binCount; ++bin) {
        runtime->adaptiveMinimum[bin] = fminf(runtime->adaptiveMinimum[bin], power[bin]);
    }
    runtime->adaptiveFramesInBlock += 1u;
    if (runtime->adaptiveFramesInBlock < runtime->adaptiveBlockTargetFrames) return;

    for (uint32_t bin = 0; bin < binCount; ++bin) {
        float candidate = fmaxf(runtime->adaptiveMinimum[bin], N60_DENOISER_EPSILON);
        if (runtime->adaptiveBlocksCompleted == 0u || runtime->noisePower[bin] <= 0.0f) {
            runtime->noisePower[bin] = candidate;
        } else {
            float previous = runtime->noisePower[bin];
            if (candidate > previous) candidate = fminf(candidate, previous * 1.2589254f); // at most +1 dB per block
            float coefficient = candidate < previous ? 0.55f : 0.90f;
            runtime->noisePower[bin] = coefficient * previous + (1.0f - coefficient) * candidate;
        }
    }
    runtime->adaptiveBlocksCompleted += 1u;
    if (runtime->adaptiveBlocksCompleted >= N60_DENOISER_ADAPTIVE_READY_BLOCKS) runtime->profileReady = true;
    reset_adaptive_minimum(runtime, binCount);
'''
new_adaptive = '''    // Adaptive learning is deliberately conservative: bins above the user-visible
    // threshold are treated as likely program content and are never promoted into
    // the noise model. Explicit Capture is the opt-in path for learning a known
    // noise-only passage and intentionally does not use this gate.
    for (uint32_t bin = 0; bin < binCount; ++bin) {
        if (power[bin] <= adaptiveCeilingPower) {
            runtime->adaptiveMinimum[bin] = fminf(runtime->adaptiveMinimum[bin], power[bin]);
        }
    }
    runtime->adaptiveFramesInBlock += 1u;
    if (runtime->adaptiveFramesInBlock < runtime->adaptiveBlockTargetFrames) return;

    bool learnedAnyBin = false;
    for (uint32_t bin = 0; bin < binCount; ++bin) {
        if (runtime->adaptiveMinimum[bin] == FLT_MAX) continue;
        learnedAnyBin = true;
        float candidate = fmaxf(runtime->adaptiveMinimum[bin], N60_DENOISER_EPSILON);
        if (runtime->adaptiveBlocksCompleted == 0u || runtime->noisePower[bin] <= 0.0f) {
            runtime->noisePower[bin] = candidate;
        } else {
            float previous = runtime->noisePower[bin];
            if (candidate > previous) candidate = fminf(candidate, previous * 1.2589254f); // at most +1 dB per block
            float coefficient = candidate < previous ? 0.55f : 0.90f;
            runtime->noisePower[bin] = coefficient * previous + (1.0f - coefficient) * candidate;
        }
    }
    if (learnedAnyBin) {
        runtime->adaptiveBlocksCompleted += 1u;
        if (runtime->adaptiveBlocksCompleted >= N60_DENOISER_ADAPTIVE_READY_BLOCKS) runtime->profileReady = true;
    }
    reset_adaptive_minimum(runtime, binCount);
'''
text = replace_once(text, old_adaptive, new_adaptive, 'adaptive threshold gate')

old_call = '''    update_profile(runtime, runtime->linkedPower, binCount, sampleRate, snapshot.hopSize);
    update_noise_telemetry(runtime, binCount);

    float thresholdPower = powf(10.0f, snapshot.thresholdDBFS / 10.0f);
'''
new_call = '''    float thresholdPower = powf(10.0f, snapshot.thresholdDBFS / 10.0f);
    update_profile(runtime, runtime->linkedPower, binCount, sampleRate, snapshot.hopSize, thresholdPower);
    update_noise_telemetry(runtime, binCount);

'''
text = replace_once(text, old_call, new_call, 'threshold before profile update')
c.write_text(text)

# Add deterministic regression coverage for program-content resistance and
# protected-band behavior. These tests use only the commercial implementation.
tests = Path('NotchSixtyTests/NotchSixtyTests.swift')
text = tests.read_text()
if 'testSpectralDenoiserAdaptiveLearningDoesNotTreatLoudToneAsNoise' not in text:
    text += r'''

extension NotchSixtyTests {
    func testSpectralDenoiserAdaptiveLearningDoesNotTreatLoudToneAsNoise() throws {
        guard let runtime = N60SpectralDenoiserCreate() else {
            XCTFail("Unable to allocate spectral denoiser")
            return
        }
        defer { N60SpectralDenoiserDestroy(runtime) }
        var snapshot = N60SpectralDenoiserSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60SpectralDenoiserSnapshotConfigure(
            &snapshot, 48_000, true, N60DenoiserTuningAggressive, N60DenoiserQualityQuality,
            1.0, -72, false, 0, 150, 0, N60DenoiserProfileCommandNone
        ))

        let frequency = 3_000.0
        var inputDot = 0.0
        var outputDot = 0.0
        var referencePower = 0.0
        let totalFrames = 48_000 * 4
        for frame in 0..<totalFrames {
            let phase = 2.0 * Double.pi * frequency * Double(frame) / 48_000.0
            let source = Float(0.20 * sin(phase))
            var left: Float = 0
            var right: Float = 0
            N60SpectralDenoiserProcessStereoFrame(runtime, snapshot, 48_000, source, source, &left, &right)
            if frame > 48_000 * 3 {
                let delayedPhase = 2.0 * Double.pi * frequency * Double(frame - Int(snapshot.latencyFrames)) / 48_000.0
                let reference = sin(delayedPhase)
                inputDot += 0.20 * reference * reference
                outputDot += Double(left) * reference
                referencePower += reference * reference
            }
        }
        let inputAmplitude = inputDot / max(referencePower, 1.0e-20)
        let outputAmplitude = outputDot / max(referencePower, 1.0e-20)
        XCTAssertGreaterThan(outputAmplitude, inputAmplitude * 0.96,
                             "Adaptive learning must not classify a clearly above-threshold program tone as stationary noise")
    }

    func testSpectralDenoiserProtectedRangeRemainsNearUnityWhileHighNoiseIsReduced() throws {
        guard let runtime = N60SpectralDenoiserCreate() else {
            XCTFail("Unable to allocate spectral denoiser")
            return
        }
        defer { N60SpectralDenoiserDestroy(runtime) }
        var snapshot = N60SpectralDenoiserSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60SpectralDenoiserSnapshotConfigure(
            &snapshot, 48_000, true, N60DenoiserTuningAggressive, N60DenoiserQualityQuality,
            1.0, -42, true, 0, 200, 1, N60DenoiserProfileCommandCapture
        ))

        let lowHz = 93.75   // exact FFT bin for N=1024 at 48 kHz
        let highHz = 6_000.0
        let totalFrames = 48_000 * 4
        var lowDot = 0.0
        var highDot = 0.0
        var basisPower = 0.0
        for frame in 0..<totalFrames {
            let low = 0.025 * sin(2.0 * Double.pi * lowHz * Double(frame) / 48_000.0)
            let high = 0.025 * sin(2.0 * Double.pi * highHz * Double(frame) / 48_000.0)
            let source = Float(low + high)
            var left: Float = 0
            var right: Float = 0
            N60SpectralDenoiserProcessStereoFrame(runtime, snapshot, 48_000, source, source, &left, &right)
            if frame > 48_000 * 3 {
                let delayedFrame = Double(frame - Int(snapshot.latencyFrames))
                let lowBasis = sin(2.0 * Double.pi * lowHz * delayedFrame / 48_000.0)
                let highBasis = sin(2.0 * Double.pi * highHz * delayedFrame / 48_000.0)
                lowDot += Double(left) * lowBasis
                highDot += Double(left) * highBasis
                basisPower += lowBasis * lowBasis
            }
        }
        let lowAmplitude = lowDot / max(basisPower, 1.0e-20)
        let highAmplitude = highDot / max(basisPower, 1.0e-20)
        XCTAssertGreaterThan(lowAmplitude, 0.022,
                             "The protected low-frequency band should remain close to unity")
        XCTAssertLessThan(highAmplitude, lowAmplitude * 0.75,
                          "An unprotected captured stationary component should be reduced relative to the protected band")
    }
}
'''
tests.write_text(text)
