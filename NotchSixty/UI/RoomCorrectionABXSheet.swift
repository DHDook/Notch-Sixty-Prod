import Combine
import SwiftUI

// E24 S9: the blind A/B/X sheet opened from the setup flow's Save step. A is minimum phase and B is mixed phase;
// nothing here says which one X is until the run and the preference answer are complete.

struct RoomCorrectionABXCard: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                Label("Compare by ear (blind ABX)", systemImage: "ear").font(DesignType.sectionTitle.font)
                Text("Listen to your own music through the minimum-phase and mixed-phase designs, level and delay matched, and see whether you can tell them apart.")
                    .font(DesignType.label.font).foregroundStyle(.secondary)
                HStack {
                    Button("Compare by ear") { Task { await model.openABX() } }
                        .disabled(model.abxUnavailableReason != nil)
                    if model.abxPreparing { ProgressView().controlSize(.small) }
                }
                if let reason = model.abxUnavailableReason {
                    Text(reason).font(DesignType.caption.font).foregroundStyle(.secondary)
                }
            }
            .padding(DesignSpacing.xs.pt)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: Binding(get: { model.abx != nil }, set: { if !$0 { model.closeABX() } })) {
            if let controller = model.abx {
                RoomCorrectionABXSheet(model: model, controller: controller)
            }
        }
    }
}

struct RoomCorrectionABXSheet: View {
    @ObservedObject var model: SystemSetupFlowModel
    @ObservedObject var controller: RoomCorrectionABXController
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Compare by ear").font(DesignType.sectionTitle.font.bold())
            Text(controller.matchSummary).font(DesignType.caption.font).foregroundStyle(.secondary)
            if let warning = controller.levelWarning {
                Label(warning, systemImage: "exclamationmark.triangle").font(DesignType.label.font).foregroundStyle(StatusLevel.attention.color)
            }
            switch controller.phase {
            case .trials: trials
            case .askingPreference: preference
            case .finished: finished
            case .ended(let reason):
                Label(reason, systemImage: "pause.circle").font(DesignType.label.font)
                Text("The applied design is back.").font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            if let message = controller.message {
                Text(message).font(DesignType.caption.font).foregroundStyle(StatusLevel.problem.color)
            }
            HStack {
                Spacer()
                Button(controller.phase == .finished ? "Close without keeping a change" : "Close") { model.closeABX() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DesignSpacing.xl.pt)
        .frame(minWidth: 460)
        .onReceive(tick) { _ in controller.refreshReadiness() }
    }

    private var trials: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Trial \(controller.currentTrialNumber) of \(controller.totalTrials)").font(DesignType.sectionTitle.font)
            if controller.seatNames.count > 1 {
                Picker("Listening seat", selection: $controller.listeningSeatIndex) {
                    ForEach(controller.seatNames.indices, id: \.self) { Text(controller.seatNames[$0]).tag($0) }
                }
            }
            HStack {
                ForEach([("A", RoomCorrectionABXController.Selection.a), ("B", .b), ("X", .x)], id: \.0) { item in
                    Button(item.0) { controller.select(item.1) }
                        .buttonStyle(.glassProminent)
                        .tint(controller.selection == item.1 ? .accentColor : .gray)
                        .disabled(!controller.canSwitch)
                }
                if controller.isSwitching { ProgressView().controlSize(.small) }
            }
            Text("Play A, B and X as often as you like, but hear X at least once before you say which one it is.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
            HStack {
                Button("X is A") { controller.answer(xIsB: false) }.disabled(!controller.canAnswer)
                Button("X is B") { controller.answer(xIsB: true) }.disabled(!controller.canAnswer)
            }
        }
    }

    private var preference: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text("All \(controller.totalTrials) trials are in.").font(DesignType.sectionTitle.font)
            Text("Which did you prefer overall?")
            HStack {
                Button("A") { controller.submitPreference(.a) }
                Button("B") { controller.submitPreference(.b) }
                Button("No preference") { controller.submitPreference(.none) }
            }
        }
    }

    @ViewBuilder private var finished: some View {
        if let result = controller.result, let names = controller.revealedNames {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                Text("\(result.correctCount) of \(result.trialCount) correct (p = \(String(format: "%.4f", result.pValue)))")
                    .font(DesignType.sectionTitle.font)
                Text("A was \(names.a). B was \(names.b).")
                Text(result.preferredDesignName.map { "You preferred \($0)." } ?? "You stated no preference.")
                Text(controller.g3Passed
                     ? "Gate G3: met (3 or more seats at p < 0.05 preferring mixed phase)."
                     : "Gate G3: \(controller.seatsWithPassingLog) of 3 seats so far.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
                Text("Log saved to \(result.logURL.lastPathComponent) in the ABX folder.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
                Divider()
                Text("Which design should be saved?").font(DesignType.label.font)
                let preferA = result.preferredDesignName == names.a
                let preferB = result.preferredDesignName == names.b
                HStack {
                    keepButton("Keep A (minimum phase)", kind: .minimumPhase, prominent: preferA)
                    keepButton("Keep B (mixed phase)", kind: .mixedPhase, prominent: preferB)
                        .disabled(model.keepMixedPhaseUnavailableReason != nil)
                }
                if let reason = model.keepMixedPhaseUnavailableReason {
                    Text(reason).font(DesignType.caption.font).foregroundStyle(.secondary)
                }
                Text("Keeping the design that is not applied needs a new verification before you can save.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func keepButton(_ title: String, kind: SystemSetupDesignKind, prominent: Bool) -> some View {
        if prominent {
            Button(title) { model.keepABXCandidate(kind) }.buttonStyle(.glassProminent)
        } else {
            Button(title) { model.keepABXCandidate(kind) }
        }
    }
}
