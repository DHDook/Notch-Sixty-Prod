import SwiftUI

/// E11 S8: RTA & SPL tab. Starts the input-only monitor on the selected microphone, shows the SPL meter (Fast,
/// Slow, Leq, C-peak) and the RTA bands, calibrates against a 94 or 114 dB calibrator, and logs CSV into the app
/// container. Readings are labelled "dB (relative)" until calibrated.
struct MeasurementRTASPLCard: View {
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    @StateObject private var monitor = MeasurementInputMonitor()
    @State private var weighting = SPLWeighting.a
    @State private var bandsPerOctave = 3
    @State private var averaging = RTASettings.Averaging.exponential
    @State private var logging = false
    @State private var logMessage: String?

    var body: some View {
        GroupBox("RTA and SPL meter") {
            VStack(alignment: .leading, spacing: 10) {
                controls
                meterRow
                RTABandsPlot(spectrum: monitor.spectrum, calibrated: monitor.isCalibrated)
                    .frame(height: 160)
                calibrationRow
                loggingRow
                if monitor.overrunFrames > 0 {
                    Text("The analyser fell behind and dropped \(monitor.overrunFrames) frames.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = monitor.lastError ?? logMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(4)
        }
        .onChange(of: monitor.spectrum) { _, spectrum in
            MeasurementLiveOverlayStore.shared.rtaCurve = MeasurementOverlays.rtaCurve(
                spectrum: spectrum, relativeToMean: true)
        }
        .onDisappear {
            monitor.stop()
            MeasurementLiveOverlayStore.shared.rtaCurve = nil
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(monitor.isRunning ? "Stop" : "Start") { toggle() }
                .disabled(!monitor.isRunning && microphone.selectedInputDevice == nil)
            Picker("Weighting", selection: $weighting) {
                ForEach(SPLWeighting.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .frame(width: 140).disabled(monitor.isRunning)
            Picker("Bands", selection: $bandsPerOctave) {
                ForEach([1, 3, 6, 12, 24, 48], id: \.self) { Text($0 == 1 ? "1/1 octave" : "1/\($0) octave").tag($0) }
            }
            .frame(width: 180).disabled(monitor.isRunning)
            Picker("Averaging", selection: $averaging) {
                Text("Off").tag(RTASettings.Averaging.none)
                Text("Exponential").tag(RTASettings.Averaging.exponential)
                Text("Infinite").tag(RTASettings.Averaging.infinite)
            }
            .frame(width: 190).disabled(monitor.isRunning)
        }
        .pickerStyle(.menu)
    }

    private var unit: String { monitor.isCalibrated ? "dB SPL" : "dB (relative)" }

    private var meterRow: some View {
        HStack(spacing: 18) {
            value("Fast", monitor.reading?.fastDB)
            value("Slow", monitor.reading?.slowDB)
            value("Leq", monitor.reading?.leqDB)
            value("C-peak", monitor.reading?.cPeakDB)
            Spacer()
            Button("Reset") { monitor.resetReadings() }.disabled(!monitor.isRunning)
        }
    }

    private func value(_ title: String, _ db: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(db.map { $0 > Double(N60_SPL_FLOOR_DB) + 1 ? String(format: "%.1f", $0) : "--" } ?? "--")
                .font(.system(.title3, design: .monospaced))
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var calibrationRow: some View {
        HStack {
            Text("Calibrator").font(.caption).foregroundStyle(.secondary)
            Button("94 dB") { monitor.calibrate(toReferenceSPL: 94) }
            Button("114 dB") { monitor.calibrate(toReferenceSPL: 114) }
            Text("Play the 1 kHz calibrator on the microphone, wait for Leq to settle, then press its level.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!monitor.isRunning)
    }

    private var loggingRow: some View {
        HStack {
            Toggle("Log levels (1 per second)", isOn: $logging)
                .onChange(of: logging) { _, on in monitor.isLogging = on }
            Button("Save CSV") { saveLog() }.disabled(monitor.log.rows.isEmpty)
        }
    }

    private func toggle() {
        if monitor.isRunning {
            monitor.stop()
        } else if let device = microphone.selectedInputDevice {
            monitor.weighting = weighting
            monitor.rtaSettings = RTASettings(bandsPerOctave: bandsPerOctave, averaging: averaging)
            monitor.start(microphone: device, channel: microphone.selectedInputChannelIndex)
        }
    }

    private func saveLog() {
        let directory = MeasurementLibrary.defaultRoot().deletingLastPathComponent().appendingPathComponent("Measurements/Logs", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        do {
            let url = try monitor.writeLog(named: "levels-\(stamp)", in: directory)
            logMessage = nil
            NSLog("Saved level log to %@", url.path)
        } catch {
            logMessage = "Could not save the log: \(error.localizedDescription)"
        }
    }
}

/// Bars on a log frequency axis; the level range follows the data (60 dB below the loudest band).
struct RTABandsPlot: View {
    let spectrum: RTASpectrum?
    let calibrated: Bool

    var body: some View {
        Canvas { context, size in
            guard let spectrum, let top = spectrum.levelsDB.max(), top > Double(N60_SPL_FLOOR_DB) + 1,
                  let lo = spectrum.centresHz.first, let hi = spectrum.centresHz.last, hi > lo else { return }
            let range = 60.0
            let n = spectrum.centresHz.count
            let barWidth = max(1, size.width / CGFloat(n) - 1)
            for index in 0..<n {
                let x = CGFloat(log(spectrum.centresHz[index] / lo) / log(hi / lo)) * (size.width - barWidth)
                let t = min(1, max(0, 1 - (top - spectrum.levelsDB[index]) / range))
                let rect = CGRect(x: x, y: size.height * (1 - t), width: barWidth, height: size.height * t)
                context.fill(Path(rect), with: .color(.accentColor))
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            if let top = spectrum?.levelsDB.max(), top > Double(N60_SPL_FLOOR_DB) + 1 {
                Text(String(format: "top %.0f %@", top, calibrated ? "dB SPL" : "dB (relative)"))
                    .font(.caption2).foregroundStyle(.secondary).padding(4)
            }
        }
        .accessibilityLabel("Real-time analyser bands")
    }
}
