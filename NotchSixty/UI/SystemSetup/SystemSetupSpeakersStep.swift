import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupSpeakersStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        let inUse = model.arrangement?.outputs.channelsInUse ?? 2
        let choices = model.speakerChoices
        VStack(alignment: .leading, spacing: 10) {
            Text("What speakers do you have?").font(.headline)
            Picker("Speaker layout", selection: Binding(get: { choices.layout }, set: { model.chooseLayout($0) })) {
                ForEach(OutputProgramLayout.allCases) { Text($0.displayName).tag($0) }
            }
            Text("How is bass handled?").font(.headline)
            ForEach(SystemSetupArrangementPlanner.bassChoices(channelsInUse: inUse, layout: choices.layout), id: \.self) { bass in
                Button { model.chooseBass(bass) } label: {
                    Label(SystemSetupArrangementPlanner.title(bass),
                          systemImage: choices.bass == bass ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.plain)
            }
            if choices.bass == .dspToSubOutputs || choices.bass.isDownstream {
                Stepper("Subwoofers: \(choices.subwooferCount)",
                        value: Binding(get: { choices.subwooferCount }, set: { model.chooseSubwooferCount($0) }),
                        in: 1...SystemArrangement.maxSubwoofers)
            }
            if choices.bass == .dspMonoToMains || choices.bass == .dspToSubOutputs {
                Stepper(
                    "Crossover \(Int(model.topologyPreset.crossoverHz)) Hz",
                    value: $model.topologyPreset.crossoverHz,
                    in: SystemSetupTopologyPreset.crossoverRangeHz, step: 5)
            }
            if choices.bass == .downstreamReceiver {
                Text(SystemCapabilityMatrix.receiverAdvice).font(.caption).foregroundStyle(.secondary)
            }
            if choices.bass.isDownstream {
                SystemSetupReceiverBassPicker(receiverBass: choices.receiverBass) { model.chooseReceiverBass($0) }
            }
            Divider()
            Text("What this arrangement can do").font(.headline)
            ForEach(Array(model.capabilityRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: row.availability.isUsable ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(row.availability.isUsable ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.feature.displayName).font(.callout)
                        Text(row.availability.text).font(.caption).foregroundStyle(.secondary)
                        if case .unavailable(_, let fix?) = row.availability {
                            Text(fix).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// E26 S1: declares how the receiver (or powered sub) handles bass. Quiet Zone is refused through it until this is set.
/// The crossover entry appears only for calibrated LFE out.
struct SystemSetupReceiverBassPicker: View {
    let receiverBass: ReceiverBass
    let onChange: (ReceiverBass) -> Void

    private enum Kind: Hashable { case undeclared, openPreout, calibratedLFE }
    private var kind: Kind {
        switch receiverBass {
        case .undeclared: return .undeclared
        case .openPreout: return .openPreout
        case .calibratedLFE: return .calibratedLFE
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How does it handle bass?").font(.subheadline.bold())
            Picker("Receiver bass", selection: Binding(
                get: { kind },
                set: { newKind in
                    switch newKind {
                    case .undeclared: onChange(.undeclared)
                    case .openPreout: onChange(.openPreout)
                    case .calibratedLFE: onChange(.calibratedLFE(crossoverHz: ReceiverBass.defaultCrossoverHz))
                    }
                })) {
                Text("Not set").tag(Kind.undeclared)
                Text("\(SystemSetupTerm.openSubPreout.plainLabel) (open sub pre-out)").tag(Kind.openPreout)
                Text("\(SystemSetupTerm.calibratedLFEOut.plainLabel) (calibrated LFE out)").tag(Kind.calibratedLFE)
            }
            if case .calibratedLFE(let hz) = receiverBass {
                Stepper(
                    "Receiver crossover \(Int(hz)) Hz",
                    value: Binding(get: { hz }, set: { onChange(.calibratedLFE(crossoverHz: $0)) }),
                    in: ReceiverBass.crossoverRangeHz, step: 5)
            }
            if !receiverBass.isDeclared {
                Text(TwoChannelAncArming.undeclaredReceiverRefusal).font(.caption).foregroundStyle(.orange)
            }
            Text(ReceiverBass.setupNote).font(.caption).foregroundStyle(.secondary)
            SystemSetupTermNotes(step: .topology)
        }
    }
}
