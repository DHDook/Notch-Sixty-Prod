from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"anchor not found: {label}")
    return text.replace(old, new, 1)

# -----------------------------------------------------------------------------
# Validation UI: every PR31 denoiser control and realtime telemetry is visible.
# -----------------------------------------------------------------------------
ui = Path('NotchSixty/NotchSixtyApp.swift')
text = ui.read_text()

binding_anchor = '''    private func harmonicDepthBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.harmonicDepthsDB[index] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.harmonicDepthsDB[index] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    var body: some View {
'''
binding_repl = '''    private func harmonicDepthBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.harmonicDepthsDB[index] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.mainsNotch.harmonicDepthsDB[index] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var denoiserEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.dynamicsConfiguration.spectralDenoiser.enabled },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.spectralDenoiser.enabled = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    private var denoiserPresetBinding: Binding<SpectralDenoiserPreset> {
        Binding(
            get: { engine.dynamicsConfiguration.spectralDenoiser.preset },
            set: { value in try? engine.applySpectralDenoiserPreset(value) }
        )
    }

    private func denoiserBinding<Value>(
        _ keyPath: WritableKeyPath<SpectralDenoiserConfiguration, Value>,
        marksCustom: Bool = true
    ) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration.spectralDenoiser[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated.spectralDenoiser[keyPath: keyPath] = value
                if marksCustom { updated.spectralDenoiser.markCustom() }
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    var body: some View {
'''
text = replace_once(text, binding_anchor, binding_repl, 'denoiser UI bindings')

text = text.replace(
    'Text("PR31 Slice 2 adds independent mains-frequency detection, confidence telemetry, one-shot Detect, and bounded Continuous Tracking with click-safe notch retuning. Spectral denoising follows below in Slice 3.")',
    'Text("PR31 now includes mains-frequency detection/tracking plus the new clean-room spectral denoiser. The denoiser is deliberately conservative: linked-stereo WOLA processing, threshold-gated adaptive learning, explicit noise Capture, protected bands, and measurable latency.")'
)

