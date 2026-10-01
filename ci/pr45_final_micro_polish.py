from pathlib import Path

root_path = Path('NotchSixty/UI/ProductionRootView.swift')
root = root_path.read_text()
old_toolbar = '''    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ProductionProfileToolbar(profiles: product.profiles, engine: engine)

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.glass)
            .help("Open Notch Sixty Settings")

            if let output = engine.selectedOutputDevice {
                HStack(spacing: 5) {
                    Image(systemName: "hifispeaker")
                    Text("\\(output.name) · \\(output.nominalSampleRate / 1_000, specifier: \"%.1f\") kHz")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Output \\(output.name), \\(output.nominalSampleRate / 1_000, specifier: \"%.1f\") kilohertz")
            }
            #if DEBUG
            Button {
                openWindow(id: "engineering-validation")
            } label: {
                Label("Engineering Validation", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.glass)
            .help("Open the retained engineering validation tools")
            #endif

            Button {
                Task { @MainActor in
                    await Task.yield()
                    if engine.lifecycleState == .running { engine.stop() }
                    else if engine.lifecycleState == .idle { try? engine.start() }
                }
            } label: {
                Label(
                    engine.lifecycleState == .running ? "Stop Processing" : "Start Processing",
                    systemImage: engine.lifecycleState == .running ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.glassProminent)
            .disabled(engine.lifecycleState != .idle && engine.lifecycleState != .running)
        }
    }
'''
new_toolbar = '''    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            ProductionProfileToolbar(profiles: product.profiles, engine: engine)

            if let output = engine.selectedOutputDevice {
                HStack(spacing: 5) {
                    Image(systemName: "hifispeaker")
                    Text("\\(output.name) · \\(output.nominalSampleRate / 1_000, specifier: \"%.1f\") kHz")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Output \\(output.name), \\(output.nominalSampleRate / 1_000, specifier: \"%.1f\") kilohertz")
            }
            #if DEBUG
            Button {
                openWindow(id: "engineering-validation")
            } label: {
                Label("Engineering Validation", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.glass)
            .help("Open the retained engineering validation tools")
            #endif

            Button {
                Task { @MainActor in
                    await Task.yield()
                    if engine.lifecycleState == .running { engine.stop() }
                    else if engine.lifecycleState == .idle { try? engine.start() }
                }
            } label: {
                Label(
                    engine.lifecycleState == .running ? "Stop Processing" : "Start Processing",
                    systemImage: engine.lifecycleState == .running ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.glassProminent)
            .disabled(engine.lifecycleState != .idle && engine.lifecycleState != .running)
        }

        ToolbarSpacer(.flexible)

        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.glass)
            .help("Open Notch Sixty Settings")
        }
    }
'''
if old_toolbar not in root:
    raise SystemExit('ProductionRootView toolbar block not found')
root_path.write_text(root.replace(old_toolbar, new_toolbar, 1))

dynamics_path = Path('NotchSixty/UI/ProductionDynamicsView.swift')
dynamics = dynamics_path.read_text()
old_clip = '''        .scrollIndicators(.visible)
        .background(.clear)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .containerShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
'''
new_clip = '''        .scrollIndicators(.visible)
        .background(.clear)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
'''
if old_clip not in dynamics:
    raise SystemExit('Dynamics rounded clipping block not found')
dynamics_path.write_text(dynamics.replace(old_clip, new_clip, 1))

print('Applied final toolbar/scrollbar micro-polish')
