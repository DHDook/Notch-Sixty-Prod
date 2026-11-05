import SwiftUI

/// E25 S8b (flag): the Speakers-tab card that chooses the wider program source device and
/// how the fold treats the LFE channel and headroom. Hidden with the flag off and for direct multi-output systems.
struct ProductionProgramSourceCard: View {
    @StateObject private var controller: ProgramSourceController

    init(engine: AudioIOEngine, profiles: ProductProfileController) {
        _controller = StateObject(wrappedValue: ProgramSourceController(engine: engine, profiles: profiles))
    }

    var body: some View {
        if controller.isVisible {
            VStack(alignment: .leading, spacing: 12) {
                Text("Program source").font(.headline)
                Text("A 5.1 or 7.1 program is folded to your two speaker feeds before any other processing.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Source device", selection: Binding(
                    get: { controller.foldDown.programSourceDeviceUID },
                    set: { controller.setSource(uid: $0) }
                )) {
                    Text("None (player or macOS folds)").tag(String?.none)
                    ForEach(controller.candidates) { device in
                        Text("\(device.name) · \(device.outputChannelCount) ch").tag(Optional(device.uid))
                    }
                }
                .disabled(!controller.foldApplies)

                Picker("LFE channel", selection: Binding(
                    get: { controller.foldDown.lfe }, set: { controller.setLFE($0) }
                )) {
                    Text("Drop (ITU default)").tag(FoldDownLFEMode.drop)
                    Text("Fold at +10 dB with limiter").tag(FoldDownLFEMode.foldPlus10dBWithLimiter)
                }
                .disabled(!controller.foldApplies || !controller.foldDown.isActive)

                Picker("Headroom", selection: Binding(
                    get: { controller.foldDown.headroom }, set: { controller.setHeadroom($0) }
                )) {
                    Text("None (limiter at the output)").tag(FoldDownHeadroom.none)
                    Text("Peak-safe (no input can clip)").tag(FoldDownHeadroom.peakSafe)
                }
                .disabled(!controller.foldApplies || !controller.foldDown.isActive)

                Text(controller.resolutionText).font(.callout)
                if controller.foldApplies, controller.foldDown.isActive {
                    Text(controller.lfeNote).font(.caption).foregroundStyle(.secondary)
                    Text(ProgramSourceController.rebuildNote).font(.caption).foregroundStyle(.secondary)
                }
                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.quaternary, lineWidth: 0.5) }
        }
    }
}
