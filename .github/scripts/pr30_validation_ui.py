from pathlib import Path

path = Path('NotchSixty/NotchSixtyApp.swift')
text = path.read_text()

if 'private struct PR30PhaseTimeValidationView' not in text:
    marker = '@main\nstruct NotchSixtyApp: App {'
    if marker not in text:
        raise SystemExit('Unable to find NotchSixtyApp marker')

    view = r'''
private struct PR30PhaseTimeValidationView: View {
    @ObservedObject var engine: AudioIOEngine

    private var delayBinding: Binding<Double> {
        Binding(
            get: { engine.playbackControlConfiguration.interChannelDelayMs },
            set: { try? engine.setInterChannelDelayMs($0) }
        )
    }

    private var phaseModeBinding: Binding<EQPhaseMode> {
        Binding(
            get: { engine.stereoEQConfiguration.phaseMode },
            set: { try? engine.setEQPhaseMode($0) }
        )
    }

    private var allPassBands: [EQBand] {
        engine.stereoEQConfiguration.editableBands.filter { $0.type == .allPass }
    }

    private func bandDoubleBinding(_ source: EQBand, _ keyPath: WritableKeyPath<EQBand, Double>) -> Binding<Double> {
        Binding(
            get: {
                engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id })?[keyPath: keyPath]
                    ?? source[keyPath: keyPath]
            },
            set: { value in
                guard var updated = engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id }) else { return }
                updated[keyPath: keyPath] = value
                try? engine.updateEQBand(updated)
            }
        )
    }

    private func bandEnabledBinding(_ source: EQBand) -> Binding<Bool> {
        Binding(
            get: {
                engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id })?.enabled ?? source.enabled
            },
            set: { value in
                guard var updated = engine.stereoEQConfiguration.editableBands.first(where: { $0.id == source.id }) else { return }
                updated.enabled = value
                try? engine.updateEQBand(updated)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PR30 Phase / Time Alignment Validation")
                    .font(.title2.bold())

                Text("Focused hardware validation for the new phase-only All-Pass EQ and signed fractional inter-channel timing alignment.")
                    .foregroundStyle(.secondary)

                GroupBox("All-Pass EQ") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("EQ Phase Mode", selection: phaseModeBinding) {
                            ForEach(EQPhaseMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        HStack {
                            Button("Add All-Pass Test Band") {
                                try? engine.setEQPhaseMode(.minimumPhase)
                                try? engine.addEQBand(
                                    EQBand(type: .allPass, frequencyHz: 1_000, gainDB: 0, q: 0.707)
                                )
                            }
                            Button("Remove All-Pass Bands") {
                                let ids = allPassBands.map(\.id)
                                for id in ids { try? engine.removeEQBand(id: id) }
                            }
                            .disabled(allPassBands.isEmpty)
                        }

                        Text("All-Pass is intentionally available only in Minimum phase/IIR mode. It rotates phase/group delay while preserving steady-state magnitude.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if allPassBands.isEmpty {
                            Text("No All-Pass bands yet. Add one above for the PR30 listening test.")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(allPassBands) { band in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Toggle("Enabled", isOn: bandEnabledBinding(band))
                                        .toggleStyle(.switch)
                                    Spacer()
                                    Button("Remove") { try? engine.removeEQBand(id: band.id) }
                                }

                                HStack(spacing: 12) {
                                    Text("Frequency").frame(width: 90, alignment: .leading)
                                    Slider(value: bandDoubleBinding(band, \.frequencyHz), in: 20...20_000, step: 10)
                                    Text("\(engine.stereoEQConfiguration.editableBands.first(where: { $0.id == band.id })?.frequencyHz ?? band.frequencyHz, specifier: \"%.0f\") Hz")
                                        .monospacedDigit().frame(width: 92)
                                }

                                HStack(spacing: 12) {
                                    Text("Q").frame(width: 90, alignment: .leading)
                                    Slider(value: bandDoubleBinding(band, \.q), in: 0.10...20.0, step: 0.01)
                                    Text("\(engine.stereoEQConfiguration.editableBands.first(where: { $0.id == band.id })?.q ?? band.q, specifier: \"%.2f\")")
                                        .monospacedDigit().frame(width: 72)
                                }
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    .padding(6)
                }

                GroupBox("Fractional Inter-Channel Delay") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text("Delay L").foregroundStyle(.secondary)
                            Slider(
                                value: delayBinding,
                                in: PlaybackControlConfiguration.interChannelDelayRange,
                                step: 0.01
                            )
                            Text("Delay R").foregroundStyle(.secondary)
                            Text("\(engine.playbackControlConfiguration.interChannelDelayMs, specifier: \"%+.2f\") ms")
                                .monospacedDigit().frame(width: 84, alignment: .trailing)
                        }

                        HStack {
                            Button("Reset to 0.00 ms") { try? engine.setInterChannelDelayMs(0) }
                            Text("Negative values delay Left; positive values delay Right. Zero is transparent.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("The fractional stage uses phase-preserving all-pass interpolation with a tiny common alignment delay when active, rather than amplitude-interpolating between adjacent samples.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Realtime Alignment Telemetry") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                            GridRow {
                                Text("Published L/R delay").foregroundStyle(.secondary)
                                Text("\(diagnostics?.interChannelDelayMs ?? 0, specifier: \"%+.3f\") ms")
                            }
                            GridRow {
                                Text("Alignment latency").foregroundStyle(.secondary)
                                Text("\(diagnostics?.interChannelAlignmentLatencyFrames ?? 0) frames")
                            }
                            GridRow {
                                Text("Total DSP latency").foregroundStyle(.secondary)
                                Text("\(diagnostics?.latencyFrames ?? 0) frames")
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    }
                    .padding(6)
                }

                Text("Acceptance focus: All-Pass should alter phase/spatial behavior without an obvious level or tonal shift; ± delay should move the appropriate channel; 0.00 ms should return to transparent behavior; changes should remain click-free. Also verify Processed / Reference / Delta and Global Bypass after exercising both stages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
    }
}

'''
    text = text.replace(marker, view + marker, 1)

old_tabs = '''                PR28AdvancedDynamicsValidationView(engine: product.audioEngine)\n                    .tabItem { Label("PR28 Advanced Dynamics", systemImage: "waveform.badge.plus") }'''
new_tabs = old_tabs + '''\n\n                PR30PhaseTimeValidationView(engine: product.audioEngine)\n                    .tabItem { Label("PR30 Phase / Time", systemImage: "timeline.selection") }'''
if 'Label("PR30 Phase / Time"' not in text:
    if old_tabs not in text:
        raise SystemExit('Unable to find PR28 tab marker')
    text = text.replace(old_tabs, new_tabs, 1)

path.write_text(text)
