import SwiftUI

/// E15 S3b: the Settings row shown while Follow macOS output is on and macOS notifications are off or not yet decided.
/// The button opens System Settings; Notch Sixty never changes the setting itself.
struct OutputFollowNotificationsRow: View {
    @ObservedObject var follow: OutputFollowCoordinator
    @ObservedObject var notifications: FollowNotificationController

    var body: some View {
        if follow.isFollowing, notifications.authorization != .authorized {
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS notifications are off for Notch Sixty")
                    .font(.subheadline.weight(.medium))
                Text("Follow macOS output still shows its banner in the app. Turn notifications on to hear about output changes while Notch Sixty is in the background.")
                    .foregroundStyle(.secondary)
                Button("Open System Settings") { notifications.openSystemSettings() }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// E15 S4 (G9): the Settings switch for Follow macOS output. Same coordinator call as the Playback System menu.
struct OutputFollowSettingsToggle: View {
    @ObservedObject var follow: OutputFollowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Follow macOS output", isOn: Binding(get: { follow.isFollowing }, set: { follow.setFollowing($0) }))
            Text(OutputFollowCopy.recoveryPolicy(following: follow.isFollowing))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
