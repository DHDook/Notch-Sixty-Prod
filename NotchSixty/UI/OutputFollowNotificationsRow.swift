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
