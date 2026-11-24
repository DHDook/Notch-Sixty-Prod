import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProductionHeadphoneWorkspace: View {
    var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    /// E13 S7: the measurement path the BRIR capture uses; nil hides the capture button.
    var calibration: MultichannelCalibrationController?

    @State private var draft = HeadphoneDeviceProfileConfiguration()
    /// E13 S3: previews draft edits on the running graph without saving them.
    @State private var tuner: HeadphoneLiveTuner?
    @State private var importingSpatialProfile = false
    @State private var importingEQProposal = false
    @State private var pendingEQProposal: HeadphoneCorrectionProposal?
    @State private var importingModelResponse = false
    @State private var modelRecords: [HeadphoneModelMeasurement] = []
    @State private var selectedModelID: UUID?
    @State private var modeledCorrection: HeadphoneModelFitResult?
    @State private var availableImportedHRTFs: [BinauralProfileAsset] = []
    // E13 S2: bring-your-own responses and one-click fit.
    @State private var importingResponses = false
    @State private var importingAPOPreset = false
    @State private var storedResponses: [HeadphoneResponseRecord] = []
    @State private var selectedResponseID: UUID?
    @State private var headphoneTargets: [RoomCorrectionTargetCurve] = [RoomCorrectionBuiltInTarget.flat.curve]
    @State private var selectedTargetID: UUID? = RoomCorrectionBuiltInTarget.flat.curve.id
    @State private var oneClick = HeadphoneOneClickSession()
    @State private var oneClickFit: HeadphoneAutoFitResult?
    @State private var fitting = false
    @State private var brirFlow: BRIRCaptureFlow?
    // E13 S9 (`e13.headphones-page`).
    @State private var shaping = HeadphoneTargetShaping()
    @State private var autoHeadroom = false
    @State private var recordTargets: [UUID: RoomCorrectionTargetCurve] = [:]
    @State private var fitPreview: HeadphoneFitPreview?
    // E13 S10: the headphone list.
    @State private var renamingHeadphones = false
    @State private var deletingHeadphones = false
    @State private var renameText = ""
    /// The page clean-up is on only behind its flag; off, the page is as shipped by S8.
    private var cleanPage: Bool { FeatureFlags().isEnabled(.headphonesPage) }
    private static let sofaFileType: UTType =
        UTType(filenameExtension: "sofa")
            ?? UTType(importedAs: "org.aes69.sofa", conformingTo: .data)

    private var selectedSampleRate: Double? {
        engine.selectedOutputDevice?.nominalSampleRate
    }

    // A display fallback ONLY when no output is selected; Apply requires a
    // real selected device and its actual rate for activation validation.
    private var previewSampleRate: Double {
        selectedSampleRate ?? 48_000
    }
    @State private var actionError: String?
    @State private var statusMessage: String?

    var body: some View {
        ProductionPageContainer {
            VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
                header
                SystemCapabilityNoteCard(
                    title: "With your speaker arrangement", features: SystemCapabilityText.headphoneFeatures, profiles: profiles)
                if cleanPage { headphonePickerCard }
                modeCard
                correctionCard
                perEarEQCard
                oneClickFitCard
                crossfeedCard
                if draft.spatialMode == .virtualSpeakers {
                    spatialCard
                }
                deploymentCard

                if let error = actionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(StatusLevel.problem.color)
                        .textSelection(.enabled)
                        .padding(DesignSpacing.l.pt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .designTint(StatusLevel.problem.color, opacity: 0.08, radius: .medium)
                } else if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(DesignSpacing.l.pt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .designTint(StatusLevel.off.color, opacity: 0.06, radius: .medium)
                }
            }
        }
        .task {
            syncFromSelectedSystem()
            loadSavedModelMeasurements()
            loadImportedHRTFs()
            loadResponsesAndTargets()
        }
        .task(id: profiles.selectedSystemProfileID) { syncFromSelectedSystem() }
        .onChange(of: draft.spatialMode) { _, mode in
            // E13 S11: Virtual Speakers works at once with the built-in generic head model.
            if cleanPage, mode == .virtualSpeakers, draft.binauralProfile == nil {
                draft.binauralProfile = GenericHRTF.reference
            }
        }
        .onChange(of: draft) { _, newDraft in
            keepAutoHeadroom(newDraft)
            previewLive(newDraft)
        }
        .onChange(of: selectedResponseID) { _, _ in adoptRecordTarget(); refreshFitPreview() }
        .onChange(of: selectedTargetID) { _, _ in refreshFitPreview() }
        .onChange(of: shaping) { _, _ in refreshFitPreview() }
        .onChange(of: engine.lifecycleState) { _, _ in restoreLivePreview() }
        .onDisappear { restoreLivePreview() }
        .sheet(isPresented: Binding(
            get: { brirFlow != nil },
            set: { if !$0 { brirFlow?.cancel(); brirFlow = nil } }
        )) {
            if let brirFlow, let calibration {
                BRIRCaptureSheet(
                    flow: brirFlow, microphone: calibration.microphone,
                    onSaved: { brirCaptured($0) },
                    onClose: { brirFlow.cancel(); self.brirFlow = nil })
            }
        }
        .fileImporter(
            isPresented: $importingSpatialProfile,
            allowedContentTypes: [.json, Self.sofaFileType],
            allowsMultipleSelection: false
        ) { result in
            importSpatialProfile(result)
        }
        .fileImporter(
            isPresented: $importingEQProposal,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importEQProposal(result)
        }
        .fileImporter(
            isPresented: $importingResponses,
            allowedContentTypes: cleanPage ? [.plainText, .text, .commaSeparatedText, .json] : [.plainText, .text, .commaSeparatedText],
            allowsMultipleSelection: true
        ) { result in
            importHeadphoneResponses(result)
        }
        .fileImporter(
            isPresented: $importingAPOPreset,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            importAPOPreset(result)
        }
        .fileImporter(
            isPresented: $importingModelResponse,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importLocalModelMeasurement(result)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text(cleanPage
                 ? "Headphone correction is separate from your Content Presets. Stereo keeps your normal sound settings; Virtual Speakers plays surround sound through a head model (an HRTF or BRIR) before correction and the final safety limiter."
                 : "Keep headphone hardware correction separate from Content Presets. Stereo mode preserves the normal content DSP chain; Virtual Speakers renders semantic program channels through a prepared HRTF or BRIR before headphone correction and true-peak protection.")
                .foregroundStyle(.secondary)
        }
    }

    private var listeningModePicker: some View {
        Picker("Listening Mode", selection: $draft.spatialMode) {
            ForEach(HeadphoneSpatialMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .frame(maxWidth: 260)
    }

    // E13 S10 (`e13.headphones-page`): the list of headphones in this Playback System.
    private var headphoneList: HeadphoneList { profiles.selectedSystemHeadphoneList ?? HeadphoneList() }

    private var headphonePickerCard: some View {
        let list = headphoneList
        let current = list.selected
        let output = engine.selectedOutputDevice
        return VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Headphones").font(DesignType.sectionTitle.font)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpacing.m.pt) {
                    headphonePicker(list)
                    headphoneButtons(current)
                }
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                    headphonePicker(list)
                    headphoneButtons(current)
                }
            }
            if let current {
                Toggle(isOn: Binding(
                    get: { current.linkedOutputUID != nil && current.linkedOutputUID == output?.uid },
                    set: { linkHeadphones(current.id, on: $0) }
                )) {
                    Text(output.map { "Use these for \($0.name)" } ?? "Use these for the current output")
                }
                .disabled(output == nil)
                Text(current.linkedOutputUID == nil
                     ? "Not linked to an output: pick them by hand (for example a wired pair on a DAC)."
                     : "Linked to an output device. Switching to a linked device picks these automatically once output following is available.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            } else {
                Text("No headphones saved yet. Apply the settings below, or add a pair to start a list.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designTint(StatusLevel.off.color, opacity: 0.06, radius: .medium)
        .alert("Rename Headphones", isPresented: $renamingHeadphones) {
            TextField("Name", text: $renameText)
            Button("Rename") { renameCurrentHeadphones() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete these headphones?", isPresented: $deletingHeadphones, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrentHeadphones() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their correction is removed. Your other headphones are not changed.")
        }
    }

    private func headphonePicker(_ list: HeadphoneList) -> some View {
        Picker("Current headphones", selection: Binding<UUID?>(
            get: { list.selectedID },
            set: { id in if let id { selectHeadphones(id) } }
        )) {
            if list.entries.isEmpty { Text("None saved").tag(UUID?.none) }
            ForEach(list.entries) { entry in Text(entry.name).tag(UUID?.some(entry.id)) }
        }
        .frame(maxWidth: 320)
        .disabled(list.entries.isEmpty)
    }

    private func headphoneButtons(_ current: HeadphoneListEntry?) -> some View {
        HStack(spacing: DesignSpacing.s.pt) {
            Button("Add") { editHeadphoneList { list in
                let id = try list.add(
                    name: "Headphones", enabled: draft.enabled, outputDeviceUID: engine.selectedOutputDevice?.uid)
                try list.select(id)
            } }
            Button("Duplicate") { editHeadphoneList { list in
                if let current { try list.select(try list.duplicate(current.id)) }
            } }.disabled(current == nil)
            Button("Rename") { renameText = current?.name ?? ""; renamingHeadphones = true }.disabled(current == nil)
            Button("Delete", role: .destructive) { deletingHeadphones = true }.disabled(current == nil)
        }
    }

    private func editHeadphoneList(_ change: (inout HeadphoneList) throws -> Void) {
        actionError = nil
        statusMessage = nil
        restoreLivePreview()
        do {
            try profiles.editSelectedSystemHeadphoneList(change)
            syncFromSelectedSystem()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func selectHeadphones(_ id: UUID) {
        editHeadphoneList { try $0.select(id) }
    }

    private func linkHeadphones(_ id: UUID, on: Bool) {
        let uid = on ? engine.selectedOutputDevice?.uid : nil
        editHeadphoneList { try $0.link(id, toOutputUID: uid) }
    }

    private func renameCurrentHeadphones() {
        guard let id = headphoneList.selectedID else { return }
        let name = renameText
        editHeadphoneList { try $0.rename(id, to: name) }
    }

    private func deleteCurrentHeadphones() {
        guard let id = headphoneList.selectedID else { return }
        editHeadphoneList { try $0.delete(id) }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                Text("Headphone Device Profile").font(DesignType.sectionTitle.font)
                Spacer()
                Toggle("Headphone Device Profile", isOn: $draft.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            LabeledContent("Playback System") {
                Text(profiles.selectedSystemProfileName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Headphone Output") {
                Text(engine.selectedOutputDevice?.name ?? "No output selected")
                    .foregroundStyle(engine.selectedOutputDevice == nil ? StatusLevel.problem.color : .secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpacing.l.pt) {
                    if !cleanPage {
                        TextField("Profile Name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    listeningModePicker
                }
                listeningModePicker
            }

            Text(draft.spatialMode == .stereo
                 ? "Stereo: the existing EQ, dynamics and convolution chain remains available; headphone correction is applied immediately before final protection."
                 : cleanPage
                 ? "Virtual Speakers: surround sound is mixed down to two ears first. Stereo-only effects stay neutral because they cannot be applied fairly to a surround source."
                 : "Virtual Speakers: multichannel decoded PCM is rendered to two ears first. Stereo-only creative DSP must be neutral because it cannot be applied honestly to an arbitrary semantic multichannel source.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
        .designPanel()
    }

    private var correctionCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                Text("Device Correction").font(DesignType.sectionTitle.font)
                Spacer()
                bypassSwitch(.correction, label: "Bypass correction")
            }

            HStack(spacing: DesignSpacing.xl.pt) {
                if !cleanPage {
                    VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                        Text("Target").font(DesignType.caption.font.bold()).foregroundStyle(.secondary)
                        Picker("Target", selection: $draft.targetCurve) {
                            ForEach(HeadphoneTargetCurve.allCases) { target in
                                Text(target.displayName).tag(target)
                            }
                        }
                        .labelsHidden()
                    }
                }
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                    Text("Correction Headroom").font(DesignType.caption.font.bold()).foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $draft.headroomAttenuationDB, in: 0...30, step: 0.5)
                        .designSlider("Correction headroom", value: draft.headroomAttenuationDB, unit: .db)
                        .disabled(cleanPage && autoHeadroom)
                        Text("\(draft.headroomAttenuationDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 68, alignment: .trailing)
                    }
                    if cleanPage {
                        Toggle("Auto", isOn: $autoHeadroom)
                            .toggleStyle(.switch)
                            .help("Sets the headroom from the EQ boosts and keeps it in step as you edit. Turning it off keeps the last value.")
                            .onChange(of: autoHeadroom) { _, on in if on { keepAutoHeadroom(draft) } }
                    }
                }
            }

            Divider()
            HStack(alignment: .top, spacing: DesignSpacing.xl.pt) {
                channelControls(title: "Left", correction: binding(\.left))
                channelControls(title: "Right", correction: binding(\.right))
            }

            Text(cleanPage
                 ? "Each ear has 16 EQ bands that you can switch on separately. The graph below shows what the filters do to the signal."
                 : "Device correction is separate from Content Presets. The editor below exposes all 16 independently enabled parametric EQ bands per ear, with a preview of the electrical DSP response.")
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)

            let required = draft.conservativeRequiredHeadroomDB
            HStack {
                Label(
                    String(format: "Conservative positive-gain allowance: %.1f dB", required),
                    systemImage: "waveform.path"
                )
                .font(DesignType.caption.font)
                Spacer()
                Text(
                    draft.headroomAttenuationDB + 0.000001 >= required
                        ? "Headroom covered" : "Increase headroom before applying"
                )
                .foregroundStyle(
                    draft.headroomAttenuationDB + 0.000001 >= required
                        ? Color.secondary : StatusLevel.attention.color
                )
                .font(DesignType.caption.font.bold())
            }
        }
        .designPanel()
    }

    // MARK: - Batch 3 headphone PEQ completion

    private var perEarEQCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                Text("Per-Ear Parametric Equalizer")
                    .font(DesignType.sectionTitle.font)
                Spacer()
                Text("16 bands per ear")
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(
                "Preview is calculated from the production filter coefficients at "
                + String(format: "%.1f kHz", previewSampleRate / 1000)
                + (selectedSampleRate == nil
                   ? " (illustration only: choose an output to validate)." : ".")
                + " Includes per-ear trim and common attenuation. It is not an acoustic headphone measurement."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
            headphoneResponseGraph
                .frame(height: 210)

            HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                channelEQEditor(
                    "Left ear", correction: binding(\.left),
                    accent: .orange
                )
                channelEQEditor(
                    "Right ear", correction: binding(\.right),
                    accent: .cyan
                )
            }

            if !cleanPage { legacyImportCards }
            if let proposal = pendingEQProposal {
                pendingProposalCard(proposal)
            }
        }
        .designPanel()
    }

    /// The two cards `e13.headphones-page` removes: "Import EQ Proposal" and the local model measurement library.
    private var legacyImportCards: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Optional local correction proposal").font(.subheadline.bold())
                    Text(
                        "Import a user-supplied, explicitly attributed JSON PEQ proposal. It is reviewed as a draft and never downloads, automatically selects, or distributes a model correction database."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Import EQ Proposal…") {
                    importingEQProposal = true
                }
                .buttonStyle(.glass)
            }
            modelCorrectionLibraryCard
        }
    }

    private func pendingProposalCard(_ proposal: HeadphoneCorrectionProposal) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Divider()
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                    Text(proposal.headphoneModel)
                        .font(.subheadline.bold())
                    Text(
                        "Source: " + proposal.sourceName
                        + " · Attribution: " + proposal.sourceAttribution
                        + " · Stated license: " + proposal.sourceLicense
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Text(
                        "This metadata does not establish redistribution rights or verify the measurements. Review before using; no automatic deployment."
                    )
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Stage Bands in Draft") {
                            stageEQProposal(proposal)
                        }
                        .buttonStyle(.glassProminent)
                        Button("Discard") {
                            pendingEQProposal = nil
                        }
                        .buttonStyle(.glass)
                    }
                }
        }
    }

    private var modelCorrectionLibraryCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Divider()
            HStack {
                Text("Local Headphone Model Measurement Library")
                    .font(.subheadline.bold())
                Spacer()
                Button("Import Response JSON…") {
                    importingModelResponse = true
                }
                .buttonStyle(.glass)
                Button("Refresh") {
                    loadSavedModelMeasurements()
                }
                .buttonStyle(.glass)
            }
            Text(
                "Import your own attributed left/right headphone frequency-response measurement and explicit target points. The app fits bounded PEQ proposals using its production biquad coefficients; there is no bundled third-party correction database, network retrieval or individual-ear calibration claim."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
            Picker("Stored measurement", selection: $selectedModelID) {
                Text("Choose local measurement…").tag(UUID?.none)
                ForEach(modelRecords) { model in
                    Text(model.headphoneModel + " · " + model.sourceName)
                        .tag(UUID?.some(model.id))
                }
            }
            if let model = modelRecords.first(where: { $0.id == selectedModelID }) {
                Text(
                    "Credit: " + model.sourceAttribution
                    + " · Stated license: " + model.sourceLicense
                    + " · " + String(model.points.count) + " frequencies"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                Button("Fit Editable PEQ Proposal") {
                    fitLocalModel(model)
                }
                .buttonStyle(.glassProminent)
            }
            if let fit = modeledCorrection {
                Text(
                    String(
                        format: "Modeled target RMSE L %.2f → %.2f dB; R %.2f → %.2f dB; headroom %.2f dB",
                        fit.leftRMSEBeforeDB, fit.leftRMSEAfterDB,
                        fit.rightRMSEBeforeDB, fit.rightRMSEAfterDB,
                        fit.recommendedHeadroomDB
                    )
                )
                .font(DesignType.caption.font.monospacedDigit())
                Text(
                    String(
                        format: "Maximum frequency-by-frequency error regression: %.2f dB",
                        fit.worstFrequencyRegressionDB
                    )
                )
                .font(DesignType.caption.font.monospacedDigit())
                ForEach(fit.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                Button("Review Fitted Bands Below") {
                    pendingEQProposal = fit.proposal
                }
                .buttonStyle(.glass)
                Text("No model fitting automatically changes EQ, saved profiles, or playing audio.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: One-click fit (E13 S2)

    private var oneClickFitCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Fit and apply").font(DesignType.sectionTitle.font)
            Text(cleanPage
                 ? "Import your own headphone measurement: AutoEq CSV, REW or squig.link text, a response JSON or a ready-made EQ JSON. Pick the left and right files together, or one file for both ears. Then choose a target and fit an EQ in one step. Nothing is bundled or downloaded."
                 : "Import your own headphone response (AutoEq CSV, REW or squig.link text; pick left and right files together, or one file for both ears), choose a target, and fit a parametric EQ in one step. Nothing is bundled or downloaded.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
            HStack {
                Button("Import response...") { importingResponses = true }
                Button("Import Equalizer APO preset...") { importingAPOPreset = true }
                Button("Undo", action: undoOneClick).disabled(!oneClick.canUndo)
            }
            Picker("Response", selection: $selectedResponseID) {
                Text("Choose a response...").tag(UUID?.none)
                ForEach(storedResponses) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            Picker("Target", selection: $selectedTargetID) {
                ForEach(headphoneTargets) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if cleanPage { targetShapingControls }
            Button(fitting ? "Fitting..." : "Fit and apply", action: fitAndApply)
                .buttonStyle(.glassProminent)
                .disabled(fitting || selectedResponseID == nil || selectedSampleRate == nil)
            if let fit = oneClickFit {
                Text(String(format: "Error L %.2f to %.2f dB, R %.2f to %.2f dB; headroom %.1f dB",
                            fit.leftRMSEBeforeDB, fit.leftRMSEAfterDB, fit.rightRMSEBeforeDB, fit.rightRMSEAfterDB,
                            fit.recommendedHeadroomDB))
                    .font(DesignType.caption.font.monospacedDigit())
                ForEach(fit.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(DesignType.caption.font).foregroundStyle(.secondary) }
            }
            if cleanPage, let preview = fitPreview { fitGraph(preview) }
        }
        .designPanel()
    }

    private var targetShapingControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text("Shape the target").font(DesignType.caption.font.bold()).foregroundStyle(.secondary)
            HStack {
                Text("Bass").frame(width: 70, alignment: .leading)
                Slider(value: $shaping.bassShelfDB, in: HeadphoneTargetShaping.shelfRangeDB, step: 0.5)
                    .designSlider("Target bass shelf", value: shaping.bassShelfDB, unit: .db)
                Text(String(format: "%+.1f dB", shaping.bassShelfDB)).monospacedDigit()
                    .frame(width: 68, alignment: .trailing)
            }
            HStack {
                Text("Treble").frame(width: 70, alignment: .leading)
                Slider(value: $shaping.trebleTiltDB, in: HeadphoneTargetShaping.tiltRangeDB, step: 0.5)
                    .designSlider("Target treble tilt", value: shaping.trebleTiltDB, unit: .db)
                Text(String(format: "%+.1f dB", shaping.trebleTiltDB)).monospacedDigit()
                    .frame(width: 68, alignment: .trailing)
            }
            .font(DesignType.caption.font)
            Text("Bass lifts or lowers everything below about 100 Hz. Treble tilts the sound from 1 kHz up to 10 kHz. Works on top of the chosen target, so Flat can be shaped without a file.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
        }
    }

    private func fitGraph(_ preview: HeadphoneFitPreview) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Label("Imported", systemImage: "waveform").foregroundStyle(.secondary)
                Label("Target", systemImage: "scope").foregroundStyle(.green)
                Label("After EQ (left)", systemImage: "waveform").foregroundStyle(.orange)
                Label("After EQ (right)", systemImage: "waveform").foregroundStyle(.cyan)
            }
            .font(DesignType.caption.font)
            Canvas { context, size in
                let width = max(size.width, 1), height = max(size.height, 1)
                let minDB = -20.0, maxDB = 20.0
                let curves: [([Double], Color)] = [
                    (preview.responseLeftDB, Color.secondary.opacity(0.6)), (preview.responseRightDB, Color.secondary.opacity(0.6)),
                    (preview.targetDB, Color.green),
                    (preview.predictedLeftDB, Color.orange), (preview.predictedRightDB, Color.cyan)
                ]
                for (values, color) in curves where values.count > 1 {
                    var path = Path()
                    for (i, db) in values.enumerated() {
                        let x = CGFloat(i) / CGFloat(values.count - 1) * width
                        let y = CGFloat(min(1, max(0, (maxDB - db) / (maxDB - minDB)))) * height
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(path, with: .color(color), lineWidth: 1.5)
                }
            }
            .frame(height: 180)
            Text("20 Hz to 20 kHz, level-matched at 250 Hz to 2.5 kHz; vertical range 40 dB.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
        }
    }

    /// The target the fit uses: the picked target with the bass and treble shaping on top (page flag on).
    private var effectiveTarget: RoomCorrectionTargetCurve? {
        let base = headphoneTargets.first { $0.id == selectedTargetID }
        return cleanPage ? HeadphoneTargetShaping.shaped(base: base, shaping: shaping) : base
    }

    private func keepAutoHeadroom(_ newDraft: HeadphoneDeviceProfileConfiguration) {
        guard cleanPage, autoHeadroom else { return }
        let value = HeadphoneAutoHeadroom.headroomDB(for: newDraft)
        if draft.headroomAttenuationDB != value { draft.headroomAttenuationDB = value }
    }

    private func adoptRecordTarget() {
        guard cleanPage, let id = selectedResponseID, let target = recordTargets[id] else { return }
        if !headphoneTargets.contains(where: { $0.id == target.id }) { headphoneTargets.append(target) }
        selectedTargetID = target.id
    }

    private func refreshFitPreview() {
        guard cleanPage, let rate = selectedSampleRate,
              let record = storedResponses.first(where: { $0.id == selectedResponseID }) else { fitPreview = nil; return }
        fitPreview = try? HeadphoneFitPreview.make(record: record, target: effectiveTarget, draft: draft, sampleRate: rate)
    }

    private func loadResponsesAndTargets() {
        storedResponses = HeadphoneResponseStore().loadAll().records
        if cleanPage {
            // Stored library records stay readable from the Response picker (their card is gone).
            let stored = (try? HeadphoneModelMeasurementLibrary().list(sampleRate: previewSampleRate)) ?? []
            for model in stored where !storedResponses.contains(where: { $0.id == model.id }) {
                let (record, target) = HeadphoneResponseRecord.make(from: model)
                storedResponses.append(record)
                if let target { recordTargets[record.id] = target }
            }
        }
        let user = TargetLibrary().loadAll().records.filter {
            !TargetLibrary.isBuiltIn($0.id) && ($0.category == .headphone || $0.category == .general)
        }
        headphoneTargets = [RoomCorrectionBuiltInTarget.flat.curve] + user.map(\.curve)
        if !headphoneTargets.contains(where: { $0.id == selectedTargetID }) {
            selectedTargetID = RoomCorrectionBuiltInTarget.flat.curve.id
        }
    }

    private func importHeadphoneResponses(_ result: Result<[URL], Error>) {
        actionError = nil
        do {
            let urls = try result.get()
            guard !urls.isEmpty, urls.count <= 2 else { throw HeadphoneResponseError.pairingFailed }
            if cleanPage, urls.count == 1, urls[0].pathExtension.lowercased() == "json" {
                try importJSON(urls[0])
                return
            }
            var curves: [ImportedCurve] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                curves.append(try FrequencyResponseImporter.parse(
                    Data(contentsOf: url), sourceName: url.deletingPathExtension().lastPathComponent))
            }
            let record = try HeadphoneResponseRecord.make(from: curves)
            try HeadphoneResponseStore().save(record)
            loadResponsesAndTargets()
            selectedResponseID = record.id
            statusMessage = "Imported \(record.name). Choose a target and press Fit and apply."
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Fit and apply accepts both JSON formats: a response (with its target) is stored and selected; a ready-made
    /// EQ proposal is staged for review.
    private func importJSON(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let outcome = try HeadphoneImportRouter.importData(
            Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent, sampleRate: previewSampleRate)
        switch outcome {
        case .response(var record, let target):
            record.id = UUID() // Never let an untrusted file's ID overwrite storage.
            try HeadphoneResponseStore().save(record)
            if let target {
                var targetRecord = TargetRecord(curve: target)
                targetRecord.category = .headphone
                try TargetLibrary().save(targetRecord)
                recordTargets[record.id] = target
            }
            loadResponsesAndTargets()
            selectedResponseID = record.id
            statusMessage = "Imported \(record.name). Choose a target and press Fit and apply."
        case .proposal(let proposal):
            pendingEQProposal = proposal
            statusMessage = "EQ file loaded for review below. No bands have been applied."
        }
    }

    private func fitAndApply() {
        actionError = nil
        guard let rate = selectedSampleRate,
              let record = storedResponses.first(where: { $0.id == selectedResponseID }) else { return }
        let target = effectiveTarget
        fitting = true
        Task {
            do {
                let fit = try await Task.detached(priority: .userInitiated) {
                    try HeadphoneAutoFitter.fit(
                        measurement: try record.measurement(target: target, sampleRate: rate), sampleRate: rate)
                }.value
                oneClickFit = fit
                var session = oneClick
                let before = draft
                draft = try session.apply(fit, to: draft, targetID: target?.id, targetName: target?.name, sampleRate: rate)
                applyDraft()
                if actionError != nil { draft = before } else {
                    oneClick = session
                    refreshFitPreview()
                    statusMessage = "Applied a fitted EQ for \(record.name) and enabled the headphone profile. Undo restores the previous profile."
                }
            } catch {
                actionError = error.localizedDescription
            }
            fitting = false
        }
    }

    private func importAPOPreset(_ result: Result<[URL], Error>) {
        actionError = nil
        do {
            guard let url = try result.get().first, let rate = selectedSampleRate else {
                throw HeadphoneDeviceProfileError.outputDeviceRequired
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let preset = try EqualizerAPOPresetImporter.parse(Data(contentsOf: url))
            let proposal = try EqualizerAPOPresetImporter.proposal(
                from: preset, name: url.deletingPathExtension().lastPathComponent, sampleRate: rate)
            var session = oneClick
            let before = draft
            draft = try session.apply(preset: proposal, to: draft, sampleRate: rate)
            applyDraft()
            if actionError != nil { draft = before } else {
                oneClick = session
                statusMessage = "Applied \(preset.bands.count) preset filters to both ears; headroom set from the filters (the preset's own preamp is not used)."
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func undoOneClick() {
        actionError = nil
        guard let previous = oneClick.undo() else { return }
        draft = previous
        applyDraft()
        if actionError == nil { statusMessage = "Restored the profile from before the last fit." }
    }

    private func importLocalModelMeasurement(
        _ result: Result<[URL], Error>
    ) {
        actionError = nil
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let rate = selectedSampleRate else {
                throw HeadphoneDeviceProfileError.outputDeviceRequired
            }
            let model = try HeadphoneModelMeasurementLibrary().importFile(
                url, sampleRate: rate
            )
            loadSavedModelMeasurements()
            selectedModelID = model.id
            modeledCorrection = nil
            statusMessage = "Local model measurement imported with source metadata. No EQ was changed."
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func loadSavedModelMeasurements() {
        do {
            modelRecords = try HeadphoneModelMeasurementLibrary().list(
                sampleRate: previewSampleRate
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func fitLocalModel(_ model: HeadphoneModelMeasurement) {
        actionError = nil
        do {
            guard let rate = selectedSampleRate else {
                throw HeadphoneDeviceProfileError.outputDeviceRequired
            }
            modeledCorrection = try HeadphoneModelCorrectionDesigner().fit(
                measurement: model, sampleRate: rate
            )
            statusMessage = "PEQ proposal generated for manual review only."
        } catch {
            modeledCorrection = nil
            actionError = error.localizedDescription
        }
    }

    private func loadImportedHRTFs() {
        do {
            let store = BinauralProfileAssetStore()
            availableImportedHRTFs = try store.existingAssetIDs().map {
                try store.load(id: $0)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var headphoneResponseGraph: some View {
        let leftCurve = HeadphoneEQResponsePreview.curve(
            draft.left, sampleRate: previewSampleRate,
            headroomAttenuationDB: draft.headroomAttenuationDB
        )
        let rightCurve = HeadphoneEQResponsePreview.curve(
            draft.right, sampleRate: previewSampleRate,
            headroomAttenuationDB: draft.headroomAttenuationDB
        )
        return VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Label("Left", systemImage: "waveform").foregroundStyle(.orange)
                Label("Right", systemImage: "waveform").foregroundStyle(.cyan)
                Spacer()
                Text("20 Hz – 20 kHz · modeled dB")
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(DesignType.caption.font)
            Canvas { context, size in
                let height = max(size.height, 1)
                let width = max(size.width, 1)
                let minDB = -30.0, maxDB = 24.0
                let zeroY = CGFloat((maxDB) / (maxDB - minDB)) * height
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: zeroY))
                zero.addLine(to: CGPoint(x: width, y: zeroY))
                context.stroke(zero, with: .color(.secondary.opacity(0.4)),
                               lineWidth: 1)
                for curve in [
                    (points: leftCurve, color: Color.orange),
                    (points: rightCurve, color: Color.cyan)
                ] {
                    guard curve.points.count > 1 else { continue }
                    var path = Path()
                    for (index, point) in curve.points.enumerated() {
                        let x = CGFloat(index) / CGFloat(curve.points.count - 1)
                            * width
                        let fraction = (maxDB - point.db) / (maxDB - minDB)
                        let y = CGFloat(min(1, max(0, fraction))) * height
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(path, with: .color(curve.color),
                                   style: StrokeStyle(lineWidth: 2))
                }
            }
            .accessibilityLabel("Estimated left and right electrical headphone EQ response")
            .designTint(StatusLevel.off.color, opacity: 0.055)
        }
    }

    private func channelEQEditor(
        _ title: String,
        correction: Binding<HeadphoneChannelCorrection>,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                Circle().fill(accent).frame(width: 9, height: 9)
                Text(title).font(.subheadline.bold())
                Spacer()
                Text("\(correction.wrappedValue.eqBands.count)/16")
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    guard correction.wrappedValue.eqBands.count
                        < Int(N60_HEADPHONE_MAX_EQ_SECTIONS) else { return }
                    var next = correction.wrappedValue
                    next.eqBands.append(HeadphoneCorrectionEQBand())
                    correction.wrappedValue = next
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .disabled(
                    correction.wrappedValue.eqBands.count
                        >= Int(N60_HEADPHONE_MAX_EQ_SECTIONS)
                )
                .buttonStyle(.glass)
            }
            ForEach(
                correction.wrappedValue.eqBands.indices,
                id: \.self
            ) { index in
                perEarBandControls(correction: correction, index: index)
            }
            if correction.wrappedValue.eqBands.isEmpty {
                Text("No filters. Use Add to create a band.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 65)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func perEarBandControls(
        correction: Binding<HeadphoneChannelCorrection>,
        index: Int
    ) -> some View {
        let band = Binding<HeadphoneCorrectionEQBand>(
            get: {
                guard correction.wrappedValue.eqBands.indices.contains(index)
                else { return HeadphoneCorrectionEQBand() }
                return correction.wrappedValue.eqBands[index]
            },
            set: { value in
                guard correction.wrappedValue.eqBands.indices.contains(index)
                else { return }
                var changed = correction.wrappedValue
                changed.eqBands[index] = value
                correction.wrappedValue = changed
            }
        )
        let upper = min(20_000.0, previewSampleRate * 0.45)
        return VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Toggle("Band \(index + 1)", isOn: band.enabled)
                    .toggleStyle(.switch)
                Spacer()
                Button(role: .destructive) {
                    guard correction.wrappedValue.eqBands.indices.contains(index)
                    else { return }
                    var next = correction.wrappedValue
                    next.eqBands.remove(at: index)
                    correction.wrappedValue = next
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete band \(index + 1)")
            }
            Picker("Filter", selection: band.type) {
                ForEach(HeadphoneCorrectionFilterType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            HStack {
                Text("Hz").frame(width: 37, alignment: .leading)
                Slider(
                    value: Binding(
                        get: {
                            log10(min(upper, max(20, band.wrappedValue.frequencyHz)))
                        },
                        set: {
                            band.wrappedValue.frequencyHz = pow(10, $0)
                        }
                    ),
                    in: log10(20.0)...log10(upper),
                    step: 0.01
                )
                .designSlider("Frequency", value: band.wrappedValue.frequencyHz, unit: .hz)
                Text(
                    String(format: "%.0f", band.wrappedValue.frequencyHz)
                )
                .frame(width: 52, alignment: .trailing)
            }
            HStack {
                Text("dB").frame(width: 37, alignment: .leading)
                Slider(value: band.gainDB, in: -18...18, step: 0.25)
                .designSlider("Gain", value: band.wrappedValue.gainDB, unit: .db)
                Text(String(format: "%+.2f", band.wrappedValue.gainDB))
                    .frame(width: 57, alignment: .trailing)
            }
            HStack {
                Text("Q").frame(width: 37, alignment: .leading)
                Slider(value: band.q, in: 0.2...12, step: 0.05)
                .designSlider("Q", value: band.wrappedValue.q, unit: .number)
                Text(String(format: "%.2f", band.wrappedValue.q))
                    .frame(width: 52, alignment: .trailing)
            }
            .font(DesignType.caption.font.monospacedDigit())
        }
        .padding(DesignSpacing.m.pt)
        .designTint(StatusLevel.off.color, opacity: 0.05, radius: .medium)
    }

    private func importEQProposal(_ result: Result<[URL], Error>) {
        actionError = nil
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let rate = selectedSampleRate else {
                throw HeadphoneDeviceProfileError.outputDeviceRequired
            }
            pendingEQProposal = try HeadphoneCorrectionProposal.load(
                from: url, sampleRate: rate
            )
            statusMessage = "Local correction proposal loaded for review. No bands have been applied."
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func stageEQProposal(_ proposal: HeadphoneCorrectionProposal) {
        actionError = nil
        do {
            guard let rate = selectedSampleRate else {
                throw HeadphoneDeviceProfileError.outputDeviceRequired
            }
            try draft.stageLocalProposal(proposal, sampleRate: rate)
            pendingEQProposal = nil
            statusMessage = cleanPage
                ? "EQ bands staged in the draft and headroom raised to cover them. Press Apply to use them."
                : "EQ bands staged in the editable draft. Headroom adjusted conservatively. Apply while playback is stopped to save."
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var crossfeedCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                Text("Acoustic Crossfeed").font(DesignType.sectionTitle.font)
                Spacer()
                bypassSwitch(.crossfeed, label: "Bypass crossfeed")
                Picker("Preset", selection: Binding(
                    get: { draft.crossfeed.preset },
                    set: { preset in draft.crossfeed.applyPreset(preset) }
                )) {
                    ForEach(HeadphoneCrossfeedPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .frame(maxWidth: 220)
                .disabled(draft.spatialMode == .virtualSpeakers)
            }

            if cleanPage {
                Text(draft.crossfeed.preset.summary)
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            HStack {
                Slider(value: $draft.crossfeed.amount, in: 0...1, step: 0.05)
                .designSlider("Crossfeed amount", value: draft.crossfeed.amount, unit: .percent)
                    .disabled(draft.crossfeed.preset == .off || draft.spatialMode == .virtualSpeakers)
                Text("\(draft.crossfeed.amount * 100, specifier: "%.0f")%")
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }
            if cleanPage, draft.crossfeed.preset == .custom, draft.spatialMode != .virtualSpeakers {
                customCrossfeedControls
            }

            Text(draft.spatialMode == .virtualSpeakers
                 ? "Crossfeed is automatically bypassed in Virtual Speakers mode because the HRTF/BRIR already supplies interaural timing and level cues."
                 : "Crossfeed affects only the low-frequency contralateral path and preserves direct high-frequency energy; it is not an HRTF renderer.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
        .designPanel()
    }

    /// The Custom preset's own controls: speaker angle, head radius and head-shadow frequency (level is the slider above).
    private var customCrossfeedControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Text("Speaker angle").frame(width: 130, alignment: .leading)
                Slider(value: $draft.crossfeed.virtualSpeakerAngleDegrees, in: 15...90, step: 1)
                    .designSlider("Crossfeed speaker angle", value: draft.crossfeed.virtualSpeakerAngleDegrees, unit: .degrees)
                Text("\(draft.crossfeed.virtualSpeakerAngleDegrees, specifier: "%.0f") deg")
                    .monospacedDigit().frame(width: 68, alignment: .trailing)
            }
            HStack {
                Text("Head radius").frame(width: 130, alignment: .leading)
                Slider(value: $draft.crossfeed.headRadiusMeters, in: 0.06...0.12, step: 0.0025)
                    .designSlider("Crossfeed head radius", value: draft.crossfeed.headRadiusMeters, unit: .plain("metres"))
                Text("\(draft.crossfeed.headRadiusMeters * 100, specifier: "%.2f") cm")
                    .monospacedDigit().frame(width: 68, alignment: .trailing)
            }
            HStack {
                Text("Cutoff").frame(width: 130, alignment: .leading)
                Slider(value: $draft.crossfeed.headShadowFrequencyHz, in: 200...2_000, step: 10)
                    .designSlider("Crossfeed cutoff", value: draft.crossfeed.headShadowFrequencyHz, unit: .hz)
                Text("\(draft.crossfeed.headShadowFrequencyHz, specifier: "%.0f") Hz")
                    .monospacedDigit().frame(width: 68, alignment: .trailing)
            }
        }
        .font(DesignType.caption.font)
    }

    private var spatialCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            HStack {
                Text("Virtual Speakers").font(DesignType.sectionTitle.font)
                Spacer()
                bypassSwitch(.virtualSpeakers, label: "Bypass Virtual Speakers")
            }

            Picker("Program Layout", selection: $draft.programLayout) {
                ForEach(OutputProgramLayout.allCases) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }

            Picker(cleanPage ? "Surround source device" : "Decoded Program Source", selection: Binding(
                get: { draft.programSourceDeviceUID ?? engine.selectedOutputDevice?.uid },
                set: { uid in
                    if uid == engine.selectedOutputDevice?.uid { draft.programSourceDeviceUID = nil }
                    else { draft.programSourceDeviceUID = uid }
                }
            )) {
                ForEach(engine.outputDevices) { device in
                    Text("\(device.name) · \(device.outputChannelCount) ch")
                        .tag(Optional(device.uid))
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("HRTF / BRIR Profile").font(.subheadline.bold())
                    if let profile = draft.binauralProfile, GenericHRTF.isGeneric(profile) {
                        Text("\(profile.displayName) · generated at the output rate")
                            .foregroundStyle(.secondary)
                    } else if let profile = draft.binauralProfile {
                        Text("\(profile.displayName) · \(profile.tapCount) taps · \(profile.sampleRate / 1_000, specifier: "%.1f") kHz")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(cleanPage ? "No listening profile selected" : "No normalized profile selected")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Import HRTF / SOFA…") {
                    importingSpatialProfile = true
                }
                .buttonStyle(.glass)
            }

            if cleanPage {
                if draft.binauralProfile.map(GenericHRTF.isGeneric) != true {
                    Button("Use the built-in generic head model") { draft.binauralProfile = GenericHRTF.reference }
                        .buttonStyle(.glass)
                }
                Text("The generic head model is a calculated average head, so placement is approximate. Import a SOFA file or capture your own BRIR for a closer match.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }

            if FeatureFlags().isEnabled(.headphones), let calibration {
                Button("Capture your own BRIR…") { startBRIRCapture(calibration) }
                    .buttonStyle(.glass)
                    .disabled(selectedSampleRate == nil)
                    .help("Record your speakers with in-ear microphones.")
            }

            if !availableImportedHRTFs.isEmpty {
                Picker(
                    "Previously imported spatial profile",
                    selection: Binding(
                        get: { draft.binauralProfile?.assetID },
                        set: { id in
                            draft.binauralProfile = availableImportedHRTFs
                                .first { $0.id == id }?.reference
                        }
                    )
                ) {
                    Text("Choose stored HRTF…").tag(UUID?.none)
                    ForEach(availableImportedHRTFs) { asset in
                        Text("\(asset.displayName) · \(Int(asset.sampleRate)) Hz")
                            .tag(UUID?.some(asset.id))
                    }
                }
                Text(
                    "User-rated HRTF preferences can be reviewed in Developer → Acoustic Research (turn on Show developer tools in Settings). Selection changes this draft only; Apply still requires a matching device rate and stopped playback."
                )
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            }
            Divider()
            headTrackingControls

            Text(
                "Import native AES69 .sofa files or the normalized JSON profile. SOFA/HDF5 decoding, coordinate conversion and receiver-delay baking occur only while importing, never on the audio callback."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
            if let profile = draft.binauralProfile, !GenericHRTF.isGeneric(profile) {
                let matching = selectedSampleRate.map {
                    abs($0 - profile.sampleRate) < 0.5
                } ?? false
                Label(
                    matching
                        ? "HRTF rate matches the selected headphone output."
                        : "HRTF measured at \(Int(profile.sampleRate)) Hz. It will be converted to the output rate when processing starts; importing an HRTF at the output's native rate avoids the conversion.",
                    systemImage: matching ? "checkmark.shield" : "arrow.triangle.2.circlepath"
                )
                .font(DesignType.caption.font)
                .foregroundStyle(Color.secondary)
            }

            if draft.programSourceDeviceUID == nil {
                Text("Using the headphone endpoint as the program source. If it exposes only stereo, Virtual Speakers will render a stereo virtual pair. Select a multichannel decoded endpoint to preserve 5.1/7.1.4 channels.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(StatusLevel.attention.color)
            }
        }
        .designPanel()
    }

    private var headTrackingControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Head Tracking").font(.subheadline.bold())
                    Text("Keeps virtual speakers fixed in space using supported Apple headphone motion sensors. If motion is unavailable, static Virtual Speakers remains active by default.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Head Tracking", isOn: Binding(
                    get: { draft.headTracking?.enabled ?? false },
                    set: { enabled in
                        var configuration = draft.headTracking ?? HeadTrackingConfiguration()
                        configuration.enabled = enabled
                        draft.headTracking = configuration
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if draft.headTracking?.enabled == true {
                HStack {
                    Label(engine.headTrackingRuntimeStatus.displayName, systemImage: engine.headTrackingRuntimeStatus.isActivelyTracking ? "gyroscope" : "headphones")
                        .foregroundStyle(engine.headTrackingRuntimeStatus.isActivelyTracking ? .primary : .secondary)
                    Spacer()
                    Button("Recenter") { engine.recenterHeadTracking() }
                        .buttonStyle(.glass)
                        .disabled(!engine.headTrackingRuntimeStatus.isActivelyTracking)
                }
                if draft.spatialMode == .virtualSpeakers, let reference = draft.binauralProfile,
                   let note = UnifiedGraphTranslator.binauralTrackingNote(
                       channels: draft.programLayout.roles.count, sampleRate: reference.sampleRate,
                       tapCount: reference.tapCount, elevationData: reference.hasElevationSets ?? true) {
                    Text(note)
                        .font(DesignType.caption.font)
                        .foregroundStyle(StatusLevel.attention.color)
                }
                if let detail = engine.headTrackingRuntimeStatus.detail {
                    Text(detail)
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Toggle("Fall back to static Virtual Speakers when tracking is unavailable", isOn: Binding(
                    get: { draft.headTracking?.fallbackToStaticSpatial ?? true },
                    set: { enabled in
                        var configuration = draft.headTracking ?? HeadTrackingConfiguration()
                        configuration.fallbackToStaticSpatial = enabled
                        draft.headTracking = configuration
                    }
                ))
                .toggleStyle(.switch)
            }
        }
    }

    private var deploymentCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Deploy to Playback System").font(DesignType.sectionTitle.font)
                    Text(cleanPage
                         ? "EQ, trim, headroom and crossfeed changes apply while music plays. Changing the listening mode, speaker layout, listening profile, polarity or the program source needs playback stopped first."
                         : "Changes require processing to be stopped because headphone and spatial runtimes are prepared before Core Audio callbacks start.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { syncFromSelectedSystem() }
                    .buttonStyle(.glass)
                Button("Apply") { applyDraft() }
                    .buttonStyle(.glassProminent)
                    .disabled(!canApply)
            }
        }
        .designPanel()
    }

    private func channelControls(
        title: String,
        correction: Binding<HeadphoneChannelCorrection>
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text(title).font(.subheadline.bold())
            HStack {
                Text("Trim")
                Slider(value: correction.gainDB, in: -12...6, step: 0.25)
                .designSlider("Trim", value: correction.wrappedValue.gainDB, unit: .db)
                Text("\(correction.wrappedValue.gainDB, specifier: "%.2f") dB")
                    .monospacedDigit().frame(width: 76, alignment: .trailing)
            }
            HStack {
                Text("Delay")
                Slider(value: correction.delayMilliseconds, in: 0...20, step: 0.01)
                .designSlider("Delay", value: correction.wrappedValue.delayMilliseconds, unit: .ms)
                Text("\(correction.wrappedValue.delayMilliseconds, specifier: "%.2f") ms")
                    .monospacedDigit().frame(width: 76, alignment: .trailing)
            }
            Toggle("Invert polarity", isOn: correction.polarityInverted)
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// E13 S12: a listening switch on a card (page flag on). Live while playing, never saved.
    @ViewBuilder private func bypassSwitch(_ part: HeadphoneBypassSet, label: String) -> some View {
        if cleanPage {
            HeadphoneBypassSwitch(
                state: profiles.headphoneBypass, part: part, label: label, enabled: bypassAvailable,
                changed: { previewLive(draft) })
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<HeadphoneDeviceProfileConfiguration, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 })
    }

    /// E13 S3: with live tuning on, Apply also works while playing when the draft is a live edit of what renders.
    private var canApply: Bool {
        guard engine.selectedOutputDevice != nil else { return false }
        if engine.lifecycleState == .idle { return true }
        return liveTuningAvailable
    }

    private var liveTuningAvailable: Bool {
        guard FeatureFlags().isEnabled(.headphones), engine.lifecycleState == .running else { return false }
        return HeadphoneLiveTuner.isLiveEditable(saved: profiles.selectedSystemHeadphoneDeviceProfile, draft: draft)
    }

    /// E13 S12: a bypass switch needs only a running, enabled saved profile; it plays the saved profile (or the draft when
    /// that is a live edit of it) with the bypassed parts switched off, and saves nothing.
    private var bypassAvailable: Bool {
        engine.lifecycleState == .running && profiles.selectedSystemHeadphoneDeviceProfile?.enabled == true
    }

    private func previewLive(_ newDraft: HeadphoneDeviceProfileConfiguration) {
        let bypass = profiles.headphoneBypass
        let bypassing = cleanPage && !bypass.bypassed.isEmpty && bypassAvailable
        guard liveTuningAvailable || bypassing, let saved = profiles.selectedSystemHeadphoneDeviceProfile else {
            restoreLivePreview()
            return
        }
        if tuner == nil {
            let engine = engine
            tuner = HeadphoneLiveTuner(apply: { try engine.replaceHeadphoneDeviceProfileConfiguration($0) })
            tuner?.begin(from: engine.headphoneDeviceProfileConfiguration ?? saved)
        }
        var candidate = liveTuningAvailable ? newDraft : saved
        candidate.outputDeviceUID = saved.outputDeviceUID
        if cleanPage { candidate = bypass.effective(candidate) }
        tuner?.submit(candidate)
        if let error = tuner?.lastError { actionError = error }
    }

    /// Puts the saved profile back on the engine (Revert, leaving, a lifecycle change) and drops the preview.
    private func restoreLivePreview() {
        profiles.headphoneBypass.clear()
        guard let tuner else { return }
        if let saved = profiles.selectedSystemHeadphoneDeviceProfile { tuner.restore(saved) }
        self.tuner = nil
    }

    private func syncFromSelectedSystem() {
        restoreLivePreview()
        if cleanPage { profiles.ensureSelectedSystemHeadphoneList() }
        if let saved = profiles.selectedSystemHeadphoneDeviceProfile {
            draft = saved
        } else {
            var fresh = HeadphoneDeviceProfileConfiguration()
            fresh.outputDeviceUID = engine.selectedOutputDevice?.uid
            draft = fresh
        }
        if cleanPage {
            let entry = profiles.selectedSystemHeadphoneList?.selected
            shaping = entry?.targetShaping ?? HeadphoneTargetShaping()
            autoHeadroom = entry?.autoHeadroom ?? false
        }
        if cleanPage, let id = profiles.selectedSystemHeadphoneList?.selected?.fittedResponseID,
           id != selectedResponseID, storedResponses.contains(where: { $0.id == id }) {
            selectedResponseID = id
        }
        actionError = nil
        statusMessage = nil
    }

    private func applyDraft() {
        actionError = nil
        statusMessage = nil
        do {
            draft.outputDeviceUID = engine.selectedOutputDevice?.uid
            guard let rate = selectedSampleRate,
                  rate.isFinite,
                  (8_000...384_000).contains(rate) else {
                throw HeadphoneDeviceProfileError.sampleRateUnsupported(
                    previewSampleRate
                )
            }
            try draft.validateStructure(sampleRate: rate)
            tuner = nil  // the engine is about to take the draft as the saved profile
            profiles.headphoneBypass.clear()
            try profiles.replaceSelectedSystemHeadphoneDeviceProfile(
                draft, fittedResponseID: cleanPage && oneClickFit != nil ? selectedResponseID : nil,
                targetShaping: cleanPage ? shaping : nil, autoHeadroom: cleanPage ? autoHeadroom : nil)
            statusMessage = draft.enabled
                ? "Headphone Device Profile deployed. Start processing to use \(draft.spatialMode.displayName)."
                : "Headphone Device Profile saved disabled."
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func startBRIRCapture(_ calibration: MultichannelCalibrationController) {
        guard let rate = selectedSampleRate else { return }
        let roles = calibration.profile?.programLayout.roles ?? []
        brirFlow = BRIRCaptureFlow(
            environment: BRIRLiveCaptureEnvironment(calibration: calibration),
            sampleRate: rate, availableSpeakers: roles)
    }

    private func brirCaptured(_ reference: BinauralProfileReference) {
        draft.binauralProfile = reference
        loadImportedHRTFs()
        statusMessage = "Captured \(reference.displayName). Apply to persist the selection with this Playback System."
    }

    private func importSpatialProfile(_ result: Result<[URL], Error>) {
        actionError = nil
        statusMessage = nil
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            draft.binauralProfile = try engine.importNormalizedBinauralProfile(from: url)
            statusMessage = "Imported \(draft.binauralProfile?.displayName ?? "spatial profile"). Apply to persist the selection with this Playback System."
        } catch {
            actionError = error.localizedDescription
        }
    }
}


/// One bypass switch. Switching it off hears the card's processing again; nothing is saved either way.
private struct HeadphoneBypassSwitch: View {
    @ObservedObject var state: HeadphoneBypassState
    let part: HeadphoneBypassSet
    let label: String
    let enabled: Bool
    let changed: () -> Void

    var body: some View {
        Toggle(label, isOn: Binding(
            get: { state.isBypassed(part) },
            set: { state.set(part, on: $0); changed() }))
            .toggleStyle(.switch)
            .disabled(!enabled)
            .help(enabled ? "Listen with this part switched off. Not saved; it ends when you leave the page." : "Start playback with headphones on to compare.")
    }
}
