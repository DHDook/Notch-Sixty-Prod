import Foundation
import SwiftUI

/// Optional research is read-only. The normal Room Correction and Headphones
/// workspaces retain sole control of committed DSP and device profiles.
struct ProductionOptionalAudioResearchWorkspace: View {
    @ObservedObject var projects: RoomCorrectionProjectController
    @ObservedObject var engine: AudioIOEngine

    @State private var mixedShare = 0.15
    @State private var latencyBudgetMS = 12.0
    @State private var mixed: MixedPhaseResearchResult?
    @State private var working = false

    @State private var availableHRTFs: [BinauralProfileAsset] = []
    @State private var selectedHRTFID: UUID?
    @State private var previewAzimuth = 25.0
    @State private var previewElevation = 0.0
    @State private var spatial: HRTFResearchPreview?
    @State private var listenerRating = 3
    @State private var auditionNotes = ""
    @State private var savedAudition: HRTFAuditionRecord?
    @State private var errorMessage: String?

    private var selectedHRTF: BinauralProfileAsset? {
        availableHRTFs.first { $0.id == selectedHRTFID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(
                    "Optional experimental comparison tools. They never apply a DSP filter, change audio routing or declare measured improvement. Use Room Correction or Headphones for the separate, validated deployment workflows."
                )
                .foregroundStyle(.secondary)

                mixedPhaseCard
                hrtfCard

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .topLeading)
        }
        .task { loadHRTFs() }
        .task(id: projects.selectedDesign?.id) {
            mixed = nil
        }
    }

    private var mixedPhaseCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Experimental Mixed-Phase FIR")
                .font(.headline)
            Text(
                "Start from the selected, real Room Correction minimum-phase FIR design. Blend a bounded symmetric component and audit its actual taps. This is a research preview: extra latency and pre-ringing can make it worse, even when predicted magnitude looks similar."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let design = projects.selectedDesign {
                Text(
                    "\(design.name) · \(Int(design.sampleRate)) Hz · \(design.filter.leftTaps.count) FIR taps"
                )
                .font(.subheadline)
            } else {
                Text("Select and generate a Room Correction FIR design first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Symmetric phase share")
                Slider(value: $mixedShare, in: 0...0.4, step: 0.05)
                Text("\(mixedShare * 100, specifier: "%.0f")%")
                    .monospacedDigit()
                    .frame(width: 52)
            }
            HStack {
                Text("Maximum added delay")
                Slider(value: $latencyBudgetMS, in: 1...30, step: 1)
                Text("\(latencyBudgetMS, specifier: "%.0f") ms")
                    .monospacedDigit()
                    .frame(width: 63)
            }
            Button(working ? "Auditing candidate…" : "Compare offline FIR candidate") {
                evaluateMixedPhase()
            }
            .buttonStyle(.borderedProminent)
            .disabled(projects.selectedDesign == nil || working)

            if let result = mixed {
                LabeledContent("Declared latency") {
                    Text(
                        "\(result.declaredLatencyFrames) frames · "
                        + String(format: "%.2f ms", Double(result.declaredLatencyFrames)
                            / result.sampleRate * 1000)
                    )
                }
                LabeledContent("Largest measured-tap magnitude difference") {
                    Text(String(format: "%.2f dB", result.maximumMagnitudeDeviationDB))
                }
                LabeledContent("Worst pre-ringing energy fraction") {
                    Text(String(format: "%.2f%%", result.preRingingEnergyFraction * 100))
                }
                LabeledContent("Conservative attenuation recommendation") {
                    Text(String(format: "%.2f dB", result.recommendedHeadroomDB))
                }
                if result.blockingReasons.isEmpty {
                    Text(
                        "Candidate passes bounded numerical review only; no hardware/seat verification and no Apply path."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(result.blockingReasons, id: \.self) { reason in
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }

    private var hrtfCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("HRTF Coverage & Listener Preference")
                    .font(.headline)
                Spacer()
                Button("Refresh imported HRTFs") { loadHRTFs() }
                    .buttonStyle(.bordered)
            }
            Text(
                "Explore interpolation among directions actually captured in a local SOFA/HRTF profile. Record your own subjective preference for imported profiles; this does not measure your ears or personalize transfer functions physiologically. Audition using the normal Headphones profile, starting at low volume."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Picker("Imported HRTF", selection: $selectedHRTFID) {
                Text("Choose an imported HRTF…").tag(UUID?.none)
                ForEach(availableHRTFs, id: \.id) { profile in
                    Text(
                        "\(profile.displayName) · \(Int(profile.sampleRate)) Hz · "
                        + "\(profile.measurements.count) directions"
                    )
                    .tag(UUID?.some(profile.id))
                }
            }
            .onChange(of: selectedHRTFID) { _, _ in
                spatial = nil
                loadAudition()
            }

            if let profile = selectedHRTF {
                let matched = engine.selectedOutputDevice.map {
                    abs($0.nominalSampleRate - profile.sampleRate) < 0.5
                } ?? false
                Label(
                    matched
                        ? "Profile matches selected output nominal rate."
                        : "Output rate mismatch or no output selected; no implicit SOFA resampling or deployment.",
                    systemImage: matched ? "checkmark.shield" : "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(matched ? Color.secondary : Color.orange)

                HStack {
                    Text("Azimuth")
                    Slider(value: $previewAzimuth, in: -180...180, step: 5)
                    Text("\(previewAzimuth, specifier: "%.0f")°")
                        .frame(width: 52)
                }
                HStack {
                    Text("Elevation")
                    Slider(value: $previewElevation, in: -80...80, step: 5)
                    Text("\(previewElevation, specifier: "%.0f")°")
                        .frame(width: 52)
                }
                Button("Analyze recorded directional coverage") {
                    analyzeHRTF(profile)
                }
                .buttonStyle(.borderedProminent)
                if let spatial {
                    LabeledContent("Nearest recorded direction") {
                        Text(
                            String(format: "%.1f°", spatial.nearestAngularDistanceDegrees)
                        )
                    }
                    LabeledContent("Interpolated measurements") {
                        Text("\(spatial.sourceMeasurementCount)")
                    }
                    LabeledContent("Peak sampled HRTF impulse") {
                        Text(String(format: "%.3f", spatial.maximumAbsoluteTap))
                    }
                    ForEach(spatial.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("User-guided profile audition").font(.subheadline.bold())
                Picker("Listening preference", selection: $listenerRating) {
                    ForEach(1...5, id: \.self) { rating in
                        Text("\(rating) / 5").tag(rating)
                    }
                }
                TextField("Optional subjective comfort/localization notes",
                          text: $auditionNotes)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save local listening preference") {
                        saveAudition(profile)
                    }
                    .buttonStyle(.bordered)
                    Text(savedAudition == nil
                         ? "No saved rating"
                         : "Local rating saved; choose the profile in Headphones to audition or stage it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Import an HRTF/SOFA file in Headphones before exploring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }

    private func evaluateMixedPhase() {
        guard let design = projects.selectedDesign else { return }
        mixed = nil
        errorMessage = nil
        working = true
        let left = design.filter.leftTaps
        let right = design.filter.rightTaps ?? design.filter.leftTaps
        let rate = design.sampleRate
        let share = mixedShare
        let latency = latencyBudgetMS
        Task.detached(priority: .userInitiated) {
            let result = Result {
                try MixedPhaseResearchDesigner().design(
                    left: left, right: right, sampleRate: rate,
                    linearPhaseShare: share,
                    latencyBudgetMilliseconds: latency
                )
            }
            await MainActor.run {
                working = false
                switch result {
                case .success(let value): mixed = value
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadHRTFs() {
        errorMessage = nil
        do {
            let store = BinauralProfileAssetStore()
            availableHRTFs = try store.existingAssetIDs().map { try store.load(id: $0) }
            if selectedHRTFID == nil, let first = availableHRTFs.first {
                selectedHRTFID = first.id
            }
            loadAudition()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func analyzeHRTF(_ asset: BinauralProfileAsset) {
        errorMessage = nil
        do {
            spatial = try HRTFDirectionalResearchDesigner().interpolate(
                asset: asset,
                azimuthDegrees: previewAzimuth,
                elevationDegrees: previewElevation
            )
        } catch {
            spatial = nil
            errorMessage = error.localizedDescription
        }
    }

    private func saveAudition(_ asset: BinauralProfileAsset) {
        errorMessage = nil
        do {
            let record = HRTFAuditionRecord(
                assetID: asset.id,
                sourceName: asset.displayName,
                listenerRating: listenerRating,
                notes: auditionNotes,
                createdAt: Date()
            )
            try HRTFAuditionPreferenceStore().save(record)
            savedAudition = record
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadAudition() {
        savedAudition = nil
        guard let selectedHRTFID else { return }
        do {
            savedAudition = try HRTFAuditionPreferenceStore().load(
                assetID: selectedHRTFID
            )
            if let savedAudition {
                listenerRating = savedAudition.listenerRating
                auditionNotes = savedAudition.notes
            } else {
                listenerRating = 3
                auditionNotes = ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
