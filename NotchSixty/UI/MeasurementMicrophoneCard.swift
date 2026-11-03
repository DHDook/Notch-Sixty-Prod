import SwiftUI

/// E24 S5 leftovers: the one measurement-microphone control shared by the setup wizard, Room Correction and
/// multichannel calibration: permission, input device, input channel and the calibration file. It is content
/// only; each surface wraps it in its own container and supplies what differs through closures.
struct MeasurementMicrophoneCard: View {
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    /// True while a measurement owns the input; every control is disabled.
    var locked = false
    /// Called after the user picks a device; the default selects it on the controller.
    var onSelect: ((String?) -> Void)?
    /// Shows Import and Clear for the calibration file when set.
    var onImportCalibration: (() -> Void)?
    var onError: (String?) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Permission") {
                HStack(spacing: 10) {
                    Text(permissionLabel)
                        .foregroundStyle(microphone.permissionStatus == .authorized ? .primary : .secondary)
                    if microphone.permissionStatus != .authorized {
                        Button("Request Access") {
                            onError(nil)
                            Task {
                                await microphone.requestMicrophonePermission()
                                _ = try? microphone.refreshInputDevices()
                            }
                        }
                        .disabled(microphone.state == .requestingPermission)
                    }
                }
            }
            if microphone.permissionStatus == .authorized {
                LabeledContent("Input") {
                    HStack(spacing: 10) {
                        Picker("Measurement Input", selection: Binding<String?>(
                            get: { microphone.selectedInputUID },
                            set: { uid in
                                if let onSelect { onSelect(uid) } else { microphone.selectInput(uid: uid) }
                            }
                        )) {
                            Text("Choose a microphone…").tag(Optional<String>.none)
                            ForEach(microphone.inputDevices) { device in
                                Text("\(device.name) · \(device.nominalSampleRate / 1_000, specifier: "%.1f") kHz")
                                    .tag(Optional(device.uid))
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 300)
                        .disabled(locked)
                        Button("Refresh") {
                            onError(nil)
                            do { _ = try microphone.refreshInputDevices() } catch { onError(error.localizedDescription) }
                        }
                        .disabled(locked)
                    }
                }
                LabeledContent("Input Channel") {
                    Stepper(
                        "Channel \(microphone.selectedInputChannelIndex + 1)",
                        value: Binding(
                            get: { microphone.selectedInputChannelIndex + 1 },
                            set: { try? microphone.selectInputChannel(index: max(0, $0 - 1)) }),
                        in: 1...64
                    )
                    .disabled(locked || microphone.selectedInputDevice == nil)
                }
                LabeledContent("Calibration") {
                    HStack(spacing: 10) {
                        Text(microphone.microphoneCalibration.map { $0.sourceName ?? "Loaded calibration curve" } ?? "No calibration curve")
                            .foregroundStyle(microphone.microphoneCalibration == nil ? .secondary : .primary)
                            .lineLimit(1)
                        if let onImportCalibration {
                            Button("Import…") { onError(nil); onImportCalibration() }.disabled(locked)
                            Button("Clear") { onError(nil); microphone.clearMicrophoneCalibration() }
                                .disabled(locked || microphone.microphoneCalibration == nil)
                        }
                    }
                }
                if let curve = microphone.microphoneCalibration {
                    Text("\(curve.points.count) calibration points. The curve is applied to offline measurement analysis only; it is never inserted into daily playback DSP.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var permissionLabel: String {
        switch microphone.permissionStatus {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        }
    }
}
