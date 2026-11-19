import SwiftUI

/// E33 S21 (G40): "Fit bands" on the Equalizer page. Proposes bands from a saved measurement, shows the predicted result
/// against the target, and changes nothing until Keep. Keep replaces the bands of the lane being edited as one undo step.
struct EQFitBandsButton: View {
    let curves: [EQReferenceCurve]
    let sampleRate: Double
    let existingBandCount: Int
    /// Applies the kept bands (the page records it as one undo step).
    let keep: ([EQBand]) -> Void

    @State private var shown = false

    var body: some View {
        Button {
            shown = true
        } label: {
            Label("Fit bands", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderless)
        .help("Propose EQ bands that bring a saved measurement to a target. Nothing changes until you keep them.")
        .accessibilityLabel("Fit bands to a curve")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            EQFitBandsPanel(
                curves: curves, sampleRate: sampleRate, existingBandCount: existingBandCount,
                keep: { bands in
                    keep(bands)
                    shown = false
                },
                cancel: { shown = false })
        }
    }
}

private struct EQFitBandsPanel: View {
    let curves: [EQReferenceCurve]
    let sampleRate: Double
    let existingBandCount: Int
    let keep: ([EQBand]) -> Void
    let cancel: () -> Void

    @State private var request = EQFitRequest()
    @State private var proposal: EQBandFitProposal?
    @State private var refusal: String?

    private var sources: [EQReferenceCurveKind] {
        [EQReferenceCurveKind.measurement, .corrected].filter { kind in curves.contains { $0.kind == kind } }
    }
    private var hasTarget: Bool { curves.contains { $0.kind == .target } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fit bands to a curve").font(.headline)
            Picker("Curve", selection: $request.source) {
                ForEach(sources) { Text($0.displayName).tag($0) }
            }
            Picker("Target", selection: $request.target) {
                Text(EQFitTarget.flat.displayName).tag(EQFitTarget.flat)
                if hasTarget { Text(EQFitTarget.correctionTarget.displayName).tag(EQFitTarget.correctionTarget) }
            }
            HStack {
                rangeField("From", value: $request.lowHz, in: EQBandRules.minimumFrequency...2_000)
                rangeField("To", value: $request.highHz, in: 40...EQBandRules.maximumFrequency(sampleRate: sampleRate))
            }
            Stepper("Bands: \(request.bandCount)", value: $request.bandCount, in: EQFitRequest.bandCountRange)
            Stepper(
                "Largest boost: \(request.maximumBoostDB, specifier: "%.0f") dB",
                value: $request.maximumBoostDB, in: EQFitRequest.maximumBoostRange, step: 1)

            if let refusal {
                Text(refusal).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let proposal {
                EQFitPreview(proposal: proposal)
                    .frame(height: 120)
                    .accessibilityLabel("Predicted result against the target")
                Text(summary(proposal)).font(.callout).foregroundStyle(.secondary)
                if existingBandCount > 0 {
                    Text("Keeping replaces the \(existingBandCount) bands in this lane. Undo brings them back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Keep bands") { if let proposal { keep(proposal.bands) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposal == nil || proposal?.bands.isEmpty == true || refusal != nil)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear(perform: recompute)
        .onChange(of: request) { _, _ in recompute() }
    }

    private func rangeField(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 4) {
            Text(title)
            TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 64)
                .onSubmit { value.wrappedValue = min(max(value.wrappedValue, range.lowerBound), range.upperBound) }
            Text("Hz").foregroundStyle(.secondary)
        }
    }

    private func summary(_ proposal: EQBandFitProposal) -> String {
        if proposal.bands.isEmpty { return "The curve already meets the target in this range. No bands are needed." }
        return String(
            format: "%d bands. Error against the target: %.1f dB rms before, %.1f dB after.",
            proposal.bands.count, proposal.rmsBeforeDB, proposal.rmsAfterDB)
    }

    private func recompute() {
        do {
            proposal = try EQBandFitter.fit(request, curves: curves, sampleRate: sampleRate)
            refusal = nil
        } catch {
            proposal = nil
            refusal = error.localizedDescription
        }
    }
}

/// The measurement, the target and the predicted result, on the page's log-frequency axis.
private struct EQFitPreview: View {
    let proposal: EQBandFitProposal

    var body: some View {
        Canvas { context, size in
            let range = proposal.fittedRangeHz
            let lo = log(range.lowerBound), hi = log(max(range.upperBound, range.lowerBound * 1.01))
            let all = proposal.measuredDB + proposal.targetDB + proposal.predictedDB
            let top = max((all.max() ?? 6), 6), bottom = min((all.min() ?? -6), -6)
            func point(_ hz: Double, _ db: Double) -> CGPoint {
                CGPoint(
                    x: size.width * (log(hz) - lo) / (hi - lo),
                    y: size.height * (top - db) / (top - bottom))
            }
            func draw(_ values: [Double], _ color: Color, width: CGFloat) {
                var path = Path()
                var started = false
                for (hz, db) in zip(proposal.frequenciesHz, values) where hz >= range.lowerBound && hz <= range.upperBound {
                    let p = point(hz, db)
                    if started { path.addLine(to: p) } else { path.move(to: p); started = true }
                }
                context.stroke(path, with: .color(color), lineWidth: width)
            }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: point(range.lowerBound, 0).y))
            zero.addLine(to: CGPoint(x: size.width, y: point(range.lowerBound, 0).y))
            context.stroke(zero, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
            draw(proposal.measuredDB, .teal.opacity(0.6), width: 1)
            draw(proposal.targetDB, .yellow, width: 1)
            draw(proposal.predictedDB, .green, width: 1.5)
        }
        .background(Color.secondary.opacity(0.08))
        .overlay(alignment: .topTrailing) {
            Text("measured, target, predicted").font(.caption2).foregroundStyle(.secondary).padding(3)
        }
    }
}
