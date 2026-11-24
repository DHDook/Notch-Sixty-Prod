import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

struct SystemSetupOutputStep: View {
    @ObservedObject var model: SystemSetupFlowModel
    private var engine: AudioIOEngine

    init(model: SystemSetupFlowModel) {
        self.model = model
        engine = model.engine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which output plays your speakers?").font(.headline)
            Picker("Output", selection: Binding(
                get: { engine.selectedOutputDevice?.uid ?? "" },
                set: { if !$0.isEmpty { model.chooseOutput(uid: $0) } }
            )) {
                Text("Choose an output").tag("")
                ForEach(engine.outputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            if let device = engine.selectedOutputDevice {
                Text("Runs at \(device.nominalSampleRate, specifier: "%g") Hz, the device's own rate.")
                    .font(.caption).foregroundStyle(.secondary)
                if SystemSetupEntryPolicy.isHeadphoneOutput(
                    name: device.name, uid: device.uid, state: model.profiles.selectedSystemProfile?.state) {
                    Label("This looks like headphones. Use the Headphones workspace for headphone correction.",
                          systemImage: "headphones")
                        .font(.callout)
                }
                if let arrangement = model.arrangement {
                    let detected = model.detectedChannelCount
                    Picker("Output channels in use", selection: Binding(
                        get: { arrangement.outputs.channelsInUse }, set: { model.chooseChannelCount($0) }
                    )) {
                        ForEach(SystemSetupArrangementPlanner.channelChoices(detected: detected), id: \.self) {
                            Text("\($0) channels").tag($0)
                        }
                    }
                    Text(detected > 0
                         ? "This device reports \(detected) output channels. Lower the number if you wire fewer."
                         : "This device did not report its channel count, so two channels are assumed.")
                        .font(.caption).foregroundStyle(.secondary)
                    if arrangement.outputs.channelsInUse == 2 {
                        Text("Two channels can still feed a receiver or a powered subwoofer. Describe that on the next step.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
