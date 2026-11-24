import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupSaveStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save your system").font(.headline)
            TextField("Profile name", text: Binding(
                get: { model.choices.profileName }, set: { model.setProfileName($0) }))
            if model.savesAsNotVerified {
                Label("This profile will be labelled Not verified.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if let summary = model.verificationSummary {
                Label(summary.headline, systemImage: "checkmark.seal.fill").font(.callout)
            }
            RoomCorrectionABXCard(model: model)
        }
    }
}
