import SwiftUI

// E12 S16: the Speakers page, moved out of ProductionRootView.swift. With `e12.system-pages` on it names one owner of
// bass and routing, hosts the arrangement editor and shows only that owner's cards; with it off the page is as before.

struct ProductionSpeakersView: View {
    var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    @State private var actionError: String?

    private var routing: MultiOutputRoutingConfiguration {
        profiles.selectedSystemOutputRouting
    }

    private var physicalRoutingLocked: Bool {
        engine.lifecycleState != .idle
    }

    /// E12 S16: the flag decides the layout (Swift only; the engine never reads it).
    private var systemPages: Bool { FeatureFlags().isEnabled(.systemPages) }

    private var page: SpeakersPageModel {
        SpeakersPageModel.make(
            matrixEnabled: engine.speakerRoutingConfiguration?.enabled == true,
            bass: engine.bassManagementConfiguration,
            legacyRoutingReason: profiles.selectedSystemProfile?.state.unmigratedLegacyRoutingReason,
            carry: profiles.selectedSystemProfile.map {
                SpeakersBassMigration.outcome(for: $0.state, detectedChannelCount: detectedChannelCount)
            } ?? .nothingToCarry)
    }

    private var detectedChannelCount: Int { Int(engine.selectedOutputDevice?.outputChannelCount ?? 0) }

    /// S16b: carries what the retired Crossover Design and Sub Phase Alignment cards stored to the arrangement.
    private func carryOlderBassSettings() {
        do { try SpeakersBassMigration.carry(profiles: profiles, detectedChannelCount: detectedChannelCount) }
        catch { actionError = error.localizedDescription }
    }

    @ViewBuilder
    var body: some View {
        if systemPages { ownedBody } else { legacyBody }
    }

