from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)

# Expose PR29 loudness telemetry through render diagnostics.
h = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
s = h.read_text()
s = replace_once(
    s,
    """    float multibandHighGainReductionDB;\n    bool compressorEnabled;\n""",
    """    float multibandHighGainReductionDB;\n    float loudnessShortTermLUFS;\n    float loudnessMatchGainDB;\n    float loudnessContourScale;\n    bool compressorEnabled;\n""",
    "render diagnostics loudness fields",
)
h.write_text(s)

c = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
s = c.read_text()
s = replace_once(
    s,
    """    _Atomic uint32_t multibandHighGainReductionBits;\n    _Atomic uint32_t compressorGainReductionBits;\n""",
    """    _Atomic uint32_t multibandHighGainReductionBits;\n    _Atomic uint32_t loudnessShortTermLUFSBits;\n    _Atomic uint32_t loudnessMatchGainBits;\n    _Atomic uint32_t loudnessContourScaleBits;\n    _Atomic uint32_t compressorGainReductionBits;\n""",
    "render kernel loudness atomics",
)
s = replace_once(
    s,
    """        atomic_store_explicit(&kernel->multibandHighGainReductionBits, float_to_bits(telemetry.multibandHighGainReductionDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->compressorGainReductionBits, float_to_bits(telemetry.compressorGainReductionDB), memory_order_relaxed);\n""",
    """        atomic_store_explicit(&kernel->multibandHighGainReductionBits, float_to_bits(telemetry.multibandHighGainReductionDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->loudnessShortTermLUFSBits, float_to_bits(telemetry.loudnessShortTermLUFS), memory_order_relaxed);\n        atomic_store_explicit(&kernel->loudnessMatchGainBits, float_to_bits(telemetry.loudnessMatchGainDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->loudnessContourScaleBits, float_to_bits(telemetry.loudnessContourScale), memory_order_relaxed);\n        atomic_store_explicit(&kernel->compressorGainReductionBits, float_to_bits(telemetry.compressorGainReductionDB), memory_order_relaxed);\n""",
    "publish loudness telemetry",
)
s = replace_once(
    s,
    """    diagnostics.multibandHighGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->multibandHighGainReductionBits, memory_order_relaxed));\n    diagnostics.compressorGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->compressorGainReductionBits, memory_order_relaxed));\n""",
    """    diagnostics.multibandHighGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->multibandHighGainReductionBits, memory_order_relaxed));\n    diagnostics.loudnessShortTermLUFS = bits_to_float(atomic_load_explicit(&kernel->loudnessShortTermLUFSBits, memory_order_relaxed));\n    diagnostics.loudnessMatchGainDB = bits_to_float(atomic_load_explicit(&kernel->loudnessMatchGainBits, memory_order_relaxed));\n    diagnostics.loudnessContourScale = bits_to_float(atomic_load_explicit(&kernel->loudnessContourScaleBits, memory_order_relaxed));\n    diagnostics.compressorGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->compressorGainReductionBits, memory_order_relaxed));\n""",
    "read loudness telemetry",
)
c.write_text(s)

view = Path("NotchSixty/ContentView.swift")
s = view.read_text()
s = replace_once(
    s,
    """            dynamicsValidationView\n            crossoverValidationView\n""",
    """            dynamicsValidationView\n            advancedDynamicsValidationView\n            crossoverValidationView\n""",
    "advanced dynamics view call",
)