placeholder = '''                GroupBox("Spectral Denoising") {
                    Text("Natural / Standard / Aggressive / Dehiss presets, profile Capture / Reset, protected-frequency range, and Quality / High / Ultra modes are the following PR31 slice.")
                        .foregroundStyle(.secondary)
                        .padding(6)
                }

                Text("Acceptance focus for this slice: with the filter disabled the path must be transparent; with it enabled, a 50/60 Hz tone and selected harmonics should fall by the configured depth without broad tonal loss. Toggle and parameter changes must remain stable and click-free enough for interactive validation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
'''
replacement = '''                GroupBox("Spectral Denoising") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Spectral Denoiser", isOn: denoiserEnabledBinding)
                            .toggleStyle(.switch)

                        Picker("Preset", selection: denoiserPresetBinding) {
                            ForEach(SpectralDenoiserPreset.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Text("Reduction").frame(width: 105, alignment: .leading)
                            Slider(value: denoiserBinding(\\.reductionAmount), in: SpectralDenoiserConfiguration.reductionRange, step: 0.01)
                            Text("\\(engine.dynamicsConfiguration.spectralDenoiser.reductionAmount * 100, specifier: \"%.0f\")%")
                                .monospacedDigit().frame(width: 58)
                        }

                        HStack(spacing: 12) {
                            Text("Threshold").frame(width: 105, alignment: .leading)
                            Slider(value: denoiserBinding(\\.thresholdDBFS), in: SpectralDenoiserConfiguration.thresholdRange, step: 1)
                            Text("\\(engine.dynamicsConfiguration.spectralDenoiser.thresholdDBFS, specifier: \"%.0f\") dBFS")
                                .monospacedDigit().frame(width: 78)
                        }

                        Picker("Quality", selection: denoiserBinding(\\.quality)) {
                            ForEach(SpectralDenoiserQuality.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)

                        Toggle("Protect Frequency Range", isOn: denoiserBinding(\\.protectedRangeEnabled))
                            .toggleStyle(.switch)

                        if engine.dynamicsConfiguration.spectralDenoiser.protectedRangeEnabled {
                            let rate = mainsDiagnostics?.sampleRate ?? 48_000
                            let maximum = max(200.0, min(20_000.0, rate * 0.5 - 1.0))
                            HStack(spacing: 12) {
                                Text("Protected Low").frame(width: 105, alignment: .leading)
                                Slider(value: denoiserBinding(\\.protectedLowHz), in: 0...maximum, step: 10)
                                Text("\\(engine.dynamicsConfiguration.spectralDenoiser.protectedLowHz, specifier: \"%.0f\") Hz")
                                    .monospacedDigit().frame(width: 78)
                            }
                            HStack(spacing: 12) {
                                Text("Protected High").frame(width: 105, alignment: .leading)
                                Slider(value: denoiserBinding(\\.protectedHighHz), in: 0...maximum, step: 10)
                                Text("\\(engine.dynamicsConfiguration.spectralDenoiser.protectedHighHz, specifier: \"%.0f\") Hz")
                                    .monospacedDigit().frame(width: 78)
                            }
                        }

                        Divider()
                        HStack(spacing: 12) {
                            Button("Capture Noise Profile") { try? engine.captureSpectralNoiseProfile() }
                            Button("Reset Profile") { try? engine.resetSpectralNoiseProfile() }
                        }
                        Text("Capture listens for about one second. Use a noise-only passage if possible. Reset returns to conservative adaptive learning. Analysis remains warm while bypassed so enabling does not begin from a cold estimator.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Denoiser Telemetry") {
                    let diagnostics = mainsDiagnostics
                    let status: String = {
                        if diagnostics?.denoiserCaptureActive == true { return "Capturing" }
                        if diagnostics?.denoiserCapturedProfile == true { return "Captured Profile" }
                        if diagnostics?.denoiserProfileReady == true { return "Adaptive Ready" }
                        return "Learning"
                    }()
                    let rate = diagnostics?.sampleRate ?? 0
                    let denoiserFrames = diagnostics?.denoiserLatencyFrames ?? 0
                    let denoiserMS = rate > 0 ? Double(denoiserFrames) * 1000.0 / rate : 0
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        GridRow { Text("Profile state").foregroundStyle(.secondary); Text(status) }
                        GridRow { Text("Capture progress").foregroundStyle(.secondary); Text("\\((diagnostics?.denoiserCaptureProgress ?? 0) * 100, specifier: \"%.0f\")%") }
                        GridRow { Text("Estimated noise").foregroundStyle(.secondary); Text("\\(diagnostics?.denoiserEstimatedNoiseDBFS ?? -120, specifier: \"%.1f\") dBFS") }
                        GridRow { Text("Mean suppression").foregroundStyle(.secondary); Text("\\(diagnostics?.denoiserMeanSuppressionDB ?? 0, specifier: \"%.2f\") dB") }
                        GridRow { Text("Max suppression").foregroundStyle(.secondary); Text("\\(diagnostics?.denoiserMaxSuppressionDB ?? 0, specifier: \"%.2f\") dB") }
                        GridRow { Text("FFT / hop").foregroundStyle(.secondary); Text("\\(diagnostics?.denoiserFFTSize ?? 0) / \\(diagnostics?.denoiserHopSize ?? 0) frames") }
                        GridRow { Text("Denoiser latency").foregroundStyle(.secondary); Text("\\(denoiserFrames) frames  (\\(denoiserMS, specifier: \"%.2f\") ms)") }
                        GridRow { Text("Total DSP latency").foregroundStyle(.secondary); Text("\\(diagnostics?.latencyFrames ?? 0) frames") }
                        GridRow { Text("Spectral frames").foregroundStyle(.secondary); Text("\\(diagnostics?.denoiserSpectralFramesProcessed ?? 0)") }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                }

                Text("Denoiser acceptance focus: start with Natural or Standard. Listen for real noise-floor reduction without pumping, chirping/musical-noise artifacts, softened transients, vocal smearing, or stereo-image movement. Compare Capture against adaptive learning, exercise the protected range, and compare Quality / High / Ultra. Reference and Delta must remain latency aligned. Aggressive is intentionally the stress case, not the default recommendation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
'''
text = replace_once(text, placeholder, replacement, 'denoiser UI placeholder')
ui.write_text(text)

