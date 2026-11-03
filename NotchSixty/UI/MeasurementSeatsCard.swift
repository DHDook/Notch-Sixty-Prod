import SwiftUI

/// E24 S5: the one listening-seat control shared by the setup wizard and multichannel calibration. Content only;
/// each surface wraps it in its own container. Name, include and weight editing appear when `editsDetails` is set;
/// the per-seat microphone controls appear in per-seat mode when the wizard supplies their closures; the wizard adds
/// its progress and re-measure controls through `accessory`.
struct MeasurementSeatsCard<Accessory: View>: View {
    @ObservedObject var calibration: MultichannelCalibrationController
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    /// True while a measurement owns the seats; every control is disabled.
    var locked = false
    var editsDetails = false
    var onAdd: () -> Void
    var onRemove: (UUID) -> Void
    /// Applies a seat edit (name, include, weight); nil disables detail editing.
    var onUpdate: ((UUID, String, Bool, Double) -> Void)?
    var onSetDevice: ((UUID, String) -> Void)?
    var onSetChannel: ((UUID, Int) -> Void)?
    var onImportCalibration: ((UUID) -> Void)?
    var onClearCalibration: ((UUID) -> Void)?
    @ViewBuilder var accessory: (MultichannelCalibrationSeat) -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(calibration.seats) { seat in
                HStack(spacing: 12) {
                    if editsDetails, let onUpdate {
                        Toggle("", isOn: Binding(
                            get: { seat.included },
                            set: { onUpdate(seat.id, seat.name, $0, seat.weight) }))
                            .toggleStyle(.switch).labelsHidden()
                        TextField("Seat name", text: Binding(
                            get: { seat.name },
                            set: { value in
                                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                onUpdate(seat.id, value, seat.included, seat.weight)
                            }))
                            .textFieldStyle(.roundedBorder).frame(width: 190)
                        Stepper(value: Binding(
                            get: { seat.weight },
                            set: { onUpdate(seat.id, seat.name, seat.included, $0) }), in: 0...5, step: 0.25) {
                            Text("Weight \(seat.weight, specifier: "%.2g")")
                                .monospacedDigit().frame(width: 100, alignment: .leading)
                        }
                    } else {
                        Text(seat.name)
                    }
                    accessory(seat)
                    if calibration.seatMicrophoneMode == .perSeat, let onSetDevice, let onSetChannel {
                        Picker("Device", selection: Binding(
                            get: { seat.microphone?.deviceUID ?? microphone.selectedInputDevice?.uid ?? "" },
                            set: { onSetDevice(seat.id, $0) })) {
                            ForEach(microphone.inputDevices) { Text($0.name).tag($0.uid) }
                        }
                        .fixedSize()
                        Stepper("Input channel \((seat.microphone?.channelIndex ?? 0) + 1)", value: Binding(
                            get: { seat.microphone?.channelIndex ?? 0 },
                            set: { onSetChannel(seat.id, $0) }), in: 0...63)
                            .fixedSize()
                        if let onImportCalibration {
                            Button(seat.microphone?.calibration == nil ? "Calibration file" : "Replace file") {
                                onImportCalibration(seat.id)
                            }
                        }
                        if seat.microphone?.calibration != nil, let onClearCalibration {
                            Button("Clear file") { onClearCalibration(seat.id) }
                        }
                    }
                    Spacer()
                    if calibration.seats.count > 1 {
                        Button(role: .destructive) { onRemove(seat.id) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove this seat and its measurements")
                    }
                }
                .disabled(locked)
            }
            HStack {
                Button("Add Seat") { onAdd() }
                    .disabled(locked || calibration.seats.count >= Int(N60_CALIBRATION_MAX_SEATS))
                Spacer()
                Text("Up to \(Int(N60_CALIBRATION_MAX_SEATS)) weighted seats")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
