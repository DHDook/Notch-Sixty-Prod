import SwiftUI

/// E4 S9b2: measures the feed-forward design in the
/// app: reference to seat transfer from the noise itself, then speaker leakage
/// into the reference microphone. Nothing here plays anti-noise.
struct ProductionFeedForwardDesignSurveyCard: View {
    @ObservedObject var survey: QuietZoneFeedForwardSurveyController

    private static let channels = Array(0..<32)

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Feed-Forward Design Measurement")
                        .font(DesignType.sectionTitle.font)
                    Text("The reference microphone is a second channel of the seat microphone's interface, so both share one clock.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(activityLabel)
                    .font(DesignType.caption.font.bold())
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignSpacing.m.pt)
                    .padding(.vertical, DesignSpacing.s.pt)
                    .glassEffect(.regular, in: .capsule)
            }

            HStack(spacing: DesignSpacing.m.pt) {
                Picker("Reference channel", selection: Binding(
                    get: { survey.referenceChannel ?? -1 },
                    set: { survey.setReferenceChannel($0 < 0 ? nil : $0) }
                )) {
                    Text("Not set").tag(-1)
                    ForEach(Self.channels.filter { $0 != survey.errorChannel }, id: \.self) {
                        Text("Input \($0 + 1)").tag($0)
                    }
                }
                .frame(maxWidth: 260)
                if let seat = survey.errorChannel {
                    Text("Seat microphone: input \(seat + 1)")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: DesignSpacing.m.pt) {
                Button("Measure reference to seat (60 s)") { survey.startNoiseSurvey() }
                    .disabled(survey.activity != .idle)
                Button("Measure speaker leakage") { survey.measureLeakage() }
                    .disabled(survey.activity != .idle || survey.survey == nil)
                if survey.activity != .idle {
                    Button("Cancel", role: .cancel) { survey.cancel() }
                }
            }

            if let progress {
                ProgressView(value: progress)
            }

            Text(survey.message)
                .font(DesignType.label.font)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let measured = survey.survey {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["Band", "|H| ref → seat", "Coherence", "Leakage L / R"], id: \.self) {
                            Text($0).font(DesignType.caption.font.bold()).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(measured.bands, id: \.frequencyHz) { band in
                        GridRow {
                            Text(String(format: "%.1f Hz", band.frequencyHz))
                            Text(String(format: "%.1f dB", 20 * log10(max(band.referenceToSeat.magnitude, 1e-12))))
                            Text(String(format: "%.2f", band.coherence))
                                .foregroundStyle(band.coherence >= QuietZoneFeedForwardSurveyGrid.minimumCoherence
                                                 ? Color.primary : Color.orange)
                            Text(leakageText(band.frequencyHz))
                        }
                        .font(DesignType.caption.font.monospacedDigit())
                    }
                }
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
        .onAppear { survey.refresh() }
    }

    private var activityLabel: String {
        switch survey.activity {
        case .idle: return survey.design == nil ? "NO DESIGN" : "DESIGN READY"
        case .surveying: return "RECORDING"
        case .measuringLeakage: return "SWEEPING"
        case .analyzing: return "ANALYSING"
        }
    }

    private var progress: Double? {
        switch survey.activity {
        case .surveying(let p), .measuringLeakage(let p): return p
        case .idle, .analyzing: return nil
        }
    }

    private func leakageText(_ hz: Double) -> String {
        guard let band = survey.assembled?.bands.first(where: { $0.frequencyHz == hz }) else { return "—" }
        let db = { (m: Double) in 20 * log10(max(m, 1e-12)) }
        return String(format: "%.0f / %.0f dB", db(band.leftLeakageAtReference.magnitude),
                      db(band.rightLeakageAtReference.magnitude))
    }
}
