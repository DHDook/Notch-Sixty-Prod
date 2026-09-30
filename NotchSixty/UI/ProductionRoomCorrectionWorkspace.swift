import SwiftUI

struct ProductionRoomCorrectionWorkspace: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var calibration: RoomCorrectionCalibrationController

    @State private var actionError: String?

    private var selectedInputBinding: Binding<String?> {
        Binding(
            get: { calibration.selectedInputUID },
            set: { calibration.selectInput(uid: $0) }
        )
    }

    private var inputChannelBinding: Binding<Int> {
        Binding(
            get: { calibration.selectedInputChannelIndex + 1 },
            set: { value in try? calibration.selectInputChannel(index: value - 1) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                dailyPlaybackCard
                setupCard
                measurementCard

                if let error = actionError ?? calibration.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(28)
            .frame(maxWidth: 940, alignment: .topLeading)
        }
        .navigationTitle("Room Correction")
        .task { calibration.prepareForUse() }
        .task(id: calibration.state) {
            guard calibration.state == .measuring else { return }
            while !Task.isCancelled && calibration.state == .measuring {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                do {
                    if try calibration.finishMeasurementIfComplete() { break }
                } catch {
                    actionError = error.localizedDescription
                    break
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Room Correction")
                .font(.largeTitle.bold())
            Text("Measure the physical stereo playback system independently from daily content DSP, then analyze and design a reproducible correction filter.")
                .foregroundStyle(.secondary)
        }
    }

    private var dailyPlaybackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Daily Playback").font(.headline)
                    Text(engine.roomCorrectionConfiguration.filter?.name ?? "No correction filter deployed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "Correction Enabled",
                    isOn: Binding(
                        get: { engine.roomCorrectionConfiguration.enabled },
                        set: { try? engine.setRoomCorrectionEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .disabled(engine.roomCorrectionConfiguration.filter == nil)
            }

            HStack(spacing: 22) {
                statusValue(
                    "Playback System Output",
                    calibration.selectedOutputDevice?.name ?? "Not selected"
                )
                statusValue(
                    "Native Rate",
                    calibration.selectedOutputDevice.map { formattedRate($0.nominalSampleRate) } ?? "—"
                )
                statusValue(
                    "DSP State",
                    engine.lifecycleState.rawValue.capitalized
                )
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("1. Setup").font(.headline)
                Spacer()
                calibrationStateBadge
            }

            LabeledContent("Microphone Permission") {
                HStack(spacing: 10) {
                    Text(permissionLabel)
                        .foregroundStyle(calibration.permissionStatus == .authorized ? .primary : .secondary)
                    if calibration.permissionStatus != .authorized {
                        Button("Request Access") {
                            actionError = nil
                            Task { await calibration.requestMicrophonePermission() }
                        }
                        .disabled(calibration.state == .requestingPermission)
                    }
                }
            }

            if calibration.permissionStatus == .authorized {
                LabeledContent("Measurement Input") {
                    HStack(spacing: 10) {
                        Picker("Measurement Input", selection: selectedInputBinding) {
                            Text("Choose a microphone…").tag(Optional<String>.none)
                            ForEach(calibration.inputDevices) { device in
                                Text("\(device.name) · \(formattedRate(device.nominalSampleRate))")
                                    .tag(Optional(device.uid))
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 320)
                        .disabled(calibration.state == .measuring || calibration.state == .arming)

                        Button("Refresh") {
                            actionError = nil
                            do { _ = try calibration.refreshInputDevices() }
                            catch { actionError = error.localizedDescription }
                        }
                        .disabled(calibration.state == .measuring || calibration.state == .arming)
                    }
                }

                LabeledContent("Microphone Channel") {
                    Stepper(
                        "Input \(calibration.selectedInputChannelIndex + 1)",
                        value: inputChannelBinding,
                        in: 1...32
                    )
                    .disabled(calibration.selectedInputDevice == nil || calibration.state == .measuring)
                }
            }

            Divider()

            LabeledContent("Sweep Duration") {
                Picker("Sweep Duration", selection: $calibration.sweepDurationSeconds) {
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                    Text("15 s").tag(15.0)
                    Text("20 s").tag(20.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 320)
                .disabled(calibration.state == .measuring || calibration.state == .arming)
            }

            LabeledContent("Sweep Level") {
                HStack(spacing: 12) {
                    Slider(value: $calibration.sweepLevelDBFS, in: -36 ... -6, step: 1)
                        .frame(width: 280)
                    Text("\(calibration.sweepLevelDBFS, specifier: "%.0f") dBFS")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }

            Text("Measurement uses two sequential sweeps at the current native output rate: Left speaker first, then Right. Captured microphone audio is never routed into playback. Start conservatively and raise the level only if measurement quality requires it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var measurementCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("2. Measure").font(.headline)

            if engine.lifecycleState != .idle {
                Label(
                    "Stop normal DSP playback before calibration can take exclusive ownership of the physical output.",
                    systemImage: "stop.circle"
                )
                .foregroundStyle(.orange)
            } else {
                Label(
                    "Normal DSP is idle. Calibration may claim the selected output without changing your Playback System settings.",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.secondary)
            }

            switch calibration.state {
            case .measuring:
                ProgressView(value: calibration.measurementProgress) {
                    Text("Capturing sequential Left / Right sweeps")
                } currentValueLabel: {
                    Text("\(calibration.measurementProgress * 100, specifier: "%.0f")%")
                        .monospacedDigit()
                }
                Text("Keep the microphone stationary until both sweeps and the decay tail finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel Measurement", role: .cancel) {
                    calibration.cancelMeasurement()
                }

            case .analyzing:
                if let capture = calibration.latestCapture {
                    Label("Paired stereo capture complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Left: \(capture.left.count) samples · Right: \(capture.right.count) samples")
                        .font(.system(.body, design: .monospaced))
                    Text("The raw measurement is ready for impulse-response extraction and transfer-function analysis in the next calibration stage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .failed:
                Button("Reset Calibration") {
                    actionError = nil
                    calibration.resetAfterFailure()
                    calibration.prepareForUse()
                }

            default:
                Button {
                    actionError = nil
                    do { try calibration.beginMeasurement() }
                    catch { actionError = error.localizedDescription }
                } label: {
                    Label("Measure Current Position", systemImage: "waveform.badge.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!calibration.canBeginMeasurement)

                Text("This first capture surface measures one position. Named multi-position storage, quality analysis, weighting, targets, and FIR design build on the paired capture in the following Room Correction stages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var calibrationStateBadge: some View {
        Text(calibration.state.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    private var permissionLabel: String {
        switch calibration.permissionStatus {
        case .notDetermined: return "Not requested"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        }
    }

    @ViewBuilder
    private func statusValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
    }

    private func formattedRate(_ rate: Double) -> String {
        if rate >= 1_000 {
            return String(format: "%.1f kHz", rate / 1_000)
        }
        return String(format: "%.0f Hz", rate)
    }
}
