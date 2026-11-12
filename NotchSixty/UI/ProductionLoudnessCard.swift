import SwiftUI

/// Text for the Loudness card; plain functions so the tests can check them.
enum LoudnessCardText {
    static func lufs(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f LUFS", value)
    }

    static func lu(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f LU", value)
    }

    static func truePeak(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f dBTP", value)
    }

    static let foldNote = "Measured on the stereo capture, after any wider program has been folded to two channels, "
        + "with BS.1770-4 gating."

    /// E28 S6b: wide (N-channel and binaural) sessions are measured on the semantic program channels.
    static let wideNote = "Measured on the semantic program channels with BS.1770-4 channel weights (LFE excluded). "
        + "Output is taken after the render, protection and master gain; subwoofer feeds are not included. On a routed output map each program channel is "
        + "the sum of its speaker's output lanes."

    /// Shown when a routed output map has no speaker lane that carries a program channel (sub or matrix-only routing).
    static let wideOutputUnavailableNote = "Output loudness is not measured here, because none of the routed output lanes "
        + "carries a program channel on its own (subwoofer and matrix-only outputs are not measured). Choose Input."
}

enum LoudnessSource: String, CaseIterable, Identifiable {
    case output
    case input

    var id: String { rawValue }
    var title: String { self == .output ? "Output" : "Input" }
}

/// E28 S2 Loudness card on Meters > Levels: momentary, short-term, integrated
/// and range per EBU R128, and the true-peak maximum since Reset.
struct ProductionLoudnessCard: View {
    let snapshot: ProductionAnalysisSnapshot
    let source: LoudnessSource
    let truePeak: TruePeakMaxHold
    let isRunning: Bool
    let unavailableReason: String?
    /// True for N-channel and binaural sessions (E28 S6b).
    var isWide = false
    let onSource: (LoudnessSource) -> Void
    let onReset: () -> Void

    private var readout: LoudnessReadout? {
        source == .output ? snapshot.loudnessOutput : snapshot.loudnessInput
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Loudness").font(.title3.bold())
                Picker("Source", selection: Binding(get: { source }, set: onSource)) {
                    ForEach(LoudnessSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                .accessibilityIdentifier("meters.loudness.source")
                Spacer()
                Button("Reset Loudness", action: onReset)
                    .accessibilityIdentifier("meters.loudness.reset")
            }

            if let unavailableReason {
                Text(unavailableReason).font(.caption).foregroundStyle(.secondary)
            } else if !isRunning {
                Text("Start processing to measure loudness.").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    value("Momentary", LoudnessCardText.lufs(readout?.momentary), "momentary")
                    value("Short-term", LoudnessCardText.lufs(readout?.shortTerm), "shortTerm")
                    value("Integrated", LoudnessCardText.lufs(readout?.integrated), "integrated")
                    value("Loudness range", LoudnessCardText.lu(readout?.range), "range")
                    value(
                        "True peak max",
                        LoudnessCardText.truePeak(truePeak.maxDBTP),
                        "truePeakMax"
                    )
                }
                if readout?.isGapped == true {
                    Label("Gapped: capture frames were lost, so integrated loudness may read low. Reset to start again.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .accessibilityIdentifier("meters.loudness.gapped")
                }
                Text(isWide ? LoudnessCardText.wideNote : LoudnessCardText.foldNote)
                    .font(.caption2).foregroundStyle(.tertiary)
                if isWide, source == .output, snapshot.loudnessInput != nil, snapshot.loudnessOutput == nil {
                    Text(LoudnessCardText.wideOutputUnavailableNote).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meters.loudness")
    }

    private func value(_ title: String, _ text: String, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(source.title)")
        .accessibilityValue(text)
        .accessibilityIdentifier("meters.loudness.\(id)")
    }
}
