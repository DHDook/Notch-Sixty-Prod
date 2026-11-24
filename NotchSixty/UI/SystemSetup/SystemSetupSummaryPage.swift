import SwiftUI

// E12 S29 (decision 37): the page after Save.

struct SystemSetupSummaryPage: View {
    @ObservedObject var model: SystemSetupFlowModel
    let summary: SystemSetupSummary
    let exit: (SystemSetupExit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Saved \(summary.profileName)", systemImage: "checkmark.circle.fill").font(.headline)
            if summary.notVerified {
                Label("This profile is labelled Not verified: the result was not checked by a second measurement.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if let headline = summary.verificationHeadline {
                Label(headline, systemImage: "checkmark.seal.fill").font(.callout)
            }
            GroupBox("What was set") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.lines, id: \.self) { Text($0).font(.callout) }
                    if summary.lines.isEmpty { Text("Your choices were saved.").font(.callout) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            if model.quickFinished {
                Text("The quick setup measured one seat and used default bass and correction settings. Open the full setup to see every choice, add seats or describe the room; nothing you have set changes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
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