# -----------------------------------------------------------------------------
# Living PR31 technical contract.
# -----------------------------------------------------------------------------
doc = Path('docs/PR31_NOISE_HUM_SUPPRESSION.md')
text = doc.read_text()
if '## Slice 3 — spectral denoiser implementation' not in text:
    text += r'''

## Slice 3 — spectral denoiser implementation

The commercial denoiser is an independent clean-room redesign. The legacy application supplies only the observable preset/control inventory; its `SpectralDenoiser` implementation and tests are not implementation references.

### Signal architecture

- Mains-notch cleanup runs first so coherent 50/60 Hz energy and selected harmonics do not contaminate broadband noise estimation.
- The denoiser uses a 50%-overlapped weighted overlap-add (WOLA) STFT with a square-root Hann analysis/synthesis pair.
- Linked stereo uses one common spectral gain per bin, derived from the larger L/R bin power, while preserving each channel's complex phase. This prevents independent-channel noise decisions from wandering the stereo image.
- Suppression uses a conservative decision-directed Wiener-style gain estimate, bounded by a preset-specific gain floor, plus temporal and modest neighboring-bin smoothing to reduce musical-noise artifacts.
- The protected-frequency range forces unity spectral gain inside the selected range.
- Dehiss increases the noise estimate progressively above roughly 3 kHz rather than applying a broadband extra cut.

### Noise profile behavior

Two workflows exist deliberately:

1. **Adaptive:** low-envelope/minimum statistics learn only bins at or below the Threshold safety ceiling. Clearly above-threshold program bins are not admitted into the adaptive noise model. Upward movement of the learned floor is bounded to approximately +1 dB per one-second estimator block.
2. **Capture:** an explicit user request measures roughly one second and freezes that spectrum as the profile. Capture intentionally bypasses the adaptive threshold gate because the user is declaring the passage to be noise-only; the Threshold still caps suppression-time assumed noise power.

Reset discards the captured profile and returns to conservative adaptive learning. Changing Quality changes the spectral grid and therefore resets the runtime profile.

### Quality / latency contract

| Mode | FFT | Hop | Added denoiser latency |
|---|---:|---:|---:|
| Quality | 1024 | 512 | 1024 frames |
| High | 2048 | 1024 | 2048 frames |
| Ultra | 4096 | 2048 | 4096 frames |

At 96 kHz, those added latencies are approximately 10.67 ms, 21.33 ms, and 42.67 ms. The graph publishes the chosen latency so Processed / Reference / Delta remain aligned. Enabling/disabling the denoiser and changing Quality while active use the graph-transition path rather than a hard live latency change.

### Realtime contract

- portable C hot path
- fixed/preallocated FFT, window, spectral, overlap-add, profile, and telemetry state
- no heap allocation/free, locks, logging, device/file I/O, or filter/FFT-plan construction in the render callback
- FFT/window tables are built at runtime creation on the control side
- exact input passthrough when disabled; analysis/profile state remains warm
- full graph tests include latency accounting, WOLA unity reconstruction against latency-matched Reference, linked-stereo behavior, program-content resistance, protected-band behavior, stationary-noise reduction, and finite 384 kHz operation

### Validation intent

The old denoiser's audible artifacts are not a parity target. Hardware acceptance prioritizes naturalness: noise reduction must not introduce pumping, chirping/musical noise, transient softening, vocal smearing, or stereo-image movement. Natural is the conservative baseline; Aggressive is a stress mode.
'''
doc.write_text(text)

# -----------------------------------------------------------------------------
# Provenance entry.
# -----------------------------------------------------------------------------
prov = Path('docs/PROVENANCE.md')
text = prov.read_text()
if '### PR31 Slice 3 — spectral denoiser' not in text:
    text += r'''

### PR31 Slice 3 — spectral denoiser

- **Classification:** specification-derived / original commercial implementation.
- **Behavioral references:** legacy materials were used only to inventory the visible Natural / Standard / Aggressive / Dehiss / Custom workflow, Reduction Amount, Threshold, Quality modes, protected range, and Capture / Reset controls.
- **Excluded implementation references:** historical `SpectralDenoiser` source, algorithms, tests, tuning internals, and implementation structure were not used as coding references.
- **Independent technical basis:** general public short-time Fourier analysis/weighted overlap-add mathematics, Hann-family perfect-reconstruction windowing concepts, Wiener-style spectral gain estimation, decision-directed a-priori SNR estimation concepts, and conservative low-envelope/minimum-statistics noise estimation. The implementation is independently authored for the proprietary N60 realtime graph and does not reproduce a third-party codebase.
- **Commercial design choices:** linked-stereo common gain, threshold-gated adaptive learning, explicit user-directed one-second Capture, bounded upward noise-floor adaptation, protected unity bands, Dehiss high-frequency weighting, preset-specific gain floors/smoothing, explicit Quality/High/Ultra FFT and latency contracts, and exact disabled passthrough with warm analysis.
- **Realtime implementation:** all FFT/window/profile/OLA scratch is fixed and preallocated when the runtime is created; no allocation, locks, logging, file/device I/O, or plan construction occurs in the render callback.
- **Validation:** synthetic deterministic tests cover exact disabled transparency, captured stationary-noise reduction, linked-stereo ratio, profile Reset, program-material resistance, protected-band behavior, latency-matched WOLA reconstruction, graph latency, and finite operation through 384 kHz. Hardware listening acceptance remains required before PR31 merge.
'''
prov.write_text(text)

# Cleanup diagnostic-only scaffolding now that the root integration failure was
# identified (a test ordering mistake) and the graph integration is green.
for path in [
    Path('.github/debug/pr31_slice3_errors.txt'),
    Path('.github/workflows/pr31-slice3-debug.yml'),
]:
    if path.exists():
        path.unlink()
