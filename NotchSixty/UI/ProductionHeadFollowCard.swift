import SwiftUI

/// E4 S26b: let the quiet zone follow your head. Shown under the ear survey when flag `e4.head-position-camera` is on.
/// Off by default and at every launch. The camera runs only while the switch is on, frames stay on this Mac and are never
/// stored or sent. It only chooses between surveyed ear positions; it never arms anything.
struct ProductionHeadFollowCard: View {
    @ObservedObject var follow: QuietZoneHeadFollowController
    @ObservedObject var survey: QuietZoneVirtualMicSurveyController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Follow My Head")
                    .font(.headline)
                Spacer()
                cameraIndicator
            }
            Text("Uses the Mac camera to find where your head is, so the quiet zone can move with you between the seats you have surveyed. Pictures are processed on this Mac only, are never stored or sent, and the camera stops when you switch this off, when the Mac sleeps, and when Notch Sixty is in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Follow my head with the camera", isOn: Binding(
                get: { follow.isEnabled },
                set: { follow.setEnabled($0) }
            ))
            .disabled(!survey.isActive && !follow.isEnabled)
            if !survey.isActive {
                Text("Survey an ear position and switch on “Quiet the ear position” first.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(follow.message)
                .font(.callout)
                .foregroundStyle(.secondary)

            placementSection

            if follow.cameraState == .denied {
                Button("Open Camera Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            if follow.isCameraOn {
                HStack(spacing: 16) {
                    if let pose = follow.pose {
                        Text(String(format: "Head at %.0f, %.0f, %.0f cm", pose.x * 100, pose.y * 100, pose.z * 100))
                            .font(.callout.monospacedDigit())
                    } else {
                        Text("Looking for your head…").font(.callout)
                    }
                    Text(readoutText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Save this seat") { follow.savePosition(tones: survey.tones, earPositionID: survey.ear?.id, monitorID: survey.monitorID?()) }
                        .disabled(survey.tones.isEmpty || follow.pose == nil)
                    if !follow.positions.isEmpty {
                        Button("Clear seats") { follow.clearPositions() }
                    }
                    Text("Sit where the ear microphone was, survey it, then save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !follow.positions.isEmpty {
                Text("Saved seats: " + follow.positions.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// E4 G20: where the camera is, measured from the middle of the screen. Changing it clears the saved seats.
    private var placementSection: some View {
        DisclosureGroup("Camera position") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where the camera is, in centimetres in the room frame you use for the listening seats (x and y along the floor, height up) and the direction it faces, in degrees from the x axis. Changing it clears the saved seats and switches head follow off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                placementField("Room x (cm)", \.x, scale: 100)
                placementField("Room y (cm)", \.y, scale: 100)
                placementField("Height (cm)", \.z, scale: 100)
                placementField("Facing (degrees)", \.yawRadians, scale: 180 / .pi)
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private func placementField(_ title: String, _ key: WritableKeyPath<QuietZoneCameraPlacement, Double>, scale: Double) -> some View {
        HStack {
            Text(title).frame(width: 130, alignment: .leading)
            TextField(title, value: Binding(
                get: { follow.placement[keyPath: key] * scale },
                set: { value in
                    var next = follow.placement
                    next[keyPath: key] = value / scale
                    follow.setPlacement(next)
                }
            ), format: .number.precision(.fractionLength(0...1)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .labelsHidden()
        }
    }

    private var readoutText: String {
        switch follow.readout {
        case .cameraOff: return ""
        case .noPositions: return "Save at least one seat."
        case .waitingForPose: return "Waiting for a steady pose."
        case .outsideSurvey: return "Outside the saved seats; using the fixed ear position."
        case .following(let name, let cm): return "Following: nearest \(name), \(cm) cm away."
        }
    }

    @ViewBuilder private var cameraIndicator: some View {
        switch follow.cameraState {
        case .on:
            Label("Camera on", systemImage: "camera.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
        case .starting:
            Label("Starting camera", systemImage: "camera")
                .font(.caption)
                .foregroundStyle(.orange)
        case .paused:
            Label("Camera paused", systemImage: "camera")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            Label("Camera off", systemImage: "camera")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