advanced = r'''    @ViewBuilder
    private var advancedDynamicsValidationView: some View {
        let stereoMode = dynamicsBinding(\.stereoMode)
        let widenerEnabled = dynamicsBinding(\.stereoWidener.enabled)
        let monoLowBand = dynamicsBinding(\.stereoWidener.monoLowBand)
        let lowWidth = dynamicsBinding(\.stereoWidener.lowWidth)
        let midWidth = dynamicsBinding(\.stereoWidener.midWidth)
        let highWidth = dynamicsBinding(\.stereoWidener.highWidth)
        let lowMidWidthXover = dynamicsBinding(\.stereoWidener.lowMidFrequencyHz)
        let midHighWidthXover = dynamicsBinding(\.stereoWidener.midHighFrequencyHz)

        let dcEnabled = dynamicsBinding(\.dcOffsetFilter.enabled)
        let infrasonicEnabled = dynamicsBinding(\.infrasonicFilter.enabled)
        let infrasonicCutoff = dynamicsBinding(\.infrasonicFilter.cutoffHz)
        let infrasonicSlope = dynamicsBinding(\.infrasonicFilter.slope)

        let loudnessMatchEnabled = dynamicsBinding(\.loudnessMatch.enabled)
        let loudnessTarget = dynamicsBinding(\.loudnessMatch.targetLUFS)
        let loudnessMaxCorrection = dynamicsBinding(\.loudnessMatch.maxCorrectionDB)
        let loudnessAttack = dynamicsBinding(\.loudnessMatch.attackSeconds)
        let loudnessRelease = dynamicsBinding(\.loudnessMatch.releaseSeconds)
        let dialogueGate = dynamicsBinding(\.loudnessMatch.dialogueGateEnabled)

        let contourEnabled = dynamicsBinding(\.loudnessContour.enabled)
        let contourStrength = dynamicsBinding(\.loudnessContour.strength)

        let deEsserEnabled = dynamicsBinding(\.deEsser.enabled)
        let deEsserFrequency = dynamicsBinding(\.deEsser.frequencyHz)
        let deEsserThreshold = dynamicsBinding(\.deEsser.thresholdDB)
        let deEsserDynamicEQ = dynamicsBinding(\.deEsser.dynamicEQMode)

        let multibandEnabled = dynamicsBinding(\.multibandCompressor.enabled)
        let multibandLowMid = dynamicsBinding(\.multibandCompressor.lowMidFrequencyHz)
        let multibandMidHigh = dynamicsBinding(\.multibandCompressor.midHighFrequencyHz)
        let multibandSlope = dynamicsBinding(\.multibandCompressor.slope)
        let multibandLowThreshold = dynamicsBinding(\.multibandCompressor.lowThresholdDB)
        let multibandMidThreshold = dynamicsBinding(\.multibandCompressor.midThresholdDB)
        let multibandHighThreshold = dynamicsBinding(\.multibandCompressor.highThresholdDB)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Advanced dynamics validation").font(.headline)
                Spacer()
                Text("PR28 + PR29")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Picker("Stereo mode", selection: stereoMode) {
                    ForEach(StereoProcessingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(width: 250)

                Toggle("3-band Widener", isOn: widenerEnabled).toggleStyle(.switch)
                Toggle("Mono low band", isOn: monoLowBand).toggleStyle(.switch)
            }

            HStack(spacing: 10) {
                Text("Widths").frame(width: 90, alignment: .leading)
                Text("Low")
                Slider(value: lowWidth, in: StereoWidenerConfiguration.lowWidthRange, step: 0.05).frame(width: 115)
                Text("\(engine.dynamicsConfiguration.stereoWidener.lowWidth, specifier: \"%.2f\")×").monospacedDigit().frame(width: 52)
                Text("Mid")
                Slider(value: midWidth, in: StereoWidenerConfiguration.midWidthRange, step: 0.05).frame(width: 115)
                Text("\(engine.dynamicsConfiguration.stereoWidener.midWidth, specifier: \"%.2f\")×").monospacedDigit().frame(width: 52)
                Text("High")
                Slider(value: highWidth, in: StereoWidenerConfiguration.highWidthRange, step: 0.05).frame(width: 115)
                Text("\(engine.dynamicsConfiguration.stereoWidener.highWidth, specifier: \"%.2f\")×").monospacedDigit().frame(width: 52)
            }

            HStack(spacing: 10) {
                Text("Width xovers").frame(width: 90, alignment: .leading)
                Text("Low/Mid")
                Slider(value: lowMidWidthXover, in: StereoWidenerConfiguration.lowMidFrequencyRange, step: 10).frame(width: 170)
                Text("\(engine.dynamicsConfiguration.stereoWidener.lowMidFrequencyHz, specifier: \"%.0f\") Hz").monospacedDigit().frame(width: 72)
                Text("Mid/High")
                Slider(value: midHighWidthXover, in: StereoWidenerConfiguration.midHighFrequencyRange, step: 100).frame(width: 170)
                Text("\(engine.dynamicsConfiguration.stereoWidener.midHighFrequencyHz, specifier: \"%.0f\") Hz").monospacedDigit().frame(width: 78)
            }

            Divider()

            HStack(spacing: 14) {
                Toggle("DC Offset Filter", isOn: dcEnabled).toggleStyle(.switch)
                Toggle("Infrasonic", isOn: infrasonicEnabled).toggleStyle(.switch)
                Text("Cutoff")
                Slider(value: infrasonicCutoff, in: InfrasonicFilterConfiguration.cutoffRange, step: 1).frame(width: 150)
                Text("\(engine.dynamicsConfiguration.infrasonicFilter.cutoffHz, specifier: \"%.0f\") Hz").monospacedDigit().frame(width: 58)
                Picker("Slope", selection: infrasonicSlope) {
                    ForEach(InfrasonicSlope.allCases) { slope in
                        Text(slope.displayName).tag(slope)
                    }
                }
                .frame(width: 160)
            }

            Divider()

            HStack(spacing: 12) {
                Toggle("LUFS Loudness Match", isOn: loudnessMatchEnabled).toggleStyle(.switch)
                Toggle("Dialogue Gate", isOn: dialogueGate).toggleStyle(.switch)
                Text("Target")
                Slider(value: loudnessTarget, in: LoudnessMatchConfiguration.targetRange, step: 0.5).frame(width: 140)
                Text("\(engine.dynamicsConfiguration.loudnessMatch.targetLUFS, specifier: \"%.1f\") LUFS").monospacedDigit().frame(width: 86)
                Text("Max")
                Slider(value: loudnessMaxCorrection, in: LoudnessMatchConfiguration.maxCorrectionRange, step: 1).frame(width: 110)
                Text("±\(engine.dynamicsConfiguration.loudnessMatch.maxCorrectionDB, specifier: \"%.0f\") dB").monospacedDigit().frame(width: 58)
            }

            HStack(spacing: 10) {
                Text("LUFS timing").frame(width: 90, alignment: .leading)
                Text("Attack")
                Slider(value: loudnessAttack, in: LoudnessMatchConfiguration.attackRange, step: 0.1).frame(width: 145)
                Text("\(engine.dynamicsConfiguration.loudnessMatch.attackSeconds, specifier: \"%.1f\") s").monospacedDigit().frame(width: 50)
                Text("Release")
                Slider(value: loudnessRelease, in: LoudnessMatchConfiguration.releaseRange, step: 0.1).frame(width: 145)
                Text("\(engine.dynamicsConfiguration.loudnessMatch.releaseSeconds, specifier: \"%.1f\") s").monospacedDigit().frame(width: 50)
            }

            HStack(spacing: 12) {
                Toggle("Volume-aware Loudness Contour", isOn: contourEnabled).toggleStyle(.switch)
                Text("Max strength")
                Slider(value: contourStrength, in: LoudnessContourConfiguration.strengthRange, step: 0.05).frame(width: 180)
                Text("\(engine.dynamicsConfiguration.loudnessContour.strength, specifier: \"%.2f\")").monospacedDigit().frame(width: 46)
                Text("Contour automatically backs off as master volume rises.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                HStack(spacing: 16) {
                    Text("Short-term: \(diagnostics?.loudnessShortTermLUFS ?? -120, specifier: \"%.1f\") LUFS")
                    Text("Match gain: \(diagnostics?.loudnessMatchGainDB ?? 0, specifier: \"%+.2f\") dB")
                    Text("Contour: \((diagnostics?.loudnessContourScale ?? 0) * 100, specifier: \"%.0f\")%")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Toggle("De-Esser", isOn: deEsserEnabled).toggleStyle(.switch)
                Toggle("Dynamic EQ", isOn: deEsserDynamicEQ).toggleStyle(.switch)
                Text("Frequency")
                Slider(value: deEsserFrequency, in: DeEsserConfiguration.frequencyRange, step: 100).frame(width: 150)
                Text("\(engine.dynamicsConfiguration.deEsser.frequencyHz, specifier: \"%.0f\") Hz").monospacedDigit().frame(width: 76)
                Text("Threshold")
                Slider(value: deEsserThreshold, in: DeEsserConfiguration.thresholdRange, step: 0.5).frame(width: 140)
                Text("\(engine.dynamicsConfiguration.deEsser.thresholdDB, specifier: \"%.1f\") dB").monospacedDigit().frame(width: 68)
            }

            HStack(spacing: 12) {
                Toggle("3-band Multiband", isOn: multibandEnabled).toggleStyle(.switch)
                Text("Low/Mid")
                Slider(value: multibandLowMid, in: MultibandCompressorConfiguration.lowMidFrequencyRange, step: 5).frame(width: 125)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.lowMidFrequencyHz, specifier: \"%.0f\") Hz").monospacedDigit().frame(width: 70)
                Text("Mid/High")
                Slider(value: multibandMidHigh, in: MultibandCompressorConfiguration.midHighFrequencyRange, step: 100).frame(width: 125)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.midHighFrequencyHz, specifier: \"%.0f\") Hz").monospacedDigit().frame(width: 76)
                Picker("Slope", selection: multibandSlope) {
                    ForEach(MultibandSlope.allCases) { slope in
                        Text(slope.displayName).tag(slope)
                    }
                }
                .frame(width: 170)
            }

            HStack(spacing: 10) {
                Text("MB thresholds").frame(width: 90, alignment: .leading)
                Text("Low")
                Slider(value: multibandLowThreshold, in: MultibandCompressorConfiguration.thresholdRange, step: 0.5).frame(width: 120)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.lowThresholdDB, specifier: \"%.1f\")").monospacedDigit().frame(width: 50)
                Text("Mid")
                Slider(value: multibandMidThreshold, in: MultibandCompressorConfiguration.thresholdRange, step: 0.5).frame(width: 120)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.midThresholdDB, specifier: \"%.1f\")").monospacedDigit().frame(width: 50)
                Text("High")
                Slider(value: multibandHighThreshold, in: MultibandCompressorConfiguration.thresholdRange, step: 0.5).frame(width: 120)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.highThresholdDB, specifier: \"%.1f\") dB").monospacedDigit().frame(width: 64)
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                HStack(spacing: 16) {
                    Text("De-Esser GR: \(diagnostics?.deEsserGainReductionDB ?? 0, specifier: \"%.2f\") dB")
                    Text("MB Low: \(diagnostics?.multibandLowGainReductionDB ?? 0, specifier: \"%.2f\") dB")
                    Text("Mid: \(diagnostics?.multibandMidGainReductionDB ?? 0, specifier: \"%.2f\") dB")
                    Text("High: \(diagnostics?.multibandHighGainReductionDB ?? 0, specifier: \"%.2f\") dB")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text("This engineering surface intentionally exposes the PR28 + PR29 controls needed for hardware validation. Stereo widening defaults remain conservative; extreme settings are available only for deliberate testing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

'''

s = replace_once(
    s,
    """    @ViewBuilder\n    private var crossoverValidationView: some View {\n""",
    advanced + """    @ViewBuilder\n    private var crossoverValidationView: some View {\n""",
    "advanced dynamics view definition",
)
view.write_text(s)
