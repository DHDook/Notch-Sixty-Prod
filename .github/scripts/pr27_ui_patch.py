from pathlib import Path

path = Path("NotchSixty/ContentView.swift")
text = path.read_text()

text = text.replace(
    'Text("Production transport + minimum/linear EQ + gain/headroom + crossover + room-correction runtime validation")',
    'Text("Production transport + minimum/linear EQ + gain/headroom + crossover + dynamics/protection + room-correction runtime validation")'
)

needle = '''        let gateRelease = dynamicsBinding(\\.pauseGate.releaseMs)\n'''
replacement = '''        let gateRelease = dynamicsBinding(\\.pauseGate.releaseMs)\n        let oversampling = dynamicsBinding(\\.oversampling)\n        let clipperEnabled = dynamicsBinding(\\.softClipper.enabled)\n        let clipperDrive = dynamicsBinding(\\.softClipper.driveDB)\n        let clipperThreshold = dynamicsBinding(\\.softClipper.thresholdDB)\n        let clipperCurve = dynamicsBinding(\\.softClipper.curve)\n        let clipperAutoGain = dynamicsBinding(\\.softClipper.autoCompensateGain)\n        let limiterEnabled = dynamicsBinding(\\.limiter.enabled)\n        let limiterCeiling = dynamicsBinding(\\.limiter.ceilingDB)\n        let limiterAttack = dynamicsBinding(\\.limiter.attackMs)\n        let limiterRelease = dynamicsBinding(\\.limiter.releaseMs)\n        let limiterLookAhead = dynamicsBinding(\\.limiter.lookAheadMs)\n'''
assert needle in text, "dynamics binding insertion point not found"
text = text.replace(needle, replacement, 1)

text = text.replace(
    'Text("PR26 parity foundation")',
    'Text("PR27 protection + oversampling")',
    1
)

needle = '''            HStack(spacing: 12) {\n                Text("Gate fades").frame(width: 90, alignment: .leading)\n                Text("Attack / fade-out")\n                Slider(value: gateAttack, in: PauseGateConfiguration.attackRange, step: 1).frame(width: 120)\n                Text("\\(engine.dynamicsConfiguration.pauseGate.attackMs, specifier: \"%.0f\") ms")\n                    .monospacedDigit().frame(width: 60)\n                Text("Release / fade-in")\n                Slider(value: gateRelease, in: PauseGateConfiguration.releaseRange, step: 5).frame(width: 120)\n                Text("\\(engine.dynamicsConfiguration.pauseGate.releaseMs, specifier: \"%.0f\") ms")\n                    .monospacedDigit().frame(width: 60)\n            }\n\n'''
insert = needle + '''            Divider()\n\n            HStack(spacing: 12) {\n                Picker("Oversampling", selection: oversampling) {\n                    ForEach(OversamplingFactor.allCases) { factor in\n                        Text(factor.displayName).tag(factor)\n                    }\n                }\n                .pickerStyle(.segmented)\n                .frame(width: 220)\n                Text("1× / 2× / 4× protection-path validation")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n            }\n\n            HStack(spacing: 12) {\n                Toggle("Soft Clipper", isOn: clipperEnabled).toggleStyle(.switch)\n                Text("Drive")\n                Slider(value: clipperDrive, in: SoftClipperConfiguration.driveRange, step: 0.5).frame(width: 120)\n                Text("\\(engine.dynamicsConfiguration.softClipper.driveDB, specifier: \"%.1f\") dB")\n                    .monospacedDigit().frame(width: 62)\n                Text("Threshold")\n                Slider(value: clipperThreshold, in: SoftClipperConfiguration.thresholdRange, step: 0.1).frame(width: 120)\n                Text("\\(engine.dynamicsConfiguration.softClipper.thresholdDB, specifier: \"%.1f\") dB")\n                    .monospacedDigit().frame(width: 62)\n            }\n            HStack(spacing: 12) {\n                Text("Clip curve").frame(width: 90, alignment: .leading)\n                Picker("Curve", selection: clipperCurve) {\n                    ForEach(SoftClipperCurve.allCases) { curve in\n                        Text(curve.displayName).tag(curve)\n                    }\n                }\n                .frame(width: 190)\n                Toggle("Auto gain compensation", isOn: clipperAutoGain).toggleStyle(.switch)\n            }\n\n            HStack(spacing: 12) {\n                Toggle("TP Limiter", isOn: limiterEnabled).toggleStyle(.switch)\n                Text("Ceiling")\n                Slider(value: limiterCeiling, in: LimiterConfiguration.ceilingRange, step: 0.1).frame(width: 120)\n                Text("\\(engine.dynamicsConfiguration.limiter.ceilingDB, specifier: \"%.1f\") dBTP")\n                    .monospacedDigit().frame(width: 72)\n                Text("Look-ahead")\n                Slider(value: limiterLookAhead, in: LimiterConfiguration.lookAheadRange, step: 0.1).frame(width: 120)\n                Text("\\(engine.dynamicsConfiguration.limiter.lookAheadMs, specifier: \"%.1f\") ms")\n                    .monospacedDigit().frame(width: 66)\n            }\n            HStack(spacing: 12) {\n                Text("Limiter timing").frame(width: 90, alignment: .leading)\n                Text("Attack")\n                Slider(value: limiterAttack, in: LimiterConfiguration.attackRange, step: 0.1).frame(width: 120)\n                Text("\\(engine.dynamicsConfiguration.limiter.attackMs, specifier: \"%.1f\") ms")\n                    .monospacedDigit().frame(width: 66)\n                Text("Release")\n                Slider(value: limiterRelease, in: LimiterConfiguration.releaseRange, step: 1).frame(width: 120)\n                Text("\\(engine.dynamicsConfiguration.limiter.releaseMs, specifier: \"%.0f\") ms")\n                    .monospacedDigit().frame(width: 66)\n            }\n\n'''
assert needle in text, "gate fade block not found"
text = text.replace(needle, insert, 1)

