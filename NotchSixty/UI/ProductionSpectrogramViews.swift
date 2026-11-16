import SwiftUI

/// Text for the E33 S9 views; plain so the tests can check it.
enum SpectrogramText {
    static let note = "Output level against time (left is oldest) and frequency (20 Hz at the bottom, log scale), "
        + "from a mono mix of the output. Colour runs from −100 dBFS (dark) to 0 dBFS (bright)."
    static let bitNote = "Which of the 24 fixed-point bits of the program input have been both 0 and 1 since the page was "
        + "opened or Reset. A word shorter than 24 bits leaves its low bits still; a gain-scaled word shows every bit "
        + "active but sits on a coarser grid, and reads as scaled."
    static let channelNames = ["Left", "Right"]
}

/// Spectrogram (D2): one image, newest on the right.
struct ProductionSpectrogramView: View {
    let snapshot: SpectrogramSnapshot?
    let isRunning: Bool
    @Binding var window: SpectrogramWindow

    private let marks: [Double] = [20, 100, 1_000, 10_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Spectrogram").font(.title2.bold())
                Spacer()
                Picker("Window", selection: $window) {
                    ForEach(SpectrogramWindow.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 140)
                .accessibilityIdentifier("meters.spectrogram.window")
            }
            if !isRunning {
                Text("Start processing to view the spectrogram.").foregroundStyle(.secondary)
            } else if snapshot == nil || snapshot?.totalColumns == 0 {
                Text("The spectrogram is filling its first analysis frame…").foregroundStyle(.secondary)
            }
            ZStack(alignment: .leading) {
                if let image = renderedImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                } else {
                    Color.black.opacity(0.4)
                }
            }
            .frame(minHeight: 300)
            .clipShape(.rect(cornerRadius: 14))
            .accessibilityElement()
            .accessibilityLabel("Spectrogram")
            .accessibilityValue(accessibilitySummary)
            .accessibilityIdentifier("meters.spectrogram.image")
            HStack {
                ForEach(marks, id: \.self) { Text($0 >= 1_000 ? "\(Int($0) / 1_000) kHz" : "\(Int($0)) Hz"); Spacer() }
                Text("Bottom to top").foregroundStyle(.tertiary)
            }
            .font(.caption2).foregroundStyle(.secondary)
            Text(SpectrogramText.note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var renderedImage: CGImage? {
        guard let snapshot, snapshot.totalColumns > 0 else { return nil }
        let pixels = snapshot.rgbaPixels()
        guard !pixels.isEmpty, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: snapshot.columns, height: snapshot.rows, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: snapshot.columns * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private var accessibilitySummary: String {
        guard let snapshot, snapshot.totalColumns > 0 else { return "No data" }
        let newest = ((snapshot.totalColumns - 1) % snapshot.columns) * snapshot.rows
        var best = 0
        for r in 0..<snapshot.rows where snapshot.image[newest + r] > snapshot.image[newest + best] { best = r }
        let hz = snapshot.minHz * pow(snapshot.maxHz / snapshot.minHz, Double(best) / Double(snapshot.rows - 1))
        let text = hz >= 1_000 ? String(format: "%.1f kHz", hz / 1_000) : String(format: "%.0f Hz", hz)
        return "Last \(snapshot.window.title). Loudest now near \(text)"
    }
}

/// Bit activity (D3): 24 cells per channel, most significant bit on the left.
struct ProductionBitActivityCard: View {
    let channels: [BitActivityChannel]
    let isRunning: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bit Activity").font(.title3.bold())
                Spacer()
                Button("Reset", action: onReset).accessibilityIdentifier("meters.bits.reset")
            }
            if !isRunning || channels.isEmpty {
                Text("Start processing to measure.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(channels.enumerated()), id: \.offset) { index, channel in
                    HStack(spacing: 10) {
                        Text(SpectrogramText.channelNames[min(index, 1)]).frame(width: 44, alignment: .leading)
                        HStack(spacing: 2) {
                            ForEach((0..<BitActivityChannel.bits).reversed(), id: \.self) { bit in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(channel.toggledMask & (1 << UInt32(bit)) != 0 ? Color.accentColor : Color.secondary.opacity(0.25))
                                    .frame(height: 16)
                            }
                        }
                        Text(channel.text)
                            .font(.callout.monospacedDigit())
                            .frame(minWidth: 220, alignment: .leading)
                            .accessibilityIdentifier("meters.bits.verdict.\(index)")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(SpectrogramText.channelNames[min(index, 1)]) channel bit activity")
                    .accessibilityValue("\(channel.toggledCount) of 24 bits active. \(channel.text)")
                }
            }
            Text(SpectrogramText.bitNote).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 18))
    }
}
