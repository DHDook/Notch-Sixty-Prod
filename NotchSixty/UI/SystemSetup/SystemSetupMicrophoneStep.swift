import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupMicrophoneStep: View {
    @ObservedObject var model: SystemSetupFlowModel
    @ObservedObject private var microphone: RoomCorrectionCalibrationController
    @ObservedObject private var monitor: MeasurementInputMonitor
    @State private var splText = ""
    @State private var importing = false

    init(model: SystemSetupFlowModel) {
        self.model = model
        _microphone = ObservedObject(wrappedValue: model.microphone)
        _monitor = ObservedObject(wrappedValue: model.levelMonitor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measurement microphone").font(.headline)
            Text("Notch Sixty listens through this microphone to measure your speakers. Macs ask for microphone permission the first time; audio is analysed on this Mac and never leaves it.")
                .font(.callout).foregroundStyle(.secondary)
            MeasurementMicrophoneCard(
                microphone: microphone, locked: model.noiseIsPlaying,
                onSelect: { model.selectMicrophone(uid: $0) })
            calibrationFile
            Divider()
            Text("Set the level").font(.headline)
            Text("Set each channel on its own, then use All channels as a combined check (the bass-only channel is left out unless you choose the including mode). The test noise starts very quietly at \(Int(SystemSetupLevelPlan.startLevelDB)) \(SystemSetupTerm.dBFS.technicalName). Press Set the level for me, or raise it a step at a time yourself, until the meter reads about \(Int(SystemSetupLevelPlan.targetSPLdBC)) \(SystemSetupTerm.dBC.technicalName) at your main seat. It never goes above \(Int(SystemSetupLevelPlan.ceilingDB)) \(SystemSetupTerm.dBFS.technicalName).")
                .font(.callout).foregroundStyle(.secondary)
            let channels = model.noiseChannels
            Picker("Channel", selection: Binding<Int>(
                get: {
                    switch model.level.target {
                    case .lane(let lane): return lane
                    case .allProgram(let includeLFE): return includeLFE ? -2 : -1
                    case .lanes: return -1
                    }
                },
                set: { model.selectNoiseTarget(lane: $0 < 0 ? nil : $0, includeLFE: $0 == -2) }
            )) {
                Text("All channels except the bass-only channel (LFE, combined check)").tag(-1)
                if channels.contains(where: \.isLFE) { Text("All channels including the bass-only channel (LFE)").tag(-2) }
                ForEach(channels, id: \.index) { Text($0.name + ($0.isLFE ? " (starts at \(Int(SystemSetupLevelPlan.lfeStartLevelDB)) dBFS, bass only)" : "")).tag($0.index) }
            }
            if model.level.showsFullBandLFEWarning {
                Text("Warning: this mode sends full-band noise to the subwoofer as well. It starts at \(Int(SystemSetupLevelPlan.lfeStartLevelDB)) dBFS. Raise the level slowly and stop if the sub strains.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let status = model.autoLevelStatus {
                Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SystemSetupTermNotes(step: .microphone)
            HStack {
                Button("Lower") { model.lowerLevel() }.disabled(model.autoLevelRunning)
                Text("\(Int(model.level.levelDB)) dBFS").monospacedDigit()
                Button("Raise") { model.raiseLevel() }.disabled(model.level.atCeiling || model.autoLevelRunning)
                Spacer()
                if let reading = monitor.reading {
                    Text("\(reading.slowDB, specifier: "%.1f") dB(C)").monospacedDigit()
                }
            }
            HStack {
                if model.autoLevelRunning {
                    Button("Stop automatic level") { model.stopAutoLevel() }
                } else {
                    Button("Set the level for me") { model.startAutoLevel() }
                        .disabled(microphone.selectedInputDevice == nil)
                        .help("Plays the noise and raises it a step at a time until the meter reads about \(Int(SystemSetupLevelPlan.targetSPLdBC)) dB(C). It never goes above the top level.")
                }
            }
            HStack {
                Button(model.noiseIsPlaying ? "Stop noise" : "Play noise") { model.toggleNoise() }
                Button(monitor.isRunning ? "Stop meter" : "Start meter") { toggleMeter() }
                    .disabled(microphone.selectedInputDevice == nil)
                Button("Use this level for the sweep") {
                    if let reading = monitor.reading { model.acceptSweepLevel(measuredSPLdBC: reading.slowDB) }
                }
                .disabled(monitor.reading == nil)
                if let sweep = model.choices.sweepLevelDBFS {
                    Text("Sweep level \(sweep, specifier: "%.0f") dBFS").font(.caption)
                }
            }
        }
        .onDisappear { monitor.stop(); model.stopNoise() }
    }

    /// E12 S29: the microphone's calibration file is imported here, not in a tab the sheet blocks.
    private var calibrationFile: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let file = microphone.microphoneCalibration {
                HStack {
                    Label("Calibration file: \(file.sourceName ?? "imported")", systemImage: "checkmark.circle")
                        .font(.callout)
                    Button("Remove") { model.clearMicrophoneCalibration() }
                }
            } else if microphone.permissionStatus == .authorized {
                Text(model.verdictsEnabled
                     ? SystemSetupCorrectionLimit.note(limitHz: model.correctionLimitHz)
                     : "No calibration file. Import the file that came with your microphone for the most accurate results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(microphone.microphoneCalibration == nil ? "Import calibration file…" : "Replace calibration file…") {
                importing = true
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .data]) { result in
                importFile(result)
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                model.message = "Microphone calibration files must be UTF-8 text with frequency and gain columns."
                return
            }
            model.importMicrophoneCalibration(text: text, sourceName: url.lastPathComponent)
        } catch {
            model.message = error.localizedDescription
        }
    }

    private func toggleMeter() {
        if monitor.isRunning { model.stopLevelMeter() } else { model.startLevelMeter() }
    }
}