needle = '''                HStack(spacing: 18) {\n                    Text("Comp GR: \\(diagnostics?.compressorGainReductionDB ?? 0, specifier: \"%.2f\") dB")\n                    Text("Exp attenuation: \\(diagnostics?.expanderAttenuationDB ?? 0, specifier: \"%.2f\") dB")\n                    Text("Gate: \\((diagnostics?.pauseGateOpen ?? true) ? \"open\" : \"closed\")")\n                    Text("Gate gain: \\(diagnostics?.pauseGateGain ?? 1, specifier: \"%.3f\")")\n                }\n                .font(.caption.monospacedDigit())\n                .foregroundStyle(.secondary)\n'''
replacement = needle + '''                HStack(spacing: 18) {\n                    Text("OS: \\(oversamplingName(diagnostics?.oversamplingFactor ?? N60OversamplingFactor1x)) → \\(oversamplingName(diagnostics?.effectiveOversamplingFactor ?? N60OversamplingFactor1x))")\n                    Text("In TP: \\(formattedLevel(diagnostics?.inputTruePeakLinear ?? 0))")\n                    Text("Out TP: \\(formattedLevel(diagnostics?.outputTruePeakLinear ?? 0))")\n                    Text("Limiter GR: \\(diagnostics?.limiterGainReductionDB ?? 0, specifier: \"%.2f\") dB")\n                    Text("Safety clamps: \\(diagnostics?.limiterSafetyClampSamples ?? 0)")\n                }\n                .font(.caption.monospacedDigit())\n                .foregroundStyle(.secondary)\n'''
assert needle in text, "telemetry block not found"
text = text.replace(needle, replacement, 1)

text = text.replace(
    'Text("Compressor and Expander are linked-stereo. Pause Gate uses Attack for fade-out and Release for fade-in. This is validation UI; the full legacy Dynamics surface remains tracked in docs/DYNAMICS_PARITY_INVENTORY.md.")',
    'Text("Compressor and Expander are linked-stereo. Pause Gate uses Attack for fade-out and Release for fade-in. PR27 adds explicit 1×/2×/4× protection-path validation, soft clipping, true-peak limiting, and realtime protection telemetry. This remains engineering validation UI.")',
    1
)

needle = '''                diagnosticRow("Sub gain", formattedGain(render.crossoverSubGainLinear))\n'''
insert = needle + '''                diagnosticRow(\n                    "Protection",\n                    "clipper \\(render.softClipperEnabled ? \"on\" : \"off\") / limiter \\(render.limiterEnabled ? \"on\" : \"off\") / oversampling \\(oversamplingName(render.oversamplingFactor)) → \\(oversamplingName(render.effectiveOversamplingFactor))"\n                )\n                diagnosticRow("True peak", "input \\(formattedLevel(render.inputTruePeakLinear)) / output \\(formattedLevel(render.outputTruePeakLinear))")\n                diagnosticRow("Limiter GR", "\\(render.limiterGainReductionDB.formatted(.number.precision(.fractionLength(2)))) dB")\n                diagnosticRow("Limiter safety clamps", "\\(render.limiterSafetyClampSamples)")\n'''
assert needle in text, "diagnostics insertion point not found"
text = text.replace(needle, insert, 1)

needle = '''    private func crossoverTopologyName(_ topology: N60CrossoverTopology) -> String {\n'''
insert = '''    private func oversamplingName(_ factor: N60OversamplingFactor) -> String {\n        switch factor {\n        case N60OversamplingFactor4x: return "4×"\n        case N60OversamplingFactor2x: return "2×"\n        default: return "1×"\n        }\n    }\n\n''' + needle
assert needle in text, "helper insertion point not found"
text = text.replace(needle, insert, 1)

path.write_text(text)
