import SwiftUI

// E24 S9: the blind A/B/X sheet opened from the setup flow's Save step. A is minimum phase and B is mixed phase;
// nothing here says which one X is until the run and the preference answer are complete.

struct RoomCorrectionABXCard: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("Compare by ear (blind ABX)", systemImage: "ear").font(.headline)
                Text("Listen to your own music through the minimum-phase and mixed-phase designs, level and delay matched, and see whether you can tell them apart.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Compare by ear") { Task { await model.openABX() } }
                        .disabled(model.abxUnavailableReason != nil)
                    if model.abxPreparing { ProgressView().controlSize(.small) }
                }
                if let reason = model.abxUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare by ear").font(.title3.bold())
            Text(controller.matchSummary).font(.caption).foregroundStyle(.secondary)
            if let warning = controller.levelWarning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            switch controller.phase {
            case .trials: trials
            case .askingPreference: preference
            case .finished: finished
            case .ended(let reason):
                Label(reason, systemImage: "pause.circle").font(.callout)
                Text("The applied design is back.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(controller.phase == .finished ? "Close without keeping a change" : "Close") { model.closeABX() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
        .onReceive(tick) { _ in controller.refreshReadiness() }
    }

    private var trials: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trial \(controller.currentTrialNumber) of \(controller.totalTrials)").font(.headline)
            if controller.seatNames.count > 1 {
                Picker("Listening seat", selection: $controller.listeningSeatIndex) {
                    ForEach(controller.seatNames.indices, id: \.self) { Text(controller.seatNames[$0]).tag($0) }
                }
            }
            HStack {
                ForEach([("A", RoomCorrectionABXController.Selection.a), ("B", .b), ("X", .x)], id: \.0) { item in
                    Button(item.0) { controller.select(item.1) }
                        .buttonStyle(.borderedProminent)
                        .tint(controller.selection == item.1 ? .accentColor : .gray)
                        .disabled(!controller.canSwitch)
                }
                if controller.isSwitching { ProgressView().controlSize(.small) }
            }
            Text("Play A, B and X as often as you like, then say which one X is.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("X is A") { controller.answer(xIsB: false) }.disabled(!controller.canAnswer)
                Button("X is B") { controller.answer(xIsB: true) }.disabled(!controller.canAnswer)
            }
        }
    }

    private var preference: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All \(controller.totalTrials) trials are in.").font(.headline)
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
            VStack(alignment: .leading, spacing: 8) {
                Text("\(result.correctCount) of \(result.trialCount) correct (p = \(String(format: "%.4f", result.pValue)))")
                    .font(.headline)
                Text("A was \(names.a). B was \(names.b).")
                Text(result.preferredDesignName.map { "You preferred \($0)." } ?? "You stated no preference.")
                Text(controller.g3Passed
                     ? "Gate G3: met (3 or more seats at p < 0.05 preferring mixed phase)."
                     : "Gate G3: \(controller.seatsWithPassingLog) of 3 seats so far.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Log saved to \(result.logURL.lastPathComponent) in the ABX folder.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Which design should be saved?").font(.subheadline)
                let preferA = result.preferredDesignName == names.a
                let preferB = result.preferredDesignName == names.b
                HStack {
                    keepButton("Keep A (minimum phase)", kind: .minimumPhase, prominent: preferA)
                    keepButton("Keep B (mixed phase)", kind: .mixedPhase, prominent: preferB)
                        .disabled(model.keepMixedPhaseUnavailableReason != nil)
                }
                if let reason = model.keepMixedPhaseUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Text("Keeping the design that is not applied needs a new verification before you can save.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func keepButton(_ title: String, kind: SystemSetupDesignKind, prominent: Bool) -> some View {
        if prominent {
            Button(title) { model.keepABXCandidate(kind) }.buttonStyle(.borderedProminent)
        } else {
            Button(title) { model.keepABXCandidate(kind) }
        }
    }
}
