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
            VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
                Text("Program source").font(DesignType.sectionTitle.font)
                Text("A 5.1 or 7.1 program is folded to your two speaker feeds before any other processing.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)

                Picker("Source device", selection: Binding(
                    get: { controller.foldDown.programSourceDeviceUID },
                    set: { controller.setSource(uid: $0) }
                )) {
                    Text("None (player or macOS folds)").tag(String?.none)
                    Text("Notch Sixty virtual driver (needs the driver)").tag(Optional(ProgramFoldDown.driverSourceUID))
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

                Text(controller.resolutionText).font(DesignType.label.font)
                if controller.foldDown.usesDriverSource {
                    Text(ProgramSourceController.driverSourceNote).font(DesignType.caption.font).foregroundStyle(.secondary)
                }
                if controller.foldApplies, controller.foldDown.isActive {
                    Text(controller.lfeNote).font(DesignType.caption.font).foregroundStyle(.secondary)
                    Text(ProgramSourceController.rebuildNote).font(DesignType.caption.font).foregroundStyle(.secondary)
                }
                if let error = controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(DesignType.label.font).foregroundStyle(StatusLevel.problem.color)
                }
            }
            .padding(DesignSpacing.l.pt)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: DesignRadius.large.pt))
            .overlay { RoundedRectangle(cornerRadius: DesignRadius.large.pt, style: .continuous).stroke(.quaternary, lineWidth: 0.5) }
        }
    }
}
