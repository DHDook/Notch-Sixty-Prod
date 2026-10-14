import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProductionHeadphoneWorkspace: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController

    @State private var draft = HeadphoneDeviceProfileConfiguration()
    @State private var importingSpatialProfile = false
    @State private var importingEQProposal = false
    @State private var pendingEQProposal: HeadphoneCorrectionProposal?
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                modeCard
                correctionCard
                perEarEQCard
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
                        Slider(value: $draft.headroomAttenuationDB, in: 0...30, step: 0.5)
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

            Text(
                "Device correction is separate from Content Presets. The editor below exposes all 16 independently enabled parametric EQ bands per ear, with a preview of the electrical DSP response."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            let required = draft.conservativeRequiredHeadroomDB
            HStack {
                Label(
                    String(format: "Conservative positive-gain allowance: %.1f dB", required),
                    systemImage: "waveform.path"
                )
                .font(.caption)
                Spacer()
                Text(
                    draft.headroomAttenuationDB + 0.000001 >= required
                        ? "Headroom covered" : "Increase headroom before applying"
                )
                .foregroundStyle(
                    draft.headroomAttenuationDB + 0.000001 >= required
                        ? Color.secondary : Color.orange
                )
                .font(.caption.bold())
            }
        }
        .productionCard()
    }

    // MARK: - Batch 3 headphone PEQ completion

    private var perEarEQCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Per-Ear Parametric Equalizer")
                    .font(.headline)
                Spacer()
                Text("16 bands per ear")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(
                "Preview is calculated from the production filter coefficients at "
                + String(format: "%.1f kHz", previewSampleRate / 1000)
                + (selectedSampleRate == nil
                   ? " (illustration only: choose an output to validate)." : ".")
                + " Includes per-ear trim and common attenuation. It is not an acoustic headphone measurement."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            headphoneResponseGraph
                .frame(height: 210)

            HStack(alignment: .top, spacing: 16) {
                channelEQEditor(
                    "Left ear", correction: binding(\.left),
                    accent: .orange
                )
                channelEQEditor(
                    "Right ear", correction: binding(\.right),
                    accent: .cyan
                )
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Optional local correction proposal").font(.subheadline.bold())
                    Text(
                        "Import a user-supplied, explicitly attributed JSON PEQ proposal. It is reviewed as a draft and never downloads, automatically selects, or distributes a model correction database."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Import EQ Proposal…") {
                    importingEQProposal = true
                }
                .buttonStyle(.bordered)
            }
            if let proposal = pendingEQProposal {
                VStack(alignment: .leading, spacing: 6) {
                    Text(proposal.headphoneModel)
                        .font(.subheadline.bold())
                    Text(
                        "Source: " + proposal.sourceName
                        + " · Attribution: " + proposal.sourceAttribution
                        + " · Stated license: " + proposal.sourceLicense
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    Text(
                        "This metadata does not establish redistribution rights or verify the measurements. Review before using; no automatic deployment."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Stage Bands in Draft") {
                            stageEQProposal(proposal)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Discard") {
                            pendingEQProposal = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .productionCard()
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
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Left", systemImage: "waveform").foregroundStyle(.orange)
                Label("Right", systemImage: "waveform").foregroundStyle(.cyan)
                Spacer()
                Text("20 Hz – 20 kHz · modeled dB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
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
            .background(.secondary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func channelEQEditor(
        _ title: String,
        correction: Binding<HeadphoneChannelCorrection>,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(accent).frame(width: 9, height: 9)
                Text(title).font(.subheadline.bold())
                Spacer()
                Text("\(correction.wrappedValue.eqBands.count)/16")
                    .font(.caption.monospacedDigit())
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
                .buttonStyle(.bordered)
            }
            ForEach(
                correction.wrappedValue.eqBands.indices,
                id: \.self
            ) { index in
                perEarBandControls(correction: correction, index: index)
            }
            if correction.wrappedValue.eqBands.isEmpty {
                Text("No filters. Use Add to create a band.")
                    .font(.caption)
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
        return VStack(alignment: .leading, spacing: 8) {
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
            .productionGlassPickerChrome()
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
                Text(
                    String(format: "%.0f", band.wrappedValue.frequencyHz)
                )
                .frame(width: 52, alignment: .trailing)
            }
            HStack {
                Text("dB").frame(width: 37, alignment: .leading)
                Slider(value: band.gainDB, in: -18...18, step: 0.25)
                Text(String(format: "%+.2f", band.wrappedValue.gainDB))
                    .frame(width: 57, alignment: .trailing)
            }
            HStack {
                Text("Q").frame(width: 37, alignment: .leading)
                Slider(value: band.q, in: 0.2...12, step: 0.05)
                Text(String(format: "%.2f", band.wrappedValue.q))
                    .frame(width: 52, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(10)
        .background(.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 12))
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
            statusMessage = "EQ bands staged in the editable draft. Headroom adjusted conservatively. Apply while playback is stopped to save."
        } catch {
            actionError = error.localizedDescription
        }
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
                Button("Import HRTF / SOFA…") {
                    importingSpatialProfile = true
                }
                .buttonStyle(.glass)
            }

            Divider()
            headTrackingControls

            Text(
                "Import native AES69 .sofa files or the normalized JSON profile. SOFA/HDF5 decoding, coordinate conversion and receiver-delay baking occur only while importing, never on the audio callback."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let profile = draft.binauralProfile {
                let matching = selectedSampleRate.map {
                    abs($0 - profile.sampleRate) < 0.5
                } ?? false
                Label(
                    matching
                        ? "HRTF rate matches the selected headphone output."
                        : "Sample-rate mismatch: profile \(Int(profile.sampleRate)) Hz. Select a matching output rate or import a matching HRTF. Automatic HRTF resampling is not implemented.",
                    systemImage: matching ? "checkmark.shield" : "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(matching ? Color.secondary : Color.orange)
            }

            if draft.programSourceDeviceUID == nil {
                Text("Using the headphone endpoint as the program source. If it exposes only stereo, Virtual Speakers will render a stereo virtual pair. Select a multichannel decoded endpoint to preserve 5.1/7.1.4 channels.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .productionCard()
    }

    private var headTrackingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Head Tracking").font(.subheadline.bold())
                    Text("Keeps virtual speakers fixed in space using supported Apple headphone motion sensors. If motion is unavailable, static Virtual Speakers remains active by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { draft.headTracking?.enabled ?? false },
                    set: { enabled in
                        var configuration = draft.headTracking ?? HeadTrackingConfiguration()
                        configuration.enabled = enabled
                        draft.headTracking = configuration
                    }
                ))
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
                if let detail = engine.headTrackingRuntimeStatus.detail {
                    Text(detail)
                        .font(.caption)
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
            guard let rate = selectedSampleRate,
                  rate.isFinite,
                  (8_000...384_000).contains(rate) else {
                throw HeadphoneDeviceProfileError.sampleRateUnsupported(
                    previewSampleRate
                )
            }
            try draft.validateStructure(sampleRate: rate)
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
