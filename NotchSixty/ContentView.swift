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
