import SwiftUI

/// E33 S17: the one View selector shared by Spectrum, RTA and Spectrogram (decision 18).
struct ProductionAnalysisViewPicker: View {
    let options: [AnalysisViewOptions.Entry]
    @Binding var selection: AnalysisView

    var body: some View {
        if options.count > 1 {
            HStack(spacing: DesignSpacing.s.pt) {
                Text("View").font(DesignType.caption.font).foregroundStyle(.secondary)
                Picker("View", selection: $selection) {
                    ForEach(options) { Text($0.title).tag($0.view) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityLabel("Analysis view")
                .accessibilityIdentifier("meters.analysis.view")
            }
        }
    }
}

/// E33 S17: the pair the Stereo page's correlation and goniometer follow (G30).
struct ProductionAnalysisPairPicker: View {
    let options: [AnalysisViewOptions.PairEntry]
    @Binding var selection: AnalysisPair

    var body: some View {
        HStack(spacing: DesignSpacing.s.pt) {
            Text("Pair").font(DesignType.caption.font).foregroundStyle(.secondary)
            Picker("Pair", selection: $selection) {
                ForEach(options) { Text($0.title).tag($0.pair) }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .accessibilityLabel("Stereo pair")
            .accessibilityIdentifier("meters.analysis.pair")
        }
    }
}
