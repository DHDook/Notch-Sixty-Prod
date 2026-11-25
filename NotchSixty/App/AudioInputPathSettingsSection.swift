import SwiftUI

/// E36 S4: the "Audio input path" card in Settings. Shown only while `e36.virtual-driver` is on.
struct AudioInputPathSettingsSection: View {
    @ObservedObject var model: AudioInputPathModel

    var body: some View {
        let presentation = model.presentation
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Label("Audio input path", systemImage: "arrow.triangle.branch")
                .font(DesignType.sectionTitle.font)

            Text(presentation.headline).font(DesignType.label.font.weight(.semibold))
            Text(presentation.detail)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let waiting = model.waitingMessage {
                Text(waiting).font(DesignType.caption.font.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
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

            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                Text("Needs the driver").font(DesignType.label.font.weight(.semibold))
                ForEach(model.unlocks, id: \.unlock) { row in
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text(row.unlock.title).font(DesignType.caption.font.weight(.semibold))
                        Text(row.unlock.summary).font(DesignType.caption.font).foregroundStyle(.secondary)
                        if let note = row.note { Text(note).font(DesignType.caption.font).foregroundStyle(.secondary) }
                    }
                    .opacity(row.available ? 1 : 0.6)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("Follow the player's sample rate", isOn: Binding(
                get: { model.rateFollowingEnabled },
                set: { model.setRateFollowing($0) }
            ))
            .disabled(!model.rateFollowingAvailable)
            .help("Sets the DAC to the rate the player picks, or the nearest supported multiple of it. Off by default.")

            Text(AudioInputPathPresentation.crashWarning)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
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
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text(AudioInputPathPresentation.sheetTitle).font(DesignType.sectionTitle.font)
            Text(AudioInputPathPresentation.sheetBody)
                .fixedSize(horizontal: false, vertical: true)
            if !model.canOpenDownloadPage {
                Text(AudioInputPathPresentation.downloadUnavailable)
                    .font(DesignType.caption.font)
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
        .padding(DesignSpacing.xl.pt)
        .frame(width: 420)
    }
}
