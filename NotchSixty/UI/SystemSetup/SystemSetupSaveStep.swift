import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupSaveStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Save your system").font(DesignType.sectionTitle.font)
            TextField("Profile name", text: Binding(
                get: { model.choices.profileName }, set: { model.setProfileName($0) }))
            if model.savesAsNotVerified {
                Label("This profile will be labelled Not verified.", systemImage: "exclamationmark.triangle")
                    .font(DesignType.label.font).foregroundStyle(StatusLevel.attention.color)
            } else if let summary = model.verificationSummary {
                Label(summary.headline, systemImage: "checkmark.seal.fill").font(DesignType.label.font)
            }
            RoomCorrectionABXCard(model: model)
        }
    }
}
