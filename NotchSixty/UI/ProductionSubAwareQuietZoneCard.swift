import SwiftUI

/// E26 S5 (`e26.sub-aware-anc`): Quiet Zone setup with a subwoofer in the path. How bass reaches the room, the
/// receiver declaration, "Measure with your subwoofer" and why Turn On is not ready yet. Text and two actions only;
/// being ready grants nothing, because Turn On stays the user's own action.
struct ProductionSubAwareQuietZoneCard: View {
    @ObservedObject var quietZone: ActiveQuietZoneController
    @ObservedObject var survey: QuietZoneFeedForwardSurveyController
    @State private var errorText: String?

    var body: some View {
        if quietZone.subAwareAncEnabled, quietZone.bassConditioningActive {
            let readiness = quietZone.subAwareReadiness(mode: .feedForward)
            VStack(alignment: .leading, spacing: 10) {
                Text(SubAwareQuietZoneText.question).font(.headline)
                Text(SubAwareQuietZoneText.pathSummary(quietZone.ancBassPathState.path)).font(.callout)
                if let arrangement = quietZone.arrangement, arrangement.hasDownstreamSubwoofer {
                    SystemSetupReceiverBassPicker(receiverBass: arrangement.receiverBass) { declared in
                        do { try quietZone.declareReceiverBass(declared); errorText = nil } catch {
                            errorText = error.localizedDescription
                        }
                    }
                }
                HStack {
                    Button("Measure with your subwoofer") { survey.measureSubPath(thenLeakage: true) }
                        .disabled(survey.activity != .idle)
                    Text(survey.message).font(.caption).foregroundStyle(.secondary)
                }
                Text(SubAwareQuietZoneText.advice).font(.caption).foregroundStyle(.secondary)
                if let readout = quietZone.bassConditioningReadout {
                    Label(readout, systemImage: "waveform.path").font(.caption).foregroundStyle(.secondary)
                }
                if let message = readiness.message {
                    Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else {
                    Label("Your subwoofer setup is measured. Turn On is still your choice.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
