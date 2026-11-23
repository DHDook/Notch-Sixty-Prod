import SwiftUI

/// E36 S4: the "Audio input path" card in Settings. Shown only while `e36.virtual-driver` is on.
struct AudioInputPathSettingsSection: View {
    @ObservedObject var model: AudioInputPathModel

    var body: some View {
        let presentation = model.presentation
        VStack(alignment: .leading, spacing: 12) {
            Label("Audio input path", systemImage: "arrow.triangle.branch")
                .font(.headline)

            Text(presentation.headline).font(.subheadline.weight(.semibold))
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let waiting = model.waitingMessage {
                Text(waiting).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Use the virtual audio driver", isOn: Binding(
                get: { model.selectedPath == .virtualDriver },
                set: { model.select($0 ? .virtualDriver : .processTap) }
            ))
            .disabled(!presentation.canSwitchToDriver && model.selectedPath != .virtualDriver)

            // Wraps onto a second line instead of forcing the window wider (AGENTS.md section 13).
            ViewThatFits(in: .horizontal) {
                HStack { actionButtons(presentation) }
                VStack(alignment: .leading) { actionButtons(presentation) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Needs the driver").font(.subheadline.weight(.semibold))
                ForEach(model.unlocks, id: \.unlock) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.unlock.title).font(.caption.weight(.semibold))
                        Text(row.unlock.summary).font(.caption).foregroundStyle(.secondary)
                        if let note = row.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .opacity(row.available ? 1 : 0.6)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(AudioInputPathPresentation.crashWarning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .sheet(isPresented: $model.isShowingSetupSheet) { setupSheet }
    }

    @ViewBuilder
    private func actionButtons(_ presentation: AudioInputPathPresentation) -> some View {
        if presentation.actions.contains(.openDownloadPage) {
            Button("Set Up Driver…") { model.isShowingSetupSheet = true }
                .buttonStyle(.glass)
        }
        if presentation.actions.contains(.recheck) {
            Button("Check Again") { model.refresh() }
                .buttonStyle(.glass)
        }
    }

    private var setupSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AudioInputPathPresentation.sheetTitle).font(.headline)
            Text(AudioInputPathPresentation.sheetBody)
                .fixedSize(horizontal: false, vertical: true)
            if !model.canOpenDownloadPage {
                Text(AudioInputPathPresentation.downloadUnavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Download Page") { model.openDownloadPage() }
                    .buttonStyle(.glass)
                    .disabled(!model.canOpenDownloadPage)
                Button("Close") { model.isShowingSetupSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
