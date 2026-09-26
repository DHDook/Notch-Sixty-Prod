import AppKit
import Combine
import Foundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: AudioIOEngine

    private var selectedUIDBinding: Binding<String?> {
        Binding(
            get: { engine.routeConfiguration.selectedOutputUID },
            set: { newValue in try? engine.selectOutput(uid: newValue) }
        )
    }

    private var eqBypassBinding: Binding<Bool> {
        Binding(get: { engine.eqConfiguration.bypassed }, set: { try? engine.setEQBypassed($0) })
    }

    private var eqPhaseModeBinding: Binding<EQPhaseMode> {
        Binding(get: { engine.eqConfiguration.phaseMode }, set: { try? engine.setEQPhaseMode($0) })
    }

    private var inputPreampBinding: Binding<Double> {
        Binding(get: { engine.gainConfiguration.inputPreampDB }, set: { try? engine.setInputPreampDB($0) })
    }

    private var headroomBinding: Binding<Double> {
        Binding(get: { engine.gainConfiguration.headroomAttenuationDB }, set: { try? engine.setHeadroomAttenuationDB($0) })
    }

    private var outputGainBinding: Binding<Double> {
        Binding(get: { engine.gainConfiguration.outputGainDB }, set: { try? engine.setOutputGainDB($0) })
    }

    private var eqChannelModeBinding: Binding<EQChannelMode> {
        Binding(get: { engine.stereoEQConfiguration.channelMode }, set: { try? engine.setEQChannelMode($0) })
    }

    private var eqEditChannelBinding: Binding<EQEditChannel> {
        Binding(get: { engine.stereoEQConfiguration.editChannel }, set: { engine.setEQEditChannel($0) })
    }

    private var balanceBinding: Binding<Double> {
        Binding(get: { engine.playbackControlConfiguration.balance }, set: { try? engine.setChannelBalance($0) })
    }

    private var interChannelDelayBinding: Binding<Double> {
        Binding(
            get: { engine.playbackControlConfiguration.interChannelDelayMs },
            set: { try? engine.setInterChannelDelayMs($0) }
        )
    }

    private var masterVolumeBinding: Binding<Double> {

        Binding(get: { engine.masterVolumeConfiguration.level }, set: { try? engine.setMasterVolumeLevel($0) })

    }


    private var masterMuteBinding: Binding<Bool> {

        Binding(get: { engine.masterVolumeConfiguration.muted }, set: { try? engine.setMasterMuted($0) })

    }

    private var globalVolumeKeyStatus: String {
        switch engine.globalVolumeKeyMonitoringState {
        case .stopped: return "Keys: Stopped"
        case .permissionRequired: return "Keys: Permission Required"
        case .active: return "Keys: Active"
        }
    }

    private var globalBypassBinding: Binding<Bool> {
        Binding(get: { engine.playbackControlConfiguration.globalBypassed }, set: { try? engine.setGlobalDSPBypassed($0) })
    }

    private var auditionModeBinding: Binding<AuditionMode> {
        Binding(get: { engine.playbackControlConfiguration.auditionMode }, set: { try? engine.setAuditionMode($0) })
    }

    private var crossoverEnabledBinding: Binding<Bool> { crossoverBinding(\.enabled) }
    private var crossoverFrequencyBinding: Binding<Double> { crossoverBinding(\.frequencyHz) }
    private var crossoverTopologyBinding: Binding<CrossoverTopology> { crossoverBinding(\.topology) }
    private var crossoverMonitorBinding: Binding<CrossoverMonitorMode> { crossoverBinding(\.monitorMode) }
    private var subGainBinding: Binding<Double> { crossoverBinding(\.subGainDB) }
    private var subPolarityBinding: Binding<Bool> { crossoverBinding(\.subPolarityInverted) }

    private var roomCorrectionEnabledBinding: Binding<Bool> {
        Binding(
            get: { engine.roomCorrectionConfiguration.enabled },
            set: { try? engine.setRoomCorrectionEnabled($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            Text("Notch Sixty")
                .font(.title.bold())

            Text("Production transport + minimum/linear EQ + gain/headroom + crossover + room-correction runtime validation")
                .foregroundStyle(.secondary)

            Picker("Output", selection: selectedUIDBinding) {
                Text("Choose an output…").tag(Optional<String>.none)
                ForEach(engine.outputDevices) { device in
                    Text("\(device.name) — \(formattedRate(device.nominalSampleRate))")
                        .tag(Optional(device.uid))
                }
            }
            .disabled(engine.lifecycleState != .idle)

            HStack {
                Button("Refresh Devices") { _ = try? engine.refreshOutputDevices() }
                    .disabled(engine.lifecycleState != .idle)

                if engine.lifecycleState == .idle {
                    Button("Start Processing") { try? engine.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(engine.selectedOutputDevice == nil)
                } else {
                    Button("Stop Processing") { engine.stop() }
                        .keyboardShortcut(.cancelAction)
                }
            }

            playbackValidationView
            gainValidationView
            dynamicsValidationView
            advancedDynamicsValidationView
            crossoverValidationView
            roomCorrectionValidationView
            eqValidationView

            Divider()

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                diagnosticsView(engine.diagnosticsSnapshot())
            }

            if let error = engine.lastErrorDescription {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            }
            .padding(20)
        }
        .frame(minWidth: 880, minHeight: 700)
        .onAppear { engine.prepareForUse() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            engine.shutdownForTermination()
        }
    }

    @ViewBuilder
    private var playbackValidationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stereo / playback validation").font(.headline)
                Spacer()
                Toggle("Global Bypass", isOn: globalBypassBinding).toggleStyle(.switch)
                Picker("Audition", selection: auditionModeBinding) {
                    ForEach(AuditionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            HStack(spacing: 12) {
                Text("Master").frame(width: 90, alignment: .leading)
                Slider(value: masterVolumeBinding, in: MasterVolumeConfiguration.levelRange, step: 0.01)
                Text("\(Int((engine.masterVolumeConfiguration.level * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                Toggle("Mute", isOn: masterMuteBinding).toggleStyle(.switch)
                Text(engine.masterVolumeCapabilities.controlMode == .device ? "Device" : "Software DSP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(globalVolumeKeyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("Balance").frame(width: 90, alignment: .leading)
                Text("L").foregroundStyle(.secondary)
                Slider(value: balanceBinding, in: PlaybackControlConfiguration.balanceRange, step: 0.01)
                Text("R").foregroundStyle(.secondary)
                Text(engine.playbackControlConfiguration.balance.formatted(.number.precision(.fractionLength(2))))
                    .monospacedDigit()
                    .frame(width: 55)
            }
            HStack(spacing: 12) {
                Text("L/R delay").frame(width: 90, alignment: .leading)
                Text("Delay L").foregroundStyle(.secondary)
                Slider(value: interChannelDelayBinding, in: PlaybackControlConfiguration.interChannelDelayRange, step: 0.01)
                Text("Delay R").foregroundStyle(.secondary)
                Text("\(engine.playbackControlConfiguration.interChannelDelayMs, specifier: "%+.2f") ms")
                    .monospacedDigit()
                    .frame(width: 84, alignment: .trailing)
            }
            Text("Signed speaker-alignment delay: negative delays Left; positive delays Right. Zero is transparent. Non-zero alignment uses a 2-frame common interpolation latency and fractional-sample phase-preserving timing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Processed runs the configured DSP. Reference is untreated input delayed to the processed-path latency. Delta is Processed − Reference. Global Bypass remains the true raw escape path.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var gainValidationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gain / headroom validation").font(.headline)
            gainControlRow(label: "Input preamp", value: inputPreampBinding, range: DSPGainConfiguration.inputPreampRange)
            gainControlRow(label: "Headroom attenuation", value: headroomBinding, range: DSPGainConfiguration.headroomAttenuationRange)
            gainControlRow(label: "Output gain", value: outputGainBinding, range: DSPGainConfiguration.outputGainRange)
            Text("Headroom attenuation remains a separate internal stage reserved for future automatic compensation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func gainControlRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 155, alignment: .leading)
            Slider(value: value, in: range, step: 0.5).frame(minWidth: 280)
            TextField("dB", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Text("dB").foregroundStyle(.secondary)
        }
    }

    private func dynamicsBinding<Value>(_ keyPath: WritableKeyPath<DynamicsConfiguration, Value>) -> Binding<Value> {
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
        let compressorTopology = dynamicsBinding(\.compressor.topology)
        let compressorProgramRelease = dynamicsBinding(\.compressor.programDependentRelease)
        let compressorSidechainHPF = dynamicsBinding(\.compressor.sidechainHighPassHz)
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
                Text("Comp detector").frame(width: 90, alignment: .leading)
                Picker("Topology", selection: compressorTopology) {
                    ForEach(CompressorTopology.allCases) { topology in Text(topology.displayName).tag(topology) }
                }.frame(width: 190)
                Toggle("Program-dependent release", isOn: compressorProgramRelease).toggleStyle(.switch)
                Text("Sidechain HPF")
                Slider(value: compressorSidechainHPF, in: CompressorConfiguration.sidechainHighPassRange, step: 5).frame(width: 140)
                Text("\(engine.dynamicsConfiguration.compressor.sidechainHighPassHz, specifier: "%.0f") Hz").monospacedDigit().frame(width: 62)
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

            Text("Compressor and Expander are linked-stereo. PR32 adds feed-forward/feed-back detector topology, program-dependent release, and detector-only sidechain HPF. Pause Gate uses Attack for fade-out and Release for fade-in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
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

        let dialogueEnabled = dynamicsBinding(\.dialogueRelativeLeveler.enabled)
        let dialogueVoiceGate = dynamicsBinding(\.dialogueRelativeLeveler.voiceGate.enabled)
        let dialogueLow = dynamicsBinding(\.dialogueRelativeLeveler.bandLowHz)
        let dialogueHigh = dynamicsBinding(\.dialogueRelativeLeveler.bandHighHz)
        let dialogueGap = dynamicsBinding(\.dialogueRelativeLeveler.targetGapDB)
        let dialogueRatio = dynamicsBinding(\.dialogueRelativeLeveler.boostRatio)
        let dialogueMaxBoost = dynamicsBinding(\.dialogueRelativeLeveler.maxBoostDB)
        let dialogueDetector = dynamicsBinding(\.dialogueRelativeLeveler.detectorWindowMs)
        let dialogueAttack = dynamicsBinding(\.dialogueRelativeLeveler.attackMs)
        let dialogueRelease = dynamicsBinding(\.dialogueRelativeLeveler.releaseMs)
        let dialogueProgramGate = dynamicsBinding(\.dialogueRelativeLeveler.programGateThresholdDB)
        let voiceCenter = dynamicsBinding(\.dialogueRelativeLeveler.voiceGate.modulationCenterHz)
        let voiceBandwidth = dynamicsBinding(\.dialogueRelativeLeveler.voiceGate.modulationBandwidthHz)
        let voiceEnvelopeWindow = dynamicsBinding(\.dialogueRelativeLeveler.voiceGate.envelopeWindowMs)
        let voiceMeasurementWindow = dynamicsBinding(\.dialogueRelativeLeveler.voiceGate.measurementWindowMs)
        let voiceConfidenceFloor = dynamicsBinding(\.dialogueRelativeLeveler.voiceGate.confidenceFloorIndex)
        let voiceConfidenceCeiling = dynamicsBinding(\.dialogueRelativeLeveler.voiceGate.confidenceCeilingIndex)
        let voiceMinimumConfidence = dynamicsBinding(\.dialogueRelativeLeveler.voiceGate.minConfidence)

        let deEsserEnabled = dynamicsBinding(\.deEsser.enabled)
        let deEsserFrequency = dynamicsBinding(\.deEsser.frequencyHz)
        let deEsserThreshold = dynamicsBinding(\.deEsser.thresholdDB)
        let deEsserRatio = dynamicsBinding(\.deEsser.ratio)
        let deEsserRange = dynamicsBinding(\.deEsser.rangeDB)
        let deEsserQ = dynamicsBinding(\.deEsser.detectionQ)
        let deEsserAttack = dynamicsBinding(\.deEsser.attackMs)
        let deEsserRelease = dynamicsBinding(\.deEsser.releaseMs)
        let deEsserDynamicEQ = dynamicsBinding(\.deEsser.dynamicEQMode)

        let multibandEnabled = dynamicsBinding(\.multibandCompressor.enabled)
        let multibandLowMid = dynamicsBinding(\.multibandCompressor.lowMidFrequencyHz)
        let multibandMidHigh = dynamicsBinding(\.multibandCompressor.midHighFrequencyHz)
        let multibandLowSlope = dynamicsBinding(\.multibandCompressor.lowMidSlope)
        let multibandHighSlope = dynamicsBinding(\.multibandCompressor.midHighSlope)
        let multibandLowThreshold = dynamicsBinding(\.multibandCompressor.lowThresholdDB)
        let multibandMidThreshold = dynamicsBinding(\.multibandCompressor.midThresholdDB)
        let multibandHighThreshold = dynamicsBinding(\.multibandCompressor.highThresholdDB)
        let multibandLowRatio = dynamicsBinding(\.multibandCompressor.lowRatio)
        let multibandMidRatio = dynamicsBinding(\.multibandCompressor.midRatio)
        let multibandHighRatio = dynamicsBinding(\.multibandCompressor.highRatio)
        let multibandLowAttack = dynamicsBinding(\.multibandCompressor.lowAttackMs)
        let multibandMidAttack = dynamicsBinding(\.multibandCompressor.midAttackMs)
        let multibandHighAttack = dynamicsBinding(\.multibandCompressor.highAttackMs)
        let multibandLowRelease = dynamicsBinding(\.multibandCompressor.lowReleaseMs)
        let multibandMidRelease = dynamicsBinding(\.multibandCompressor.midReleaseMs)
        let multibandHighRelease = dynamicsBinding(\.multibandCompressor.highReleaseMs)
        let multibandLowKnee = dynamicsBinding(\.multibandCompressor.lowKneeDB)
        let multibandMidKnee = dynamicsBinding(\.multibandCompressor.midKneeDB)
        let multibandHighKnee = dynamicsBinding(\.multibandCompressor.highKneeDB)
        let multibandLowSC = dynamicsBinding(\.multibandCompressor.lowSidechainHighPassHz)
        let multibandMidSC = dynamicsBinding(\.multibandCompressor.midSidechainHighPassHz)
        let multibandHighSC = dynamicsBinding(\.multibandCompressor.highSidechainHighPassHz)
        let multibandLowMakeup = dynamicsBinding(\.multibandCompressor.lowMakeupGainDB)
        let multibandMidMakeup = dynamicsBinding(\.multibandCompressor.midMakeupGainDB)
        let multibandHighMakeup = dynamicsBinding(\.multibandCompressor.highMakeupGainDB)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Advanced dynamics validation").font(.headline)
                Spacer()
                Text("PR28 + PR29 + PR32")
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
                Text("\(engine.dynamicsConfiguration.stereoWidener.lowWidth, specifier: "%.2f")×").monospacedDigit().frame(width: 52)
                Text("Mid")
                Slider(value: midWidth, in: StereoWidenerConfiguration.midWidthRange, step: 0.05).frame(width: 115)
                Text("\(engine.dynamicsConfiguration.stereoWidener.midWidth, specifier: "%.2f")×").monospacedDigit().frame(width: 52)
                Text("High")
                Slider(value: highWidth, in: StereoWidenerConfiguration.highWidthRange, step: 0.05).frame(width: 115)
                Text("\(engine.dynamicsConfiguration.stereoWidener.highWidth, specifier: "%.2f")×").monospacedDigit().frame(width: 52)
            }

            HStack(spacing: 10) {
                Text("Width xovers").frame(width: 90, alignment: .leading)
                Text("Low/Mid")
                Slider(value: lowMidWidthXover, in: StereoWidenerConfiguration.lowMidFrequencyRange, step: 10).frame(width: 170)
                Text("\(engine.dynamicsConfiguration.stereoWidener.lowMidFrequencyHz, specifier: "%.0f") Hz").monospacedDigit().frame(width: 72)
                Text("Mid/High")
                Slider(value: midHighWidthXover, in: StereoWidenerConfiguration.midHighFrequencyRange, step: 100).frame(width: 170)
                Text("\(engine.dynamicsConfiguration.stereoWidener.midHighFrequencyHz, specifier: "%.0f") Hz").monospacedDigit().frame(width: 78)
            }

            Divider()

            HStack(spacing: 14) {
                Toggle("DC Offset Filter", isOn: dcEnabled).toggleStyle(.switch)
                Toggle("Infrasonic", isOn: infrasonicEnabled).toggleStyle(.switch)
                Text("Cutoff")
                Slider(value: infrasonicCutoff, in: InfrasonicFilterConfiguration.cutoffRange, step: 1).frame(width: 150)
                Text("\(engine.dynamicsConfiguration.infrasonicFilter.cutoffHz, specifier: "%.0f") Hz").monospacedDigit().frame(width: 58)
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
                Text("\(engine.dynamicsConfiguration.loudnessMatch.targetLUFS, specifier: "%.1f") LUFS").monospacedDigit().frame(width: 86)
                Text("Max")
                Slider(value: loudnessMaxCorrection, in: LoudnessMatchConfiguration.maxCorrectionRange, step: 1).frame(width: 110)
                Text("±\(engine.dynamicsConfiguration.loudnessMatch.maxCorrectionDB, specifier: "%.0f") dB").monospacedDigit().frame(width: 58)
            }

            HStack(spacing: 10) {
                Text("LUFS timing").frame(width: 90, alignment: .leading)
                Text("Attack")
                Slider(value: loudnessAttack, in: LoudnessMatchConfiguration.attackRange, step: 0.1).frame(width: 145)
                Text("\(engine.dynamicsConfiguration.loudnessMatch.attackSeconds, specifier: "%.1f") s").monospacedDigit().frame(width: 50)
                Text("Release")
                Slider(value: loudnessRelease, in: LoudnessMatchConfiguration.releaseRange, step: 0.1).frame(width: 145)
                Text("\(engine.dynamicsConfiguration.loudnessMatch.releaseSeconds, specifier: "%.1f") s").monospacedDigit().frame(width: 50)
            }

            HStack(spacing: 12) {
                Toggle("Volume-aware Loudness Contour", isOn: contourEnabled).toggleStyle(.switch)
                Text("Max strength")
                Slider(value: contourStrength, in: LoudnessContourConfiguration.strengthRange, step: 0.05).frame(width: 180)
                Text("\(engine.dynamicsConfiguration.loudnessContour.strength, specifier: "%.2f")").monospacedDigit().frame(width: 46)
                Text("Contour automatically backs off as master volume rises.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                HStack(spacing: 16) {
                    Text("Short-term: \(diagnostics?.loudnessShortTermLUFS ?? -120, specifier: "%.1f") LUFS")
                    Text("Match gain: \(diagnostics?.loudnessMatchGainDB ?? 0, specifier: "%+.2f") dB")
                    Text("Contour: \((diagnostics?.loudnessContourScale ?? 0) * 100, specifier: "%.0f")%")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Toggle("Dialogue-Relative Leveler", isOn: dialogueEnabled).toggleStyle(.switch)
                Toggle("Voice confidence gate", isOn: dialogueVoiceGate).toggleStyle(.switch)
                Text("Band")
                TextField("Low", value: dialogueLow, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("–")
                TextField("High", value: dialogueHigh, format: .number).frame(width: 66).textFieldStyle(.roundedBorder)
                Text("Hz")
                Text("Target gap")
                Slider(value: dialogueGap, in: DialogueRelativeLevelerConfiguration.targetGapRange, step: 0.5).frame(width: 110)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.targetGapDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 62)
            }
            HStack(spacing: 10) {
                Text("Dialogue gain").frame(width: 90, alignment: .leading)
                Text("Ratio")
                Slider(value: dialogueRatio, in: DialogueRelativeLevelerConfiguration.boostRatioRange, step: 0.1).frame(width: 110)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.boostRatio, specifier: "%.1f"):1").monospacedDigit().frame(width: 48)
                Text("Max boost")
                Slider(value: dialogueMaxBoost, in: DialogueRelativeLevelerConfiguration.maxBoostRange, step: 0.5).frame(width: 110)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.maxBoostDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 60)
                Text("Program gate")
                Slider(value: dialogueProgramGate, in: DialogueRelativeLevelerConfiguration.programGateRange, step: 1).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.programGateThresholdDB, specifier: "%.0f") dBFS").monospacedDigit().frame(width: 68)
            }
            HStack(spacing: 10) {
                Text("Dialogue time").frame(width: 90, alignment: .leading)
                Text("Detector")
                Slider(value: dialogueDetector, in: DialogueRelativeLevelerConfiguration.detectorWindowRange, step: 10).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.detectorWindowMs, specifier: "%.0f") ms").monospacedDigit().frame(width: 58)
                Text("Attack")
                Slider(value: dialogueAttack, in: DialogueRelativeLevelerConfiguration.attackRange, step: 10).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.attackMs, specifier: "%.0f")").monospacedDigit().frame(width: 44)
                Text("Release")
                Slider(value: dialogueRelease, in: DialogueRelativeLevelerConfiguration.releaseRange, step: 25).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.dialogueRelativeLeveler.releaseMs, specifier: "%.0f") ms").monospacedDigit().frame(width: 58)
            }
            if engine.dynamicsConfiguration.dialogueRelativeLeveler.voiceGate.enabled {
                HStack(spacing: 8) {
                    Text("Voice gate").frame(width: 90, alignment: .leading)
                    Text("Center"); TextField("Hz", value: voiceCenter, format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                    Text("BW"); TextField("Hz", value: voiceBandwidth, format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                    Text("Env ms"); TextField("ms", value: voiceEnvelopeWindow, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                    Text("Measure ms"); TextField("ms", value: voiceMeasurementWindow, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                    Text("Floor"); TextField("", value: voiceConfidenceFloor, format: .number.precision(.fractionLength(2))).frame(width: 54).textFieldStyle(.roundedBorder)
                    Text("Ceil"); TextField("", value: voiceConfidenceCeiling, format: .number.precision(.fractionLength(2))).frame(width: 54).textFieldStyle(.roundedBorder)
                    Text("Min"); TextField("", value: voiceMinimumConfidence, format: .number.precision(.fractionLength(2))).frame(width: 54).textFieldStyle(.roundedBorder)
                }
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let d = engine.diagnosticsSnapshot().renderKernelDiagnostics
                HStack(spacing: 14) {
                    Text("Program: \(d?.dialogueProgramLevelDBFS ?? -120, specifier: "%.1f") dBFS")
                    Text("Dialogue band: \(d?.dialogueBandLevelDBFS ?? -120, specifier: "%.1f")")
                    Text("Gap: \(d?.dialogueGapDB ?? 0, specifier: "%.1f") dB")
                    Text("Voice: \((d?.dialogueVoiceConfidence ?? 1) * 100, specifier: "%.0f")%")
                    Text("Boost: \(d?.dialogueBoostDB ?? 0, specifier: "%+.2f") dB")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Toggle("De-Esser", isOn: deEsserEnabled).toggleStyle(.switch)
                Toggle("Dynamic EQ", isOn: deEsserDynamicEQ).toggleStyle(.switch)
                Text("Frequency")
                Slider(value: deEsserFrequency, in: DeEsserConfiguration.frequencyRange, step: 100).frame(width: 150)
                Text("\(engine.dynamicsConfiguration.deEsser.frequencyHz, specifier: "%.0f") Hz").monospacedDigit().frame(width: 76)
                Text("Threshold")
                Slider(value: deEsserThreshold, in: DeEsserConfiguration.thresholdRange, step: 0.5).frame(width: 140)
                Text("\(engine.dynamicsConfiguration.deEsser.thresholdDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 68)
            }

            HStack(spacing: 10) {
                Text("De-Esser depth").frame(width: 90, alignment: .leading)
                Text("Ratio")
                Slider(value: deEsserRatio, in: DeEsserConfiguration.ratioRange, step: 0.5).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.deEsser.ratio, specifier: "%.1f")").monospacedDigit().frame(width: 42)
                Text("Max cut")
                Slider(value: deEsserRange, in: DeEsserConfiguration.rangeRange, step: 0.5).frame(width: 100)
                Text("\(engine.dynamicsConfiguration.deEsser.rangeDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 60)
                Text("Q")
                Slider(value: deEsserQ, in: DeEsserConfiguration.detectionQRange, step: 0.1).frame(width: 90)
                Text("\(engine.dynamicsConfiguration.deEsser.detectionQ, specifier: "%.1f")").monospacedDigit().frame(width: 38)
                Text("A/R")
                TextField("A", value: deEsserAttack, format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                TextField("R", value: deEsserRelease, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                Text("ms").foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Toggle("3-band Multiband", isOn: multibandEnabled).toggleStyle(.switch)
                Text("Low/Mid")
                Slider(value: multibandLowMid, in: MultibandCompressorConfiguration.lowMidFrequencyRange, step: 5).frame(width: 125)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.lowMidFrequencyHz, specifier: "%.0f") Hz").monospacedDigit().frame(width: 70)
                Text("Mid/High")
                Slider(value: multibandMidHigh, in: MultibandCompressorConfiguration.midHighFrequencyRange, step: 100).frame(width: 125)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.midHighFrequencyHz, specifier: "%.0f") Hz").monospacedDigit().frame(width: 76)
                Picker("Low slope", selection: multibandLowSlope) {
                    ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                }.frame(width: 160)
                Picker("High slope", selection: multibandHighSlope) {
                    ForEach(MultibandSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                }.frame(width: 160)
            }

            HStack(spacing: 10) {
                Text("MB thresholds").frame(width: 90, alignment: .leading)
                Text("Low")
                Slider(value: multibandLowThreshold, in: MultibandCompressorConfiguration.thresholdRange, step: 0.5).frame(width: 120)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.lowThresholdDB, specifier: "%.1f")").monospacedDigit().frame(width: 50)
                Text("Mid")
                Slider(value: multibandMidThreshold, in: MultibandCompressorConfiguration.thresholdRange, step: 0.5).frame(width: 120)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.midThresholdDB, specifier: "%.1f")").monospacedDigit().frame(width: 50)
                Text("High")
                Slider(value: multibandHighThreshold, in: MultibandCompressorConfiguration.thresholdRange, step: 0.5).frame(width: 120)
                Text("\(engine.dynamicsConfiguration.multibandCompressor.highThresholdDB, specifier: "%.1f") dB").monospacedDigit().frame(width: 64)
            }

            HStack(spacing: 8) {
                Text("MB ratios").frame(width: 90, alignment: .leading)
                Text("L"); Slider(value: multibandLowRatio, in: MultibandCompressorConfiguration.ratioRange, step: 0.5).frame(width: 90); Text("\(engine.dynamicsConfiguration.multibandCompressor.lowRatio, specifier: "%.1f")")
                Text("M"); Slider(value: multibandMidRatio, in: MultibandCompressorConfiguration.ratioRange, step: 0.5).frame(width: 90); Text("\(engine.dynamicsConfiguration.multibandCompressor.midRatio, specifier: "%.1f")")
                Text("H"); Slider(value: multibandHighRatio, in: MultibandCompressorConfiguration.ratioRange, step: 0.5).frame(width: 90); Text("\(engine.dynamicsConfiguration.multibandCompressor.highRatio, specifier: "%.1f")")
            }
            HStack(spacing: 8) {
                Text("MB attack").frame(width: 90, alignment: .leading)
                TextField("L", value: multibandLowAttack, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidAttack, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighAttack, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                Text("ms   release")
                TextField("L", value: multibandLowRelease, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidRelease, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighRelease, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                Text("ms")
            }
            HStack(spacing: 8) {
                Text("MB knee").frame(width: 90, alignment: .leading)
                TextField("L", value: multibandLowKnee, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidKnee, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighKnee, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                Text("dB   sidechain HPF")
                TextField("L", value: multibandLowSC, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidSC, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighSC, format: .number).frame(width: 64).textFieldStyle(.roundedBorder)
                Text("Hz")
            }
            HStack(spacing: 8) {
                Text("MB makeup").frame(width: 90, alignment: .leading)
                TextField("L", value: multibandLowMakeup, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("M", value: multibandMidMakeup, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                TextField("H", value: multibandHighMakeup, format: .number).frame(width: 58).textFieldStyle(.roundedBorder)
                Text("dB (linked stereo per band)").font(.caption).foregroundStyle(.secondary)
            }

            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
                HStack(spacing: 16) {
                    Text("De-Esser GR: \(diagnostics?.deEsserGainReductionDB ?? 0, specifier: "%.2f") dB")
                    Text("MB Low: \(diagnostics?.multibandLowGainReductionDB ?? 0, specifier: "%.2f") dB")
                    Text("Mid: \(diagnostics?.multibandMidGainReductionDB ?? 0, specifier: "%.2f") dB")
                    Text("High: \(diagnostics?.multibandHighGainReductionDB ?? 0, specifier: "%.2f") dB")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text("PR32 validation adds the legacy control depth for Compressor, De-Esser and Multiband plus the independently authored Dialogue-Relative Leveler. Defaults preserve the already accepted commercial behavior unless a PR32 control is deliberately changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var crossoverValidationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bass management / crossover validation").font(.headline)
                Spacer()
                Toggle("Enable", isOn: crossoverEnabledBinding).toggleStyle(.switch)
            }

            HStack(spacing: 12) {
                Text("Crossover").frame(width: 90, alignment: .leading)
                Slider(value: crossoverFrequencyBinding, in: BassManagementConfiguration.frequencyRange, step: 1)
                TextField("Hz", value: crossoverFrequencyBinding, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("Hz").foregroundStyle(.secondary)

                Picker("Topology", selection: crossoverTopologyBinding) {
                    ForEach(CrossoverTopology.allCases) { topology in
                        Text(topology.displayName).tag(topology)
                    }
                }
                .frame(width: 210)

                Picker("Monitor", selection: crossoverMonitorBinding) {
                    ForEach(CrossoverMonitorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .frame(width: 175)
            }

            HStack(spacing: 12) {
                Text("Sub gain").frame(width: 90, alignment: .leading)
                Slider(value: subGainBinding, in: BassManagementConfiguration.subGainRange, step: 0.5)
                TextField("dB", value: subGainBinding, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("dB").foregroundStyle(.secondary)
                Toggle("Invert sub polarity", isOn: subPolarityBinding)
                    .toggleStyle(.switch)
            }

            Text("PR #16 exposes logical mains and mono-sub buses through stereo audition modes. It does not yet create an independently routable physical sub output.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func crossoverBinding<Value>(_ keyPath: WritableKeyPath<BassManagementConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: { engine.bassManagementConfiguration[keyPath: keyPath] },
            set: { value in
                var updated = engine.bassManagementConfiguration
                updated[keyPath: keyPath] = value
                try? engine.replaceBassManagementConfiguration(updated)
            }
        )
    }

    @ViewBuilder
    private var roomCorrectionValidationView: some View {
        let filter = engine.roomCorrectionConfiguration.filter
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Room correction runtime validation").font(.headline)
                Spacer()
                Button("Load 3-Tap Validation FIR") {
                    try? engine.loadRoomCorrectionValidationFilter()
                }
                Toggle("Enable", isOn: roomCorrectionEnabledBinding)
                    .toggleStyle(.switch)
                    .disabled(filter == nil)
            }

            if let filter {
                Text("Loaded: \(filter.name) — \(filter.leftTaps.count) taps / declared latency \(filter.declaredLatencyFrames) frame\(filter.declaredLatencyFrames == 1 ? "" : "s")")
                    .font(.caption)
            } else {
                Text("No room-correction FIR loaded. The PR #20 runtime remains bypassed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The validation FIR [0.25, 0.50, 0.25] is deliberately not an acoustic correction. It provides an audible, deterministic end-to-end hardware check of the dedicated room-correction control and convolution path before measurement/filter design exists.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var eqValidationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Parametric EQ validation").font(.headline)
                Text("\(engine.eqConfiguration.enabledBandCount) active / \(engine.eqConfiguration.bands.count) configured / \(EQConfiguration.maximumBandCount) max")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Channels", selection: eqChannelModeBinding) {
                    ForEach(EQChannelMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                if engine.stereoEQConfiguration.channelMode == .independent {
                    Picker("Edit", selection: eqEditChannelBinding) {
                        Text("Left").tag(EQEditChannel.left)
                        Text("Right").tag(EQEditChannel.right)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                Picker("Phase", selection: eqPhaseModeBinding) {
                    ForEach(EQPhaseMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                Toggle("Bypass EQ", isOn: eqBypassBinding).toggleStyle(.switch)
                Button("Add Band") { try? engine.addEQBand() }
                    .disabled(engine.eqConfiguration.bands.count >= EQConfiguration.maximumBandCount)
                Button("Load 64-Band Stress") { load64BandStressConfiguration() }
            }

            if engine.eqConfiguration.phaseMode == .linearPhase {
                if let design = engine.linearPhaseDesignInfo {
                    Text("Linear FIR: \(design.tapCount) taps / group delay \(design.groupDelayMilliseconds.formatted(.number.precision(.fractionLength(2)))) ms / total \(formattedDSPTime(frames: design.totalLatencyFrames, sampleRate: currentDSPRate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Linear FIR will be designed for the active device sample rate when processing starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if engine.eqConfiguration.bands.isEmpty {
                Text("No EQ bands configured. Add a band to validate live graph publication.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(engine.eqConfiguration.bands.enumerated()), id: \.element.id) { index, band in
                            eqBandRow(index: index, band: band)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var currentDSPRate: Double {
        engine.diagnosticsSnapshot().renderKernelDiagnostics?.sampleRate
            ?? engine.selectedOutputDevice?.nominalSampleRate
            ?? 48_000
    }

    @ViewBuilder
    private func eqBandRow(index: Int, band: EQBand) -> some View {
        let binding = eqBandBinding(for: band.id)
        HStack(spacing: 8) {
            Text("\(index + 1)").frame(width: 24, alignment: .trailing).foregroundStyle(.secondary)
            Toggle("", isOn: binding.enabled).labelsHidden()
            Picker("", selection: binding.type) {
                ForEach(EQFilterType.allCases) { type in Text(type.displayName).tag(type) }
            }
            .labelsHidden()
            .frame(width: 115)
            TextField("Hz", value: binding.frequencyHz, format: .number.precision(.fractionLength(0...1))).frame(width: 85)
            Text("Hz").foregroundStyle(.secondary)
            TextField("dB", value: binding.gainDB, format: .number.precision(.fractionLength(1))).frame(width: 65)
            Text("dB (±24 max)").font(.caption).foregroundStyle(.secondary)
            TextField("Q", value: binding.q, format: .number.precision(.fractionLength(2...3))).frame(width: 65)
            Text("Q").foregroundStyle(.secondary)
            Spacer()
            Button("Remove") { try? engine.removeEQBand(id: band.id) }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func eqBandBinding(for id: UUID) -> Binding<EQBand> {
        Binding(
            get: { engine.eqConfiguration.bands.first(where: { $0.id == id }) ?? EQBand(id: id, enabled: false) },
            set: { updated in
                guard updated.gainDB.isFinite else { return }
                var sanitized = updated
                sanitized.gainDB = min(
                    max(updated.gainDB, StereoEQConfiguration.bandGainRange.lowerBound),
                    StereoEQConfiguration.bandGainRange.upperBound
                )
                try? engine.updateEQBand(sanitized)
            }
        )
    }

    private func load64BandStressConfiguration() {
        let count = EQConfiguration.maximumBandCount
        let minimumFrequency = 30.0
        let maximumFrequency = 18_000.0
        let ratio = maximumFrequency / minimumFrequency
        let bands = (0..<count).map { index -> EQBand in
            let position = count > 1 ? Double(index) / Double(count - 1) : 0
            let frequency = minimumFrequency * pow(ratio, position)
            return EQBand(
                enabled: true,
                type: .peaking,
                frequencyHz: frequency,
                gainDB: index.isMultiple(of: 2) ? 0.25 : -0.25,
                q: 1.0
            )
        }
        try? engine.replaceEQConfiguration(
            EQConfiguration(
                phaseMode: engine.eqConfiguration.phaseMode,
                bypassed: false,
                bands: bands
            )
        )
    }

    @ViewBuilder
    private func diagnosticsView(_ snapshot: AudioDiagnosticsSnapshot) -> some View {
        let session = snapshot.sessionTransportCounters
        let lifetime = snapshot.lifetimeTransportCounters

        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            diagnosticRow("State", snapshot.lifecycleState.rawValue)
            diagnosticRow("Selected output", snapshot.selectedOutputName ?? "—")
            diagnosticRow("Tap rate", snapshot.tapSampleRate.map(formattedRate) ?? "—")
            diagnosticRow("Output rate", snapshot.outputSampleRate.map(formattedRate) ?? "—")

            if let gateOpened = snapshot.startupGateOpened,
               let targetFrames = snapshot.startupGateTargetFrames,
               let activationFrames = snapshot.startupGateActivationFrames {
                diagnosticRow("Startup gate", "\(gateOpened ? "open" : "armed") / target \(targetFrames) / activate \(activationFrames)")
            }

            if let render = snapshot.renderKernelDiagnostics {
                diagnosticRow("DSP graph", "generation \(render.publishedGeneration) / \(render.bypassed ? "bypassed" : "active")")
                diagnosticRow("DSP rate", formattedRate(render.sampleRate))
                diagnosticRow("DSP latency", formattedDSPTime(frames: render.latencyFrames, sampleRate: render.sampleRate))
                diagnosticRow("Input preamp", formattedGain(render.inputGainLinear))
                diagnosticRow("Headroom stage", formattedGain(render.headroomGainLinear))
                diagnosticRow("Output gain", formattedGain(render.outputGainLinear))
                diagnosticRow("Balance gains", "L \(formattedGain(render.balanceGainLeftLinear)) / R \(formattedGain(render.balanceGainRightLinear))")
                diagnosticRow("EQ mode", engine.stereoEQConfiguration.phaseMode.displayName)
                diagnosticRow("EQ channels", "\(engine.stereoEQConfiguration.channelMode.displayName) / L \(render.eqLeftBandCount) / R \(render.eqRightBandCount)")
                diagnosticRow("EQ stage", "\(render.eqBypassed ? "bypassed" : "active") / \(render.eqBandCount) IIR bands")
                diagnosticRow(
                    "Linear FIR",
                    render.convolutionEnabled
                        ? "active / slot \(render.convolutionProgramSlot) / gen \(render.convolutionProgramGeneration) / \(render.convolutionTapCount) taps / \(render.convolutionPartitionCount) partitions"
                        : "bypassed"
                )
                if render.convolutionEnabled {
                    diagnosticRow(
                        "FIR latency",
                        "engine \(formattedDSPTime(frames: render.convolutionEngineLatencyFrames, sampleRate: render.sampleRate)) / group \(formattedDSPTime(frames: render.convolutionDeclaredLatencyFrames, sampleRate: render.sampleRate))"
                    )
                }
                diagnosticRow(
                    "Crossover",
                    render.crossoverEnabled
                        ? "active / \(render.crossoverFrequencyHz.formatted(.number.precision(.fractionLength(0)))) Hz / \(crossoverTopologyName(render.crossoverTopology)) / \(crossoverMonitorName(render.crossoverMonitorMode)) / \(render.crossoverSectionCount) sections"
                        : "bypassed"
                )
                diagnosticRow("Sub polarity", render.crossoverSubPolarityInverted ? "inverted" : "normal")
                diagnosticRow("Sub gain", formattedGain(render.crossoverSubGainLinear))
                diagnosticRow(
                    "Room FIR",
                    render.roomCorrectionEnabled
                        ? "active / slot \(render.roomCorrectionProgramSlot) / gen \(render.roomCorrectionProgramGeneration) / \(render.roomCorrectionTapCount) taps / \(render.roomCorrectionPartitionCount) partitions"
                        : "bypassed"
                )
                if render.roomCorrectionEnabled {
                    diagnosticRow(
                        "Room FIR latency",
                        "engine \(formattedDSPTime(frames: render.roomCorrectionEngineLatencyFrames, sampleRate: render.sampleRate)) / filter \(formattedDSPTime(frames: render.roomCorrectionDeclaredLatencyFrames, sampleRate: render.sampleRate))"
                    )
                }
                meterRow("Input meter", render.inputMeter)
                meterRow("Post-EQ meter", render.postEQMeter)
                meterRow("DSP output meter", render.outputMeter)
                diagnosticRow("DSP rendered frames", "\(render.renderedFrames)")
                diagnosticRow("DSP non-finite sanitized", "\(render.sanitizedNonFiniteSamples)")
                diagnosticRow("DSP denormals flushed", "\(render.flushedDenormalSamples)")
                diagnosticRow("DSP snapshot read misses", "\(render.snapshotReadMisses)")
                diagnosticRow("FIR program misses", "\(render.convolutionProgramMisses)")
                diagnosticRow("Room FIR program misses", "\(render.roomCorrectionProgramMisses)")
            }

            diagnosticRow("Counter scope", "current processing session")
            diagnosticRow("Capture callbacks", "\(session.captureCallbacks)")
            diagnosticRow("Output callbacks", "\(session.outputCallbacks)")
            diagnosticRow("Gated output callbacks", "\(session.gatedOutputCallbacks)")
            diagnosticRow("Gated output frames", "\(session.gatedOutputFrames)")
            diagnosticRow("Captured frames", "\(session.capturedFrames)")
            diagnosticRow("Delivered frames", "\(session.deliveredFrames)")
            diagnosticRow("Underrun frames", "\(session.underrunFrames)")
            diagnosticRow("Overrun frames", "\(session.overrunFrames)")
            diagnosticRow("Buffered frames", "\(session.bufferedFrames)")
            diagnosticRow("Bridge queue", formattedBridgeQueue(frames: session.bufferedFrames, sampleRate: snapshot.outputSampleRate))
            diagnosticRow("Lifetime underruns", "\(lifetime.underrunFrames)")
            diagnosticRow("Lifetime overruns", "\(lifetime.overrunFrames)")
            diagnosticRow("Rate rebuilds", "\(snapshot.sampleRateChangesHandled)")
            diagnosticRow("Recovery", "\(snapshot.recoverySuccesses) success / \(snapshot.recoveryFailures) retry errors / \(snapshot.recoveryAttempts) attempts")
        }
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    @ViewBuilder
    private func meterRow(_ label: String, _ meter: StereoMeterReading) -> some View {
        diagnosticRow(
            label,
            "peak L \(formattedLevel(meter.peakLeft)) / R \(formattedLevel(meter.peakRight)) | RMS L \(formattedLevel(meter.rmsLeft)) / R \(formattedLevel(meter.rmsRight)) | over-range \(meter.overRangeSamples)"
        )
    }

    private func crossoverTopologyName(_ topology: N60CrossoverTopology) -> String {
        switch topology {
        case N60CrossoverTopologyLinkwitzRiley48: return "LR48"
        default: return "LR24"
        }
    }

    private func crossoverMonitorName(_ mode: N60CrossoverMonitorMode) -> String {
        switch mode {
        case N60CrossoverMonitorModeMainsOnly: return "mains"
        case N60CrossoverMonitorModeSubOnly: return "sub"
        default: return "recombined"
        }
    }

    private func formattedRate(_ rate: Double) -> String {
        if rate >= 1_000 { return String(format: "%.1f kHz", rate / 1_000) }
        return String(format: "%.0f Hz", rate)
    }

    private func formattedBridgeQueue(frames: UInt32, sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate > 0 else { return "\(frames) frames" }
        return String(format: "%u frames / %.2f ms", frames, Double(frames) / sampleRate * 1_000.0)
    }

    private func formattedDSPTime(frames: UInt32, sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "\(frames) frames" }
        return String(format: "%u frames / %.3f ms", frames, Double(frames) / sampleRate * 1_000.0)
    }

    private func formattedGain(_ linear: Float) -> String {
        guard linear > 0 else { return "−∞ dB" }
        return String(format: "%+.2f dB", 20.0 * log10(Double(linear)))
    }

    private func formattedLevel(_ linear: Float) -> String {
        guard linear > 0 else { return "−∞ dBFS" }
        return String(format: "%.1f dBFS", 20.0 * log10(Double(linear)))
    }
}