    /// E12 S16 (G16, G17): one owner of bass and routing, the arrangement editor, and only the owner's cards.
    private var ownedBody: some View {
        let page = page
        return ProductionPageContainer {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your speakers, how they are connected, and who handles bass.")
                    .foregroundStyle(.secondary)
                Label(page.ownerLine, systemImage: page.owner == .routingMatrix ? "square.grid.3x3" : "hifispeaker.2")
                    .font(DesignType.label.font)
                    .padding(DesignSpacing.m.pt)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt))
                    .accessibilityIdentifier("speakers-owner-line")
                SpeakersArrangementEditorCard(engine: engine, profiles: profiles)
                playbackSystemCard
                if page.owner == .routingMatrix {
                    ProductionRoutingEditorView(engine: engine)
                    if let note = page.legacyBassNote {
                        Label(note, systemImage: "info.circle")
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProductionProfileSubwooferCard(engine: engine, profiles: profiles)
                    if engine.bassManagementConfiguration.enabled { subLevelCard }
                    if let summary = page.legacyBassSummary {
                        Label(summary, systemImage: "info.circle")
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("speakers-legacy-bass-summary")
                    }
                    DisclosureGroup("Routing matrix (per-driver control)") {
                        ProductionRoutingEditorView(engine: engine).padding(.top, 10)
                    }
                    legacyRoutingSummary
                    verificationCard
                }
                ProductionProgramSourceCard(engine: engine, profiles: profiles)
                errorLabel
            }
        }
        .task { carryOlderBassSettings() }
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let error = actionError ?? profiles.lastErrorDescription {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var legacyBody: some View {
        ProductionPageContainer {
            VStack(alignment: .leading, spacing: 20) {
                Text("Speaker topology, bass management, crossover design, physical routing, and driver-level processing.")
                    .foregroundStyle(.secondary)

                SystemCapabilityNoteCard(
                    title: "What your speaker arrangement allows", features: SystemCapabilityText.speakersTabFeatures,
                    profiles: profiles, deviceChannelCount: Int(engine.selectedOutputDevice?.outputChannelCount ?? 0))
                SystemCapabilityNoteCard(
                    title: "Routing", features: SystemCapabilityText.routingEditorFeatures,
                    profiles: profiles, deviceChannelCount: Int(engine.selectedOutputDevice?.outputChannelCount ?? 0))
                ProductionRoutingEditorView(engine: engine)
                ProductionProfileSubwooferCard(engine: engine, profiles: profiles)
                ProductionProgramSourceCard(engine: engine, profiles: profiles)
                playbackSystemCard
                SystemCapabilityNoteCard(
                    title: "Saved with this profile", features: SystemCapabilityText.profileFeatures,
                    profiles: profiles, deviceChannelCount: Int(engine.selectedOutputDevice?.outputChannelCount ?? 0),
                    includeArrangement: true)
                crossoverCard
                if engine.bassManagementConfiguration.physicalOutputMode == .mainsSub {
                    subAlignmentCard
                }
                legacyRoutingSummary
                verificationCard

                if let error = actionError ?? profiles.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var playbackSystemCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System").font(.caption).foregroundStyle(.secondary)
                    Text(profiles.selectedSystemProfileName).font(.headline)
                }
                Spacer()
                if routing.enabled {
                    Label(
                        "\(routing.enabledRoutes.count) routes · \(routing.requiredDeviceUIDs.count) devices",
                        systemImage: routing.usesMultiplePhysicalDevices ? "square.stack.3d.up" : "rectangle.stack"
                    )
                    .font(.caption.bold())
                }
            }
            Text("Speaker topology, crossover, and physical-output routing are stored with this System profile. Playback EQ, dynamics, preamp, and headroom remain independent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var crossoverCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Crossover Design").font(.headline)
                    Text("Logical stereo bass management. Physical speaker layouts, crossovers and driver processing are set up in the routing editor above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Crossover Design", isOn: Binding(
                    get: { engine.bassManagementConfiguration.enabled },
                    set: { value in updateCrossover { $0.enabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            LabeledContent("Crossover Frequency") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.frequencyHz },
                        set: { value in updateCrossover { $0.frequencyHz = value } }
                    ), in: lowerFrequencyRange, step: 1)
                    .designSlider("Crossover frequency", value: engine.bassManagementConfiguration.frequencyHz, unit: .hz)
                    .frame(width: 330)
                    Text("\(engine.bassManagementConfiguration.frequencyHz, specifier: "%.0f") Hz")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }
            .disabled(physicalRoutingLocked && routing.enabled)

            LabeledContent("Topology") {
                Picker("Topology", selection: Binding(
                    get: { engine.bassManagementConfiguration.topology },
                    set: { value in updateCrossover { $0.topology = value } }
                )) {
                    ForEach(CrossoverTopology.allCases) { topology in
                        Text(topology.displayName).tag(topology)
                    }
                }
                .labelsHidden()
                .frame(width: 280)
            }
            .disabled(physicalRoutingLocked && routing.enabled)

            if engine.bassManagementConfiguration.physicalOutputMode == .mainsSub
                || engine.bassManagementConfiguration.physicalOutputMode == nil {
                LabeledContent("Sub Gain") {
                    HStack(spacing: 12) {
                        Slider(value: Binding(
                            get: { engine.bassManagementConfiguration.subGainDB },
                            set: { value in updateCrossover { $0.subGainDB = value } }
                        ), in: BassManagementConfiguration.subGainRange, step: 0.5)
                        .designSlider("Subwoofer gain", value: engine.bassManagementConfiguration.subGainDB, unit: .db)
                        .frame(width: 260)
                        Text("\(engine.bassManagementConfiguration.subGainDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 68, alignment: .trailing)
                    }
                }

                Toggle("Invert Sub Polarity", isOn: Binding(
                    get: { engine.bassManagementConfiguration.subPolarityInverted },
                    set: { value in updateCrossover { $0.subPolarityInverted = value } }
                ))
                .toggleStyle(.switch)
            }

            if physicalRoutingLocked && routing.enabled {
                Label("Stop processing before changing physical crossover topology or route assignments.", systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var subAlignmentCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sub Phase Alignment").font(.headline)
                    Text("All-pass alignment on the physical Sub Mono bus. Use measurement evidence when available rather than tuning blindly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Sub Phase Alignment", isOn: Binding(
                    get: { engine.bassManagementConfiguration.subPhaseAlignmentEnabled },
                    set: { value in updateCrossover { $0.subPhaseAlignmentEnabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            LabeledContent("Alignment Frequency") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.subPhaseAlignmentFrequencyHz },
                        set: { value in updateCrossover { $0.subPhaseAlignmentFrequencyHz = value } }
                    ), in: BassManagementConfiguration.frequencyRange, step: 1)
                    .designSlider("Alignment frequency", value: engine.bassManagementConfiguration.subPhaseAlignmentFrequencyHz, unit: .hz)
                    .frame(width: 260)
                    Text("\(engine.bassManagementConfiguration.subPhaseAlignmentFrequencyHz, specifier: "%.0f") Hz")
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
            }
            .disabled(!engine.bassManagementConfiguration.subPhaseAlignmentEnabled)

            LabeledContent("Alignment Q") {
                HStack {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.subPhaseAlignmentQ },
                        set: { value in updateCrossover { $0.subPhaseAlignmentQ = value } }
                    ), in: BassManagementConfiguration.subPhaseAlignmentQRange, step: 0.05)
                    .designSlider("Alignment Q", value: engine.bassManagementConfiguration.subPhaseAlignmentQ, unit: .number)
                    .frame(width: 260)
                    Text("\(engine.bassManagementConfiguration.subPhaseAlignmentQ, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
            }
            .disabled(!engine.bassManagementConfiguration.subPhaseAlignmentEnabled)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    /// E12 S16b: the sub level and polarity the retired Crossover Design card carried. Frequency and slope are in the
    /// arrangement editor above; the sub phase all-pass is a matrix setting.
    private var subLevelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subwoofer level and polarity").font(.headline)
            LabeledContent("Sub Gain") {
                HStack(spacing: 12) {
                    Slider(value: Binding(
                        get: { engine.bassManagementConfiguration.subGainDB },
                        set: { value in updateCrossover { $0.subGainDB = value } }
                    ), in: BassManagementConfiguration.subGainRange, step: 0.5)
                    .designSlider("Subwoofer gain", value: engine.bassManagementConfiguration.subGainDB, unit: .db)
                    .frame(minWidth: 160, maxWidth: 260)
                    Text("\(engine.bassManagementConfiguration.subGainDB, specifier: "%.1f") dB")
                        .monospacedDigit()
                        .frame(width: 68, alignment: .trailing)
                }
            }
            Toggle("Invert Sub Polarity", isOn: Binding(
                get: { engine.bassManagementConfiguration.subPolarityInverted },
                set: { value in updateCrossover { $0.subPolarityInverted = value } }
            ))
            .toggleStyle(.switch)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var verificationCard: some View {
        DisclosureGroup("Verification Monitor") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Monitor Path", selection: Binding(
                    get: { engine.bassManagementConfiguration.monitorMode },
                    set: { value in updateCrossover { $0.monitorMode = value } }
                )) {
                    ForEach(CrossoverMonitorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("The verification monitor affects the ordinary logical stereo crossover preview. Physical split routes are generated independently after the shared stereo DSP chain and are protected by their mandatory crossover even when raw Global Bypass is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
    }

    private var lowerFrequencyRange: ClosedRange<Double> {
        engine.bassManagementConfiguration.lowerFrequencyRange
    }

    @ViewBuilder
    private var legacyRoutingSummary: some View {
        if let reason = profiles.selectedSystemProfile?.state.unmigratedLegacyRoutingReason {
            VStack(alignment: .leading, spacing: 10) {
                Text("Legacy routing").font(.headline)
                Text("This profile uses a legacy physical crossover that the routing editor cannot represent: \(reason) It stays as stored and blocks multichannel playback until it is turned off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Turn off legacy routing") { turnOffLegacyRouting() }
                    .buttonStyle(.glass)
                    .disabled(physicalRoutingLocked)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
        }
    }

    private func turnOffLegacyRouting() {
        updateRouting { $0.enabled = false }
    }

    private func updateRouting(_ mutation: (inout MultiOutputRoutingConfiguration) -> Void) {
        actionError = nil
        var updated = routing
        mutation(&updated)
        do {
            try profiles.replaceSelectedSystemOutputRouting(updated)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func updateCrossover(_ mutation: (inout BassManagementConfiguration) -> Void) {
        actionError = nil
        var updated = engine.bassManagementConfiguration
        mutation(&updated)
        do {
            try profiles.replaceSelectedSystemBassManagement(updated)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

