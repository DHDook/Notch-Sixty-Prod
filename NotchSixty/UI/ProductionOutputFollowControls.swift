import SwiftUI

/// E15 S3: the Follow macOS output controls (design note 8), shown only while `e15.follow-output` is on. The toggle and
/// the binding actions live inside the toolbar's Playback System menu, so the toolbar row gets no wider (AGENTS.md
/// section 13). The banner and the unbound sheet hang off the toolbar row.

/// Menu items for the Playback System menu: the Follow toggle, "Stop following", "Use for <device>", "Remove binding".
struct OutputFollowMenuSection: View {
    @ObservedObject var follow: OutputFollowCoordinator
    @ObservedObject var profiles: ProductProfileController
    let currentDeviceName: String

    var body: some View {
        Divider()
        Toggle("Follow macOS output", isOn: Binding(get: { follow.isFollowing }, set: { follow.setFollowing($0) }))
        if follow.isFollowing {
            Button("Stop following") { follow.setFollowing(false) }
        }
        if profiles.selectedSystemProfile != nil {
            Button("Use for \(currentDeviceName)") { follow.useSelectedSystemForCurrentOutput() }
        }
        Button("Remove binding for \(currentDeviceName)") { follow.removeBindingForCurrentOutput() }
        Text("Follow macOS output processes whichever output macOS is set to, with the Playback System bound to it.")
    }
}

/// The in-app banner (a popover on the toolbar) and the unbound sheet.
struct OutputFollowPresentation: ViewModifier {
    @ObservedObject var follow: OutputFollowCoordinator

    func body(content: Content) -> some View {
        content
            .popover(isPresented: bannerBinding, arrowEdge: .bottom) {
                if let note = follow.announcement {
                    OutputFollowBanner(note: note) { follow.dismissAnnouncement() }
                }
            }
            .sheet(isPresented: sheetBinding) {
                if let note = follow.announcement {
                    OutputFollowUnboundSheet(note: note, follow: follow)
                }
            }
    }

    private var bannerBinding: Binding<Bool> {
        Binding(
            get: { follow.announcement.map { !$0.isPause } ?? false },
            set: { if !$0 { follow.dismissAnnouncement() } })
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { follow.announcement?.isPause ?? false },
            set: { if !$0 { follow.dismissAnnouncement() } })
    }
}

struct OutputFollowBanner: View {
    let note: OutputFollowAnnouncement
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title).font(.headline)
            if let detail = note.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            Button("OK", action: dismiss).keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
    }
}

/// "No Playback System for <device>" with "Choose…" and "Use current for this device" (design note 6).
struct OutputFollowUnboundSheet: View {
    let note: OutputFollowAnnouncement
    @ObservedObject var follow: OutputFollowCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(note.title).font(.title3.weight(.semibold))
            if let detail = note.detail { Text(detail).foregroundStyle(.secondary) }
            Text("Choose a Playback System from the System menu in the toolbar, or use the current one for this device, then press Start.")
                .font(.callout)
            HStack {
                Spacer()
                Button("Choose…") { follow.dismissAnnouncement() }
                Button("Use current for this device") { follow.useSelectedSystemForCurrentOutput() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
