import SwiftUI

/// E11 S9b: seat picker for simultaneous multi-microphone capture. Lists the seats of one pass (up to 16)
/// and names the clocking mode: one interface is "shared clock"; microphones on several devices are captured in
/// a private drift-compensated aggregate with per-mic acoustic timing and are labelled less precise.
struct MeasurementSeatPickerCard: View {
    @ObservedObject var microphone: RoomCorrectionCalibrationController
    @Binding var plan: MeasurementSeatPlan
    @State private var deviceUID: String?
    @State private var channel = 1
    @State private var message: String?

    var body: some View {
        GroupBox("Measurement seats") {
            VStack(alignment: .leading, spacing: 8) {
                if plan.isEmpty {
                    Text("No seats yet. Add the microphone channels you placed at each listening position.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(plan.seats.enumerated()), id: \.element.id) { index, seat in
                    HStack {
                        Text("Seat \(index + 1)").bold()
                        Text(seat.name)
                        Spacer()
                        Button("Remove") { plan.remove(id: seat.id) }
                    }
                }
                HStack {
                    Picker("Device", selection: $deviceUID) {
                        Text("Choose").tag(String?.none)
                        ForEach(microphone.inputDevices) { Text($0.name).tag(Optional($0.uid)) }
                    }
                    Stepper("Channel \(channel)", value: $channel, in: 1 ... 64)
                    Button("Add seat") { add() }.disabled(deviceUID == nil)
                }
                if !plan.isEmpty {
                    Text(plan.mode.label).font(.caption)
                        .foregroundStyle(plan.mode.isLessPrecise ? .orange : .secondary)
                    if plan.mode.isLessPrecise {
                        Text("Each microphone has its own clock, so inter-seat timing comes from the reference speaker's chirp and is less precise than one interface.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
            }
            .padding(4)
        }
    }

    private func add() {
        guard let device = microphone.inputDevices.first(where: { $0.uid == deviceUID }) else { return }
        do {
            try plan.add(MeasurementSeat(device: device, channelIndex: channel - 1))
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
