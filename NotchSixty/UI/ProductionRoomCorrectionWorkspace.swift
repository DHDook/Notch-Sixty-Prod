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

                if calibration.state == .reviewing, let analysis = calibration.latestAnalysis {
                    reviewCard(analysis)
                }

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
            switch calibration.state {
            case .measuring:
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

            case .analyzing:
                _ = await calibration.analyzeLatestCapture()

            default:
                break
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
                    .disabled(
                        calibration.selectedInputDevice == nil
                            || calibration.state == .measuring
                            || calibration.state == .arming
                    )
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
            case .arming:
                ProgressView("Preparing dedicated calibration transport…")

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
                ProgressView("Extracting impulse responses and transfer functions…")
                if let capture = calibration.latestCapture {
                    Text("Left: \(capture.left.count) samples · Right: \(capture.right.count) samples")
                        .font(.system(.body, design: .monospaced))
                }
                Text("Analysis runs off the realtime audio path. The captured sweeps are being deconvolved and checked for clipping, noise, usable bandwidth, and direct-arrival timing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .reviewing:
                Label("Measurement and analysis complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Review the measured Left / Right quality below before keeping this position or measuring again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    actionError = nil
                    do { try calibration.beginMeasurement() }
                    catch { actionError = error.localizedDescription }
                } label: {
                    Label("Measure Current Position Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!calibration.canBeginMeasurement)

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

                Text("This capture measures one listening position. Named multi-position storage and weighting build on the analyzed Left / Right result in the next Room Correction stage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func reviewCard(_ analysis: RoomCorrectionMeasurementAnalysis) -> some View {
        let warnings = analysisWarnings(analysis)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("3. Review").font(.headline)
                Spacer()
                Text(formattedRate(analysis.sampleRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            channelReview("Left", measurement: analysis.left)
            Divider()
            channelReview("Right", measurement: analysis.right)

            if !warnings.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Measurement notes", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.semibold))
                    ForEach(warnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("This review is the measured response for the current position only. Named positions, inclusion/weighting, spatial aggregation, target shaping, and FIR design remain separate downstream stages; none are inferred here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private func channelReview(
        _ name: String,
        measurement: RoomCorrectionChannelMeasurement
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).font(.callout.weight(.semibold))
                Spacer()
                if measurement.quality.clipped {
                    Label("Clipped", systemImage: "waveform.path.badge.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                } else {
                    Label("No clipping", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 24) {
                statusValue("SNR", formattedDB(measurement.quality.estimatedSNRDB))
                statusValue("Capture Peak", formattedDB(measurement.quality.capturePeakDBFS))
                statusValue(
                    "Direct Arrival",
                    formattedMilliseconds(measurement.quality.directArrivalSeconds)
                )
                statusValue(
                    "Usable Band",
                    formattedBand(
                        low: measurement.quality.usableLowHz,
                        high: measurement.quality.usableHighHz
                    )
                )
                statusValue(
                    "Response Points",
                    String(measurement.transferFunction?.frequenciesHz.count ?? 0)
                )
            }
        }
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

    private func analysisWarnings(_ analysis: RoomCorrectionMeasurementAnalysis) -> [String] {
        Array(Set(analysis.left.quality.warnings + analysis.right.quality.warnings)).sorted()
    }

    private func formattedDB(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f dB", value)
    }

    private func formattedMilliseconds(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return String(format: "%.2f ms", seconds * 1_000)
    }

    private func formattedBand(low: Double?, high: Double?) -> String {
        guard let low, let high else { return "—" }
        return "\(formattedFrequency(low)) – \(formattedFrequency(high))"
    }

    private func formattedFrequency(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            return String(format: "%.1f kHz", frequency / 1_000)
        }
        return String(format: "%.0f Hz", frequency)
    }

    private func formattedRate(_ rate: Double) -> String {
        if rate >= 1_000 {
            return String(format: "%.1f kHz", rate / 1_000)
        }
        return String(format: "%.0f Hz", rate)
    }
}
