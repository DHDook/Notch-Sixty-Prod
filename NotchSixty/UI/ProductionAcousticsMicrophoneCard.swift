import SwiftUI

/// E12 S22 (G25, G99): the one microphone strip on Active Acoustics. A live indicator, what happens when the
/// microphone is lost, a picker, and one line saying that one microphone serves both features. The picker only
/// chooses the input; listening still starts only when a feature needs it, and nothing here arms anything.
struct ProductionAcousticsMicrophoneCard: View {
    @ObservedObject var ambient: AmbientCompensationController
    @ObservedObject var microphone: RoomCorrectionCalibrationController

    private var state: AcousticsMicrophoneState {
        AcousticsStatusModel.microphoneState(
            permissionGranted: microphone.permissionStatus == .authorized,
            selectedName: microphone.selectedInputDevice?.name,
            lostName: microphone.lostInput?.name,
            monitorStatus: ambient.monitorStatus)
    }

    var body: some View {
        let state = state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: state.isLive ? "mic.fill" : state.isLost ? "mic.slash.fill" : "mic")
                    .foregroundStyle(state.isLive ? Color.green : state.isLost ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text(state.title).font(.headline)
                    .accessibilityIdentifier("acoustics.microphone.title")
            }
            Text(state.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("acoustics.microphone.detail")
            if microphone.permissionStatus == .authorized {
                Picker("Microphone", selection: Binding<String?>(
                    get: { microphone.selectedInputUID },
                    set: { microphone.selectInput(uid: $0) })
                ) {
                    Text("Choose a microphone…").tag(Optional<String>.none)
                    if let lost = microphone.lostInput {
                        Text("\(lost.name) (not connected)").tag(Optional(lost.uid))
                    }
                    ForEach(microphone.inputDevices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                .frame(maxWidth: 420)
            }
            Text(AcousticsMicrophoneState.sharedNote).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("acoustics.microphone.shared")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }
}

/// E12 S22 (G32): what Room Treatment is, how it differs from Room Correction, and what this setup is missing.
struct ProductionRoomTreatmentHonesty: View {
    var missing: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AcousticsStatusModel.roomTreatmentHeadline).font(.headline)
                .accessibilityIdentifier("acoustics.treatment.headline")
            Text(AcousticsStatusModel.roomTreatmentDifference).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !missing.isEmpty {
                Text("This setup is missing:").font(.subheadline.bold())
                ForEach(missing, id: \.self) { item in
                    Label(item, systemImage: "circle.dashed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// Redraws the honesty box as the treatment design and permit change.
struct ProductionRoomTreatmentHonestyLive: View {
    @ObservedObject var controller: MIMOTreatmentController

    var body: some View {
        ProductionRoomTreatmentHonesty(missing: AcousticsStatusModel.roomTreatmentMissing(
            measuredSpeakers: !controller.rows.isEmpty,
            designed: controller.phase == .designed,
            qualified: controller.permitHeld,
            refusals: controller.permitRefusals))
    }
}
