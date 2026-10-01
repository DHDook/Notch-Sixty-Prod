import Foundation
import SwiftUI

struct ProductionDynamicsView: View {
    @ObservedObject var engine: AudioIOEngine
    @State private var selectedModule: ProductionDynamicsModule = .compressor
    @State private var mainsDetectInFlight = false
    @State private var mainsDetectionMessage: String?

    private var configuration: DynamicsConfiguration { engine.dynamicsConfiguration }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HSplitView {
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Dynamics").font(.largeTitle.bold())
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
                ForEach(ProductionDynamicsGroup.allCases) { group in
                    Text(group.title.uppercased())
                        .font(.caption2.bold())
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    ForEach(group.modules) { module in
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
                }
            }
            .padding(8)
        }
        .scrollIndicators(.visible)
        .background(.clear)
        .clipShape(.rect(cornerRadius: 18))
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
            DynamicsParameterRow("Threshold", value: doubleBinding({ $0.compressor.thresholdDB }, { $0.compressor.thresholdDB = $1 }), range: -60...0, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Ratio", value: doubleBinding({ $0.compressor.ratio }, { $0.compressor.ratio = $1 }), range: 1...20, step: 0.1, unit: ":1", digits: 1)
            DynamicsParameterRow("Knee", value: doubleBinding({ $0.compressor.kneeWidthDB }, { $0.compressor.kneeWidthDB = $1 }), range: 0...20, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Attack", value: doubleBinding({ $0.compressor.attackMs }, { $0.compressor.attackMs = $1 }), range: 0.1...100, step: 0.5, unit: "ms", digits: 1)
            DynamicsParameterRow("Release", value: doubleBinding({ $0.compressor.releaseMs }, { $0.compressor.releaseMs = $1 }), range: 5...1_000, step: 5, unit: "ms", digits: 0)
            DynamicsParameterRow("Makeup Gain", value: doubleBinding({ $0.compressor.makeupGainDB }, { $0.compressor.makeupGainDB = $1 }), range: -24...24, step: 0.5, unit: "dB", digits: 1)

            Divider()
            Picker("Topology", selection: binding({ $0.compressor.topology }, { $0.compressor.topology = $1 })) {
                ForEach(CompressorTopology.allCases) { topology in
                    Text(topology.displayName).tag(topology)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Program-Dependent Release", isOn: boolBinding({ $0.compressor.programDependentRelease }, { $0.compressor.programDependentRelease = $1 }))
                .help("Adapts release behavior to program dynamics instead of using only the fixed release time.")
            DynamicsParameterRow("Sidechain High-Pass", value: doubleBinding({ $0.compressor.sidechainHighPassHz }, { $0.compressor.sidechainHighPassHz = $1 }), range: 0...300, step: 5, unit: "Hz", digits: 0)
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
                    DynamicsParameterRow("Low / Mid", value: doubleBinding({ $0.multibandCompressor.lowMidFrequencyHz }, { $0.multibandCompressor.lowMidFrequencyHz = $1 }), range: 40...250, step: 5, unit: "Hz", digits: 0)
                    Picker("Low / Mid Slope", selection: binding({ $0.multibandCompressor.lowMidSlope }, { $0.multibandCompressor.lowMidSlope = $1 })) {
                        ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                    }
                    DynamicsParameterRow("Mid / High", value: doubleBinding({ $0.multibandCompressor.midHighFrequencyHz }, { $0.multibandCompressor.midHighFrequencyHz = $1 }), range: 1_000...8_000, step: 100, unit: "Hz", digits: 0)
                    Picker("Mid / High Slope", selection: binding({ $0.multibandCompressor.midHighSlope }, { $0.multibandCompressor.midHighSlope = $1 })) {
                        ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                    }
                }
                .padding(.vertical, 6)
            }

            multibandBandEditor(
                title: "Low Band",
                threshold: doubleBinding({ $0.multibandCompressor.lowThresholdDB }, { $0.multibandCompressor.lowThresholdDB = $1 }),
                ratio: doubleBinding({ $0.multibandCompressor.lowRatio }, { $0.multibandCompressor.lowRatio = $1 }),
                attack: doubleBinding({ $0.multibandCompressor.lowAttackMs }, { $0.multibandCompressor.lowAttackMs = $1 }),
                release: doubleBinding({ $0.multibandCompressor.lowReleaseMs }, { $0.multibandCompressor.lowReleaseMs = $1 }),
                knee: doubleBinding({ $0.multibandCompressor.lowKneeDB }, { $0.multibandCompressor.lowKneeDB = $1 }),
                makeup: doubleBinding({ $0.multibandCompressor.lowMakeupGainDB }, { $0.multibandCompressor.lowMakeupGainDB = $1 }),
                sidechain: doubleBinding({ $0.multibandCompressor.lowSidechainHighPassHz }, { $0.multibandCompressor.lowSidechainHighPassHz = $1 }),
                sidechainRange: 0...300
            )
            multibandBandEditor(
                title: "Mid Band",
                threshold: doubleBinding({ $0.multibandCompressor.midThresholdDB }, { $0.multibandCompressor.midThresholdDB = $1 }),
                ratio: doubleBinding({ $0.multibandCompressor.midRatio }, { $0.multibandCompressor.midRatio = $1 }),
                attack: doubleBinding({ $0.multibandCompressor.midAttackMs }, { $0.multibandCompressor.midAttackMs = $1 }),
                release: doubleBinding({ $0.multibandCompressor.midReleaseMs }, { $0.multibandCompressor.midReleaseMs = $1 }),
                knee: doubleBinding({ $0.multibandCompressor.midKneeDB }, { $0.multibandCompressor.midKneeDB = $1 }),
                makeup: doubleBinding({ $0.multibandCompressor.midMakeupGainDB }, { $0.multibandCompressor.midMakeupGainDB = $1 }),
                sidechain: doubleBinding({ $0.multibandCompressor.midSidechainHighPassHz }, { $0.multibandCompressor.midSidechainHighPassHz = $1 }),
                sidechainRange: 0...1_000
            )
            multibandBandEditor(
                title: "High Band",
                threshold: doubleBinding({ $0.multibandCompressor.highThresholdDB }, { $0.multibandCompressor.highThresholdDB = $1 }),
                ratio: doubleBinding({ $0.multibandCompressor.highRatio }, { $0.multibandCompressor.highRatio = $1 }),
                attack: doubleBinding({ $0.multibandCompressor.highAttackMs }, { $0.multibandCompressor.highAttackMs = $1 }),
                release: doubleBinding({ $0.multibandCompressor.highReleaseMs }, { $0.multibandCompressor.highReleaseMs = $1 }),
                knee: doubleBinding({ $0.multibandCompressor.highKneeDB }, { $0.multibandCompressor.highKneeDB = $1 }),
                makeup: doubleBinding({ $0.multibandCompressor.highMakeupGainDB }, { $0.multibandCompressor.highMakeupGainDB = $1 }),
                sidechain: doubleBinding({ $0.multibandCompressor.highSidechainHighPassHz }, { $0.multibandCompressor.highSidechainHighPassHz = $1 }),
                sidechainRange: 0...3_000
            )
        }
    }

