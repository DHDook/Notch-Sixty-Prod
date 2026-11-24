import SwiftUI

// E12 S29: the step list down the side of the guided setup. Finished steps are ticked and can be reopened.

struct SystemSetupStepList: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Steps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(model.stepRows) { row in
                Button { model.open(row.step) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(row.state))
                            .foregroundStyle(row.state == .upcoming ? Color.secondary : Color.accentColor)
                            .frame(width: 16)
                        Text(ProductionSystemSetupFlowView.title(row.step))
                            .fontWeight(row.state == .current ? .semibold : .regular)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!row.canOpen)
                .accessibilityLabel(label(row))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 190, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func icon(_ state: SystemSetupStepState) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .current: return "circle.inset.filled"
        case .upcoming: return "circle"
        }
    }

    private func label(_ row: SystemSetupStepRow) -> String {
        let title = ProductionSystemSetupFlowView.title(row.step)
        switch row.state {
        case .done: return "\(title), finished. Open it again."
        case .current: return "\(title), this step"
        case .upcoming: return "\(title), not reached yet"
        }
    }
}
