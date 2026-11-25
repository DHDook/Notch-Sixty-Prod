import SwiftUI

// E12 S29 (decision 37): the page after Save.

struct SystemSetupSummaryPage: View {
    @ObservedObject var model: SystemSetupFlowModel
    let summary: SystemSetupSummary
    let exit: (SystemSetupExit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Label("Saved \(summary.profileName)", systemImage: "checkmark.circle.fill").font(DesignType.sectionTitle.font)
            if summary.notVerified {
                Label("This profile is labelled Not verified: the result was not checked by a second measurement.",
                      systemImage: "exclamationmark.triangle")
                    .font(DesignType.label.font).foregroundStyle(StatusLevel.attention.color)
            } else if let headline = summary.verificationHeadline {
                Label(headline, systemImage: "checkmark.seal.fill").font(DesignType.label.font)
            }
            GroupBox("What was set") {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    ForEach(summary.lines, id: \.self) { Text($0).font(DesignType.label.font) }
                    if summary.lines.isEmpty { Text("Your choices were saved.").font(DesignType.label.font) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignSpacing.xs.pt)
            }
            if model.quickFinished {
                Text("The quick setup measured one seat and used default bass and correction settings. Open the full setup to see every choice, add seats or describe the room; nothing you have set changes.")
                    .font(DesignType.label.font).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpacing.s.pt) { actions }
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) { actions }
            }
            Button("Look at the room with the Room advisor") { exit(.roomAdvisor) }
                .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Listen") { exit(.listen) }
            .help("Closes the setup and goes to the Dashboard so you can play something.")
        Button(model.comparingBefore ? "Back to the corrected sound" : "Compare before and after") { model.toggleBeforeAfter() }
            .help("Switches between your system without and with this setup. Use it while music plays.")
        Button("Open the full settings") { exit(.fullSettings) }
    }
}
