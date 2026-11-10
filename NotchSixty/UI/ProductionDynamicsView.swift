import Foundation
import SwiftUI

struct ProductionDynamicsView: View {
    @ObservedObject var engine: AudioIOEngine
    var reference: ProductionReferenceNavigator? = nil
    @State private var selectedModule: ProductionDynamicsModule = .compressor
    @State private var expandedMoreGroups: Set<String> = []
    @State private var mainsDetectInFlight = false
    @State private var mainsDetectionMessage: String?
    @State private var actionError: String?
    @Environment(\.undoManager) private var undoManager
    @State private var history = EditHistory<DynamicsConfiguration>()

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var configuration: DynamicsConfiguration { engine.dynamicsConfiguration }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ProductionActionErrorBanner(message: $actionError)

            HStack(alignment: .top, spacing: 12) {
                moduleNavigator
                    .frame(minWidth: 250, idealWidth: 285, maxWidth: 330)

                ScrollView {
                    moduleEditor
                        .padding(.horizontal, 4)
                }
                .frame(minWidth: 560)
            }
        }
        .padding(24)
        .onAppear { configureHistory() }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { _, _ in configureHistory() }
        .onChange(of: engine.dynamicsConfiguration) { _, _ in history.observeLiveChange() }
        .onDisappear { history.clear() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Level control, restoration, protection, and program-aware processing. Select a processor to expose its complete configuration.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(activeModuleCount) ACTIVE")
                .font(.caption.bold())
                .tracking(1.1)
                .foregroundStyle(.secondary)
        }
    }

    private var moduleNavigator: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(ProductionDynamicsLayout.groups) { group in
                    Text(group.title.uppercased())
                        .font(.caption2.bold())
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, group.note == nil ? 2 : 0)

                    if let note = group.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)
                    }

                    ForEach(moreIsExpanded(group) ? group.modules : group.shown) { module in
                        moduleRow(module)
                    }

                    if !group.more.isEmpty {
                        moreRow(for: group)
                    }
                }
            }
            .padding(8)
        }
        .scrollIndicators(.visible)
        .background(.clear)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// "More" stays open while one of its processors is selected, so the
    /// selection never disappears from the list.
    private func moreIsExpanded(_ group: ProductionDynamicsLayout.Group) -> Bool {
        expandedMoreGroups.contains(group.id) || group.more.contains(selectedModule)
    }

    private func moreRow(for group: ProductionDynamicsLayout.Group) -> some View {
        let expanded = moreIsExpanded(group)
        return Button {
            if expanded {
                expandedMoreGroups.remove(group.id)
            } else {
                expandedMoreGroups.insert(group.id)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(expanded ? "Fewer" : "More (\(group.more.count))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !expanded, group.moreHasActiveModule(isActive: moduleIsActive) {
                    Text("ON")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                        .accessibilityLabel("A processor under More is on")
                }
            }
            .contentShape(.rect)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func moduleRow(_ module: ProductionDynamicsModule) -> some View {
        Button {
            selectedModule = module
        } label: {
            HStack(spacing: 9) {
                Image(systemName: module.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(selectedModule == module ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title)
                        .foregroundStyle(.primary)
                    Text(module.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Circle()
                    .fill(moduleIsActive(module) ? Color.green : Color.secondary.opacity(0.28))
                    .frame(width: 7, height: 7)
            }
            .contentShape(.rect)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                if selectedModule == module {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(0.09))
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var moduleEditor: some View {
        switch selectedModule {
        case .compressor: compressorEditor
        case .multiband: multibandEditor
        case .expander: expanderEditor
        case .pauseGate: pauseGateEditor
        case .gainRider: gainRiderEditor
        case .denoiser: denoiserEditor
        case .deEsser: deEsserEditor
        case .mainsHum: mainsHumEditor
        case .infrasonic: infrasonicEditor
        case .loudnessMatch: loudnessMatchEditor
        case .loudnessContour: loudnessContourEditor
        case .dialogueLeveler: dialogueLevelerEditor
        case .limiter: limiterEditor
        case .softClipper: softClipperEditor
        case .automaticHeadroom: automaticHeadroomEditor
        case .oversampling: oversamplingEditor
        case .deHarsh: deHarshEditor
        case .stereoWidener: stereoWidenerEditor
        case .stereoMode: stereoModeEditor
        case .dcOffset: dcOffsetEditor
        }
    }

    // MARK: - Dynamics

    private var compressorEditor: some View {
        moduleCard(
            module: .compressor,
            enabled: boolBinding({ $0.compressor.enabled }, { $0.compressor.enabled = $1 }),
            reset: { preserveEnabledReset(\.compressor, defaultValue: CompressorConfiguration()) }
        ) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .compressor)
            row(.compressorThresholdDB)
            row(.compressorRatio)
            row(.compressorKneeWidthDB)
            row(.compressorAttackMs)
            row(.compressorReleaseMs)
            row(.compressorMakeupGainDB, enabled: configuration.compressor.autoMakeupGain != true)
            Toggle("Auto Makeup", isOn: binding(
                { $0.compressor.autoMakeupGain == true },
                { $0.compressor.autoMakeupGain = $1 }
            ))
            .help(Self.autoMakeupHelp)
            .accessibilityIdentifier("dynamics.compressor.autoMakeup")

            Divider()
            HStack(spacing: 12) {
                Text("Topology")
                Picker("Topology", selection: binding({ $0.compressor.topology }, { $0.compressor.topology = $1 })) {
                    ForEach(CompressorTopology.allCases) { topology in
                        Text(topology.displayName).tag(topology)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Toggle("Program-Dependent Release", isOn: boolBinding({ $0.compressor.programDependentRelease }, { $0.compressor.programDependentRelease = $1 }))
                .help("Release starts at half the set time for light gain reduction and lengthens to twice the set time as the reduction deepens toward 12 dB, so brief peaks recover quickly and sustained material does not pump.")
            row(.compressorSidechainHighPassHz)
                .help("0 Hz disables the sidechain high-pass filter.")
        }
    }

    private var multibandEditor: some View {
        moduleCard(
            module: .multiband,
            enabled: boolBinding({ $0.multibandCompressor.enabled }, { $0.multibandCompressor.enabled = $1 }),
            reset: { preserveEnabledReset(\.multibandCompressor, defaultValue: MultibandCompressorConfiguration()) }
        ) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .multiband)
            GroupBox("Crossovers") {
                VStack(spacing: 10) {
                    row(.multibandCompressorLowMidFrequencyHz)
                    Picker("Low / Mid Slope", selection: binding({ $0.multibandCompressor.lowMidSlope }, { $0.multibandCompressor.lowMidSlope = $1 })) {
                        ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                    }
                    row(.multibandCompressorMidHighFrequencyHz)
                    Picker("Mid / High Slope", selection: binding({ $0.multibandCompressor.midHighSlope }, { $0.multibandCompressor.midHighSlope = $1 })) {
                        ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                    }
                }
                .padding(.vertical, 6)
            }

            multibandBandEditor(band: 0, title: "Low Band")
            multibandBandEditor(band: 1, title: "Mid Band")
            multibandBandEditor(band: 2, title: "High Band")
        }
    }

    private var expanderEditor: some View {
        moduleCard(module: .expander, enabled: boolBinding({ $0.expander.enabled }, { $0.expander.enabled = $1 }), reset: { preserveEnabledReset(\.expander, defaultValue: ExpanderConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .expander)
            row(.expanderThresholdDB)
            row(.expanderRatio)
            row(.expanderRangeDB)
            row(.expanderAttackMs)
            row(.expanderReleaseMs)
        }
    }

    private var pauseGateEditor: some View {
        moduleCard(module: .pauseGate, enabled: boolBinding({ $0.pauseGate.enabled }, { $0.pauseGate.enabled = $1 }), reset: { preserveEnabledReset(\.pauseGate, defaultValue: PauseGateConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .pauseGate)
            Picker("Preset", selection: binding({ $0.pauseGate.preset }, { config, value in config.pauseGate.applyPreset(value) })) {
                ForEach(PauseGatePreset.allCases) { preset in Text(preset.displayName).tag(preset) }
            }
            .pickerStyle(.menu)

            row(.pauseGateThresholdDBFS)
            row(.pauseGateHoldMs)
            row(.pauseGateAttackMs)
                .help("Attack is the fade-out / gate-close time.")
            row(.pauseGateReleaseMs)
                .help("Release is the fade-in / gate-open time.")
            row(.pauseGateHysteresisDB)

            Label("Product convention: Attack = fade-out, Release = fade-in.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var gainRiderEditor: some View {
        moduleCard(module: .gainRider, enabled: boolBinding({ $0.gainRider.enabled }, { $0.gainRider.enabled = $1 }), reset: { preserveEnabledReset(\.gainRider, defaultValue: GainRiderConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .gainRider)
            row(.gainRiderTargetGainReductionDB)
            row(.gainRiderMaxReductionDB)
            Picker("Response", selection: binding({ $0.gainRider.speed }, { $0.gainRider.speed = $1 })) {
                ForEach(GainRiderSpeed.allCases) { speed in Text(speed.displayName).tag(speed) }
            }
            .pickerStyle(.segmented)
            Text("The live readout above is derived from existing Gain Rider runtime state and does not activate unrelated metering or analysis.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Restoration

    private var denoiserEditor: some View {
        moduleCard(module: .denoiser, enabled: boolBinding({ $0.spectralDenoiser.enabled }, { $0.spectralDenoiser.enabled = $1 }), reset: resetDenoiser) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .denoiser)
            Picker("Preset", selection: Binding(
                get: { configuration.spectralDenoiser.preset },
                set: { preset in perform { try engine.applySpectralDenoiserPreset(preset) } }
            )) {
                ForEach(SpectralDenoiserPreset.allCases) { preset in Text(preset.displayName).tag(preset) }
            }
            .pickerStyle(.menu)

            Picker("Quality", selection: denoiserBinding({ $0.quality }, { $0.quality = $1; $0.markCustom() })) {
                ForEach(SpectralDenoiserQuality.allCases) { quality in Text(quality.displayName).tag(quality) }
            }
            .pickerStyle(.segmented)

            row(.spectralDenoiserThresholdDBFS)
            row(.spectralDenoiserReductionAmount)

            Toggle("Protect Frequency Range", isOn: denoiserBinding({ $0.protectedRangeEnabled }, { $0.protectedRangeEnabled = $1; $0.markCustom() }))
            if configuration.spectralDenoiser.protectedRangeEnabled {
                row(.spectralDenoiserProtectedLowHz)
                row(.spectralDenoiserProtectedHighHz)
            }

            DisclosureGroup("Advanced Suppression") {
                VStack(spacing: 10) {
                    Toggle("Override Preset Smoothing", isOn: denoiserBinding({ $0.advancedTuningEnabled }, { $0.advancedTuningEnabled = $1; $0.markCustom() }))
                    row(.spectralDenoiserMinimumGain)
                        .disabled(!configuration.spectralDenoiser.advancedTuningEnabled)
                    row(.spectralDenoiserAttackMs)
                        .disabled(!configuration.spectralDenoiser.advancedTuningEnabled)
                    row(.spectralDenoiserReleaseMs)
                        .disabled(!configuration.spectralDenoiser.advancedTuningEnabled)
                    Text("Named presets retain their accepted internal suppression behavior. These values take effect only when the explicit override is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            Divider()
            HStack {
                Button("Capture Noise Profile") { perform { try engine.captureSpectralNoiseProfile() } }
                    .buttonStyle(.glassProminent)
                Button("Reset Profile") { perform { try engine.resetSpectralNoiseProfile() } }
                    .buttonStyle(.glass)
                Spacer()
            }
        }
    }

    private var deEsserEditor: some View {
        moduleCard(module: .deEsser, enabled: boolBinding({ $0.deEsser.enabled }, { $0.deEsser.enabled = $1 }), reset: { preserveEnabledReset(\.deEsser, defaultValue: DeEsserConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .deEsser)
            row(.deEsserFrequencyHz)
            row(.deEsserDetectionQ)
            row(.deEsserThresholdDB)
            row(.deEsserRatio)
            row(.deEsserRangeDB)
            row(.deEsserAttackMs)
            row(.deEsserReleaseMs)
            DisclosureGroup("Advanced") {
                Toggle("Dynamic-EQ Processing Mode", isOn: boolBinding({ $0.deEsser.dynamicEQMode }, { $0.deEsser.dynamicEQMode = $1 }))
                    .padding(.top, 8)
            }
        }
    }

    private var mainsHumEditor: some View {
        moduleCard(module: .mainsHum, enabled: boolBinding({ $0.mainsNotch.enabled }, { $0.mainsNotch.enabled = $1 }), reset: resetMainsHum) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .mainsHum)
            Picker("Mains Region", selection: binding({ $0.mainsNotch.region }, { config, region in config.mainsNotch.selectRegion(region) })) {
                ForEach(MainsRegion.allCases) { region in Text(region.displayName).tag(region) }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle("Continuous Tracking", isOn: boolBinding({ $0.mainsNotch.continuousTracking }, { $0.mainsNotch.continuousTracking = $1 }))
                Spacer()
                Button(mainsDetectInFlight ? "Detecting…" : "Detect") {
                    guard !mainsDetectInFlight else { return }
                    mainsDetectInFlight = true
                    mainsDetectionMessage = nil
                    Task { @MainActor in
                        do {
                            let applied = try await engine.detectMainsHumOnce()
                            mainsDetectionMessage = applied ? "Detected frequency applied." : "No stable mains tone detected."
                        } catch {
                            mainsDetectionMessage = error.localizedDescription
                        }
                        mainsDetectInFlight = false
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(mainsDetectInFlight || engine.lifecycleState != .running)
            }
            if let mainsDetectionMessage {
                Text(mainsDetectionMessage).font(.caption).foregroundStyle(.secondary)
            }
            Text("Current fundamental: \(configuration.mainsNotch.fundamentalHz, specifier: "%.2f") Hz")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Stepper("Harmonics: \(configuration.mainsNotch.harmonicCount)", value: binding({ $0.mainsNotch.harmonicCount }, { $0.mainsNotch.harmonicCount = $1 }), in: MainsNotchConfiguration.harmonicCountRange)
            row(.mainsNotchQ)

            DisclosureGroup("Harmonic Depths") {
                VStack(spacing: 8) {
                    ForEach(0..<configuration.mainsNotch.harmonicCount, id: \.self) { index in
                        row(
                            DynamicsParameterSpec.harmonicDepth(index),
                            title: "H\(index + 1) · \(Int(configuration.mainsNotch.fundamentalHz * Double(index + 1))) Hz"
                        )
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var infrasonicEditor: some View {
        moduleCard(module: .infrasonic, enabled: boolBinding({ $0.infrasonicFilter.enabled }, { $0.infrasonicFilter.enabled = $1 }), reset: { preserveEnabledReset(\.infrasonicFilter, defaultValue: InfrasonicFilterConfiguration()) }) {
            row(.infrasonicFilterCutoffHz)
            Picker("Slope", selection: binding({ $0.infrasonicFilter.slope }, { $0.infrasonicFilter.slope = $1 })) {
                ForEach(InfrasonicSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
            }
            .pickerStyle(.segmented)
            Label("Legacy application-target routing is tracked as a parity gap. Main/sub target selection will live with crossover/output routing rather than be duplicated here.", systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Level & Dialogue

    private var loudnessMatchEditor: some View {
        moduleCard(module: .loudnessMatch, enabled: boolBinding({ $0.loudnessMatch.enabled }, { $0.loudnessMatch.enabled = $1 }), reset: { preserveEnabledReset(\.loudnessMatch, defaultValue: LoudnessMatchConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .loudnessMatch)
            row(.loudnessMatchTargetLUFS)
            row(.loudnessMatchMaxCorrectionDB)
            row(.loudnessMatchAttackSeconds)
            row(.loudnessMatchReleaseSeconds)
            Toggle("Dialogue Gate", isOn: boolBinding({ $0.loudnessMatch.dialogueGateEnabled }, { $0.loudnessMatch.dialogueGateEnabled = $1 }))
        }
    }

    private var loudnessContourEditor: some View {
        moduleCard(module: .loudnessContour, enabled: boolBinding({ $0.loudnessContour.enabled }, { $0.loudnessContour.enabled = $1 }), reset: { preserveEnabledReset(\.loudnessContour, defaultValue: LoudnessContourConfiguration()) }) {
            row(.loudnessContourStrength)
            row(.loudnessContourReferencePhons)
            row(.loudnessContourMaxBoostDB)
            row(.loudnessContourMaxCutDB)
            Picker("Level Source", selection: binding({ $0.loudnessContour.levelSource }, { $0.loudnessContour.levelSource = $1 })) {
                ForEach(LoudnessLevelSource.allCases) { source in Text(source.displayName).tag(source) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var dialogueLevelerEditor: some View {
        moduleCard(module: .dialogueLeveler, enabled: boolBinding({ $0.dialogueRelativeLeveler.enabled }, { $0.dialogueRelativeLeveler.enabled = $1 }), reset: { preserveEnabledReset(\.dialogueRelativeLeveler, defaultValue: DialogueRelativeLevelerConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .dialogue)
            row(.dialogueRelativeLevelerBandLowHz)
            row(.dialogueRelativeLevelerBandHighHz)
            row(.dialogueRelativeLevelerTargetGapDB)
            row(.dialogueRelativeLevelerBoostRatio)
            row(.dialogueRelativeLevelerMaxBoostDB)
            row(.dialogueRelativeLevelerAttackMs)
            row(.dialogueRelativeLevelerReleaseMs)
            row(.dialogueRelativeLevelerProgramGateThresholdDB)

            Divider()
            Toggle("Voice Gate", isOn: boolBinding({ $0.dialogueRelativeLeveler.voiceGate.enabled }, { $0.dialogueRelativeLeveler.voiceGate.enabled = $1 }))
            if configuration.dialogueRelativeLeveler.voiceGate.enabled {
                row(.dialogueRelativeLevelerVoiceGateSensitivity)
                row(.dialogueRelativeLevelerVoiceGateMinConfidence)
            }

            DisclosureGroup("Advanced Detection") {
                VStack(spacing: 10) {
                    row(.dialogueRelativeLevelerDetectorWindowMs)
                    row(.dialogueRelativeLevelerVoiceGateModulationCenterHz)
                    row(.dialogueRelativeLevelerVoiceGateModulationBandwidthHz)
                    row(.dialogueRelativeLevelerVoiceGateEnvelopeWindowMs)
                    row(.dialogueRelativeLevelerVoiceGateMeasurementWindowMs)
                    row(.dialogueRelativeLevelerVoiceGateConfidenceFloorIndex)
                    row(.dialogueRelativeLevelerVoiceGateConfidenceCeilingIndex)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Protection

    private var limiterEditor: some View {
        moduleCard(module: .limiter, enabled: boolBinding({ $0.limiter.enabled }, { $0.limiter.enabled = $1 }), reset: { preserveEnabledReset(\.limiter, defaultValue: LimiterConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .limiter)
            row(.limiterCeilingDB)
            row(.limiterAttackMs)
            row(.limiterReleaseMs)
            row(.limiterLookAheadMs)
            Toggle("True-Peak Guard", isOn: boolBinding({ $0.limiter.truePeakGuardEnabled }, { $0.limiter.truePeakGuardEnabled = $1 }))
            // E9 S5b: per-output protection (empty unless `e9.output-protection` is on).
            ProductionOutputProtectionSection(
                engine: engine, settings: configuration.outputProtection ?? OutputProtectionSettings(),
                apply: { next in update { $0.outputProtection = next == OutputProtectionSettings() ? nil : next } },
                programLimiterOn: configuration.limiter.enabled)
        }
    }

    private var softClipperEditor: some View {
        moduleCard(module: .softClipper, enabled: boolBinding({ $0.softClipper.enabled }, { $0.softClipper.enabled = $1 }), reset: { preserveEnabledReset(\.softClipper, defaultValue: SoftClipperConfiguration()) }) {
            row(.softClipperDriveDB)
            row(.softClipperThresholdDB)
            row(.softClipperKneeSmooth)
            Picker("Curve", selection: binding({ $0.softClipper.curve }, { $0.softClipper.curve = $1 })) {
                ForEach(SoftClipperCurve.allCases) { curve in Text(curve.displayName).tag(curve) }
            }
            .pickerStyle(.menu)
            Toggle("Automatic Gain Compensation", isOn: boolBinding({ $0.softClipper.autoCompensateGain }, { $0.softClipper.autoCompensateGain = $1 }))
            row(.softClipperAsymmetryTrimDB)
        }
    }

    private var automaticHeadroomEditor: some View {
        moduleCard(module: .automaticHeadroom, enabled: boolBinding({ $0.automaticHeadroom.enabled }, { $0.automaticHeadroom.enabled = $1 }), reset: { preserveEnabledReset(\.automaticHeadroom, defaultValue: AutomaticHeadroomConfiguration()) }) {
            row(.automaticHeadroomMaxAttenuationDB)
            Text("Predictive headroom is distinct from the Dynamic Gain Rider: it reserves known filter/EQ headroom before clipping can occur, rather than reacting to limiter activity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var oversamplingEditor: some View {
        moduleCard(module: .oversampling, enabled: nil, reset: { update { $0.oversampling = .one } }) {
            Picker("Protection Oversampling", selection: binding({ $0.oversampling }, { $0.oversampling = $1 })) {
                ForEach(OversamplingFactor.allCases) { factor in Text(factor.displayName).tag(factor) }
            }
            .pickerStyle(.segmented)
            Text("Use higher factors when nonlinear protection stages need additional anti-aliasing margin. CPU cost rises with factor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Conditioning

    private var deHarshEditor: some View {
        moduleCard(module: .deHarsh, enabled: boolBinding({ $0.deHarsh.enabled }, { $0.deHarsh.enabled = $1 }), reset: { preserveEnabledReset(\.deHarsh, defaultValue: DeHarshConfiguration()) }) {
            row(.deHarshAmountDB)
            row(.deHarshFrequencyHz)
        }
    }

    private var stereoWidenerEditor: some View {
        moduleCard(module: .stereoWidener, enabled: boolBinding({ $0.stereoWidener.enabled }, { $0.stereoWidener.enabled = $1 }), reset: { preserveEnabledReset(\.stereoWidener, defaultValue: StereoWidenerConfiguration()) }) {
            Toggle("Mono Low Band", isOn: boolBinding({ $0.stereoWidener.monoLowBand }, { $0.stereoWidener.monoLowBand = $1 }))
            row(.stereoWidenerLowWidth)
            row(.stereoWidenerLowMidFrequencyHz)
            row(.stereoWidenerMidWidth)
            row(.stereoWidenerMidHighFrequencyHz)
            row(.stereoWidenerHighWidth)
        }
    }

    private var stereoModeEditor: some View {
        moduleCard(module: .stereoMode, enabled: nil, reset: { update { $0.stereoMode = .stereo } }) {
            Picker("Stereo Processing Mode", selection: binding({ $0.stereoMode }, { $0.stereoMode = $1 })) {
                ForEach(StereoProcessingMode.allCases) { mode in Text(mode.displayName).tag(mode) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var dcOffsetEditor: some View {
        moduleCard(module: .dcOffset, enabled: boolBinding({ $0.dcOffsetFilter.enabled }, { $0.dcOffsetFilter.enabled = $1 }), reset: { preserveEnabledReset(\.dcOffsetFilter, defaultValue: DCOffsetFilterConfiguration()) }) {
            Text("Removes DC bias with the production 0.5 Hz high-pass stage. There are intentionally no tone-shaping controls because this is a utility filter.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared UI

    private func moduleCard<Content: View>(
        module: ProductionDynamicsModule,
        enabled: Binding<Bool>?,
        reset: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: module.systemImage)
                    .font(.title2)
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular, in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(module.title).font(.title2.bold())
                    Text(module.longDescription).foregroundStyle(.secondary)
                }
                Spacer()
                if let enabled {
                    Toggle(module.title, isOn: enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("\(module.title) enabled")
                        .accessibilityIdentifier("dynamics.\(module.rawValue).enabled")
                }
                Button("Reset", action: reset)
                    .buttonStyle(.glass)
                    .accessibilityLabel("Reset \(module.title)")
                    .accessibilityIdentifier("dynamics.\(module.rawValue).reset")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(20)
        }
        .frame(maxWidth: 920, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .padding(.bottom, 24)
    }

    private func multibandBandEditor(band: Int, title: String) -> some View {
        let rows = DynamicsParameterSpec.multibandBand(band)
        let auto = configuration.multibandCompressor.autoMakeupBands?.contains(band) == true
        return DisclosureGroup(title) {
            VStack(spacing: 10) {
                ForEach(rows) { spec in
                    row(spec, enabled: !(auto && spec.title == "Makeup Gain"))
                    if spec.title == "Makeup Gain" {
                        Toggle("Auto Makeup", isOn: binding(
                            { $0.multibandCompressor.autoMakeupBands?.contains(band) == true },
                            { config, on in
                                var bands = config.multibandCompressor.autoMakeupBands ?? []
                                if on { bands.insert(band) } else { bands.remove(band) }
                                config.multibandCompressor.autoMakeupBands = bands.isEmpty ? nil : bands
                            }
                        ))
                        .help(Self.autoMakeupHelp)
                        .accessibilityIdentifier("dynamics.multiband.\(band).autoMakeup")
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Bindings / mutation

    private func binding<Value>(
        _ get: @escaping (DynamicsConfiguration) -> Value,
        _ set: @escaping (inout DynamicsConfiguration, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { get(engine.dynamicsConfiguration) },
            set: { value in update { set(&$0, value) } }
        )
    }

    private func boolBinding(
        _ get: @escaping (DynamicsConfiguration) -> Bool,
        _ set: @escaping (inout DynamicsConfiguration, Bool) -> Void
    ) -> Binding<Bool> { binding(get, set) }

    private func doubleBinding(
        _ get: @escaping (DynamicsConfiguration) -> Double,
        _ set: @escaping (inout DynamicsConfiguration, Double) -> Void
    ) -> Binding<Double> { binding(get, set) }

    private func denoiserBinding<Value>(
        _ get: @escaping (SpectralDenoiserConfiguration) -> Value,
        _ set: @escaping (inout SpectralDenoiserConfiguration, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { get(engine.dynamicsConfiguration.spectralDenoiser) },
            set: { value in
                update { config in
                    set(&config.spectralDenoiser, value)
                }
            }
        )
    }

    /// Applies an edit and records it as one undo step. A refused edit leaves the stored configuration (so
    /// every row shows the live value) and shows `failure(reason)` or the engine's reason (E28 S4, G1).
    @discardableResult
    private func update(
        name: String = "Edit Dynamics",
        coalesceKey: String? = nil,
        failure: ((String) -> String)? = nil,
        _ mutation: (inout DynamicsConfiguration) -> Void
    ) -> Bool {
        let before = engine.dynamicsConfiguration
        var updated = before
        mutation(&updated)
        updated.applyAutoMakeup()
        do {
            try engine.replaceDynamicsConfiguration(updated)
            actionError = nil
            history.record(before: before, after: engine.dynamicsConfiguration, name: name, coalesceKey: coalesceKey)
            return true
        } catch {
            let reason = error.localizedDescription
            actionError = failure?(reason) ?? reason
            return false
        }
    }

    private func row(_ spec: DynamicsParameterSpec, enabled: Bool = true, title: String? = nil) -> some View {
        DynamicsParameterRow(
            spec: spec,
            title: title ?? spec.title,
            value: configuration[keyPath: spec.keyPath],
            isEnabled: enabled,
            reference: reference,
            commit: { value, isStep in
                update(
                    name: "Edit \(spec.stage) \(spec.title)",
                    coalesceKey: isStep ? spec.id : nil,
                    failure: { spec.rejectionMessage(value: value, reason: $0) }
                ) { spec.apply(value, to: &$0) }
            },
            beginGesture: {
                history.beginGesture(before: engine.dynamicsConfiguration, name: "Edit \(spec.stage) \(spec.title)")
            },
            endGesture: { history.endGesture(after: engine.dynamicsConfiguration) }
        )
    }

    private func configureHistory() {
        history.configure(
            undoManager: undoManager,
            live: { engine.dynamicsConfiguration },
            apply: { try engine.replaceDynamicsConfiguration($0) }
        )
    }

    static let autoMakeupHelp = "Sets makeup gain to restore the level this stage removes at a typical programme level of -18 dBFS, from the threshold, ratio and knee. Turning it off keeps the current value."

    private func preserveEnabledReset<Value>(_ keyPath: WritableKeyPath<DynamicsConfiguration, Value>, defaultValue: Value) {
        update { $0[keyPath: keyPath] = defaultValue }
    }

    private func resetDenoiser() {
        update { config in
            let enabled = config.spectralDenoiser.enabled
            config.spectralDenoiser = SpectralDenoiserConfiguration()
            config.spectralDenoiser.enabled = enabled
        }
    }

    private func resetMainsHum() {
        update { config in
            let enabled = config.mainsNotch.enabled
            config.mainsNotch = MainsNotchConfiguration()
            config.mainsNotch.enabled = enabled
        }
    }

    private var activeModuleCount: Int {
        ProductionDynamicsModule.allCases.reduce(0) { $0 + (moduleIsActive($1) ? 1 : 0) }
    }

    private func moduleIsActive(_ module: ProductionDynamicsModule) -> Bool {
        let d = configuration
        switch module {
        case .compressor: return d.compressor.enabled
        case .multiband: return d.multibandCompressor.enabled
        case .expander: return d.expander.enabled
        case .pauseGate: return d.pauseGate.enabled
        case .gainRider: return d.gainRider.enabled
        case .denoiser: return d.spectralDenoiser.enabled
        case .deEsser: return d.deEsser.enabled
        case .mainsHum: return d.mainsNotch.enabled || d.mainsNotch.continuousTracking
        case .infrasonic: return d.infrasonicFilter.enabled
        case .loudnessMatch: return d.loudnessMatch.enabled
        case .loudnessContour: return d.loudnessContour.enabled
        case .dialogueLeveler: return d.dialogueRelativeLeveler.enabled
        case .limiter: return d.limiter.enabled
        case .softClipper: return d.softClipper.enabled
        case .automaticHeadroom: return d.automaticHeadroom.enabled
        case .oversampling: return d.oversampling != .one
        case .deHarsh: return d.deHarsh.enabled
        case .stereoWidener: return d.stereoWidener.enabled
        case .stereoMode: return d.stereoMode != .stereo
        case .dcOffset: return d.dcOffsetFilter.enabled
        }
    }
}

enum ProductionDynamicsModule: String, CaseIterable, Identifiable, Hashable {
    case compressor
    case multiband
    case expander
    case pauseGate
    case gainRider
    case denoiser
    case deEsser
    case mainsHum
    case infrasonic
    case loudnessMatch
    case loudnessContour
    case dialogueLeveler
    case limiter
    case softClipper
    case automaticHeadroom
    case oversampling
    case deHarsh
    case stereoWidener
    case stereoMode
    case dcOffset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compressor: return "Compressor"
        case .multiband: return "Multiband Compressor"
        case .expander: return "Expander"
        case .pauseGate: return "Pause Gate"
        case .gainRider: return "Dynamic Gain Rider"
        case .denoiser: return "Spectral Denoiser"
        case .deEsser: return "De-Esser"
        case .mainsHum: return "Mains Hum"
        case .infrasonic: return "Infrasonic Filter"
        case .loudnessMatch: return "LUFS Match"
        case .loudnessContour: return "Loudness Compensation"
        case .dialogueLeveler: return "Dialogue Leveler"
        case .limiter: return "Limiter"
        case .softClipper: return "Soft Clipper"
        case .automaticHeadroom: return "Automatic Headroom"
        case .oversampling: return "Oversampling"
        case .deHarsh: return "De-Harsh"
        case .stereoWidener: return "Stereo Widener"
        case .stereoMode: return "Stereo Mode"
        case .dcOffset: return "DC Offset Filter"
        }
    }

    var subtitle: String {
        switch self {
        case .compressor: return "Wideband level control"
        case .multiband: return "Three-band dynamics"
        case .expander: return "Downward expansion"
        case .pauseGate: return "Silence / amplifier-hiss gate"
        case .gainRider: return "Limiter-aware slow gain control"
        case .denoiser: return "Spectral noise reduction"
        case .deEsser: return "Sibilance control"
        case .mainsHum: return "50 / 60 Hz harmonic removal"
        case .infrasonic: return "Subsonic protection"
        case .loudnessMatch: return "Program loudness normalization"
        case .loudnessContour: return "Low-level listening compensation"
        case .dialogueLeveler: return "Masking-aware dialogue lift"
        case .limiter: return "Look-ahead peak protection"
        case .softClipper: return "Pre-limiter peak shaping"
        case .automaticHeadroom: return "Predictive filter headroom"
        case .oversampling: return "Protection-stage sample rate"
        case .deHarsh: return "High-frequency conditioning"
        case .stereoWidener: return "Three-band width control"
        case .stereoMode: return "Stereo / mono fold-down"
        case .dcOffset: return "DC removal utility"
        }
    }

    var longDescription: String {
        switch self {
        case .compressor: return "Primary wideband compressor with topology, program-dependent release, and sidechain filtering."
        case .multiband: return "Independent Low, Mid, and High dynamics with production-accessible crossover slopes and per-band timing."
        case .expander: return "Downward expander for increasing low-level contrast without using a hard gate."
        case .pauseGate: return "Silences near-zero program material with explicit hold and click-free close/open fades."
        case .gainRider: return "Slowly manages sustained limiter activity before the final protection stages."
        case .denoiser: return "FFT-domain noise reduction with named tuning, profile capture, protected frequency ranges, and expert smoothing overrides."
        case .deEsser: return "Frequency-selective dynamics for sibilance and high-frequency harshness."
        case .mainsHum: return "Tracks and removes mains fundamentals and harmonics with independently adjustable notch depths."
        case .infrasonic: return "Steep subsonic high-pass protection. Output-target routing is deliberately owned by crossover/routing."
        case .loudnessMatch: return "Program-level LUFS matching with bounded correction and asymmetric timing."
        case .loudnessContour: return "Equal-loudness compensation for lower playback levels with bounded bass/treble correction."
        case .dialogueLeveler: return "Compares dialogue-band energy against the full program and lifts speech only when masking warrants it."
        case .limiter: return "Final look-ahead limiter with optional true-peak reconstruction guard."
        case .softClipper: return "Nonlinear peak shaping before limiting, including selectable curve and asymmetric character."
        case .automaticHeadroom: return "Predictive attenuation budget that reserves headroom for known filter/EQ boosts."
        case .oversampling: return "Controls nonlinear protection oversampling independently from ordinary linear DSP."
        case .deHarsh: return "Broad high-frequency conditioning for fatiguing or aggressively mastered material."
        case .stereoWidener: return "Frequency-dependent Mid/Side width control with mono-bass protection."
        case .stereoMode: return "Global stereo, wide-mono, or true-mono processing mode."
        case .dcOffset: return "Removes DC bias before downstream dynamics processing."
        }
    }

    var systemImage: String {
        switch self {
        case .compressor: return "arrow.down.right.and.arrow.up.left"
        case .multiband: return "waveform.path"
        case .expander: return "arrow.up.left.and.arrow.down.right"
        case .pauseGate: return "pause.circle"
        case .gainRider: return "dial.medium"
        case .denoiser: return "waveform.badge.minus"
        case .deEsser: return "mouth"
        case .mainsHum: return "bolt.slash"
        case .infrasonic: return "speaker.wave.1"
        case .loudnessMatch: return "waveform.and.magnifyingglass"
        case .loudnessContour: return "ear"
        case .dialogueLeveler: return "quote.bubble"
        case .limiter: return "shield.lefthalf.filled"
        case .softClipper: return "waveform.path.badge.plus"
        case .automaticHeadroom: return "gauge.with.dots.needle.33percent"
        case .oversampling: return "4.circle"
        case .deHarsh: return "sparkles"
        case .stereoWidener: return "arrow.left.and.right"
        case .stereoMode: return "speaker.2"
        case .dcOffset: return "waveform.path.ecg.rectangle"
        }
    }
}

/// The dynamics navigator's groups, in the order the engine runs the
/// processors (`docs/DSP_KERNEL.md`). Niche processors fold under "More" in
/// their own group, so the list still reads as the signal path.
enum ProductionDynamicsLayout {
    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let note: String?
        /// Every processor in the group, in signal-chain order.
        let modules: [ProductionDynamicsModule]
        /// The niche processors folded under "More" until it is expanded.
        let folded: Set<ProductionDynamicsModule>

        init(
            id: String,
            title: String,
            note: String? = nil,
            modules: [ProductionDynamicsModule],
            folded: Set<ProductionDynamicsModule> = []
        ) {
            self.id = id
            self.title = title
            self.note = note
            self.modules = modules
            self.folded = folded
        }

        var shown: [ProductionDynamicsModule] { modules.filter { !folded.contains($0) } }
        var more: [ProductionDynamicsModule] { modules.filter { folded.contains($0) } }

        /// Drives the badge on a folded "More" row, so processing that is on
        /// is never hidden.
        func moreHasActiveModule(isActive: (ProductionDynamicsModule) -> Bool) -> Bool {
            more.contains(where: isActive)
        }
    }

    static let groups: [Group] = [
        Group(
            id: "input",
            title: "Input & Clean-up",
            note: "Runs before EQ and room correction.",
            modules: [.automaticHeadroom, .dcOffset, .infrasonic, .mainsHum, .denoiser],
            folded: [.dcOffset, .denoiser]
        ),
        Group(
            id: "stereo",
            title: "Stereo",
            note: "Runs after EQ and room correction.",
            modules: [.stereoMode, .stereoWidener]
        ),
        Group(
            id: "level",
            title: "Level & Dialogue",
            modules: [.loudnessMatch, .loudnessContour, .dialogueLeveler]
        ),
        Group(id: "tone", title: "Tone", modules: [.deHarsh, .deEsser], folded: [.deEsser]),
        Group(
            id: "dynamics",
            title: "Dynamics",
            modules: [.multiband, .compressor, .expander],
            folded: [.expander]
        ),
        Group(
            id: "output",
            title: "Output",
            // Oversampling sets the rate the protection stage runs at, so it
            // closes the list.
            modules: [.pauseGate, .gainRider, .softClipper, .limiter, .oversampling],
            folded: [.oversampling]
        ),
    ]
}

// MARK: - E9 S5b output protection

/// E9 S5b: the Protection card's "Outputs" list (`e9.output-protection`). One row per output with its own on/off and ceiling
/// (live: a ceiling edit is a parameter post, not a rebuild) and the live gain reduction and true peak of that output, plus
/// the Advanced "Independent per output" switch. Shows nothing while the flag is off.
struct ProductionOutputProtectionSection: View {
    @ObservedObject var engine: AudioIOEngine
    let settings: OutputProtectionSettings
    let apply: (OutputProtectionSettings) -> Void
    /// E9 S5c (G19): per-output ceilings ride on the program limiter's stages, so they do nothing while it is off.
    var programLimiterOn = true

    @State private var readings: [Int: UnifiedGraphOutputProtectionReading] = [:]

    var body: some View {
        let lanes = engine.outputProtectionLanes
        if lanes.isEmpty {
            EmptyView()
        } else {
            GroupBox("Outputs") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Every output also has an always-on hard limit at \(Int(UnifiedGraphOutputProtection.hardLimitCeilingDB)) dBFS that these settings cannot lower. Turning an output off parks its own ceiling at the hard limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("Advanced") {
                        Toggle("Independent per output", isOn: Binding(
                            get: { settings.independent },
                            set: { value in var next = settings; next.independent = value; apply(next) }
                        ))
                        Text("Off keeps the program outputs as one linked group so the stereo image is preserved. On gives every program output its own limiter. Switching rebuilds the graph with a short fade.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !programLimiterOn {
                        Text("The program Limiter is off, so these ceilings have no effect. The \(Int(UnifiedGraphOutputProtection.hardLimitCeilingDB)) dBFS hard limit still holds every output.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(lanes) { lane in row(lane) }
                }
                .padding(.vertical, 5)
            }
            .task { await poll() }
        }
    }

    private func row(_ lane: AudioIOEngine.OutputProtectionLane) -> some View {
        let own = lane.isSub || settings.independent
        let setting = settings.lane(lane.index)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(lane.label).font(.subheadline.weight(.medium))
                Spacer()
                if own {
                    Toggle("On", isOn: Binding(
                        get: { setting.enabled },
                        set: { value in
                            var next = settings
                            var updated = setting
                            updated.enabled = value
                            next.set(updated, at: lane.index)
                            apply(next)
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("\(lane.label) protection")
                } else {
                    Text("Linked").font(.caption).foregroundStyle(.secondary)
                }
            }
            if own {
                OutputCeilingSlider(value: setting.ceilingDB ?? Double(UnifiedGraphOutputProtection.hardLimitCeilingDB), isEnabled: setting.enabled) { value in
                    var next = settings
                    var updated = setting
                    updated.ceilingDB = value
                    next.set(updated, at: lane.index)
                    apply(next)
                }
            }
            if let reading = readings[lane.index] {
                Text(readoutText(reading, own: own))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func peakDB(_ linear: Float) -> String {
        linear > 0 ? String(format: "%.1f dBTP", Double(20 * log10(linear))) : "-inf dBTP"
    }

    private func readoutText(_ reading: UnifiedGraphOutputProtectionReading, own: Bool) -> String {
        var parts: [String] = []
        if own, let gr = reading.userGainReductionDB { parts.append(String(format: "limiter %.1f dB", Double(gr))) }
        parts.append(String(format: "hard limit %.1f dB", Double(reading.hardLimitGainReductionDB)))
        parts.append("peak " + Self.peakDB(reading.outputTruePeakLinear))
        return parts.joined(separator: "  ·  ")
    }

    @MainActor
    private func poll() async {
        while !Task.isCancelled {
            if engine.lifecycleState == .running {
                var next: [Int: UnifiedGraphOutputProtectionReading] = [:]
                for reading in engine.outputProtectionReadings() { next[reading.lane] = reading }
                readings = next
            } else {
                readings = [:]
            }
            try? await Task.sleep(nanoseconds: 125_000_000)
        }
    }
}

/// E9 S5c (G20): the per-output ceiling slider. The label follows the drag at once; the edit reaches the engine once the drag
/// pauses (`OutputProtectionEditDebouncer`) or ends, instead of publishing the whole graph on every tick.
private struct OutputCeilingSlider: View {
    let value: Double
    let isEnabled: Bool
    let commit: (Double) -> Void

    @State private var draft: Double?
    @State private var holder = Holder()

    @MainActor final class Holder {
        var commit: ((Double) -> Void)?
        lazy var debouncer = OutputProtectionEditDebouncer<Double> { [unowned self] in self.commit?($0) }
    }

    var body: some View {
        let _ = holder.commit = { [commit] value in commit(value) }
        HStack {
            Text("Ceiling").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { draft ?? value },
                set: { next in
                    draft = next
                    holder.debouncer.submit(next)
                }
            ), in: OutputProtectionSettings.ceilingRangeDB, step: 0.1) { editing in
                if !editing {
                    holder.debouncer.flush()
                    draft = nil
                }
            }
            .disabled(!isEnabled)
            .onDisappear { holder.debouncer.flush() }
            Text(String(format: "%.1f dB", draft ?? value))
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
    }
}