    private var expanderEditor: some View {
        moduleCard(module: .expander, enabled: boolBinding({ $0.expander.enabled }, { $0.expander.enabled = $1 }), reset: { preserveEnabledReset(\.expander, defaultValue: ExpanderConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .expander)
            DynamicsParameterRow("Threshold", value: doubleBinding({ $0.expander.thresholdDB }, { $0.expander.thresholdDB = $1 }), range: -60...0, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Ratio", value: doubleBinding({ $0.expander.ratio }, { $0.expander.ratio = $1 }), range: 1...4, step: 0.1, unit: ":1", digits: 1)
            DynamicsParameterRow("Range", value: doubleBinding({ $0.expander.rangeDB }, { $0.expander.rangeDB = $1 }), range: -40...0, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Attack", value: doubleBinding({ $0.expander.attackMs }, { $0.expander.attackMs = $1 }), range: 0.1...100, step: 0.5, unit: "ms", digits: 1)
            DynamicsParameterRow("Release", value: doubleBinding({ $0.expander.releaseMs }, { $0.expander.releaseMs = $1 }), range: 10...1_000, step: 10, unit: "ms", digits: 0)
        }
    }

    private var pauseGateEditor: some View {
        moduleCard(module: .pauseGate, enabled: boolBinding({ $0.pauseGate.enabled }, { $0.pauseGate.enabled = $1 }), reset: { preserveEnabledReset(\.pauseGate, defaultValue: PauseGateConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .pauseGate)
            Picker("Preset", selection: binding({ $0.pauseGate.preset }, { config, value in config.pauseGate.applyPreset(value) })) {
                ForEach(PauseGatePreset.allCases) { preset in Text(preset.displayName).tag(preset) }
            }
            .pickerStyle(.menu)

            DynamicsParameterRow("Threshold", value: pauseGateDoubleBinding(\.thresholdDBFS), range: -80 ... -40, step: 1, unit: "dBFS", digits: 0)
            DynamicsParameterRow("Hold", value: pauseGateDoubleBinding(\.holdMs), range: 100...2_000, step: 25, unit: "ms", digits: 0)
            DynamicsParameterRow("Attack", value: pauseGateDoubleBinding(\.attackMs), range: 1...100, step: 1, unit: "ms", digits: 0)
                .help("Attack is the fade-out / gate-close time.")
            DynamicsParameterRow("Release", value: pauseGateDoubleBinding(\.releaseMs), range: 10...500, step: 5, unit: "ms", digits: 0)
                .help("Release is the fade-in / gate-open time.")
            DynamicsParameterRow("Hysteresis", value: pauseGateDoubleBinding(\.hysteresisDB), range: 0...6, step: 0.5, unit: "dB", digits: 1)

            Label("Product convention: Attack = fade-out, Release = fade-in.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var gainRiderEditor: some View {
        moduleCard(module: .gainRider, enabled: boolBinding({ $0.gainRider.enabled }, { $0.gainRider.enabled = $1 }), reset: { preserveEnabledReset(\.gainRider, defaultValue: GainRiderConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .gainRider)
            DynamicsParameterRow("Target Gain Reduction", value: doubleBinding({ $0.gainRider.targetGainReductionDB }, { $0.gainRider.targetGainReductionDB = $1 }), range: 0.5...6, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Maximum Reduction", value: doubleBinding({ $0.gainRider.maxReductionDB }, { $0.gainRider.maxReductionDB = $1 }), range: 3...12, step: 1, unit: "dB", digits: 0)
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
                set: { try? engine.applySpectralDenoiserPreset($0) }
            )) {
                ForEach(SpectralDenoiserPreset.allCases) { preset in Text(preset.displayName).tag(preset) }
            }
            .pickerStyle(.menu)

            Picker("Quality", selection: denoiserBinding({ $0.quality }, { $0.quality = $1; $0.markCustom() })) {
                ForEach(SpectralDenoiserQuality.allCases) { quality in Text(quality.displayName).tag(quality) }
            }
            .pickerStyle(.segmented)

            DynamicsParameterRow("Threshold", value: denoiserDoubleBinding(\.thresholdDBFS), range: -96 ... -30, step: 1, unit: "dBFS", digits: 0)
            DynamicsParameterRow("Reduction", value: denoiserDoubleBinding(\.reductionAmount), range: 0...1, step: 0.01, unit: "", digits: 2)

            Toggle("Protect Frequency Range", isOn: denoiserBinding({ $0.protectedRangeEnabled }, { $0.protectedRangeEnabled = $1; $0.markCustom() }))
            if configuration.spectralDenoiser.protectedRangeEnabled {
                DynamicsParameterRow("Protect From", value: denoiserDoubleBinding(\.protectedLowHz), range: 0...20_000, step: 10, unit: "Hz", digits: 0)
                DynamicsParameterRow("Protect To", value: denoiserDoubleBinding(\.protectedHighHz), range: 0...20_000, step: 10, unit: "Hz", digits: 0)
            }

            DisclosureGroup("Advanced Suppression") {
                VStack(spacing: 10) {
                    Toggle("Override Preset Smoothing", isOn: denoiserBinding({ $0.advancedTuningEnabled }, { $0.advancedTuningEnabled = $1; $0.markCustom() }))
                    DynamicsParameterRow("Wiener / Minimum Gain", value: denoiserDoubleBinding(\.minimumGain), range: 0.001...0.5, step: 0.001, unit: "", digits: 3)
                        .disabled(!configuration.spectralDenoiser.advancedTuningEnabled)
                    DynamicsParameterRow("Attack", value: denoiserDoubleBinding(\.attackMs), range: 1...100, step: 1, unit: "ms", digits: 0)
                        .disabled(!configuration.spectralDenoiser.advancedTuningEnabled)
                    DynamicsParameterRow("Release", value: denoiserDoubleBinding(\.releaseMs), range: 5...500, step: 5, unit: "ms", digits: 0)
                        .disabled(!configuration.spectralDenoiser.advancedTuningEnabled)
                    Text("Named presets retain their accepted internal suppression behavior. These values take effect only when the explicit override is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }

            Divider()
            HStack {
                Button("Capture Noise Profile") { try? engine.captureSpectralNoiseProfile() }
                    .buttonStyle(.glassProminent)
                Button("Reset Profile") { try? engine.resetSpectralNoiseProfile() }
                    .buttonStyle(.glass)
                Spacer()
            }
        }
    }

    private var deEsserEditor: some View {
        moduleCard(module: .deEsser, enabled: boolBinding({ $0.deEsser.enabled }, { $0.deEsser.enabled = $1 }), reset: { preserveEnabledReset(\.deEsser, defaultValue: DeEsserConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .deEsser)
            DynamicsParameterRow("Frequency", value: doubleBinding({ $0.deEsser.frequencyHz }, { $0.deEsser.frequencyHz = $1 }), range: 2_000...10_000, step: 50, unit: "Hz", digits: 0)
            DynamicsParameterRow("Detector Q", value: doubleBinding({ $0.deEsser.detectionQ }, { $0.deEsser.detectionQ = $1 }), range: 0.5...8, step: 0.1, unit: "", digits: 1)
            DynamicsParameterRow("Threshold", value: doubleBinding({ $0.deEsser.thresholdDB }, { $0.deEsser.thresholdDB = $1 }), range: -60...0, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Ratio", value: doubleBinding({ $0.deEsser.ratio }, { $0.deEsser.ratio = $1 }), range: 1...20, step: 0.5, unit: ":1", digits: 1)
            DynamicsParameterRow("Range", value: doubleBinding({ $0.deEsser.rangeDB }, { $0.deEsser.rangeDB = $1 }), range: -24...0, step: 1, unit: "dB", digits: 0)
            DynamicsParameterRow("Attack", value: doubleBinding({ $0.deEsser.attackMs }, { $0.deEsser.attackMs = $1 }), range: 0.1...100, step: 0.1, unit: "ms", digits: 1)
            DynamicsParameterRow("Release", value: doubleBinding({ $0.deEsser.releaseMs }, { $0.deEsser.releaseMs = $1 }), range: 10...1_000, step: 5, unit: "ms", digits: 0)
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
            DynamicsParameterRow("Global Q", value: doubleBinding({ $0.mainsNotch.q }, { $0.mainsNotch.q = $1 }), range: 5...60, step: 1, unit: "", digits: 0)

            DisclosureGroup("Harmonic Depths") {
                VStack(spacing: 8) {
                    ForEach(0..<configuration.mainsNotch.harmonicCount, id: \.self) { index in
                        DynamicsParameterRow(
                            "H\(index + 1) · \(Int(configuration.mainsNotch.fundamentalHz * Double(index + 1))) Hz",
                            value: harmonicDepthBinding(index),
                            range: -40...0,
                            step: 1,
                            unit: "dB",
                            digits: 0
                        )
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var infrasonicEditor: some View {
        moduleCard(module: .infrasonic, enabled: boolBinding({ $0.infrasonicFilter.enabled }, { $0.infrasonicFilter.enabled = $1 }), reset: { preserveEnabledReset(\.infrasonicFilter, defaultValue: InfrasonicFilterConfiguration()) }) {
            DynamicsParameterRow("Cutoff", value: doubleBinding({ $0.infrasonicFilter.cutoffHz }, { $0.infrasonicFilter.cutoffHz = $1 }), range: 10...30, step: 1, unit: "Hz", digits: 0)
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
            DynamicsParameterRow("Target", value: doubleBinding({ $0.loudnessMatch.targetLUFS }, { $0.loudnessMatch.targetLUFS = $1 }), range: -24 ... -10, step: 0.5, unit: "LUFS", digits: 1)
            DynamicsParameterRow("Maximum Correction", value: doubleBinding({ $0.loudnessMatch.maxCorrectionDB }, { $0.loudnessMatch.maxCorrectionDB = $1 }), range: 3...20, step: 1, unit: "dB", digits: 0)
            DynamicsParameterRow("Attack", value: doubleBinding({ $0.loudnessMatch.attackSeconds }, { $0.loudnessMatch.attackSeconds = $1 }), range: 0.3...5, step: 0.1, unit: "s", digits: 1)
            DynamicsParameterRow("Release", value: doubleBinding({ $0.loudnessMatch.releaseSeconds }, { $0.loudnessMatch.releaseSeconds = $1 }), range: 1...10, step: 0.1, unit: "s", digits: 1)
            Toggle("Dialogue Gate", isOn: boolBinding({ $0.loudnessMatch.dialogueGateEnabled }, { $0.loudnessMatch.dialogueGateEnabled = $1 }))
        }
    }

    private var loudnessContourEditor: some View {
        moduleCard(module: .loudnessContour, enabled: boolBinding({ $0.loudnessContour.enabled }, { $0.loudnessContour.enabled = $1 }), reset: { preserveEnabledReset(\.loudnessContour, defaultValue: LoudnessContourConfiguration()) }) {
            DynamicsParameterRow("Strength", value: doubleBinding({ $0.loudnessContour.strength }, { $0.loudnessContour.strength = $1 }), range: 0...1, step: 0.05, unit: "", digits: 2)
            DynamicsParameterRow("Reference Level", value: doubleBinding({ $0.loudnessContour.referencePhons }, { $0.loudnessContour.referencePhons = $1 }), range: 60...95, step: 1, unit: "phon", digits: 0)
            DynamicsParameterRow("Maximum Boost", value: doubleBinding({ $0.loudnessContour.maxBoostDB }, { $0.loudnessContour.maxBoostDB = $1 }), range: 6...20, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Maximum Cut", value: doubleBinding({ $0.loudnessContour.maxCutDB }, { $0.loudnessContour.maxCutDB = $1 }), range: 0...6, step: 0.5, unit: "dB", digits: 1)
            Picker("Level Source", selection: binding({ $0.loudnessContour.levelSource }, { $0.loudnessContour.levelSource = $1 })) {
                ForEach(LoudnessLevelSource.allCases) { source in Text(source.displayName).tag(source) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var dialogueLevelerEditor: some View {
        moduleCard(module: .dialogueLeveler, enabled: boolBinding({ $0.dialogueRelativeLeveler.enabled }, { $0.dialogueRelativeLeveler.enabled = $1 }), reset: { preserveEnabledReset(\.dialogueRelativeLeveler, defaultValue: DialogueRelativeLevelerConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .dialogue)
            DynamicsParameterRow("Band Low", value: doubleBinding({ $0.dialogueRelativeLeveler.bandLowHz }, { $0.dialogueRelativeLeveler.bandLowHz = $1 }), range: 100...8_000, step: 50, unit: "Hz", digits: 0)
            DynamicsParameterRow("Band High", value: doubleBinding({ $0.dialogueRelativeLeveler.bandHighHz }, { $0.dialogueRelativeLeveler.bandHighHz = $1 }), range: 100...8_000, step: 50, unit: "Hz", digits: 0)
            DynamicsParameterRow("Target Gap", value: doubleBinding({ $0.dialogueRelativeLeveler.targetGapDB }, { $0.dialogueRelativeLeveler.targetGapDB = $1 }), range: 3...20, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Boost Ratio", value: doubleBinding({ $0.dialogueRelativeLeveler.boostRatio }, { $0.dialogueRelativeLeveler.boostRatio = $1 }), range: 1...6, step: 0.1, unit: ":1", digits: 1)
            DynamicsParameterRow("Maximum Boost", value: doubleBinding({ $0.dialogueRelativeLeveler.maxBoostDB }, { $0.dialogueRelativeLeveler.maxBoostDB = $1 }), range: 0...15, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Attack", value: doubleBinding({ $0.dialogueRelativeLeveler.attackMs }, { $0.dialogueRelativeLeveler.attackMs = $1 }), range: 10...1_000, step: 10, unit: "ms", digits: 0)
            DynamicsParameterRow("Release", value: doubleBinding({ $0.dialogueRelativeLeveler.releaseMs }, { $0.dialogueRelativeLeveler.releaseMs = $1 }), range: 50...3_000, step: 50, unit: "ms", digits: 0)
            DynamicsParameterRow("Program Gate", value: doubleBinding({ $0.dialogueRelativeLeveler.programGateThresholdDB }, { $0.dialogueRelativeLeveler.programGateThresholdDB = $1 }), range: -70 ... -30, step: 1, unit: "dBFS", digits: 0)

            Divider()
            Toggle("Voice Gate", isOn: boolBinding({ $0.dialogueRelativeLeveler.voiceGate.enabled }, { $0.dialogueRelativeLeveler.voiceGate.enabled = $1 }))
            if configuration.dialogueRelativeLeveler.voiceGate.enabled {
                DynamicsParameterRow("Sensitivity", value: voiceGateSensitivityBinding, range: 0.2...0.8, step: 0.05, unit: "", digits: 2)
                DynamicsParameterRow("Minimum Confidence", value: doubleBinding({ $0.dialogueRelativeLeveler.voiceGate.minConfidence }, { $0.dialogueRelativeLeveler.voiceGate.minConfidence = $1 }), range: 0...0.6, step: 0.05, unit: "", digits: 2)
            }

            DisclosureGroup("Advanced Detection") {
                VStack(spacing: 10) {
                    DynamicsParameterRow("Detector Window", value: doubleBinding({ $0.dialogueRelativeLeveler.detectorWindowMs }, { $0.dialogueRelativeLeveler.detectorWindowMs = $1 }), range: 50...500, step: 10, unit: "ms", digits: 0)
                    DynamicsParameterRow("Modulation Center", value: doubleBinding({ $0.dialogueRelativeLeveler.voiceGate.modulationCenterHz }, { $0.dialogueRelativeLeveler.voiceGate.modulationCenterHz = $1 }), range: 2...10, step: 0.5, unit: "Hz", digits: 1)
                    DynamicsParameterRow("Modulation Bandwidth", value: doubleBinding({ $0.dialogueRelativeLeveler.voiceGate.modulationBandwidthHz }, { $0.dialogueRelativeLeveler.voiceGate.modulationBandwidthHz = $1 }), range: 2...8, step: 0.5, unit: "Hz", digits: 1)
                    DynamicsParameterRow("Envelope Window", value: doubleBinding({ $0.dialogueRelativeLeveler.voiceGate.envelopeWindowMs }, { $0.dialogueRelativeLeveler.voiceGate.envelopeWindowMs = $1 }), range: 5...30, step: 1, unit: "ms", digits: 0)
                    DynamicsParameterRow("Measurement Window", value: doubleBinding({ $0.dialogueRelativeLeveler.voiceGate.measurementWindowMs }, { $0.dialogueRelativeLeveler.voiceGate.measurementWindowMs = $1 }), range: 300...1_500, step: 50, unit: "ms", digits: 0)
                    DynamicsParameterRow("Confidence Floor", value: doubleBinding({ $0.dialogueRelativeLeveler.voiceGate.confidenceFloorIndex }, { $0.dialogueRelativeLeveler.voiceGate.confidenceFloorIndex = min($1, $0.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex - 0.01) }), range: 0...0.99, step: 0.01, unit: "", digits: 2)
                    DynamicsParameterRow("Confidence Ceiling", value: doubleBinding({ $0.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex }, { $0.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex = max($1, $0.dialogueRelativeLeveler.voiceGate.confidenceFloorIndex + 0.01) }), range: 0.01...1, step: 0.01, unit: "", digits: 2)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Protection

    private var limiterEditor: some View {
        moduleCard(module: .limiter, enabled: boolBinding({ $0.limiter.enabled }, { $0.limiter.enabled = $1 }), reset: { preserveEnabledReset(\.limiter, defaultValue: LimiterConfiguration()) }) {
            ProductionDynamicsTelemetryView(engine: engine, kind: .limiter)
            DynamicsParameterRow("Ceiling", value: doubleBinding({ $0.limiter.ceilingDB }, { $0.limiter.ceilingDB = $1 }), range: -20...0, step: 0.1, unit: "dB", digits: 1)
            DynamicsParameterRow("Attack", value: doubleBinding({ $0.limiter.attackMs }, { $0.limiter.attackMs = $1 }), range: 0.1...50, step: 0.1, unit: "ms", digits: 1)
            DynamicsParameterRow("Release", value: doubleBinding({ $0.limiter.releaseMs }, { $0.limiter.releaseMs = $1 }), range: 5...500, step: 5, unit: "ms", digits: 0)
            DynamicsParameterRow("Look-Ahead", value: doubleBinding({ $0.limiter.lookAheadMs }, { $0.limiter.lookAheadMs = $1 }), range: 0...20, step: 0.5, unit: "ms", digits: 1)
            Toggle("True-Peak Guard", isOn: boolBinding({ $0.limiter.truePeakGuardEnabled }, { $0.limiter.truePeakGuardEnabled = $1 }))
        }
    }

    private var softClipperEditor: some View {
        moduleCard(module: .softClipper, enabled: boolBinding({ $0.softClipper.enabled }, { $0.softClipper.enabled = $1 }), reset: { preserveEnabledReset(\.softClipper, defaultValue: SoftClipperConfiguration()) }) {
            DynamicsParameterRow("Drive", value: doubleBinding({ $0.softClipper.driveDB }, { $0.softClipper.driveDB = $1 }), range: 0...12, step: 0.5, unit: "dB", digits: 1)
            DynamicsParameterRow("Threshold", value: doubleBinding({ $0.softClipper.thresholdDB }, { $0.softClipper.thresholdDB = $1 }), range: -6...0, step: 0.1, unit: "dB", digits: 1)
            DynamicsParameterRow("Knee", value: doubleBinding({ $0.softClipper.kneeSmooth }, { $0.softClipper.kneeSmooth = $1 }), range: 0...1, step: 0.01, unit: "", digits: 2)
            Picker("Curve", selection: binding({ $0.softClipper.curve }, { $0.softClipper.curve = $1 })) {
                ForEach(SoftClipperCurve.allCases) { curve in Text(curve.displayName).tag(curve) }
            }
            .pickerStyle(.menu)
            Toggle("Automatic Gain Compensation", isOn: boolBinding({ $0.softClipper.autoCompensateGain }, { $0.softClipper.autoCompensateGain = $1 }))
            DynamicsParameterRow("Asymmetry Trim", value: doubleBinding({ $0.softClipper.asymmetryTrimDB }, { $0.softClipper.asymmetryTrimDB = $1 }), range: -3...3, step: 0.1, unit: "dB", digits: 1)
        }
    }

    private var automaticHeadroomEditor: some View {
        moduleCard(module: .automaticHeadroom, enabled: boolBinding({ $0.automaticHeadroom.enabled }, { $0.automaticHeadroom.enabled = $1 }), reset: { preserveEnabledReset(\.automaticHeadroom, defaultValue: AutomaticHeadroomConfiguration()) }) {
            DynamicsParameterRow("Maximum Attenuation", value: doubleBinding({ $0.automaticHeadroom.maxAttenuationDB }, { $0.automaticHeadroom.maxAttenuationDB = $1 }), range: 3...24, step: 1, unit: "dB", digits: 0)
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
            DynamicsParameterRow("Amount", value: doubleBinding({ $0.deHarsh.amountDB }, { $0.deHarsh.amountDB = $1 }), range: -6...0, step: 0.1, unit: "dB", digits: 1)
            DynamicsParameterRow("Frequency", value: doubleBinding({ $0.deHarsh.frequencyHz }, { $0.deHarsh.frequencyHz = $1 }), range: 1_500...10_000, step: 50, unit: "Hz", digits: 0)
        }
    }

    private var stereoWidenerEditor: some View {
        moduleCard(module: .stereoWidener, enabled: boolBinding({ $0.stereoWidener.enabled }, { $0.stereoWidener.enabled = $1 }), reset: { preserveEnabledReset(\.stereoWidener, defaultValue: StereoWidenerConfiguration()) }) {
            Toggle("Mono Low Band", isOn: boolBinding({ $0.stereoWidener.monoLowBand }, { $0.stereoWidener.monoLowBand = $1 }))
            DynamicsParameterRow("Low Width", value: doubleBinding({ $0.stereoWidener.lowWidth }, { $0.stereoWidener.lowWidth = $1 }), range: 0...1, step: 0.01, unit: "×", digits: 2)
            DynamicsParameterRow("Low / Mid Crossover", value: doubleBinding({ $0.stereoWidener.lowMidFrequencyHz }, { $0.stereoWidener.lowMidFrequencyHz = $1 }), range: 80...500, step: 10, unit: "Hz", digits: 0)
            DynamicsParameterRow("Mid Width", value: doubleBinding({ $0.stereoWidener.midWidth }, { $0.stereoWidener.midWidth = $1 }), range: 1...2, step: 0.01, unit: "×", digits: 2)
            DynamicsParameterRow("Mid / High Crossover", value: doubleBinding({ $0.stereoWidener.midHighFrequencyHz }, { $0.stereoWidener.midHighFrequencyHz = $1 }), range: 1_500...8_000, step: 100, unit: "Hz", digits: 0)
            DynamicsParameterRow("High Width", value: doubleBinding({ $0.stereoWidener.highWidth }, { $0.stereoWidener.highWidth = $1 }), range: 1...2, step: 0.01, unit: "×", digits: 2)
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
                    Toggle("Enabled", isOn: enabled)
                        .toggleStyle(.switch)
                }
                Button("Reset", action: reset)
                    .buttonStyle(.glass)
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

    private func multibandBandEditor(
        title: String,
        threshold: Binding<Double>,
        ratio: Binding<Double>,
        attack: Binding<Double>,
        release: Binding<Double>,
        knee: Binding<Double>,
        makeup: Binding<Double>,
        sidechain: Binding<Double>,
        sidechainRange: ClosedRange<Double>
    ) -> some View {
        DisclosureGroup(title) {
            VStack(spacing: 10) {
                DynamicsParameterRow("Threshold", value: threshold, range: -60...0, step: 0.5, unit: "dB", digits: 1)
                DynamicsParameterRow("Ratio", value: ratio, range: 1...20, step: 0.5, unit: ":1", digits: 1)
                DynamicsParameterRow("Attack", value: attack, range: 1...200, step: 1, unit: "ms", digits: 0)
                DynamicsParameterRow("Release", value: release, range: 10...1_000, step: 10, unit: "ms", digits: 0)
                DynamicsParameterRow("Knee", value: knee, range: 0...20, step: 0.5, unit: "dB", digits: 1)
                DynamicsParameterRow("Makeup Gain", value: makeup, range: -12...12, step: 0.5, unit: "dB", digits: 1)
                DynamicsParameterRow("Sidechain High-Pass", value: sidechain, range: sidechainRange, step: sidechainRange.upperBound <= 300 ? 5 : 10, unit: "Hz", digits: 0)
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

    private func denoiserDoubleBinding(_ keyPath: WritableKeyPath<SpectralDenoiserConfiguration, Double>) -> Binding<Double> {
        denoiserBinding(
            { $0[keyPath: keyPath] },
            { config, value in config[keyPath: keyPath] = value; config.markCustom() }
        )
    }

    private func pauseGateDoubleBinding(_ keyPath: WritableKeyPath<PauseGateConfiguration, Double>) -> Binding<Double> {
        Binding(
            get: { engine.dynamicsConfiguration.pauseGate[keyPath: keyPath] },
            set: { value in
                update { config in
                    config.pauseGate[keyPath: keyPath] = value
                    config.pauseGate.markCustomIfNeeded()
                }
            }
        )
    }

    private var voiceGateSensitivityBinding: Binding<Double> {
        Binding(
            get: { configuration.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex },
            set: { value in
                update { config in
                    config.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex = value
                    config.dialogueRelativeLeveler.voiceGate.confidenceFloorIndex = max(0, value - 0.30)
                }
            }
        )
    }

    private func harmonicDepthBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { engine.dynamicsConfiguration.mainsNotch.harmonicDepthsDB[index] },
            set: { value in
                update { config in config.mainsNotch.harmonicDepthsDB[index] = value }
            }
        )
    }

    private func update(_ mutation: (inout DynamicsConfiguration) -> Void) {
        var updated = engine.dynamicsConfiguration
        mutation(&updated)
        try? engine.replaceDynamicsConfiguration(updated)
    }

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

private struct DynamicsParameterRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let digits: Int

    init(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        digits: Int
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.digits = digits
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 220)

                TextField(
                    title,
                    value: $value,
                    format: .number.precision(.fractionLength(digits))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 76)

                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 38, alignment: .leading)
                }
            }
        }
    }
}

private enum ProductionDynamicsGroup: String, CaseIterable, Identifiable {
    case dynamics
    case restoration
    case levelDialogue
    case protection
    case conditioning

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dynamics: return "DYNAMICS"
        case .restoration: return "RESTORATION"
        case .levelDialogue: return "LEVEL & DIALOGUE"
        case .protection: return "PROTECTION"
        case .conditioning: return "CONDITIONING"
        }
    }

    var modules: [ProductionDynamicsModule] {
        ProductionDynamicsModule.allCases.filter { $0.group == self }
    }
}

private enum ProductionDynamicsModule: String, CaseIterable, Identifiable, Hashable {
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

    var group: ProductionDynamicsGroup {
        switch self {
        case .compressor, .multiband, .expander, .pauseGate, .gainRider: return .dynamics
        case .denoiser, .deEsser, .mainsHum, .infrasonic: return .restoration
        case .loudnessMatch, .loudnessContour, .dialogueLeveler: return .levelDialogue
        case .limiter, .softClipper, .automaticHeadroom, .oversampling: return .protection
        case .deHarsh, .stereoWidener, .stereoMode, .dcOffset: return .conditioning
        }
    }

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
