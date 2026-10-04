import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProductionHeadphoneWorkspace: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController

    @State private var draft = HeadphoneDeviceProfileConfiguration()
    @State private var importingSpatialProfile = false
    @State private var actionError: String?
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                modeCard
                correctionCard
                crossfeedCard
                if draft.spatialMode == .virtualSpeakers {
                    spatialCard
                }
                deploymentCard

                if let error = actionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                } else if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .topLeading)
        }
        .task { syncFromSelectedSystem() }
        .task(id: profiles.selectedSystemProfileID) { syncFromSelectedSystem() }
        .fileImporter(
            isPresented: $importingSpatialProfile,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            importSpatialProfile(result)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Headphones")
                .font(.largeTitle.bold())
            Text("Keep headphone hardware correction separate from Content Presets. Stereo mode preserves the normal content DSP chain; Virtual Speakers renders semantic program channels through a prepared HRTF or BRIR before headphone correction and true-peak protection.")
                .foregroundStyle(.secondary)
        }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Headphone Device Profile").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $draft.enabled)
                    .toggleStyle(.switch)
            }

            LabeledContent("Playback System") {
                Text(profiles.selectedSystemProfileName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Headphone Output") {
                Text(engine.selectedOutputDevice?.name ?? "No output selected")
                    .foregroundStyle(engine.selectedOutputDevice == nil ? .red : .secondary)
            }

            HStack(spacing: 16) {
                TextField("Profile Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                Picker("Listening Mode", selection: $draft.spatialMode) {
                    ForEach(HeadphoneSpatialMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .productionGlassPickerChrome()
                .frame(maxWidth: 260)
            }

            Text(draft.spatialMode == .stereo
                 ? "Stereo: the existing EQ, dynamics and convolution chain remains available; headphone correction is applied immediately before final protection."
                 : "Virtual Speakers: multichannel decoded PCM is rendered to two ears first. Stereo-only creative DSP must be neutral because it cannot be applied honestly to an arbitrary semantic multichannel source.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .productionCard()
    }

    private var correctionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Device Correction").font(.headline)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target").font(.caption.bold()).foregroundStyle(.secondary)
                    Picker("Target", selection: $draft.targetCurve) {
                        ForEach(HeadphoneTargetCurve.allCases) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    .productionGlassPickerChrome()
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Correction Headroom").font(.caption.bold()).foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $draft.headroomAttenuationDB, in: 0...18, step: 0.5)
                        Text("\(draft.headroomAttenuationDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 68, alignment: .trailing)
                    }
                }
            }

            Divider()
            HStack(alignment: .top, spacing: 22) {
                channelControls(title: "Left", correction: binding(\.left))
                channelControls(title: "Right", correction: binding(\.right))
            }

            Text("Independent PEQ bands are part of the saved Headphone Device Profile. Detailed per-band editing remains in the later advanced profile editor; this workspace exposes the channel-matching controls needed for branch acceptance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .productionCard()
    }

    private var crossfeedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Acoustic Crossfeed").font(.headline)
                Spacer()
                Picker("Preset", selection: Binding(
                    get: { draft.crossfeed.preset },
                    set: { preset in draft.crossfeed.applyPreset(preset) }
                )) {
                    ForEach(HeadphoneCrossfeedPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .productionGlassPickerChrome()
                .frame(maxWidth: 220)
                .disabled(draft.spatialMode == .virtualSpeakers)
            }

            HStack {
                Slider(value: $draft.crossfeed.amount, in: 0...1, step: 0.05)
                    .disabled(draft.crossfeed.preset == .off || draft.spatialMode == .virtualSpeakers)
                Text("\(draft.crossfeed.amount * 100, specifier: "%.0f")%")
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            }

            Text(draft.spatialMode == .virtualSpeakers
                 ? "Crossfeed is automatically bypassed in Virtual Speakers mode because the HRTF/BRIR already supplies interaural timing and level cues."
                 : "Crossfeed affects only the low-frequency contralateral path and preserves direct high-frequency energy; it is not an HRTF renderer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .productionCard()
    }

    private var spatialCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Virtual Speakers").font(.headline)

            Picker("Program Layout", selection: $draft.programLayout) {
                ForEach(OutputProgramLayout.allCases) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .productionGlassPickerChrome()

            Picker("Decoded Program Source", selection: Binding(
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
            .productionGlassPickerChrome()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HRTF / BRIR Profile").font(.subheadline.bold())
                    if let profile = draft.binauralProfile {
                        Text("\(profile.displayName) · \(profile.tapCount) taps · \(profile.sampleRate / 1_000, specifier: "%.1f") kHz")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No normalized profile selected")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Import Normalized Profile…") {
                    importingSpatialProfile = true
                }
                .buttonStyle(.glass)
            }

            Text("Notch Sixty currently imports its documented normalized two-ear HRTF/BRIR JSON boundary. Native AES69 .sofa files use HDF5 and are intentionally not parsed until that dependency receives an explicit license, sandbox and provenance review. The realtime renderer itself is SOFA-oriented and uses the same normalized measurements.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if draft.programSourceDeviceUID == nil {
                Text("Using the headphone endpoint as the program source. If it exposes only stereo, Virtual Speakers will render a stereo virtual pair. Select a multichannel decoded endpoint to preserve 5.1/7.1.4 channels.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .productionCard()
    }

    private var deploymentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Deploy to Playback System").font(.headline)
                    Text("Changes require processing to be stopped because headphone and spatial runtimes are prepared before Core Audio callbacks start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { syncFromSelectedSystem() }
                    .buttonStyle(.glass)
                Button("Apply") { applyDraft() }
                    .buttonStyle(.glassProminent)
                    .disabled(engine.lifecycleState != .idle || engine.selectedOutputDevice == nil)
            }
        }
        .productionCard()
    }

    private func channelControls(
        title: String,
        correction: Binding<HeadphoneChannelCorrection>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.bold())
            HStack {
                Text("Trim")
                Slider(value: correction.gainDB, in: -12...6, step: 0.25)
                Text("\(correction.wrappedValue.gainDB, specifier: "%.2f") dB")
                    .monospacedDigit().frame(width: 76, alignment: .trailing)
            }
            HStack {
                Text("Delay")
                Slider(value: correction.delayMilliseconds, in: 0...10, step: 0.01)
                Text("\(correction.wrappedValue.delayMilliseconds, specifier: "%.2f") ms")
                    .monospacedDigit().frame(width: 76, alignment: .trailing)
            }
            Toggle("Invert polarity", isOn: correction.polarityInverted)
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<HeadphoneDeviceProfileConfiguration, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 })
    }

    private func syncFromSelectedSystem() {
        if let saved = profiles.selectedSystemHeadphoneDeviceProfile {
            draft = saved
        } else {
            var fresh = HeadphoneDeviceProfileConfiguration()
            fresh.outputDeviceUID = engine.selectedOutputDevice?.uid
            draft = fresh
        }
        actionError = nil
        statusMessage = nil
    }

    private func applyDraft() {
        actionError = nil
        statusMessage = nil
        do {
            draft.outputDeviceUID = engine.selectedOutputDevice?.uid
            try profiles.replaceSelectedSystemHeadphoneDeviceProfile(draft)
            statusMessage = draft.enabled
                ? "Headphone Device Profile deployed. Start processing to use \(draft.spatialMode.displayName)."
                : "Headphone Device Profile saved disabled."
        } catch {
            actionError = error.localizedDescription
        }
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

private extension View {
    func productionCard() -> some View {
        padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
    }
}
