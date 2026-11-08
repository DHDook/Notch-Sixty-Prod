import SwiftUI

/// E27 S3b: the Equalizer page's A/B slots and the Listen audition control. Shown only when
/// `e27.eq-safety` is on (the controllers are built inert otherwise).
struct ProductionEQCompareBar: View {
    @ObservedObject var comparison: EQComparisonController
    @ObservedObject var audition: EQAuditionController
    let history: EQEditHistory
    let selectedBand: EQBand?
    let perform: (() throws -> Void) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("COMPARE").font(.caption2.bold()).tracking(1.2).foregroundStyle(.secondary)

            Picker("EQ slot", selection: Binding(
                get: { comparison.activeSlot },
                set: { slot in perform { try comparison.select(slot, history: history) } }
            )) {
                ForEach(EQComparisonSlot.allCases) { slot in Text(slot.displayName).tag(slot) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Switch between two EQ settings. B starts as a copy of A and is not saved with the profile.")

            Button("Toggle") { perform { try comparison.toggle(history: history) } }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .help("Switch to the other slot")

            Menu("Copy") {
                Button("Copy A to B") { perform { try comparison.copy(from: .a) } }
                Button("Copy B to A") { perform { try comparison.copy(from: .b) } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!comparison.isComparing)

            Button("Keep A") { perform { try comparison.keep(.a, history: history) } }
                .disabled(!comparison.isComparing)
            Button("Keep B") { perform { try comparison.keep(.b, history: history) } }
                .disabled(!comparison.isComparing)

            Toggle("Match loudness", isOn: Binding(
                get: { comparison.loudnessMatchEnabled },
                set: { comparison.setLoudnessMatch($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!comparison.isComparing)
            .help("Trims the louder slot by the K-weighted pink-noise power difference")

            if comparison.matchTrimDB < -0.05 {
                Text(String(format: "%.1f dB", comparison.matchTrimDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            listenButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    /// Press and hold to hear only the selected band's region; release ends it.
    private var listenButton: some View {
        Label(audition.active == nil ? "Listen" : "Listening", systemImage: "ear")
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(audition.active == nil ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.35), in: Capsule())
            .opacity(selectedBand == nil ? 0.4 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard let band = selectedBand, audition.active == nil else { return }
                        audition.start(band: band)
                    }
                    .onEnded { _ in audition.stop() }
            )
            .help("Hold to hear only the region around the selected band (ends on release, after 30 s, or when you leave the page)")
    }
}
