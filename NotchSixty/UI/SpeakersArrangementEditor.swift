import SwiftUI

// E12 S16 (G17): the speaker arrangement editor on the Speakers tab. The views are the wizard's Speakers step (they
// take any `SpeakerArrangementEditing`), and every change is written by `SystemArrangementApplier`, the same code the
// wizard uses. A change marks the calibration out of date through the stamp (E12 S15).

/// What the Speakers step reads and edits. The wizard's flow model and the tab's editor model both conform.
@MainActor
protocol SpeakerArrangementEditing: ObservableObject {
    var topologyPreset: SystemSetupTopologyPreset { get set }
    var speakerChoices: SystemSetupSpeakerChoices { get }
    var arrangement: SystemArrangement? { get }
    var capabilityRows: [(feature: SystemFeature, availability: CapabilityAvailability)] { get }
    func chooseLayout(_ layout: OutputProgramLayout)
    func chooseBass(_ bass: BassHandling)
    func chooseReceiverBass(_ receiverBass: ReceiverBass)
    func chooseSubwooferCount(_ count: Int)
}

@MainActor
final class SpeakersArrangementEditorModel: ObservableObject, SpeakerArrangementEditing {
    private let engine: AudioIOEngine
    private let profiles: ProductProfileController
    @Published var topologyPreset = SystemSetupTopologyPreset(topology: .stereo) {
        didSet { if topologyPreset != oldValue, !isLoading { crossoverChanged() } }
    }
    @Published private(set) var speakerChoices = SystemSetupSpeakerChoices()
    @Published private(set) var arrangement: SystemArrangement?
    @Published var message: String?
    private var isLoading = false

    init(engine: AudioIOEngine, profiles: ProductProfileController) {
        self.engine = engine
        self.profiles = profiles
        reload()
    }

    private var detectedChannelCount: Int { Int(engine.selectedOutputDevice?.outputChannelCount ?? 0) }

    /// Reads the stored arrangement (or derives one from the stored bass settings, as the wizard does).
    func reload() {
        isLoading = true
        defer { isLoading = false }
        let snapshot = profiles.captureSystemState()
        topologyPreset = SystemSetupTopologyPreset.current(from: snapshot)
        let stored = profiles.selectedSystemProfile?.state.systemArrangement
        let resolved = stored
            ?? SystemArrangementMigration.derive(from: snapshot, detectedChannelCount: detectedChannelCount)
            ?? SystemSetupArrangementPlanner.arrangement(
                deviceUID: engine.selectedOutputDevice?.uid ?? "", detectedChannelCount: detectedChannelCount,
                channelsInUse: 2, choices: SystemSetupSpeakerChoices())
        arrangement = resolved
        speakerChoices = SystemSetupArrangementPlanner.choices(from: resolved)
    }

    var capabilityRows: [(feature: SystemFeature, availability: CapabilityAvailability)] {
        guard let arrangement else { return [] }
        return SystemSetupArrangementPlanner.capabilityRows(arrangement, deviceChannelCount: detectedChannelCount)
    }

    func chooseLayout(_ layout: OutputProgramLayout) { speakerChoices.layout = layout; rebuildAndApply() }

    func chooseBass(_ bass: BassHandling) {
        speakerChoices.bass = bass
        if bass == .dspToSubOutputs || bass.isDownstream, speakerChoices.subwooferCount == 0 {
            speakerChoices.subwooferCount = 1
        }
        rebuildAndApply()
    }

    func chooseReceiverBass(_ receiverBass: ReceiverBass) {
        speakerChoices.receiverBass = receiverBass
        rebuildAndApply()
    }

    func chooseSubwooferCount(_ count: Int) {
        speakerChoices.subwooferCount = min(max(count, 0), SystemArrangement.maxSubwoofers)
        rebuildAndApply()
    }

    private func crossoverChanged() {
        guard arrangement != nil else { return }
        rebuildAndApply()
    }

    /// Rebuilds the arrangement from the choices and writes it. A refusal puts everything back and says why.
    private func rebuildAndApply() {
        let previousArrangement = arrangement
        let previousChoices = SystemSetupArrangementPlanner.choices(
            from: previousArrangement ?? SystemSetupArrangementPlanner.arrangement(
                deviceUID: "", detectedChannelCount: detectedChannelCount, channelsInUse: 2,
                choices: SystemSetupSpeakerChoices()))
        let base = profiles.captureSystemState()
        let uid = engine.selectedOutputDevice?.uid ?? previousArrangement?.outputs.deviceUID ?? ""
        let updated = SystemSetupArrangementPlanner.arrangement(
            deviceUID: uid, detectedChannelCount: detectedChannelCount,
            channelsInUse: previousArrangement?.outputs.channelsInUse ?? 2,
            choices: speakerChoices, keeping: previousArrangement)
        profiles.stampBeforeManualChange(
            hadConfiguration: SpeakerFeedTable.hadConfiguration(
                arrangement: profiles.selectedSystemProfile?.state.systemArrangement, bass: base.bassManagement))
        do {
            try SystemArrangementApplier.apply(
                updated, base: base, topologyPreset: topologyPreset, profiles: profiles, engine: engine)
            arrangement = updated
            let layout = speakerChoices.layout
            speakerChoices = SystemSetupArrangementPlanner.choices(from: updated)
            speakerChoices.layout = layout
            message = nil
        } catch {
            message = error.localizedDescription
            restore(base: base, previous: previousArrangement)
            arrangement = previousArrangement
            speakerChoices = previousChoices
        }
    }

    /// Puts the stored bass settings and arrangement back after a refused edit.
    private func restore(base: PlaybackSystemState, previous: SystemArrangement?) {
        try? profiles.replaceSelectedSystemOutputDeviceProfile(nil)
        try? profiles.replaceSelectedSystemBassManagement(base.bassManagement)
        if let profile = base.outputDeviceProfile { try? profiles.replaceSelectedSystemOutputDeviceProfile(profile) }
        try? profiles.replaceSelectedSystemArrangement(previous)
    }
}

/// The editor card on the Speakers tab: the wizard's Speakers step in a titled box.
struct SpeakersArrangementEditorCard: View {
    @StateObject private var model: SpeakersArrangementEditorModel
    @ObservedObject var profiles: ProductProfileController

    init(engine: AudioIOEngine, profiles: ProductProfileController) {
        self.profiles = profiles
        _model = StateObject(wrappedValue: SpeakersArrangementEditorModel(engine: engine, profiles: profiles))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Speaker arrangement").font(DesignType.sectionTitle.font)
            Text("Changing this marks your calibration out of date; measure again afterwards.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
            SystemSetupSpeakersStep(model: model)
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignType.label.font)
                    .foregroundStyle(StatusLevel.problem.color)
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: DesignRadius.medium.pt))
        .onChange(of: profiles.selectedSystemProfileID) { _, _ in model.reload() }
    }
}
