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

    /// Shown when a routed output map has no lane that carries a program channel or a subwoofer feed (matrix-only routing).
    static let wideOutputUnavailableNote = "Output loudness is not measured here, because none of the routed output lanes "
        + "carries a program channel or a subwoofer feed (matrix-only outputs are not measured). Choose Input."
}

/// E33 S7 (`e33.page-enhancements`): what the card adds, the 10 minute history with its target and the maxima.
struct LoudnessCardExtras {
    var history: LoudnessShortTermHistory
    var target: (lufs: Double, fromMatch: Bool)
    var chosenTarget: LoudnessHistoryTarget
    var onChooseTarget: (LoudnessHistoryTarget) -> Void
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
    /// E33 S6: spoken values change at most every 2 s or on a 1 LU move (`e33.page-enhancements`).
    var rateLimitedSpeech = false
    /// E33 S7: nil leaves the card as it was.
    var extras: LoudnessCardExtras?
    @State var spoken = SpokenValueBook()
    let onSource: (LoudnessSource) -> Void
    let onReset: () -> Void

    private var readout: LoudnessReadout? {
        source == .output ? snapshot.loudnessOutput : snapshot.loudnessInput
    }

    /// The target readout and its preset picker. The readout never wraps letter by letter: it keeps its line and the row
    /// reflows to a stack when the width runs out.
    @ViewBuilder
    private func targetRow(_ extras: LoudnessCardExtras) -> some View {
        Text(LoudnessHistoryText.target(extras.target))
            .font(DesignType.caption.font).foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
        if !extras.target.fromMatch {
            Picker("Target", selection: Binding(get: { extras.chosenTarget }, set: extras.onChooseTarget)) {
                ForEach(LoudnessHistoryTarget.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .accessibilityIdentifier("meters.loudness.target")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.m.pt) {
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
                Text(unavailableReason).font(DesignType.caption.font).foregroundStyle(.secondary)
            } else if !isRunning {
                Text("Start processing to measure loudness.").font(DesignType.caption.font).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                    value("Momentary", LoudnessCardText.lufs(readout?.momentary), "momentary", number: readout?.momentary)
                    value("Short-term", LoudnessCardText.lufs(readout?.shortTerm), "shortTerm", number: readout?.shortTerm)
                    if extras != nil {
                        value("Momentary max", LoudnessCardText.lufs(readout?.momentaryMax), "momentaryMax")
                        value("Short-term max", LoudnessCardText.lufs(readout?.shortTermMax), "shortTermMax")
                    }
                    value("Integrated", LoudnessCardText.lufs(readout?.integrated), "integrated", number: readout?.integrated)
                    value("Loudness range", LoudnessCardText.lu(readout?.range), "range")
                    value(
                        "True peak max",
                        LoudnessCardText.truePeak(truePeak.maxDBTP),
                        "truePeakMax"
                    )
                }
                if let extras {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DesignSpacing.m.pt) { targetRow(extras) }
                        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) { targetRow(extras) }
                    }
                    LoudnessHistoryView(history: extras.history, targetLUFS: extras.target.lufs)
                    Text(LoudnessHistoryText.integratedNote + ". Maxima and history clear with Reset.")
                        .font(DesignType.caption.font).foregroundStyle(.tertiary)
                }
                if readout?.isGapped == true {
                    Label("Gapped: capture frames were lost, so integrated loudness may read low. Reset to start again.",
                          systemImage: "exclamationmark.triangle")
                        .font(DesignType.caption.font)
                        .accessibilityIdentifier("meters.loudness.gapped")
                }
                Text(isWide ? LoudnessCardText.wideNote : LoudnessCardText.foldNote)
                    .font(DesignType.caption.font).foregroundStyle(.tertiary)
                if isWide, source == .output, snapshot.loudnessInput != nil, snapshot.loudnessOutput == nil {
                    Text(LoudnessCardText.wideOutputUnavailableNote).font(DesignType.caption.font).foregroundStyle(.secondary)
                }
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designSurface(.medium)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meters.loudness")
    }

    private func value(_ title: String, _ text: String, _ id: String, number: Double? = nil) -> some View {
        let spokenText = rateLimitedSpeech
            ? spoken.value(id: id, text: text, number: number, now: ProcessInfo.processInfo.systemUptime) : text
        return VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text(title).font(DesignType.caption.font).foregroundStyle(.secondary)
            Text(text)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(source.title)")
        .accessibilityValue(spokenText)
        .accessibilityIdentifier("meters.loudness.\(id)")
    }
}
