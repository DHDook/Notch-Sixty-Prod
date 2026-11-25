import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupVerifyStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Check the result").font(DesignType.sectionTitle.font)
            Text("Notch Sixty measures your main seat once more with the correction on and compares it with what was predicted.")
                .font(DesignType.label.font).foregroundStyle(.secondary)
            HStack {
                Button("Verify") { model.runVerification() }.disabled(model.isVerifying)
                if model.isVerifying {
                    ProgressView().controlSize(.small)
                    Button("Cancel check") { model.cancelVerification() }
                }
            }
            if let summary = model.verificationSummary {
                Label(summary.headline, systemImage: summary.verdict == .verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(DesignType.sectionTitle.font)
                Text(summary.detail).font(DesignType.label.font).foregroundStyle(.secondary)
            }
            if let report = model.verificationReport {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Predicted error").bold(); Text("Measured error").bold() }
                    GridRow {
                        Text("\(report.predictedErrorDB, specifier: "%.1f") dB").monospacedDigit()
                        Text("\(report.measuredErrorDB, specifier: "%.1f") dB").monospacedDigit()
                    }
                }
            }
            if model.verificationReport != nil {
                SystemSetupGraphPanel(model: model, graph: model.verifyGraph,
                                      emptyNote: "This check did not report a response to draw.")
            }
            roomInsightsCard
        }
    }

    private var roomInsightsCard: some View {
        GroupBox("Room insights") {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                if model.roomInsights.isEmpty {
                    Text("Nothing here that EQ cannot handle.").font(DesignType.label.font).foregroundStyle(.secondary)
                }
                ForEach(model.roomInsights) { insight in
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text(insight.title).font(DesignType.label.font.weight(insight.isImportant ? .semibold : .regular))
                        Text(insight.detail).font(DesignType.caption.font).foregroundStyle(.secondary)
                    }
                }
                Text("After you save, the summary links to the full Room advisor.").font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            .padding(DesignSpacing.xs.pt)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
