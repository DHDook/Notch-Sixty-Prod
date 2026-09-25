from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    text = p.read_text()
    if text.count(old) < count:
        raise SystemExit(f'missing pattern in {path}: {old[:120]!r}')
    p.write_text(text.replace(old, new, count))

path = 'NotchSixty/ContentView.swift'
replace(path,
'''            playbackValidationView
            gainValidationView
            crossoverValidationView
''',
'''            playbackValidationView
            gainValidationView
            dynamicsValidationView
            crossoverValidationView
''')

marker = '''    @ViewBuilder
    private var crossoverValidationView: some View {
'''
view = r'''    private func dynamicsBinding<Value>(_ keyPath: WritableKeyPath<DynamicsConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { engine.dynamicsConfiguration[keyPath: keyPath] },
            set: { value in
                var updated = engine.dynamicsConfiguration
                updated[keyPath: keyPath] = value
                try? engine.replaceDynamicsConfiguration(updated)
            }
        )
    }

    @ViewBuilder
    private var dynamicsValidationView: some View {
        let compressorEnabled = dynamicsBinding(\.compressor.enabled)
        let compressorThreshold = dynamicsBinding(\.compressor.thresholdDB)
        let compressorRatio = dynamicsBinding(\.compressor.ratio)
        let compressorAttack = dynamicsBinding(\.compressor.attackMs)
        let compressorRelease = dynamicsBinding(\.compressor.releaseMs)
        let expanderEnabled = dynamicsBinding(\.expander.enabled)
        let expanderThreshold = dynamicsBinding(\.expander.thresholdDB)
        let expanderRatio = dynamicsBinding(\.expander.ratio)
        let gateEnabled = dynamicsBinding(\.pauseGate.enabled)
        let gateThreshold = dynamicsBinding(\.pauseGate.thresholdDBFS)
        let gateHold = dynamicsBinding(\.pauseGate.holdMs)
        let gateAttack = dynamicsBinding(\.pauseGate.attackMs)
        let gateRelease = dynamicsBinding(\.pauseGate.releaseMs)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Dynamics validation").font(.headline)
                Spacer()
                Text("PR26 parity foundation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Toggle("Compressor", isOn: compressorEnabled).toggleStyle(.switch)
                Text("Threshold")
                Slider(value: compressorThreshold, in: CompressorConfiguration.thresholdRange, step: 0.5)
                    .frame(width: 150)
                Text("\(engine.dynamicsConfiguration.compressor.thresholdDB, specifier: "%.1f") dB")
                    .monospacedDigit().frame(width: 70)
                Text("Ratio")
                Slider(value: compressorRatio, in: 1...10, step: 0.1).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.compressor.ratio, specifier: "%.1f"):1")
                    .monospacedDigit().frame(width: 52)
            }
            HStack(spacing: 12) {
                Text("Comp timing").frame(width: 90, alignment: .leading)
                Text("Attack")
                Slider(value: compressorAttack, in: 0.05...200, step: 0.5).frame(width: 140)
                Text("\(engine.dynamicsConfiguration.compressor.attackMs, specifier: "%.1f") ms")
                    .monospacedDigit().frame(width: 66)
                Text("Release")
                Slider(value: compressorRelease, in: 10...1_000, step: 5).frame(width: 140)
                Text("\(engine.dynamicsConfiguration.compressor.releaseMs, specifier: "%.0f") ms")
                    .monospacedDigit().frame(width: 66)
            }

            HStack(spacing: 12) {
                Toggle("Expander", isOn: expanderEnabled).toggleStyle(.switch)
                Text("Threshold")
                Slider(value: expanderThreshold, in: -80...0, step: 0.5).frame(width: 150)
                Text("\(engine.dynamicsConfiguration.expander.thresholdDB, specifier: "%.1f") dB")
                    .monospacedDigit().frame(width: 70)
                Text("Ratio")
                Slider(value: expanderRatio, in: 1...6, step: 0.1).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.expander.ratio, specifier: "%.1f"):1")
                    .monospacedDigit().frame(width: 52)
            }

            HStack(spacing: 12) {
                Toggle("Pause Gate", isOn: gateEnabled).toggleStyle(.switch)
                Text("Threshold")
                Slider(value: gateThreshold, in: PauseGateConfiguration.thresholdRange, step: 1).frame(width: 130)
                Text("\(engine.dynamicsConfiguration.pauseGate.thresholdDBFS, specifier: "%.0f") dBFS")
                    .monospacedDigit().frame(width: 70)
                Text("Hold")
                Slider(value: gateHold, in: PauseGateConfiguration.holdRange, step: 50).frame(width: 120)
                Text("\(engine.dynamicsConfiguration.pauseGate.holdMs, specifier: "%.0f") ms")
                    .monospacedDigit().frame(width: 66)
            }
            HStack(spacing: 12) {
                Text("Gate fades").frame(width: 90, alignment: .leading)
                Text("Attack / fade-out")
                Slider(value: gateAttack, in: PauseGateConfiguration.attackRange, step: 1).frame(width: 120)
                Text("\(engine.dynamicsConfiguration.pauseGate.attackMs, specifier: "%.0f") ms")
                    .monospacedDigit().frame(width: 60)
                Text("Release / fade-in")
                Slider(value: gateRelease, in: PauseGateConfiguration.releaseRange, step: 5).frame(width: 120)
                Text("\(engine.dynamicsConfiguration.pauseGate.releaseMs, specifier: "%.0f") ms")
                    .monospacedDigit().frame(width: 60)
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                HStack(spacing: 18) {
                    Text("Comp GR: \(diagnostics?.compressorGainReductionDB ?? 0, specifier: "%.2f") dB")
                    Text("Exp attenuation: \(diagnostics?.expanderAttenuationDB ?? 0, specifier: "%.2f") dB")
                    Text("Gate: \((diagnostics?.pauseGateOpen ?? true) ? "open" : "closed")")
                    Text("Gate gain: \(diagnostics?.pauseGateGain ?? 1, specifier: "%.3f")")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text("Compressor and Expander are linked-stereo. Pause Gate uses Attack for fade-out and Release for fade-in. This is validation UI; the full legacy Dynamics surface remains tracked in docs/DYNAMICS_PARITY_INVENTORY.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

'''
replace(path, marker, view + marker)
